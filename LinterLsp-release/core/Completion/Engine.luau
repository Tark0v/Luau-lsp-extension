--[[
	Engine: one completion request, end to end.

	  1. cheap check of the cursor line (Context.quick) - most keystrokes stop here
	  2. incrementally re-lex the text before the cursor (only the changed tail is lexed again)
	  3. decide what is being completed (Context.analyze) and parse the code before the access chain
	  4. interpret that code to learn what is in scope (World.runCurrent), evaluate the chain, list members
	  5. append the items to Studio's own response (Items.merge)

	Hard guarantees: never yields, never throws to Studio, bounded by fuel and wall-clock time (the clock
	starts when interpretation starts, so parsing a big file cannot starve it), and a circuit breaker
	switches the engine off for a while if requests keep being slow.
]]

local Budget = require(script.Parent.Parent.Core.Budget)
local Log = require(script.Parent.Parent.Core.Log)
local Lexer = require(script.Parent.Parent.Language.Lexer)
local Parser = require(script.Parent.Parent.Language.Parser)
local Signature = require(script.Parent.Parent.Language.Signature)
local Annotations = require(script.Parent.Parent.Language.Annotations)
local InstanceApi = require(script.Parent.Parent.Builtin.InstanceApi)
local Values = require(script.Parent.Parent.Interp.Values)
local Context = require(script.Parent.Context)
local Items = require(script.Parent.Items)
local Arguments = require(script.Parent.Arguments)

local Engine = {}
Engine.__index = Engine

local force = Values.force

local MAX_CACHED_DOCUMENTS = 3
local COMMAND_BAR = {}

local LUA_KEYWORDS = {}
for _, word in
	{ "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while" }
do
	LUA_KEYWORDS[word] = true
end

--- Can `name` follow a dot / colon?
local function isIdentifier(name)
	return string.match(name, "^[%a_][%w_]*$") ~= nil and not LUA_KEYWORDS[name]
end

--- Can `name` be shown as a string key (`t["name"]`, `WaitForChild("name")`) without confusing the popup?
local function isShowable(name)
	return #name > 0 and #name <= 120 and not string.find(name, "%c")
end

--- `Spawn "Point"` -> `Spawn \"Point\"`, for writing a name between double quotes.
local function escapeKey(name)
	return (string.gsub(string.gsub(name, "\\", "\\\\"), '"', '\\"'))
end

--- A textEdit that replaces `back` bytes before the cursor (and `extend` after it) with `newText`. `edit` is
--- { position = request.position, back = n }. The cursor ends up after the new text.
local function replaceEdit(edit, newText, extend)
	local position = edit.position
	return {
		newText = newText,
		replace = {
			start = { line = position.line, character = position.character - edit.back },
			["end"] = { line = position.line, character = position.character + (extend or 0) },
		},
	}
end

--- Takes the names in `hide` out of Studio's own list (a member marked `--@Private` is listed by Studio when it can type the module
--- itself). A name Linter is offering anyway (a union where another table has it publicly) stays.
local function trimHidden(list, hide, offered)
	local visible = {}
	for _, item in offered do
		visible[item.label] = true
	end
	local count = #list
	local kept = 0
	for index = 1, count do
		local item = list[index]
		local label = type(item) == "table" and item.label
		if not (label and hide[label] and not visible[label]) then
			kept += 1
			list[kept] = item
		end
	end
	for index = count, kept + 1, -1 do
		list[index] = nil
	end
end

--- deps: config, world, items (Items instance), catalog (ClassCatalog|nil), clock
function Engine.new(deps)
	return setmetatable({
		_config = deps.config,
		_world = deps.world,
		_items = deps.items,
		_catalog = deps.catalog,
		_clock = deps.clock or os.clock,
		_strikes = 0,
		_disabledUntil = 0,
		_lexCache = {},
		_lexOrder = {},
		_hide = {}, -- names of the member list being built that are marked private / hidden: they leave Studio's list too
		lastStats = nil, -- { ms, status, added } of the most recent request
	}, Engine)
end

--- Drops cached token streams (e.g. after Rescan).
function Engine:clearCaches()
	self._lexCache, self._lexOrder = {}, {}
end

