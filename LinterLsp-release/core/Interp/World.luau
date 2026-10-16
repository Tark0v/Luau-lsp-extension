--[[
	World: one interpreter plus everything it caches.

	  * module exports: a lazy thunk per ModuleScript, plus a reverse-dependency map so editing one
	    module drops exactly the modules that required it (and nothing else)
	  * two "VMs", server and client, each with its own module cache. A VM is BOOTED once: the project's entry scripts
	    of that kind (Scripts / LocalScripts) run symbolically INSIDE its cache, so what they do at start-up
	    (`GRequire._Addition("Workspace", ...)`, registries filled by `Launch`) is part of the world completions see, and
	    the arguments they hand to functions (`Init(maid)`) are recorded. See `ensureBooted`.
	  * _G / shared: shared open tables, populated on first use by running (symbolically) the scripts
	    that mention them
	  * the current (half-typed) script is never cached; it is re-run for every request

	The World outlives requests. `beginRequest` installs a fresh Budget and resets interpreter state
	that an aborted previous request may have left behind.
]]

local Budget = require(script.Parent.Parent.Core.Budget)
local Log = require(script.Parent.Parent.Core.Log)
local Natives = require(script.Parent.Parent.Builtin.Natives)
local Traversal = require(script.Parent.Parent.Project.Traversal)
local Values = require(script.Parent.Values)
local Scope = require(script.Parent.Scope)
local Interpreter = require(script.Parent.Interpreter)
local TypeResolver = require(script.Parent.TypeResolver)
local Shape = require(script.Parent.Parent.Language.Shape)

local World = {}
World.__index = World

local Unknown, Nil = Values.Unknown, Values.Nil
local force = Values.force

--- deps: config (Core.Config), host, sources (SourceStore), catalog (ClassCatalog|nil), registry (Registry|nil)
function World.new(deps)
	local self = setmetatable({}, World)
	self.config = deps.config
	self.cfg = deps.config:Snapshot()
	self.host = deps.host
	self.sources = deps.sources
	self.catalog = deps.catalog
	self.registry = deps.registry
	self.budget = Budget.new({ fuel = self.cfg.fuelPerRequest, ms = self.cfg.requestBudgetMs, clock = deps.host.clock })

	self.moduleTypes = {} -- script -> name -> alias entry, read from the source without running it (kind independent)
	self.vms = { server = World.newVm("server"), client = World.newVm("client") }
	self.vm = nil -- the VM the script being completed belongs to; modules/rdeps/moduleScopes/observed point into it
	self:_bind(self.vms.server)
	self.shapeDirty = false -- the script being edited changed; its top-level shape may differ from the one the VM was booted under
	self.editing = nil -- the script the editor just reported a change in (it counts as "current" before the next request says so)
	self.problems = {} -- script -> why its analysis is incomplete (shown by the Report button)
	self.slowUntil = {} -- script -> clock time before which a module that ran out of time is not tried again
	self.contributing = {} -- module -> true while other modules' writes into its table are being gathered (no re-entry)
	self.currentScript = nil -- the script being completed
	self.epoch = 0 -- counts invalidations: an analysis result is good until it changes (see Completion/Checker)
	self.globalsLoaded = false
	self.gTable = Values.newTable()
	self.gTable.isGlobals, self.gTable.open = true, true
	self.sharedTable = Values.newTable()
	self.sharedTable.isGlobals, self.sharedTable.open = true, true

	self.root = Scope.new(nil)
	self.interp = Interpreter.new(self)
	self.types = TypeResolver.new(self)
	Natives.install(self, self.root)
	return self
end

--- Undoes every mutation the current script made to shared tables during this request.
function World:endRequest()
	local journal = self.journal
	Values.journal = nil
	self.journal = nil
	if journal then
		for index = #journal, 1, -1 do
			journal[index]()
		end
	end
end

function World:beginRequest(budget)
	self:endRequest() -- a previous request may have been aborted before it could clean up
	self.cfg = self.config:Snapshot()
	self.budget = budget
	local interp = self.interp
	interp.cfg, interp.budget = self.cfg, budget
	interp.maybe, interp.callDepth, interp.callStack, interp.evalDepth, interp.loopProduct = 0, 0, {}, 0, 1
	interp.halted, interp.cursorScope, interp.cursorEnabled, interp.haltFatal = false, nil, true, true
	interp.moduleStack = {}
end

-- ===== VMs: server and client worlds =====

