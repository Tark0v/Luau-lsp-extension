--[[
	Parser: error-tolerant recursive descent for Luau.

	Tolerance rules (the editor always hands us half-typed code):
	  * a statement that fails to parse is dropped and parsing resumes on a later line
	  * a block closed by end-of-file is flagged `unterminated` instead of failing - the interpreter
	    uses that flag to find the scope that contains the cursor
	  * type annotations are skipped structurally and kept as text

	Node kinds are in field `k`. Expressions: Nil True False Vararg Number String Interp Name Index
	IndexExpr Call Function Table Binary Unary Cast IfExpr Paren. Statements: Local LocalFunction
	FunctionDecl Assign CompoundAssign ExprStat Return If While Repeat ForNum ForIn Do Break
	Continue TypeDecl.
]]

local Lexer = require(script.Parent.Lexer)
local Annotations = require(script.Parent.Annotations)

local Parser = {}

local BINARY_PRIORITY = {
	["or"] = { 1, 1 },
	["and"] = { 2, 2 },
	["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 }, [">="] = { 3, 3 }, ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
	[".."] = { 5, 4 },
	["+"] = { 6, 6 }, ["-"] = { 6, 6 },
	["*"] = { 7, 7 }, ["/"] = { 7, 7 }, ["//"] = { 7, 7 }, ["%"] = { 7, 7 },
	["^"] = { 10, 9 },
}
local UNARY_PRIORITY = 8

local COMPOUND = {
	["+="] = "+", ["-="] = "-", ["*="] = "*", ["/="] = "/", ["//="] = "//", ["%="] = "%", ["^="] = "^", ["..="] = "..",
}

local sub, gsub = string.sub, string.gsub

local function parseTokens(tokens, opts)
	opts = opts or {}
	local maxDepth = opts.maxDepth or 100
	local spans = opts.spans == true -- record where each expression starts and ends (`sp`, `ep`: byte offsets in the source; `e` is taken by unary/paren operands)
	local kinds, texts, values, lines = tokens.kinds, tokens.texts, tokens.values, tokens.lines
	local starts, ends = tokens.starts, tokens.ends
	local source = tokens.source
	local i = 1
	local depth = 0
	local errors = {}

	local function fail(message)
		error({ parseError = true, msg = message, index = i }, 0)
	end

	local function isOp(text)
		return kinds[i] == "op" and texts[i] == text
	end
	local function isKw(text)
		return kinds[i] == "keyword" and texts[i] == text
	end
	local function acceptOp(text)
		if kinds[i] == "op" and texts[i] == text then
			i += 1
			return true
		end
		return false
	end
	local function expectOp(text)
		if not acceptOp(text) then
			fail(`expected '{text}'`)
		end
	end
	local function expectKw(text)
		if isKw(text) then
			i += 1
		else
			fail(`expected '{text}'`)
		end
	end
	local function expectName()
		if kinds[i] ~= "name" then
			fail("expected name")
		end
		local text = texts[i]
		i += 1
		return text
	end
	local function isBlockEnd()
		local k, t = kinds[i], texts[i]
		if k == "eof" then
			return true
		end
		return k == "keyword" and (t == "end" or t == "else" or t == "elseif" or t == "until")
	end
	local function closeWithEnd(block)
		if isKw("end") then
			i += 1
		elseif kinds[i] == "eof" then
			block.unterminated = true
		else
			fail("expected 'end'")
		end
	end

	-- ===== types (skipped structurally, kept as text) =====

	local skipType, skipReturnType

	local function skipBalanced(open, close)
		local d = 0
		repeat
			local k, t = kinds[i], texts[i]
			if k == "eof" then
				fail("unterminated bracket")
			end
			if k == "op" then
				if t == open then
					d += 1
				elseif t == close then
					d -= 1
				end
			end
			i += 1
		until d == 0
	end

	local function typeText(first, last)
		if last <= first then
			return nil
		end
		local comments = tokens.comments
		if lines[last - 1] == lines[first] or not comments or #comments == 0 then
			return (gsub(sub(source, starts[first], ends[last - 1]), "%s+", " "))
		end
		-- A multi-line type (a class's `export type` table): rebuild it from the tokens so comments disappear, except
		-- visibility markers, which stay as inline `@@L...` / `@@T...` tokens that Types reads back.
		local lo, hi = 1, #comments + 1
		while lo < hi do
			local mid = (lo + hi) // 2
			if comments[mid].pos > starts[first] then
				hi = mid
			else
				lo = mid + 1
			end
		end
		local ci = lo
		local parts = {}
		for k = first, last - 1 do
			while ci <= #comments and comments[ci].pos < starts[k] do
				local comment = comments[ci]
				local visibility = comment.kind == "line" and Annotations.visibilityOf(comment.text)
				if visibility then
					parts[#parts + 1] = (comment.ownLine and " @@L" or " @@T") .. visibility .. " "
				end
				ci += 1
			end
			if k > first and starts[k] > ends[k - 1] + 1 then
				parts[#parts + 1] = " "
			end
			parts[#parts + 1] = sub(source, starts[k], ends[k])
		end
		return table.concat(parts)
	end

	local function skipSimpleType()
		local k, t = kinds[i], texts[i]
		if k == "op" and t == "(" then
			skipBalanced("(", ")")
			if isOp("->") then
				i += 1
				skipReturnType()
			end
		elseif k == "op" and t == "<" then
			skipBalanced("<", ">")
			if isOp("(") then
				skipBalanced("(", ")")
			end
			if isOp("->") then
				i += 1
				skipReturnType()
			end
		elseif k == "op" and t == "{" then
			skipBalanced("{", "}")
		elseif k == "name" or (k == "keyword" and (t == "nil" or t == "function")) then
			i += 1
			while isOp(".") and kinds[i + 1] == "name" do
				i += 2
			end
			if t == "typeof" and isOp("(") then
				skipBalanced("(", ")")
			elseif isOp("<") then
				skipBalanced("<", ">")
			end
			if isOp("...") then
				i += 1
			end
		elseif k == "string" or (k == "keyword" and (t == "true" or t == "false")) then
			i += 1
		elseif k == "op" and t == "..." then
			i += 1
			skipSimpleType()
		else
			fail("expected type")
		end
	end

	skipType = function()
		if isOp("|") or isOp("&") then
			i += 1
		end
		skipSimpleType()
		while true do
			if isOp("?") then
				i += 1
			elseif isOp("|") or isOp("&") then
				i += 1
				skipSimpleType()
			else
				break
			end
		end
	end

	skipReturnType = function()
		if isOp("(") then
			skipBalanced("(", ")")
			if isOp("->") then
				i += 1
				skipReturnType()
			end
			while isOp("?") do
				i += 1
			end
			while isOp("|") or isOp("&") do
				i += 1
				skipSimpleType()
				while isOp("?") do
					i += 1
				end
			end
		else
			skipType()
		end
	end

	local function parseTypeText()
		local first = i
		skipType()
		return typeText(first, i)
	end

	local function skipAttributes()
		while isOp("@") do
			i += 1
			if isOp("[") then
				skipBalanced("[", "]")
			else
				expectName()
			end
		end
	end

	-- ===== expressions =====

	local parseExpr, parseBlock, parseSuffixedExpr

	local function parseExprList()
		local list = { parseExpr() }
		while acceptOp(",") do
			list[#list + 1] = parseExpr()
		end
		return list
	end

	local function parseFuncBody(startIdx, isMethod, name)
		local generics
		if isOp("<") then
			local genericsFirst = i
			skipBalanced("<", ">")
			generics = {}
			for k = genericsFirst + 1, i - 2 do
				if kinds[k] == "name" and (k == genericsFirst + 1 or (kinds[k - 1] == "op" and texts[k - 1] == ",")) then
					generics[#generics + 1] = texts[k]
				end
			end
		end
		expectOp("(")
		local params, vararg = {}, false
		if isMethod then
			params[1] = { name = "self", implicit = true }
		end
		if not isOp(")") then
			repeat
				if isOp("...") then
					i += 1
					vararg = true
					if acceptOp(":") then
						skipType()
					end
				else
					local pname = expectName()
					local ptype
					if acceptOp(":") then
						ptype = parseTypeText()
					end
					params[#params + 1] = { name = pname, type = ptype }
				end
			until not acceptOp(",")
		end
		expectOp(")")
		local ret
		if acceptOp(":") then
			local first = i
			skipReturnType()
			ret = typeText(first, i)
		end
		local body = parseBlock()
		closeWithEnd(body)
		return {
			k = "Function",
			params = params,
			vararg = vararg,
			ret = ret,
			generics = generics,
			body = body,
			isMethod = isMethod,
			name = name,
			line = lines[startIdx],
			sp = spans and starts[startIdx] or nil,
		}
	end

	-- Keywords that, at the start of a table entry, mean the table was never closed and a new statement began.
	local TABLE_ENDERS = {
		["local"] = true, ["for"] = true, ["while"] = true, ["repeat"] = true, ["return"] = true, ["do"] = true,
		["end"] = true, ["until"] = true, ["else"] = true, ["elseif"] = true,
	}

	--- After a bad entry: advance to the next separator or the table's own closing brace, without consuming it.
	local function skipToSeparator()
		local nesting = 0
		while kinds[i] ~= "eof" do
			local k, t = kinds[i], texts[i]
			if k == "op" then
				if t == "{" or t == "(" or t == "[" then
					nesting += 1
				elseif t == "}" or t == ")" or t == "]" then
					if nesting == 0 then
						return
					end
					nesting -= 1
				elseif (t == "," or t == ";") and nesting == 0 then
					return
				end
			elseif k == "keyword" and nesting == 0 and TABLE_ENDERS[t] and lines[i] > lines[i - 1] then
				return
			end
			i += 1
		end
	end

	-- Table constructors are the one expression that is routinely half-typed in the middle (a config module
	-- being edited), so they recover per entry instead of failing as a whole.
	local function parseTable()
		local startIdx = i
		expectOp("{")
		local entries = {}
		local terminated = false
		while true do
			if isOp("}") then
				i += 1
				terminated = true
				break
			end
			if kinds[i] == "eof" or (kinds[i] == "keyword" and TABLE_ENDERS[texts[i]] and lines[i] > lines[startIdx]) then
				break -- never closed: keep what we have
			end
			local entryIdx = i
			local savedDepth = depth
			local entryCount = #entries
			local ok, res = pcall(function()
				local doc = Lexer.docBefore(tokens, lines[i])
				if kinds[i] == "name" and kinds[i + 1] == "op" and texts[i + 1] == "=" then
					local key = texts[i]
					i += 2
					entries[#entries + 1] = { ty = "named", key = key, value = parseExpr(), doc = doc, line = lines[entryIdx] }
				elseif isOp("[") then
					i += 1
					local keyExpr = parseExpr()
					expectOp("]")
					expectOp("=")
					local value = parseExpr()
					if keyExpr.k == "String" then
						entries[#entries + 1] = { ty = "named", key = keyExpr.v, value = value, doc = doc, line = lines[entryIdx] }
					else
						entries[#entries + 1] = { ty = "keyed", keyExpr = keyExpr, value = value }
					end
				else
					entries[#entries + 1] = { ty = "pos", value = parseExpr() }
				end
			end)
			if not ok then
				depth = savedDepth
				errors[#errors + 1] = {
					msg = type(res) == "table" and res.msg or tostring(res),
					line = lines[entryIdx],
				}
				skipToSeparator()
			elseif not (isOp(",") or isOp(";") or isOp("}")) then
				errors[#errors + 1] = { msg = "expected ',' or '}' in table", line = lines[i] }
				skipToSeparator()
			end
			if i == entryIdx then
				i += 1 -- always make progress
			end
			local separated = acceptOp(",") or acceptOp(";")
			local entry = entries[entryCount + 1]
			if entry and entry.ty == "named" then
				-- `--@Private` above the entry, or at the end of its line (after the comma too)
				local trailing = Lexer.trailingComment(tokens, lines[i - 1] or entry.line) or Lexer.trailingComment(tokens, entry.line)
				entry.doc, entry.tags = Annotations.extract(entry.doc, trailing)
			end
			if not separated and not isOp("}") and kinds[i] == "eof" then
				break
			end
		end
		return { k = "Table", entries = entries, line = lines[startIdx], unterminated = not terminated or nil }
	end

	--- `text {expr} more` -> { k = "Interp", parts = { "text ", <expr node>, " more" } } so known values fold into
	--- a known string (`Addons/{RUN_CONTEXT}` becomes "Addons/Client").
	local function parseInterpolation(raw)
		local body = sub(raw, 2)
		if sub(body, -1) == "`" then
			body = sub(body, 1, -2)
		end
		local parts, buffer = {}, {}
		local position, length = 1, #body
		local function flush()
			if #buffer > 0 then
				parts[#parts + 1] = table.concat(buffer)
				buffer = {}
			end
		end
		while position <= length and #parts < 64 do
			local c = sub(body, position, position)
			if c == "\\" then
				buffer[#buffer + 1] = Lexer.decodeEscapes(sub(body, position, position + 1))
				position += 2
			elseif c == "{" then
				local braces, j = 1, position + 1
				while j <= length and braces > 0 do
					local d = sub(body, j, j)
					if d == "{" then
						braces += 1
					elseif d == "}" then
						braces -= 1
					elseif d == '"' or d == "'" then
						j = string.find(body, d, j + 1, true) or length
					end
					j += 1
				end
				local node = Parser.parseExpression(Lexer.lex(sub(body, position + 1, j - 2)))
				flush()
				parts[#parts + 1] = node or { k = "Unknown" }
				position = j
			else
				buffer[#buffer + 1] = c
				position += 1
			end
		end
		flush()
		return { k = "Interp", parts = parts }
	end

	local function parseCallArgs()
		if isOp("(") then
			i += 1
			local args = {}
			if not isOp(")") then
				args = parseExprList()
			end
			expectOp(")")
			return args
		elseif kinds[i] == "string" then
			local v = values[i]
			local node = { k = "String", v = v }
			if spans then
				node.sp, node.ep = starts[i], ends[i]
			end
			i += 1
			return { node }
		elseif isOp("{") then
			local first = i
			local node = parseTable()
			if spans then
				node.sp, node.ep = starts[first], ends[i - 1]
			end
			return { node }
		elseif kinds[i] == "interp" then
			local raw = texts[i]
			local first = i
			i += 1
			local node = parseInterpolation(raw)
			if spans then
				node.sp, node.ep = starts[first], ends[first]
			end
			return { node }
		end
		fail("expected arguments")
	end

	parseSuffixedExpr = function()
		local firstTok = i -- every a.b / a[b] / a:m() / a() in the chain records where it starts and ends (when spans are on)
		local e
		if kinds[i] == "name" then
			e = { k = "Name", name = texts[i], line = lines[i] }
			i += 1
		elseif isOp("(") then
			i += 1
			local inner = parseExpr()
			expectOp(")")
			e = { k = "Paren", e = inner }
		else
			fail(`unexpected '{texts[i]}'`)
		end
		while true do
			local k, t = kinds[i], texts[i]
			if k == "op" and t == "." then
				i += 1
				local key = expectName()
				e = { k = "Index", base = e, key = key, line = lines[i - 1] }
				if spans then
					e.sp, e.ep = starts[firstTok], ends[i - 1]
				end
			elseif k == "op" and t == "[" then
				i += 1
				local key = parseExpr()
				expectOp("]")
				if key.k == "String" then
					e = { k = "Index", base = e, key = key.v, line = lines[i - 1] }
					if spans then
						e.sp, e.ep = starts[firstTok], ends[i - 1]
					end
				else
					e = { k = "IndexExpr", base = e, key = key, line = lines[i - 1] }
					if spans then
						e.sp, e.ep = starts[firstTok], ends[i - 1]
					end
				end
			elseif k == "op" and t == ":" then
				i += 1
				local method = expectName()
				e = { k = "Call", fn = e, method = method, args = parseCallArgs(), line = lines[i - 1] }
				if spans then
					e.sp, e.ep = starts[firstTok], ends[i - 1]
				end
			elseif (k == "op" and (t == "(" or t == "{")) or k == "string" or k == "interp" then
				e = { k = "Call", fn = e, args = parseCallArgs(), line = lines[i - 1] }
				if spans then
					e.sp, e.ep = starts[firstTok], ends[i - 1]
				end
			else
				break
			end
		end
		return e
	end

	local function parseIfExpr()
		i += 1 -- if
		local cond = parseExpr()
		expectKw("then")
		local a = parseExpr()
		local b
		if isKw("elseif") then
			b = parseIfExpr()
		else
			expectKw("else")
			b = parseExpr()
		end
		return { k = "IfExpr", cond = cond, a = a, b = b }
	end

	local function parseSimpleExpr()
		local k, t = kinds[i], texts[i]
		if k == "number" then
			local v = values[i]
			i += 1
			return { k = "Number", v = v }
		elseif k == "string" then
			local v = values[i]
			i += 1
			return { k = "String", v = v }
		elseif k == "interp" then
			local raw = texts[i]
			i += 1
			return parseInterpolation(raw)
		elseif k == "keyword" then
			if t == "nil" then
				i += 1
				return { k = "Nil" }
			elseif t == "true" then
				i += 1
				return { k = "True" }
			elseif t == "false" then
				i += 1
				return { k = "False" }
			elseif t == "function" then
				local startIdx = i
				i += 1
				return parseFuncBody(startIdx, false, nil)
			elseif t == "if" then
				return parseIfExpr()
			end
			fail(`unexpected '{t}'`)
		elseif k == "op" then
			if t == "..." then
				i += 1
				return { k = "Vararg" }
			elseif t == "{" then
				return parseTable()
			elseif t == "@" then
				skipAttributes()
				return parseSimpleExpr()
			end
		end
		return parseSuffixedExpr()
	end

	local function parseAssertion()
		local e = parseSimpleExpr()
		while isOp("::") do
			i += 1
			local first = i
			skipType()
			e = { k = "Cast", e = e, type = typeText(first, i) }
		end
		return e
	end

	parseExpr = function(limit)
		limit = limit or 0
		local first = i
		depth += 1
		if depth > maxDepth then
			fail("expression nested too deeply")
		end
		local left
		local k, t = kinds[i], texts[i]
		if (k == "keyword" and t == "not") or (k == "op" and (t == "-" or t == "#")) then
			i += 1
			left = { k = "Unary", op = t, e = parseExpr(UNARY_PRIORITY) }
		else
			left = parseAssertion()
		end
		while true do
			k, t = kinds[i], texts[i]
			local priority = (k == "op" or k == "keyword") and BINARY_PRIORITY[t]
			if not priority or priority[1] <= limit then
				break
			end
			i += 1
			left = { k = "Binary", op = t, l = left, r = parseExpr(priority[2]) }
		end
		depth -= 1
		if spans then
			left.sp, left.ep = starts[first], ends[i - 1]
		end
		return left
	end

	-- ===== statements =====

	local function parseLocal(startIdx, doc)
		i += 1 -- local (or const)
		if isKw("function") then
			i += 1
			local name = expectName()
			local fn = parseFuncBody(startIdx, false, name)
			return { k = "LocalFunction", name = name, fn = fn, doc = doc, line = lines[startIdx] }
		end
		local names = {}
		repeat
			local name = expectName()
			local ptype
			if acceptOp(":") then
				ptype = parseTypeText()
			end
			names[#names + 1] = { name = name, type = ptype }
		until not acceptOp(",")
		local vals = {}
		if acceptOp("=") then
			vals = parseExprList()
		end
		return { k = "Local", names = names, values = vals, doc = doc, line = lines[startIdx] }
	end

	local function parseFunctionDecl(startIdx, doc)
		i += 1 -- function
		local path = { expectName() }
		while isOp(".") do
			i += 1
			path[#path + 1] = expectName()
		end
		local method
		if acceptOp(":") then
			method = expectName()
		end
		local fn = parseFuncBody(startIdx, method ~= nil, method or path[#path])
		return { k = "FunctionDecl", path = path, method = method, fn = fn, doc = doc, line = lines[startIdx] }
	end

	local function parseIf(startIdx)
		i += 1
		local clauses, orelse = {}, nil
		local cond = parseExpr()
		expectKw("then")
		clauses[1] = { cond = cond, body = parseBlock() }
		while true do
			if isKw("elseif") then
				i += 1
				local c = parseExpr()
				expectKw("then")
				clauses[#clauses + 1] = { cond = c, body = parseBlock() }
			elseif isKw("else") then
				i += 1
				orelse = parseBlock()
				break
			else
				break
			end
		end
		closeWithEnd(orelse or clauses[#clauses].body)
		return { k = "If", clauses = clauses, orelse = orelse, line = lines[startIdx] }
	end

	local function parseFor(startIdx)
		i += 1
		local first = expectName()
		if isOp("=") then
			i += 1
			local a = parseExpr()
			expectOp(",")
			local b = parseExpr()
			local c
			if acceptOp(",") then
				c = parseExpr()
			end
			expectKw("do")
			local body = parseBlock()
			closeWithEnd(body)
			return { k = "ForNum", var = first, start = a, stop = b, step = c, body = body, line = lines[startIdx] }
		end
		local names = { first }
		if acceptOp(":") then
			skipType()
		end
		while acceptOp(",") do
			names[#names + 1] = expectName()
			if acceptOp(":") then
				skipType()
			end
		end
		expectKw("in")
		local iters = parseExprList()
		expectKw("do")
		local body = parseBlock()
		closeWithEnd(body)
		return { k = "ForIn", names = names, iters = iters, body = body, line = lines[startIdx] }
	end

	local function parseTypeDecl(startIdx, exported)
		if exported then
			i += 1 -- export
		end
		i += 1 -- type
		local name = expectName()
		local generics
		if isOp("<") then
			local genericsFirst = i
			skipBalanced("<", ">")
			generics = typeText(genericsFirst + 1, i - 1)
		end
		expectOp("=")
		local first = i
		skipType()
		return {
			k = "TypeDecl",
			name = name,
			exported = exported,
			generics = generics,
			text = typeText(first, i),
			line = lines[startIdx],
		}
	end

	local function continueFollows(index)
		local k, t = kinds[index], texts[index]
		if k == "eof" or lines[index] > lines[index - 1] then
			return true
		end
		return (k == "keyword" and (t == "end" or t == "else" or t == "elseif" or t == "until")) or (k == "op" and t == ";")
	end

	--- Doc comment above + marker comment on the statement's own first or last line -> node.doc / node.tags.
	local function annotate(node, doc, startIdx)
		local trailing = Lexer.trailingComment(tokens, lines[i - 1] or lines[startIdx]) or Lexer.trailingComment(tokens, lines[startIdx])
		node.doc, node.tags = Annotations.extract(doc, trailing)
		return node
	end

	local function parseExprStatement(startIdx, doc)
		local e = parseSuffixedExpr()
		if isOp("=") or isOp(",") then
			local targets = { e }
			while acceptOp(",") do
				targets[#targets + 1] = parseSuffixedExpr()
			end
			expectOp("=")
			return { k = "Assign", targets = targets, values = parseExprList(), doc = doc, line = lines[startIdx] }
		end
		if kinds[i] == "op" and COMPOUND[texts[i]] then
			local op = COMPOUND[texts[i]]
			i += 1
			return { k = "CompoundAssign", target = e, op = op, value = parseExpr(), line = lines[startIdx] }
		end
		return { k = "ExprStat", e = e, line = lines[startIdx] }
	end

	local function parseStatement()
		local startIdx = i
		local k, t = kinds[i], texts[i]
		if k == "op" then
			if t == ";" then
				i += 1
				return nil
			elseif t == "@" then
				skipAttributes()
				return parseStatement()
			end
		end
		local doc = Lexer.docBefore(tokens, lines[i])
		if k == "keyword" then
			if t == "local" then
				return annotate(parseLocal(startIdx, doc), doc, startIdx)
			elseif t == "function" then
				return annotate(parseFunctionDecl(startIdx, doc), doc, startIdx)
			elseif t == "if" then
				return parseIf(startIdx)
			elseif t == "for" then
				return parseFor(startIdx)
			elseif t == "while" then
				i += 1
				local cond = parseExpr()
				expectKw("do")
				local body = parseBlock()
				closeWithEnd(body)
				return { k = "While", cond = cond, body = body, line = lines[startIdx] }
			elseif t == "repeat" then
				i += 1
				local body = parseBlock()
				local cond
				if isKw("until") then
					i += 1
					cond = parseExpr()
				elseif kinds[i] == "eof" then
					body.unterminated = true
				else
					fail("expected 'until'")
				end
				return { k = "Repeat", body = body, cond = cond, line = lines[startIdx] }
			elseif t == "do" then
				i += 1
				local body = parseBlock()
				closeWithEnd(body)
				return { k = "Do", body = body, line = lines[startIdx] }
			elseif t == "return" then
				i += 1
				local vals = {}
				if not isBlockEnd() and not isOp(";") then
					vals = parseExprList()
				end
				acceptOp(";")
				return { k = "Return", values = vals, line = lines[startIdx] }
			elseif t == "break" then
				i += 1
				return { k = "Break", line = lines[startIdx] }
			end
		elseif k == "name" then
			if t == "const" and (kinds[i + 1] == "name" or (kinds[i + 1] == "keyword" and texts[i + 1] == "function")) then
				return annotate(parseLocal(startIdx, doc), doc, startIdx) -- Luau's `const x = ...` / `const function f()` bind like `local`
			elseif t == "type" and kinds[i + 1] == "name" and (texts[i + 2] == "=" or texts[i + 2] == "<") then
				return parseTypeDecl(startIdx, false)
			elseif t == "export" and texts[i + 1] == "type" and kinds[i + 2] == "name" then
				return parseTypeDecl(startIdx, true)
			elseif t == "continue" and continueFollows(i + 1) then
				i += 1
				return { k = "Continue", line = lines[startIdx] }
			end
		end
		return annotate(parseExprStatement(startIdx, doc), doc, startIdx)
	end

	local STATEMENT_KEYWORDS = {
		["local"] = true, ["function"] = true, ["if"] = true, ["for"] = true,
		["while"] = true, ["repeat"] = true, ["return"] = true, ["do"] = true,
	}

	local function skipToNextLine(failIndex)
		local line = lines[failIndex] or lines[i]
		while kinds[i] ~= "eof" and lines[i] <= line do
			if isBlockEnd() then
				return
			end
			i += 1
		end
	end

	parseBlock = function()
		local stmts = {}
		local block = { k = "Block", stmts = stmts, line = lines[i] }
		while not isBlockEnd() do
			local startIdx = i
			local savedDepth = depth
			local ok, res = pcall(parseStatement)
			if ok then
				if res then
					stmts[#stmts + 1] = res
				end
			else
				depth = savedDepth
				local failIndex = startIdx
				if type(res) == "table" and res.parseError then
					errors[#errors + 1] = { msg = res.msg, line = lines[res.index] or lines[startIdx] }
					failIndex = math.max(res.index or startIdx, startIdx)
				else
					errors[#errors + 1] = { msg = tostring(res), line = lines[startIdx] }
				end
				if i == startIdx then
					i += 1
				end
				-- an unfinished statement followed by a fresh statement keyword on a later line: resume
				-- right there instead of discarding the whole line (`local t = {` then `local x = ...`)
				if type(res) == "table" and res.msg == "unterminated bracket" and kinds[failIndex] == "eof" then
					-- a half-typed annotation (`local x: { a:`) swallowed the rest of the file looking for its closing
					-- bracket: give up on that one line and parse everything after it normally
					i = startIdx
					skipToNextLine(startIdx)
				elseif
					failIndex > startIdx
					and kinds[failIndex] == "keyword"
					and STATEMENT_KEYWORDS[texts[failIndex]]
					and lines[failIndex] > lines[startIdx]
				then
					i = failIndex
				else
					skipToNextLine(failIndex)
				end
			end
		end
		for _, stmt in stmts do
			if stmt.k == "TypeDecl" then
				block.types = block.types or {}
				block.types[#block.types + 1] = stmt -- aliases are visible in the whole block, even above their declaration
			end
		end
		return block
	end

	-- ===== entry =====

	if opts.expression then
		-- a single expression (access chains, interpolation holes): returns the node, or nil if it does not parse
		local ok, node = pcall(parseExpr)
		return ok and node or nil
	end

	local stmts = {}
	local chunk = { k = "Chunk", body = { k = "Block", stmts = stmts, line = 1 }, errors = errors, tokens = tokens }
	while true do
		local block = parseBlock()
		for _, stmt in block.stmts do
			stmts[#stmts + 1] = stmt
		end
		for _, decl in block.types or {} do
			chunk.body.types = chunk.body.types or {}
			chunk.body.types[#chunk.body.types + 1] = decl
		end
		if kinds[i] == "eof" then
			break
		end
		errors[#errors + 1] = { msg = `unexpected '{texts[i]}'`, line = lines[i] }
		i += 1
	end
	return chunk
end

--[[
	opts.maxDepth: nesting limit (default 100)
	opts.limit:    parse only tokens 1 .. limit and treat the rest as end-of-file. Done without copying: the
	               token after `limit` is temporarily patched into an eof sentinel and restored afterwards.
]]
function Parser.parse(tokens, opts)
	local limit = opts and opts.limit
	if not limit or limit >= tokens.n - 1 then
		return parseTokens(tokens, opts)
	end
	local at = limit + 1
	local kinds, texts, values, starts, ends, lines =
		tokens.kinds, tokens.texts, tokens.values, tokens.starts, tokens.ends, tokens.lines
	local savedKind, savedText, savedValue, savedStart, savedEnd, savedLine =
		kinds[at], texts[at], values[at], starts[at], ends[at], lines[at]
	local lastEnd = limit > 0 and ends[limit] or 0
	kinds[at], texts[at], values[at], starts[at], ends[at] = "eof", "", nil, lastEnd + 1, lastEnd
	lines[at] = limit > 0 and lines[limit] or 1
	local ok, result = pcall(parseTokens, tokens, opts)
	kinds[at], texts[at], values[at], starts[at], ends[at], lines[at] = savedKind, savedText, savedValue, savedStart, savedEnd, savedLine
	if not ok then
		error(result, 0)
	end
	return result
end

--- Parses a single expression (used for access chains extracted from the cursor line).
--- Returns the node or nil on failure.
function Parser.parseExpression(tokens, opts)
	local options = { expression = true }
	if opts then
		options.maxDepth = opts.maxDepth
	end
	return parseTokens(tokens, options)
end

return Parser