function Engine:_tokens(key, before)
	local cache, order = self._lexCache, self._lexOrder
	local tokens = Lexer.update(cache[key], before)
	if cache[key] == nil then
		order[#order + 1] = key
		if #order > MAX_CACHED_DOCUMENTS then
			cache[table.remove(order, 1)] = nil
		end
	end
	cache[key] = tokens
	return tokens
end

local function parseChain(text)
	return Parser.parseExpression(Lexer.lex(text))
end

--- How well `query` matches `text` (case-insensitive), lower is better, nil = no match:
--- 1 prefix, 2 prefix of a later path segment, 3 substring, 4 letters in order ("fusn" finds "Fusion").
local function fuzzyRank(text, query, sep)
	local t, q = string.lower(text), string.lower(query)
	if string.sub(t, 1, #q) == q then
		return 1
	end
	if string.find(t, sep .. q, 1, true) then
		return 2
	end
	if string.find(t, q, 1, true) then
		return 3
	end
	local position = 1
	for index = 1, #q do
		local found = string.find(t, string.sub(q, index, index), position, true)
		if not found then
			return nil
		end
		position = found + 1
	end
	return 4
end

local MAX_PATH_ITEMS = 80

-- strings that name an attribute / a tag, by the method that takes them (names only: nothing here is ever called)
local ATTRIBUTE_CALLS = { ["GetAttribute"] = true, ["SetAttribute"] = true, ["GetAttributeChangedSignal"] = true }
local INSTANCE_TAG_CALLS = { ["HasTag"] = true, ["AddTag"] = true, ["RemoveTag"] = true }
local COLLECTION_TAG_CALLS = {
	["GetTagged"] = 1, ["GetInstanceAddedSignal"] = 1, ["GetInstanceRemovedSignal"] = 1,
	["AddTag"] = 2, ["HasTag"] = 2, ["RemoveTag"] = 2,
}

--- Completion items for path-like candidates ("A/B/C"). Works one directory at a time, like a file picker:
---   typed "SystemLibraries/"    -> the entries directly inside it, as bare segments
---   typed "SystemLibraries/Su"  -> segments (and deeper paths) that fuzzy-match "Su"
--- Every item carries a textEdit that replaces just the segment being typed, so accepting one never duplicates
--- the part of the path you already wrote.
local function pathItems(items, candidates, sep, prefix, position)
	local dirEnd, from = 0, 1
	while true do
		local first, last = string.find(prefix, sep, from, true)
		if not first then
			break
		end
		dirEnd, from = last, last + 1
	end
	local dir, partial = string.sub(prefix, 1, dirEnd), string.sub(prefix, dirEnd + 1)

	local scored = {}
	for _, candidate in candidates do
		local path = candidate.name
		if dir == "" or string.sub(path, 1, #dir) == dir then
			local relative = string.sub(path, #dir + 1)
			if relative ~= "" and isShowable(relative) then
				local rank
				if partial == "" then
					rank = string.find(relative, sep, 1, true) == nil and 0 or nil -- just what is directly inside
				else
					rank = fuzzyRank(relative, partial, sep)
				end
				if rank then
					scored[#scored + 1] = { relative = relative, path = path, rank = rank }
				end
			end
		end
	end
	table.sort(scored, function(a, b)
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		if #a.relative ~= #b.relative then
			return #a.relative < #b.relative
		end
		return a.relative < b.relative
	end)

	-- "letters in order" matches are only a last resort: next to a real prefix/substring hit they are noise
	if scored[1] and scored[1].rank >= 1 and scored[1].rank <= 3 then
		local strong = {}
		for _, entry in scored do
			if entry.rank <= 3 then
				strong[#strong + 1] = entry
			end
		end
		scored = strong
	end

	local out = {}
	for index = 1, math.min(#scored, MAX_PATH_ITEMS) do
		local entry = scored[index]
		local edit
		if position then
			edit = {
				newText = entry.relative,
				replace = {
					start = { line = position.line, character = position.character - #partial },
					["end"] = { line = position.line, character = position.character },
				},
			}
		end
		out[#out + 1] = items:fromName(entry.relative, "Module", entry.path, edit)
	end
	return out
end

local function isFunctionWithColon(field)
	local v = field.value
	return v.k == "function" and (field.isMethod or (v.fn ~= nil and Signature.takesSelf(v.fn)))
end

--- `bracket`: the key will be typed inside quotes (`t["..."]`), so any showable string is valid;
--- otherwise only names that can follow a dot are offered.
--- Array positions of a table as items `1`, `2` ... `make(label)` builds each one's textEdit. Before a digit is typed only the
--- first few are offered; with digits typed, every position that starts with them (up to a cap).
function Engine:_arrayItems(tbl, prefix, make, out)
	local count = #tbl.arr
	if count == 0 or not (prefix == "" or string.find(prefix, "^%d+$")) then
		return
	end
	local cfg = self._world.cfg
	local limit = prefix == "" and cfg.maxIndexItems or 30
	local added = 0
	for position = 1, count do
		local label = tostring(position)
		if prefix == "" or string.sub(label, 1, #prefix) == prefix then
			local ok, item = pcall(self._items.fromIndex, self._items, position, count, tbl.arr[position], make(label))
			if ok then
				out[#out + 1] = item
			end
			added += 1
			if added >= limit then
				break
			end
		end
	end
end

--- `edit` ({ position, back, prefix }) is present when the list is being written after a `.`: that is what lets an item replace the
--- dot as well, so a name that cannot follow one becomes `["Spawn Point"]` and an array position becomes `[1]`.
function Engine:_memberItems(value, sep, out, depth, bracket, edit)
	value = force(value)
	local world = self._world
	local cfg = world.cfg
	local viewer = world.currentScript -- the script being edited: it may see its own `--@Private` members
	local items = self._items
	local function usable(name)
		if bracket then
			return isShowable(name)
		end
		return isIdentifier(name)
	end

	if value.k == "table" then
		if value.isGlobals then
			self._world:ensureGlobals()
		end
		local oddKeys = edit ~= nil and sep == "." and not bracket and cfg.suggestBracketKeys
		for _, member in Values.members(value) do
			-- metamethod names are noise, and a constructor reached through __index is not a member of an instance
			local hidden = string.sub(member.name, 1, 2) == "__" or (member.inherited and member.name == "new")
			local plain = usable(member.name)
			if not hidden and (sep == "." or isFunctionWithColon(member.field)) and (plain or (oddKeys and isShowable(member.name))) then
				local field = member.field
				local fieldValue = field.value
				local marked = Values.hiddenFor(member.name, field, viewer, cfg.hideUnderscore)
					or (fieldValue.k == "thunk" and world:isFilePrivate(fieldValue.module, viewer))
				if marked then
					self._hide[member.name] = true -- Studio may list it too (it types a plainly required module itself)
				else
					-- one member that cannot be rendered must not take the whole list down with it
					local ok, item = pcall(items.fromField, items, member.name, field, sep)
					if ok then
						if not plain then
							item.textEdit = replaceEdit(edit, `["{escapeKey(member.name)}"]`) -- `end`, `Spawn Point`, `2nd`: no dot form exists
						end
						out[#out + 1] = item
					else
						Log.debug("could not render member %s: %s", member.name, tostring(item))
					end
				end
			end
		end
		if edit and sep == "." and depth == 0 and not bracket and cfg.suggestIndexes then
			self:_arrayItems(value, edit.prefix, function(label)
				return replaceEdit(edit, `[{label}]`)
			end, out)
		end
		if value.idx and sep == "." then
			-- unknown keys exist: surface the shape of what they hold, one level deep
			local inner = force(value.idx)
			if inner.k == "table" and depth < 1 then
				self:_memberItems(inner, sep, out, depth + 1, bracket, edit)
			elseif inner.k ~= "table" and #value.arr == 0 and edit and depth == 0 and not bracket and edit.prefix == "" then
				-- keys only known at run time (`cache[id] = 32`): one row says what they hold; accepting it starts `[`
				local ok, item = pcall(items.fromField, items, "[key]", { value = inner }, sep)
				if ok then
					item.tags, item.textEdit = nil, replaceEdit(edit, "[")
					out[#out + 1] = item
				end
			end
		end
	elseif value.k == "instance" then
		if value.inst and sep == "." then
			local oddNames = edit ~= nil and not bracket and cfg.suggestBracketKeys
			for _, entry in InstanceApi.childEntries(value.inst, cfg.maxChildren, world.vm and world.vm.moves) do
				if entry.inst and world:isFilePrivate(entry.inst, viewer) then
					self._hide[entry.name] = true
				else
					if usable(entry.name) then
						out[#out + 1] = items:fromName(entry.name, Items.childKind(entry.class), entry.class)
					elseif oddNames and isShowable(entry.name) then
						-- a child called "Spawn Point": workspace["Spawn Point"]
						out[#out + 1] = items:fromName(entry.name, Items.childKind(entry.class), entry.class, replaceEdit(edit, `["{escapeKey(entry.name)}"]`))
					end
				end
			end
		end
		local catalog = self._catalog
		if catalog and cfg.reflection and value.class and not bracket then
			for _, entry in catalog:members(value.class) or {} do
				if (sep == "." or entry.kind == "Method") and isIdentifier(entry.name) then
					out[#out + 1] = items:fromCatalog(entry)
				end
			end
		end
	elseif value.k == "union" then
		for _, member in value.members do
			self:_memberItems(member, sep, out, depth, bracket, edit)
		end
	end
end

--- The function being called at the cursor: base (the value before the `.` / `:`, nil for a plain name), callee, and the `self`
--- a `:` call passes. An instance base has no callee here (its methods are Studio's and the whitelist's business).
function Engine:_calleeOf(ctx, scope)
	local interp = self._world.interp
	if not ctx.baseText then
		return nil, ctx.name and (scope:lookup(ctx.name) or Values.Unknown) or Values.Unknown, nil
	end
	local baseExpr = parseChain(ctx.baseText)
	if not baseExpr then
		return nil, nil, nil
	end
	local base = force(interp:eval(baseExpr, scope))
	if base.k == "instance" then
		return base, nil, nil
	end
	return base, interp:index(base, ctx.name), ctx.sep == ":" and base or nil
end

--- What the parameter at the cursor accepts: spec (TypeResolver:argumentSpec), the call's description and the parameter.
function Engine:_parameterAt(callee, ctx)
	local info = Arguments.describe(callee, ctx.sep == ":")
	local param = info and Arguments.parameter(info, ctx.argIndex)
	if not param then
		return nil, info, nil
	end
	local fnV = info.fnV
	local generics = fnV.fn and fnV.fn.generics or fnV.typeNode and fnV.typeNode.generics
	local spec = (param.node or param.text) and self._world.types:argumentSpec(param.node or param.text, fnV.env, generics)
	return spec, info, param
end

--- `f(` / `f(a, na|`: the parameter being written, and what its type allows.
function Engine:_argumentItems(ctx, scope)
	if not self._world.cfg.suggestArguments then
		return nil
	end
	local _, callee = self:_calleeOf(ctx, scope)
	if not callee then
		return nil
	end
	local spec, info, param = self:_parameterAt(callee, ctx)
	if not param then
		return nil
	end
	return Arguments.items(self._items, ctx, info, param, spec)
end

function Engine:_callStringItems(ctx, scope)
	local world = self._world
	local interp = world.interp
	local items = self._items
	local selfV, callee

	if ctx.baseText then
		local baseExpr = parseChain(ctx.baseText)
		if not baseExpr then
			return nil
		end
		local base = force(interp:eval(baseExpr, scope))
		if base.k == "instance" then
			local out = {}
			local cfgNow = world.cfg
			if base.inst and cfgNow.suggestAttributeNames then
				local tagArg = COLLECTION_TAG_CALLS[ctx.name]
				if ATTRIBUTE_CALLS[ctx.name] and ctx.argIndex == 1 then
					for _, attribute in InstanceApi.attributeEntries(base.inst, cfgNow.maxItems) do
						out[#out + 1] = items:fromName(attribute.name, "Field", `attribute ({attribute.type})`)
					end
					return out
				elseif (INSTANCE_TAG_CALLS[ctx.name] and ctx.argIndex == 1) or (base.class == "CollectionService" and tagArg == ctx.argIndex) then
					local own = base.class ~= "CollectionService" and base.inst or nil
					for _, name in InstanceApi.tagNames(world.host.game, own, cfgNow.maxItems) do
						out[#out + 1] = items:fromName(name, "Field", "tag")
					end
					return out
				end
			end
			if base.inst and ctx.argIndex == 1 and (ctx.name == "WaitForChild" or ctx.name == "FindFirstChild") then
				for _, entry in InstanceApi.childEntries(base.inst, world.cfg.maxChildren, world.vm and world.vm.moves) do
					if isShowable(entry.name) and not (entry.inst and world:isFilePrivate(entry.inst, world.currentScript)) then
						out[#out + 1] = items:fromName(entry.name, Items.childKind(entry.class), entry.class)
					end
				end
			end
			return out
		end
		if ctx.sep == ":" then
			selfV = base
		end
		callee = interp:index(base, ctx.name)
	else
		callee = ctx.name and (scope:lookup(ctx.name) or Values.Unknown) or Values.Unknown
	end

	local candidates = world:stringCandidates(callee, selfV, ctx.argIndex)
	local literals = {}
	if world.cfg.suggestArguments then
		-- `mode: "Fast" | "Slow"`: the strings the parameter's type allows
		local ok, spec = pcall(self._parameterAt, self, callee, ctx)
		if ok and spec then
			literals = Arguments.strings(spec)
		end
	end
	if not candidates and #literals == 0 then
		return nil
	end
	local out, paths, sep = {}, {}, nil
	local signature, note
	if #literals > 0 then
		local _, info, param = self:_parameterAt(callee, ctx)
		if param then
			signature = Arguments.signature(info, ctx.name or "f")
			local described = param.name and (param.text and `{param.name}: {param.text}` or param.name) or param.text or "any"
			note = `Argument {ctx.argIndex} of {#info.params - info.first + 1}: {described}`
		end
	end
	for _, text in literals do
		out[#out + 1] = items:fromArgument(text, "EnumMember", "allowed string", signature, note, nil)
	end
	for _, candidate in candidates or {} do
		if candidate.sep then
			sep = candidate.sep
			paths[#paths + 1] = candidate
		elseif isShowable(candidate.name) then
			local kind = candidate.kind == "instance" and Items.childKind(candidate.detail) or "Module"
			out[#out + 1] = items:fromName(candidate.name, kind, candidate.detail)
		end
	end
	if sep then
		for _, item in pathItems(items, paths, sep, ctx.prefix or "", ctx.position) do
			out[#out + 1] = item
		end
	end
	return out
end

local PRIMITIVE_TYPE_NAMES = { "string", "number", "boolean", "any", "nil", "table", "thread", "buffer", "unknown" }
local MAX_TYPE_ITEMS = 80

--- Parameter names of the function declared on the first code line below the cursor.
local function parametersBelow(text, offset)
	local lineEnd = string.find(text, "\n", offset, true)
	if not lineEnd then
		return {}
	end
	local position = lineEnd + 1
	for _ = 1, 8 do
		local nextEnd = string.find(text, "\n", position, true) or #text + 1
		local line = string.sub(text, position, nextEnd - 1)
		if string.find(line, "%S") and not string.find(line, "^%s*%-%-") then
			local names = {}
			local list = string.match(line, "%(([^%)]*)%)")
			for part in string.gmatch(list or "", "[^,]+") do
				local name = string.match(part, "^%s*([%a_][%w_]*)")
				if name and name ~= "self" then
					names[#names + 1] = name
				end
			end
			return names
		end
		position = nextEnd + 1
		if position > #text then
			break
		end
	end
	return {}
end

--- Aliases (`type X` / `export type X`) written in the document, in order of appearance.
local function aliasesIn(text)
	local names, seen = {}, {}
	for _, pattern in { "\n%s*export%s+type%s+([%a_][%w_]*)", "\n%s*type%s+([%a_][%w_]*)" } do
		for name in string.gmatch("\n" .. text, pattern) do
			if not seen[name] then
				seen[name] = true
				names[#names + 1] = name
			end
		end
	end
	return names
end

--- Completions for an annotation being typed in a comment: the tag itself (`--@Pri|`), a parameter name
--- (`--@param na|`) or a type (`--@param maid Ma|`, `--@type Co|`).
function Engine:_markerItems(ctx, text, offset)
	local items = self._items
	local position, prefix = ctx.position, ctx.prefix
	local lowered = string.lower(prefix)
	local function edit(word)
		return {
			newText = word,
			replace = {
				start = { line = position.line, character = position.character - #prefix },
				["end"] = { line = position.line, character = position.character },
			},
		}
	end
	local function matches(name)
		return string.lower(string.sub(name, 1, #prefix)) == lowered
	end

	local out = {}
	if ctx.stage == "tag" then
		for _, entry in Annotations.CATALOG do
			if matches(entry.name) then
				out[#out + 1] = items:fromTag(entry, edit(entry.name))
			end
		end
	elseif ctx.stage == "param-name" then
		for _, name in parametersBelow(text, offset) do
			if matches(name) then
				out[#out + 1] = items:fromName(name, "Variable", "parameter", edit(name))
			end
		end
	else
		local seen = {}
		local function add(name, kind, detail)
			if not seen[name] and matches(name) and #out < MAX_TYPE_ITEMS then
				seen[name] = true
				out[#out + 1] = items:fromName(name, kind, detail, edit(name))
			end
		end
		for _, name in aliasesIn(text) do
			add(name, "Struct", "type alias")
		end
		for _, name in PRIMITIVE_TYPE_NAMES do
			add(name, "Keyword", "type")
		end
		local classes = self._catalog and self._catalog:classNames()
		for _, name in classes or {} do
			if #out >= MAX_TYPE_ITEMS then
				break
			end
			add(name, "Class", "Roblox class")
		end
	end
	return out
end

--- `Shapes.` in a type position: the types `Shapes` exports (and, for a plain table of modules, the modules inside it).
function Engine:_typeMemberItems(value, out)
	local world = self._world
	local items = self._items
	value = force(value)
	local module = value.k == "table" and value.moduleScript or nil
	if module then
		for name, entry in world:typesOf(module) do
			if entry.decl.exported then
				local generics = entry.decl.generics
				out[#out + 1] = items:fromName(name, "Struct", generics and `type {name}<{generics}>` or "type")
			end
		end
	end
	if value.k == "table" then
		for _, member in Values.members(value) do
			local fieldValue = member.field.value
			if string.sub(member.name, 1, 2) ~= "__" and isIdentifier(member.name) and (fieldValue.k == "thunk" and fieldValue.module or force(fieldValue).k == "table") then
				if not Values.hiddenFor(member.name, member.field, world.currentScript, false) then
					out[#out + 1] = items:fromName(member.name, "Module", "namespace")
				end
			end
		end
	end
end

function Engine:_resolve(ctx, chunk, scriptInst)
	local world = self._world
	local scope = world:runCurrent(chunk, scriptInst)
	if ctx.kind == "call-string" then
		return self:_callStringItems(ctx, scope)
	elseif ctx.kind == "call-arg" then
		return self:_argumentItems(ctx, scope)
	end
	local expr = parseChain(ctx.chainText)
	if not expr then
		return nil
	end
	if ctx.kind == "type-member" then
		local out = {}
		self:_typeMemberItems(world.interp:eval(expr, scope), out)
		return out
	end
	if ctx.kind == "index-number" then
		-- `t[` / `t[1`: the array positions that exist, written as `1]` (replacing a `]` the editor already closed)
		local out = {}
		if world.cfg.suggestIndexes then
			local value = force(world.interp:eval(expr, scope))
			if value.k == "union" then
				for _, member in value.members do
					local candidate = force(member)
					if candidate.k == "table" and #candidate.arr > 0 then
						value = candidate
						break
					end
				end
			end
			if value.k == "table" then
				local position, closed = ctx.position, ctx.nextChar == "]" and 1 or 0
				self:_arrayItems(value, ctx.prefix, function(label)
					return replaceEdit({ position = position, back = #ctx.prefix }, label .. "]", closed)
				end, out)
			end
		end
		return out
	end
	local out = {}
	local edit = ctx.operatorBack and { position = ctx.position, back = ctx.operatorBack, prefix = ctx.prefix } or nil
	self:_memberItems(world.interp:eval(expr, scope), ctx.sep, out, 0, ctx.kind == "index-string", edit)
	return out
end

function Engine:_complete(request, response)
	local cfg = self._config
	local document = request.textDocument and request.textDocument.document
	if not document then
		return
	end
	local text = document:GetText()
	if #text > cfg:Get("maxSourceBytes") then
		return
	end
	local offset = Context.offsetOf(text, request.position.line, request.position.character)
	local before = string.sub(text, 1, offset - 1)
	if not Context.quick(before) then
		return
	end

	local scriptInst = request.textDocument.script
	if scriptInst then
		self._world:syncEditorText(scriptInst, text) -- never answer from a past version if the change event is late
	end
	local tokens = self:_tokens(scriptInst or COMMAND_BAR, before)
	local ctx = Context.analyze(before, tokens)
	if not ctx then
		return
	end
	if ctx.kind == "call-arg" and not cfg:Get("suggestArguments") then
		return -- nothing to say, so do not interpret the script for it
	end
	ctx.position = request.position
	ctx.nextChar = string.sub(text, offset, offset)
	if ctx.kind == "marker" then
		local result = self:_markerItems(ctx, text, offset)
		local added = Items.merge(response, result, cfg:Get("maxItems"))
		self.lastStats = { status = "ok", added = added, kind = "marker" }
		return
	end
	local chunk = Parser.parse(tokens, { limit = ctx.startIndex - 1 })

	-- the clock starts here: lexing and parsing a large file must not eat the interpreter's allowance
	local budget = Budget.new({
		fuel = cfg:Get("fuelPerRequest"),
		ms = cfg:Get("requestBudgetMs"),
		clock = self._clock,
	})
	self._hide = {}
	self._world:beginRequest(budget)
	local ok, result, status = Budget.run(function()
		return self:_resolve(ctx, chunk, scriptInst)
	end)
	self._world:endRequest()
	if not ok then
		Log.debug("request %s (%s)", status, tostring(result))
		self.lastStats = { status = status, added = 0 }
		return
	end
	if result and cfg:Get("trimStudioList") and next(self._hide) then
		trimHidden(response.items, self._hide, result)
	end
	local added = result and Items.merge(response, result, cfg:Get("maxItems")) or 0
	self.lastStats = { status = "ok", added = added, kind = ctx.kind }
end

--- Names the last request marked private / hidden: a host that cannot trim the editor's own list (the LSP proxy) removes them itself.
function Engine:hiddenNames()
	local names = {}
	for name in self._hide do
		names[#names + 1] = name
	end
	table.sort(names)
	return names
end

--- Entry point for the autocomplete callback. Always returns `response`.
function Engine:complete(request, response)
	local cfg = self._config
	self.lastStats = nil
	if not cfg:Get("enabled") then
		return response
	end
	local started = self._clock()
	if started < self._disabledUntil then
		return response
	end

	local ok, err = pcall(self._complete, self, request, response)
	if not ok then
		Log.debug("completion error: %s", tostring(err))
		self.lastStats = { status = "error", error = tostring(err), added = 0 }
	end

	local elapsedMs = (self._clock() - started) * 1000
	if self.lastStats then
		self.lastStats.ms = elapsedMs
	end
	-- Options > Debug output: shows whether Studio asked at all (it does not ask on every keystroke) and what Linter answered
	if Log.debugEnabled then
		local position = request.position
		local stats = self.lastStats
		Log.debug(
			"request %s:%s -> %s%s (%.1f ms)",
			tostring(position and position.line),
			tostring(position and position.character),
			stats and `{stats.kind or "-"} {stats.status}, {stats.added or 0} items` or "nothing to complete here",
			stats and stats.error and ` [{stats.error}]` or "",
			elapsedMs
		)
	end
	if elapsedMs > cfg:Get("slowRequestMs") then
		self._strikes += 1
		if self._strikes >= cfg:Get("slowRequestStrikes") then
			self._strikes = 0
			self._disabledUntil = started + cfg:Get("circuitCooldownSeconds")
			Log.warn("completions were slow %d times in a row; pausing for %ds", cfg:Get("slowRequestStrikes"), cfg:Get("circuitCooldownSeconds"))
		end
	else
		self._strikes = 0
	end
	return response
end

return Engine
