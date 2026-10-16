--[[
	Config: typed settings with defaults. Overrides persist through an injected store
	(plugin:GetSetting / plugin:SetSetting in Studio) and changes are broadcast on `Changed`.
]]

local Signal = require(script.Parent.Signal)

local Config = {}
Config.__index = Config

local STORE_KEY = "LinterConfig"

Config.DEFAULTS = {
	enabled = true,
	debug = false,

	-- request budgets: every completion is bounded in both steps and wall-clock time
	requestBudgetMs = 100, -- the first completion in a session evaluates your modules; later ones are served from cache
	fuelPerRequest = 250000,
	moduleFuel = 100000, -- steps one module body may spend before it is cut off
	moduleMs = 90, -- milliseconds one module body may spend; a slow module is cut off alone (see Budget slices)
	slowModuleCooldown = 5, -- seconds a module that ran out of time is left alone before it is tried again
	observeFuel = 300000, -- extra steps / milliseconds granted once to run entry scripts and learn what frameworks pass
	observeMs = 220,
	maxCallDepth = 30,
	maxLoopIterations = 4000, -- unroll cap per loop (loops with more iterations get one abstract pass)
	maxLoopBudget = 6000, -- total body runs shared by nested unrolled loops
	maxUnion = 8,

	-- "a billion objects" guards
	maxChildren = 3000, -- children kept from one GetChildren() call
	maxDescendants = 6000, -- results kept from one GetDescendants()-style walk
	maxChildrenPerNode = 2000, -- above this a node is only searched for scripts/containers
	maxTraversalNodes = 40000, -- nodes visited by one registry scan
	maxScripts = 15000, -- scripts the registry will track
	maxWatchedContainers = 2000, -- folders watched for renames (each holds scripts beneath it)
	maxSourceBytes = 300000, -- larger sources are never parsed
	maxItems = 400, -- completion items added per request

	addParens = true, -- accepted functions insert `()` (Studio's AddParens / PutCursorInParens tags)
	observeCalls = true, -- run entry scripts symbolically to learn what frameworks pass to your functions
	maxEntryScripts = 12, -- entry scripts run for that
	warmup = true, -- parse scripts in the background after the scan so the first completion is not slow
	prewarm = true, -- boot the project (run entry scripts symbolically) when a script opens or after edits, while you are not typing
	prewarmDelay = 0.35, -- seconds of quiet before that happens
	prewarmMs = 400, -- time allowance of one such boot
	globalsScan = true, -- discover _G / shared members by evaluating scripts that write them
	maxGlobalScripts = 48,
	contributorScan = true, -- a module's table also shows what OTHER modules write into it (`cache[k] = v`, even inside functions nobody calls yet)
	maxContributors = 12, -- modules examined for that per table
	reflection = true, -- fill Instance members from ReflectionService
	suggestIndexes = true, -- a table's array positions show up as `1`, `2` ... and accepting `1` after a dot writes `[1]`
	maxIndexItems = 12, -- positions offered before you type a digit (once you do, every matching position, up to 30)
	suggestBracketKeys = true, -- names that cannot follow a dot (`Spawn Point`, `end`) are offered as `["Spawn Point"]`
	suggestAttributeNames = true, -- GetAttribute("), SetAttribute("), HasTag(" ... offer the attributes / tags that exist
	suggestArguments = true, -- inside `f(`: the parameter being typed (name and type) and the strings / enums its type allows
	checkArguments = true, -- underline arguments whose type cannot match the parameter (ScriptEditorService script analysis)
	checkMs = 150, -- time one analysis of one script may take
	checkFunctionFuel = 25000, -- steps one function of the script may use while its calls are checked
	maxCheckedFunctions = 200, -- functions of one script that are run (with unknown arguments) to check the calls inside them
	checkMembers = true, -- a misspelled member of a table / child of an instance that has a close match ("Did you mean ...?"), and calling a value that is not a function
	checkArgumentCount = false, -- more arguments than a function takes (off: callbacks often get extra arguments on purpose)
	checkMissingChildren = false, -- WaitForChild("X") of a child the project files do not contain (off: many children are created at run time)
	hideMovedErrors = true, -- tell the proxy which "not found" errors are false because a script moves the instance there at run time
	maxDiagnostics = 60, -- underlines reported for one script
	trimStudioList = true, -- remove members you marked private (or `_names` when hideUnderscore is on) from Studio's own list too
	hideUnderscore = false, -- treat members named `_like_this` as private (hidden outside the script that defines them)

	-- circuit breaker: repeated slow requests switch the resolver off for a while
	slowRequestMs = 200,
	slowRequestStrikes = 5,
	circuitCooldownSeconds = 20,

	roots = {
		"ReplicatedFirst",
		"ReplicatedStorage",
		"ServerScriptService",
		"ServerStorage",
		"StarterPlayer",
		"StarterGui",
		"StarterPack",
		"Workspace", -- last: usually the largest
	},
}

local function copyDefault(value)
	if type(value) == "table" then
		return table.clone(value)
	end
	return value
end

--- store: optional { get = function(key) -> any, set = function(key, value) }
function Config.new(store)
	local self = setmetatable({}, Config)
	self._store = store
	self._values = {}
	for key, value in Config.DEFAULTS do
		self._values[key] = copyDefault(value)
	end
	self.Changed = Signal.new()

	if store then
		local ok, saved = pcall(store.get, STORE_KEY)
		if ok and type(saved) == "table" then
			for key, value in saved do
				if Config.DEFAULTS[key] ~= nil and type(value) == type(Config.DEFAULTS[key]) then
					self._values[key] = value
				end
			end
		end
	end
	return self
end

function Config:Get(key)
	return self._values[key]
end

--- Plain-table copy of every value, for hot paths that must not pay for method calls.
function Config:Snapshot()
	return table.clone(self._values)
end

function Config:Set(key, value)
	local default = Config.DEFAULTS[key]
	if default == nil then
		error(`unknown config key '{tostring(key)}'`, 2)
	end
	if type(value) ~= type(default) then
		error(`config '{key}' expects {type(default)}, got {type(value)}`, 2)
	end
	if self._values[key] == value then
		return
	end
	self._values[key] = value
	self:_persist()
	self.Changed:Fire(key, value)
end

function Config:_persist()
	if not self._store then
		return
	end
	local overrides = {}
	for key, value in self._values do
		if value ~= Config.DEFAULTS[key] then
			overrides[key] = value
		end
	end
	pcall(self._store.set, STORE_KEY, overrides)
end

function Config:Destroy()
	self.Changed:Destroy()
end

return Config
