--[[
	Annotations: `--@Tag` markers in comments, the way a person marks their own code for the autocomplete.

	  --@Private             hidden from completions everywhere except inside the script that defines it
	  --@Hidden              hidden from completions everywhere, even in the script that defines it
	  --@Public              shown even though it would be hidden (a `_name` when hideUnderscore is on)
	  --@Deprecated [why]    shown struck through
	  --@param name Type     the type of an unannotated parameter
	  --@return Type         the type a function returns when its body cannot tell
	  --@type Type           the type of the variable / field declared on this line or the next

	A marker sits in the comment block directly above a declaration (like a doc comment) or at the end of the
	declaration's own line. At the very top of a ModuleScript, followed by a blank line, `--@Private` hides the
	whole module (it stops showing up in `require` paths and instance listings).

	Tags are matched case-insensitively. Everything here is plain string work on comment text.
]]

local Annotations = {}

local find, sub, match, lower = string.find, string.sub, string.match, string.lower

--- Tag name -> what the completion popup shows when the marker itself is being typed.
Annotations.CATALOG = {
	{ name = "Private", detail = "hide from autocomplete outside this script", doc = "Members marked `--@Private` are only offered inside the script that defines them." },
	{ name = "Hidden", detail = "hide from autocomplete everywhere", doc = "Members marked `--@Hidden` are never offered, not even in the script that defines them." },
	{ name = "Public", detail = "always show", doc = "Overrides hiding, e.g. for a `_name` member when `hideUnderscore` is on." },
	{ name = "Deprecated", detail = "show struck through", doc = "`--@Deprecated reason` shows the member with a strike-through and the reason." },
	{ name = "param", detail = "type of a parameter", doc = "`--@param name Type` gives an unannotated parameter a type." },
	{ name = "return", detail = "type of the result", doc = "`--@return Type` gives a function a result type when its body cannot tell." },
	{ name = "type", detail = "type of a variable or field", doc = "`--@type Type` gives the declaration below (or on this line) a type." },
}

local KNOWN = {}
for _, entry in Annotations.CATALOG do
	KNOWN[lower(entry.name)] = true
end

--- First marker on a comment line: tag (lowercase), rest of the line. Nil when the line is ordinary text.
function Annotations.parseLine(text)
	local tag, rest = match(text, "^%s*@(%a+)%s*(.-)%s*$")
	if tag then
		tag = lower(tag)
		if KNOWN[tag] then
			return tag, rest
		end
	end
	return nil
end

local function addTag(tags, tag, rest)
	if tag == "param" then
		local name, ptype = match(rest, "^([%a_][%w_]*)%s*:?%s*(.-)$")
		if name and ptype ~= "" then
			tags.params = tags.params or {}
			tags.params[name] = ptype
		end
	elseif tag == "return" then
		if rest ~= "" then
			tags.ret = rest
		end
	elseif tag == "type" then
		if rest ~= "" then
			tags.type = rest
		end
	elseif tag == "deprecated" then
		tags.deprecated = rest ~= "" and rest or true
	else
		tags[tag] = true -- private / hidden / public
	end
end

--- Splits a doc comment (and an optional trailing comment from the declaration's own line) into the text to
--- show and the markers found. Marker lines that only configure visibility are removed from the text.
--- Returns doc (string|nil), tags (table|nil).
function Annotations.extract(doc, trailing)
	local tags
	local kept
	if doc then
		for line in string.gmatch(doc .. "\n", "(.-)\n") do
			local tag, rest = Annotations.parseLine(line)
			if tag then
				tags = tags or {}
				addTag(tags, tag, rest)
				if tag ~= "private" and tag ~= "hidden" and tag ~= "public" and tag ~= "type" then
					kept = kept or {}
					kept[#kept + 1] = "@" .. tag .. (rest ~= "" and (" " .. rest) or "")
				end
			else
				kept = kept or {}
				kept[#kept + 1] = line
			end
		end
	end
	if trailing then
		local tag, rest = Annotations.parseLine(trailing)
		if tag then
			tags = tags or {}
			addTag(tags, tag, rest)
		end
	end
	local text = kept and table.concat(kept, "\n") or nil
	if text then
		text = string.gsub(text, "^%s+", "")
		text = string.gsub(text, "%s+$", "")
		if text == "" then
			text = nil
		end
	end
	return text, tags
end

--- The visibility tag in one comment line (used when type bodies are flattened to text), or nil.
function Annotations.visibilityOf(text)
	local tag = Annotations.parseLine(text)
	if tag == "private" or tag == "hidden" or tag == "public" or tag == "deprecated" then
		return tag
	end
	return nil
end

--[[
	File-level markers: the comment block at the very top of a ModuleScript.
	It describes the FILE (not the first declaration) when a blank line follows it, or when the marker says
	`file` / `module` (`--@Private file`). Returns { private = true } / { hidden = true } or nil.
]]
function Annotations.fileTags(text)
	local head = sub(text, 1, 4096)
	local tags
	local lines = {}
	local fileMarked = false
	local pos = 1
	local sawBlank = false
	while pos <= #head do
		local nl = find(head, "\n", pos, true)
		local line = sub(head, pos, (nl or #head + 1) - 1)
		pos = (nl or #head) + 1
		local trimmed = match(line, "^%s*(.-)%s*$")
		if trimmed == "" then
			if #lines > 0 then
				sawBlank = true
				break
			end
		elseif sub(trimmed, 1, 3) == "--!" then
			-- a directive (`--!strict`) belongs to no block
		elseif sub(trimmed, 1, 2) == "--" and not find(trimmed, "^%-%-%[=*%[") then
			local body = match(trimmed, "^%-%-+%s*(.*)$")
			lines[#lines + 1] = body
			local tag, rest = Annotations.parseLine(body)
			if (tag == "private" or tag == "hidden") and (rest == "file" or rest == "module") then
				fileMarked = true
			end
		else
			break -- code (or a block comment, which we do not treat as a header)
		end
	end
	if #lines == 0 or not (sawBlank or fileMarked) then
		return nil
	end
	for _, body in lines do
		local tag, rest = Annotations.parseLine(body)
		if tag == "private" or tag == "hidden" then
			tags = tags or {}
			tags[tag] = true
		elseif tag == "deprecated" then
			tags = tags or {}
			tags.deprecated = rest ~= "" and rest or true
		end
	end
	return tags
end

return Annotations
