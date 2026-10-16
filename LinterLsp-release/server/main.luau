--[[
	Linter language server entry point.  Run from the project root:  lune run server/main
	Transport: one JSON-RPC message per line on stdin / stdout (the proxy in bridge/ adds the LSP framing). Logs go to stderr.
]]

local process = require("@lune/process")
local stdio = require("@lune/stdio")
local serde = require("@lune/serde")

local HostInfo = require("./HostInfo")
local Loader = require("./Loader")
local Server = require("./Server")
local Json = require("./Json")

local root = process.env.LINTER_ROOT or "."
local host = HostInfo.detect()

local function log(text)
	stdio.ewrite("[linter-lsp] " .. text .. "\n")
end

local problems = HostInfo.preflight(root)
if #problems > 0 then
	for _, problem in problems do
		log("preflight: " .. problem)
	end
	process.exit(2)
end

local function send(message)
	local ok, encoded = pcall(Json.encodeMessage, message)
	if not ok then
		log("could not encode a message: " .. tostring(encoded))
		return
	end
	stdio.write(encoded .. "\n")
end

local server = Server.new({
	loader = Loader.new(root .. "/core"),
	root = root,
	send = send,
	host = host,
	log = log,
})

log(`ready ({host.os}/{host.arch})`)
while server.exitCode == nil do
	local line = stdio.readLine()
	if line == nil or line == "" then
		break -- stdin closed
	end
	line = string.gsub(line, "[\r\n]+$", "")
	if line ~= "" then
		local ok, message = pcall(serde.decode, "json", line)
		if ok then
			server:handle(message)
		else
			log("bad json line ignored")
		end
	end
end
process.exit(server.exitCode or 0)
