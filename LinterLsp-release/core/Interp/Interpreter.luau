--[[
	Interpreter: a bounded symbolic evaluator for Luau ASTs.

	It never runs user code. It walks the AST with abstract Values (see Values.luau) against the live
	edit-time DataModel, so `for _, c in folder:GetChildren() do M[c.Name] = require(c) end` really
	produces one field per child, each a lazy module thunk.

	Rules that keep it safe:
	  * every step spends Budget fuel; wall-clock is checked every few steps
	  * unknown conditions run BOTH branches under `maybe` (assignments merge instead of overwrite)
	  * loops over known tables are unrolled up to cfg.maxLoopIterations; otherwise one abstract pass
	  * recursion and call depth are capped; require cycles resolve to Unknown
	  * blocks flagged `unterminated` by the parser (the one holding the cursor) are always entered,
	    and the scope at their end is remembered in `cursorScope`
]]

local Values = require(script.Parent.Values)
local Scope = require(script.Parent.Scope)
local Budget = require(script.Parent.Parent.Core.Budget)
local Log = require(script.Parent.Parent.Core.Log)
local Signature = require(script.Parent.Parent.Language.Signature)
local InstanceApi = require(script.Parent.Parent.Builtin.InstanceApi)
local Natives = require(script.Parent.Parent.Builtin.Natives)

local Interpreter = {}
Interpreter.__index = Interpreter

local Unknown, Nil = Values.Unknown, Values.Nil
local force = Values.force
local truthy = Values.truthy
local scalarString = Natives.scalarString

local EVAL = {}
local EXEC = {}

local function normalize(result)
	if result == nil then
		return {}
	end
	if result.k ~= nil then
		return { result }
	end
	return result
end

local function takesSelf(v)
	return v.k == "function" and v.fn ~= nil and Signature.takesSelf(v.fn)
end

--- Expression nesting we are willing to recurse into; deeper expressions evaluate to Unknown. Keeps
--- pathological input (a 10,000-term chain, 1,000 nested parentheses) from exhausting the Lua stack.
local MAX_EVAL_DEPTH = 160

function Interpreter.new(world)
	return setmetatable({
		world = world,
		cfg = world.cfg,
		budget = world.budget,
		evalDepth = 0,
		loopProduct = 1,
		callDepth = 0,
		callStack = {},
		maybe = 0,
		halted = false,
		haltFatal = true,
		recording = false,
		cursorScope = nil,
		cursorEnabled = true,
		moduleStack = {},
	}, Interpreter)
end

