--[[
	Server: the Linter language server. Speaks LSP (JSON-RPC messages as Lua tables; the transport lives elsewhere) and answers
	two things luau-lsp cannot: completions that come from evaluating the project symbolically (dynamic module lists, custom
	`require`, `_G` / `shared`, shared tables other modules fill, observed framework parameters ...) and wrong-argument-type
	warnings. A proxy (bridge/) merges its answers with luau-lsp's.

	  Workspace (folder -> DataModel) -> Host -> SourceStore / Registry / World / Engine / Checker   (the unchanged core)

	Protection: every message is handled under pcall (a failure becomes an error response, never a crash), repeated failures
	of one method trip a breaker, memory is watched, and the core's own budgets and circuit breakers stay on.
]]

local Text = require("./Text")
local Uri = require("./Uri")
local Convert = require("./Convert")
local Workspace = require("./Workspace")
local Reflection = require("./Reflection")
local Report = require("./Report")

local Server = {}
Server.__index = Server

local TRIGGERS = { ".", ":", "\"", "'", "(", ",", "[", "/", "@", " " }
local MAX_FAILURES = 5 -- consecutive failures of one method before it is switched off for a while
local BREAKER_SECONDS = 15
local MEMORY_LIMIT_KB = 1500 * 1024

--- deps: loader (core loader), root (directory with core/ and data/), send(message), clock, host (HostInfo.detect()), log(text)
function Server.new(deps)
	return setmetatable({
		_loader = deps.loader,
		_root = deps.root,
		_send = deps.send,
		_clock = deps.clock or os.clock,
		_host = deps.host,
		_log = deps.log or function() end,
		_docs = {}, -- uri -> { text, version, inst, starts }
		_open = {}, -- instance -> text (what the editor shows)
		_events = {}, -- instance -> eventName -> { { fn, connected } }
		_failures = {}, -- method -> { count, until }
		_requests = 0,
		_initialized = false,
		_shutdown = false,
		stack = nil,
	}, Server)
end

-- ===== stack =====

function Server:_connect(inst, eventName, fn)
	local perInstance = self._events[inst]
	if not perInstance then
		perInstance = {}
		self._events[inst] = perInstance
	end
	perInstance[eventName] = perInstance[eventName] or {}
	local entry = { fn = fn, connected = true }
	table.insert(perInstance[eventName], entry)
	return {
		Disconnect = function()
			entry.connected = false
		end,
	}
end

function Server:_fire(inst, eventName, ...)
	local handlers = self._events[inst] and self._events[inst][eventName]
	for _, entry in handlers or {} do
		if entry.connected then
			local ok, err = pcall(entry.fn, ...)
			if not ok then
				self._log("event handler failed: " .. tostring(err))
			end
		end
	end
end

