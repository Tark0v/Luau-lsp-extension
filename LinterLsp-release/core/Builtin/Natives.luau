--[[
	Natives: models of Luau / Roblox globals for the interpreter (require, pcall, table.*, Instance.new,
	game, ...). A native is `fn(interp, args) -> Value | {Value...}`. Anything not modelled here
	evaluates to Unknown, which is always safe.
]]

local Values = require(script.Parent.Parent.Interp.Values)

local Natives = {}

local Unknown, Nil = Values.Unknown, Values.Nil
local force = Values.force

--- `next` is a marker so `for k, v in next, t do` can be recognised by the interpreter.
Natives.NEXT = Values.native("next", function()
	return Unknown
end)

local function scalarString(v)
	v = force(v)
	if v.k == "string" and v.v ~= nil and not v.probe then
		return v.v
	elseif v.k == "number" and v.v ~= nil then
		return tostring(v.v)
	end
	return nil
end
Natives.scalarString = scalarString

local function cloneTable(source)
	local copy = Values.newTable(source.origin)
	for _, name in source.order do
		local field = source.fields[name]
		Values.setField(copy, name, field.value, { doc = field.doc, method = field.isMethod, tags = field.tags, module = field.module })
	end
	for _, v in source.arr do
		Values.push(copy, v)
	end
	copy.meta, copy.idx, copy.truncated = source.meta, source.idx, source.truncated
	return copy
end

-- ===== string methods (on known strings; unknown or symbolic strings degrade gracefully) =====

local MAX_STRING = 4000

local function text(s)
	if s.v ~= nil and not s.probe and #s.v <= MAX_STRING then
		return s.v
	end
	return nil
end

local function number(v)
	v = force(v or Unknown)
	if v.k == "number" then
		return v.v
	end
	return nil
end

local STRING_METHODS = {}

--- `path:split("/")`. A SYMBOLIC string (one the engine is probing a function with) yields a symbolic list, so
--- a path-walking custom require can later report the full paths it accepts.
STRING_METHODS.split = function(_, s, args)
	local sep = args[1] and scalarString(args[1]) or ","
	if not sep or sep == "" then
		return Unknown
	end
	if s.probe then
		local t = Values.newTable()
		t.probeSplit = { probe = s, sep = sep }
		return t
	end
	local t = text(s)
	if not t then
		return Unknown
	end
	local out, position = Values.newTable(), 1
	while true do
		local first, last = string.find(t, sep, position, true)
		if not first or #out.arr >= 200 then
			Values.push(out, Values.str(string.sub(t, position)))
			break
		end
		Values.push(out, Values.str(string.sub(t, position, first - 1)))
		position = last + 1
	end
	return out
end

STRING_METHODS.lower = function(_, s)
	local t = text(s)
	return Values.str(t and string.lower(t) or nil)
end
STRING_METHODS.upper = function(_, s)
	local t = text(s)
	return Values.str(t and string.upper(t) or nil)
end
STRING_METHODS.reverse = function(_, s)
	local t = text(s)
	return Values.str(t and string.reverse(t) or nil)
