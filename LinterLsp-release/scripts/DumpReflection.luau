--[[
	Runs INSIDE Roblox Studio (execute_luau, Edit datamodel). Sends every class's properties, methods and events from
	ReflectionService, as a game script sees them, to scripts/receive-dump.luau. Needs HttpService.HttpEnabled.
	Set PORT to the receiver's port.
]]

local PORT = 38211

local HttpService = game:GetService("HttpService")
local ReflectionService = game:GetService("ReflectionService")

local CAPABILITIES = {
	"Basic", "Players", "Input", "Network", "Physics", "UI", "Audio", "Animation", "Chat", "Environment",
	"RemoteEvent", "CreateInstances", "DataStore", "ScriptGlobals", "LegacySound", "CSG", "Material", "Teleport",
	"Groups", "Social", "Monetization", "Logging", "ServerCommunication", "AvatarAppearance", "AvatarBehavior",
	"RunServerScript", "RunClientScript", "LoadString", "PromptExternalPurchase", "Consequences",
}
local items = {}
for _, name in CAPABILITIES do
	local ok, item = pcall(function()
		return Enum.SecurityCapability[name]
	end)
	if ok and item then
		table.insert(items, item)
	end
end
local options = #items > 0 and { Security = SecurityCapabilities.new(table.unpack(items)) } or nil

local function plainType(t)
	if type(t) ~= "table" then
		return { ScriptType = "any", EngineType = "Variant" }
	end
	return { ScriptType = t.ScriptType, EngineType = t.EngineType, EnumType = t.EnumType, InstanceType = t.InstanceType }
end

local function permits(list)
	local out = {}
	if type(list) == "table" then
		for key, value in list do
			table.insert(out, type(value) == "string" and value or tostring(typeof(value) == "EnumItem" and value.Name or key))
		end
	end
	return out
end

local function params(list)
	local out = {}
	for _, p in list or {} do
		table.insert(out, { Name = p.Name, Type = plainType(p.Type), DefaultValue = p.DefaultValue ~= nil and true or nil })
	end
	return out
end

local function post(path, body)
	local response = HttpService:RequestAsync({
		Url = `http://localhost:{PORT}{path}`,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode(body),
	})
	assert(response.Success, `{path}: {response.StatusCode}`)
end

local batch, inBatch = {}, 0
local total = 0
for _, entry in ReflectionService:GetClasses() do
	local name = entry.Name
	local class = { superclass = entry.Superclass, properties = {}, methods = {}, events = {} }
	for _, p in ReflectionService:GetPropertiesOfClass(name, options) or {} do
		table.insert(class.properties, {
			Name = p.Name, Owner = p.Owner, Type = plainType(p.Type),
			Display = { Category = p.Display and p.Display.Category, DeprecationMessage = p.Display and p.Display.DeprecationMessage },
			Permits = permits(p.Permits),
		})
	end
	for _, m in ReflectionService:GetMethodsOfClass(name, options) or {} do
		table.insert(class.methods, {
			Name = m.Name, Owner = m.Owner, Parameters = params(m.Parameters), ReturnType = plainType(m.ReturnType),
			CanYield = m.CanYield, Display = { DeprecationMessage = m.Display and m.Display.DeprecationMessage },
			Permits = permits(m.Permits),
		})
	end
	for _, e in ReflectionService:GetEventsOfClass(name, options) or {} do
		table.insert(class.events, {
			Name = e.Name, Owner = e.Owner, Parameters = params(e.Parameters),
			Display = { DeprecationMessage = e.Display and e.Display.DeprecationMessage }, Permits = permits(e.Permits),
		})
	end
	batch[name] = class
	inBatch += 1
	total += 1
	if inBatch >= 40 then
		post("/chunk", { classes = batch })
		batch, inBatch = {}, 0
		task.wait()
	end
end
if inBatch > 0 then
	post("/chunk", { classes = batch })
end
post("/done", { source = `studio {version()}` })
return `sent {total} classes`
