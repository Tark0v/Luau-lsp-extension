--[[
	Checker: squiggles for mistakes Linter can be sure about, through ScriptEditorService:RegisterScriptAnalysisCallback (Studio) or
	publishDiagnostics (the server). It checks what a general analyzer cannot see: functions reached through tables of modules
	built in a loop, custom `require`, registries, things scripts move at run time, hand-written types and `--@param` markers.

	How: the script is parsed with spans, run symbolically (World:checkCalls) together with every function it wrote, and each call
	and each `a.b` read evaluated inside it is judged by what the interpreter knows.

	What counts as wrong (deliberately narrow; a squiggle that is not a bug is worse than a missing one). Every finding must hold
	EVERY time its code is evaluated (loops and branches run it several times); one good evaluation cancels it.

	  Linter.ArgumentType     the argument is CERTAIN to be a string / number / boolean / nil / table / function and the callee is ONE
	                          function whose parameter type was read in full and accepts none of that kind (or is a set of string
	                          literals and the string is not in it).
	  Linter.UnknownMember    `t.nme` / `t:Nme()` on a table whose fields are all known (no metatable, no index signature, not
	                          truncated, not `_G`) when a field with a CLOSE name exists. No close name, no finding.
	  Linter.UnknownChild     `game.ReplicatedStorage.Shard` where the instance has no such property or child, but a child with a
	                          close name exists (children moved there by scripts count).
	  Linter.NotCallable      calling a name whose value is certainly a string / number / boolean.
	  Linter.ArgumentCount    more arguments than the function takes (off by default: `checkArgumentCount`).
	  Linter.MissingChild     WaitForChild("X") where the project files contain no X (off by default: `checkMissingChildren`).
	  Linter.MovedAtRuntime   not shown to the user: marks a read of an instance that a script moves there at run time, so the
	                          proxy can hide luau-lsp's false "not found" for it (`hideMovedErrors`).
]]

local Budget = require(script.Parent.Parent.Core.Budget)
local Log = require(script.Parent.Parent.Core.Log)
local Lexer = require(script.Parent.Parent.Language.Lexer)
local Parser = require(script.Parent.Parent.Language.Parser)
local Values = require(script.Parent.Parent.Interp.Values)
local InstanceApi = require(script.Parent.Parent.Builtin.InstanceApi)
local Arguments = require(script.Parent.Arguments)

local Checker = {}
Checker.__index = Checker

local force = Values.force

