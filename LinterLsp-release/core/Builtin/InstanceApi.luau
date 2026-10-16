--[[
	InstanceApi: how the interpreter sees live Instances. Property reads go through pcall on the real
	Instance (exact Roblox semantics for free); method calls are a WHITELIST of read-only queries.
	Nothing here can mutate the place, yield, or enumerate without a cap.
]]

local Values = require(script.Parent.Parent.Interp.Values)
local Budget = require(script.Parent.Parent.Core.Budget)
local Log = require(script.Parent.Parent.Core.Log)
local Traversal = require(script.Parent.Parent.Project.Traversal)

local InstanceApi = {}

local Unknown, Nil = Values.Unknown, Values.Nil
local force = Values.force

local MAX_STRING = 2000
local MAX_ANCESTORS = 128

local function fromLua(v)
	local kind = typeof(v)
	if kind == "Instance" then
		return Values.instance(v)
	elseif kind == "string" then
		return Values.str(#v <= MAX_STRING and v or nil)
	elseif kind == "number" then
		return Values.num(v)
	elseif kind == "boolean" then
		return Values.bool(v)
	elseif v == nil then
		return Nil
	end
	return Unknown
end

local function stringArg(args, index)
	local v = force(args[index] or Unknown)
	if v.k == "string" and v.v ~= nil and not v.probe then
		return v.v, v
	end
	return nil, v
end

local function walkOptions(interp)
	local cfg = interp.cfg
	return {
		maxNodes = cfg.maxTraversalNodes,
		maxChildrenPerNode = cfg.maxChildrenPerNode,
		limit = cfg.maxDescendants,
	}
end

--- Records that a symbolic string was used to look something up, so callers can list valid arguments.
function InstanceApi.noteDomain(v, domain)
	if v and v.probe and #v.domains < 16 then
		domain.sep = v.pathSep -- set when the key was one piece of a split path string
		v.domains[#v.domains + 1] = domain
	end
end

-- ===== moves: what scripts reparent at run time =====
--[[
	A script that does `child.Parent = game.ReplicatedStorage` (or clones something and parents the clone) changes the tree
	at run time. The place on disk never does, and nothing here edits it: a move is only RECORDED in the VM the script runs
	in (`vm.moves[parent] = list of { name, inst, class }`), and lookups below consult that record after the real tree.
	The old location stays listed as well - a script that runs before the move is right to use it, and showing both can
	only add a name, never hide a real one. A VM that is discarded or re-booted starts with no moves; moves made by the script
	being completed are undone at the end of the request (Values.journal), like writes to shared tables.
]]
local MAX_MOVES = 2000

local function movesOf(interp)
	local world = interp and interp.world
	local vm = world and world.vm
	return vm and vm.moves
end

--- The record for `parent` as a list (or nil). `moves` is the VM's table.
function InstanceApi.movedChildren(moves, parent)
	return moves and parent and moves[parent] or nil
end

local function movedNamed(interp, inst, name)
	local list = InstanceApi.movedChildren(movesOf(interp), inst)
	if list then
		for index = #list, 1, -1 do
			if list[index].name == name then
				return list[index]
			end
		end
	end
	return nil
end

local function movedValue(entry)
	if entry.inst then
		return Values.instance(entry.inst)
	end
	return Values.instance(nil, entry.class)
end

--- `child.Parent = parent`: remember that `child` is now listed under `parent`.
function InstanceApi.recordMove(interp, childV, parentV)
	local moves = movesOf(interp)
	childV, parentV = force(childV), force(parentV)
	if not moves or childV.k ~= "instance" or parentV.k ~= "instance" or not parentV.inst then
		return
	end
	local origin = childV.inst or childV.cloneOf
	local name = childV.nameOverride or (childV.inst and moves.__names and moves.__names[childV.inst])
	if name == nil and origin then
		local ok, found = pcall(function()
			return origin.Name
		end)
		name = ok and found or nil
	end
	if type(name) ~= "string" or name == "" then
		return
	end
	local list = moves[parentV.inst]
	if not list then
		list = {}
		moves[parentV.inst] = list
	end
	if #list >= MAX_MOVES then
		return
	end
	local entry = { name = name, inst = origin, class = childV.class or "Instance" }
	list[#list + 1] = entry
	local journal = Values.journal
	if journal then
		journal[#journal + 1] = function()
			local at = table.find(list, entry)
			if at then
				table.remove(list, at)
			end
		end
	end
end

--- `inst.Parent = x` / `inst.Name = x` on an instance value. Nothing is written to a real Instance.
function InstanceApi.set(interp, v, key, value)
	if key == "Parent" then
		InstanceApi.recordMove(interp, v, value)
	elseif key == "Name" then
		local text = force(value)
		if text.k == "string" and text.v ~= nil and not text.probe then
			v.nameOverride = text.v
			local moves = movesOf(interp)
			if moves and v.inst then
				-- remembered per instance (the same instance is reached through many separate evaluations of a path), and applied to
				-- the places it was already moved to: `x.Parent = rs` then `rs.X.Name = "Y"`
				moves.__names = moves.__names or {}
				local oldName = moves.__names[v.inst]
				moves.__names[v.inst] = text.v
				local renamed = {}
				for key, list in moves do
					if key ~= "__names" then
						for _, entry in list do
							if entry.inst == v.inst then
								renamed[#renamed + 1] = { entry = entry, before = entry.name }
								entry.name = text.v
							end
						end
					end
				end
				local journal = Values.journal
				if journal then
					journal[#journal + 1] = function()
						moves.__names[v.inst] = oldName
						for _, item in renamed do
							item.entry.name = item.before
						end
					end
				end
			end
		end
	end
end

function InstanceApi.index(interp, v, key)
	local inst = v.inst
	if inst == nil then
		return Unknown
	end
	local ok, result = pcall(function()
		return inst[key]
	end)
	if not ok or result == nil then
		local moved = movedNamed(interp, inst, key)
		if moved then
			return movedValue(moved)
		end
	end
	if not ok then
		return Unknown
	end
	return fromLua(result)
end

local METHODS = {}

METHODS.GetChildren = function(interp, inst)
	local list, truncated = Traversal.children(inst, interp.cfg.maxChildren)
	interp.budget:tick(1 + #list // 16)
	local t = Values.newTable()
	for _, child in list do
		Values.push(t, Values.instance(child))
	end
	for _, entry in InstanceApi.movedChildren(movesOf(interp), inst) or {} do
		if #t.arr < interp.cfg.maxChildren then
			Values.push(t, movedValue(entry))
		end
	end
	t.truncated = truncated
	return t
end

METHODS.GetDescendants = function(interp, inst)
	local list, truncated = Traversal.descendants(inst, walkOptions(interp))
	interp.budget:tick(1 + #list // 8)
	local t = Values.newTable()
	for _, child in list do
		Values.push(t, Values.instance(child))
	end
	t.truncated = truncated
	return t
end

METHODS.FindFirstChild = function(interp, inst, args)
	local name, symbolic = stringArg(args, 1)
	local recursive = Values.truthy(args[2] or Nil) == true
	if not name then
		InstanceApi.noteDomain(symbolic, { kind = "children", inst = inst, recursive = recursive })
		return Unknown
	end
	if recursive then
		local found = Traversal.findNamed(inst, name, walkOptions(interp))
		return found and Values.instance(found) or Nil
	end
	local ok, found = pcall(inst.FindFirstChild, inst, name)
	if ok and found then
		return Values.instance(found)
	end
	local moved = movedNamed(interp, inst, name)
	return moved and movedValue(moved) or Nil
end

METHODS.WaitForChild = function(interp, inst, args)
	local result = METHODS.FindFirstChild(interp, inst, { args[1] or Unknown })
	if result == Nil then
		return Unknown -- it may simply not exist yet at edit time
	end
	return result
end

local function firstChildMatching(interp, inst, args, exact)
	local className = stringArg(args, 1)
	if not className then
		return Unknown
	end
	local list = Traversal.children(inst, interp.cfg.maxChildren)
	for _, child in list do
		local matches
		if exact then
			matches = child.ClassName == className
		else
			local ok, isA = pcall(child.IsA, child, className)
			matches = ok and isA
		end
		if matches then
			return Values.instance(child)
		end
	end
	return Nil
end

METHODS.FindFirstChildOfClass = function(interp, inst, args)
	return firstChildMatching(interp, inst, args, true)
end
METHODS.FindFirstChildWhichIsA = function(interp, inst, args)
	return firstChildMatching(interp, inst, args, false)
end

local function ancestorMatching(inst, test)
	local current = inst.Parent
	for _ = 1, MAX_ANCESTORS do
		if current == nil then
			return Nil
		end
		if test(current) then
			return Values.instance(current)
		end
		current = current.Parent
	end
	return Nil
end

METHODS.FindFirstAncestor = function(_, inst, args)
	local name = stringArg(args, 1)
	if not name then
		return Unknown
	end
	return ancestorMatching(inst, function(a)
		return a.Name == name
	end)
end
METHODS.FindFirstAncestorOfClass = function(_, inst, args)
	local className = stringArg(args, 1)
	if not className then
		return Unknown
	end
	return ancestorMatching(inst, function(a)
		return a.ClassName == className
	end)
end
METHODS.FindFirstAncestorWhichIsA = function(_, inst, args)
	local className = stringArg(args, 1)
	if not className then
		return Unknown
	end
	return ancestorMatching(inst, function(a)
		local ok, isA = pcall(a.IsA, a, className)
		return ok and isA
	end)
end

METHODS.IsA = function(_, inst, args)
	local className = stringArg(args, 1)
	if not className then
		return Values.MAYBE
	end
	local ok, result = pcall(inst.IsA, inst, className)
	return ok and Values.bool(result) or Values.MAYBE
end

METHODS.IsDescendantOf = function(_, inst, args)
	local other = force(args[1] or Unknown)
	if other.k ~= "instance" or not other.inst then
		return Values.MAYBE
	end
	local ok, result = pcall(inst.IsDescendantOf, inst, other.inst)
	return ok and Values.bool(result) or Values.MAYBE
end

METHODS.IsAncestorOf = function(_, inst, args)
	local other = force(args[1] or Unknown)
	if other.k ~= "instance" or not other.inst then
		return Values.MAYBE
	end
	local ok, result = pcall(inst.IsAncestorOf, inst, other.inst)
	return ok and Values.bool(result) or Values.MAYBE
end

METHODS.GetFullName = function(_, inst)
	local ok, name = pcall(inst.GetFullName, inst)
	return fromLua(ok and name or nil)
end

METHODS.GetAttribute = function(_, inst, args)
	local name = stringArg(args, 1)
	if not name then
		return Unknown
	end
	local ok, value = pcall(inst.GetAttribute, inst, name)
	return ok and fromLua(value) or Unknown
end

--- FindService, never GetService: GetService creates a service that does not exist yet, which would be a
--- (tiny) write to the place. A service that is not there is simply unknown.
local function service(_, inst, args)
	local name = stringArg(args, 1)
	if not name then
		return Unknown
	end
	local ok, found = pcall(inst.FindService, inst, name)
	return (ok and found) and Values.instance(found) or Unknown
end
METHODS.GetService = service
METHODS.FindService = service

--- Returns a list of result values for `inst:name(args)`.
function InstanceApi.call(interp, v, name, args)
	local handler = METHODS[name]
	local inst = v.inst
	if not inst then
		-- symbolic instance (Instance.new / Clone): we only know its class
		if name == "Clone" then
			local copy = Values.instance(nil, v.class)
			copy.cloneOf, copy.nameOverride = v.cloneOf, v.nameOverride
			return { copy }
		end
		return { Unknown }
	end
	if name == "Clone" then
		-- a copy of a real instance is a new instance that remembers where it came from, so a move of the copy can be listed
		local copy = Values.instance(nil, v.class)
		copy.cloneOf, copy.nameOverride = inst, v.nameOverride
		return { copy }
	end
	if not handler then
		return { Unknown }
	end
	local ok, result = Budget.pcall(handler, interp, inst, args)
	if not ok then
		Log.debug("InstanceApi.%s failed: %s", name, tostring(result))
		return { Unknown }
	end
	return { result }
end

--- Child names and classes of an instance, capped. Used for completion lists.
--- Attribute names set on a real instance, sorted: { { name, type } ... }. Read-only.
function InstanceApi.attributeEntries(inst, cap)
	local ok, attributes = pcall(inst.GetAttributes, inst)
	local out = {}
	if ok and type(attributes) == "table" then
		for name, value in attributes do
			if type(name) == "string" then
				out[#out + 1] = { name = name, type = typeof(value) }
			end
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	while #out > cap do
		out[#out] = nil
	end
	return out
end

-- CollectionService.GetAllTags also lists the tags Studio puts on its own interface (CoreGui, plugin panels ...).
local STUDIO_UI = { CoreGui = true, PluginGuiService = true, CorePackages = true }
local INTERNAL_TAG = { "^_", "^data%-", "^TagEditor", "^RigEdit", "^Theme_", "^VFXStudio", "^gui%-", "^size%-" }
local MAX_TAGGED_CHECKED = 2000

--- Does something in the user's place carry this tag (as opposed to only Studio's own windows)?
local function inUserPlace(instance, game)
	local node, below = instance, nil
	for _ = 1, 64 do
		local parent = node.Parent
		if parent == nil or parent == game then
			-- `node` is a service (its parent is the DataModel) or the DataModel itself (`below` is then the service)
			local service = parent == nil and below or node
			return not (service and STUDIO_UI[service.Name])
		end
		below, node = node, parent
	end
	return true
end

--- Tags worth offering: every tag applied to something in the place, plus tags that exist but are applied to nothing yet (defined
--- in the Tag Editor) unless they look like Studio's own. Without CollectionService, only the tags on `inst`. Read-only.
function InstanceApi.tagNames(game, inst, cap)
	local names, seen = {}, {}
	local function add(list)
		if type(list) == "table" then
			for _, name in list do
				if type(name) == "string" and not seen[name] then
					seen[name] = true
					names[#names + 1] = name
				end
			end
		end
	end
	local okService, service = pcall(game.FindService, game, "CollectionService")
	if okService and service then
		local ok, all = pcall(service.GetAllTags, service)
		if ok and type(all) == "table" then
			local mine = {}
			for _, name in all do
				if type(name) == "string" then
					local keep
					local gotten, tagged = pcall(service.GetTagged, service, name)
					if gotten and type(tagged) == "table" and #tagged > 0 then
						keep = false
						for index = 1, math.min(#tagged, MAX_TAGGED_CHECKED) do
							if inUserPlace(tagged[index], game) then
								keep = true
								break
							end
						end
					else
						keep = true
						for _, pattern in INTERNAL_TAG do
							if string.find(name, pattern) then
								keep = false
								break
							end
						end
					end
					if keep then
						mine[#mine + 1] = name
					end
				end
			end
			add(mine)
		end
	end
	if inst then
		local ok, own = pcall(inst.GetTags, inst)
		if ok then
			add(own)
		end
	end
	table.sort(names)
	while #names > cap do
		names[#names] = nil
	end
	return names
end

--- `moves` (the VM's record, optional) adds what scripts parent here at run time; those entries may have no `inst`.
function InstanceApi.childEntries(inst, cap, moves)
	local list = Traversal.children(inst, cap)
	local out = {}
	local seen = {}
	for _, child in list do
		out[#out + 1] = { name = child.Name, class = child.ClassName, inst = child }
		seen[child.Name] = true
	end
	for _, entry in InstanceApi.movedChildren(moves, inst) or {} do
		if not seen[entry.name] and #out < cap then
			seen[entry.name] = true
			local class = entry.class
			if entry.inst then
				local ok, found = pcall(function()
					return entry.inst.ClassName
				end)
				class = ok and found or class
			end
			out[#out + 1] = { name = entry.name, class = class, inst = entry.inst, moved = true }
		end
	end
	return out
end

--- Is `key` something `inst` really has (a property or a child)? Read-only.
function InstanceApi.hasMember(inst, key)
	local ok, result = pcall(function()
		return inst[key]
	end)
	return ok and result ~= nil
end

--- The moved-at-run-time entry named `key` under `inst`, or nil (see the moves section above).
function InstanceApi.movedEntry(interp, inst, key)
	return movedNamed(interp, inst, key)
end

--- Names of the children of `inst` (the real ones, then the ones scripts move there), capped.
function InstanceApi.childNames(inst, cap, moves)
	local names = {}
	for _, entry in InstanceApi.childEntries(inst, cap, moves) do
		names[#names + 1] = entry.name
	end
	return names
end

return InstanceApi
