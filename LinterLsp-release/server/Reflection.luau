--[[
	Reflection: a ReflectionService stand-in for the class catalog, since there is no Studio here.

	  1. `data/reflection.json`, a cached dump of a real Studio's ReflectionService (properties, methods, events with
	     their types; produced by scripts/DumpReflection.luau through the Studio MCP) - the full answer.
	  2. Lune's bundled Roblox API database - properties only (no methods or events, no Instance-typed members beyond
	     "Instance"). luau-lsp's own definitions cover what is missing here, and the proxy merges the two.

	Both answer exactly the calls Builtin/ClassCatalog makes: GetClass, GetClasses, GetPropertiesOfClass,
	GetMethodsOfClass, GetEventsOfClass, with the shapes a live Studio returns (ReflectionType is a TABLE).
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Reflection = {}

local SCRIPT_TYPES = {
	Bool = { "boolean", "bool" },
	String = { "string", "string" },
	BinaryString = { "string", "BinaryString" },
	Content = { "Content", "Content" },
	ContentId = { "string", "ContentId" },
	Int32 = { "number", "int" },
	Int64 = { "number", "int64" },
	Float32 = { "number", "float" },
	Float64 = { "number", "double" },
}

--- Lune database datatype text -> a ReflectionType table.
local function reflectionType(datatype)
	if type(datatype) ~= "string" then
		return { ScriptType = "any", EngineType = "Variant" }
	end
	local enumName = string.match(datatype, "^Enum%.(.+)$")
	if enumName then
		return { ScriptType = "EnumItem", EngineType = "Enum", EnumType = enumName }
	end
	if datatype == "Ref" then
		return { ScriptType = "Instance", EngineType = "Instance", InstanceType = "Instance" }
	end
	local known = SCRIPT_TYPES[datatype]
	if known then
		return { ScriptType = known[1], EngineType = known[2] }
	end
	return { ScriptType = datatype, EngineType = datatype }
end
Reflection.reflectionType = reflectionType

local function hasTag(tags, name)
	return table.find(tags, name) ~= nil
end

--- Properties of a class and its ancestors from Lune's database, as ReflectionService descriptors.
local function databaseProperties(db, className)
	local out, seen = {}, {}
	local node, hops = db:GetClass(className), 0
	while node and hops < 40 do
		for name, prop in node.Properties do
			if not seen[name] and prop.Scriptability ~= "None" and not hasTag(prop.Tags, "NotScriptable") and not hasTag(prop.Tags, "Hidden") then
				seen[name] = true
				local display = { Category = "Data" }
				if hasTag(prop.Tags, "Deprecated") then
					display.DeprecationMessage = "Deprecated"
				end
				out[#out + 1] = {
					Name = name,
					Owner = node.Name,
					Type = reflectionType(prop.Datatype),
					Display = display,
					Permits = { prop.Scriptability == "Read" and "Read" or "Read", prop.Scriptability == "ReadWrite" and "Write" or nil },
				}
			end
		end
		local parent = node.Superclass
		node = parent and db:GetClass(parent) or nil
		hops += 1
	end
	return out
end

--- The Lune-database stand-in (properties only).
function Reflection.fromDatabase()
	local ok, db = pcall(roblox.getReflectionDatabase)
	if not ok or not db then
		return nil
	end
	local service = {}
	function service:GetClasses()
		local out = {}
		for _, name in db:GetClassNames() do
			local class = db:GetClass(name)
			out[#out + 1] = { Name = name, Superclass = class and class.Superclass or nil }
		end
		return out
	end
	function service:GetClass(name)
		return db:GetClass(name) and { Name = name } or nil
	end
	function service:GetPropertiesOfClass(name)
		return db:GetClass(name) and databaseProperties(db, name) or nil
	end
	function service:GetMethodsOfClass(name)
		return db:GetClass(name) and {} or nil
	end
	function service:GetEventsOfClass(name)
		return db:GetClass(name) and {} or nil
	end
	return service
end

--- A cached Studio dump: { version = 1, classes = { Part = { properties = {...}, methods = {...}, events = {...} } } }.
function Reflection.fromDump(data)
	if type(data) ~= "table" or type(data.classes) ~= "table" then
		return nil
	end
	local classes = data.classes
	local service = {}
	function service:GetClasses()
		local out = {}
		for name, class in classes do
			out[#out + 1] = { Name = name, Superclass = class.superclass }
		end
		return out
	end
	function service:GetClass(name)
		return classes[name] and { Name = name } or nil
	end
	function service:GetPropertiesOfClass(name)
		return classes[name] and (classes[name].properties or {}) or nil
	end
	function service:GetMethodsOfClass(name)
		return classes[name] and (classes[name].methods or {}) or nil
	end
	function service:GetEventsOfClass(name)
		return classes[name] and (classes[name].events or {}) or nil
	end
	return service
end

--[[
	The cached dump is about 10 MB of JSON and decoding it takes ~400 ms - most of the server's start-up. Nothing needs it until a
	completion asks for the members of a class, so it is read and decoded on the first such question (or by `preload`, which the server
	calls when it is otherwise idle). A dump that cannot be read or is malformed falls back to Lune's database, the same fallback
	`load` always had, just discovered later.
]]
function Reflection.lazyDump(path)
	local real
	local function ensure()
		if real then
			return real
		end
		local okRead, text = pcall(fs.readFile, path)
		if okRead then
			local okDecode, data = pcall(serde.decode, "json", text)
			real = okDecode and Reflection.fromDump(data) or nil
		end
		real = real or Reflection.fromDatabase()
		if not real then
			-- neither source works: answer "no such class" to everything instead of failing
			real = {
				GetClasses = function()
					return {}
				end,
				GetClass = function()
					return nil
				end,
				GetPropertiesOfClass = function()
					return nil
				end,
				GetMethodsOfClass = function()
					return nil
				end,
				GetEventsOfClass = function()
					return nil
				end,
			}
		end
		return real
	end
	local service = {}
	function service:GetClasses()
		return ensure():GetClasses()
	end
	function service:GetClass(name)
		return ensure():GetClass(name)
	end
	function service:GetPropertiesOfClass(name)
		return ensure():GetPropertiesOfClass(name)
	end
	function service:GetMethodsOfClass(name)
		return ensure():GetMethodsOfClass(name)
	end
	function service:GetEventsOfClass(name)
		return ensure():GetEventsOfClass(name)
	end
	service.preload = ensure
	function service.isLoaded()
		return real ~= nil
	end
	return service
end

--- Loads `root/data/reflection.json` when present and valid; otherwise the Lune database.
--- Returns service, sourceName ("dump" | "lune" | "none").
function Reflection.load(root)
	local path = root .. "/data/reflection.json"
	if fs.isFile(path) then
		return Reflection.lazyDump(path), "dump"
	end
	local service = Reflection.fromDatabase()
	if service then
		return service, "lune"
	end
	return nil, "none"
end

return Reflection
