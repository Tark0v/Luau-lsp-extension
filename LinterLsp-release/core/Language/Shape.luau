--[[
	Shape: a fingerprint of everything in a script EXCEPT what happens inside its function bodies.

	Frameworks decide what to do with a module by looking at what it exports (`module.Reloader = true`, `return { Init = ... }`),
	not at what its functions do. So while you type inside a function the fingerprint stays the same, and the moment you add or
	remove a top-level field, table entry or statement it changes. The plugin uses that to know when what the rest of the project
	passes to your functions has to be learned again.

	Positions, comments and error lists are not part of it: moving code around or adding a blank line changes nothing.
]]

local Shape = {}

local SKIP = { line = true, doc = true, tags = true, errors = true, tokens = true, unterminated = true }
local MAX_DEPTH = 80

local function walk(node, out, depth)
	if type(node) ~= "table" then
		out[#out + 1] = tostring(node)
		return
	end
	if depth > MAX_DEPTH then
		out[#out + 1] = "~"
		return
	end
	if node.k == "Function" then
		out[#out + 1] = "fn("
		for _, param in node.params do
			out[#out + 1] = `{param.name}:{param.type or ""},`
		end
		out[#out + 1] = node.vararg and "...)" or ")"
		return -- the body is exactly what we do not look at
	end
	local keys = {}
	for key in node do
		if not SKIP[key] then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	out[#out + 1] = "{"
	for _, key in keys do
		out[#out + 1] = tostring(key) .. "="
		walk(node[key], out, depth + 1)
		out[#out + 1] = ";"
	end
	out[#out + 1] = "}"
end

--- chunk: a Parser chunk. Returns a string; equal strings mean the same shape.
function Shape.of(chunk)
	local out = {}
	walk(chunk.body, out, 0)
	return table.concat(out)
end

return Shape