--[[
	A VM is one module cache plus what booting it learned.
	  modules / rdeps / scopes   the lazy exports, who required whom, each module's top-level scope
	  chunks                     the AST each evaluated script ran from (to tell later whether its top level changed)
	  observed                   what functions were called with while booting: module -> name -> { args }
	  touched                    every script this VM has ever evaluated or been asked for (edits to these make the boot out of date)
	  entries                    entry scripts that were run while booting
	  booted                     the entry scripts have run in this cache
	  stale / staleChunk         the script being typed in was part of the boot: keep answering from it, but rebuild when
	                             its top level changes or the user moves to another script
	  skipped                    the entry script that was being edited, and so left out of the boot
]]
function World.newVm(kind)
	return {
		kind = kind,
		modules = {},
		rdeps = {},
		scopes = {},
		chunks = {},
		observed = {},
		touched = {},
		entries = {},
		moves = {}, -- parent Instance -> { { name, inst, class } }: what scripts reparent at run time (see Builtin/InstanceApi)
		booted = false,
		stale = nil,
		staleChunk = nil,
		skipped = nil,
	}
end

--- Points the shortcut fields (`modules`, `rdeps`, ...) at a VM.
function World:_bind(vm)
	self.vm = vm
	self.modules, self.rdeps, self.moduleScopes, self.observed = vm.modules, vm.rdeps, vm.scopes, vm.observed
end

--- Throws a VM's cache away: it is rebuilt (and re-booted) the next time something needs it.
function World:discardVm(vm)
	vm.modules, vm.rdeps, vm.scopes, vm.chunks = {}, {}, {}, {}
	vm.observed, vm.entries, vm.touched, vm.moves = {}, {}, {}, {}
	vm.booted, vm.stale, vm.staleChunk, vm.skipped = false, nil, nil, nil
	if vm == self.vm then
		self:_bind(vm)
	end
end

local CLIENT_CONTAINERS = {
	StarterPlayer = true, StarterGui = true, StarterPack = true, ReplicatedFirst = true, PlayerGui = true,
	StarterPlayerScripts = true, StarterCharacterScripts = true,
}
local SERVER_CONTAINERS = { ServerScriptService = true, ServerStorage = true }

--- "server" or "client": which VM a script belongs to. LocalScripts and `RunContext = Client` scripts are client; for
--- everything else the nearest container decides: a client/server service, or a folder named like OriginEngine's own
--- convention (`ClientSystems`, `ServerCore`). Shared locations default to server.
function World:kindOf(inst)
	if inst == nil then
		return "server"
	end
	local class = inst.ClassName
	if class == "LocalScript" then
		return "client"
	end
	if class == "Script" then
		local ok, name = pcall(function()
			return inst.RunContext.Name
		end)
		if ok and name == "Client" then
			return "client"
		end
	end
	local node = inst
	for _ = 1, 40 do
		if not node then
			break
		end
		local name = node.Name
		if SERVER_CONTAINERS[name] then
			return "server"
		elseif CLIENT_CONTAINERS[name] then
			return "client"
		elseif string.find(name, "Client", 1, true) then
			return "client"
		elseif string.find(name, "Server", 1, true) then
			return "server"
		end
		node = node.Parent
	end
	return "server"
end

-- ===== modules =====

