--[[
	Report: what Linter could not fully understand, in plain lines for the Output window (the toolbar's Report button).

	Everything it lists is a script, not a bug: a syntax error that is being typed, a module too big or too slow to
	analyse, a statement the evaluator had to skip. Linter keeps working around all of them; this just says where
	completions may be thinner than expected, so nobody has to guess why `Module.` shows less than it should.

	collect() is bounded (it parses at most `limit` scripts, cached ones for free); format() is pure.
]]

local Report = {}

local DEFAULT_LIMIT = 500

--- deps: registry, sources, world, engine (optional). Returns
--- { tracked, checked, truncated, problems = { { path, reason } ... }, last = engine.lastStats }
function Report.collect(deps, limit)
	limit = limit or DEFAULT_LIMIT
	local registry, sources, world = deps.registry, deps.sources, deps.world
	local list = registry:Scripts()
	local problems, seen = {}, {}
	local function add(inst, reason)
		if not seen[inst] then
			seen[inst] = true
			problems[#problems + 1] = { path = inst:GetFullName(), reason = reason }
		end
	end

	local checked = 0
	for _, inst in list do
		if checked >= limit then
			break
		end
		checked += 1
		local chunk = sources:parse(inst)
		if not chunk then
			add(inst, sources:problem(inst) or "could not be read")
		else
			local first = chunk.errors[1]
			if first then
				add(inst, `syntax error near line {first.line}` .. (#chunk.errors > 1 and ` (+{#chunk.errors - 1} more)` or ""))
			end
		end
	end
	for _, entry in world:problemList() do
		add(entry.script, entry.reason)
	end
	table.sort(problems, function(a, b)
		return a.path < b.path
	end)
	return {
		tracked = #list,
		checked = checked,
		truncated = registry.Truncated,
		problems = problems,
		last = deps.engine and deps.engine.lastStats or nil,
	}
end

local MAX_LISTED = 40

--- Lines of text for a collected report.
function Report.format(report)
	local lines = {}
	lines[#lines + 1] = `{report.tracked} scripts tracked`
		.. (report.truncated and " (the scan hit its limits; raise maxScripts / maxTraversalNodes for more)" or "")
		.. (report.checked < report.tracked and `, {report.checked} checked` or "")
	if #report.problems == 0 then
		lines[#lines + 1] = "nothing to report: every checked script was understood"
	else
		lines[#lines + 1] = `{#report.problems} script(s) were only partly understood:`
		for index, problem in report.problems do
			if index > MAX_LISTED then
				lines[#lines + 1] = `  ... and {#report.problems - MAX_LISTED} more`
				break
			end
			lines[#lines + 1] = `  {problem.path}: {problem.reason}`
		end
	end
	local last = report.last
	if last then
		lines[#lines + 1] = `last completion: {last.status}`
			.. (last.ms and string.format(" in %.1f ms", last.ms) or "")
			.. (last.added and `, {last.added} items added` or "")
	end
	return lines
end

return Report
