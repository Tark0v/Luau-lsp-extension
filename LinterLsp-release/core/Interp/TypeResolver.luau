--[[
	TypeResolver: turns Luau type annotations (see Language/Types) into abstract Values, so the completion list for
	`local cfg: Config = ...`, `function f(player: Player, opts: Options)` or `expr :: Stack<string>` is the shape
	the annotation promises.

	Where names come from, in order:
	  generic parameter in scope (`T`)      -> unknown (a function's own generics) or the bound argument (`Stack<string>`)
	  type alias in scope                   -> `type X = ...` / `export type X = ...`, hoisted per block, generics bound
	  module-qualified alias                -> `Maid.Maid`: `Maid` is a value from a require; its module's exported aliases
	  primitive                             -> string / number / boolean
	  Roblox class                          -> an instance of that class (members come from ReflectionService)
	  anything else                         -> unknown

	Table-typed fields are lazy: a self-referential type (`type Node = { next: Node? }`) only expands as deep as someone
	navigates. Everything is bounded by depth and by the interpreter's budget; a bad annotation yields nil, never an error.
]]

local Values = require(script.Parent.Values)
local Types = require(script.Parent.Parent.Language.Types)
local Lexer = require(script.Parent.Parent.Language.Lexer)
local Parser = require(script.Parent.Parent.Language.Parser)
local Budget = require(script.Parent.Parent.Core.Budget)

local TypeResolver = {}
TypeResolver.__index = TypeResolver

local Unknown, Nil = Values.Unknown, Values.Nil
local force = Values.force

local MAX_DEPTH = 24
local MAX_FIELDS = 400

local PRIMITIVES = {
	string = function()
		return Values.str(nil)
	end,
	number = function()
		return Values.num(nil)
	end,
	boolean = function()
		return Values.MAYBE
	end,
}

function TypeResolver.new(world)
	return setmetatable({ world = world }, TypeResolver)
end

-- ===== names =====

--- The alias entry `{ decl, scope?, static?, module }` visible under `name`, if any.
function TypeResolver:aliasFor(name, env)
	if env.scope then
		local entry = env.scope:lookupType(name)
		if entry then
			return entry
		end
	end
	if env.static then
		return env.static[name]
	end
	return nil
end

--- The ModuleScript a require'd value came from: lazy thunks remember it, evaluated export tables are stamped with it.
local function moduleOf(value)
	if value.k == "thunk" then
		return value.module
	elseif value.k == "table" then
		return value.moduleScript
	end
	return nil
end

--- Value of the first name of a qualified type (`Maid` in `Maid.Maid`), looked up like a variable.
function TypeResolver:headValue(name, env)
	local scope = env.scope or (env.module and self.world.moduleScopes[env.module])
	if not scope then
		return nil
	end
	return scope:lookup(name)
end

--- The exported alias entry a qualified type name (`Maid.Maid`) points at, or nil.
function TypeResolver:qualifiedEntry(node, env)
	local head = self:headValue(node.path[1], env)
	if not head then
		return nil
	end
	local value = head
	for index = 2, #node.path - 1 do
		value = force(value)
		if value.k ~= "table" then
			return nil
		end
		value = Values.get(value, node.path[index])
	end
	local module = moduleOf(value)
	if not module then
		-- the head may be an already-forced module export that was not stamped; force it once to find out
		module = moduleOf(force(value))
	end
	if not module then
		return nil
	end
	local entry = self.world:typesOf(module)[node.path[#node.path]]
	if entry and entry.decl.exported then
		return entry
	end
	return nil
end

function TypeResolver:convertQualified(node, env)
	local entry = self:qualifiedEntry(node, env)
	if entry then
		return self:convertAlias(entry, node.args, env)
	end
	return Unknown
end

--- The type tree of alias `entry` and the environment to read it in (generic parameters bound to `args`), or nil.
function TypeResolver:expandAlias(entry, args, env)
	local depth = (env.depth or 0) + 1
	if depth > MAX_DEPTH then
		return nil
	end
	local decl = entry.decl
	local body = Types.parse(decl.text)
	if not body then
		return nil
	end
	local module = entry.module
	local inner = {
		scope = entry.scope or (module and self.world.moduleScopes[module]),
		static = entry.static or (module and self.world:typesOf(module)),
		module = module,
		depth = depth,
	}
	if decl.generics then
		local params = Types.parseGenerics(decl.generics)
		if params then
			local bound = {}
			for index, param in params do
				local arg = args and args[index]
				if arg then
					bound[param.name] = { type = arg, env = env } -- an argument means what it means where it was written
				elseif param.default then
					bound[param.name] = { type = param.default, env = inner }
				else
					bound[param.name] = false
				end
			end
			inner.generics = bound
		end
	end
	return body, inner
end

function TypeResolver:convertAlias(entry, args, env)
	local body, inner = self:expandAlias(entry, args, env)
	if not body then
		return Unknown
	end
	return self:convert(body, inner)
end

function TypeResolver:convertName(node, env)
	local path = node.path
	if #path > 1 then
		return self:convertQualified(node, env)
	end
	local name = path[1]
	local generics = env.generics
	if generics then
		local bound = generics[name]
		if bound == false then
			return Unknown
		elseif bound ~= nil then
			local nextEnv = table.clone(bound.env)
			nextEnv.depth = (env.depth or 0) + 1
			if nextEnv.depth > MAX_DEPTH then
				return Unknown
			end
			return self:convert(bound.type, nextEnv)
		end
	end
	local entry = self:aliasFor(name, env)
	if entry then
		return self:convertAlias(entry, node.args, env)
	end
	local primitive = PRIMITIVES[name]
	if primitive then
		return primitive()
	end
	if name == "table" then
		local t = Values.newTable()
		t.open = true
		return t
	end
	local catalog = self.world.catalog
	if catalog and catalog:hasClass(name) then
		return Values.instance(nil, name)
	end
	return Unknown
end

-- ===== shapes =====

--- Cheap to convert right now (no nested structure to expand)?
function TypeResolver:isEager(node, env)
	local k = node.k
	if k == "nil" or k == "lit" or k == "fn" or k == "vararg" or k == "pack" then
		return true
	elseif k == "opt" then
		return self:isEager(node.inner, env)
	elseif k == "name" then
		local name = node.path[1]
		if #node.path > 1 then
			return false
		end
		if env.generics and env.generics[name] ~= nil then
			return false
		end
		return self:aliasFor(name, env) == nil
	end
	return false
end

--- Converts now when cheap, otherwise a thunk that remembers the type text for display.
function TypeResolver:lazy(node, env)
	if self:isEager(node, env) then
		return self:convert(node, env)
	end
	local thunk = Values.thunk(function()
		return self:convert(node, env)
	end)
	thunk.typeText = node.text
	return thunk
end

function TypeResolver:buildTable(node, env)
	local t = Values.newTable()
	t.typed = true
	local count = 0
	for _, field in node.fields do
		count += 1
		if count > MAX_FIELDS then
			t.truncated = true
			break
		end
		local first = field.type.k == "fn" and field.type.params[1]
		local isMethod = first and first.name == "self" or false
		Values.setField(t, field.name, self:lazy(field.type, env), { method = isMethod, tags = field.tags, module = env.module })
	end
	if node.array then
		local element = self:lazy(node.array, env)
		t.arr[1] = element -- one abstract element: loops see one pass, indexing any position gives it
		t.idx = element
	end
	if node.indexer then
		t.idx = self:lazy(node.indexer.value, env)
	end
	return t
end

function TypeResolver:buildFunction(node, env)
	local inner = env
	if node.generics then
		inner = table.clone(env)
		local generics = inner.generics and table.clone(inner.generics) or {}
		for _, name in node.generics do
			generics[name] = false -- the function's own generics are anything
		end
		inner.generics = generics
	end
	local fn = Values.native(nil, function()
		local out = {}
		for index, result in node.ret do
			if index > 4 then
				break
			end
			out[index] = self:convert(result, inner)
		end
		return out
	end)
	fn.typeNode = node
	return fn
end

function TypeResolver:convertTypeof(node, env)
	local scope = env.scope or (env.module and self.world.moduleScopes[env.module])
	if not scope then
		return Unknown
	end
	local expr = Parser.parseExpression(Lexer.lex(node.expr))
	if not expr then
		return Unknown
	end
	local ok, value = Budget.pcall(function()
		return self.world.interp:eval(expr, scope)
	end)
	return ok and value or Unknown
end

function TypeResolver:convert(node, env)
	self.world.budget:tick()
	if (env.depth or 0) > MAX_DEPTH then
		return Unknown
	end
	local k = node.k
	if k == "name" then
		return self:convertName(node, env)
	elseif k == "opt" then
		return self:convert(node.inner, env)
	elseif k == "table" then
		return self:buildTable(node, env)
	elseif k == "fn" then
		return self:buildFunction(node, env)
	elseif k == "union" then
		local list = {}
		for index, member in node.members do
			if index > 8 then
				break
			end
			list[#list + 1] = self:convert(member, env)
		end
		return Values.union(list, self.world.cfg.maxUnion)
	elseif k == "inter" then
		local merged = Values.newTable()
		merged.typed = true
		local any = false
		for _, member in node.members do
			local value = force(self:convert(member, env))
			if value.k == "table" then
				any = true
				for _, name in value.order do
					local field = value.fields[name]
					Values.setField(merged, name, field.value, { method = field.isMethod, tags = field.tags, module = field.module, doc = field.doc })
				end
				merged.idx = merged.idx or value.idx
				merged.meta = merged.meta or value.meta
			end
		end
		return any and merged or Unknown
	elseif k == "lit" then
		if node.vk == "string" then
			return Values.str(node.value)
		end
		return Values.bool(node.value)
	elseif k == "nil" then
		return Nil
	elseif k == "typeof" then
		return self:convertTypeof(node, env)
	end
	return Unknown
end

-- ===== entry points =====

local function baseEnv(self, scope, generics)
	local env = { scope = scope, module = self.world.interp:currentModule(), depth = 0 }
	if generics and #generics > 0 then
		local map = {}
		for _, name in generics do
			map[name] = false
		end
		env.generics = map
	end
	return env
end

--- Value described by type text, or nil when there is nothing useful to say. `scope` resolves aliases and qualified
--- names; `generics` lists the enclosing function's own generic parameter names.
function TypeResolver:valueFor(text, scope, generics)
	local node = Types.parse(text)
	if not node then
		return nil
	end
	local value = self:convert(node, baseEnv(self, scope, generics))
	if value == Unknown then
		return nil
	end
	return value
end

--- Like valueFor for a result type, which may be a pack `(A, B)`: a list of values, or nil.
function TypeResolver:valuesFor(text, scope, generics)
	local node = Types.parse(text)
	if not node then
		return nil
	end
	local env = baseEnv(self, scope, generics)
	local members = node.k == "pack" and node.members or { node }
	local out = {}
	for index, member in members do
		if index > 4 then
			break
		end
		out[index] = self:convert(member, env)
	end
	return out
end

-- ===== what an argument may be written as =====

local PLAIN_KINDS = {
	string = true, number = true, boolean = true, any = true, unknown = true, thread = true, buffer = true, table = true, vector = true,
}
local MAX_SPEC_DEPTH = 10
local MAX_SPEC_MEMBERS = 24

function TypeResolver:collectSpec(node, env, spec, depth)
	if depth > MAX_SPEC_DEPTH then
		spec.open = true
		return
	end
	local k = node.k
	if k == "opt" then
		spec.nilOk = true
		self:collectSpec(node.inner, env, spec, depth + 1)
	elseif k == "nil" then
		spec.nilOk = true
	elseif k == "union" then
		for index, member in node.members do
			if index > MAX_SPEC_MEMBERS then
				spec.open = true
				break
			end
			self:collectSpec(member, env, spec, depth + 1)
		end
	elseif k == "lit" then
		if node.vk == "string" then
			if not table.find(spec.strings, node.value) then
				spec.strings[#spec.strings + 1] = node.value
			end
		else
			spec.kinds.boolean = true
		end
	elseif k == "table" then
		spec.kinds.table = true
	elseif k == "fn" then
		spec.kinds["function"] = true
	elseif k == "name" then
		self:collectName(node, env, spec, depth)
	else
		spec.open = true -- an intersection, `typeof(x)`, a pack: not something this can list
	end
end

function TypeResolver:collectName(node, env, spec, depth)
	local path = node.path
	local entry, args
	if #path > 1 then
		if #path == 2 and path[1] == "Enum" then
			spec.enums[#spec.enums + 1] = path[2]
			return
		end
		entry, args = self:qualifiedEntry(node, env), node.args
		if not entry then
			spec.open = true
		end
	else
		local name = path[1]
		local generics = env.generics
		local bound = generics and generics[name]
		if bound == false then
			spec.kinds.any = true
			return
		elseif bound ~= nil then
			local nextEnv = table.clone(bound.env)
			nextEnv.depth = (env.depth or 0) + 1
			self:collectSpec(bound.type, nextEnv, spec, depth + 1)
			return
		end
		entry, args = self:aliasFor(name, env), node.args
		if not entry then
			if PLAIN_KINDS[name] then
				spec.kinds[name] = true
			elseif self.world.catalog and self.world.catalog:hasClass(name) then
				spec.classes[#spec.classes + 1] = name
			else
				spec.open = true -- a datatype (Vector3), a name this cannot resolve: it may accept anything
			end
			return
		end
	end
	if entry then
		local body, inner = self:expandAlias(entry, args, env)
		if body then
			self:collectSpec(body, inner, spec, depth + 1)
		else
			spec.open = true
		end
	end
end

--- What an argument of this type may be: { strings = { "Fast", "Slow" }, enums = { "KeyCode" }, classes = { "Part" },
--- kinds = { number = true, ... }, nilOk, open }. `open` means part of the type could not be read, so it may accept more than listed. `type` is type text or a tree from Language/Types; aliases are read in `scope`.
--- Nil when the type cannot be read.
function TypeResolver:argumentSpec(type, scope, generics)
	local node = type
	if typeof(type) == "string" then
		node = Types.parse(type)
	end
	if not node then
		return nil
	end
	local spec = { strings = {}, enums = {}, classes = {}, kinds = {}, nilOk = false }
	self:collectSpec(node, baseEnv(self, scope, generics), spec, 0)
	return spec
end

return TypeResolver
