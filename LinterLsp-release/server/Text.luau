--[[
	Text: converts between LSP positions (0-based line, UTF-16 code units) and the engine's (1-based line, 1-based byte column).
	Pure functions, no state.
]]

local Text = {}

--- Byte index (1-based) where each line starts.
function Text.lineStarts(text)
	local starts = { 1 }
	local at = 1
	while true do
		local newline = string.find(text, "\n", at, true)
		if not newline then
			break
		end
		starts[#starts + 1] = newline + 1
		at = newline + 1
	end
	return starts
end

local function units(codepoint)
	return codepoint >= 0x10000 and 2 or 1
end

--- Byte offset (1-based, may be #text + 1) of an LSP position. Positions past the end of a line clamp to its end.
function Text.offsetAt(text, starts, line, character)
	local lineStart = starts[line + 1]
	if not lineStart then
		return #text + 1
	end
	local lineEnd = (starts[line + 2] or (#text + 2)) - 1 -- includes the "\n"
	local at, used = lineStart, 0
	while at <= lineEnd and used < character do
		local byte = string.byte(text, at)
		if byte == 10 then
			break
		end
		local ok, codepoint = pcall(utf8.codepoint, text, at)
		if ok and codepoint then
			used += units(codepoint)
			at = utf8.offset(text, 2, at) or (at + 1)
		else
			used += 1 -- invalid UTF-8: one byte counts as one unit
			at += 1
		end
	end
	return at
end

--- LSP position -> engine position { line = 1-based, character = 1-based byte column }.
function Text.toEngine(text, starts, line, character)
	local offset = Text.offsetAt(text, starts, line, character)
	local lineStart = starts[line + 1] or offset
	return { line = line + 1, character = offset - lineStart + 1 }
end

--- Engine position -> LSP position.
function Text.fromEngine(text, starts, line, column)
	local lineStart = starts[line]
	if not lineStart then
		return { line = line - 1, character = column - 1 }
	end
	local stop = lineStart + column - 2 -- last byte before the position
	local at, used = lineStart, 0
	while at <= stop do
		local ok, codepoint = pcall(utf8.codepoint, text, at)
		if ok and codepoint then
			used += units(codepoint)
			at = utf8.offset(text, 2, at) or (at + 1)
		else
			used += 1
			at += 1
		end
	end
	return { line = line - 1, character = used }
end

return Text
