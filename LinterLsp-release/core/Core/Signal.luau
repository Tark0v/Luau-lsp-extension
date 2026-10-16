--[[
	Signal: tiny event class. Handlers run through task.spawn so one failing handler never stops the
	others. Handlers must not rely on running after Fire() returns.
]]

local Log = require(script.Parent.Log)

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local signal = self._signal
	self._signal = nil
	if signal then
		local list = signal._connections
		local index = table.find(list, self)
		if index then
			table.remove(list, index)
		end
	end
end
Connection.Destroy = Connection.Disconnect

function Signal.new()
	return setmetatable({ _connections = {}, _destroyed = false }, Signal)
end

function Signal.is(value)
	return type(value) == "table" and getmetatable(value) == Signal
end

function Signal:Connect(handler)
	assert(type(handler) == "function", "Signal:Connect expects a function")
	local connection = setmetatable({ Connected = not self._destroyed, _signal = self, _fn = handler }, Connection)
	if self._destroyed then
		connection._signal = nil
		return connection
	end
	table.insert(self._connections, connection)
	return connection
end

function Signal:Once(handler)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

local function traceback(message)
	return debug.traceback(tostring(message), 2)
end

--- Runs a handler on its own thread; a failure is logged, never propagated.
local function runHandler(handler, ...)
	local ok, err = xpcall(handler, traceback, ...)
	if not ok then
		Log.warn("signal handler failed: %s", tostring(err))
	end
end

function Signal:Fire(...)
	if self._destroyed or #self._connections == 0 then
		return
	end
	for _, connection in table.clone(self._connections) do
		if connection.Connected then
			task.spawn(runHandler, connection._fn, ...)
		end
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:GetConnectionCount()
	return #self._connections
end

function Signal:DisconnectAll()
	for _, connection in table.clone(self._connections) do
		connection:Disconnect()
	end
end

function Signal:Destroy()
	self._destroyed = true
	self:DisconnectAll()
end

return Signal
