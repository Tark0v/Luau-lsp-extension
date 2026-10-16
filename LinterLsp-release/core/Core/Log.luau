--[[
	Log: prefixed output with a debug switch and a replaceable sink (tests silence it).
]]

local Log = {
	debugEnabled = false,
	sink = nil, -- optional function(level: string, message: string)
}

local PREFIX = "[Linter] "

local function format(message, ...)
	if select("#", ...) == 0 then
		return tostring(message)
	end
	local ok, text = pcall(string.format, message, ...)
	return ok and text or tostring(message)
end

local function emit(level, message, ...)
	local text = format(message, ...)
	if Log.sink then
		Log.sink(level, text)
	elseif level == "warn" then
		warn(PREFIX .. text)
	else
		print(PREFIX .. text)
	end
end

function Log.setDebug(enabled)
	Log.debugEnabled = enabled == true
end

function Log.debug(message, ...)
	if Log.debugEnabled then
		emit("debug", message, ...)
	end
end

function Log.info(message, ...)
	emit("info", message, ...)
end

function Log.warn(message, ...)
	emit("warn", message, ...)
end

return Log
