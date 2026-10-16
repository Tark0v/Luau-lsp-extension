--[[
	Arguments: what to tell someone who is writing the arguments of a call to a function Linter can see.

	  f(|           the parameter being written ("amount: number", argument 1 of 3) as a row that changes nothing when accepted
	  f(a, mo|      the same for argument 2, plus the strings its type allows ("Fast" | "Slow") and the enum it wants
	  f(a, "|       the strings its type allows (the string completion in Engine adds the lookup keys)

	The function comes from the interpreter (user code, hand-written types, `--@param`), so this works on modules Studio
	cannot type: a table of modules built in a loop, a custom `require`, a framework's registry.
]]

local Values = require(script.Parent.Parent.Interp.Values)

local Arguments = {}

local force = Values.force

local MAX_STRINGS = 40
local MAX_TEXT = 90

local function clip(text)
	if #text <= MAX_TEXT then
		return text
	end
	return string.sub(text, 1, MAX_TEXT - 3) .. "..."
end

--- The function a callee value stands for (the first one of a union that has parameters we can read), or nil.
local function pickFunction(callee)
	callee = force(callee)
	if callee.k == "union" then
		for _, member in callee.members do
			local candidate = force(member)
			if candidate.k == "function" and (candidate.fn or candidate.typeNode) then
				return candidate
			end
		end
		return nil
	end
	if callee.k == "function" and (callee.fn or callee.typeNode) then
		return callee
	end
	return nil
end

--- { fnV, params = { { name, text, node, isSelf } ... }, first, vararg } or nil. `first` is the index of the first parameter the
--- caller writes (2 when the call is `obj:method(` and the function takes `self`).
function Arguments.describe(callee, methodCall)
	local fnV = pickFunction(callee)
	if not fnV then
		return nil
	end
	local params = {}
	local vararg = false
	if fnV.fn then
		local tags = fnV.tags
		for index, param in fnV.fn.params do
			params[index] = {
				name = param.name,
				text = param.type or (tags and tags.params and tags.params[param.name]),
				isSelf = index == 1 and (param.implicit == true or param.name == "self"),
			}
		end
		vararg = fnV.fn.vararg == true
	else
		for index, param in fnV.typeNode.params do
			params[index] = {
				name = param.name,
				text = param.type and param.type.text,
				node = param.type,
				isSelf = index == 1 and param.name == "self",
				vararg = param.vararg == true,
			}
			vararg = vararg or param.vararg == true
		end
	end
	-- `obj:method(x)` passes obj as the first parameter, whatever it is called
	local first = (methodCall and params[1]) and 2 or 1
	return { fnV = fnV, params = params, first = first, vararg = vararg }
end

--- The parameter that argument number `argIndex` (1-based, as the caller counts) goes to, or nil.
function Arguments.parameter(info, argIndex)
	return info.params[argIndex + info.first - 1]
end

--- `name(a: number, b: string)` as the caller sees it.
function Arguments.signature(info, name)
	local parts = {}
	for index = info.first, #info.params do
		local param = info.params[index]
		if param.name and param.text then
			parts[#parts + 1] = `{param.name}: {param.text}`
		else
			parts[#parts + 1] = param.name or param.text or "any"
		end
	end
	if info.vararg then
		parts[#parts + 1] = "..."
	end
	return `{name}({table.concat(parts, ", ")})`
end

local function quote(text)
	return '"' .. string.gsub(string.gsub(string.gsub(text, "\\", "\\\\"), '"', '\\"'), "\n", "\\n") .. '"'
end

--- The strings a parameter's type allows (`"Fast" | "Slow"`), for completing inside quotes.
function Arguments.strings(spec)
	local out = {}
	for _, text in spec and spec.strings or {} do
		if #out < MAX_STRINGS and #text > 0 and #text <= 120 and not string.find(text, "%c") then
			out[#out + 1] = text
		end
	end
	return out
end

--- Items for `f(|` / `f(a, na|`. `spec` (from TypeResolver:argumentSpec) may be nil. Nothing here inserts anything the person did not
--- choose: the parameter row replaces what was typed with itself.
function Arguments.items(items, ctx, info, param, spec)
	local out = {}
	local position, prefix = ctx.position, ctx.prefix
	local function edit(newText)
		return {
			newText = newText,
			replace = {
				start = { line = position.line, character = position.character - #prefix },
				["end"] = { line = position.line, character = position.character },
			},
		}
	end

	local visible = #info.params - info.first + 1
	local number = ctx.argIndex
	local signature = Arguments.signature(info, ctx.name or "f")
	local described = param.name and (param.text and `{param.name}: {param.text}` or param.name) or param.text or "any"
	local note = `Argument {number} of {visible}: {described}`
	if spec and spec.nilOk then
		note ..= "\n\nMay be nil."
	end
	-- With nothing typed yet the row is the selected one, so the documentation panel opens on the signature the moment the list does.
	-- Once a name is being typed it stays an ordinary row: Tab must still complete what the person is typing.
	local row = items:fromArgument(clip(described), "Variable", clip(`argument {number} of {visible}`), signature, note, edit(prefix), prefix == "")
	out[#out + 1] = row

	if spec then
		for _, text in Arguments.strings(spec) do
			out[#out + 1] = items:fromArgument(text, "EnumMember", clip(`{quote(text)}  ({described})`), signature, note, edit(quote(text)))
		end
		for _, enum in spec.enums do
			out[#out + 1] = items:fromArgument(`Enum.{enum}`, "Enum", clip(`Enum.{enum}  ({described})`), signature, note .. "\n\nContinue with a dot to pick the item.", edit(`Enum.{enum}`))
		end
	end
	return out
end

return Arguments
