--[[
	Json: the encoder for outgoing messages. serde's encoder writes an empty Lua table as `{}`, but LSP wants `[]` for
	empty lists (`items`, `diagnostics`), so this one decides: an empty table is an array unless made with Json.object().
	Decoding stays with serde.
]]

local Json = {}

local OBJECT = {}
--- An empty table that must be written as `{}`.
function Json.object(fields)
	return setmetatable(fields or {}, OBJECT)
end

local ESCAPES = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\b"] = "\\b",
	["\f"] = "\\f",
}

local function escape(text)
	return '"'
		.. string.gsub(text, '[%c"\\]', function(char)
			return ESCAPES[char] or string.format("\\u%04x", string.byte(char))
		end)
		.. '"'
end

local encode

local function encodeTable(value, out, depth)
	if depth > 60 then
		out[#out + 1] = "null"
		return
	end
	local isObject = getmetatable(value) == OBJECT
	local count = #value
	if not isObject and count > 0 then
		out[#out + 1] = "["
		for index = 1, count do
			if index > 1 then
				out[#out + 1] = ","
			end
			encode(value[index], out, depth + 1)
		end
		out[#out + 1] = "]"
		return
	end
	if not isObject and next(value) == nil then
		out[#out + 1] = "[]"
		return
	end
	out[#out + 1] = "{"
	local first = true
	for key, item in value do
		if item ~= nil then
			if not first then
				out[#out + 1] = ","
			end
			first = false
			out[#out + 1] = escape(tostring(key))
			out[#out + 1] = ":"
			encode(item, out, depth + 1)
		end
	end
	out[#out + 1] = "}"
end

encode = function(value, out, depth)
	local kind = type(value)
	if value == nil then
		out[#out + 1] = "null"
	elseif kind == "boolean" then
		out[#out + 1] = value and "true" or "false"
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			out[#out + 1] = "null"
		elseif value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			out[#out + 1] = string.format("%d", value)
		else
			out[#out + 1] = string.format("%.17g", value)
		end
	elseif kind == "string" then
		out[#out + 1] = escape(value)
	elseif kind == "table" then
		encodeTable(value, out, depth)
	else
		out[#out + 1] = "null"
	end
end

function Json.encode(value)
	local out = {}
	encode(value, out, 0)
	return table.concat(out)
end

--- A JSON-RPC message; a successful response with no result gets `"result": null` (required by the spec).
function Json.encodeMessage(message)
	if message.id ~= nil and message.error == nil and message.result == nil and message.method == nil then
		message = table.clone(message)
		message.result = Json.null
	end
	return Json.encode(message)
end

Json.null = setmetatable({}, { __tostring = function() return "null" end })
local baseEncode = encode
encode = function(value, out, depth)
	if value == Json.null then
		out[#out + 1] = "null"
		return
	end
	baseEncode(value, out, depth)
end

return Json
