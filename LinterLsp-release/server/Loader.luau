--[[
	Loader: runs the core modules, which are written Roblox-style (`require(script.Parent.Foo)`), under Lune.
	Builds an instance-like tree over a directory and loads each file with luau.load so a module gets its own
	`script`, `require` and `task`.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local lunetask = require("@lune/task")

local Loader = {}

local Node = {}
Node.__index = function(self, key)
	return rawget(self, "_children")[key]
end

local function stripExtension(name)
	return (string.gsub(name, "%.luau?$", ""))
end

local function build(path, name, parent)
	local node = setmetatable({ Name = name, Parent = parent, _path = path, _children = {}, _isDir = fs.isDir(path) }, Node)
	if node._isDir then
		for _, entry in fs.readDir(path) do
			local childName = stripExtension(entry)
			node._children[childName] = build(path .. "/" .. entry, childName, node)
		end
	end
	return node
end

--- rootPath: the directory of core modules, e.g. "core".
function Loader.new(rootPath)
	local root = build(rootPath, "core", nil)
	local cache = {}

	local requireNode
	local function environmentFor(node)
		return {
			script = node,
			require = requireNode,
			task = lunetask,
			warn = warn,
			print = print,
		}
	end

	requireNode = function(node)
		if getmetatable(node) ~= Node then
			error("Loader can only require core modules")
		end
		local cached = cache[node]
		if cached ~= nil then
			return cached.value
		end
		local source = fs.readFile(node._path)
		local fn = luau.load(source, { debugName = node._path, environment = environmentFor(node) })
		local entry = { value = nil }
		cache[node] = entry
		entry.value = fn()
		return entry.value
	end

	local loader = { root = root }

	--- loader.require("Core/Maid")
	function loader.require(path)
		local node = root
		for part in string.gmatch(path, "[^/]+") do
			node = node._children[part]
			if not node then
				error(`no core module '{path}'`)
			end
		end
		return requireNode(node)
	end

	return loader
end

return Loader
