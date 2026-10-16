--[[
	Receives a ReflectionService dump from a running Roblox Studio and writes data/reflection.json.
	  1. lune run scripts/receive-dump [port]          (default 38211, listens on localhost only)
	  2. in Studio (HTTP requests enabled for the place): run scripts/DumpReflection.luau with the same port
	     (for example through the Studio MCP `execute_luau`, Edit datamodel)
	The server exits after Studio sends the final message. Nothing else is accepted.
]]

local net = require("@lune/net")
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")
local Json = require("../server/Json")

local port = tonumber(process.args[1]) or 38211
local classes, count = {}, 0
local handle

handle = net.serve(port, function(request)
	if request.method ~= "POST" then
		return { status = 405, body = "POST only" }
	end
	local ok, body = pcall(serde.decode, "json", request.body)
	if not ok or type(body) ~= "table" then
		return { status = 400, body = "bad json" }
	end
	if request.path == "/chunk" and type(body.classes) == "table" then
		for name, class in body.classes do
			classes[name] = class
			count += 1
		end
		return { status = 200, body = "ok" }
	elseif request.path == "/done" then
		local out = { version = 1, source = body.source or "studio", classes = classes }
		-- the server's encoder: empty member lists stay `[]`
		if not fs.isDir("data") then
			fs.writeDir("data")
		end
		fs.writeFile("data/reflection.json", Json.encode(out))
		print(`wrote data/reflection.json ({count} classes)`)
		task.defer(function()
			handle:stop()
		end)
		return { status = 200, body = "written" }
	end
	return { status = 404, body = "not found" }
end)
print(`waiting for a Studio dump on http://localhost:{port}`)
