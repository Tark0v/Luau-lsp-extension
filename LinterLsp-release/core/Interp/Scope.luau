--[[
	Scope: lexical variable scope. Values are never Lua nil (the abstract Nil is a value).
]]

local Scope = {}
Scope.__index = Scope

function Scope.new(parent)
	return setmetatable({ vars = {}, parent = parent }, Scope)
end

function Scope:lookup(name)
	local scope = self
	while scope do
		local v = scope.vars[name]
		if v ~= nil then
			return v
		end
		scope = scope.parent
	end
	return nil
end

function Scope:declare(name, value)
	self.vars[name] = value
end

--- Assigns to the nearest existing binding; returns false when there is none.
function Scope:assign(name, value)
	local scope = self
	while scope do
		if scope.vars[name] ~= nil then
			scope.vars[name] = value
			return true
		end
		scope = scope.parent
	end
	return false
end

--- Type aliases are scoped like variables: `type Foo = ...` is visible in its block and the blocks inside it.
function Scope:declareType(name, decl)
	local types = self.types
	if not types then
		types = {}
		self.types = types
	end
	types[name] = decl
end

function Scope:lookupType(name)
	local scope = self
	while scope do
		local types = scope.types
		if types then
			local decl = types[name]
			if decl then
				return decl
			end
		end
		scope = scope.parent
	end
	return nil
end

function Scope:root()
	local scope = self
	while scope.parent do
		scope = scope.parent
	end
	return scope
end

return Scope