--- Builds (or rebuilds) the whole engine over a freshly mapped DataModel.
function Server:_build()
	local loader = self._loader
	local Config = loader.require("Core/Config")
	local Log = loader.require("Core/Log")
	local Debouncer = loader.require("Core/Debouncer")
	local Maid = loader.require("Core/Maid")
	local Host = loader.require("Project/Host")
	local SourceStore = loader.require("Project/SourceStore")
	local Registry = loader.require("Project/Registry")
	local ClassCatalog = loader.require("Builtin/ClassCatalog")
	local World = loader.require("Interp/World")
	local Items = loader.require("Completion/Items")
	local Engine = loader.require("Completion/Engine")
	local Checker = loader.require("Completion/Checker")

	Log.sink = function(level, message)
		self._log(`[{level}] {message}`)
	end

	if self.stack then
		self.stack.maid:Destroy()
	end
	local maid = Maid.new()
	local config = self._config or Config.new()
	self._config = config
	Log.setDebug(config:Get("debug"))

	local workspace = Workspace.new({
		root = self._rootPath,
		projectFile = self._options.projectFile,
		windows = self._host.os == "windows",
		log = self._log,
	})
	local game = workspace:load()
	self._events = {}
	self._open = {} -- instances are new after a rebuild; open documents are re-attached below

	local openText = self._open
	local host = Host.new({
		game = game,
		clock = self._clock,
		readSource = function(inst)
			return openText[inst] or inst.Source
		end,
		connect = function(inst, eventName, fn)
			return self:_connect(inst, eventName, fn)
		end,
	})
	local sources = SourceStore.new(host, config)
	local registry = maid:Give(Registry.new({ host = host, config = config, sources = sources }))
	local service, reflectionSource = Reflection.load(self._root)
	local catalog = ClassCatalog.new(service)
	local world = World.new({ config = config, host = host, sources = sources, catalog = catalog, registry = registry })
	local engine = Engine.new({
		config = config,
		world = world,
		items = Items.new(setmetatable({}, { __index = function(_, name) return name end }), setmetatable({}, { __index = function(_, name) return name end }), config),
		catalog = catalog,
		clock = host.clock,
	})
	local checker = Checker.new({ config = config, world = world, severity = 2, clock = host.clock })

	local stack = {
		maid = maid,
		workspace = workspace,
		game = game,
		host = host,
		sources = sources,
		registry = registry,
		world = world,
		engine = engine,
		checker = checker,
		catalog = catalog,
		reflectionSource = reflectionSource,
		Log = Log,
	}
	self.stack = stack
	-- Start the project's boot (its entry scripts, run symbolically) as soon as the project is loaded instead of when the first file
	-- opens, so the first completion finds that work already done. Any module will do as the "current script": entry scripts are
	-- left out of their own boot, so one must not be chosen. The class data below is decoded first; both happen in idle time.
	if config:Get("prewarm") then
		require("@lune/task").delay(1.2, function()
			if not self.stack or self.stack ~= stack then
				return -- the stack was rebuilt (project file changed) or the server is shutting down
			end
			for _, inst in registry:Scripts() do
				if inst.ClassName == "ModuleScript" then
					local ok, err = pcall(world.prewarm, world, inst)
					if not ok then
						Log.debug("start-up prewarm failed: %s", tostring(err))
					end
					break
				end
			end
		end)
	end
	-- the class data (~10 MB of JSON) is decoded in the background shortly after start-up instead of in front of the first request
	if service.preload then
		require("@lune/task").delay(0.8, function()
			pcall(service.preload)
		end)
	end

	-- while you are not typing, boot the project in the background so the first completion after opening a file is fast
	local prewarmTarget
	local prewarm = maid:Give(Debouncer.new(config:Get("prewarmDelay"), function()
		if prewarmTarget and config:Get("enabled") then
			local ok, err = pcall(world.prewarm, world, prewarmTarget)
			if not ok then
				Log.debug("prewarm failed: %s", tostring(err))
			end
		end
	end))
	stack.schedulePrewarm = function(inst)
		prewarmTarget = inst or world.currentScript
		if prewarmTarget and config:Get("prewarm") then
			prewarm:Trigger()
		end
	end
	local diagnosticsTarget = {}
	local diagnosticsDebounce = maid:Give(Debouncer.new(0.35, function()
		for uri in diagnosticsTarget do
			diagnosticsTarget[uri] = nil
			self:_publishDiagnostics(uri)
		end
	end))
	stack.scheduleDiagnostics = function(uri)
		diagnosticsTarget[uri] = true
		diagnosticsDebounce:Trigger()
	end

	maid:Give(registry.ScriptChanged:Connect(function(inst)
		world:invalidate(inst)
		stack.schedulePrewarm(world.editing or world.currentScript)
	end))
	maid:Give(registry.StructureChanged:Connect(function()
		world:reset()
		stack.schedulePrewarm(world.currentScript)
	end))
	registry:Start({ synchronous = true })

	-- documents that were open before a rebuild get their scripts back
	for uri, doc in self._docs do
		doc.inst = self:_instanceFor(uri, doc.text)
		if doc.inst then
			self._open[doc.inst] = doc.text
		end
	end
	self._log(`workspace mapped from {workspace.mode} ({workspace.files} files, reflection: {reflectionSource})`)
end

