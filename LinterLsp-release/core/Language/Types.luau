--[[
	Types: reads Luau type syntax - the part after `:` / `::` / `type Name =` / `-> ` - into a small tree, so the
	rest of the plugin can ask "what does a value of this type look like?".

	Handled: primitives and class names, qualified names (`Maid.Maid`), generics with arguments (`Stack<string>`),
	table types (fields, arrays `{T}`, indexers `{[K]: V}`, `read`/`write`), function types (named/anonymous
	parameters, varargs, generic functions, return packs), unions, intersections, optionals, singleton
	strings/booleans, `typeof(expr)`, variadic packs.

	Node kinds (field `k`; `text` is the source text of the node):
	  name    { path = { "Maid", "Maid" }, args = { type... } }
	  table   { fields = { { name, type, tags } ... }, array = type|nil, indexer = { key, value }|nil }
	  fn      { params = { { name|nil, type|nil, vararg } ... }, ret = { type... }, generics = { name... }|nil, retText }
	  union / inter { members }          opt { inner }          vararg { inner }
	  lit     { vk = "string"|"boolean", value }                nil {}
	  typeof  { expr = "source text" }                          pack { members }

	`Types.parse` never throws; it returns nil for text it cannot read. Results are cached by text.
]]

local Lexer = require(script.Parent.Lexer)

local Types = {}

local sub, lower = string.sub, string.lower

local cache = {}
local cacheSize = 0
local MAX_CACHE = 1500
local MAX_TEXT = 20000
local MAX_DEPTH = 40

