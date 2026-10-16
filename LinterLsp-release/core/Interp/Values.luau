--[[
	Values: the abstract values the interpreter computes with. Everything is a plain table with a
	kind in field `k`:

	  unknown            we know nothing (the safe default; never an error)
	  nil                definitely nil
	  bool/number/string optional concrete `v`; a string with `probe = true` is a symbolic argument
	  instance           `inst` (live Instance) and/or `class` (ClassName)
	  table              fields (ordered), arr, idx (indexer for unknown keys), meta (metatable)
	  function           `fn` (AST closure + env) or `native`
	  union              several possibilities, capped
	  thunk              lazy value (module exports, _G members); always read through Values.force
	  varargs / iterator internal helpers
]]

local Budget = require(script.Parent.Parent.Core.Budget)
local Log = require(script.Parent.Parent.Core.Log)

local Values = {}

local MAX_FIELDS = 1500
local MAX_ARRAY = 5000
local MAX_UNION = 8
Values.MAX_FIELDS = MAX_FIELDS
Values.MAX_ARRAY = MAX_ARRAY

Values.Unknown = { k = "unknown" }
Values.Nil = { k = "nil" }
Values.TRUE = { k = "bool", v = true }
Values.FALSE = { k = "bool", v = false }
Values.MAYBE = { k = "bool" }

local Unknown, Nil = Values.Unknown, Values.Nil

local nextId = 0

function Values.bool(v)
	if v == true then
		return Values.TRUE
	elseif v == false then
		return Values.FALSE
	end
	return Values.MAYBE
end

function Values.num(v)
	return { k = "number", v = v }
end

function Values.str(v)
	return { k = "string", v = v }
end

--- A symbolic string: records how it is used as a key so callers can list valid arguments.
function Values.probe()
	return { k = "string", probe = true, domains = {} }
end

function Values.instance(inst, class)
	if inst ~= nil and class == nil then
		local ok, name = pcall(function()
			return inst.ClassName
		end)
		class = ok and name or nil
	end
	return { k = "instance", inst = inst, class = class }
end

function Values.newTable(origin)
	nextId += 1
	return { k = "table", id = nextId, fields = {}, order = {}, arr = {}, origin = origin }
end

function Values.closure(fnNode, env, name, doc)
	return { k = "function", fn = fnNode, env = env, name = name or fnNode.name, doc = doc }
end

function Values.native(name, fn)
	return { k = "function", native = fn, name = name }
end

function Values.thunk(compute)
	return { k = "thunk", compute = compute }
end

function Values.force(v)
	while v.k == "thunk" do
		if v.done then
			v = v.value
		elseif v.running then
			return Unknown
		else
			v.running = true
			local ok, res, transient = pcall(v.compute)
			v.running = false
			if not ok then
				if Budget.isSignal(res) then
					error(res, 0)
				end
				Log.debug("thunk failed: %s", tostring(res))
				v.done, v.value = true, Unknown
				return Unknown
			end
			if transient then
				return Unknown -- a temporary failure (out of budget): not remembered, so a later request tries again
			end
			v.done, v.value = true, res
			v = res
		end
	end
	return v
end

local force = Values.force

-- ===== tables =====

--- While set (to a list), every mutation of a table records an undo closure here. The world uses it
--- so the half-typed script being completed can never leave edits behind in cached module tables.
Values.journal = nil

