--[[
	Items: turns interpreter values and ReflectionService entries into Studio completion items, and
	merges them into the response Studio already built without replacing anything.

	Lazy values (unevaluated module thunks) are NEVER forced here: listing a registry of 80 modules
	must not evaluate 80 modules. They show as modules; the user pays only for the one they enter.
]]

local Signature = require(script.Parent.Parent.Language.Signature)
local Types = require(script.Parent.Parent.Language.Types)

local Items = {}
Items.__index = Items

--- kinds: { Function = Enum.CompletionItemKind.Function, ... } (missing names fall back to Text)
--- tags:  { Deprecated = Enum.CompletionItemTag.Deprecated, AddParens = ..., PutCursorInParens = ... }
--- config: optional Core.Config (only `addParens` is read, live)
function Items.new(kinds, tags, config)
	return setmetatable({ _kinds = kinds or {}, _tags = tags or {}, _config = config }, Items)
end

function Items:_kind(name)
	return self._kinds[name] or self._kinds.Text
end

--- Studio's own function completions carry AddParens (insert `()`) and PutCursorInParens (when the
--- function takes arguments); doing the same makes accepted items behave like built-in ones.
function Items:_setTags(item, deprecated, callable, hasParams)
	local names = {}
	if callable and (not self._config or self._config:Get("addParens")) then
		names[#names + 1] = "AddParens"
		if hasParams then
			names[#names + 1] = "PutCursorInParens"
		end
	end
	if deprecated then
		names[#names + 1] = "Deprecated"
	end
	local tags = {}
	for _, name in names do
		local tag = self._tags[name]
		if tag then
			tags[#tags + 1] = tag
		end
	end
	if #tags > 0 then
		item.tags = tags
	end
end

local MAX_DETAIL = 160
local MAX_DOC = 3000

--- Keeps the popup sane when a signature, type or comment is absurdly long.
local function clip(text, limit)
	if #text <= limit then
		return text
	end
	return string.sub(text, 1, limit - 3) .. "..."
end

--- The documentation panel shows plain text (a markdown code fence is printed as typed), so the signature is a plain first line.
local function docValue(signature, doc)
	local parts = {}
	if signature then
		parts[#parts + 1] = clip(signature, 600)
	end
	if doc and doc ~= "" then
		parts[#parts + 1] = doc
	end
	if #parts == 0 then
		return nil
	end
	return { value = clip(table.concat(parts, "\n\n"), MAX_DOC) }
end

local function isDeprecated(doc, tags)
	if tags and tags.deprecated then
		return true
	end
	return doc ~= nil and string.find(string.lower(doc), "@deprecated", 1, true) ~= nil
end

local function peel(v)
	while v.k == "thunk" and v.done do
		v = v.value
	end
	return v
end

local CHILD_KINDS = { ModuleScript = "Module", Folder = "Folder", Script = "Module", LocalScript = "Module" }

--- A named member of a table value. `sep` is "." or ":" (display only affects signatures).
function Items:fromField(name, field, sep)
	local v = peel(field.value)
	local item = { label = name }
	local doc = field.doc
	local tags = field.tags
	if tags and type(tags.deprecated) == "string" and not (doc and string.find(string.lower(doc), "@deprecated", 1, true)) then
		doc = (doc and doc .. "\n\n" or "") .. "@deprecated " .. tags.deprecated
	end
	local callable, hasParams = false, false

	if v.k == "thunk" then
		item.kind = self:_kind(v.module and "Module" or "Field")
		item.detail = v.module and `module {v.module.Name}` or v.typeText or "any"
		item.documentation = docValue(nil, doc)
	elseif v.k == "function" then
		callable = true
		item.kind = self:_kind((field.isMethod or (v.fn and Signature.takesSelf(v.fn))) and "Method" or "Function")
		if v.typeNode then
			-- a function that exists only as a type annotation (`push: (self: Stack<T>, v: T) -> ()`)
			local params, ret = Types.describe(v.typeNode, sep == ":")
			hasParams = params ~= ""
			item.detail = `({params})` .. (ret and ` -> {ret}` or "")
			item.documentation = docValue(`{name}({params})` .. (ret and ` -> {ret}` or ""), doc)
		elseif v.fn then
			local dropSelf = sep == ":"
			local params = Signature.params(v.fn, { dropSelf = dropSelf })
			hasParams = params ~= ""
			item.detail = `({params})` .. (v.fn.ret and ` -> {v.fn.ret}` or "")
			item.documentation = docValue(Signature.render(name, v.fn, { dropSelf = dropSelf }), doc or v.doc)
		else
			hasParams = true
			item.detail = "(...)"
			item.documentation = docValue(nil, doc)
		end
	elseif v.k == "table" then
		local isClass = v.fields.new ~= nil and peel(v.fields.new.value).k == "function"
		item.kind = self:_kind(isClass and "Class" or "Module")
		item.detail = `\{ {#v.order + #v.arr} members }`
		item.documentation = docValue(nil, doc)
	elseif v.k == "instance" then
		item.kind = self:_kind(CHILD_KINDS[v.class] or "Field")
		item.detail = v.class or "Instance"
		item.documentation = docValue(nil, doc)
	elseif v.k == "number" or v.k == "string" or v.k == "bool" then
		local known = v.v ~= nil
		item.kind = self:_kind(known and "Constant" or "Field")
		if v.k == "string" then
			item.detail = known and string.format("string = %q", string.sub(v.v, 1, 40)) or "string"
		elseif v.k == "number" then
			item.detail = known and `number = {v.v}` or "number"
		else
			item.detail = known and `boolean = {tostring(v.v)}` or "boolean"
		end
		item.documentation = docValue(nil, doc)
	elseif v.k == "union" then
		item.kind = self:_kind("Field")
		item.detail = `union of {#v.members}`
		item.documentation = docValue(nil, doc)
	else
		item.kind = self:_kind("Field")
		item.detail = "any"
		item.documentation = docValue(nil, doc)
	end
	self:_setTags(item, isDeprecated(doc, tags), callable, hasParams)
	if item.detail then
		item.detail = clip(item.detail, MAX_DETAIL)
	end
	return item
end

--- An annotation tag being typed after `--@` (see Language/Annotations.CATALOG). `edit` replaces the typed prefix.
function Items:fromTag(entry, edit)
	return {
		label = entry.name,
		kind = self:_kind("Keyword"),
		detail = entry.detail,
		documentation = docValue(nil, entry.doc),
		textEdit = edit,
	}
end

--- One array position of a table (`1`, `2` ...): the value's own summary, minus anything that would add `()`.
function Items:fromIndex(index, count, value, edit)
	local item = self:fromField(tostring(index), { value = value }, ".")
	item.tags = nil
	item.kind = self:_kind("Value")
	item.documentation = docValue(nil, `Array position {index} of {count}.`)
	item.textEdit = edit
	return item
end

--- A row about the argument being written (see Completion/Arguments): the parameter itself, one of the strings its type allows, an enum.
function Items:fromArgument(label, kind, detail, signature, doc, edit, preselect)
	return {
		label = label,
		kind = self:_kind(kind),
		detail = detail and clip(detail, MAX_DETAIL) or nil,
		documentation = docValue(signature, doc),
		textEdit = edit,
		preselect = preselect or nil,
	}
end

--- A ReflectionService member (see ClassCatalog).
function Items:fromCatalog(entry)
	local item = {
		label = entry.name,
		kind = self:_kind(entry.kind),
		detail = entry.detail and clip(entry.detail, MAX_DETAIL) or nil,
	}
	local note = entry.owner and `Defined on {entry.owner}` or nil
	if entry.deprecated and entry.deprecated ~= "" then
		note = (note and note .. "\n\n" or "") .. `@deprecated {entry.deprecated}`
	end
	local params = string.match(entry.detail or "", "^%b()") or "()"
	item.documentation = docValue(entry.kind == "Method" and `{entry.name}{params}` or nil, note)
	self:_setTags(item, entry.deprecated ~= nil, entry.kind == "Method", params ~= "()")
	return item
end

--- A plain name (child instance, registry key, ...). `className` picks the icon. `edit` is an optional
--- textEdit: { newText, replace = { start = {line, character}, end = {line, character} } }.
function Items:fromName(name, kind, detail, edit)
	return {
		label = name,
		kind = self:_kind(kind or "Field"),
		detail = detail and clip(detail, MAX_DETAIL) or nil,
		textEdit = edit,
	}
end

function Items.childKind(className)
	return CHILD_KINDS[className] or "Field"
end

--- Appends new items to response.items. Items whose label already exists only fill missing detail /
--- documentation (Studio's own entries win). Returns how many were added.
function Items.merge(response, newItems, maxItems)
	local existing = {}
	for _, item in response.items do
		existing[item.label] = item
	end
	local added = 0
	for _, item in newItems do
		local current = existing[item.label]
		if current then
			if (current.detail == nil or current.detail == "any") and item.detail ~= nil then
				current.detail = item.detail
			end
			if current.documentation == nil and item.documentation ~= nil then
				current.documentation = item.documentation
			end
		elseif added < maxItems then
			response.items[#response.items + 1] = item
			existing[item.label] = item
			added += 1
		end
	end
	return added
end

return Items
