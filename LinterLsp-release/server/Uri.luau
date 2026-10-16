--[[
	Uri: file:// URIs <-> paths. Pure; handles the Windows forms (`file:///c%3A/Users/me`) on any host so it can be tested everywhere.
]]

local Uri = {}

local function decode(text)
	return (string.gsub(text, "%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16) :: number) -- the pattern only matches two hex digits, so this is always a number
	end))
end

local function encode(text)
	return (string.gsub(text, "[^%w%-%._~/:]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

--- "file:///home/me/a b.luau" -> "/home/me/a b.luau"; "file:///c%3A/Users/me" -> "c:/Users/me". Other schemes -> nil.
function Uri.toPath(uri)
	local rest = string.match(uri, "^file://(.*)$")
	if not rest then
		return nil
	end
	local path = decode(rest)
	local host, tail = string.match(path, "^([^/]+)(/.*)$") -- file://server/share/x (UNC)
	if host and not string.match(path, "^/") then
		path = "//" .. host .. tail
	end
	if string.match(path, "^/%a:") then
		path = string.sub(path, 2)
	end
	return path
end

--- "/home/me/a b.luau" -> "file:///home/me/a%20b.luau"; "c:/Users/me" -> "file:///c%3A/Users/me".
function Uri.fromPath(path)
	path = string.gsub(path, "\\", "/")
	if string.match(path, "^%a:") then
		path = "/" .. string.sub(path, 1, 1) .. "%3A" .. encode(string.sub(path, 3))
		return "file://" .. path
	end
	return "file://" .. encode(path)
end

--- Case-folded, slash-normalised key for comparing paths (Windows paths are case-insensitive).
function Uri.key(path, windows)
	path = string.gsub(path, "\\", "/")
	if windows or string.match(path, "^%a:") then
		path = string.lower(path)
	end
	return path
end

return Uri
