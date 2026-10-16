--[[
	HostInfo: what machine this is, and whether it is fit to run the server. Everything OS-specific asks here,
	so tests and runtime agree on one answer.
]]

local process = require("@lune/process")
local fs = require("@lune/fs")

local HostInfo = {}

--- os: "linux" | "windows" | "macos" | "other"; arch: "x86_64" | "aarch64" | ...; sep: path separator.
function HostInfo.detect()
	local os = process.os
	if os ~= "linux" and os ~= "windows" and os ~= "macos" then
		os = "other"
	end
	local env = process.env
	return {
		os = os,
		arch = process.arch,
		sep = os == "windows" and "\\" or "/",
		-- Studio-under-Wine setups (Vinegar, Sober-like wrappers) leave these behind
		wine = env.WINEPREFIX ~= nil or env.WINELOADER ~= nil,
		home = env.HOME or env.USERPROFILE,
	}
end

--- Is a test tagged with `only` (nil = every OS, a string, or a list) meant for this host?
function HostInfo.matches(host, only)
	if only == nil then
		return true
	end
	if type(only) == "string" then
		return only == host.os
	end
	return table.find(only, host.os) ~= nil
end

--- Problems that would make running unsafe. Returns a list of strings (empty = fine).
--- root: the directory holding `core/`.
function HostInfo.preflight(root)
	local problems = {}
	if not fs.isDir(root .. "/core") then
		problems[#problems + 1] = `core modules not found under {root}/core`
	end
	for _, layer in { "Core", "Language", "Builtin", "Interp", "Project", "Completion" } do
		if fs.isDir(root .. "/core") and not fs.isDir(root .. "/core/" .. layer) then
			problems[#problems + 1] = `missing core layer {layer}`
		end
	end
	return problems
end

return HostInfo
