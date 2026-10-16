--[[
	Convert: Studio-shaped completion items and diagnostics (what Completion/Items and Completion/Checker build: 1-based
	positions in bytes, kinds and tags as names) -> LSP shapes (0-based UTF-16 positions, numeric kinds).
]]

local Text = require("./Text")

local Convert = {}

local KIND_NAMES = {
	"Text", "Method", "Function", "Constructor", "Field", "Variable", "Class", "Interface", "Module", "Property",
	"Unit", "Value", "Enum", "Keyword", "Snippet", "Color", "File", "Reference", "Folder", "EnumMember", "Constant",
	"Struct", "Event", "Operator", "TypeParameter",
}
local KIND_NUMBER = {}
for index, name in KIND_NAMES do
	KIND_NUMBER[name] = index -- LSP CompletionItemKind numbers are exactly this order
end
Convert.KIND_NAMES = KIND_NAMES

local function hasTag(tags, name)
	return tags ~= nil and table.find(tags, name) ~= nil
end

local function lspRange(text, starts, range)
	return {
		start = Text.fromEngine(text, starts, range.start.line, range.start.character),
		["end"] = Text.fromEngine(text, starts, range["end"].line, range["end"].character),
	}
end

--- One item. `text`/`starts`: the document; `cursor`: the engine position of the request (for filterText).
function Convert.item(item, text, starts, cursor)
	local out = {
		label = item.label,
		kind = KIND_NUMBER[item.kind] or 1,
		detail = item.detail,
		preselect = item.preselect,
	}
	if item.documentation and item.documentation.value then
		out.documentation = { kind = "plaintext", value = item.documentation.value }
	end
	if hasTag(item.tags, "Deprecated") then
		out.tags = { 1 }
	end
	local edit = item.textEdit
	if edit then
		local range = lspRange(text, starts, edit.replace)
		out.textEdit = { newText = edit.newText, range = range }
		-- an edit that starts before the typed word (over the dot, over `/`): the editor filters on the replaced text, so the
		-- filter text has to carry that lead too
		local lineStart = starts[cursor.line]
		if lineStart then
			local startOffset = lineStart + edit.replace.start.character - 1
			local cursorOffset = lineStart + cursor.character - 1
			local replaced = string.sub(text, startOffset, cursorOffset - 1)
			local typed = string.match(replaced, "[%w_]*$") or ""
			local lead = string.sub(replaced, 1, #replaced - #typed)
			if lead ~= "" and edit.newText ~= item.label then
				out.filterText = lead .. item.label
			end
		end
	elseif hasTag(item.tags, "AddParens") then
		-- Studio's AddParens / PutCursorInParens: accepting a function writes the call parentheses
		out.insertTextFormat = 2
		out.insertText = item.label .. (hasTag(item.tags, "PutCursorInParens") and "($1)$0" or "()$0")
	end
	return out
end

function Convert.items(items, text, starts, cursor)
	local out = {}
	for _, item in items do
		local ok, converted = pcall(Convert.item, item, text, starts, cursor)
		if ok then
			out[#out + 1] = converted
		end
	end
	return out
end

--- Checker diagnostics (Studio shape) -> LSP diagnostics.
function Convert.diagnostics(list, text, starts)
	local out = {}
	for _, diagnostic in list do
		local ok, converted = pcall(function()
			return {
				range = lspRange(text, starts, diagnostic.range),
				severity = diagnostic.severity or 2,
				code = diagnostic.code,
				source = "Linter",
				data = diagnostic.data, -- { suppress = name }: the proxy uses it to hide luau-lsp's false "not found" for a moved instance
				message = diagnostic.message,
			}
		end)
		if ok then
			out[#out + 1] = converted
		end
	end
	return out
end

return Convert