end
STRING_METHODS.len = function(_, s)
	local t = text(s)
	return Values.num(t and #t or nil)
end
STRING_METHODS.sub = function(_, s, args)
	local t, from, to = text(s), number(args[1]), args[2] and number(args[2]) or -1
	if t and from and to then
		return Values.str(string.sub(t, from, to))
	end
	return Values.str(nil)
end
STRING_METHODS.rep = function(_, s, args)
	local t, count = text(s), number(args[1])
	if t and count and #t * math.max(count, 0) <= MAX_STRING then
		return Values.str(string.rep(t, count))
	end
	return Values.str(nil)
end
STRING_METHODS.find = function(_, s, args)
	local t, pattern = text(s), args[1] and scalarString(args[1])
	if not (t and pattern and #pattern <= 200) then
		return Unknown
	end
	local init = args[2] and number(args[2]) or 1
	local plain = args[3] ~= nil and Values.truthy(args[3]) == true
	local ok, first, last = pcall(string.find, t, pattern, init, plain)
	if not ok then
		return Unknown
	end
	if first == nil then
		return Nil
	end
	return { Values.num(first), Values.num(last) }
end
STRING_METHODS.match = function(_, s, args)
	local t, pattern = text(s), args[1] and scalarString(args[1])
	if not (t and pattern and #pattern <= 200) then
		return Unknown
	end
	local results = table.pack(pcall(string.match, t, pattern))
	if not results[1] then
		return Unknown
	end
	if results[2] == nil then
		return Nil
	end
	local out = {}
	for index = 2, results.n do
		out[#out + 1] = type(results[index]) == "string" and Values.str(results[index]) or Values.num(results[index])
	end
	return out
end
STRING_METHODS.format = function(_, s, args)
	local t = text(s)
	if not t then
		return Values.str(nil)
	end
	local scalars = {}
	for index, arg in ipairs(args) do
		local v = force(arg)
		if (v.k == "string" or v.k == "number") and v.v ~= nil and not v.probe then
			scalars[index] = v.v
		else
			return Values.str(nil)
		end
	end
	local ok, result = pcall(string.format, t, table.unpack(scalars, 1, #args))
	return Values.str(ok and result or nil)
end

--- `s` is an already-forced string value. Returns a Value or a list of Values.
function Natives.callStringMethod(interp, s, name, args)
	local handler = STRING_METHODS[name]
	if not handler then
		return Unknown
	end
	return handler(interp, s, args)
end

--- Roblox's require-by-string: "./Sibling", "../Folder/Module" are relative to the requiring script's PARENT, and a
--- folder holding a ModuleScript named init/Init is required through it. Returns the ModuleScript or nil.
local function resolveStringRequire(origin, path)
	if not origin then
		return nil
	end
	if not (path == "." or path == ".." or string.sub(path, 1, 2) == "./" or string.sub(path, 1, 3) == "../") then
		return nil
	end
	local ok, found = pcall(function()
		local dir = origin.Parent
		for segment in string.gmatch(path, "[^/]+") do
			if not dir then
				return nil
			end
			if segment == ".." then
				dir = dir.Parent
			elseif segment ~= "." then
				dir = dir:FindFirstChild(segment)
			end
		end
		if not dir or dir:IsA("ModuleScript") then
			return dir
		end
		return dir:FindFirstChild("init") or dir:FindFirstChild("Init")
	end)
	if ok and found and found:IsA("ModuleScript") then
		return found
	end
	return nil
end

--- Modules are evaluated lazily (only when something uses what they export). While an entry script is being run to learn how the project
--- starts up, `require(Module)` whose result is thrown away still matters: its top level may move instances, fill `_G` or set up a
--- registry. A real game runs it, so the boot does too (still bounded by the boot's own budgets).
local function hasSideEffects(world, inst)
	local ok, text = pcall(function()
		return world.sources:text(inst)
	end)
	if not ok or type(text) ~= "string" then
		return false
	end
	-- only modules that visibly act (reparent / rename things, write _G or shared) are run for their effects; the rest stay lazy,
	-- which is what keeps module lists cheap and their rows reading "module Name"
	return string.find(text, "%.Parent%s*=") ~= nil
		or string.find(text, "%f[%w_]_G%s*%.[%w_]+%s*=") ~= nil
		or string.find(text, "%f[%w_]shared%s*%.[%w_]+%s*=") ~= nil
end

local function requireValue(interp, inst, value)
	if interp.recording and hasSideEffects(interp.world, inst) then
		force(value)
	end
	return value
end

function Natives.install(world, root)
	local function def(name, fn)
		root:declare(name, Values.native(name, fn))
	end

	local function lib(name, entries)
		local t = Values.newTable()
		for key, fn in entries do
			Values.setField(t, key, Values.native(key, fn), { method = false })
		end
		root:declare(name, t)
		return t
	end

	local function constantly(value)
		return function()
			return value
		end
	end

	-- ===== core functions =====

	def("require", function(interp, args)
		local target = force(args[1] or Unknown)
		if target.k == "instance" and target.inst then
			local ok, isModule = pcall(target.inst.IsA, target.inst, "ModuleScript")
			if ok and isModule then
				return requireValue(interp, target.inst, interp.world:moduleValue(target.inst, interp:currentModule()))
			end
		elseif target.k == "string" and target.v ~= nil and not target.probe then
			local resolved = resolveStringRequire(interp:currentModule(), target.v)
			if resolved then
				return requireValue(interp, resolved, interp.world:moduleValue(resolved, interp:currentModule()))
			end
		end
		return Unknown
	end)

	--- pcall(f, ...) -> true, results... ; an error() reached inside f is caught here, not propagated.
	local function protectedCall(interp, fnV, rest)
		local results = interp:call(fnV, rest)
		if interp.halted then
			interp.halted = false -- the error was raised by `fnV` itself (e.g. pcall(error, "x"))
			return { Values.FALSE, Unknown }
		end
		return { Values.TRUE, table.unpack(results) }
	end

	def("pcall", function(interp, args)
		return protectedCall(interp, args[1] or Unknown, { table.unpack(args, 2) })
	end)

	def("xpcall", function(interp, args)
		return protectedCall(interp, args[1] or Unknown, { table.unpack(args, 3) })
	end)

	def("assert", function(interp, args)
		-- Only a literal `false` ends the script. A nil from a lookup (`assert(workspace:FindFirstChild("Settings"))`) usually means
		-- "that instance is added at publish time / by another tool", which the project files do not show; stopping there would
		-- hide everything after it (including the moves and requires that make the rest of the project make sense).
		local first = force(args[1] or Nil)
		if first.k == "bool" and first.v == false then
			interp.halted = true
			return {}
		end
		return args
	end)

	def("error", function(interp)
		interp.halted = true
		return {}
	end)

	def("type", function(_, args)
		return Values.str(Values.typeName(args[1] or Unknown, false))
	end)
	def("typeof", function(_, args)
		return Values.str(Values.typeName(args[1] or Unknown, true))
	end)

	def("tostring", function(_, args)
		local s = scalarString(args[1] or Unknown)
		return Values.str(s)
	end)
	def("tonumber", function(_, args)
		local v = force(args[1] or Unknown)
		if v.k == "number" then
			return v
		elseif v.k == "string" and v.v ~= nil and not v.probe then
			return Values.num(tonumber(v.v))
		end
		return Values.num(nil)
	end)

	def("ipairs", function(_, args)
		return { k = "iterator", mode = "ipairs", source = args[1] or Unknown }
	end)
	def("pairs", function(_, args)
		return { k = "iterator", mode = "pairs", source = args[1] or Unknown }
	end)
	root:declare("next", Natives.NEXT)

	def("select", function(_, args)
		local first = force(args[1] or Unknown)
		if first.k == "string" and first.v == "#" then
			return Values.num(#args - 1)
		elseif first.k == "number" and first.v and first.v >= 1 then
			return { table.unpack(args, first.v + 1) }
		end
		return Unknown
	end)

	def("unpack", function(_, args)
		local t = force(args[1] or Unknown)
		if t.k == "table" then
			return table.clone(t.arr)
		end
		return Unknown
	end)

	def("setmetatable", function(_, args)
		local t = force(args[1] or Unknown)
		if t.k == "table" then
			local mt = args[2] and force(args[2]) or Nil
			Values.setMeta(t, mt.k == "table" and mt or nil)
		end
		return t
	end)
	def("getmetatable", function(_, args)
		local t = force(args[1] or Unknown)
		if t.k == "table" and t.meta then
			return t.meta
		end
		return Nil
	end)
	def("rawget", function(_, args)
		local t, key = force(args[1] or Unknown), scalarString(args[2] or Unknown)
		if t.k == "table" and key then
			local field = t.fields[key]
			return field and field.value or Nil
		end
		return Unknown
	end)
	def("rawset", function(_, args)
		local t, key = force(args[1] or Unknown), scalarString(args[2] or Unknown)
		if t.k == "table" and key then
			Values.setField(t, key, args[3] or Nil)
		end
		return t
	end)
	def("rawequal", constantly(Values.MAYBE))
	def("rawlen", constantly(Values.num(nil)))

	for _, name in { "print", "warn", "wait", "tick", "time", "elapsedTime" } do
		def(name, constantly(Values.num(nil)))
	end

	-- ===== task =====

	local function runDetached(interp, fnV, rest)
		interp.maybe += 1
		interp:call(fnV, rest)
		interp.maybe -= 1
		return Unknown
	end
	lib("task", {
		spawn = function(interp, args)
			return runDetached(interp, args[1] or Unknown, { table.unpack(args, 2) })
		end,
		defer = function(interp, args)
			return runDetached(interp, args[1] or Unknown, { table.unpack(args, 2) })
		end,
		delay = function(interp, args)
			return runDetached(interp, args[2] or Unknown, { table.unpack(args, 3) })
		end,
		wait = constantly(Values.num(nil)),
		cancel = constantly(Nil),
	})
	def("spawn", function(interp, args)
		return runDetached(interp, args[1] or Unknown, { table.unpack(args, 2) })
	end)

	-- ===== table =====

	lib("table", {
		insert = function(_, args)
			local t = force(args[1] or Unknown)
			if t.k == "table" and #args >= 2 then
				Values.push(t, args[#args])
			end
			return {}
		end,
		remove = function(_, args)
			local t = force(args[1] or Unknown)
			if t.k == "table" and #t.arr > 0 then
				return table.remove(t.arr)
			end
			return Unknown
		end,
		clone = function(_, args)
			local t = force(args[1] or Unknown)
			if t.k == "table" then
				return cloneTable(t)
			end
			return Unknown
		end,
		freeze = function(_, args)
			return args[1] or Unknown
		end,
		unpack = function(_, args)
			local t = force(args[1] or Unknown)
			if t.k == "table" then
				return table.clone(t.arr)
			end
			return Unknown
		end,
		pack = function(_, args)
			local t = Values.newTable()
			for _, v in args do
				Values.push(t, v)
			end
			return t
		end,
		find = constantly(Values.num(nil)),
		concat = constantly(Values.str(nil)),
		sort = constantly(Nil),
		clear = constantly(Nil),
		create = function()
			local t = Values.newTable()
			t.open = true
			return t
		end,
		move = function(_, args)
			return args[4] or Unknown
		end,
	})

	-- ===== string / math / os =====

	local unknownString = constantly(Values.str(nil))
	local stringEntries = { gsub = unknownString, char = unknownString, byte = constantly(Unknown), gmatch = constantly(Unknown) }
	for name in STRING_METHODS do
		-- string.lower(s) is the same operation as s:lower()
		stringEntries[name] = function(interp, args)
			local s = force(args[1] or Unknown)
			if s.k ~= "string" then
				return Unknown
			end
			return Natives.callStringMethod(interp, s, name, { table.unpack(args, 2) })
		end
	end
	lib("string", stringEntries)

	local numberFn = constantly(Values.num(nil))
	local mathLib = lib("math", {})
	for _, name in
		{ "abs", "ceil", "floor", "sqrt", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "exp", "log",
			"log10", "max", "min", "random", "randomseed", "sign", "clamp", "round", "noise", "fmod", "pow", "deg", "rad", "modf" }
	do
		Values.setField(mathLib, name, Values.native(name, numberFn), { method = false })
	end
	Values.setField(mathLib, "huge", Values.num(1 / 0))
	Values.setField(mathLib, "pi", Values.num(3.141592653589793))

	lib("os", {
		time = numberFn, clock = numberFn, date = unknownString,
	})

	-- ===== Roblox =====

	lib("Instance", {
		new = function(_, args)
			local class = scalarString(args[1] or Unknown)
			return Values.instance(nil, class)
		end,
	})

	local game = world.host.game
	if game then
		root:declare("game", Values.instance(game))
		local ok, workspaceInstance = pcall(game.FindService, game, "Workspace")
		if ok and workspaceInstance then
			local value = Values.instance(workspaceInstance)
			root:declare("workspace", value)
			root:declare("Workspace", value)
		end
	end

	root:declare("_G", world.gTable)
	root:declare("shared", world.sharedTable)
end

return Natives