local function record(undo)
	local journal = Values.journal
	if journal then
		journal[#journal + 1] = undo
	end
end

function Values.setField(t, name, value, info)
	local field = t.fields[name]
	if field then
		if Values.journal then
			local value0, doc0, method0 = field.value, field.doc, field.isMethod
			local tags0, module0 = field.tags, field.module
			record(function()
				field.value, field.doc, field.isMethod = value0, doc0, method0
				field.tags, field.module = tags0, module0
			end)
		end
		field.value = value
		if info then
			field.doc = info.doc or field.doc
			if info.method ~= nil then
				field.isMethod = info.method
			end
			if info.tags then
				field.tags = info.tags -- an explicit declaration with markers wins over earlier ones
				field.module = info.module or field.module
			end
		end
		return
	end
	if #t.order >= MAX_FIELDS then
		t.truncated = true
		return
	end
	t.fields[name] = {
		value = value,
		doc = info and info.doc,
		isMethod = info and info.method or false,
		line = info and info.line,
		tags = info and info.tags, -- `--@Private` & co. (see Language/Annotations)
		module = info and info.module, -- the script whose code declared it
	}
	t.order[#t.order + 1] = name
	record(function()
		t.fields[name] = nil
		local index = table.find(t.order, name)
		if index then
			table.remove(t.order, index)
		end
	end)
end

--- Should a completion list leave this member out for someone editing script `viewer`?
--- `--@Hidden` hides everywhere, `--@Private` outside the declaring script; with `hideUnderscore`, `_names` count as
--- private unless marked `--@Public`.
function Values.hiddenFor(name, field, viewer, hideUnderscore)
	local tags = field.tags
	if tags then
		if tags.hidden then
			return true
		end
		if tags.public then
			return false
		end
		if tags.private and field.module ~= viewer then
			return true
		end
	end
	if hideUnderscore and string.byte(name) == 95 and string.byte(name, 2) ~= 95 and field.module ~= viewer then
		return true
	end
	return false
end

function Values.push(t, value)
	if #t.arr >= MAX_ARRAY then
		t.truncated = true
		return
	end
	t.arr[#t.arr + 1] = value
	record(function()
		for index = #t.arr, 1, -1 do
			if t.arr[index] == value then
				table.remove(t.arr, index)
				return
			end
		end
	end)
end

function Values.setIdx(t, value)
	local old = t.idx
	t.idx = value
	record(function()
		t.idx = old
	end)
end

function Values.setMeta(t, meta)
	local old = t.meta
	t.meta = meta
	record(function()
		t.meta = old
	end)
end

function Values.setArr(t, index, value)
	local old = t.arr[index]
	t.arr[index] = value
	record(function()
		t.arr[index] = old
	end)
end

function Values.clearTable(t)
	t.fields, t.order, t.arr, t.idx = {}, {}, {}, nil
end

--- Own field first, then the metatable's __index chain, then the indexer.
function Values.get(t, key, depth)
	depth = depth or 0
	local field = t.fields[key]
	if field then
		return force(field.value)
	end
	if t.meta and depth < 8 then
		local meta = force(t.meta)
		if meta.k == "table" then
			local indexField = meta.fields.__index
			if indexField then
				local target = force(indexField.value)
				if target.k == "table" and target ~= t then
					local found = Values.get(target, key, depth + 1)
					if found ~= Nil then
						return found
					end
				elseif target.k == "function" then
					-- `Class.__index = function(self, key) return Class[key] ... end` with the class as its own
					-- metatable (the classic Maid shape): the class table is where the members live
					if string.sub(key, 1, 2) ~= "__" then
						local own = meta.fields[key]
						if own then
							return force(own.value)
						end
					end
					return Unknown
				end
			end
		end
	end
	if t.idx then
		return force(t.idx)
	end
	if t.open then
		return Unknown
	end
	return Nil
end

--- Own + inherited members in declaration order. Each entry: { name, field, owner, inherited }.
function Values.members(t)
	local out, seen = {}, {}
	local function walk(tbl, depth)
		for _, name in tbl.order do
			if not seen[name] then
				seen[name] = true
				out[#out + 1] = { name = name, field = tbl.fields[name], owner = tbl, inherited = depth > 0 }
			end
		end
		if depth < 6 and tbl.meta then
			local meta = force(tbl.meta)
			if meta.k == "table" then
				local indexField = meta.fields.__index
				if indexField then
					local target = force(indexField.value)
					if target.k == "table" and target ~= tbl then
						walk(target, depth + 1)
					elseif target.k == "function" and meta ~= tbl then
						walk(meta, depth + 1) -- function __index: the metatable doubles as the class
					end
				end
			end
		end
	end
	walk(t, 0)
	return out
end

-- ===== unions and merging =====

function Values.union(list, maxMembers)
	local members, seen = {}, {}
	local function add(v)
		v = force(v)
		if v.k == "union" then
			for _, m in v.members do
				add(m)
			end
			return
		end
		if v.k == "unknown" or v.k == "nil" then
			return
		end
		local key = v
		if v.k == "table" then
			key = v.id
		elseif v.k == "instance" and v.inst then
			key = v.inst
		end
		if not seen[key] and #members < (maxMembers or MAX_UNION) then
			seen[key] = true
			members[#members + 1] = v
		end
	end
	for _, v in list do
		add(v)
	end
	if #members == 0 then
		return Unknown
	elseif #members == 1 then
		return members[1]
	end
	return { k = "union", members = members }
end

--- Optimistic merge: prefer whichever side knows something.
function Values.merge(a, b)
	a, b = force(a), force(b)
	if a == b then
		return a
	end
	local ka, kb = a.k, b.k
	if ka == "unknown" then
		return b
	end
	if kb == "unknown" then
		return a
	end
	if ka == "nil" then
		return b
	end
	if kb == "nil" then
		return a
	end
	if ka == kb and (ka == "string" or ka == "number" or ka == "bool") then
		if a.v ~= nil and a.v == b.v and not a.probe then
			return a
		end
		if a.probe then
			return a
		elseif b.probe then
			return b
		end
		return { k = ka }
	end
	return Values.union({ a, b })
end

--- true / false / nil (unknown) - Lua truthiness of an abstract value.
function Values.truthy(v)
	v = force(v)
	local k = v.k
	if k == "nil" then
		return false
	elseif k == "unknown" then
		return nil
	elseif k == "bool" then
		return v.v
	elseif k == "union" then
		local result
		for _, m in v.members do
			local t = Values.truthy(m)
			if t == nil then
				return nil
			end
			if result == nil then
				result = t
			elseif result ~= t then
				return nil
			end
		end
		return result
	end
	return true
end

--- true / false / nil for `a == b`.
function Values.equals(a, b)
	a, b = force(a), force(b)
	if a.k == "unknown" or b.k == "unknown" or a.k == "union" or b.k == "union" then
		return nil
	end
	if a == b then
		return a.probe == nil and (a.k ~= "bool" or a.v ~= nil) and true or nil
	end
	if a.k == "nil" or b.k == "nil" then
		return a.k == b.k
	end
	if a.k ~= b.k then
		return false
	end
	local k = a.k
	if k == "string" or k == "number" or k == "bool" then
		if a.v ~= nil and b.v ~= nil then
			return a.v == b.v
		end
		return nil
	elseif k == "instance" then
		if a.inst and b.inst then
			return a.inst == b.inst
		end
		return nil
	end
	return false -- distinct tables / functions
end

function Values.typeName(v, roblox)
	v = force(v)
	local k = v.k
	if k == "nil" then
		return "nil"
	elseif k == "bool" then
		return "boolean"
	elseif k == "number" then
		return "number"
	elseif k == "string" then
		return "string"
	elseif k == "table" then
		return "table"
	elseif k == "function" then
		return "function"
	elseif k == "instance" then
		return roblox and "Instance" or "userdata"
	end
	return nil
end

return Values
