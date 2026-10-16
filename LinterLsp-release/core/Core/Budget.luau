--[[
	Budget: fuel + wall-clock guard for anything that walks user data. The interpreter ticks it on
	every step; when it runs dry it throws a sentinel (never a string) that callers recognise.

	  OutOfFuel  - this slice (or the whole pool) ran out of steps
	  OutOfTime  - the wall-clock deadline of the whole request passed; always aborts the request
	  slice time - one slice (a single module) used up its own time allowance; only that slice is cut

	Slices are how one runaway module is kept from blocking everything else: it gets its own fuel and its
	own milliseconds, and when it overruns, only IT is cut short. 15% of the request's steps and time is
	never handed to a slice (the reserve), so the script being completed can always still be evaluated after
	a greedy module. A module's allowance covers its own work: time spent evaluating modules it requires is
	charged to those modules, not to it.
]]

local Budget = {}
Budget.__index = Budget

Budget.OutOfFuel = setmetatable({}, { __tostring = function() return "Budget.OutOfFuel" end })
Budget.OutOfTime = setmetatable({}, { __tostring = function() return "Budget.OutOfTime" end })

local SLICE_TIMEOUT = { __tostring = function() return "Budget.SliceTimeout" end }

local CHECK_EVERY = 32
local RESERVE_FRACTION = 0.15

--- opts: fuel (steps), ms (wall clock), clock (function, defaults to os.clock)
function Budget.new(opts)
	local clock = opts.clock or os.clock
	local fuel = opts.fuel or 50000
	local seconds = (opts.ms or 30) / 1000
	return setmetatable({
		fuel = fuel,
		reserve = math.floor(fuel * RESERVE_FRACTION),
		timeReserve = seconds * RESERVE_FRACTION,
		clock = clock,
		deadline = clock() + seconds,
		_ticks = 0,
		_sliceDeadline = nil,
		_sliceToken = nil,
		_depth = 0,
	}, Budget)
end

function Budget.isSignal(value)
	return value == Budget.OutOfFuel or value == Budget.OutOfTime or getmetatable(value) == SLICE_TIMEOUT
end

function Budget:tick(cost)
	self.fuel -= cost or 1
	if self.fuel < 0 then
		error(Budget.OutOfFuel, 0)
	end
	self._ticks += 1
	if self._ticks % CHECK_EVERY == 0 then
		local now = self.clock()
		local deadline = self.deadline
		if now > deadline then
			error(Budget.OutOfTime, 0)
		end
		local sliceDeadline = self._sliceDeadline
		if sliceDeadline and now > math.min(sliceDeadline, deadline - self.timeReserve) then
			error(self._sliceToken, 0)
		end
	end
end

function Budget:expired()
	return self.fuel < 0 or self.clock() > self.deadline
end

--- pcall that never swallows budget signals.
function Budget.pcall(fn, ...)
	local ok, result = pcall(fn, ...)
	if not ok and Budget.isSignal(result) then
		error(result, 0)
	end
	return ok, result
end

--- Runs fn with at most `maxFuel` steps and `maxMs` milliseconds (either may be nil) of the shared pool.
--- Returns (true, ...results) on success or (false, reason):
---   "fuel"     the slice used up its own steps (deterministic: the code really is that big)
---   "time"     the slice used up its own milliseconds
---   "starved"  the request had nothing to spare (the reserve is off limits); try again on a later request
---   other      the error value fn threw (an internal error is the slice's problem, not the request's)
--- The request's own OutOfTime, or the pool running dry, always propagates.
function Budget:sliceTimed(maxFuel, maxMs, fn, ...)
	local outer = self.fuel
	-- only the outermost slice has to leave the reserve alone; inside a slice `fuel` is already that slice's allowance
	local available = self._depth == 0 and math.max(outer - self.reserve, 0) or outer
	local started = maxMs and self.clock()
	if available <= 0 or (started and started > self.deadline - self.timeReserve) then
		return false, "starved"
	end
	local inner = math.min(available, maxFuel)
	self.fuel = inner
	self._depth += 1

	local outerDeadline, outerToken = self._sliceDeadline, self._sliceToken
	local ownDeadline
	if maxMs then
		-- always its own deadline: how long ANOTHER module takes is that module's business, not this one's
		ownDeadline = started + maxMs / 1000
		self._sliceDeadline, self._sliceToken = ownDeadline, setmetatable({}, SLICE_TIMEOUT)
	end
	local token = self._sliceToken

	local results = table.pack(pcall(fn, ...))
	self._depth -= 1
	self._sliceDeadline, self._sliceToken = outerDeadline, outerToken
	if started and outerDeadline then
		-- the time spent in here was not spent by the enclosing module itself: its allowance covers its own work only
		self._sliceDeadline = outerDeadline + (self.clock() - started)
	end

	local used = math.min(inner - self.fuel, inner)
	self.fuel = outer - used
	if results[1] then
		return true, table.unpack(results, 2, results.n)
	end
	local err = results[2]
	if err == Budget.OutOfTime then
		error(err, 0)
	end
	if getmetatable(err) == SLICE_TIMEOUT then
		if err == token and token ~= outerToken then
			-- own allowance, or the request's last stretch (the reserve) being protected?
			return false, self.clock() > ownDeadline and "time" or "starved"
		end
		error(err, 0) -- an enclosing slice's allowance ran out: let that slice handle it
	end
	if err == Budget.OutOfFuel then
		if self.fuel <= 0 then
			error(err, 0)
		end
		return false, inner < maxFuel and "starved" or "fuel"
	end
	return false, err
end

function Budget:slice(maxFuel, fn, ...)
	return self:sliceTimed(maxFuel, nil, fn, ...)
end

--- Top-level runner for a request. Returns ok, result, status where status is
--- "ok" | "fuel" | "time" | "error".
function Budget.run(fn, ...)
	local ok, result = pcall(fn, ...)
	if ok then
		return true, result, "ok"
	end
	if result == Budget.OutOfFuel then
		return false, nil, "fuel"
	elseif result == Budget.OutOfTime or getmetatable(result) == SLICE_TIMEOUT then
		return false, nil, "time"
	end
	return false, result, "error"
end

return Budget
