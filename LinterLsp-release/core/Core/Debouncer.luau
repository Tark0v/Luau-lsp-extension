--[[
	Debouncer: coalesces bursts of triggers into a single delayed callback. The first Trigger()
	schedules the callback; further triggers before it fires are absorbed.
]]

local Log = require(script.Parent.Log)

local Debouncer = {}
Debouncer.__index = Debouncer

function Debouncer.new(delaySeconds, callback)
	return setmetatable({
		_delay = delaySeconds,
		_callback = callback,
		_pending = false,
		_thread = nil,
		_destroyed = false,
	}, Debouncer)
end

function Debouncer:Trigger()
	if self._pending or self._destroyed then
		return
	end
	self._pending = true
	self._thread = task.delay(self._delay, function()
		self._pending = false
		self._thread = nil
		if not self._destroyed then
			local ok, err = pcall(self._callback)
			if not ok then
				Log.warn("debounced callback failed: %s", tostring(err))
			end
		end
	end)
end

--- Runs the callback now if a trigger is pending.
function Debouncer:Flush()
	if not self._pending then
		return
	end
	self:Cancel()
	self._callback()
end

function Debouncer:Cancel()
	if self._thread then
		pcall(task.cancel, self._thread)
		self._thread = nil
	end
	self._pending = false
end

function Debouncer:Destroy()
	self._destroyed = true
	self:Cancel()
end

return Debouncer
