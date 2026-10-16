--[[
	Context: decides what the user is completing from the text before the cursor.

	  member        `chain.` / `chain:` / `chain.pre|` / `chain.1|` (an array position typed after a dot)
  index-number  `chain[` / `chain[12|`   (an array position inside brackets)
	  index-string  `chain["pre|`
	  call-string   `callee("pre|` / `callee(a, "pre|`   (callee ends in a plain name)
	  call-arg      `callee(` / `callee(a, ` / `callee(a, pre|`   (an argument is being started)
  marker		`--@Pri|` / `--@param na|` / `--@param name Ty|` / `--@type Ty|`   (typing an annotation in a comment)

	Returns nil (cheaply, before any lexing) for everything else. For a hit it returns
	  { kind, sep, prefix, chainText, programText, ... }
	where `programText` is the code BEFORE the chain: that is what gets interpreted to learn what
	the chain refers to.
]]

local Lexer = require(script.Parent.Parent.Language.Lexer)

local Context = {}

local find, sub, match = string.find, string.sub, string.match

--- Byte offset of the character at (line, character), both 1-based; text before the cursor is
--- sub(text, 1, offset - 1).
function Context.offsetOf(text, line, character)
	local pos = 1
	for _ = 2, line do
		local newline = find(text, "\n", pos, true)
		if not newline then
			return #text + 1
		end
		pos = newline + 1
	end
	return math.min(pos + character - 1, #text + 1)
end

local function worthAnalyzing(lineBefore)
	if find(lineBefore, "[%.:]%s*[%w_]*$") and not find(lineBefore, "%.%.%s*[%w_]*$") then
		return true
	end
	if find(lineBefore, "%-%-[%-%s]*@") then
		return true
	end
	if find(lineBefore, "%[%s*%d*$") then
		return true
	end
	if find(lineBefore, "[%(,]%s*[%w_]*$") then
		return true -- an argument is being started
	end
	return find(lineBefore, "[\"'][^\"']*$") ~= nil
end

--- The cursor is at the end of a line comment that is an annotation being typed (`--@Pri|`). `tokens` are the tokens
--- of the text before the cursor, so a `--@` inside a string is not mistaken for a comment.
local function analyzeMarker(before, tokens)
	local comments = tokens.comments
	local comment = comments[#comments]
	if not comment or comment.kind ~= "line" or comment.e < #before then
		return nil
	end
	local body = match(sub(before, comment.pos, comment.e), "^%-%-+%s*(@.*)$")
	if not body then
		return nil
	end
	local tag = match(body, "^@([%a_]*)$")
	if tag then
		return { kind = "marker", stage = "tag", prefix = tag }
	end
	local word = match(body, "^@param%s+([%w_]*)$")
	if word then
		return { kind = "marker", stage = "param-name", prefix = word }
	end
	local typed = match(body, "^@param%s+[%w_]+%s*:?%s*(.*)$") or match(body, "^@type%s+(.*)$") or match(body, "^@return%s+(.*)$")
	if typed then
		return { kind = "marker", stage = "type", prefix = match(typed, "[%w_%.]*$") or "" }
	end
	return nil
end

local function isChainEnd(tokens, index)
	local kind, text = tokens.kinds[index], tokens.texts[index]
	return kind == "name" or (kind == "op" and (text == ")" or text == "]"))
end

local function matchBackward(tokens, closeIndex)
	local kinds, texts = tokens.kinds, tokens.texts
	local close = texts[closeIndex]
	local open = close == ")" and "(" or "["
	local depth = 0
	for index = closeIndex, math.max(1, closeIndex - 400), -1 do
		if kinds[index] == "op" then
			local text = texts[index]
			if text == close then
				depth += 1
			elseif text == open then
				depth -= 1
				if depth == 0 then
					return index
				end
			end
		end
	end
	return nil
end

--- Index of the first token of the access chain whose last token is `endIndex`.
local function chainStart(tokens, endIndex)
	local kinds, texts = tokens.kinds, tokens.texts
	local pos = endIndex
	for _ = 1, 64 do
		if pos < 1 then
			return nil
		end
		local kind, text = kinds[pos], texts[pos]
		if kind == "name" then
			local prev = pos - 1
			if prev >= 1 and kinds[prev] == "op" and (texts[prev] == "." or texts[prev] == ":") then
				pos = prev - 1
				if pos < 1 or not isChainEnd(tokens, pos) then
					return nil
				end
			else
				return pos
			end
		elseif kind == "op" and (text == ")" or text == "]") then
			local open = matchBackward(tokens, pos)
			if not open then
				return nil
			end
			local before = open - 1
			if text == ")" and not (before >= 1 and isChainEnd(tokens, before)) then
				return open -- a parenthesised expression is the base
			end
			if before < 1 or not isChainEnd(tokens, before) then
				return nil
			end
			pos = before
		else
			return nil
		end
	end
	return nil
end

local function invalidBefore(tokens, startIndex)
	local prev = startIndex - 1
	if prev < 1 then
		return false
	end
	local kind, text = tokens.kinds[prev], tokens.texts[prev]
	if (kind == "keyword" and (text == "function" or text == "local")) or (kind == "name" and text == "const") then
		return true
	end
	return kind == "op" and (text == "::" or text == "->")
end

local STATEMENT_WORDS = {}
for _, word in { "end", "then", "do", "local", "return", "for", "function", "while", "repeat", "until", "else", "elseif" } do
	STATEMENT_WORDS[word] = true
end

--- Walks back from a string token to the call's opening paren. Returns openIndex, argIndex.
local function findCallOpen(tokens, stringIndex)
	local kinds, texts = tokens.kinds, tokens.texts
	local depth, commas = 0, 0
	for index = stringIndex - 1, math.max(1, stringIndex - 200), -1 do
		if kinds[index] == "op" then
			local text = texts[index]
			if text == ")" or text == "]" or text == "}" then
				depth += 1
			elseif text == "(" or text == "[" or text == "{" then
				if depth == 0 then
					if text == "(" then
						return index, commas + 1
					end
					return nil
				end
				depth -= 1
			elseif text == "," and depth == 0 then
				commas += 1
			end
		elseif kinds[index] == "keyword" and depth == 0 then
			-- a statement boundary: whatever opened before it is not the call this argument belongs to
			if STATEMENT_WORDS[texts[index]] then
				return nil
			end
		end
	end
	return nil
end

-- Calls whose arguments Luau and Studio already describe: asking the interpreter about them on every keystroke would be wasted work.
local KNOWN_CALLEES = {}
for _, name in
	{
		"print", "warn", "error", "assert", "require", "pcall", "xpcall", "select", "type", "typeof", "tostring", "tonumber", "ipairs", "pairs", "next",
		"unpack", "rawget", "rawset", "rawequal", "rawlen", "setmetatable", "getmetatable", "newproxy", "spawn", "delay", "wait", "tick", "time",
		"string", "table", "math", "task", "os", "coroutine", "debug", "utf8", "bit32", "buffer", "Instance", "Enum", "game", "workspace", "script",
		"Vector2", "Vector3", "CFrame", "Color3", "UDim", "UDim2", "Rect", "Ray", "Region3", "BrickColor", "TweenInfo", "NumberRange",
		"NumberSequence", "ColorSequence", "Random", "DateTime", "Font", "OverlapParams", "RaycastParams", "PhysicalProperties",
	}
do
	KNOWN_CALLEES[name] = true
end

--- The call whose parentheses opened at `openIndex` (an argument, number `argIndex`, is being written). `kind` is call-string or
--- call-arg. Nil when the callee does not end in a plain name, or is a declaration (`function f(a, `).
local function callContext(tokens, openIndex, argIndex, prefix, before, kind)
	local kinds, texts, starts, ends = tokens.kinds, tokens.texts, tokens.starts, tokens.ends
	local calleeEnd = openIndex - 1
	if calleeEnd < 1 or kinds[calleeEnd] ~= "name" then
		return nil
	end
	local startIndex = chainStart(tokens, calleeEnd)
	if not startIndex or invalidBefore(tokens, startIndex) then
		return nil
	end
	if kind == "call-arg" and KNOWN_CALLEES[texts[startIndex]] then
		return nil
	end
	local ctx = {
		kind = kind,
		prefix = prefix,
		argIndex = argIndex,
		name = texts[calleeEnd],
		programText = sub(before, 1, starts[startIndex] - 1),
		startIndex = startIndex,
	}
	local sepIndex = calleeEnd - 1
	if sepIndex >= startIndex and kinds[sepIndex] == "op" and (texts[sepIndex] == "." or texts[sepIndex] == ":") then
		ctx.sep = texts[sepIndex]
		ctx.baseText = sub(before, starts[startIndex], ends[sepIndex - 1])
	end
	return ctx
end

local function analyzeString(tokens, stringIndex, prefix, before)
	local kinds, texts, starts, ends = tokens.kinds, tokens.texts, tokens.starts, tokens.ends
	local prev = stringIndex - 1
	if prev < 1 then
		return nil
	end

	if kinds[prev] == "op" and texts[prev] == "[" then
		local startIndex = chainStart(tokens, prev - 1)
		if not startIndex or invalidBefore(tokens, startIndex) then
			return nil
		end
		return {
			kind = "index-string",
			sep = ".",
			prefix = prefix,
			chainText = sub(before, starts[startIndex], ends[prev - 1]),
			programText = sub(before, 1, starts[startIndex] - 1),
			startIndex = startIndex,
		}
	end

	if kinds[prev] == "op" and (texts[prev] == "(" or texts[prev] == ",") then
		local openIndex, argIndex = findCallOpen(tokens, stringIndex)
		if not openIndex then
			return nil
		end
		return callContext(tokens, openIndex, argIndex, prefix, before, "call-string")
	end
	return nil
end

--- `f(`, `f(a, `, `f(a, na|`: the first token of an argument is being written. `argToken` is the index of the token the
--- argument would start at (the typed name, or the one after the `(` / `,`).
local function analyzeArgument(tokens, argToken, prefix, before)
	local openIndex, argIndex = findCallOpen(tokens, argToken)
	if not openIndex then
		return nil
	end
	return callContext(tokens, openIndex, argIndex, prefix, before, "call-arg")
end

--- Cheap pre-check on the cursor line only: is this even a place we could complete? (no lexing)
function Context.quick(before)
	local line = match(before, "[^\n]*$")
	if worthAnalyzing(line) then
		return true
	end
	-- an argument on its own line:  f(\n    a,\n    |   -- the line above ends with `(` or `,`
	if find(line, "^%s*[%w_]*$") then
		local index = #before - #line
		for _ = 1, 400 do
			local byte = string.byte(before, index)
			if byte == nil then
				return false
			elseif byte == 40 or byte == 44 then -- ( ,
				return true
			elseif byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
				return false
			end
			index -= 1
		end
	end
	return false
end

--- `chain[` or `chain[12` with the cursor right after it: someone reaching for an array position.
local function analyzeIndexNumber(tokens, bracketIndex, digits, before)
	local endIndex = bracketIndex - 1
	if endIndex < 1 or not isChainEnd(tokens, endIndex) then
		return nil
	end
	local startIndex = chainStart(tokens, endIndex)
	if not startIndex or invalidBefore(tokens, startIndex) then
		return nil
	end
	return {
		kind = "index-number",
		sep = ".",
		prefix = digits,
		chainText = sub(before, tokens.starts[startIndex], tokens.ends[endIndex]),
		programText = sub(before, 1, tokens.starts[startIndex] - 1),
		startIndex = startIndex,
	}
end

--- Is the cursor inside a type annotation, right after `Name.` / `Pkg.Name.`? Returns the index of the first name of that
--- dotted path, or nil. After `:`, `::` and `->` it is always a type (an expression cannot continue that way); after
--- `<`, `|` and `&` the line must look like a type position too, because those are also ordinary operators.
local function typePathStart(tokens, endIndex, lineBefore)
	local kinds, texts = tokens.kinds, tokens.texts
	if kinds[endIndex] ~= "name" then
		return nil
	end
	local pos = endIndex
	while pos >= 3 and kinds[pos - 1] == "op" and texts[pos - 1] == "." and kinds[pos - 2] == "name" do
		pos -= 2
	end
	local prev = pos - 1
	if prev < 1 or kinds[prev] ~= "op" then
		return nil
	end
	local text = texts[prev]
	if text == ":" or text == "::" or text == "->" then
		return pos
	end
	if text == "=" and (find(lineBefore, "^%s*export%s+type%s") or find(lineBefore, "^%s*type%s")) then
		return pos
	end
	if text == "<" or text == "|" or text == "&" then
		if find(lineBefore, "^%s*export%s+type%s") or find(lineBefore, "^%s*type%s+[%w_]+.-=") or find(lineBefore, "::") or find(lineBefore, "[^:]:%s*[^:]") or find(lineBefore, "%->") then
			return pos
		end
	end
	return nil
end

--- `tokens` (optional) are the tokens of `before`; pass them to avoid lexing twice.
--- On a hit the result includes `startIndex`: the first token of the access chain, so the code
--- before the chain is exactly tokens 1 .. startIndex - 1.
function Context.analyze(before, tokens)
	if not tokens then
		if not Context.quick(before) then
			return nil
		end
		tokens = Lexer.lex(before)
	end
	local kinds, texts, starts, ends = tokens.kinds, tokens.texts, tokens.starts, tokens.ends
	local marker = analyzeMarker(before, tokens)
	if marker then
		return marker
	end
	local last = tokens.n - 1
	if last < 1 then
		return nil
	end

	if kinds[last] == "string" and tokens.unterminated[last] and ends[last] >= #before then
		return analyzeString(tokens, last, tokens.values[last], before)
	end

	-- `t.1` lexes as the name `t` and the NUMBER `.1`; `t[1` as `t`, `[`, `1`. Both are someone reaching for an array position.
	if kinds[last] == "number" and ends[last] == #before then
		local text = texts[last]
		local digits = match(text, "^%.(%d+)$")
		if digits then
			local endIndex = last - 1
			if endIndex >= 1 and isChainEnd(tokens, endIndex) then
				local startIndex = chainStart(tokens, endIndex)
				if startIndex and not invalidBefore(tokens, startIndex) then
					return {
						kind = "member",
						sep = ".",
						prefix = digits,
						chainText = sub(before, starts[startIndex], ends[endIndex]),
						programText = sub(before, 1, starts[startIndex] - 1),
						startIndex = startIndex,
						operatorBack = #before - starts[last] + 1,
					}
				end
			end
			return nil
		end
		if find(text, "^%d+$") and last >= 2 and kinds[last - 1] == "op" and texts[last - 1] == "[" then
			return analyzeIndexNumber(tokens, last - 1, text, before)
		end
		return nil
	end
	if kinds[last] == "op" and texts[last] == "[" and ends[last] == #before then
		return analyzeIndexNumber(tokens, last, "", before)
	end

	if kinds[last] == "op" and (texts[last] == "(" or texts[last] == ",") and find(sub(before, ends[last] + 1), "^%s*$") then
		return analyzeArgument(tokens, last + 1, "", before)
	end
	if kinds[last] == "name" and ends[last] == #before and last >= 2 and kinds[last - 1] == "op" and (texts[last - 1] == "(" or texts[last - 1] == ",") then
		return analyzeArgument(tokens, last, texts[last], before)
	end

	local index, prefix = last, ""
	if kinds[index] == "name" and ends[index] == #before then
		prefix = texts[index]
		index -= 1
	end
	if index < 1 or kinds[index] ~= "op" or (texts[index] ~= "." and texts[index] ~= ":") then
		return nil
	end
	local endIndex = index - 1
	if endIndex < 1 then
		return nil
	end
	if texts[index] == "." then
		local typeStart = typePathStart(tokens, endIndex, match(before, "[^\n]*$"))
		if typeStart then
			return {
				kind = "type-member",
				sep = ".",
				prefix = prefix,
				chainText = sub(before, starts[typeStart], ends[endIndex]),
				programText = sub(before, 1, starts[typeStart] - 1),
				startIndex = typeStart,
			}
		end
	end
	local startIndex = chainStart(tokens, endIndex)
	if not startIndex or invalidBefore(tokens, startIndex) then
		return nil
	end
	return {
		kind = "member",
		sep = texts[index],
		prefix = prefix,
		chainText = sub(before, starts[startIndex], ends[endIndex]),
		programText = sub(before, 1, starts[startIndex] - 1),
		startIndex = startIndex,
		operatorBack = #before - starts[index] + 1, -- bytes from the cursor back to the `.` / `:`
	}
end

return Context