function Server:_instanceFor(uri, text)
	local path = Uri.toPath(uri)
	local stack = self.stack
	if not (path and stack) then
		return nil
	end
	local inst = stack.workspace.byPath[stack.workspace:_key(path)]
	if inst then
		return inst
	end
	local created, isNew = stack.workspace:ensureLoose(path, text)
	if isNew then
		stack.registry:noteDocumentChanged(created)
	end
	return created
end

-- ===== transport helpers =====

function Server:_reply(id, result)
	self._send({ jsonrpc = "2.0", id = id, result = result })
end

function Server:_replyError(id, code, message)
	self._send({ jsonrpc = "2.0", id = id, error = { code = code, message = message } })
end

function Server:_notify(method, params)
	self._send({ jsonrpc = "2.0", method = method, params = params })
end

-- ===== settings =====

--- Applies `{ key = value }` to the core config, ignoring unknown keys and wrong types (a bad setting must not stop the server).
-- The core's defaults are sized for the Studio plugin, which shares a thread with the editor and must answer in ~100 ms.
-- Here the engine is its own process and luau-lsp has already answered, so the ONE-TIME costs (booting the project by running
-- the entry scripts, evaluating big modules) get room to finish. Cut short, they leave a different half-built world on every
-- run (the same question answered differently depending on machine speed). Per-request limits stay under the proxy's wait.
-- User settings (linter.advanced) are applied after these and win.
Server.PROCESS_DEFAULTS = {
	requestBudgetMs = 450,
	fuelPerRequest = 1000000,
	moduleMs = 1500,
	moduleFuel = 1500000,
	observeMs = 6000,
	observeFuel = 6000000,
	prewarmMs = 7000,
	maxEntryScripts = 24,
	maxLoopBudget = 400000,
	maxLoopIterations = 20000,
	slowRequestMs = 900,
}

function Server:_applySettings(settings)
	local config = self._config
	if type(settings) ~= "table" or not config then
		return
	end
	for key, value in settings do
		local ok = pcall(config.Set, config, key, value)
		if not ok then
			self._log(`ignored setting '{tostring(key)}'`)
		end
	end
	if settings.debug ~= nil then
		self.stack.Log.setDebug(config:Get("debug"))
	end
end

-- ===== handlers =====

function Server:_initialize(params)
	local root = params.rootUri and Uri.toPath(params.rootUri)
	if not root and params.workspaceFolders and params.workspaceFolders[1] then
		root = Uri.toPath(params.workspaceFolders[1].uri)
	end
	self._rootPath = root or self._root
	self._options = type(params.initializationOptions) == "table" and params.initializationOptions or {}
	local Config = self._loader.require("Core/Config")
	self._config = Config.new()
	self:_applySettings(Server.PROCESS_DEFAULTS)
	local ok, err = pcall(self._build, self)
	if not ok then
		self._log("initial build failed: " .. tostring(err)) -- the server still answers (with nothing) instead of dying
	else
		self:_applySettings(self._options.linter)
	end
	self._initialized = true
	return {
		capabilities = {
			textDocumentSync = { openClose = true, change = 2, save = { includeText = false } },
			completionProvider = { triggerCharacters = TRIGGERS, resolveProvider = false },
		},
		serverInfo = { name = "linter-lsp", version = "0.1.0" },
	}
end

function Server:_didOpen(params)
	local item = params.textDocument
	local stack = self.stack
	if not stack then
		return
	end
	local doc = { text = item.text, version = item.version }
	self._docs[item.uri] = doc
	doc.inst = self:_instanceFor(item.uri, item.text)
	if doc.inst then
		self._open[doc.inst] = item.text
		stack.world.editing = nil
		stack.registry:noteDocumentChanged(doc.inst)
		stack.schedulePrewarm(doc.inst)
		stack.scheduleDiagnostics(item.uri)
	end
end

--- Applies LSP content changes (full replacement or ranges, positions in UTF-16 units) to a text.
local function applyChanges(text, changes)
	for _, change in changes do
		if change.range then
			local starts = Text.lineStarts(text)
			local from = Text.offsetAt(text, starts, change.range.start.line, change.range.start.character)
			local to = Text.offsetAt(text, starts, change.range["end"].line, change.range["end"].character)
			text = string.sub(text, 1, from - 1) .. change.text .. string.sub(text, to)
		else
			text = change.text
		end
	end
	return text