local CODE = "Linter.ArgumentType"
local CODE_MEMBER = "Linter.UnknownMember"
local CODE_CHILD = "Linter.UnknownChild"
local CODE_CALL = "Linter.NotCallable"
local CODE_COUNT = "Linter.ArgumentCount"
local CODE_MISSING = "Linter.MissingChild"
local CODE_MOVED = "Linter.MovedAtRuntime"
local WARNING, INFORMATION, HINT = 2, 3, 4 -- LSP severities
local COMPARE = { ["=="] = true, ["~="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true }
local PRIMITIVE_OF = { string = "string", number = "number", bool = "boolean" }
local ARTICLE = { string = "a string", number = "a number", boolean = "a boolean", ["nil"] = "nil", table = "a table", ["function"] = "a function" }
local MAX_TEXT = 80

--- deps: config, world, severity (Enum.Severity item for the squiggles; nil in tests), clock
function Checker.new(deps)
	return setmetatable({
		_config = deps.config,
		_world = deps.world,
		_severity = deps.severity,
		_clock = deps.clock or os.clock,
		_cache = setmetatable({}, { __mode = "k" }), -- script -> { text, epoch, findings }
		_strikes = 0,
		_pausedUntil = 0,
		lastStats = nil,
	}, Checker)
end

--- The kind an argument expression is CERTAIN to have, and its string value when that is known; nil when it is not certain.
local function argumentKind(node, value)
	local k = node.k
	if k == "String" then
		return "string", node.v
	elseif k == "Interp" then
		return "string"
	elseif k == "Number" then
		return "number"
	elseif k == "True" or k == "False" then
		return "boolean"
	elseif k == "Nil" then
		return "nil"
	elseif k == "Table" then
		return "table"
	elseif k == "Function" then
		return "function"
	elseif k == "Paren" then
		return argumentKind(node.e, value)
	elseif k == "Unary" then
		if node.op == "not" then
			return "boolean"
		elseif node.op == "-" and node.e.k == "Number" then
			return "number"
		end
	elseif k == "Binary" then
		if node.op == ".." then
			return "string"
		elseif COMPARE[node.op] then
			return "boolean"
		end
	elseif k == "Name" or k == "Index" or k == "IndexExpr" then
		-- a variable: only when the interpreter has already worked out a plain value (never force a module to find out)
		local v = value
		while v and v.k == "thunk" do
			if not v.done then
				return nil
			end
			v = v.value
		end
		local kind = v and PRIMITIVE_OF[v.k]
		if kind and not v.probe then
			return kind, v.k == "string" and v.v or nil
		end
	end
	return nil
end

local function clip(text)
	if #text <= MAX_TEXT then
		return text
	end
	return string.sub(text, 1, MAX_TEXT - 3) .. "..."
end

--- How many single-character edits turn a into b (small strings only).
local function distance(a, b)
	if #a > 24 or #b > 24 then
		return 99
	end
	local previous = {}
	for j = 0, #b do
		previous[j] = j
	end
	for i = 1, #a do
		local current = { [0] = i }
		for j = 1, #b do
			local cost = string.byte(a, i) == string.byte(b, j) and 0 or 1
			current[j] = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
		end
		previous = current
	end
	return previous[#b]
end

--- The allowed string a mistyped one most likely meant. Short strings get no suggestion: one letter is "close" to every other letter.
local function closest(text, list)
	local best, bestDistance = nil, 3
	for _, candidate in list do
		local d = distance(string.lower(text), string.lower(candidate))
		local near = d == 0 or (d <= (#text >= 5 and 2 or 1) and d < #text and d < #candidate)
		if near and d < bestDistance then
			best, bestDistance = candidate, d
		end
	end
	return best
end
Checker.closest = closest

--- A table whose every field is known: nothing (metatable, index signature, truncation, `_G`, a symbolic path) can supply a name we did not see.
local function closedTable(t)
	return t.k == "table" and #t.order > 0 and not t.open and not t.idx and not t.meta and not t.truncated and not t.isGlobals and not t.probeSplit
end

--- Why `kind` (with `literal`, a known string) cannot go to this parameter, or nil when it can or nobody can tell.
local function mismatch(spec, param, kind, literal)
	if spec.open or spec.kinds.any or spec.kinds.unknown then
		return nil
	end
	local accepted
	if kind == "string" then
		accepted = spec.kinds.string or #spec.strings > 0
	elseif kind == "nil" then
		accepted = spec.nilOk
	else
		accepted = spec.kinds[kind]
	end
	local name = param.name and `'{param.name}'` or "this argument"
	local expected = clip(param.text or "?")
	if not accepted then
		return `{name} expects {expected}, got {ARTICLE[kind]}`
	end
	if kind == "string" and literal and not spec.kinds.string and not table.find(spec.strings, literal) then
		local text = `{name} expects {expected}, got "{clip(literal)}"`
		local suggestion = closest(literal, spec.strings)
		if suggestion then
			text ..= `. Did you mean "{suggestion}"?`
		end
		return text
	end
	return nil
end

--- Every finding in `scriptInst`: a list of { s, e, message, code, severity?, suppress? } (byte offsets in `text`), sorted by position.
--- Raises Budget signals when the script is too big for the allowance; the caller keeps what was found.
function Checker:findings(scriptInst, text, found)
	local world = self._world
	local interp = world.interp
	local config = self._config
	local wantArguments = config:Get("checkArguments")
	local wantMembers = config:Get("checkMembers")
	local wantCount = config:Get("checkArgumentCount")
	local wantMissing = config:Get("checkMissingChildren")
	local wantMoved = config:Get("hideMovedErrors")
	local maxChildren = config:Get("maxChildren")
	local tokens = Lexer.lex(text)
	local chunk = Parser.parse(tokens, { spans = true })
	local records = {} -- node -> { bad = finding|nil, ok = bool }
	local specs = {} -- function node -> parameter index -> spec

	local function record(node)
		local entry = records[node]
		if not entry then
			entry = {}
			records[node] = entry
		end
		return entry
	end
	local function good(node)
		record(node).ok = true
	end
	local function bad(node, finding)
		local entry = record(node)
		entry.bad = entry.bad or finding
	end

	--- Where the member `key` of an `a.b` node sits: its last #key bytes (checked against the text).
	local function keySpan(node, key)
		local s = node.ep - #key + 1
		if s >= 1 and string.sub(text, s, node.ep) == key then
			return s, node.ep
		end
		return node.sp, node.ep
	end

	local function check(node, callee, args)
		local argNodes = node.args
		if node.sp == nil or interp:currentModule() ~= scriptInst then
			return -- not a call written in this script (those carry no spans)
		end
		local methodCall = node.method ~= nil
		local base = methodCall and force(callee) or nil

		-- WaitForChild("X") of something the project files do not contain
		if wantMissing and methodCall and node.method == "WaitForChild" and base.k == "instance" and base.inst and argNodes[1] and argNodes[1].k == "String" then
			local name = argNodes[1].v
			if InstanceApi.hasMember(base.inst, name) or InstanceApi.movedEntry(interp, base.inst, name) then
				good(argNodes)
			else
				bad(argNodes, {
					s = argNodes[1].sp,
					e = argNodes[1].ep,
					message = `'{name}' is not in the project files under {base.inst.Name} (fine if something creates it at run time)`,
					code = CODE_MISSING,
					severity = INFORMATION,
				})
			end
			return
		end

		local fnValue
		if methodCall then
			if base.k ~= "table" then
				return
			end
			fnValue = interp:index(base, node.method)
			if wantMembers and closedTable(base) and base.fields[node.method] == nil then
				local suggestion = closest(node.method, base.order)
				if suggestion then
					local at = string.find(text, ":" .. node.method, node.sp, true)
					bad(node, {
						s = at and at + 1 or node.sp,
						e = at and at + #node.method or node.ep,
						message = `'{node.method}' is not a member here. Did you mean '{suggestion}'?`,
						code = CODE_MEMBER,
						severity = INFORMATION,
					})
					return
				end
			end
		else
			fnValue = callee
		end
		fnValue = force(fnValue)
		if fnValue.k ~= "function" then
			-- a value that is certainly a string / number / boolean is being called
			local kind = PRIMITIVE_OF[fnValue.k]
			local target = node.fn
			if wantMembers and not methodCall and kind and not fnValue.probe and target and (target.k == "Name" or target.k == "Index") then
				local name = target.k == "Name" and target.name or target.key
				bad(node, {
					s = node.sp,
					e = node.ep,
					message = `'{name}' is {ARTICLE[kind]}, not a function`,
					code = CODE_CALL,
					severity = WARNING,
				})
			end
			return -- a union of functions (merged branches), a native, something unknown: no single signature to hold it to
		end
		good(node)
		local info = Arguments.describe(fnValue, methodCall)
		if not info then
			return
		end

		if wantCount and not info.vararg then
			local visible = #info.params - info.first + 1
			local last = argNodes[#argNodes]
			local multi = last ~= nil and (last.k == "Call" or last.k == "Vararg")
			if #argNodes > visible and not multi and argNodes[visible + 1].sp and last.ep then
				bad(argNodes, { -- keyed by the argument list: the call node itself is already marked "was callable"
					s = argNodes[visible + 1].sp,
					e = last.ep,
					message = `takes {visible} argument{visible == 1 and "" or "s"}, but {#argNodes} were passed`,
					code = CODE_COUNT,
					severity = INFORMATION,
				})
			else
				good(argNodes)
			end
		end
		if not wantArguments then
			return
		end

		local fnV = info.fnV
		local owner = fnV.fn or fnV.typeNode
		local perFunction = specs[owner]
		if not perFunction then
			perFunction = {}
			specs[owner] = perFunction
		end
		local count = #argNodes
		for index, argNode in argNodes do
			if index == count and (argNode.k == "Call" or argNode.k == "Vararg") then
				break -- the last argument may stand for several values
			end
			local param = Arguments.parameter(info, index)
			if not param then
				break
			end
			if param.isSelf or param.vararg or not (param.node or param.text) then
				continue
			end
			local kind, literal = argumentKind(argNode, args[index])
			if kind == nil then
				continue
			end
			local position = index + info.first - 1
			local spec = perFunction[position]
			if spec == nil then
				local generics = fnV.fn and fnV.fn.generics or fnV.typeNode and fnV.typeNode.generics
				spec = world.types:argumentSpec(param.node or param.text, fnV.env, generics) or false
				perFunction[position] = spec
			end
			if spec then
				local why = mismatch(spec, param, kind, literal)
				if why then
					bad(argNode, { s = argNode.sp, e = argNode.ep, message = why, code = CODE })
				else
					good(argNode)
				end
			end
		end
	end

	local function watcher(node, callee, args)
		local ok, err = pcall(check, node, callee, args)
		if not ok and Budget.isSignal(err) then
			error(err, 0)
		end
	end

	--- Every `a.b` written in this script, with the value of `a`.
	local function checkIndex(node, baseValue, key)
		if node.sp == nil or interp:currentModule() ~= scriptInst then
			return
		end
		local base = force(baseValue)
		if base.k == "instance" and base.inst then
			local inst = base.inst
			if InstanceApi.hasMember(inst, key) then
				return good(node)
			end
			local s, e = keySpan(node, key)
			if InstanceApi.movedEntry(interp, inst, key) then
				if wantMoved then
					bad(node, {
						s = s,
						e = e,
						message = `'{key}' is moved here at run time by a script`,
						code = CODE_MOVED,
						severity = HINT,
						suppress = key,
					})
				end
				return
			end
			if wantMembers then
				local suggestion = closest(key, InstanceApi.childNames(inst, maxChildren, world.vm and world.vm.moves))
				if suggestion then
					return bad(node, {
						s = s,
						e = e,
						message = `'{key}' is not a child of {inst.Name}. Did you mean '{suggestion}'?`,
						code = CODE_CHILD,
						severity = WARNING,
					})
				end
			end
			return
		end
		if wantMembers and base.k == "table" then
			if closedTable(base) and base.fields[key] == nil then
				local suggestion = closest(key, base.order)
				if suggestion then
					local s, e = keySpan(node, key)
					return bad(node, {
						s = s,
						e = e,
						message = `'{key}' is not a member here. Did you mean '{suggestion}'?`,
						code = CODE_MEMBER,
						severity = INFORMATION,
					})
				end
			end
			good(node)
		end
		return nil
	end

	local function indexWatcher(node, baseValue, key)
		local ok, err = pcall(checkIndex, node, baseValue, key)
		if not ok and Budget.isSignal(err) then
			error(err, 0)
		end
	end

	local ok, signal = pcall(world.checkCalls, world, chunk, scriptInst, watcher, indexWatcher)
	-- whatever was found before a cut-off is still true: only calls that were never reached are missing
	for _, entry in records do
		if entry.bad and not entry.ok then
			found[#found + 1] = entry.bad
		end
	end
	table.sort(found, function(a, b)
		return a.s < b.s
	end)
	if not ok then
		if Budget.isSignal(signal) then
			return found, false
		end
		error(signal, 0)
	end
	return found, true
end

--- Byte offsets -> { line, character } (both 1-indexed, the character counted in bytes like every position the editor API uses).
local function locator(text)
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
	return function(offset)
		local low, high = 1, #starts
		while low < high do
			local middle = (low + high + 1) // 2
			if starts[middle] <= offset then
				low = middle
			else
				high = middle - 1
			end
		end
		return { line = low, character = offset - starts[low] + 1 }
	end
end

--- The analysis callback: `request.script` -> { diagnostics = { ... } }. Never throws, never yields, never takes long.
function Checker:run(request)
	local diagnostics = {}
	local response = { diagnostics = diagnostics }
	local config = self._config
	if not config:Get("enabled") then
		return response
	end
	if not (config:Get("checkArguments") or config:Get("checkMembers") or config:Get("checkArgumentCount") or config:Get("checkMissingChildren") or config:Get("hideMovedErrors")) then
		return response
	end
	local script = request and request.script
	if not script then
		return response
	end
	local world = self._world
	local started = self._clock()
	if started < self._pausedUntil then
		return response -- checks have been slow lately (a huge place being analysed script by script): leave Studio alone for a while
	end
	self.lastStats = nil
	local analysed = false

	local ok, err = pcall(function()
		local okText, text = pcall(world.host.readSource, script)
		if not okText or type(text) ~= "string" or #text > config:Get("maxSourceBytes") or not string.find(text, "(", 1, true) and not string.find(text, ".", 1, true) then
			return
		end
		world:syncEditorText(script, text)
		local cached = self._cache[script]
		local list
		-- what was asked for is part of the answer: switching a check off and on again must not serve the old (empty) list
		local flags = table.concat({ tostring(config:Get("checkArguments")), tostring(config:Get("checkMembers")), tostring(config:Get("checkArgumentCount")), tostring(config:Get("checkMissingChildren")), tostring(config:Get("hideMovedErrors")) }, ",")
		if cached and cached.text == text and cached.epoch == world.epoch and cached.flags == flags then
			list = cached.findings
		else
			analysed = true
			local budget = Budget.new({ fuel = config:Get("fuelPerRequest"), ms = config:Get("checkMs"), clock = self._clock })
			world:beginRequest(budget)
			local found = {}
			local okRun, result, status = Budget.run(function()
				world:bootFor(script) -- so moves / _G made by the project's start-up are part of what the script is checked against
				local _, complete = self:findings(script, text, found)
				return complete
			end)
			world:endRequest()
			if not okRun then
				Log.debug("check of %s failed (%s %s)", script.Name, tostring(status), tostring(result))
			end
			list = found
			if okRun and result then
				self._cache[script] = { text = text, epoch = world.epoch, findings = found, flags = flags } -- a cut-off run is not remembered
			end
		end

		local locate = locator(text)
		for index, finding in list do
			if index > config:Get("maxDiagnostics") then
				break
			end
			local diagnostic = {
				range = { start = locate(finding.s), ["end"] = locate(finding.e + 1) }, -- the end is exclusive, like a textEdit's
				code = finding.code or CODE,
				message = finding.message,
			}
			local severity = finding.severity or self._severity
			if severity then
				diagnostic.severity = severity
			end
			if finding.suppress then
				diagnostic.data = { suppress = finding.suppress }
			end
			diagnostics[#diagnostics + 1] = diagnostic
		end
		self.lastStats = { count = #diagnostics, ms = (self._clock() - started) * 1000 }
	end)
	if analysed then
		local elapsedMs = (self._clock() - started) * 1000
		if elapsedMs > config:Get("slowRequestMs") then
			self._strikes += 1
			if self._strikes >= config:Get("slowRequestStrikes") then
				self._strikes = 0
				self._pausedUntil = started + config:Get("circuitCooldownSeconds")
				Log.warn("checking arguments was slow %d times in a row; pausing for %ds", config:Get("slowRequestStrikes"), config:Get("circuitCooldownSeconds"))
			end
		else
			self._strikes = 0
		end
	end
	if not ok then
		Log.debug("argument check error: %s", tostring(err))
		self.lastStats = { count = 0, error = tostring(err) }
		table.clear(diagnostics)
	elseif Log.debugEnabled and self.lastStats then
		Log.debug("checked %s: %d underline(s) (%.1f ms)", script.Name, self.lastStats.count, self.lastStats.ms)
	end
	return response
end

return Checker
