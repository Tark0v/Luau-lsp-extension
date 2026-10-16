--[[
	SourceStore: bounded cache of script text and parsed ASTs.

	Invalidation is event driven (Registry calls :invalidate when a script changes), so reading is
	never a poll. Oversize sources are never parsed. The cache evicts least-recently-used entries.
]]

local Lexer = require(script.Parent.Parent.Language.Lexer)
local Parser = require(script.Parent.Parent.Language.Parser)
local Annotations = require(script.Parent.Parent.Language.Annotations)

local SourceStore = {}
SourceStore.__index = SourceStore

local MAX_ENTRIES = 300
local EVICT_COUNT = 100
local MAX_TAG_ENTRIES = 3000

function SourceStore.new(host, config)
	return setmetatable({
		_host = host,
		_config = config,
		_entries = {},
		_count = 0,
		_tick = 0,
		_tags = {}, -- script -> file-level markers (false = none)
		_tagCount = 0,
	}, SourceStore)
end

function SourceStore:_evict()
	local list = {}
	for inst, entry in self._entries do
		list[#list + 1] = { inst = inst, used = entry.used }
	end
	table.sort(list, function(a, b)
		return a.used < b.used
	end)
	for index = 1, math.min(EVICT_COUNT, #list) do
		self._entries[list[index].inst] = nil
		self._count -= 1
	end
end

function SourceStore:_entry(inst)
	self._tick += 1
	local entry = self._entries[inst]
	if entry then
		entry.used = self._tick
		return entry
	end
	if self._count >= MAX_ENTRIES then
		self:_evict()
	end
	local ok, text = pcall(self._host.readSource, inst)
	entry = { used = self._tick }
	if ok and type(text) == "string" then
		if #text > self._config:Get("maxSourceBytes") then
			entry.oversize = true
		else
			entry.text = text
		end
	end
	self._entries[inst] = entry
	self._count += 1
	if entry.text and self._tags[inst] == nil and inst.ClassName == "ModuleScript" then
		-- the text is in hand anyway: note the file-level markers now, so listing a folder later does not re-read every script
		if self._tagCount >= MAX_TAG_ENTRIES then
			self._tags, self._tagCount = {}, 0
		end
		self._tags[inst] = Annotations.fileTags(entry.text) or false
		self._tagCount += 1
	end
	return entry
end

--- The cached text of a script, or nil when nothing is cached (never reads the script).
function SourceStore:peek(inst)
	local entry = self._entries[inst]
	return entry and entry.text or nil
end

--- Uncached read (used for one-off scans such as finding _G writers).
function SourceStore:read(inst)
	local ok, text = pcall(self._host.readSource, inst)
	if ok and type(text) == "string" then
		return text
	end
	return nil
end

function SourceStore:text(inst)
	return self:_entry(inst).text
end

--- Parsed chunk, or nil when the script is unreadable, too large or could not be parsed. A script that
--- fails to parse is remembered as failed (until it changes), so it costs one attempt, not one per request.
function SourceStore:parse(inst)
	local entry = self:_entry(inst)
	if entry.chunk then
		return entry.chunk
	end
	if entry.failed or not entry.text then
		return nil
	end
	local ok, chunk = pcall(function()
		return Parser.parse(Lexer.lex(entry.text))
	end)
	if not ok then
		entry.failed = true
		return nil
	end
	chunk.tokens = nil -- the AST carries everything the interpreter needs; the raw token arrays are only memory
	entry.chunk = chunk
	return chunk
end

--- Why `parse` gave nothing for this script (short, for the Report button), or nil.
function SourceStore:problem(inst)
	local entry = self._entries[inst]
	if not entry then
		return nil
	end
	if entry.oversize then
		return "too large to analyse (over maxSourceBytes)"
	elseif entry.failed then
		return "could not be parsed"
	elseif not entry.text then
		return "source could not be read"
	end
	return nil
end

--- File-level `--@Private` / `--@Hidden` markers in the header comment of a script, or nil. Cached (header only).
function SourceStore:fileTags(inst)
	local cached = self._tags[inst]
	if cached ~= nil then
		return cached or nil
	end
	local class = inst.ClassName
	local tags = false
	if class == "ModuleScript" then
		local text = self:read(inst)
		tags = text and Annotations.fileTags(text) or false
	end
	if self._tagCount >= MAX_TAG_ENTRIES then
		self._tags, self._tagCount = {}, 0
	end
	self._tags[inst] = tags
	self._tagCount += 1
	return tags or nil
end

function SourceStore:invalidate(inst)
	if self._entries[inst] then
		self._entries[inst] = nil
		self._count -= 1
	end
	if self._tags[inst] ~= nil then
		self._tags[inst] = nil
		self._tagCount -= 1
	end
end

function SourceStore:clear()
	self._entries = {}
	self._count = 0
	self._tags, self._tagCount = {}, 0
end

return SourceStore
