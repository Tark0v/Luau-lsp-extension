--[[
	Signature: renders function AST nodes as `(a: number, b) -> string` for completion details.
]]

local Signature = {}

--- opts.dropSelf: omit a leading implicit/explicit `self` (the call is written with `:`)
function Signature.params(fnNode, opts)
	local dropSelf = opts and opts.dropSelf
	local parts = {}
	for index, param in fnNode.params do
		local isSelf = index == 1 and (param.implicit or param.name == "self")
		if not (dropSelf and isSelf) then
			parts[#parts + 1] = param.type and `{param.name}: {param.type}` or param.name
		end
	end
	if fnNode.vararg then
		parts[#parts + 1] = "..."
	end
	return table.concat(parts, ", ")
end

function Signature.render(name, fnNode, opts)
	local text = `{name or ""}({Signature.params(fnNode, opts)})`
	if fnNode.ret then
		text ..= ` -> {fnNode.ret}`
	end
	return text
end

--- True when the function expects `self` first (declared with `:` or an explicit `self` param).
function Signature.takesSelf(fnNode)
	local first = fnNode.params[1]
	return first ~= nil and (first.implicit == true or first.name == "self")
end

return Signature
