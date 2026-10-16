--[[
	Traversal: bounded walks over the DataModel. Everything that touches user instances goes through
	here so a place full of junk cannot hurt us:

	  * iterative DFS with an explicit stack (no recursion, no giant GetDescendants() table)
	  * hard cap on nodes visited, and a cap on how many children of one node are even considered;
	    an over-wide node is only searched for scripts / containers
	  * optional time-slicing (opts.yield) so a long scan never freezes Studio
	  * Terrain and Camera are never entered
]]

local Traversal = {}

local NO_DESCEND = { Terrain = true, Camera = true }

--- Classes worth descending into when a node has more children than we are willing to look at.
local CONTAINERS = {
	Folder = true, Model = true, Configuration = true, Actor = true, Tool = true, Accessory = true,
	Script = true, LocalScript = true, ModuleScript = true,
	ScreenGui = true, Frame = true, ScrollingFrame = true, BillboardGui = true, SurfaceGui = true,
}
Traversal.CONTAINERS = CONTAINERS

function Traversal.isScript(inst)
	local ok, result = pcall(inst.IsA, inst, "LuaSourceContainer")
	return ok and result == true
end

--- Children of one instance, truncated to `cap`. Returns list, truncated.
function Traversal.children(inst, cap)
	local ok, list = pcall(inst.GetChildren, inst)
	if not ok then
		return {}, false
	end
	if #list > cap then
		return table.move(list, 1, cap, 1, {}), true
	end
	return list, false
end

--[[
	Visits every descendant of `root` (not root itself) depth-first, first child first.

	opts: maxNodes, maxChildrenPerNode, clock, sliceMs, yield (function), cancelled (function)
	visit(node) may return false (do not descend into node) or "stop" (end the walk).
	Returns visitedCount, truncated.
]]
function Traversal.walk(root, opts, visit)
	local maxNodes = opts.maxNodes or 20000
	local perNode = opts.maxChildrenPerNode or 2000
	local clock = opts.clock or os.clock
	local yield = opts.yield
	local sliceSeconds = (opts.sliceMs or 4) / 1000

	local stack = {}
	local count, truncated = 0, false

	local function pushChildren(node)
		if NO_DESCEND[node.ClassName] then
			return
		end
		local ok, kids = pcall(node.GetChildren, node)
		if not ok then
			return
		end
		if #kids > perNode then
			truncated = true
			local filtered, n = {}, 0
			for _, kid in kids do
				if CONTAINERS[kid.ClassName] then
					n += 1
					filtered[n] = kid
					if n >= perNode then
						break
					end
				end
			end
			kids = filtered
		end
		for index = #kids, 1, -1 do
			stack[#stack + 1] = kids[index]
		end
	end

	pushChildren(root)
	local sliceStart = clock()
	while #stack > 0 do
		local node = table.remove(stack)
		count += 1
		if count > maxNodes then
			truncated = true
			break
		end
		local verdict = visit(node)
		if verdict == "stop" then
			break
		end
		if verdict ~= false then
			pushChildren(node)
		end
		if yield and clock() - sliceStart > sliceSeconds then
			yield()
			if opts.cancelled and opts.cancelled() then
				return count, true
			end
			sliceStart = clock()
		end
	end
	return count, truncated
end

--- Descendants as a list, capped at opts.limit. Returns list, truncated.
function Traversal.descendants(root, opts)
	local limit = opts.limit or 4000
	local out = {}
	local _, truncated = Traversal.walk(root, opts, function(node)
		out[#out + 1] = node
		if #out >= limit then
			return "stop"
		end
	end)
	if #out >= limit then
		truncated = true
	end
	return out, truncated
end

--- First descendant with the given Name (bounded). Returns instance or nil.
function Traversal.findNamed(root, name, opts)
	local found
	Traversal.walk(root, opts, function(node)
		if node.Name == name then
			found = node
			return "stop"
		end
	end)
	return found
end

return Traversal
