--[[
	Maid: owns things that need cleaning up (connections, instances, functions, threads, and any
	object with :Destroy() / :Disconnect()). Named slots (`maid.Foo = x`) clean their previous
	occupant when replaced.
]]

local Log = require(script.Parent.Log)

local Maid = {}
Maid.ClassName = "Maid"

local function runTask(item)
	local kind = typeof(item)
	if kind == "function" then
		item()
	elseif kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "thread" then
		if task and task.cancel then
			pcall(task.cancel, item)
		end
	elseif kind == "table" then
		if type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		end
	end
end

function Maid.new()
	return setmetatable({ _tasks = {}, _count = 0 }, Maid)
end

function Maid.is(value)
	return type(value) == "table" and getmetatable(value) == Maid
end

Maid.__index = function(self, key)
	local method = Maid[key]
	if method ~= nil then
		return method
	end
	return rawget(self, "_tasks")[key]
end

Maid.__newindex = function(self, key, value)
	if Maid[key] ~= nil then
		error(`'{tostring(key)}' is reserved on Maid`, 2)
	end
	local tasks = rawget(self, "_tasks")
	local old = tasks[key]
	if old == value then
		return
	end
	tasks[key] = value
	if old ~= nil then
		runTask(old)
	end
end

--- Adds an item to be cleaned up later. Returns the item.
function Maid:Give(item)
	local n = rawget(self, "_count") + 1
	rawset(self, "_count", n)
	rawget(self, "_tasks")[n] = item
	return item
end

function Maid:IsEmpty()
	return next(rawget(self, "_tasks")) == nil
end

--- Runs one cleanup; a failing task is logged and never prevents the others from running.
local function safely(item)
	local ok, err = pcall(runTask, item)
	if not ok then
		Log.warn("cleanup task failed: %s", tostring(err))
	end
end

--- Cleans everything. Connections go first so nothing fires while objects are torn down.
function Maid:Clean()
	local tasks = rawget(self, "_tasks")
	for key, item in next, tasks do
		if typeof(item) == "RBXScriptConnection" then
			tasks[key] = nil
			safely(item)
		end
	end
	local key, item = next(tasks)
	while item ~= nil do
		tasks[key] = nil
		safely(item)
		key, item = next(tasks)
	end
end

Maid.Destroy = Maid.Clean
Maid.DoCleaning = Maid.Clean

return Maid
