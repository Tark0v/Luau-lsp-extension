--[[
	Host: everything the engine needs from the outside world, injected so the same code runs in
	Studio and under Lune tests.

	  game          DataModel
	  readSource    function(script) -> string            (live editor text in Studio)
	  connect       function(instance, eventName, fn) -> connection   (nil-safe in tests)
	  yield         function() | nil                       (nil = never yield, used by tests)
	  clock         function() -> seconds
]]

local Host = {}

function Host.new(fields)
	return {
		game = fields.game,
		readSource = fields.readSource,
		connect = fields.connect or function()
			return { Disconnect = function() end }
		end,
		yield = fields.yield,
		clock = fields.clock or os.clock,
	}
end

--- The real thing: ScriptEditorService for live text, real signals, task.wait to yield.
function Host.studio(env)
	local editor = env.ScriptEditorService
	return Host.new({
		game = env.game,
		readSource = function(script)
			if editor then
				local ok, text = pcall(editor.GetEditorSource, editor, script)
				if ok and type(text) == "string" then
					return text
				end
			end
			return script.Source
		end,
		connect = function(instance, eventName, fn)
			return instance[eventName]:Connect(fn)
		end,
		yield = function()
			task.wait()
		end,
	})
end

return Host
