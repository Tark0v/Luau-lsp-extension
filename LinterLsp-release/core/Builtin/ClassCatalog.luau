--[[
	ClassCatalog: members of Roblox classes, sourced from ReflectionService.

	Verified against a live Studio (the shapes the docs leave undefined):
	  * a `ReflectionType` is a table: { EngineType = "bool", ScriptType = "boolean" } with optional
	    EnumType ("Material") and InstanceType ("BasePart"). Void returns have only EngineType = "Void".
	  * descriptors: properties { Name, Type, Owner, Display = { Category, DeprecationMessage? }, Permits },
	    methods { Name, Parameters = { { Name, Type, DefaultValue? } }, ReturnType, CanYield?, Owner },
	    events { Name, Parameters, Owner }
	  * the default (plugin) view includes legacy lowercase aliases (className, getChildren ...) flagged with
	    Display.DeprecationMessage, and plugin-only members (Capabilities, Sandboxed, LinkedSource). Studio
	    does not offer those to game scripts, so deprecated members are skipped here and `opts.security`
	    should describe a game script. An EMPTY SecurityCapabilities is too strict (it hides Workspace.Gravity
	    and friends); a curated game-script set, built by the app, matches what scripts can really use.

	`opts.security` is passed as the `Security` filter; if a call with it fails we retry without.
	`opts.includeDeprecated` keeps deprecated members.

	Entry shape: { name, kind = "Property" | "Method" | "Event", detail, owner, deprecated, yields }
]]

local Log = require(script.Parent.Parent.Core.Log)

local ClassCatalog = {}
ClassCatalog.__index = ClassCatalog

local SCRIPT_TYPES = {
	Object = "any",
	Function = "function",
	Map = "{ [string]: any }",
	EventInstance = "RBXScriptSignal",
	Connection = "RBXScriptConnection",
	["..."] = "...any",
}

local ENGINE_TYPES = {
	Void = "()",
	Variant = "any",
	Tuple = "...any",
	ValueArray = "{any}",
	ValueTable = "{ [string]: any }",
	ValueMap = "{ [string]: any }",
	BinaryString = "string",
	ProtectedString = "string",
}

--- Renders a ReflectionType as Luau type text. Also accepts plain strings.
local function typeName(t)
	if type(t) == "string" then
		return t
	end
	if type(t) ~= "table" then
		return "any"
	end
	local scriptType, engineType = t.ScriptType, t.EngineType
	if scriptType == "Instance" then
		return t.InstanceType or "Instance"
	elseif scriptType == "Instances" then
		return `\{{t.InstanceType or "Instance"}}`
	elseif scriptType == "EnumItem" then
		return t.EnumType and `Enum.{t.EnumType}` or "EnumItem"
	elseif scriptType then
		return SCRIPT_TYPES[scriptType] or scriptType
	elseif engineType then
		return ENGINE_TYPES[engineType] or engineType
	end
	return "any"
end
ClassCatalog.typeName = typeName

local function paramList(parameters)
	local parts = {}
	for _, param in parameters or {} do
		local text = typeName(param.Type)
		if param.DefaultValue ~= nil then
			text ..= "?"
		end
		parts[#parts + 1] = `{param.Name or "_"}: {text}`
	end
	return table.concat(parts, ", ")
end

local function deprecation(descriptor)
	local display = descriptor.Display
	if type(display) == "table" then
		return display.DeprecationMessage
	end
	return nil
end

--- reflectionService may be nil (older Studio); every query then returns nil.
function ClassCatalog.new(reflectionService, opts)
	opts = opts or {}
	return setmetatable({
		_service = reflectionService or nil,
		_security = opts.security,
		_includeDeprecated = opts.includeDeprecated == true,
		_members = {},
		_classes = {},
	}, ClassCatalog)
end

function ClassCatalog:available()
	return self._service ~= nil
end

function ClassCatalog:_fetch(method, className)
	local service = self._service
	local fn = service[method]
	if type(fn) ~= "function" then
		return nil
	end
	if self._security then
		local ok, list = pcall(fn, service, className, { Security = self._security })
		if ok and type(list) == "table" then
			return list
		end
	end
	local ok, list = pcall(fn, service, className)
	if ok and type(list) == "table" then
		return list
	end
	if not ok then
		Log.debug("ReflectionService.%s(%s) failed: %s", method, className, tostring(list))
	end
	return nil
end

--- True when ReflectionService knows the class.
function ClassCatalog:hasClass(className)
	if not self._service or type(className) ~= "string" then
		return false
	end
	local cached = self._classes[className]
	if cached ~= nil then
		return cached
	end
	local ok, result = pcall(self._service.GetClass, self._service, className)
	local known = ok and result ~= nil
	self._classes[className] = known
	return known
end

--- All members of a class (inherited included) or nil when unavailable. Cached per class.
function ClassCatalog:members(className)
	if not self._service or type(className) ~= "string" then
		return nil
	end
	local cached = self._members[className]
	if cached ~= nil then
		return cached or nil
	end

	local properties = self:_fetch("GetPropertiesOfClass", className)
	local methods = self:_fetch("GetMethodsOfClass", className)
	local events = self:_fetch("GetEventsOfClass", className)
	if not (properties or methods or events) then
		self._members[className] = false
		return nil
	end

	local out, seen = {}, {}
	local keepDeprecated = self._includeDeprecated
	local function add(descriptor, entry)
		-- members with empty Permits exist for the engine only (`shap`, `siz`, `Pivot Offset` ...): scripts cannot touch them
		local permits = descriptor.Permits
		if type(permits) == "table" and next(permits) == nil then
			return
		end
		if type(entry.name) ~= "string" or seen[entry.name] then
			return
		end
		if entry.deprecated and not keepDeprecated then
			return
		end
		seen[entry.name] = true
		out[#out + 1] = entry
	end

	for _, p in properties or {} do
		add(p, {
			name = p.Name,
			kind = "Property",
			detail = typeName(p.Type),
			owner = p.Owner,
			deprecated = deprecation(p),
		})
	end
	for _, m in methods or {} do
		local detail = `({paramList(m.Parameters)}) -> {typeName(m.ReturnType)}`
		add(m, {
			name = m.Name,
			kind = "Method",
			detail = m.CanYield and detail .. " [yields]" or detail,
			owner = m.Owner,
			deprecated = deprecation(m),
			yields = m.CanYield == true,
		})
	end
	for _, e in events or {} do
		add(e, {
			name = e.Name,
			kind = "Event",
			detail = `RBXScriptSignal({paramList(e.Parameters)})`,
			owner = e.Owner,
			deprecated = deprecation(e),
		})
	end

	self._members[className] = out
	return out
end

--- Sorted names of every class ReflectionService knows (live shape: a list of `{ Name, Superclass, ... }`), or nil.
function ClassCatalog:classNames()
	if self._names ~= nil then
		return self._names or nil
	end
	local service = self._service
	local names = false
	if service and type(service.GetClasses) == "function" then
		local ok, list = pcall(service.GetClasses, service)
		if ok and type(list) == "table" then
			names = {}
			for _, entry in list do
				local name = type(entry) == "string" and entry or select(2, pcall(function()
					return entry.Name
				end))
				if type(name) == "string" then
					names[#names + 1] = name
				end
			end
			table.sort(names)
		end
	end
	self._names = names
	return names or nil
end

function ClassCatalog:clear()
	self._members = {}
	self._classes = {}
	self._names = nil
end

return ClassCatalog