end
Server.applyChanges = applyChanges

function Server:_didChange(params)
	local doc = self._docs[params.textDocument.uri]
	local stack = self.stack
	if not (doc and stack) then
		return
	end
	doc.text = applyChanges(doc.text, params.contentChanges or {})
	doc.version = params.textDocument.version
	doc.starts = nil
	if doc.inst then
		self._open[doc.inst] = doc.text
		stack.world.editing = doc.inst
		stack.registry:noteDocumentChanged(doc.inst)
		stack.schedulePrewarm(doc.inst)
		stack.scheduleDiagnostics(params.textDocument.uri)
	end
end

function Server:_didClose(params)
	local uri = params.textDocument.uri
	local doc = self._docs[uri]
	if doc and doc.inst and self.stack then
		self._open[doc.inst] = nil
		-- the file on disk is the truth again
		local path = Uri.toPath(uri)
		if path then
			local updates = self.stack.workspace:update(path, "changed")
			self:_applyUpdates(updates)
		end
		self:_notify("textDocument/publishDiagnostics", { uri = uri, diagnostics = {} })
	end
	self._docs[uri] = nil
end

--- Tells the engine what the workspace layer changed.
function Server:_applyUpdates(updates)
	local stack = self.stack
	if not stack then
		return
	end
	for _, update in updates do
		if update.op == "rebuild" then
			local ok, err = pcall(self._build, self)
			if not ok then
				self._log("rebuild failed: " .. tostring(err))
			end
			return
		end
		local inst = update.inst
		local service = Workspace.serviceOf(stack.game, inst)
		if update.op == "changed" then
			self:_fire(inst, "Changed", "Source")
			stack.registry:noteDocumentChanged(inst)
		elseif update.op == "added" then
			if service then
				self:_fire(service, "DescendantAdded", inst)
			end
		elseif update.op == "removed" then
			if service then
				self:_fire(service, "DescendantRemoving", inst)
			end
			inst.Parent = nil
		end
	end
end

function Server:_didChangeWatchedFiles(params)
	local stack = self.stack
	if not stack then
		return
	end
	local kinds = { "created", "changed", "deleted" }
	for _, change in params.changes or {} do
		local path = Uri.toPath(change.uri)
		local kind = kinds[change.type]
		if path and kind then
			local doc = self._docs[change.uri]
			if not (doc and kind == "changed") then -- an open file's truth is the editor, not the disk
				local ok, updates = pcall(stack.workspace.update, stack.workspace, path, kind)
				if ok then
					self:_applyUpdates(updates)
				end
			end
		end
	end
end

function Server:_document(uri)
	local doc = self._docs[uri]
	if doc and not doc.starts then
		doc.starts = Text.lineStarts(doc.text)
	end
	return doc
end

local LIVE_KINDS = { ["call-string"] = true, ["index-string"] = true }

function Server:_completion(params)
	local stack = self.stack
	local doc = self:_document(params.textDocument.uri)
	local empty = { isIncomplete = false, items = {}, linter = { hide = {} } }
	if not (stack and doc and doc.inst) then
		return empty
	end
	local text, starts = doc.text, doc.starts
	local cursor = Text.toEngine(text, starts, params.position.line, params.position.character)
	local inst = doc.inst
	local request = {
		position = cursor,
		textDocument = {
			document = {
				GetText = function()
					return text
				end,
				GetScript = function()
					return inst
				end,
			},
			script = inst,
		},
	}
	local response = { items = {} }
	stack.engine:complete(request, response)
	local stats = stack.engine.lastStats
	return {
		isIncomplete = stats ~= nil and LIVE_KINDS[stats.kind] == true,
		items = Convert.items(response.items, text, starts, cursor),
		linter = { hide = stack.engine:hiddenNames() },
	}
end

