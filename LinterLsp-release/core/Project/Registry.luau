--[[
	Registry: which scripts exist and which of them touch _G / shared.

	Event driven and bounded:
	  * one DescendantAdded / DescendantRemoving pair per ROOT SERVICE (never per instance)
	  * one `Changed` connection per tracked script (Source / Name / Parent)
	  * the initial scan is an iterative, time-sliced walk (Traversal) with node and script caps
	  * structure events are coalesced through a Debouncer before anyone hears about them

	Signals:
	  ScriptChanged(script)   a tracked script's text/name/parent changed, or it was removed
	  StructureChanged()      containers or scripts appeared/disappeared (debounced)
	  Scanned()               an initial scan finished
]]

local Maid = require(script.Parent.Parent.Core.Maid)
local Signal = require(script.Parent.Parent.Core.Signal)
local Debouncer = require(script.Parent.Parent.Core.Debouncer)
local Log = require(script.Parent.Parent.Core.Log)
local Traversal = require(script.Parent.Traversal)

local Registry = {}
Registry.__index = Registry

local FLAG_BUDGET_SECONDS = 0.010

function Registry.new(deps)
	local self = setmetatable({}, Registry)
	self._host = deps.host
	self._config = deps.config
	self._sources = deps.sources
	self._maid = Maid.new()
	self._scripts = {} -- script -> { connection, ancestors }
	self._count = 0
	self._containers = {} -- folder -> { count, connection } (Name watchers shared by every script beneath it)
	self._containerCount = 0
	self._writers = {} -- script -> true when it mentions _G or shared
	self._dirtyFlags = {}
	self._scanGeneration = 0
	self._destroyed = false

	self.Ready = false
	self.Truncated = false
	self.ScriptChanged = self._maid:Give(Signal.new())
	self.StructureChanged = self._maid:Give(Signal.new())
	self.Scanned = self._maid:Give(Signal.new())
	self._structure = self._maid:Give(Debouncer.new(0.25, function()
		self.StructureChanged:Fire()
	end))
	return self
end