local function parseText(text, mode)
	local tokens = Lexer.lex(text)
	local kinds, texts, values, starts, ends = tokens.kinds, tokens.texts, tokens.values, tokens.starts, tokens.ends
	local i = 1
	local depth = 0

	local function fail()
		error("type", 0)
	end
	local function isOp(t)
		return kinds[i] == "op" and texts[i] == t
	end
	local function accept(t)
		if kinds[i] == "op" and texts[i] == t then
			i += 1
			return true
		end
		return false
	end
	local function expect(t)
		if not accept(t) then
			fail()
		end
	end
	local function slice(first, last)
		if last <= first then
			return nil
		end
		return sub(text, starts[first], ends[last - 1])
	end

	local parseType, parseSimple

	local function addTag(tags, tag)
		tags = tags or {}
		tags[tag] = true
		return tags
	end

	--- `( a: T, U, ...V )` -> entries; the opening paren is the current token.
	local function parseParams()
		expect("(")
		local entries = {}
		while not isOp(")") do
			if kinds[i] == "eof" then
				fail()
			end
			if isOp("...") then
				i += 1
				local entry = { vararg = true }
				if not isOp(")") and not isOp(",") then
					entry.type = parseType()
				end
				entries[#entries + 1] = entry
			elseif kinds[i] == "name" and kinds[i + 1] == "op" and texts[i + 1] == ":" then
				local name = texts[i]
				i += 2
				entries[#entries + 1] = { name = name, type = parseType() }
			else
				entries[#entries + 1] = { type = parseType() }
			end
			if not accept(",") then
				break
			end
		end
		expect(")")
		return entries
	end

	local function returnList(node)
		if node.k == "pack" then
			return node.members
		end
		return { node }
	end

	local function parseFunctionRest(first, generics, entries)
		expect("->")
		local retFirst = i
		local ret = parseType()
		return {
			k = "fn",
			params = entries,
			ret = returnList(ret),
			generics = generics,
			retText = slice(retFirst, i),
			text = slice(first, i),
		}
	end

	local function parseGenericNames()
		expect("<")
		local names = {}
		while not isOp(">") do
			if kinds[i] ~= "name" then
				fail()
			end
			names[#names + 1] = texts[i]
			i += 1
			if isOp("...") then
				i += 1
			end
			if accept("=") then
				parseType()
			end
			if not accept(",") then
				break
			end
		end
		expect(">")
		return names
	end

	local function parseTableType()
		local first = i
		expect("{")
		local node = { k = "table", fields = {} }
		local pending, last = nil, nil
		while not isOp("}") do
			if kinds[i] == "eof" then
				fail()
			end
			-- markers that the parser carried over from comments: `@@Lprivate` (above) / `@@Tprivate` (same line, after)
			while isOp("@") and kinds[i + 1] == "op" and texts[i + 1] == "@" and kinds[i + 2] == "name" do
				local marker = texts[i + 2]
				local tag = lower(sub(marker, 2))
				if sub(marker, 1, 1) == "T" and last then
					last.tags = addTag(last.tags, tag)
				else
					pending = addTag(pending, tag)
				end
				i += 3
			end
			if isOp("}") then
				break
			end
			local entryFirst = i
			local entry
			if isOp("[") then
				i += 1
				if kinds[i] == "string" and kinds[i + 1] == "op" and texts[i + 1] == "]" then
					local name = values[i]
					i += 2
					expect(":")
					entry = { name = name, type = parseType() }
				else
					local key = parseType()
					expect("]")
					expect(":")
					node.indexer = { key = key, value = parseType() }
				end
			else
				if kinds[i] == "name" and (texts[i] == "read" or texts[i] == "write") and kinds[i + 1] == "name" and kinds[i + 2] == "op" and texts[i + 2] == ":" then
					i += 1
				end
				if kinds[i] == "name" and kinds[i + 1] == "op" and texts[i + 1] == ":" then
					local name = texts[i]
					i += 2
					entry = { name = name, type = parseType() }
				else
					node.array = parseType()
				end
			end
			if entry then
				entry.tags = pending
				pending = nil
				node.fields[#node.fields + 1] = entry
				last = entry
			end
			if i == entryFirst then
				fail()
			end
			if not (accept(",") or accept(";")) and not isOp("}") then
				-- a trailing marker may sit between the value and the closing brace
				if not (isOp("@") and kinds[i + 1] == "op" and texts[i + 1] == "@") then
					fail()
				end
			end
		end
		expect("}")
		node.text = slice(first, i)
		return node
	end

	local function parseTypeArgs()
		expect("<")
		local args = {}
		while not isOp(">") do
			if kinds[i] == "eof" then
				fail()
			end
			args[#args + 1] = parseType()
			if not accept(",") then
				break
			end
		end
		expect(">")
		return args
	end

	parseSimple = function()
		depth += 1
		if depth > MAX_DEPTH then
			fail()
		end
		local first = i
		local k, t = kinds[i], texts[i]
		local node
		if k == "keyword" and t == "nil" then
			i += 1
			node = { k = "nil" }
		elseif k == "keyword" and (t == "true" or t == "false") then
			i += 1
			node = { k = "lit", vk = "boolean", value = t == "true" }
		elseif k == "string" then
			node = { k = "lit", vk = "string", value = values[i] }
			i += 1
		elseif k == "name" and t == "typeof" and kinds[i + 1] == "op" and texts[i + 1] == "(" then
			i += 2
			local exprFirst, nesting = i, 1
			while nesting > 0 do
				if kinds[i] == "eof" then
					fail()
				end
				if kinds[i] == "op" then
					if texts[i] == "(" then
						nesting += 1
					elseif texts[i] == ")" then
						nesting -= 1
					end
				end
				i += 1
			end
			node = { k = "typeof", expr = slice(exprFirst, i - 1) or "" }
		elseif k == "name" then
			local path = { t }
			i += 1
			while isOp(".") and kinds[i + 1] == "name" do
				path[#path + 1] = texts[i + 1]
				i += 2
			end
			node = { k = "name", path = path }
			if isOp("<") then
				node.args = parseTypeArgs()
			end
			if isOp("...") then
				i += 1
				node = { k = "vararg", inner = node }
			end
		elseif k == "op" and t == "{" then
			node = parseTableType()
		elseif k == "op" and t == "(" then
			local entries = parseParams()
			if isOp("->") then
				node = parseFunctionRest(first, nil, entries)
			elseif #entries == 1 and not entries[1].name and not entries[1].vararg and entries[1].type then
				node = entries[1].type -- just parentheses
			else
				local members = {}
				for _, entry in entries do
					members[#members + 1] = entry.type or { k = "name", path = { "any" } }
				end
				node = { k = "pack", members = members }
			end
		elseif k == "op" and t == "<" then
			local generics = parseGenericNames()
			local entries = parseParams()
			node = parseFunctionRest(first, generics, entries)
		elseif k == "op" and t == "..." then
			i += 1
			node = { k = "vararg", inner = parseSimple() }
		else
			fail()
		end
		depth -= 1
		node.text = node.text or slice(first, i)
		return node
	end

	parseType = function()
		local first = i
		if isOp("|") or isOp("&") then
			i += 1
		end
		local node = parseSimple()
		while true do
			if isOp("?") then
				i += 1
				node = { k = "opt", inner = node }
			elseif isOp("|") or isOp("&") then
				local kind = isOp("|") and "union" or "inter"
				i += 1
				local rhs = parseSimple()
				if node.k == kind then
					node.members[#node.members + 1] = rhs
				else
					node = { k = kind, members = { node, rhs } }
				end
			else
				break
			end
		end
		node.text = slice(first, i)
		return node
	end

	if mode == "generics" then
		local names = {}
		while kinds[i] ~= "eof" do
			if kinds[i] ~= "name" then
				fail()
			end
			local entry = { name = texts[i] }
			i += 1
			if isOp("...") then
				i += 1
				entry.pack = true
			end
			if accept("=") then
				entry.default = parseType()
			end
			names[#names + 1] = entry
			if not accept(",") then
				break
			end
		end
		return names
	end

	local result = parseType()
	if kinds[i] ~= "eof" then
		-- tolerate trailing junk (`T = value`): the type itself was read
		return result
	end
	return result
end

local function cached(key, text, mode)
	if type(text) ~= "string" or text == "" or #text > MAX_TEXT then
		return nil
	end
	local store = cache[key]
	if not store then
		store = {}
		cache[key] = store
	end
	local hit = store[text]
	if hit ~= nil then
		return hit or nil
	end
	local ok, result = pcall(parseText, text, mode)
	if cacheSize >= MAX_CACHE then
		cache, cacheSize = {}, 0
		store = {}
		cache[key] = store
	end
	cacheSize += 1
	store[text] = ok and result or false
	return ok and result or nil
end

--- Type tree for `text`, or nil when it is not readable type syntax.
function Types.parse(text)
	return cached("type", text, nil)
end

--- Generic parameter list text (`T, U = string`) -> { { name, default }... }, or nil.
function Types.parseGenerics(text)
	return cached("generics", text, "generics")
end

--- `(a: number, b: string) -> boolean` pieces for display: params as { name, text } and the result text.
function Types.describe(fnType, dropSelf)
	local params = {}
	for index, param in fnType.params do
		if not (dropSelf and index == 1 and param.name == "self") then
			local text = param.type and param.type.text or "any"
			if param.vararg then
				text = "..." .. text
			end
			params[#params + 1] = param.name and `{param.name}: {text}` or text
		end
	end
	return table.concat(params, ", "), fnType.retText
end

return Types