function Server:_publishDiagnostics(uri)
	local stack = self.stack
	local doc = self:_document(uri)
	if not (stack and doc and doc.inst) then
		return
	end
	local result = stack.checker:run({ script = doc.inst })
	self:_notify("textDocument/publishDiagnostics", {
		uri = uri,
		diagnostics = Convert.diagnostics(result.diagnostics, doc.text, doc.starts),
	})
end

function Server:_report()
	local stack = self.stack
	if not stack then
		return { lines = {} }
	end
	local report = Report.collect({ registry = stack.registry, sources = stack.sources, world = stack.world, engine = stack.engine })
	local lines = {}
	for _, line in Report.format(report) do
		lines[#lines + 1] = line
	end
	return { lines = lines }
end

local REQUESTS = {
	initialize = Server._initialize,
	["textDocument/completion"] = Server._completion,
	["linter/report"] = Server._report,
}
local NOTIFICATIONS = {
	["textDocument/didOpen"] = Server._didOpen,
	["textDocument/didChange"] = Server._didChange,
	["textDocument/didClose"] = Server._didClose,
	["workspace/didChangeWatchedFiles"] = Server._didChangeWatchedFiles,
	["workspace/didChangeConfiguration"] = function(self, params)
		local settings = params and params.settings
		self:_applySettings(type(settings) == "table" and (settings.linter or settings) or nil)
	end,
}

-- ===== protection =====

function Server:_breakerOpen(method)
	local entry = self._failures[method]
	return entry ~= nil and entry.open ~= nil and self._clock() < entry.open
end

function Server:_noteResult(method, ok)
	local entry = self._failures[method]
	if ok then
		if entry then
			entry.count = 0
		end
		return
	end
	if not entry then
		entry = { count = 0 }
		self._failures[method] = entry
	end
	entry.count += 1
	if entry.count >= MAX_FAILURES then
		entry.count = 0
		entry.open = self._clock() + BREAKER_SECONDS
		self._log(`{method} failed {MAX_FAILURES} times in a row; paused for {BREAKER_SECONDS}s`)
	end
end

--- Frees memory when the process has grown past its limit: the caches are rebuilt on demand.
function Server:_checkMemory()
	if collectgarbage("count") > MEMORY_LIMIT_KB then
		self._log("memory limit reached; dropping caches")
		if self.stack then
			self.stack.sources:clear()
			self.stack.world:reset()
		end
		collectgarbage("collect")
	end
end

--- One incoming message. Never throws.
function Server:handle(message)
	if type(message) ~= "table" then
		return
	end
	local method, id = message.method, message.id
	self._requests += 1
	if self._requests % 200 == 0 then
		pcall(self._checkMemory, self)
	end
	if method == nil then
		return -- a response to something we never asked
	end
	if method == "shutdown" then
		self._shutdown = true
		if id ~= nil then
			self:_reply(id, nil)
		end
		return
	end
	if method == "exit" then
		self.exitCode = self._shutdown and 0 or 1
		return
	end
	if self._shutdown and id ~= nil then
		self:_replyError(id, -32600, "server is shutting down")
		return
	end
	if method ~= "initialize" and not self._initialized then
		if id ~= nil then
			self:_replyError(id, -32002, "server not initialized")
		end
		return
	end

	if id ~= nil then
		local handler = REQUESTS[method]
		if not handler then
			self:_replyError(id, -32601, "method not found: " .. tostring(method))
			return
		end
		if self:_breakerOpen(method) then
			self:_reply(id, method == "textDocument/completion" and { isIncomplete = false, items = {}, linter = { hide = {} } } or nil)
			return
		end
		local ok, result = pcall(handler, self, message.params or {})
		self:_noteResult(method, ok)
		if ok then
			self:_reply(id, result)
		else
			self._log(`{method} failed: {tostring(result)}`)
			self:_replyError(id, -32603, "internal error: " .. tostring(result))
		end
	else
		local handler = NOTIFICATIONS[method]
		if handler then
			local ok, err = pcall(handler, self, message.params or {})
			self:_noteResult(method, ok)
			if not ok then
				self._log(`{method} failed: {tostring(err)}`)
			end
		end
	end
end

return Server