--- Parses a script through the cache. Reading and parsing a big module is a one-time cost (the AST is cached)
--- and says nothing about how much work the interpreter is doing, so it does not count against any deadline
--- (the request's, or the allowance of the module that happened to require it first).
function World:_parse(inst)
	local clock = self.host.clock
	local started = clock()
	local chunk = self.sources:parse(inst)
	local spent = clock() - started
	local budget = self.budget
	budget.deadline += spent
	if budget._sliceDeadline then
		budget._sliceDeadline += spent
	end
	return chunk
end

--- Lazy exports of a ModuleScript. `requester` is recorded for invalidation.
function World:moduleValue(inst, requester)
	self.vm.touched[inst] = true
	if requester then
		local set = self.rdeps[inst]
		if not set then
			set = {}
			self.rdeps[inst] = set
		end
		set[requester] = true
	end
	local thunk = self.modules[inst]
	if not thunk then
		thunk = Values.thunk(function()
			return self:evaluateModule(inst)
		end)
		thunk.module = inst
		self.modules[inst] = thunk
	end
	return thunk
end

--- A thunk computes (exports, transient). `transient` means "do not remember this result": the module was
--- skipped for lack of budget, not because of anything wrong with it, so a later request should try again.
function World:evaluateModule(inst)
	local until_ = self.slowUntil[inst]
	if until_ and self.host.clock() < until_ then
		return Unknown, true -- it was too slow a moment ago; leave it alone for a few seconds instead of paying for it again
	end
	local chunk = self:_parse(inst)
	if not chunk then
		self.problems[inst] = self.sources:problem(inst) or "unreadable"
		return Unknown
	end
	self.problems[inst] = nil

	local interp = self.interp
	local scope = Scope.new(self.root)
	scope:declare("script", Values.instance(inst))

	local state = interp:saveState()
	interp.moduleStack[#interp.moduleStack + 1] = inst
	interp.maybe = 0
	interp.cursorEnabled = false
	interp.haltFatal = true -- a module that errors at load never finishes; only the script being edited is lenient
	local journal = Values.journal -- a module's own construction is permanent, never rolled back
	Values.journal = nil

	local frame = { pending = {} }
	-- Its own fuel AND its own milliseconds: one runaway module is cut off alone and cannot starve its siblings.
	local ok, sig, vals = self.budget:sliceTimed(self.cfg.moduleFuel, self.cfg.moduleMs, function()
		return interp:execBlock(chunk.body, scope, frame)
	end)

	self.moduleScopes[inst] = scope
	self.vm.chunks[inst] = chunk
	local exports, transient
	if ok then
		exports = Interpreter.collectReturns(sig, vals, frame)[1] or Nil
		if exports.k == "table" and not exports.moduleScript then
			exports.moduleScript = inst -- so `Module.TypeName` annotations can find the module's exported types
		end
		local firstError = chunk.errors[1]
		if firstError then
			self.problems[inst] = `syntax error near line {firstError.line} (analysed the part that could be read)`
		end
	else
		-- the body ran out of steps or time (or hit an internal error): salvage what the last `return` would give
		interp:restoreState(state)
		interp.moduleStack[#interp.moduleStack + 1] = inst
		local reason = sig
		if reason == "starved" then
			transient = true
			self.problems[inst] = "skipped: this request had no budget left"
		elseif reason == "time" then
			-- time is not deterministic (a loaded machine, a first-time cost), so the result is never remembered; a module
			-- that really is slow is simply not retried for a few seconds
			transient = true
			self.slowUntil[inst] = self.host.clock() + self.cfg.slowModuleCooldown
			self.problems[inst] = "too slow to analyse (cut after " .. self.cfg.moduleMs .. " ms)"
		elseif reason == "fuel" then
			self.problems[inst] = "too many steps to analyse completely"
		else
			self.problems[inst] = "analysis error: " .. tostring(reason)
		end
		local lastReturn
		for _, stmt in ipairs(chunk.body.stmts) do
			if stmt.k == "Return" then
				lastReturn = stmt
			end
		end
		exports = Unknown
		if lastReturn and reason ~= "starved" then
			local salvaged, results = self.budget:slice(2000, function()
				return interp:evalMulti(lastReturn.values, scope)
			end)
			if salvaged then
				exports = results[1] or Unknown
			end
		end
		Log.debug("module %s cut short (%s)", inst.Name, tostring(sig))
	end
	interp:restoreState(state)
	if exports.k == "table" and not transient then
		self:_contribute(inst, exports)
	end
	Values.journal = journal
	return exports, transient
end

--- Other modules write into a module's table (`cache[id] = 32`), often inside functions nobody has called while analysing.
--- Evaluates the modules that name `inst` and run each function they export once with unknown arguments, permanently, so
--- whatever lands in `exports` is visible to a third module. A change to such a module rebuilds `inst` (rdeps).
function World:_contribute(inst, exports)
	local thunk = self.modules[inst]
	local cfg = self.cfg
	if not (self.registry and thunk and cfg.contributorScan) or self.contributing[inst] then
		return
	end
	-- only an EMPTY table (`return {}`: a cache or registry that others fill). One with functions is a framework, and running
	-- other modules' code against it (a `Build` that resets its paths) would corrupt what the booted world built; one
	-- that already has fields is described by its own code, and scanning for writers of every module would be O(n^2).
	if exports.meta or #exports.order > 0 or #exports.arr > 0 or exports.idx then
		return
	end
	local list = self.registry:contributorsOf(inst, cfg.maxContributors)
	if #list == 0 then
		return
	end
	self.contributing[inst] = true
	thunk.done, thunk.value = true, exports -- their `require` of it must find the table, not a cycle
	local interp = self.interp
	local ok, err = pcall(function()
		for _, other in list do
			local dependents = self.rdeps[other]
			if not dependents then
				dependents = {}
				self.rdeps[other] = dependents
			end
			dependents[inst] = true
			-- the script being typed in runs on its own (journaled); evaluating its saved text here too would double its writes
			local api = other ~= self.currentScript and force(self:moduleValue(other, nil)) or Unknown
			if api.k == "table" then
				-- the module's own functions, and those of the tables it exports (`return { EntityService = service }`)
				local fns = {}
				local function gather(tbl, depth)
					for _, name in tbl.order do
						local v = force(tbl.fields[name].value)
						if v.k == "function" and v.fn then
							fns[#fns + 1] = v
						elseif v.k == "table" and depth < 1 then
							gather(v, depth + 1)
						end
					end
				end
				gather(api, 0)
				for index, fnV in fns do
					if index > cfg.maxCheckedFunctions then
						break
					end
					local args = {}
					for position, param in fnV.fn.params do
						args[position] = (param.implicit and param.name == "self") and interp:selfValueFor(fnV) or Unknown
					end
					local state = interp:saveState()
					interp.moduleStack[#interp.moduleStack + 1] = other
					interp.maybe, interp.callDepth, interp.callStack = 0, 0, {}
					interp.cursorEnabled, interp.haltFatal = false, true
					self.budget:slice(cfg.checkFunctionFuel, function()
						interp:callClosure(fnV, args)
					end)
					interp:restoreState(state)
				end
			end
		end
	end)
	self.contributing[inst] = nil
	if not ok then
		if Budget.isSignal(err) then
			error(err, 0)
		end
		Log.debug("contributors of %s failed: %s", inst.Name, tostring(err))
	end
end

-- ===== observed calls =====

local OBSERVE_EXTRA_SECONDS = 0.25
local MAX_RECORDED_CALLS = 16

--- Remembers the arguments a function (identified by its defining script and name) was called with.
function World:recordCall(module, name, args)
	local byName = self.observed[module]
	if not byName then
		byName = {}
		self.observed[module] = byName
	end
	local record = byName[name]
	if not record then
		record = { calls = 0, args = {} }
		byName[name] = record
	end
	record.calls += 1
	if record.calls > MAX_RECORDED_CALLS then
		return
	end
	for index, v in ipairs(args) do
		local existing = record.args[index]
		if existing == nil then
			record.args[index] = v
		elseif existing ~= v and existing.k ~= "thunk" and v.k ~= "thunk" then
			record.args[index] = Values.merge(existing, v)
		end
	end
end

--[[
	Frameworks hand functions their arguments at runtime (`Init(maid)` is called by a hot-reloader, not by your code),
	and set things up at start-up that no module's own code shows (`GRequire._Addition("Workspace", pathing)`). So the
	active VM is BOOTED once: the project's entry scripts of its kind - Scripts for the server, LocalScripts for the
	client - run symbolically inside the VM's own cache, in order, like the real game would, with call recording on.
	Whatever they build stays in the cache (so a `GRequire.Require("` list includes the paths added at boot) and what
	each function was called with is kept (so `Init(maid)` knows `maid`).

	Each VM boots separately - server and client are separate Luau VMs and a framework's "already launched" guard
	must not trip because the other side ran first. Runs permanently (no undo journal); a boot that was cut short is
	thrown away and retried by a later request instead of being kept half-done.
]]
--- Runs one entry script inside the VM's cache. Returns false when the request has no budget left for it.
function World:_runEntry(vm, inst, chunk)
	local interp, budget, cfg = self.interp, self.budget, self.cfg
	vm.entries[inst] = true
	vm.touched[inst] = true
	vm.chunks[inst] = chunk
	local scope = Scope.new(self.root)
	scope:declare("script", Values.instance(inst))
	local state = interp:saveState()
	interp.moduleStack[#interp.moduleStack + 1] = inst
	interp.maybe, interp.cursorEnabled, interp.haltFatal = 0, false, true
	interp.recording = true
	-- one entry script that loops, errors or is simply slow must not stop the others
	local sliced, reason = budget:sliceTimed(cfg.moduleFuel, cfg.moduleMs * 2, function()
		interp:execBlock(chunk.body, scope, { pending = {} })
	end)
	interp.recording = false
	interp:restoreState(state)
	if not sliced then
		Log.debug("booting %s cut short (%s)", inst.Name, tostring(reason))
		return reason ~= "starved"
	end
	return true
end

function World:ensureBooted()
	local vm = self.vm
	if vm.booted or not self.cfg.observeCalls or not self.registry then
		return
	end
	vm.booted = true
	vm.skipped = nil

	local budget = self.budget
	local cfg = self.cfg
	local journal = Values.journal
	Values.journal = nil
	-- a one-off cost: it brings its own time and steps, so it neither eats the request's allowance nor aborts the request
	-- (and, the other way round, the extra it was lent never becomes part of what the request itself may spend)
	local clock = self.host.clock
	local started = clock()
	local deadlineBefore, fuelBefore = budget.deadline, budget.fuel
	budget.deadline += math.max(OBSERVE_EXTRA_SECONDS, cfg.observeMs / 1000 + 0.03) -- the boot's own allowance is a setting, not a constant
	budget.fuel += cfg.observeFuel
	local ran, total = 0, 0
	for _ in vm.entries do
		total += 1
	end
	local complete = true

	-- Entry scripts that have already run in this cache are not run again (a late boot after leaving the entry script you were
	-- editing runs only that one): running `Launch` twice in one VM would trip the framework's own "already launched" guard.
	local ok, finished = budget:sliceTimed(cfg.observeFuel, nil, function()
		for _, inst in self.registry:entryScripts() do
			if total >= cfg.maxEntryScripts or clock() - started > cfg.observeMs / 1000 then
				break
			end
			if self:kindOf(inst) == vm.kind and not vm.entries[inst] then
				local text = self.sources:text(inst)
				local wanted = text ~= nil and (string.find(text, "require", 1, true) ~= nil or string.find(text, "Parent", 1, true) ~= nil or string.find(text, "Clone", 1, true) ~= nil) -- scripts that only move things matter as much as ones that require
				if inst == self.currentScript then
					-- being edited: its own code runs as the request; it is run in this world once you leave it
					vm.skipped = wanted and inst or nil
				elseif wanted then
					local chunk = self:_parse(inst)
					if chunk then
						ran += 1
						total += 1
						if not self:_runEntry(vm, inst, chunk) then
							complete = false
							break
						end
					end
				end
			end
		end
	end)

	self.interp.recording = false
	Values.journal = journal
	budget.deadline = deadlineBefore + (clock() - started)
	budget.fuel = math.min(budget.fuel, fuelBefore)
	if not cfg.globalsScan then
		self:_clearGlobals() -- the scan is switched off: what the boot wrote to _G / shared is not offered either
	end
	if not ok or not complete then
		-- no half-done boots: start over from a clean cache the next time
		Log.debug("boot of the %s VM stopped early (%s)", vm.kind, tostring(finished))
		self:discardVm(vm)
	else
		Log.debug("booted the %s VM by running %d entry scripts", vm.kind, ran)
	end
end

--- What the `index`-th parameter of fnV's function was passed by whoever calls it, or nil if unknown.
function World:observedParam(fnV, index)
	if not self.cfg.observeCalls then
		return nil
	end
	local byName = self.observed[fnV.module]
	local record = byName and byName[fnV.name]
	local value = record and record.args[index]
	if value == nil or value.k == "nil" then
		return nil -- never observed, or only ever nil: no information
	end
	return value
end

--[[
	Called at the start of every request (and by prewarm): binds the VM the script belongs to, rebuilds it when what it was
	booted from is out of date, and boots it if needed.

	Out of date means: you left a script you had edited (what it passes to others, or what was built from its exports, may
	have changed), you left the entry script that was left out of the boot, or the script being edited is part of the boot
	and its TOP LEVEL changed. That last one is the Reloader case: OriginEngine only hands a module a Maid when it exports
	`Reloader`, so deleting that line must change what `Init(maid)` receives. Typing inside a function body changes nothing
	and costs nothing (Language/Shape ignores bodies).
]]
function World:_enter(scriptInst)
	local previous = self.currentScript
	for _, vm in self.vms do
		if vm.booted then
			-- a world frozen for a script that is not the one being completed is just out of date (you edited it, then asked
			-- about something else); the entry script that was left out of the boot belongs in it now that you left it
			local staleElsewhere = vm.stale ~= nil and vm.stale ~= scriptInst
			if staleElsewhere then
				self:discardVm(vm)
			elseif scriptInst ~= previous and previous ~= nil and vm.skipped == previous then
				vm.booted = false -- boots again, but only the entry scripts that have not run yet (the one you just left)
			end
		end
	end
	self.currentScript = scriptInst
	if self.editing == scriptInst then
		self.editing = nil
	end
	local vm = self.vms[self:kindOf(scriptInst)]
	self:_bind(vm)

	if self.shapeDirty then
		self.shapeDirty = false
		if vm.booted and scriptInst ~= nil and vm.stale == scriptInst and vm.staleChunk ~= nil then
			local chunk = self:_parse(scriptInst)
			vm.staleShape = vm.staleShape or Shape.of(vm.staleChunk)
			if not chunk or Shape.of(chunk) ~= vm.staleShape then
				self:discardVm(vm)
			end
		end
	end
	self:ensureBooted()
end

--- Boots the VM for `scriptInst` now, outside any request, so the first completion does not pay for it.
function World:prewarm(scriptInst)
	if not self.config:Get("prewarm") then
		return
	end
	local clock = self.host.clock
	local budget = Budget.new({ fuel = self.config:Get("fuelPerRequest"), ms = self.config:Get("prewarmMs"), clock = clock })
	self:beginRequest(budget)
	local ok, _, status = Budget.run(function()
		self:_enter(scriptInst)
	end)
	self:endRequest()
	if not ok then
		Log.debug("prewarm stopped (%s)", tostring(status))
	end
end

--- The editor's text for a script, as the completion request saw it. If the cache was built from different text the
--- change event has not arrived (or never will): treat it as the edit it is, so this request is not answered from the past.
function World:syncEditorText(inst, text)
	local cached = self.sources:peek(inst)
	if cached ~= nil and cached ~= text then
		self.editing = inst
		if self.registry then
			self.registry:noteDocumentChanged(inst)
		end
		self:invalidate(inst)
	end
end

--- Drops a script's cached exports and everything that (transitively) required it, in every VM.
function World:invalidate(inst)
	self.epoch += 1
	self.problems[inst], self.slowUntil[inst] = nil, nil
	local writers = self.registry and self.registry._writers
	local touchedWriter = false
	local isCurrent = inst == self.currentScript or inst == self.editing
	local class = inst.ClassName
	local entryClass = class == "Script" or class == "LocalScript"
	if isCurrent then
		self.shapeDirty = true
	end
	self.moduleTypes[inst] = nil

	for _, vm in self.vms do
		local known = vm.touched[inst] == true or vm.entries[inst] == true
		local frozen = false
		if vm.booted and isCurrent and known then
			-- A booted world is one consistent snapshot (modules that ran at start-up changed each other's tables), so
			-- dropping a few of its modules would corrupt it: `Build` re-running would reset the paths `Launch` added.
			-- While you type in a script it was built from, it stays exactly as it is and answers from the snapshot; it is
			-- rebuilt as a whole when the script's top level changes or you leave it (see _enter).
			frozen = true
			if vm.stale == nil then
				vm.stale, vm.staleChunk, vm.staleShape = inst, vm.chunks[inst], nil
			end
		end

		local queue, seen = { inst }, {}
		if frozen then
			queue = {}
		end
		while #queue > 0 do
			local current = table.remove(queue)
			if not seen[current] then
				seen[current] = true
				vm.modules[current] = nil
				vm.scopes[current] = nil
				vm.chunks[current] = nil
				self.moduleTypes[current] = nil
				self.problems[current] = nil
				if writers and writers[current] then
					touchedWriter = true
				end
				local dependents = vm.rdeps[current]
				if dependents then
					for dependent in dependents do
						queue[#queue + 1] = dependent
					end
				end
				vm.rdeps[current] = nil
			end
		end

		if vm.booted and not isCurrent then
			if known then
				self:discardVm(vm) -- something the boot was built from changed behind your back: boot again
			elseif entryClass and self:kindOf(inst) == vm.kind then
				vm.booted = false -- a new or changed entry script nobody has run yet: run it (and only it) next time
			end
		end
	end
	if touchedWriter or self.globalsLoaded then
		self:_clearGlobals()
	end
end

--- Containers changed: nothing cached can be trusted.
function World:reset()
	self.epoch += 1
	local kind = self.vm and self.vm.kind or "server"
	self.vms = { server = World.newVm("server"), client = World.newVm("client") }
	self:_bind(self.vms[kind])
	self.moduleTypes = {}
	self.shapeDirty = false
	self.problems, self.slowUntil = {}, {}
	self:_clearGlobals()
end

--- The interpreter lost one statement to an internal error (the rest of the script was analysed regardless).
function World:noteStatementFailure(inst, line, err)
	Log.debug("statement at line %s failed: %s", tostring(line), tostring(err))
	if inst and not self.problems[inst] then
		self.problems[inst] = `statement at line {line or "?"} could not be analysed ({tostring(err):sub(1, 80)})`
	end
end

--- Scripts whose analysis is incomplete, sorted by path: { { script, reason } ... }.
function World:problemList()
	local list = {}
	for inst, reason in self.problems do
		list[#list + 1] = { script = inst, reason = reason }
	end
	table.sort(list, function(a, b)
		return a.script:GetFullName() < b.script:GetFullName()
	end)
	return list
end

-- ===== _G / shared =====

--- "server" / "client" when the script can only run on that side (a LocalScript, a client RunContext, or a client/server container or
--- name), nil when it is shared (ReplicatedStorage modules ...) and so belongs to both. Same rules as `kindOf`, without its default.
function World:_exclusiveKind(inst)
	if inst == nil then
		return nil
	end
	local class = inst.ClassName
	if class == "LocalScript" then
		return "client"
	end
	if class == "Script" then
		local ok, name = pcall(function()
			return inst.RunContext.Name
		end)
		if ok and name == "Client" then
			return "client"
		end
	end
	local node = inst
	for _ = 1, 40 do
		if not node then
			break
		end
		local name = node.Name
		if SERVER_CONTAINERS[name] or (not CLIENT_CONTAINERS[name] and string.find(name, "Server", 1, true) and not string.find(name, "Client", 1, true)) then
			return "server"
		elseif CLIENT_CONTAINERS[name] or string.find(name, "Client", 1, true) then
			return "client"
		end
		node = node.Parent
	end
	return nil
end

function World:_clearGlobals()
	Values.clearTable(self.gTable)
	Values.clearTable(self.sharedTable)
	self.globalsLoaded = false
end

function World:ensureGlobals()
	-- _G and shared exist once per side: the server's `_G.require = ...` and the client's are different functions, and merging them
	-- makes every call run both and mix the answers. A different VM than the one the scan was made for starts the scan again.
	if self.globalsLoaded and self.globalsKind ~= self.vm.kind then
		self:_clearGlobals()
	end
	if self.globalsLoaded or not self.cfg.globalsScan or not self.registry then
		return
	end
	self.globalsLoaded = true
	self.globalsKind = self.vm.kind
	local journal = Values.journal
	Values.journal = nil -- populating _G is permanent state, not part of the script being edited
	local ok, err = pcall(function()
		local interp = self.interp
		local ran = 0
		for _, inst in self.registry:globalWriters() do
				local only = self:_exclusiveKind(inst)
				if only and only ~= self.vm.kind then
					continue -- the other side's script: its _G is not this VM's _G
				end
			ran += 1
			if ran > self.cfg.maxGlobalScripts then
				break
			end
			local chunk = self:_parse(inst)
			if chunk then
				local scope = Scope.new(self.root)
				scope:declare("script", Values.instance(inst))
				local state = interp:saveState()
				interp.moduleStack[#interp.moduleStack + 1] = inst
				interp.maybe = 0
				interp.cursorEnabled = false
				interp.haltFatal = true
				-- each writer is isolated: a broken or slow one costs only its own contribution
				local sliced, reason = self.budget:sliceTimed(self.cfg.moduleFuel, self.cfg.moduleMs, function()
					interp:execBlock(chunk.body, scope, { pending = {} })
				end)
				interp:restoreState(state)
				if not sliced then
					Log.debug("_G writer %s cut short (%s)", inst.Name, tostring(reason))
					if reason == "starved" then
						self.globalsLoaded = false -- partial: finish on a later request
						break
					end
				end
			end
		end
	end)
	Values.journal = journal
	if not ok then
		if Budget.isSignal(err) then
			self:_clearGlobals() -- aborted midway: retry from scratch on the next request
		else
			Log.debug("globals scan failed: %s", tostring(err))
			return
		end
		error(err, 0)
	end
end

-- ===== the script being edited =====

--- Runs the parsed code before the cursor and returns the scope in force at the cursor.
function World:runCurrent(chunk, scriptInst)
	self:_enter(scriptInst)
	local interp = self.interp
	local scope = Scope.new(self.root)
	scope:declare("script", scriptInst and Values.instance(scriptInst) or Unknown)
	self.journal = {}
	Values.journal = self.journal
	interp.cursorScope, interp.cursorEnabled, interp.maybe = nil, true, 0
	-- The code after a top-level `error(...)` in the file being edited still matters to the person typing it.
	interp.haltFatal = false
	interp.moduleStack = { scriptInst }
	interp:execBlock(chunk.body, scope, { pending = {} })
	local result = interp.cursorScope or scope
	interp.cursorScope = nil
	return result
end

--[[
	Runs the whole of `scriptInst` (`chunk`, parsed with spans) and then every function it wrote, each with arguments nobody knows,
	so that `watcher(callNode, callee, args)` hears about every call written in that script, in the scope it is written in.
	Does not touch which script is "current" or which VM is booted: checking one script must never cost another its snapshot.
	Budget signals propagate; the caller owns beginRequest/endRequest.
]]
function World:checkCalls(chunk, scriptInst, watcher, indexWatcher)
	local previousVm = self.vm
	self:_bind(self.vms[self:kindOf(scriptInst)])
	local interp = self.interp
	local cfg = self.cfg
	local sink = {}
	interp.callWatcher, interp.closureSink, interp.checkModule = watcher, sink, scriptInst
	interp.indexWatcher = indexWatcher
	local ok, err = pcall(function()
		local scope = Scope.new(self.root)
		scope:declare("script", Values.instance(scriptInst))
		self.journal = {}
		Values.journal = self.journal
		interp.cursorScope, interp.cursorEnabled, interp.maybe, interp.haltFatal = nil, false, 0, false
		interp.moduleStack = { scriptInst }
		interp:execBlock(chunk.body, scope, { pending = {} })

		local index = 1
		while sink[index] ~= nil do
			local fnV = sink[index]
			index += 1
			local args = {}
			for position, param in fnV.fn.params do
				args[position] = (param.implicit and param.name == "self") and interp:selfValueFor(fnV) or Unknown
			end
			interp.moduleStack, interp.callDepth, interp.callStack, interp.maybe = { scriptInst }, 0, {}, 0
			self.budget:slice(cfg.checkFunctionFuel, function()
				interp:callClosure(fnV, args)
			end)
		end
	end)
	interp.callWatcher, interp.closureSink, interp.checkModule, interp.indexWatcher = nil, nil, nil, nil
	if previousVm then
		self:_bind(previousVm)
	end
	if not ok then
		error(err, 0)
	end
end

--- Boots the VM `scriptInst` belongs to (runs the entry scripts once) without making it the current script, for a check that must
--- see what the project's start-up did (instances it moved, `_G` it filled). A no-op once booted.
function World:bootFor(scriptInst)
	local previous = self.vm
	self:_bind(self.vms[self:kindOf(scriptInst)])
	local ok, err = pcall(self.ensureBooted, self)
	if previous then
		self:_bind(previous)
	end
	if not ok then
		error(err, 0)
	end
end

-- ===== helpers for the interpreter and engine =====

--- A value for a type annotation (`number`, `Player`, `Config`, `Stack<string>`, `{ x: number }` ...), or nil when the
--- annotation says nothing useful. `scope` resolves `type` aliases; `generics` are the enclosing function's own.
function World:valueForType(text, scope, generics)
	return self.types:valueFor(text, scope, generics)
end

--- The aliases a module declares (name -> { decl, module, static }), read from its source without running it.
function World:typesOf(inst)
	local cached = self.moduleTypes[inst]
	if cached then
		return cached
	end
	local map = {}
	local chunk = self:_parse(inst)
	if chunk then
		for _, decl in chunk.body.types or {} do
			map[decl.name] = { decl = decl, module = inst, static = map }
		end
	end
	self.moduleTypes[inst] = map
	return map
end

--- Is this script hidden from listings by a file-level `--@Private` / `--@Hidden` header? (Not for its own editor.)
function World:isFilePrivate(inst, viewer)
	if inst == nil or inst == viewer then
		return false
	end
	local tags = self.sources:fileTags(inst)
	return tags ~= nil and (tags.private == true or tags.hidden == true)
end

--- Names a function accepts as its `argIndex`-th argument, discovered by calling it with a symbolic
--- string and watching what that string is used to look up. Returns a list of { name, kind, detail }.
function World:stringCandidates(callee, selfV, argIndex)
	callee = force(callee)
	if callee.k == "union" then
		for _, member in callee.members do
			member = force(member)
			if member.k == "function" and member.fn then
				callee = member
				break
			end
		end
	end
	if callee.k ~= "function" or not callee.fn then
		return nil
	end

	local probe = Values.probe()
	local offset = selfV and 1 or 0
	local args = {}
	for index = 1, argIndex + offset do
		args[index] = Unknown
	end
	if selfV then
		args[1] = selfV
	end
	args[argIndex + offset] = probe

	self.interp:callClosure(callee, args)
	return self:domainNames(probe)
end

function World:domainNames(probe)
	local cfg = self.cfg
	local out, seen = {}, {}
	local function add(name, kind, detail, sep)
		if type(name) == "string" and not seen[name] and #out < cfg.maxItems then
			seen[name] = true
			out[#out + 1] = { name = name, kind = kind, detail = detail, sep = sep }
		end
	end
	--- Every path through nested plain tables ("A", "A/B", "A/B/C"). A module is a leaf: its exports are the thing
	--- the path resolves TO, not more path segments, and looking inside would mean evaluating it.
	local function addPaths(tbl, sep, prefix, depth)
		for _, name in tbl.order do
			if #out >= cfg.maxItems then
				return
			end
			if string.sub(name, 1, 2) ~= "__" then
				local full = prefix and (prefix .. sep .. name) or name
				add(full, "table", nil, sep)
				local value = tbl.fields[name].value
				if value.k == "table" and depth < 6 then
					addPaths(value, sep, full, depth + 1)
				end
			end
		end
	end

	for _, domain in probe.domains do
		if domain.kind == "table" then
			local tbl = force(domain.table)
			if tbl.k == "table" then
				if domain.sep then
					addPaths(tbl, domain.sep, nil, 1)
				else
					for _, name in tbl.order do
						add(name, "table")
					end
				end
			end
		elseif domain.kind == "children" then
			local list
			if domain.recursive then
				list = Traversal.descendants(domain.inst, {
					limit = cfg.maxChildren,
					maxNodes = cfg.maxTraversalNodes,
					maxChildrenPerNode = cfg.maxChildrenPerNode,
				})
			else
				list = Traversal.children(domain.inst, cfg.maxChildren)
			end
			for _, child in list do
				if not domain.recursive or Traversal.isScript(child) then
					add(child.Name, "instance", child.ClassName)
				end
			end
		end
	end
	return out
end

return World