--- The script whose code is executing right now (a function body counts as running inside its DEFINING module).
function Interpreter:currentModule()
	return self.moduleStack[#self.moduleStack]
end

--- A closure that remembers where it was written, so calls to it can be attributed (observed arguments).
function Interpreter:newClosure(fnNode, scope, name, doc, tags)
	local closure = Values.closure(fnNode, scope, name, doc)
	closure.module = self:currentModule()
	closure.tags = tags
	local sink = self.closureSink
	if sink and fnNode.sp ~= nil and closure.module == self.checkModule and #sink < self.cfg.maxCheckedFunctions then
		sink[#sink + 1] = closure -- a function the script being checked wrote: it is run later so its calls are checked too
	end
	return closure
end

--- Makes a block's `type X = ...` aliases visible in `scope` (they apply to the whole block, even above the declaration).
function Interpreter:declareTypes(types, scope)
	local module = self:currentModule()
	for _, decl in ipairs(types) do
		scope:declareType(decl.name, { decl = decl, scope = scope, module = module })
	end
end

function Interpreter:saveState()
	return {
		evalDepth = self.evalDepth,
		loopProduct = self.loopProduct,
		maybe = self.maybe,
		callDepth = self.callDepth,
		callStack = table.clone(self.callStack),
		halted = self.halted,
		haltFatal = self.haltFatal,
		cursorEnabled = self.cursorEnabled,
		modules = #self.moduleStack,
	}
end

function Interpreter:restoreState(state)
	self.evalDepth = state.evalDepth
	self.loopProduct = state.loopProduct
	self.maybe = state.maybe
	self.callDepth = state.callDepth
	self.callStack = state.callStack
	self.halted = state.halted
	self.haltFatal = state.haltFatal
	self.cursorEnabled = state.cursorEnabled
	for index = #self.moduleStack, state.modules + 1, -1 do
		self.moduleStack[index] = nil
	end
end

-- ===== expressions =====

function Interpreter:eval(e, scope)
	self.budget:tick()
	local handler = EVAL[e.k]
	if not handler then
		return Unknown
	end
	local depth = self.evalDepth
	if depth >= MAX_EVAL_DEPTH then
		return Unknown
	end
	self.evalDepth = depth + 1
	local result = handler(self, e, scope)
	self.evalDepth = depth
	return result
end

function Interpreter:evalMulti(exprs, scope)
	local out = {}
	local n = #exprs
	for index = 1, n do
		local e = exprs[index]
		if index == n and e.k == "Call" then
			for _, v in self:evalCall(e, scope) do
				out[#out + 1] = v
			end
		elseif index == n and e.k == "Vararg" then
			local va = scope:lookup("...")
			if va then
				for _, v in va.list do
					out[#out + 1] = v
				end
			end
		else
			out[#out + 1] = self:eval(e, scope)
		end
	end
	return out
end

EVAL.Nil = function()
	return Nil
end
EVAL.True = function()
	return Values.TRUE
end
EVAL.False = function()
	return Values.FALSE
end
EVAL.Number = function(_, e)
	return Values.num(e.v)
end
EVAL.String = function(_, e)
	return Values.str(e.v)
end
EVAL.Interp = function(self, e, scope)
	local parts = e.parts
	if not parts then
		return Values.str(nil)
	end
	local out = {}
	for _, part in ipairs(parts) do
		if type(part) == "string" then
			out[#out + 1] = part
		else
			local text = scalarString(self:eval(part, scope))
			if not text then
				return Values.str(nil) -- one unknown piece makes the whole string unknown
			end
			out[#out + 1] = text
		end
	end
	return Values.str(table.concat(out))
end
EVAL.Vararg = function(_, _, scope)
	local va = scope:lookup("...")
	return va and va.list[1] or Nil
end
EVAL.Name = function(_, e, scope)
	return scope:lookup(e.name) or Unknown
end
EVAL.Paren = function(self, e, scope)
	return self:eval(e.e, scope)
end
EVAL.Cast = function(self, e, scope)
	local v = self:eval(e.e, scope)
	if e.type and (v == Unknown or v == Nil or (v.k == "table" and #v.order == 0 and #v.arr == 0 and not v.meta and not v.idx)) then
		-- `x :: Config` is a promise about the shape; use it when the expression itself tells us nothing
		local typed = self.world:valueForType(e.type, scope)
		if typed and v.k == "table" and typed.k == "table" then
			-- an empty shared table (a `return {}` cache module) keeps its identity: what the cast says it holds is
			-- written onto it, so every other script that requires the module sees it too
			if typed.idx and not v.idx then
				Values.setIdx(v, typed.idx)
			end
			for _, name in typed.order do
				if not v.fields[name] then
					Values.setField(v, name, typed.fields[name].value)
				end
			end
			return v
		end
		return typed or v
	end
	return v
end
EVAL.Function = function(self, e, scope)
	local closure = self:newClosure(e, scope, e.name)
	if e.body.unterminated then
		self:enterUnterminated(closure)
	end
	return closure
end
EVAL.Index = function(self, e, scope)
	local base = self:eval(e.base, scope)
	local result = self:index(base, e.key)
	local watcher = self.indexWatcher -- set only while a script is being checked (Completion/Checker)
	if watcher then
		watcher(e, base, e.key, result)
	end
	return result
end
EVAL.IndexExpr = function(self, e, scope)
	return self:indexByValue(self:eval(e.base, scope), self:eval(e.key, scope))
end
EVAL.Call = function(self, e, scope)
	return self:evalCall(e, scope)[1] or Nil
end

EVAL.Unary = function(self, e, scope)
	local v = self:eval(e.e, scope)
	if e.op == "not" then
		local t = truthy(v)
		if t == nil then
			return Values.MAYBE
		end
		return Values.bool(not t)
	elseif e.op == "-" then
		v = force(v)
		return Values.num(v.k == "number" and v.v and -v.v or nil)
	end
	v = force(v)
	if v.k == "table" and not v.idx and not v.truncated then
		return Values.num(#v.arr)
	elseif v.k == "string" and v.v then
		return Values.num(#v.v)
	end
	return Values.num(nil)
end

local ARITHMETIC = {
	["+"] = function(a, b) return a + b end,
	["-"] = function(a, b) return a - b end,
	["*"] = function(a, b) return a * b end,
	["/"] = function(a, b) return a / b end,
	["%"] = function(a, b) return a % b end,
	["^"] = function(a, b) return a ^ b end,
	["//"] = function(a, b) return a // b end,
}

EVAL.Binary = function(self, e, scope)
	local op = e.op
	if op == "and" then
		local l = self:eval(e.l, scope)
		local t = truthy(l)
		if t == false then
			return l
		elseif t == true then
			return self:eval(e.r, scope)
		end
		return Values.merge(l, self:eval(e.r, scope))
	elseif op == "or" then
		local l = self:eval(e.l, scope)
		local t = truthy(l)
		if t == true then
			return l
		elseif t == false then
			return self:eval(e.r, scope)
		end
		return Values.merge(l, self:eval(e.r, scope))
	end

	local l, r = self:eval(e.l, scope), self:eval(e.r, scope)
	if op == "==" or op == "~=" then
		local eq = Values.equals(l, r)
		if eq == nil then
			return Values.MAYBE
		end
		return Values.bool(op == "==" and eq or (op == "~=" and not eq))
	elseif op == ".." then
		local ls, rs = scalarString(l), scalarString(r)
		if ls and rs then
			return Values.str(ls .. rs)
		end
		return Values.str(nil)
	elseif ARITHMETIC[op] then
		l, r = force(l), force(r)
		if l.k == "number" and l.v and r.k == "number" and r.v then
			local ok, result = pcall(ARITHMETIC[op], l.v, r.v)
			return Values.num(ok and result or nil)
		end
		return Values.num(nil)
	end
	return Values.MAYBE -- < > <= >=
end

EVAL.IfExpr = function(self, e, scope)
	local t = truthy(self:eval(e.cond, scope))
	if t == true then
		return self:eval(e.a, scope)
	elseif t == false then
		return self:eval(e.b, scope)
	end
	return Values.merge(self:eval(e.a, scope), self:eval(e.b, scope))
end

EVAL.Table = function(self, e, scope)
	local t = Values.newTable()
	local entries = e.entries
	local MAX_FIELDS, MAX_ARRAY = Values.MAX_FIELDS, Values.MAX_ARRAY
	for index, entry in ipairs(entries) do
		self.budget:tick()
		if entry.ty == "named" then
			if #t.order >= MAX_FIELDS then
				t.truncated = true -- past the cap nothing is stored, so nothing is worth evaluating
			else
				local v = self:eval(entry.value, scope)
				if v.k == "function" and v.fn and not v.name then
					v.name = entry.key
				end
				if v.k == "function" and v.fn and not v.owner then
					v.owner = t
				end
				Values.setField(t, entry.key, v, {
					doc = entry.doc,
					tags = entry.tags,
					module = self:currentModule(),
					method = takesSelf(v),
					line = entry.line,
				})
			end
		elseif entry.ty == "pos" then
			local valueNode = entry.value
			local kind = valueNode.k
			if #t.arr >= MAX_ARRAY then
				t.truncated = true
			elseif kind == "Number" then
				Values.push(t, Values.num(valueNode.v)) -- plain data: no need to go through eval
			elseif kind == "String" then
				Values.push(t, Values.str(valueNode.v))
			elseif index == #entries and (kind == "Call" or kind == "Vararg") then
				for _, v in self:evalMulti({ valueNode }, scope) do
					Values.push(t, v)
				end
			else
				Values.push(t, self:eval(valueNode, scope))
			end
		else
			local key = force(self:eval(entry.keyExpr, scope))
			local v = self:eval(entry.value, scope)
			if key.k == "string" and key.v and not key.probe then
				Values.setField(t, key.v, v, { method = takesSelf(v) })
			elseif key.k == "number" and key.v == #t.arr + 1 then
				Values.push(t, v)
			else
				t.idx = t.idx and Values.merge(t.idx, v) or v
			end
		end
	end
	return t
end

-- ===== indexing =====

function Interpreter:index(base, key)
	base = force(base)
	local k = base.k
	if k == "table" then
		if base.isGlobals then
			self.world:ensureGlobals()
		end
		return Values.get(base, key)
	elseif k == "instance" then
		return InstanceApi.index(self, base, key)
	elseif k == "union" then
		local out = {}
		for _, member in base.members do
			out[#out + 1] = self:index(member, key)
		end
		return Values.union(out, self.cfg.maxUnion)
	end
	return Unknown
end

--- Every value a table may hold, unforced, as a lazy union (used for unknown / symbolic keys).
local function lazyMembers(self, tbl)
	local list = {}
	for _, name in tbl.order do
		list[#list + 1] = tbl.fields[name].value
		if #list >= 64 then
			break
		end
	end
	for _, v in tbl.arr do
		list[#list + 1] = v
		if #list >= 64 then
			break
		end
	end
	if tbl.idx then
		list[#list + 1] = tbl.idx
	end
	local maxUnion = self.cfg.maxUnion
	return Values.thunk(function()
		return Values.union(list, maxUnion)
	end)
end

function Interpreter:indexByValue(base, keyV)
	keyV = force(keyV)
	base = force(base)
	if keyV.k == "string" and keyV.v ~= nil and not keyV.probe then
		return self:index(base, keyV.v)
	end
	if base.k == "table" then
		if base.isGlobals then
			self.world:ensureGlobals()
		end
		if keyV.k == "number" and keyV.v then
			local v = base.arr[keyV.v]
			if v then
				return v
			end
			return base.idx or Nil
		end
		if keyV.probe then
			InstanceApi.noteDomain(keyV, { kind = "table", table = base })
		end
		return lazyMembers(self, base)
	elseif base.k == "instance" then
		-- `folder[name]` with a symbolic name: children are the valid names
		if keyV.probe and base.inst then
			InstanceApi.noteDomain(keyV, { kind = "children", inst = base.inst, recursive = false })
		end
		return Unknown
	elseif base.k == "union" then
		local out = {}
		for _, member in base.members do
			out[#out + 1] = self:indexByValue(member, keyV)
		end
		return Values.union(out, self.cfg.maxUnion)
	end
	return Unknown
end

function Interpreter:setIndex(base, key, v, info)
	base = force(base)
	if base.k == "table" then
		if base.isGlobals then
			self.world:ensureGlobals() -- populate first, so a write lands on top of what other scripts wrote
		end
		local existing = base.fields[key]
		if existing and self.maybe > 0 and existing.value.k ~= "thunk" and v.k ~= "thunk" then
			v = Values.merge(existing.value, v)
		end
		if v.k == "function" and v.fn then
			v.name = v.name or key
			v.owner = v.owner or base
		end
		Values.setField(base, key, v, info)
	elseif base.k == "instance" then
		InstanceApi.set(self, base, key, v) -- only recorded (Parent / Name); the real tree is never written
	elseif base.k == "union" then
		for _, member in base.members do
			self:setIndex(member, key, v, info)
		end
	end
end

function Interpreter:assignTarget(target, v, scope, doc, tags)
	local k = target.k
	if tags and tags.type and (v == Unknown or v == Nil) then
		v = self.world:valueForType(tags.type, scope) or v -- `--@type Maid` on the line says what it holds
	end
	if k == "Name" then
		if self.maybe > 0 then
			local old = scope:lookup(target.name)
			if old and old.k ~= "thunk" and v.k ~= "thunk" then
				v = Values.merge(old, v)
			end
		end
		if not scope:assign(target.name, v) then
			scope:root():declare(target.name, v)
		end
	elseif k == "Index" then
		self:setIndex(self:eval(target.base, scope), target.key, v, {
			doc = doc,
			tags = tags,
			module = self:currentModule(),
			method = takesSelf(v),
			line = target.line,
		})
	elseif k == "IndexExpr" then
		local base = self:eval(target.base, scope)
		local key = force(self:eval(target.key, scope))
		if key.k == "string" and key.v ~= nil and not key.probe then
			self:setIndex(base, key.v, v, {
				doc = doc,
				tags = tags,
				module = self:currentModule(),
				method = takesSelf(v),
				line = target.line,
			})
			return
		end
		local tbl = force(base)
		if tbl.k ~= "table" then
			return
		end
		if key.k == "number" and key.v then
			if key.v == #tbl.arr + 1 then
				Values.push(tbl, v)
			elseif tbl.arr[key.v] then
				Values.setArr(tbl, key.v, v)
			end
		else
			if key.probe then
				InstanceApi.noteDomain(key, { kind = "table", table = tbl })
			end
			Values.setIdx(tbl, tbl.idx and tbl.idx.k ~= "thunk" and v.k ~= "thunk" and Values.merge(tbl.idx, v) or v)
		end
	end
end

-- ===== calls =====

function Interpreter:evalCall(e, scope)
	self.budget:tick()
	local watcher = self.callWatcher -- set only while a script is being checked (Completion/Checker)
	if e.method then
		local selfV = self:eval(e.fn, scope)
		local args = self:evalMulti(e.args, scope)
		if watcher then
			watcher(e, selfV, args)
		end
		return self:callMethod(selfV, e.method, args)
	end
	local fnV = self:eval(e.fn, scope)
	local args = self:evalMulti(e.args, scope)
	if watcher then
		watcher(e, fnV, args)
	end
	return self:call(fnV, args)
end

function Interpreter:call(fnV, args)
	fnV = force(fnV)
	if fnV.k == "function" then
		if fnV.native then
			local ok, result = Budget.pcall(fnV.native, self, args)
			if not ok then
				Log.debug("native %s failed: %s", tostring(fnV.name), tostring(result))
				return { Unknown }
			end
			return normalize(result)
		end
		return self:callClosure(fnV, args)
	elseif fnV.k == "union" then
		local results, tried = {}, 0
		for _, member in fnV.members do
			if force(member).k == "function" and tried < 3 then
				tried += 1
				results[#results + 1] = self:call(member, args)[1] or Nil
			end
		end
		if #results == 0 then
			return { Unknown }
		end
		return { Values.union(results, self.cfg.maxUnion) }
	end
	return { Unknown }
end

local function collectReturns(sig, vals, frame)
	local candidates = {}
	if sig == "return" and vals then
		candidates[1] = vals
	end
	for _, pending in frame.pending do
		candidates[#candidates + 1] = pending
	end
	if #candidates == 0 then
		return {}
	elseif #candidates == 1 then
		return candidates[1]
	end
	local widest = 0
	for _, c in candidates do
		widest = math.max(widest, #c)
	end
	local merged = {}
	for index = 1, widest do
		local acc
		for _, c in candidates do
			local v = c[index] or Nil
			acc = acc and Values.merge(acc, v) or v
		end
		merged[index] = acc
	end
	return merged
end

Interpreter.collectReturns = collectReturns

--- A function may be active this many times at once. Recursive tree walkers (a collector that descends into
--- sub-folders) need real recursion; runaway recursion is cut off here, by callDepth, and by fuel.
local MAX_RECURSION = 10

function Interpreter:callClosure(fnV, args)
	local fn = fnV.fn
	local active = self.callStack[fn] or 0
	if self.callDepth >= self.cfg.maxCallDepth or active >= MAX_RECURSION then
		return { Unknown }
	end
	self.callStack[fn] = active + 1
	self.callDepth += 1
	local savedCursor = self.cursorEnabled
	self.cursorEnabled = false

	-- while observing, remember what this function is really called with (see World:ensureBooted)
	if self.recording and fnV.module and fnV.name then
		self.world:recordCall(fnV.module, fnV.name, args)
	end
	local definingModule = fnV.module
	if definingModule then
		self.moduleStack[#self.moduleStack + 1] = definingModule
	end

	local scope = Scope.new(fnV.env)
	local tags = fnV.tags
	for index, param in ipairs(fn.params) do
		local arg = args[index] or Nil
		if arg == Unknown and not param.implicit then
			-- an argument we know nothing about: the annotation (or a `--@param` marker) is the next best thing
			local declared = param.type or (tags and tags.params and tags.params[param.name])
			if declared then
				arg = self.world:valueForType(declared, fnV.env, fn.generics) or arg
			end
		end
		scope:declare(param.name, arg)
	end
	local rest = {}
	for index = #fn.params + 1, #args do
		rest[#rest + 1] = args[index]
	end
	scope:declare("...", { k = "varargs", list = rest })

	local frame = { pending = {} }
	local sig, vals = self:execBlock(fn.body, scope, frame)

	if definingModule then
		self.moduleStack[#self.moduleStack] = nil
	end
	self.cursorEnabled = savedCursor
	self.callDepth -= 1
	self.callStack[fn] = active > 0 and active or nil
	local results = collectReturns(sig, vals, frame)
	local declaredReturn = fn.ret or (tags and tags.ret)
	if declaredReturn then
		local first = results[1]
		if first == nil or first == Unknown or first == Nil then
			-- the body could not tell what comes back; the declared return type can
			results = self.world.types:valuesFor(declaredReturn, fnV.env, fn.generics) or results
		elseif first.k == "table" then
			-- the body knows the real shape; the declared type is the public contract, so its `--@Private` fields stay private
			local declared = self.world.types:valuesFor(declaredReturn, fnV.env, fn.generics)
			local shape = declared and declared[1] and force(declared[1])
			if shape and shape.k == "table" then
				for name, shapeField in pairs(shape.fields) do
					local actual = shapeField.tags and first.fields[name]
					if actual then
						actual.tags = shapeField.tags
						actual.module = actual.module or shapeField.module
					end
				end
			end
		end
	end
	return results
end

function Interpreter:callMethod(selfV, name, args)
	local base = force(selfV)
	local k = base.k
	if k == "instance" then
		return InstanceApi.call(self, base, name, args)
	elseif k == "table" then
		local fv = self:index(base, name)
		local full = { selfV }
		for _, a in ipairs(args) do
			full[#full + 1] = a
		end
		return self:call(fv, full)
	elseif k == "union" then
		local results = {}
		for _, member in base.members do
			results[#results + 1] = self:callMethod(member, name, args)[1] or Nil
		end
		return { Values.union(results, self.cfg.maxUnion) }
	elseif k == "string" then
		return normalize(Natives.callStringMethod(self, base, name, args))
	end
	return { Unknown }
end

-- ===== the cursor's function =====

--- For `function Class:method() <cursor>`: a plausible `self` (the constructor's result if we can run it).
function Interpreter:selfValueFor(fnV)
	local owner = fnV.owner and force(fnV.owner)
	if not owner or owner.k ~= "table" then
		return Unknown
	end
	local newField = owner.fields.new
	if newField then
		local constructor = force(newField.value)
		if constructor.k == "function" and constructor.fn then
			local instance = force(self:callClosure(constructor, {})[1] or Unknown)
			if instance.k == "table" then
				return instance
			end
		end
	end
	local t = Values.newTable()
	t.meta = owner
	return t
end

function Interpreter:enterUnterminated(fnV)
	if self.cursorScope then
		return
	end
	local fn = fnV.fn
	local scope = Scope.new(fnV.env)
	for index, param in ipairs(fn.params) do
		local v = Unknown
		if param.implicit and param.name == "self" then
			v = self:selfValueFor(fnV)
		else
			local declared = param.type or (fnV.tags and fnV.tags.params and fnV.tags.params[param.name])
			if declared then
				v = self.world:valueForType(declared, fnV.env, fn.generics) or Unknown
			end
		end
		if v == Unknown and not param.implicit and fnV.module and fnV.name then
			-- an unannotated parameter: whoever calls this function (often a framework) decides what it is
			v = self.world:observedParam(fnV, index) or Unknown
		end
		scope:declare(param.name, v)
	end
	scope:declare("...", { k = "varargs", list = {} })
	local saved = self.cursorEnabled
	self.cursorEnabled = true
	self:execBlock(fn.body, scope, { pending = {} })
	self.cursorEnabled = saved
end

-- ===== statements =====

--- Runs one statement; an internal failure (a shape the evaluator does not expect) costs only that statement.
--- Budget signals pass through untouched: they end the request or the module slice, never a single statement.
function Interpreter:guarded(handler, stmt, scope, frame)
	local evalDepth, maybe, loopProduct = self.evalDepth, self.maybe, self.loopProduct
	local cursorEnabled, callDepth, modules = self.cursorEnabled, self.callDepth, #self.moduleStack
	local ok, sig, vals = pcall(handler, self, stmt, scope, frame)
	if ok then
		return sig, vals
	end
	if Budget.isSignal(sig) then
		error(sig, 0)
	end
	self.evalDepth, self.maybe, self.loopProduct = evalDepth, maybe, loopProduct
	self.cursorEnabled, self.callDepth = cursorEnabled, callDepth
	for index = #self.moduleStack, modules + 1, -1 do
		self.moduleStack[index] = nil
	end
	self.world:noteStatementFailure(self:currentModule(), stmt.line, sig)
	if stmt.k == "Local" then
		for _, name in ipairs(stmt.names) do
			scope:declare(name.name, Unknown) -- later code still sees the name, just without a known value
		end
	end
	return nil
end

function Interpreter:execBlock(block, scope, frame)
	local stmts = block.stmts
	if block.types then
		self:declareTypes(block.types, scope)
	end
	for index = 1, #stmts do
		local stmt = stmts[index]
		self.budget:tick()
		local handler = EXEC[stmt.k]
		local sig, vals
		if handler then
			sig, vals = self:guarded(handler, stmt, scope, frame)
		end
		if self.halted then
			self.halted = false
			if self.haltFatal then
				return "halt"
			end
		end
		if sig then
			return sig, vals
		end
	end
	if block.unterminated and self.cursorEnabled and not self.cursorScope then
		self.cursorScope = scope
	end
	return nil
end

--- Runs a block that executes only conditionally; its returns become candidates, not exits.
local function runMaybe(self, block, scope, frame)
	self.maybe += 1
	local sig, vals = self:execBlock(block, scope, frame)
	self.maybe -= 1
	if sig == "return" and vals then
		frame.pending[#frame.pending + 1] = vals
	end
end

EXEC.Local = function(self, s, scope)
	local vals = self:evalMulti(s.values, scope)
	for index, name in ipairs(s.names) do
		local v = vals[index] or Nil
		local declared = name.type or (index == 1 and s.tags and s.tags.type) -- `local x: T` or a `--@type T` marker
		if declared and (v == Unknown or v == Nil) then
			v = self.world:valueForType(declared, scope) or v
		end
		scope:declare(name.name, v)
	end
end

EXEC.LocalFunction = function(self, s, scope)
	local fnV = self:newClosure(s.fn, scope, s.name, s.doc, s.tags)
	scope:declare(s.name, fnV)
	if s.fn.body.unterminated then
		self:enterUnterminated(fnV)
	end
end

EXEC.FunctionDecl = function(self, s, scope)
	local path = s.path
	local fnV = self:newClosure(s.fn, scope, s.method or path[#path], s.doc, s.tags)
	if #path == 1 and not s.method then
		if not scope:assign(path[1], fnV) then
			scope:root():declare(path[1], fnV)
		end
	else
		local container = scope:lookup(path[1]) or Unknown
		local last = s.method and #path or #path - 1
		for index = 2, last do
			container = self:index(container, path[index])
		end
		self:setIndex(container, s.method or path[#path], fnV, {
			doc = s.doc,
			tags = s.tags,
			module = self:currentModule(),
			method = s.method ~= nil or Signature.takesSelf(s.fn),
			line = s.line,
		})
		fnV.owner = fnV.owner or force(container)
	end
	if s.fn.body.unterminated then
		self:enterUnterminated(fnV)
	end
end

EXEC.Assign = function(self, s, scope)
	local vals = self:evalMulti(s.values, scope)
	for index, target in ipairs(s.targets) do
		self:assignTarget(target, vals[index] or Nil, scope, s.doc, s.tags)
	end
end

EXEC.CompoundAssign = function(self, s, scope)
	self:assignTarget(s.target, s.op == ".." and Values.str(nil) or Values.num(nil), scope)
end

EXEC.ExprStat = function(self, s, scope)
	self:eval(s.e, scope)
end

EXEC.Return = function(self, s, scope)
	return "return", self:evalMulti(s.values, scope)
end

EXEC.Break = function()
	return "break"
end
EXEC.Continue = function()
	return "continue"
end

EXEC.Do = function(self, s, scope, frame)
	return self:execBlock(s.body, Scope.new(scope), frame)
end

EXEC.If = function(self, s, scope, frame)
	local definite = true -- every earlier condition was definitely false
	local taken = false
	for _, clause in ipairs(s.clauses) do
		local t = truthy(self:eval(clause.cond, scope))
		if t == true and definite then
			return self:execBlock(clause.body, Scope.new(scope), frame)
		end
		if t == true or t == nil or clause.body.unterminated then
			definite = false
			runMaybe(self, clause.body, Scope.new(scope), frame)
			if t == true then
				taken = true
				break
			end
		end
	end
	if s.orelse and not taken then
		if definite then
			return self:execBlock(s.orelse, Scope.new(scope), frame)
		end
		runMaybe(self, s.orelse, Scope.new(scope), frame)
	end
end

EXEC.While = function(self, s, scope, frame)
	runMaybe(self, s.body, Scope.new(scope), frame)
end

EXEC.Repeat = function(self, s, scope, frame)
	return self:execBlock(s.body, Scope.new(scope), frame)
end

--- How many iterations a loop may be unrolled for right now. Nested unrolled loops share one budget
--- (cfg.maxLoopBudget) so `for i ... for j ... for k ...` cannot multiply into millions of body runs.
function Interpreter:loopCap()
	return math.max(1, math.min(self.cfg.maxLoopIterations, self.cfg.maxLoopBudget // self.loopProduct))
end

function Interpreter:pairsOf(source, mode)
	local out = {}
	local limit = self:loopCap()
	local split = force(source).probeSplit
	if split then
		-- `for _, part in symbolicPath:split("/")`: one abstract pass whose part remembers where it came from,
		-- so indexing a table with it can list the full paths later
		local part = Values.probe()
		part.domains, part.pathSep = split.probe.domains, split.sep
		return { { Values.num(1), part } }
	end
	local function addTable(t)
		for index, v in ipairs(t.arr) do
			if #out >= limit then
				return
			end
			out[#out + 1] = { Values.num(index), v }
		end
		if mode ~= "ipairs" then
			for _, name in ipairs(t.order) do
				if #out >= limit then
					return
				end
				out[#out + 1] = { Values.str(name), t.fields[name].value }
			end
		end
	end
	source = force(source)
	if source.k == "table" then
		addTable(source)
	elseif source.k == "union" then
		for _, member in source.members do
			member = force(member)
			if member.k == "table" then
				addTable(member)
			end
		end
	else
		return nil
	end
	return out
end

function Interpreter:iterationPairs(iterExprs, scope)
	local vals = self:evalMulti(iterExprs, scope)
	local first = force(vals[1] or Unknown)
	if first.k == "iterator" then
		return self:pairsOf(first.source or Unknown, first.mode)
	elseif first.k == "table" or first.k == "union" then
		return self:pairsOf(first, "pairs")
	elseif first == Natives.NEXT then
		return self:pairsOf(vals[2] or Unknown, "pairs")
	end
	return nil
end

EXEC.ForIn = function(self, s, scope, frame)
	local pairsList = self:iterationPairs(s.iters, scope)
	if pairsList == nil or s.body.unterminated then
		-- one abstract pass; loop variables are the union of what the loop could yield
		local keys, vals = {}, {}
		for _, pair in ipairs(pairsList or {}) do
			keys[#keys + 1] = pair[1]
			vals[#vals + 1] = pair[2]
		end
		local maxUnion = self.cfg.maxUnion
		local keyV = pairsList and Values.thunk(function()
			return Values.union(keys, maxUnion)
		end) or Unknown
		local valueV = pairsList and Values.thunk(function()
			return Values.union(vals, maxUnion)
		end) or Unknown
		local iterScope = Scope.new(scope)
		for index, name in ipairs(s.names) do
			iterScope:declare(name, index == 1 and keyV or (index == 2 and valueV or Unknown))
		end
		runMaybe(self, s.body, iterScope, frame)
		return nil
	end

	local savedProduct = self.loopProduct
	self.loopProduct = savedProduct * math.max(#pairsList, 1)
	for _, pair in ipairs(pairsList) do
		local iterScope = Scope.new(scope)
		iterScope:declare(s.names[1], pair[1])
		if s.names[2] then
			iterScope:declare(s.names[2], pair[2])
		end
		for extra = 3, #s.names do
			iterScope:declare(s.names[extra], Nil)
		end
		local sig, vals = self:execBlock(s.body, iterScope, frame)
		if sig == "break" then
			break
		elseif sig == "return" or sig == "halt" then
			self.loopProduct = savedProduct
			return sig, vals
		end
	end
	self.loopProduct = savedProduct
	return nil
end

EXEC.ForNum = function(self, s, scope, frame)
	local a, b = force(self:eval(s.start, scope)), force(self:eval(s.stop, scope))
	local step = s.step and force(self:eval(s.step, scope)) or Values.num(1)
	local known = a.k == "number" and a.v and b.k == "number" and b.v and step.k == "number" and step.v and step.v ~= 0
	local iterations = known and math.max(0, math.floor((b.v - a.v) / step.v) + 1) or math.huge
	local cap = self:loopCap()
	-- Unroll only when every iteration fits; a loop of a million is one abstract pass, not a truncated lie.
	if known and iterations <= cap and not s.body.unterminated then
		local savedProduct = self.loopProduct
		self.loopProduct = savedProduct * math.max(iterations, 1)
		local i = a.v
		for _ = 1, iterations do
			local iterScope = Scope.new(scope)
			iterScope:declare(s.var, Values.num(i))
			local sig, vals = self:execBlock(s.body, iterScope, frame)
			if sig == "break" then
				break
			elseif sig == "return" or sig == "halt" then
				self.loopProduct = savedProduct
				return sig, vals
			end
			i += step.v
		end
		self.loopProduct = savedProduct
		return nil
	end
	local iterScope = Scope.new(scope)
	iterScope:declare(s.var, Values.num(nil))
	runMaybe(self, s.body, iterScope, frame)
	return nil
end

EXEC.TypeDecl = function() end

return Interpreter