function Registry:_rootInstances()
	local game = self._host.game
	local out = {}
	if not game then
		return out
	end
	for _, name in self._config:Get("roots") do
		local ok, service = pcall(game.FindService, game, name) -- never GetService: that would create missing services
		if ok and service then
			out[#out + 1] = service
		end
	end
	return out
end

function Registry:_isStructural(inst)
	if Traversal.CONTAINERS[inst.ClassName] then
		return true
	end
	local ok, isValue = pcall(inst.IsA, inst, "ValueBase")
	return ok and isValue == true
end

function Registry:_watchAncestors(inst, record)
	local cap = self._config:Get("maxWatchedContainers")
	local game = self._host.game
	local ancestors = {}
	local node = inst.Parent
	for _ = 1, 64 do
		if not node or node == game or node.Parent == game then
			break -- services cannot be renamed
		end
		local entry = self._containers[node]
		if not entry then
			if self._containerCount >= cap then
				break
			end
			local connection = self._host.connect(node, "Changed", function(property)
				if property == "Name" then
					self._structure:Trigger()
				end
			end)
			entry = { count = 0, connection = connection }
			self._containers[node] = entry
			self._containerCount += 1
		end
		entry.count += 1
		ancestors[#ancestors + 1] = node
		node = node.Parent
	end
	record.ancestors = ancestors
end

function Registry:_unwatchAncestors(record)
	for _, node in record.ancestors or {} do
		local entry = self._containers[node]
		if entry then
			entry.count -= 1
			if entry.count <= 0 then
				self._containers[node] = nil
				self._containerCount -= 1
				if entry.connection then
					entry.connection:Disconnect()
				end
			end
		end
	end
	record.ancestors = nil
end

function Registry:_track(inst)
	if self._scripts[inst] then
		return
	end
	if self._count >= self._config:Get("maxScripts") then
		self.Truncated = true
		return
	end
	local record = {}
	local ok, connection = pcall(self._host.connect, inst, "Changed", function(property)
		if property == "Source" then
			self:_scriptChanged(inst)
		elseif property == "Name" or property == "Parent" then
			-- every path through this script changed (and so may anything built from the tree's shape)
			if property == "Parent" then
				self:_unwatchAncestors(record)
				pcall(self._watchAncestors, self, inst, record)
			end
			self:_scriptChanged(inst)
			self._structure:Trigger()
		end
	end)
	if not ok then
		Log.debug("could not watch %s: %s", tostring(inst), tostring(connection))
		return -- one script that cannot be watched must not stop the scan
	end
	record.connection = connection
	self._count += 1
	self._scripts[inst] = record
	pcall(self._watchAncestors, self, inst, record)
	self._dirtyFlags[inst] = true
end

function Registry:_untrack(inst)
	local record = self._scripts[inst]
	if not record then
		return false
	end
	self._scripts[inst] = nil
	self._count -= 1
	self._writers[inst] = nil
	self._dirtyFlags[inst] = nil
	if record.connection then
		record.connection:Disconnect()
	end
	self:_unwatchAncestors(record)
	return true
end

function Registry:_scriptChanged(inst)
	self._dirtyFlags[inst] = true
	self._sources:invalidate(inst)
	self.ScriptChanged:Fire(inst)
end

function Registry:_onAdded(inst)
	if Traversal.isScript(inst) then
		self:_track(inst)
		self._structure:Trigger()
	elseif self:_isStructural(inst) then
		self._structure:Trigger()
	end
end

function Registry:_onRemoved(inst)
	if self:_untrack(inst) then
		self._sources:invalidate(inst)
		self.ScriptChanged:Fire(inst)
		self._structure:Trigger()
	elseif self:_isStructural(inst) then
		self._structure:Trigger()
	end
end

--- Open-editor edits arrive via ScriptEditorService, not via the Source property.
function Registry:noteDocumentChanged(inst)
	if not inst then
		return
	end
	if not self._scripts[inst] then
		self:_track(inst)
	end
	self:_scriptChanged(inst)
end

function Registry:_scan()
	self._scanGeneration += 1
	local generation = self._scanGeneration
	local config, host = self._config, self._host
	local limit = config:Get("maxTraversalNodes")
	local visited = 0

	local function cancelled()
		return self._destroyed or self._scanGeneration ~= generation
	end

	for _, root in self:_rootInstances() do
		if cancelled() then
			return
		end
		local count, truncated = Traversal.walk(root, {
			maxNodes = limit - visited,
			maxChildrenPerNode = config:Get("maxChildrenPerNode"),
			yield = host.yield,
			clock = host.clock,
			cancelled = cancelled,
		}, function(node)
			if Traversal.isScript(node) then
				self:_track(node)
			end
		end)
		visited += count
		if truncated then
			self.Truncated = true
		end
		if visited >= limit then
			self.Truncated = true
			break
		end
	end

	if cancelled() then
		return
	end
	self.Ready = true
	Log.debug("scan finished: %d scripts, %d nodes%s", self._count, visited, self.Truncated and " (truncated)" or "")
	self.Scanned:Fire()
	if self._warmOnScan then
		self:_warmUp(generation)
	end
end

local WARM_LIMIT = 250
local WARM_SLICE_SECONDS = 0.004

--- Parses scripts ahead of time (time-sliced) so the first completion that needs a big module does not
--- pay for reading and parsing it. Results land in the SourceStore cache; nothing is evaluated.
function Registry:_warmUp(generation)
	local list = {}
	for inst in self._scripts do
		list[#list + 1] = inst
	end
	local host = self._host
	local sliceStart = host.clock()
	for index, inst in list do
		if index > WARM_LIMIT or self._destroyed or self._scanGeneration ~= generation then
			return
		end
		if self._scripts[inst] then
			pcall(self._sources.parse, self._sources, inst)
		end
		if host.yield and host.clock() - sliceStart > WARM_SLICE_SECONDS then
			host.yield()
			sliceStart = host.clock()
		end
	end
	Log.debug("warm-up parsed %d scripts", math.min(#list, WARM_LIMIT))
end

--- opts.synchronous: scan inline (tests). Otherwise the scan runs on its own time-sliced thread.
--- opts.warm: after the scan, parse scripts in the background (kept for later Rescans).
function Registry:Start(opts)
	self._warmOnScan = opts ~= nil and opts.warm == true
	for _, root in self:_rootInstances() do
		self._maid:Give(self._host.connect(root, "DescendantAdded", function(inst)
			local ok, err = pcall(self._onAdded, self, inst)
			if not ok then
				Log.debug("DescendantAdded handler failed: %s", tostring(err))
			end
		end))
		self._maid:Give(self._host.connect(root, "DescendantRemoving", function(inst)
			local ok, err = pcall(self._onRemoved, self, inst)
			if not ok then
				Log.debug("DescendantRemoving handler failed: %s", tostring(err))
			end
		end))
	end
	if opts and opts.synchronous then
		self:_scan()
	else
		self._maid.scan = task.spawn(function()
			self:_scan()
		end)
	end
end

function Registry:Rescan(opts)
	self._scanGeneration += 1
	for inst in table.clone(self._scripts) do
		self:_untrack(inst)
	end
	self.Ready, self.Truncated = false, false
	if opts and opts.synchronous then
		self:_scan()
	else
		self._maid.scan = task.spawn(function()
			self:_scan()
		end)
	end
end

function Registry:Count()
	return self._count
end

--- Scripts and LocalScripts (not modules), sorted by path: where a game's code actually starts running.
function Registry:entryScripts()
	local list = {}
	for inst in self._scripts do
		local class = inst.ClassName
		if class == "Script" or class == "LocalScript" then
			list[#list + 1] = inst
		end
	end
	table.sort(list, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	return list
end

--- Tracked scripts sorted by full name.
function Registry:Scripts()
	local list = {}
	for inst in self._scripts do
		list[#list + 1] = inst
	end
	table.sort(list, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	return list
end

function Registry:IsTracked(inst)
	return self._scripts[inst] ~= nil
end

--- Scripts that mention _G or shared, sorted by full name. Flags are computed lazily and
--- incrementally (a few ms per call) so a big place never stalls one request.
function Registry:globalWriters()
	if not self._config:Get("globalsScan") then
		return {}
	end
	local clock = self._host.clock
	local deadline = clock() + FLAG_BUDGET_SECONDS
	for inst in self._dirtyFlags do
		local text = self._sources:read(inst)
		local writes = text ~= nil
			and (string.find(text, "%f[%w_]_G%f[^%w_]") ~= nil or string.find(text, "%f[%w_]shared%f[^%w_]") ~= nil)
		self._writers[inst] = writes and true or nil
		self._dirtyFlags[inst] = nil
		if clock() > deadline then
			break
		end
	end
	local list = {}
	for inst in self._writers do
		list[#list + 1] = inst
	end
	table.sort(list, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	return list
end

--- ModuleScripts other than `inst` whose text calls `require` and names it: they may write into the table it returns.
function Registry:contributorsOf(inst, limit)
	if not self._config:Get("contributorScan") then
		return {}
	end
	local pattern = "%f[%w_]" .. string.gsub(inst.Name, "%W", "%%%0") .. "%f[^%w_]"
	local list = {}
	for other in self._scripts do
		if other ~= inst and other.ClassName == "ModuleScript" then
			local text = self._sources:read(other)
			if text ~= nil and string.find(text, "require", 1, true) and string.find(text, pattern) then
				list[#list + 1] = other
			end
		end
	end
	table.sort(list, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	while #list > limit do
		list[#list] = nil
	end
	return list
end

function Registry:Destroy()
	self._destroyed = true
	self._scanGeneration += 1
	for inst in table.clone(self._scripts) do
		self:_untrack(inst)
	end
	self._maid:Destroy()
end

return Registry
