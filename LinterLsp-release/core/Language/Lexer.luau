--[[
	Lexer: Luau source -> parallel token arrays (cheap on memory) plus comments for doc extraction.

	Result fields (all arrays indexed by token number, last token is kind "eof"):
	  kinds   "name" | "keyword" | "number" | "string" | "interp" | "op" | "eof"
	  texts   raw lexeme              values  decoded string / number value
	  lines   start line (1-based)    cols    start column (1-based, bytes)
	  starts/ends  inclusive byte range of the lexeme
	  unterminated[i]  string token that never closed
	  comments / commentByEnd  see docBefore
]]

local Lexer = {}

local find, sub, byte, gsub = string.find, string.sub, string.byte, string.gsub

local KEYWORDS = {}
for _, word in
	{ "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while" }
do
	KEYWORDS[word] = true
end

local OPS3 = { ["..."] = true, ["..="] = true, ["//="] = true }
local OPS2 = {}
for _, op in { "==", "~=", "<=", ">=", "..", "::", "->", "+=", "-=", "*=", "/=", "%=", "^=", "//" } do
	OPS2[op] = true
end

local SIMPLE_ESCAPES = {
	n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v",
	["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n", ["`"] = "`", ["{"] = "{",
}

local function decodeEscapes(raw)
	if not find(raw, "\\", 1, true) then
		return raw
	end
	local out, i, n = {}, 1, #raw
	while i <= n do
		local backslash = find(raw, "\\", i, true)
		if not backslash then
			out[#out + 1] = sub(raw, i)
			break
		end
		if backslash > i then
			out[#out + 1] = sub(raw, i, backslash - 1)
		end
		local d = sub(raw, backslash + 1, backslash + 1)
		if SIMPLE_ESCAPES[d] then
			out[#out + 1] = SIMPLE_ESCAPES[d]
			i = backslash + 2
		elseif d == "x" then
			local value = tonumber(sub(raw, backslash + 2, backslash + 3), 16)
			out[#out + 1] = value and string.char(value) or ""
			i = backslash + 4
		elseif d == "z" then
			local _, e = find(raw, "^%s*", backslash + 2)
			i = e + 1
		elseif d == "u" then
			local hex, nextPos = string.match(raw, "^{(%x+)}()", backslash + 2)
			if hex then
				local ok, char = pcall(utf8.char, tonumber(hex, 16))
				out[#out + 1] = ok and char or ""
				i = nextPos
			else
				i = backslash + 2
			end
		elseif find(d, "^%d") then
			local digits = string.match(raw, "^%d%d?%d?", backslash + 1)
			out[#out + 1] = string.char(math.min(tonumber(digits), 255))
			i = backslash + 1 + #digits
		else
			out[#out + 1] = d
			i = backslash + 2
		end
	end
	return table.concat(out)
end

Lexer.decodeEscapes = decodeEscapes

local function countNewlines(text)
	local count, last, p = 0, nil, 1
	while true do
		local nl = find(text, "\n", p, true)
		if not nl then
			break
		end
		count += 1
		last = nl
		p = nl + 1
	end
	return count, last
end

local function dedent(text)
	local lines = {}
	for line in string.gmatch(text .. "\n", "(.-)\r?\n") do
		lines[#lines + 1] = line
	end
	local minIndent
	for _, line in lines do
		if find(line, "%S") then
			local indent = #string.match(line, "^[ \t]*")
			if not minIndent or indent < minIndent then
				minIndent = indent
			end
		end
	end
	minIndent = minIndent or 0
	for index, line in lines do
		lines[index] = sub(line, minIndent + 1)
	end
	return (gsub(table.concat(lines, "\n"), "^%s+", ""):gsub("%s+$", ""))
end

local function cleanComment(kind, text)
	if kind == "block" then
		return dedent(text)
	end
	if sub(text, 1, 1) == "-" then
		text = sub(text, 2) -- `---` doc comments
	end
	text = gsub(text, "^ ", "")
	return (gsub(text, "%s+$", ""))
end

--- `resume` (internal, see Lexer.update) continues a previous lexing from a line start with the earlier
--- tokens already in place: { kinds ... ends, unterminated, comments, commentByEnd, n, pos, line, lastTokenLine }.
function Lexer.lex(source, resume)
	local kinds, texts, values, lines, cols, starts, ends
	local unterminated, comments, commentByEnd
	local n, pos, line, lastTokenLine
	if resume then
		kinds, texts, values, lines, cols, starts, ends =
			resume.kinds, resume.texts, resume.values, resume.lines, resume.cols, resume.starts, resume.ends
		unterminated, comments, commentByEnd = resume.unterminated, resume.comments, resume.commentByEnd
		n, pos, line, lastTokenLine = resume.n, resume.pos, resume.line, resume.lastTokenLine
	else
		kinds, texts, values, lines, cols, starts, ends = {}, {}, {}, {}, {}, {}, {}
		unterminated, comments, commentByEnd = {}, {}, {}
		n, pos, line, lastTokenLine = 0, 1, 1, 0
	end
	local len = #source
	local lineStart = pos
	local tokLine, tokCol = line, 1

	local function push(kind, text, value, s, e)
		n += 1
		kinds[n], texts[n], values[n] = kind, text, value
		lines[n], cols[n], starts[n], ends[n] = tokLine, tokCol, s, e
		lastTokenLine = tokLine
	end

	while true do
		local _, wsEnd = find(source, "^[ \t\r\f]*", pos)
		pos = wsEnd + 1
		local c = byte(source, pos)
		if not c then
			break
		end
		tokLine, tokCol = line, pos - lineStart + 1

		if c == 10 then
			line += 1
			pos += 1
			lineStart = pos
		elseif c == 45 and byte(source, pos + 1) == 45 then
			local s = pos
			local _, openEnd, eq = find(source, "^%-%-%[(=*)%[", pos)
			local body, kind, e
			if openEnd then
				kind = "block"
				local closeStart, closeEnd = find(source, "]" .. eq .. "]", openEnd + 1, true)
				if closeStart then
					body, e = sub(source, openEnd + 1, closeStart - 1), closeEnd
				else
					body, e = sub(source, openEnd + 1), len
				end
			else
				kind = "line"
				local nl = find(source, "\n", pos, true)
				e = (nl or len + 1) - 1
				body = sub(source, pos + 2, e)
			end
			local newlines, lastNl = countNewlines(sub(source, s, e))
			local text = cleanComment(kind, body)
			local comment = {
				kind = kind,
				text = text,
				pos = s,
				e = e,
				startLine = line,
				endLine = line + newlines,
				ownLine = lastTokenLine ~= line,
				directive = sub(text, 1, 1) == "!",
			}
			comments[#comments + 1] = comment
			commentByEnd[comment.endLine] = comment
			if newlines > 0 then
				line += newlines
				lineStart = s + lastNl
			end
			pos = e + 1
		elseif (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 then
			local _, e = find(source, "^[%w_]*", pos + 1)
			local text = sub(source, pos, e)
			push(KEYWORDS[text] and "keyword" or "name", text, nil, pos, e)
			pos = e + 1
		elseif (c >= 48 and c <= 57) or (c == 46 and (byte(source, pos + 1) or 0) >= 48 and (byte(source, pos + 1) or 0) <= 57) then
			local e
			local _, hexEnd = find(source, "^0[xX][%x_]+", pos)
			if hexEnd then
				e = hexEnd
			else
				local _, binEnd = find(source, "^0[bB][01_]+", pos)
				if binEnd then
					e = binEnd
				else
					if c == 46 then
						_, e = find(source, "^%.%d[%d_]*", pos)
					else
						_, e = find(source, "^%d[%d_]*%.?[%d_]*", pos)
					end
					if sub(source, e, e) == "." and byte(source, e + 1) == 46 then
						e -= 1 -- `1..x` is a number then a concat
					end
					local _, expEnd = find(source, "^[eE][%+%-]?%d+", e + 1)
					if expEnd then
						e = expEnd
					end
				end
			end
			local text = sub(source, pos, e)
			local clean = gsub(text, "_", "")
			local value
			if find(clean, "^0[bB]") then
				value = tonumber(sub(clean, 3), 2)
			else
				value = tonumber(clean)
			end
			push("number", text, value, pos, e)
			pos = e + 1
		elseif c == 34 or c == 39 then
			local cls = c == 34 and '[\\\n"]' or "[\\\n']"
			local i, closed = pos + 1, false
			while true do
				local j = find(source, cls, i)
				if not j then
					i = len + 1
					break
				end
				local ch = byte(source, j)
				if ch == 92 then
					i = j + 2
				elseif ch == 10 then
					i = j
					break
				else
					i = j + 1
					closed = true
					break
				end
			end
			local e = math.min(i - 1, len)
			local raw = sub(source, pos, e)
			local inner = sub(raw, 2, closed and -2 or -1)
			push("string", raw, decodeEscapes(inner), pos, e)
			if not closed then
				unterminated[n] = true
			end
			if find(raw, "\n", 1, true) then
				local count, lastNl = countNewlines(raw)
				line += count
				lineStart = pos + lastNl
			end
			pos = e + 1
		elseif c == 91 then
			local _, openEnd, eq = find(source, "^%[(=*)%[", pos)
			if openEnd then
				local closeStart, closeEnd = find(source, "]" .. eq .. "]", openEnd + 1, true)
				local e, inner
				if closeStart then
					inner, e = sub(source, openEnd + 1, closeStart - 1), closeEnd
				else
					inner, e = sub(source, openEnd + 1), len
				end
				if sub(inner, 1, 1) == "\n" then
					inner = sub(inner, 2)
				elseif sub(inner, 1, 2) == "\r\n" then
					inner = sub(inner, 3)
				end
				push("string", sub(source, pos, e), inner, pos, e)
				if not closeStart then
					unterminated[n] = true
				end
				local count, lastNl = countNewlines(sub(source, pos, e))
				if count > 0 then
					line += count
					lineStart = pos + lastNl
				end
				pos = e + 1
			else
				push("op", "[", nil, pos, pos)
				pos += 1
			end
		elseif c == 96 then
			local i, depth = pos + 1, 0
			local closed = false
			while i <= len do
				local ch = byte(source, i)
				if ch == 92 then
					i += 2
				elseif ch == 123 then
					depth += 1
					i += 1
				elseif ch == 125 then
					if depth > 0 then
						depth -= 1
					end
					i += 1
				elseif ch == 96 and depth == 0 then
					closed = true
					break
				elseif ch == 96 then
					local j = find(source, "`", i + 1, true)
					i = (j or len) + 1
				elseif (ch == 34 or ch == 39) and depth > 0 then
					local j = find(source, string.char(ch), i + 1, true)
					i = (j or len) + 1
				else
					i += 1
				end
			end
			local e = closed and i or len
			local raw = sub(source, pos, e)
			push("interp", raw, raw, pos, e)
			if not closed then
				unterminated[n] = true
			end
			local count, lastNl = countNewlines(raw)
			if count > 0 then
				line += count
				lineStart = pos + lastNl
			end
			pos = e + 1
		else
			local three = sub(source, pos, pos + 2)
			if OPS3[three] then
				push("op", three, nil, pos, pos + 2)
				pos += 3
			else
				local two = sub(three, 1, 2)
				if OPS2[two] then
					push("op", two, nil, pos, pos + 1)
					pos += 2
				else
					push("op", sub(three, 1, 1), nil, pos, pos)
					pos += 1
				end
			end
		end
	end

	tokLine, tokCol = line, pos - lineStart + 1
	push("eof", "", nil, len + 1, len)

	return {
		n = n,
		kinds = kinds,
		texts = texts,
		values = values,
		lines = lines,
		cols = cols,
		starts = starts,
		ends = ends,
		unterminated = unterminated,
		comments = comments,
		commentByEnd = commentByEnd,
		source = source,
		len = len,
	}
end

local ARRAYS = { "kinds", "texts", "values", "lines", "cols", "starts", "ends" }
local BLOCK = 4096

local function commonPrefix(a, b)
	local limit = math.min(#a, #b)
	local p = 0
	while p + BLOCK <= limit and sub(a, p + 1, p + BLOCK) == sub(b, p + 1, p + BLOCK) do
		p += BLOCK
	end
	local lo, hi = 0, math.min(BLOCK, limit - p)
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if sub(a, p + 1, p + mid) == sub(b, p + 1, p + mid) then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return p + lo
end

local function lineStartOf(source, position)
	while position > 1 and byte(source, position - 1) ~= 10 do
		position -= 1
	end
	return position
end

--[[
	Lexes `source` reusing the tokens of a previous lexing of a similar text. Typing happens at the
	cursor, so everything above it is unchanged: only the part from the first changed line onwards is
	lexed again. Tokens or comments that straddle that line (multi-line strings and comments) push the
	restart point earlier so the result is always identical to a full Lexer.lex(source).

	CONSUMES `prev`: its arrays are truncated and extended in place. Keep only the returned table.
]]
function Lexer.update(prev, source)
	if not prev then
		--- Text of a comment that follows code on `line` (`x = 1 -- like this`), or nil.
function Lexer.trailingComment(tokens, line)
	local comment = tokens.commentByEnd[line]
	if comment and not comment.ownLine and comment.startLine == line and comment.kind == "line" then
		return comment.text
	end
	return nil
end

return Lexer.lex(source)
	end
	if prev.source == source then
		return prev
	end

	local restart = lineStartOf(source, commonPrefix(prev.source, source) + 1)
	local starts, ends, prevComments = prev.starts, prev.ends, prev.comments
	local count = prev.n - 1 -- real tokens (the last entry is eof)
	local keep
	while true do
		local lo, hi = 0, count
		while lo < hi do
			local mid = (lo + hi + 1) // 2
			if starts[mid] < restart then
				lo = mid
			else
				hi = mid - 1
			end
		end
		keep = lo
		local moved = false
		if keep >= 1 and ends[keep] >= restart then
			restart = lineStartOf(source, starts[keep])
			moved = true
		else
			for index = #prevComments, 1, -1 do
				local comment = prevComments[index]
				if comment.pos < restart then
					if comment.e >= restart then
						restart = lineStartOf(source, comment.pos)
						moved = true
					end
					break
				end
			end
		end
		if not moved then
			break
		end
	end

	-- Truncate in place (O(changed tail), no copying) and continue lexing into the same arrays.
	for _, name in ARRAYS do
		local array = prev[name]
		for index = prev.n, keep + 1, -1 do
			array[index] = nil
		end
	end
	local unterminated = prev.unterminated
	for index in unterminated do
		if index > keep then
			unterminated[index] = nil
		end
	end
	local commentByEnd = prev.commentByEnd
	for index = #prevComments, 1, -1 do
		local comment = prevComments[index]
		if comment.e < restart then
			break
		end
		prevComments[index] = nil
		if commentByEnd[comment.endLine] == comment then
			commentByEnd[comment.endLine] = nil
		end
	end
	local _, newlines = gsub(sub(source, 1, restart - 1), "\n", "")
	--- Text of a comment that follows code on `line` (`x = 1 -- like this`), or nil.
function Lexer.trailingComment(tokens, line)
	local comment = tokens.commentByEnd[line]
	if comment and not comment.ownLine and comment.startLine == line and comment.kind == "line" then
		return comment.text
	end
	return nil
end

return Lexer.lex(source, {
		kinds = prev.kinds, texts = prev.texts, values = prev.values, lines = prev.lines,
		cols = prev.cols, starts = prev.starts, ends = prev.ends,
		unterminated = unterminated, comments = prevComments, commentByEnd = commentByEnd,
		n = keep,
		pos = restart,
		line = newlines + 1,
		lastTokenLine = keep > 0 and prev.lines[keep] or 0,
	})
end

--- The first `count` tokens followed by a fresh eof: a prefix view for parsing only the code before the cursor.
function Lexer.slice(tokens, count)
	local out = {
		n = count + 1,
		source = tokens.source,
		len = tokens.len,
		comments = tokens.comments,
		commentByEnd = tokens.commentByEnd,
		unterminated = tokens.unterminated,
	}
	for _, name in ARRAYS do
		out[name] = table.move(tokens[name], 1, count, 1, {})
	end
	local lastEnd = count > 0 and tokens.ends[count] or 0
	out.kinds[count + 1] = "eof"
	out.texts[count + 1] = ""
	out.lines[count + 1] = tokens.lines[count + 1] or tokens.lines[count] or 1
	out.cols[count + 1] = tokens.cols[count + 1] or 1
	out.starts[count + 1] = lastEnd + 1
	out.ends[count + 1] = lastEnd
	return out
end

--- Doc text for whatever starts on `line`: the block of own-line comments ending on line - 1.
function Lexer.docBefore(tokens, line)
	local byEnd = tokens.commentByEnd
	local parts = {}
	local l = line - 1
	while l >= 1 do
		local comment = byEnd[l]
		if not comment or not comment.ownLine or comment.directive then
			break
		end
		local text = comment.text
		if text ~= "" and find(text, "^[%-=%*#~_/%s]+$") then
			break -- separator banners are not documentation
		end
		table.insert(parts, 1, text)
		l = comment.startLine - 1
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "\n")
end

--- Text of a comment that follows code on `line` (`x = 1 -- like this`), or nil.
function Lexer.trailingComment(tokens, line)
	local comment = tokens.commentByEnd[line]
	if comment and not comment.ownLine and comment.startLine == line and comment.kind == "line" then
		return comment.text
	end
	return nil
end

return Lexer
