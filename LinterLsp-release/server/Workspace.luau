--[[
	Workspace: turns the folder VS Code has open into a DataModel (Lune's roblox library) the engine can read, the way Studio
	hands the plugin a live one.

	Sources, first that applies:
	  1. a Rojo project file (`default.project.json`, or the configured one)   - the tree, `$path`, `$className`
	  2. `sourcemap.json` (rojo / luau-lsp)                                    - the instance tree with file paths
	  3. the folder itself, under ServerScriptService                          - when neither exists

	File rules (Rojo's): `X.luau` ModuleScript, `X.server.luau` Script, `X.client.luau` LocalScript, a folder with an `init` file
	becomes that script and keeps its children, other folders are Folders, `X.model.json` a small instance tree, `X.txt` a StringValue.
	Nothing here writes to disk. Bounded by `maxFiles`.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Uri = require("./Uri")

local Workspace = {}
Workspace.__index = Workspace

local SKIP_DIRS = { [".git"] = true, node_modules = true, [".vscode"] = true, [".idea"] = true }
local PROJECT_FILE = "default.project.json"
local MAX_FILES = 20000

local SCRIPT_SUFFIXES = {
	{ ".server.luau", "Script" },
	{ ".server.lua", "Script" },
	{ ".client.luau", "LocalScript" },
	{ ".client.lua", "LocalScript" },
	{ ".luau", "ModuleScript" },
	{ ".lua", "ModuleScript" },
}

--- "Foo.server.luau" -> "Foo", "Script"; nil for anything that is not a script file.
local function classify(fileName)
	for _, entry in SCRIPT_SUFFIXES do
		local suffix = entry[1]
		if #fileName > #suffix and string.sub(fileName, -#suffix) == suffix then
			return string.sub(fileName, 1, #fileName - #suffix), entry[2]
		end
	end
	return nil
end

--- Rojo reads project files leniently (comments and trailing commas are fine); a strict decoder would reject files Rojo accepts.
--- Removes // and /* */ comments and commas before } or ], leaving string contents alone.
local function relaxJson(text)
	local out, n, i, length = {}, 0, 1, #text
	local function push(piece)
		n += 1
		out[n] = piece
	end
	while i <= length do
		local c = string.sub(text, i, i)
		if c == '"' then
			local j = i + 1
			while j <= length do
				local d = string.sub(text, j, j)
				if d == "\\" then
					j += 2
				elseif d == '"' then
					break
				else
					j += 1
				end
			end
			push(string.sub(text, i, j))
			i = j + 1
		elseif c == "/" and string.sub(text, i + 1, i + 1) == "/" then
			local stop = string.find(text, "\n", i, true)
			i = stop or length + 1
		elseif c == "/" and string.sub(text, i + 1, i + 1) == "*" then
			local _, stop = string.find(text, "*/", i + 2, true)
			i = (stop or length) + 1
		elseif c == "," then
			local after = string.match(text, "^[%s]*([%]}])", i + 1)
			-- a comment between the comma and the bracket is rare; the comment pass above has not run on it yet, so look past one
			if not after then
				after = string.match(text, "^%s*//[^\n]*\n%s*([%]}])", i + 1)
			end
			if not after then
				push(c)
			end
			i += 1
		else
			push(c)
			i += 1
		end
	end
	return table.concat(out)
end
Workspace.relaxJson = relaxJson

local function readJson(path)
	local ok, text = pcall(fs.readFile, path)
	if not ok then
		return nil
	end
	local decoded, value = pcall(serde.decode, "json", text)
	if decoded then
		return value
	end
	decoded, value = pcall(serde.decode, "json", relaxJson(text))
	return decoded and value or nil
end

-- Services scripts parent things into. Rojo only creates the ones a project maps, but the running game has them all, so the
-- in-memory model (never written to disk) has them too: otherwise `x.Parent = game.ReplicatedStorage` has nowhere to go.
local STANDARD_SERVICES = {
	"Workspace", "ReplicatedStorage", "ServerStorage", "ServerScriptService", "ReplicatedFirst", "StarterGui", "StarterPack",
	"StarterPlayer", "Players", "Lighting", "SoundService", "Teams",
}

local function newInstance(className)
	local ok, inst = pcall(roblox.Instance.new, className)
	return ok and inst or nil
end

function Workspace.new(options)
	return setmetatable({
		root = string.gsub(options.root, "\\", "/"),
		projectFile = options.projectFile, -- optional path relative to root
		maxFiles = options.maxFiles or MAX_FILES,
		windows = options.windows == true,
		log = options.log or function() end,
		game = nil,
		files = 0,
		truncated = false,
		byPath = {}, -- key(path) -> instance for every script file
		dirs = {}, -- key(path) -> container instance for every mapped directory
		pathOf = {}, -- instance -> path
		mode = "none",
	}, Workspace)
end

function Workspace:_key(path)
	return Uri.key(path, self.windows)
end

function Workspace:_remember(inst, path)
	self.byPath[self:_key(path)] = inst
	self.pathOf[inst] = path
end

function Workspace:_read(path)
	local ok, text = pcall(fs.readFile, path)
	return ok and text or nil
end

function Workspace:_script(className, name, path)
	local inst = newInstance(className)
	if not inst then
		return nil
	end
	inst.Name = name
	inst.Source = self:_read(path) or ""
	self:_remember(inst, path)
	return inst
end

--- Builds the instance for one directory following Rojo's rules. `className` overrides a plain Folder.
function Workspace:_fromDir(dir, name, className)
	if self.files >= self.maxFiles then
		self.truncated = true
		return nil
	end
	local entries = {}
	local okList, list = pcall(fs.readDir, dir)
	if okList then
		entries = list
	end
	table.sort(entries)

	local container
	for _, initName in { "init.server.luau", "init.client.luau", "init.luau", "init.server.lua", "init.client.lua", "init.lua" } do
		if table.find(entries, initName) then
			local _, class = classify(initName)
			container = self:_script(class, name, dir .. "/" .. initName)
			self.files += 1
			break
		end
	end
	if not container then
		container = newInstance(className or "Folder") or newInstance("Folder")
		container.Name = name
	end
	self.dirs[self:_key(dir)] = container
	self.pathOf[container] = dir

	for _, entry in entries do
		local path = dir .. "/" .. entry
		if self.files >= self.maxFiles then
			self.truncated = true
			break
		end
		if fs.isDir(path) then
			if not SKIP_DIRS[entry] then
				local child = self:_fromDir(path, entry)
				if child then
					child.Parent = container
				end
			end
		elseif not string.match(entry, "^init%.") then
			local child = self:_fromFile(path, entry)
			if child then
				child.Parent = container
			end
		end
	end
	return container
end

local function modelFromJson(node, name)
	if type(node) ~= "table" or type(node.ClassName) ~= "string" then
		return nil
	end
	local inst = newInstance(node.ClassName)
	if not inst then
		return nil
	end
	inst.Name = node.Name or name or node.ClassName
	for _, child in node.Children or {} do
		local made = modelFromJson(child)
		if made then
			made.Parent = inst
		end
	end
	return inst
end

function Workspace:_fromFile(path, fileName)
	local name, class = classify(fileName)
	if name then
		self.files += 1
		return self:_script(class, name, path)
	end
	local modelName = string.match(fileName, "^(.+)%.model%.json$")
	if modelName then
		local inst = modelFromJson(readJson(path), modelName)
		if inst then
			inst.Name = modelName
			self.files += 1
		end
		return inst
	end
	local textName = string.match(fileName, "^(.+)%.txt$")
	if textName then
		local inst = newInstance("StringValue")
		inst.Name = textName
		inst.Value = self:_read(path) or ""
		self.files += 1
		return inst
	end
	return nil
end

--- One node of a Rojo project tree. `base` is the project file's directory.
function Workspace:_fromProjectNode(node, name, base)
	local path = node["$path"]
	if type(path) == "table" then
		path = path.optional
	end
	local className = node["$className"]
	local inst
	if type(path) == "string" then
		local full = base .. "/" .. path
		if fs.isDir(full) then
			inst = self:_fromDir(full, name, className)
		elseif fs.isFile(full) then
			inst = self:_fromFile(full, (string.match(full, "[^/]+$")))
			if inst then
				inst.Name = name
			end
		end
	end
	if not inst then
		inst = newInstance(className or "Folder") or newInstance("Folder")
		inst.Name = name
	end
	for key, child in node do
		if string.sub(key, 1, 1) ~= "$" and type(child) == "table" then
			local childInst = self:_fromProjectNode(child, key, base)
			if childInst then
				childInst.Parent = inst
			end
		end
	end
	return inst
end

--- A service that already lives under the DataModel: its children come from the node and its `$path`.
function Workspace:_fillService(service, node, key, base)
	local path = node["$path"]
	if type(path) == "string" then
		local full = base .. "/" .. path
		if fs.isDir(full) then
			local built = self:_fromDir(full, key)
			if built then
				for _, child in built:GetChildren() do
					child.Parent = service
				end
				self.dirs[self:_key(full)] = service
			end
		end
	end
	for childKey, child in node do
		if string.sub(childKey, 1, 1) ~= "$" and type(child) == "table" then
			local inst = self:_fromProjectNode(child, childKey, base)
			if inst then
				inst.Parent = service
			end
		end
	end
	return service
end

function Workspace:_fromSourcemap(map, parent)
	local inst = newInstance(map.className or "Folder")
	if not inst then
		return nil
	end
	inst.Name = map.name or inst.ClassName
	local file
	for _, candidate in map.filePaths or {} do
		if classify(string.match(candidate, "[^/\\]+$") or "") then
			file = candidate
			break
		end
	end
	if file then
		local full = string.match(file, "^%a:") or string.sub(file, 1, 1) == "/" and file or (self.root .. "/" .. file)
		pcall(function()
			inst.Source = self:_read(full) or ""
		end)
		self:_remember(inst, full)
		self.files += 1
	end
	for _, child in map.children or {} do
		if self.files >= self.maxFiles then
			self.truncated = true
			break
		end
		local made = self:_fromSourcemap(child)
		if made then
			made.Parent = inst
		end
	end
	return inst
end

--- Builds the DataModel. Returns it. Never throws: a broken project file falls back to the folder layout.
function Workspace:load()
	self.files, self.truncated = 0, false
	self.byPath, self.dirs, self.pathOf = {}, {}, {}
	local game = roblox.Instance.new("DataModel")
	self.game = game

	local ok, err = pcall(function()
		local projectPath
		if self.projectFile then
			projectPath = self.root .. "/" .. self.projectFile
		elseif fs.isFile(self.root .. "/" .. PROJECT_FILE) then
			projectPath = self.root .. "/" .. PROJECT_FILE
		end
		local project = projectPath and readJson(projectPath)
		if project and type(project.tree) == "table" then
			self.mode = "project"
			self.projectPath = projectPath
			local base = string.match(projectPath, "^(.*)/[^/]+$") or self.root
			-- the tree's root is the DataModel itself: its children are services (which already exist) or plain instances
			for key, child in project.tree do
				if string.sub(key, 1, 1) ~= "$" and type(child) == "table" then
					local ok2, service = pcall(game.GetService, game, child["$className"] or key)
					if ok2 and service then
						self:_fillService(service, child, key, base)
					else
						local inst = self:_fromProjectNode(child, key, base)
						if inst then
							inst.Parent = game
						end
					end
				end
			end
			return
		end
		local mapPath = self.root .. "/sourcemap.json"
		local map = fs.isFile(mapPath) and readJson(mapPath)
		if map and type(map) == "table" then
			self.mode = "sourcemap"
			local rootInst = self:_fromSourcemap(map)
			if rootInst then
				for _, child in rootInst:GetChildren() do
					local ok2, service = pcall(game.GetService, game, child.ClassName)
					if ok2 and service then
						for _, grandchild in child:GetChildren() do
							grandchild.Parent = service
						end
					else
						child.Parent = game
					end
				end
			end
			return
		end
		self.mode = "folder"
		local ss = game:GetService("ServerScriptService")
		local folderName = string.match(self.root, "[^/]+$") or "workspace"
		local built = self:_fromDir(self.root, folderName)
		if built then
			built.Parent = ss
		end
	end)
	if not ok then
		self.log("workspace load failed: " .. tostring(err))
	end
	for _, name in STANDARD_SERVICES do
		pcall(game.GetService, game, name)
	end
	return game
end

local function serviceOf(game, inst)
	local node = inst
	while node and node.Parent ~= game do
		node = node.Parent
	end
	return node
end
Workspace.serviceOf = serviceOf

--- A file changed on disk. Returns what the caller must tell the engine, a list of
--- { op = "changed" | "added" | "removed", inst = Instance } or { { op = "rebuild" } } when the tree cannot be patched
--- (project file, init files, whole directories). kind: "created" | "changed" | "deleted".
function Workspace:update(path, kind)
	path = string.gsub(path, "\\", "/")
	local key = self:_key(path)
	local fileName = string.match(path, "[^/]+$") or path
	if string.match(fileName, "%.project%.json$") or fileName == "sourcemap.json" or string.match(fileName, "^init%.") then
		return { { op = "rebuild" } }
	end
	local inst = self.byPath[key]
	if kind == "changed" then
		if inst then
			local text = self:_read(path)
			if text then
				inst.Source = text
				return { { op = "changed", inst = inst } }
			end
		end
		return {}
	elseif kind == "deleted" then
		if inst then
			self.byPath[key], self.pathOf[inst] = nil, nil
			return { { op = "removed", inst = inst } }
		end
		if self.dirs[key] then
			return { { op = "rebuild" } }
		end
		return {}
	elseif kind == "created" then
		if inst then
			return {}
		end
		local parentDir = string.match(path, "^(.*)/[^/]+$")
		local parent = parentDir and self.dirs[self:_key(parentDir)]
		if not parent then
			return { { op = "rebuild" } }
		end
		local child
		if fs.isDir(path) then
			if SKIP_DIRS[fileName] then
				return {}
			end
			child = self:_fromDir(path, fileName)
		else
			child = self:_fromFile(path, fileName)
		end
		if child then
			child.Parent = parent
			return { { op = "added", inst = child } }
		end
	end
	return {}
end

--- A document that is not part of the mapped tree (an untitled or out-of-project file): gets a script of its own so it can still be completed.
function Workspace:ensureLoose(path, text)
	local key = self:_key(path)
	local inst = self.byPath[key]
	if inst then
		return inst, false
	end
	local fileName = string.match(path, "[^/\\]+$") or "Untitled"
	local name, class = classify(fileName)
	inst = newInstance(class or "ModuleScript")
	inst.Name = name or fileName
	inst.Source = text or ""
	local storage = self.game:GetService("ServerStorage")
	local folder = storage:FindFirstChild("LinterLoose")
	if not folder then
		folder = newInstance("Folder")
		folder.Name = "LinterLoose"
		folder.Parent = storage
	end
	inst.Parent = folder
	self:_remember(inst, path)
	return inst, true
end

return Workspace
