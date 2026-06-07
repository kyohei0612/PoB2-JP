-- PoeJP — CSV 翻訳ローダー + DrawString 用ヘルパー
local M = {
	strings = {},
	uiLabels = {},
	modExact = {},
	labelList = nil,
	count = 0,
	enabled = false,
	locale = "ja-JP",
}

local function script_root()
	return GetScriptPath() .. "/"
end

local function read_locale()
	local path = script_root() .. "Data/Settings.conf"
	local file = io.open(path, "r")
	if not file then
		return M.locale
	end
	local content = file:read("*a")
	file:close()
	return content:match("TranslateTL=(%S+)") or M.locale
end

local function unquote_csv_field(field)
	if field:sub(1, 1) == '"' and field:sub(-1) == '"' then
		return field:sub(2, -2):gsub('""', '"')
	end
	return field
end

local function parse_csv_row(line)
	if line == "" then
		return nil
	end
	if line:sub(1, 1) == '"' then
		local close = line:find('",', 2, true)
		if close then
			local source = line:sub(2, close - 1):gsub('""', '"')
			local translation = unquote_csv_field(line:sub(close + 2))
			return source, translation
		end
	end
	local comma = line:find(",", 1, true)
	if not comma then
		return nil
	end
	return unquote_csv_field(line:sub(1, comma - 1)), unquote_csv_field(line:sub(comma + 1))
end

local function csv_records(content)
	local records = {}
	local start = 1
	local index = 1
	local inQuote = false
	while index <= #content do
		local char = content:sub(index, index)
		if char == '"' then
			if inQuote and content:sub(index + 1, index + 1) == '"' then
				index = index + 1
			else
				inQuote = not inQuote
			end
		elseif (char == "\n" or char == "\r") and not inQuote then
			local record = content:sub(start, index - 1):gsub("\r$", "")
			if record ~= "" then
				records[#records + 1] = record
			end
			if char == "\r" and content:sub(index + 1, index + 1) == "\n" then
				index = index + 1
			end
			start = index + 1
		end
		index = index + 1
	end
	local tail = content:sub(start):gsub("\r$", "")
	if tail ~= "" then
		records[#records + 1] = tail
	end
	return records
end

local NOT_SUPPORTED_SUFFIXES = {
	" ^8(Not supported in PoB yet)",
	" (Not supported in PoB yet)",
}

local function split_lines(text)
	local lines = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			lines[#lines + 1] = line
		end
	end
	return lines
end

local function is_dangerous_template_source(source)
	return source:find("{%d+}") and not source:find("%a")
end

local function has_label_colon(text)
	return text:sub(-1) == ":" or text:sub(-3) == "："
end

local function strip_label_colon(text)
	if text:sub(-1) == ":" then
		return text:sub(1, -2)
	end
	if text:sub(-3) == "：" then
		return text:sub(1, -4)
	end
	return text
end

local function register_string(source, translation)
	M.strings[source] = translation
	if source:find("\n", 1, true) then
		return
	end
	if source:sub(-1) == ":" then
		local base = source:sub(1, -2):gsub("%s+$", "")
		if base ~= "" and not M.strings[base] then
			M.strings[base] = strip_label_colon(translation)
		end
	elseif not M.strings[source .. ":"] then
		local colonTranslation = translation
		if not has_label_colon(colonTranslation) then
			colonTranslation = colonTranslation .. ":"
		end
		M.strings[source .. ":"] = colonTranslation
	end
end

local function register_pair(source, translation)
	if not source or source == "" or not translation then
		return
	end
	if is_dangerous_template_source(source) then
		return
	end
	if translation ~= source then
		register_string(source, translation)
		if source:find(" % ", 1, true) then
			local sourceTemplate, sourceCount = source:gsub("%%", "{0}%%", 1)
			local translationTemplate, translationCount = translation:gsub("%%", "{0}%%", 1)
			if sourceCount == 1 and translationCount == 1 and sourceTemplate ~= source then
				register_string(sourceTemplate, translationTemplate)
			end
		end
	end
	if not source:find("\n", 1, true) then
		return
	end
	local enLines = split_lines(source)
	local jaLines = split_lines(translation)
	for index, enLine in ipairs(enLines) do
		local jaLine = jaLines[index]
		if jaLine and jaLine ~= "" and jaLine ~= enLine then
			register_string(enLine, jaLine)
		end
	end
end

local function load_csv_file(path)
	local file = io.open(path, "r")
	if not file then
		return 0
	end
	local content = file:read("*a")
	file:close()
	local loaded = 0
	local first = true
	for _, line in ipairs(csv_records(content)) do
		if first then
			line = line:gsub("^\239\187\191", "")
			first = false
		end
		local source, translation = parse_csv_row(line)
		if source and translation and source ~= "" then
			register_pair(source, translation)
			loaded = loaded + 1
		end
	end
	return loaded
end

local function load_translations()
	M.locale = read_locale()
	local dir = script_root() .. "Data/Translate/" .. M.locale
	local manifest = script_root() .. "Modules/PoeJP/manifest.lua"
	local files = {}
	local manifestChunk = loadfile(manifest)
	if manifestChunk then
		local ok, listed = pcall(manifestChunk)
		if ok and type(listed) == "table" then
			files = listed
		end
	end
	if #files == 0 then
		local handle = io.popen('dir /b "' .. dir:gsub("/", "\\") .. '\\*.csv" 2>nul')
		if handle then
			for name in handle:lines() do
				if name:lower():match("%.csv$") then
					table.insert(files, name)
				end
			end
			handle:close()
		end
	end
	local total = 0
	for _, name in ipairs(files) do
		total = total + load_csv_file(dir .. "/" .. name)
	end
	M.count = 0
	for _ in pairs(M.strings) do
		M.count = M.count + 1
	end
	M.enabled = M.count > 0
	return total
end

local function load_locale_modules()
	local ok, display = pcall(LoadModule, "Modules/PoeJP/DisplayLocale")
	if ok and type(display) == "table" then
		for key, value in pairs(display.strings or {}) do
			if type(key) == "string" and type(value) == "string" and key ~= value then
				M.uiLabels[key] = value
			end
		end
	end
	local okUi, ui = pcall(LoadModule, "Modules/PoeJP/UiLocale")
	if okUi and type(ui) == "table" then
		for key, value in pairs(ui.strings or {}) do
			if type(key) == "string" and type(value) == "string" and key ~= value then
				M.uiLabels[key] = value
			end
		end
	end
end

local function getLabelList()
	if M.labelList then
		return M.labelList
	end
	M.labelList = {}
	for key, value in pairs(M.uiLabels) do
		if key ~= "" and value ~= "" and key ~= value then
			M.labelList[#M.labelList + 1] = { key, value }
		end
	end
	table.sort(M.labelList, function(a, b)
		return #a[1] > #b[1]
	end)
	return M.labelList
end

local MOD_TEXT_REPLACEMENTS = {
	{ "Attacks with this Weapon gain", "Attack with this Weapon gain" },
	{ "Attacks with this Weapon have", "Attack with this Weapon have" },
	{ "Attacks with this Weapon deal", "Attack with this Weapon deal" },
	{ "Attacks with this Weapon Penetrate", "Attack with this Weapon Penetrate" },
	{ "Attacks with this Weapon inflict", "Attack with this Weapon inflict" },
	{ "Attacks with this Weapon Maim", "Attack with this Weapon Maim" },
	{ "All Attacks with this Weapon", "All Attack with this Weapon" },
	{ "Extra damage of each Element", "Gain damage of each ElementalDamage" },
	{ " as Extra damage", " as Gain damage" },
	{ " on Hit", " on HitDamage" },
	{ "Quarterstaves", "Quarterstaff" },
}

local function modKeyAliases(source)
	local variants = { source }
	local seen = { [source] = true }

	local function add(value)
		if value ~= "" and not seen[value] then
			seen[value] = true
			variants[#variants + 1] = value
		end
	end

	local function expand(text)
		add(text)
		if text:sub(1, 8) == "Attacks " then
			add("Attack " .. text:sub(9))
		elseif text:sub(1, 7) == "Attack " then
			add("Attacks " .. text:sub(8))
		end
		for _, pair in ipairs(MOD_TEXT_REPLACEMENTS) do
			if text:find(pair[1], 1, true) then
				add((text:gsub(pair[1], pair[2], 1)))
			end
			if text:find(pair[2], 1, true) then
				add((text:gsub(pair[2], pair[1], 1)))
			end
		end
	end

	expand(source)
	local snapshot = {}
	for _, item in ipairs(variants) do
		snapshot[#snapshot + 1] = item
	end
	for _, item in ipairs(snapshot) do
		expand(item)
		if #variants >= 128 then
			break
		end
	end
	return variants
end

local function normalizeNumericSyntax(source)
	local normalized = source:gsub("–", "-"):gsub("—", "-"):gsub("−", "-")
	normalized = normalized:gsub("\194\160", " ")
	normalized = normalized:gsub("([%+%-])%s+%(", "%1(")
	normalized = normalized:gsub("%(%s*([-+]?%d+%.?%d*)%s*%-%s*([-+]?%d+%.?%d*)%s*%)(%%?)", "(%1-%2)%3")
	return normalized
end

local function parseNumberAt(source, index)
	local length = #source
	local start = index
	local sign = source:sub(index, index)
	if sign == "+" or sign == "-" then
		index = index + 1
	end

	local digitStart = index
	local hasDigit = false
	while index <= length and source:sub(index, index):match("%d") do
		hasDigit = true
		index = index + 1
	end
	if source:sub(index, index) == "." and source:sub(index + 1, index + 1):match("%d") then
		index = index + 1
		while index <= length and source:sub(index, index):match("%d") do
			hasDigit = true
			index = index + 1
		end
	end
	if not hasDigit then
		return nil, start
	end
	return source:sub(start, index - 1), index
end

local function skipSpaces(source, index)
	while index <= #source and source:sub(index, index):match("%s") do
		index = index + 1
	end
	return index
end

local function parseRangeAt(source, index)
	if source:sub(index, index) ~= "(" then
		return nil, index
	end
	local pos = skipSpaces(source, index + 1)
	local min, nextPos = parseNumberAt(source, pos)
	if not min then
		return nil, index
	end
	pos = skipSpaces(source, nextPos)
	if source:sub(pos, pos) ~= "-" then
		return nil, index
	end
	pos = skipSpaces(source, pos + 1)
	local max
	max, nextPos = parseNumberAt(source, pos)
	if not max then
		return nil, index
	end
	pos = skipSpaces(source, nextPos)
	if source:sub(pos, pos) ~= ")" then
		return nil, index
	end
	pos = pos + 1
	local pct = ""
	if source:sub(pos, pos) == "%" then
		pct = "%"
		pos = pos + 1
	end
	return string.format("(%s-%s)", min, max), pct, pos
end

local function tokenizeLiterals(source)
	source = normalizeNumericSyntax(source)
	local values = {}
	local index = 0

	local function nextToken(pct)
		local token = string.format("{%d}%s", index, pct or "")
		index = index + 1
		return token
	end

	local parts = {}
	local pos = 1
	while pos <= #source do
		local placeholder = source:sub(pos):match("^{%d+%%?}")
		if placeholder then
			parts[#parts + 1] = placeholder
			pos = pos + #placeholder
		else
			local rangeValue, pct, nextPos = parseRangeAt(source, pos)
			if rangeValue then
				values[#values + 1] = rangeValue
				parts[#parts + 1] = nextToken(pct)
				pos = nextPos
			else
				local num, numNext = parseNumberAt(source, pos)
				if num then
					local numPct = ""
					if source:sub(numNext, numNext) == "%" then
						numPct = "%"
						numNext = numNext + 1
					end
					values[#values + 1] = num
					parts[#parts + 1] = nextToken(numPct)
					pos = numNext
				else
					parts[#parts + 1] = source:sub(pos, pos)
					pos = pos + 1
				end
			end
		end
	end
	return table.concat(parts), values
end

local function literalToTemplate(source)
	local template = tokenizeLiterals(source)
	return template
end

local function extractNumericValues(source)
	local _, values = tokenizeLiterals(source)
	return values
end

local function applyJaPlaceholders(jaTemplate, values)
	local result = jaTemplate
	for idx, value in ipairs(values) do
		result = result:gsub("{" .. (idx - 1) .. "}", value, 1)
	end
	return result
end

local function lookupModTranslation(key)
	local hit = M.strings[key]
	if hit and hit ~= key then
		return hit
	end
	return nil
end

function M.translateMod(line)
	if type(line) ~= "string" then
		return line
	end
	for _, alias in ipairs(modKeyAliases(line)) do
		local hit = lookupModTranslation(alias)
		if hit then
			return hit
		end
	end
	local template = literalToTemplate(line)
	if template ~= line then
		for _, alias in ipairs(modKeyAliases(template)) do
			local jaTemplate = lookupModTranslation(alias)
			if jaTemplate then
				local values = extractNumericValues(line)
				if #values > 0 then
					return applyJaPlaceholders(jaTemplate, values)
				end
				return jaTemplate
			end
		end
	end
	return line
end

local function applyLabelReplacement(segment)
	for _, pair in ipairs(getLabelList()) do
		if segment:find(pair[1], 1, true) then
			segment = segment:gsub(pair[1], pair[2])
		end
	end
	return segment
end

local function stripColourCodes(text)
	return text:gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%^%d", ""):gsub("%^%d", "")
end

local function splitLeadingColourCode(text)
	local code = text:match("^(%^x%x%x%x%x%x%x)") or text:match("^(%^%^%d)") or text:match("^(%^%d)")
	if not code then
		return "", text
	end
	return code, text:sub(#code + 1)
end

local COLOURED_TERM_TRANSLATIONS = {
	["Bleeding"] = "出血",
	["Blinded"] = "盲目",
	["Brittle"] = "脆弱",
	["Burning"] = "燃焼",
	["Chaos"] = "混沌",
	["Chaos Damage"] = "混沌ダメ",
	["Chaos Damage Taken"] = "受ける混沌ダメージ",
	["Chilled"] = "冷却",
	["Chill"] = "冷却",
	["Cold"] = "冷気",
	["Cold Damage"] = "冷気ダメ",
	["Cold Pen"] = "冷気貫通",
	["Cold Resistance"] = "冷気耐性",
	["Crushed"] = "破砕",
	["Dazed"] = "目眩",
	["Electrocuted"] = "感電",
	["Energy Shield"] = "エナジーシールド",
	["ES"] = "ES",
	["Evasion"] = "回避力",
	["Fire"] = "火",
	["Fire Damage"] = "火ダメ",
	["Fire Pen"] = "火貫通",
	["Fire Resistance"] = "火耐性",
	["Freeze"] = "凍結",
	["Frozen"] = "凍結",
	["Ignite"] = "発火",
	["Ignited"] = "発火",
	["Life"] = "ライフ",
	["Light"] = "雷",
	["Lightning"] = "雷",
	["Lightning Damage"] = "雷ダメ",
	["Lightning Pen"] = "雷貫通",
	["Lightning Resistance"] = "雷耐性",
	["Mana"] = "マナ",
	["Poisoned"] = "毒",
	["Rage"] = "レイジ",
	["Sap"] = "消耗",
	["Sapped"] = "消耗",
	["Scorch"] = "焦げ",
	["Scorched"] = "焦げ",
	["Shock"] = "感電",
	["Shocked"] = "感電",
	["Shocked Ground"] = "感電領域",
}

local function replaceFirstPlain(text, needle, replacement)
	local searchStart = 1
	while true do
		local startPos, endPos = text:find(needle, searchStart, true)
		if not startPos then
			return text, false
		end
		local prefix = text:sub(math.max(1, startPos - 8), startPos - 1)
		if not prefix:match("%^x%x%x%x%x%x%x$") then
			return text:sub(1, startPos - 1) .. replacement .. text:sub(endPos + 1), true
		end
		searchStart = endPos + 1
	end
end

local COLOURED_TERM_ALIASES = {
	["Energy Shield"] = { "エナシ", "エナジーシールド", "ES" },
	["ES"] = { "エナシ", "エナジーシールド", "ES" },
	["Chaos Damage"] = { "混沌ダメージ", "混沌ダメ" },
	["Chaos Damage Taken"] = { "受ける混沌ダメージ", "混沌ダメージ", "混沌ダメ" },
}

local function addColourCandidate(candidates, seen, value)
	if value and value ~= "" and not seen[value] then
		seen[value] = true
		candidates[#candidates + 1] = value
	end
end

local function colouredTermCandidates(english)
	local candidates = {}
	local seen = {}
	addColourCandidate(candidates, seen, M.strings[english])
	addColourCandidate(candidates, seen, COLOURED_TERM_TRANSLATIONS[english])
	local aliases = COLOURED_TERM_ALIASES[english]
	if aliases then
		for _, alias in ipairs(aliases) do
			addColourCandidate(candidates, seen, alias)
		end
	end
	return candidates
end

local function cleanColouredTerm(term)
	term = term:gsub("^%s+", ""):gsub("%s+$", "")
	term = term:gsub("^%p+", ""):gsub("[%s%p]+$", "")
	return term
end

local function findNextColourBreak(text, startIndex)
	local bestStart, bestEnd, bestCode
	local function consider(pattern)
		local startPos, endPos, code = text:find(pattern, startIndex)
		if startPos and (not bestStart or startPos < bestStart) then
			bestStart, bestEnd, bestCode = startPos, endPos, code
		end
	end
	consider("(%^x%x%x%x%x%x%x)")
	consider("(%^%^%d)")
	consider("(%^%d)")
	return bestStart, bestEnd, bestCode
end

local function applyColourCodeToTerm(out, code, term, reset)
	local english = cleanColouredTerm(term)
	if english == "" then
		return out
	end
	for _, japanese in ipairs(colouredTermCandidates(english)) do
		if japanese ~= english and out:find(japanese, 1, true) then
			local changed
			out, changed = replaceFirstPlain(out, japanese, code .. japanese .. (reset or "^7"))
			if changed then
				return out
			end
		end
	end
	return out
end

local function applyColourCodesToTranslation(source, translation)
	if not source:find("^", 1, true) then
		return translation
	end
	local out = translation
	local leadingColour = source:match("^(%^x%x%x%x%x%x%x)") or source:match("^(%^%^%d)") or source:match("^(%^%d)")
	local index = 1
	while true do
		local codeStart, codeEnd, code = source:find("(%^x%x%x%x%x%x%x)", index)
		if not codeStart then
			break
		end
		local termStart = codeEnd + 1
		local breakStart, breakEnd, breakCode = findNextColourBreak(source, termStart)
		local termEnd = (breakStart or (#source + 1)) - 1
		local reset = nil
		if breakCode and breakCode:match("^%^%^?%d$") then
			reset = breakCode
		end
		out = applyColourCodeToTerm(out, code, source:sub(termStart, termEnd), reset)
		if not breakStart then
			break
		end
		if reset then
			index = breakEnd + 1
		else
			index = breakStart
		end
	end
	if leadingColour and out:sub(1, 1) ~= "^" then
		out = leadingColour .. out
	end
	return out
end

local function translateSegment(segment)
	if segment == "" then
		return segment
	end
	local hit = M.translate(segment)
	if hit ~= segment then
		return hit
	end
	hit = M.translateMod(segment)
	if hit ~= segment then
		return hit
	end
	local term = cleanColouredTerm(segment)
	local termHit = M.strings[term] or COLOURED_TERM_TRANSLATIONS[term]
	if termHit and termHit ~= term then
		local replaced, changed = replaceFirstPlain(segment, term, termHit)
		if changed then
			return replaced
		end
	end
	return applyLabelReplacement(segment)
end

local function translateLabel(label)
	if type(label) ~= "string" or label == "" then
		return nil
	end
	label = stripColourCodes(label)
	local prefix, core, suffix = label:match("^(%s*)(.-)(%s*)$")
	if not core or core == "" then
		return nil
	end
	local translated = M.strings[core]
	if not translated or translated == core then
		translated = M.strings[core .. ":"]
		if translated then
			translated = translated:gsub(":%s*$", "")
		end
	end
	if not translated or translated == core then
		return nil
	end
	return prefix .. translated .. suffix
end

local function translateStatSuffix(suffix)
	if not suffix or suffix == "" then
		return suffix or ""
	end
	return suffix:gsub("per point", "ポイントごと")
end

local function firstAnnotationIndex(body)
	local best = nil
	for _, marker in ipairs({ " (", " [" }) do
		local pos = body:find(marker, 1, true)
		if pos and (not best or pos < best) then
			best = pos
		end
	end
	return best
end

local function translateStatDeltaLine(text)
	if type(text) ~= "string" then
		return text
	end
	local leadingColour, working = splitLeadingColourCode(text)
	local value, body = working:match("^([%+%-]%d[%d,]*%.?%d*%%?)%s+(.+)$")
	if not value or not body then
		return text
	end
	local cut = firstAnnotationIndex(body)
	local label = cut and body:sub(1, cut - 1) or body
	local suffix = cut and body:sub(cut) or ""
	local translatedLabel = translateLabel(label)
	if not translatedLabel then
		return text
	end
	return leadingColour .. value .. " " .. translatedLabel .. translateStatSuffix(suffix)
end

local function translateColonPrefixLine(text)
	if type(text) ~= "string" then
		return text
	end
	local leadingColour, working = splitLeadingColourCode(text)
	local prefix, suffix = working:match("^(.-:)(%s+.+)$")
	if not prefix or not suffix then
		return text
	end
	local translated = M.strings[prefix]
	if not translated or translated == prefix then
		return text
	end
	return leadingColour .. translated .. suffix
end

local function translateNumericSuffixLabelText(text)
	if type(text) ~= "string" then
		return text
	end
	local leadingColour, working = splitLeadingColourCode(text)
	local head, label = working:match("^([%s%+%-%*/xX=]*%d[%d,]*%.?%d*%%?%s+)([%a][%w%s%-%+/%']*)$")
	if not head or not label then
		return text
	end
	local translated = translateLabel(label)
	if not translated then
		return text
	end
	return leadingColour .. head .. translated
end

local function translateParenthesizedLabels(text)
	if type(text) ~= "string" then
		return text
	end
	local changed = false
	local out = text:gsub("%(([^%(%)]-)%)", function(label)
		local translated = M.strings[label]
		if translated and translated ~= label then
			changed = true
			return "(" .. translated .. ")"
		end
		translated = translateNumericSuffixLabelText(label)
		if translated ~= label then
			changed = true
			return "(" .. translated .. ")"
		end
		return "(" .. label .. ")"
	end)
	local label, suffix = out:match("^(.-)(%s+%b())$")
	if label then
		local translated = M.strings[label]
		if translated and translated ~= label then
			out = translated .. suffix
			changed = true
		end
	end
	if changed then
		return out
	end
	return text
end

local function translateNumericSuffixLabel(text)
	return translateNumericSuffixLabelText(text)
end

local function translateDelimitedList(text)
	if type(text) ~= "string" or not text:find(",", 1, true) then
		return text
	end
	local leadingColour, working = splitLeadingColourCode(text)
	local pieces = {}
	local start = 1
	while true do
		local comma = working:find(",", start, true)
		if not comma then
			pieces[#pieces + 1] = working:sub(start)
			break
		end
		pieces[#pieces + 1] = working:sub(start, comma - 1)
		start = comma + 1
	end
	if #pieces < 2 then
		return text
	end
	local changed = false
	for index, piece in ipairs(pieces) do
		local prefix, core, suffix = piece:match("^(%s*)(.-)(%s*)$")
		local translated = translateLabel(core)
		if not translated then
			return text
		end
		if translated ~= core then
			changed = true
		end
		pieces[index] = prefix .. translated .. suffix
	end
	if not changed then
		return text
	end
	return leadingColour .. table.concat(pieces, ",")
end

function M.translate(text)
	if type(text) ~= "string" then
		return text
	end
	local translated = M.strings[text]
	if translated then
		return translated
	end
	translated = translateDelimitedList(text)
	if translated ~= text then
		return translated
	end
	translated = translateNumericSuffixLabel(text)
	if translated ~= text then
		return translated
	end
	if text:find("^", 1, true) then
		local statTranslated = translateStatDeltaLine(text)
		if statTranslated ~= text then
			return statTranslated
		end
		local leadingColour, withoutLeadingColour = text:match("^(%^%^%d)(.+)$")
		if not leadingColour then
			leadingColour, withoutLeadingColour = text:match("^(%^%d)(.+)$")
		end
		if leadingColour and withoutLeadingColour then
			translated = M.strings[withoutLeadingColour]
			if translated then
				if translated:sub(1, 1) == "^" then
					return translated
				end
				return leadingColour .. translated
			end
		end
		local plain = stripColourCodes(text)
		if plain ~= text then
			translated = M.strings[plain]
			if translated then
				return applyColourCodesToTranslation(text, translated)
			end
			local modTranslated = M.translateMod(plain)
			if modTranslated ~= plain then
				return applyColourCodesToTranslation(text, modTranslated)
			end
			local statTranslated = translateStatDeltaLine(plain)
			if statTranslated ~= plain then
				return applyColourCodesToTranslation(text, statTranslated)
			end
		end
	end
	local prefix, core, suffixSpace = text:match("^(%s*)(.-)(%s*)$")
	if core and core ~= text and core ~= "" then
		translated = M.strings[core]
		if translated then
			return prefix .. translated .. suffixSpace
		end
	end
	for _, suffix in ipairs(NOT_SUPPORTED_SUFFIXES) do
		if #text > #suffix and text:sub(-#suffix) == suffix then
			local base = text:sub(1, -#suffix - 1)
			translated = M.strings[base]
			if translated then
				return translated .. suffix
			end
		end
	end
	translated = translateColonPrefixLine(text)
	if translated ~= text then
		return translated
	end
	translated = translateParenthesizedLabels(text)
	if translated ~= text then
		return translated
	end
	return text
end

local function appendColourCode(text, index)
	if text:sub(index, index + 1) == "^^" and text:sub(index + 2, index + 2):match("%d") then
		return text:sub(index, index + 2), index + 3
	end
	if text:sub(index + 1, index + 1) == "x" and text:sub(index + 2, index + 7):match("^%x%x%x%x%x%x$") then
		return text:sub(index, index + 7), index + 8
	end
	if text:sub(index + 1, index + 1):match("%d") then
		return text:sub(index, index + 1), index + 2
	end
	return nil, index
end

function M.translateColoured(text)
	if type(text) ~= "string" then
		return text
	end
	local parts = {}
	local index = 1
	local length = #text
	while index <= length do
		if text:sub(index, index) == "^" then
			local code, nextIndex = appendColourCode(text, index)
			if code then
				parts[#parts + 1] = code
				index = nextIndex
			else
				local start = index
				index = index + 1
				while index <= length and text:sub(index, index) ~= "^" do
					index = index + 1
				end
				parts[#parts + 1] = translateSegment(text:sub(start, index - 1))
			end
		else
			local start = index
			while index <= length and text:sub(index, index) ~= "^" do
				index = index + 1
			end
			local segment = text:sub(start, index - 1)
			if segment ~= "" then
				parts[#parts + 1] = translateSegment(segment)
			end
		end
	end
	return table.concat(parts)
end

local function translateDisplayMultiline(text)
	local lines = {}
	local start = 1
	while true do
		local pos = text:find("\n", start, true)
		local line
		if pos then
			line = text:sub(start, pos - 1)
		else
			line = text:sub(start)
		end
		local cr = ""
		if line:sub(-1) == "\r" then
			cr = "\r"
			line = line:sub(1, -2)
		end
		lines[#lines + 1] = M.tDisplay(line) .. cr
		if not pos then
			break
		end
		start = pos + 1
	end
	return table.concat(lines, "\n")
end

-- ビルド警告（"You do not meet the X requirement of <名前>" 等、前置詞＋動的名の連結）。
-- 前置詞を日本語化し、名前部分は再帰翻訳して日本語語順に組み替える。
local buildWarnPrefixes = {
	{ "You do not meet the Strength requirement of ", "の筋力要件を満たしていません" },
	{ "You do not meet the Dexterity requirement of ", "の器用さ要件を満たしていません" },
	{ "You do not meet the Intelligence requirement of ", "の知性要件を満たしていません" },
}
local function translateBuildWarning(text)
	for _, p in ipairs(buildWarnPrefixes) do
		if text:sub(1, #p[1]) == p[1] then
			local rest = text:sub(#p[1] + 1)
			return M.tDisplay(rest) .. p[2]
		end
	end
	return text
end

function M.tDisplay(text)
	if type(text) ~= "string" then
		return text
	end
	local mod = M.translateMod(text)
	if mod ~= text then
		return mod
	end
	local exact = M.translate(text)
	if exact ~= text then
		return exact
	end
	if text:find("\n", 1, true) then
		return translateDisplayMultiline(text)
	end
	local stat = translateStatDeltaLine(text)
	if stat ~= text then
		return stat
	end
	if text:find("^", 1, true) then
		return M.translateColoured(text)
	end
	local warn = translateBuildWarning(text)
	if warn ~= text then
		return warn
	end
	return text
end

local function translateItemLine(line)
	local prefix, core, suffix = line:match("^(%s*)(.-)(%s*)$")
	if not core or core == "" then
		return line
	end
	local translated = M.tDisplay(core)
	if translated ~= core then
		return prefix .. translated .. suffix
	end
	return line
end

function M.translateItemText(text)
	if type(text) ~= "string" then
		return text
	end
	local normalized = text:gsub("\r\n", "\n")
	local lines = {}
	local start = 1
	while true do
		local pos = normalized:find("\n", start, true)
		if not pos then
			lines[#lines + 1] = normalized:sub(start)
			break
		end
		lines[#lines + 1] = normalized:sub(start, pos - 1)
		start = pos + 1
	end
	for index, line in ipairs(lines) do
		lines[index] = translateItemLine(line)
	end
	return table.concat(lines, "\n")
end

function M.translateMatch(self, pattern)
	if self.match and self:match(pattern) then
		return true
	end
	if self.buf and type(self.buf) == "string" then
		local translated = M.translate(self.buf)
		if translated ~= self.buf and translated:match(pattern) then
			return true
		end
	end
	return false
end

function M.wrapCharm(nativeCharm)
	if type(nativeCharm) ~= "table" then
		return
	end
	local nativeTranslate = nativeCharm.Translate
	local nativeMatch = nativeCharm.TranslateMatch
	local nativeItems = nativeCharm.TranslateItems
	local nativePassives = nativeCharm.TranslatePassiveSkills
	local nativeItemText = nativeCharm.TranslateItemText

	function nativeCharm.Translate(text)
		local translated = M.tDisplay(text)
		if translated ~= text then
			return translated
		end
		if type(nativeTranslate) == "function" then
			return nativeTranslate(text)
		end
		return text
	end

	function nativeCharm.TranslateMatch(control, pattern)
		if M.translateMatch(control, pattern) then
			return true
		end
		if type(nativeMatch) == "function" then
			return nativeMatch(control, pattern)
		end
		return false
	end

	function nativeCharm.TranslateItems(...)
		if type(nativeItems) == "function" then
			local results = { nativeItems(...) }
			for index, value in ipairs(results) do
				if type(value) == "string" then
					results[index] = M.translateItemText(value)
				end
			end
			local unpackFn = table.unpack or unpack
			return unpackFn(results)
		end
		local first = ...
		if type(first) == "string" then
			return M.translateItemText(first)
		end
		return first
	end

	function nativeCharm.TranslatePassiveSkills(text)
		local translated = M.tDisplay(text)
		if translated ~= text then
			return translated
		end
		if type(nativePassives) == "function" then
			return nativePassives(text)
		end
		return text
	end

	function nativeCharm.TranslateItemText(text)
		local translated = M.translateItemText(text)
		if translated ~= text then
			return translated
		end
		if type(nativeItemText) == "function" then
			text = nativeItemText(text)
		end
		return M.translateItemText(text)
	end
end

load_translations()
-- Older PoEJP builds installed DisplayLocale.lua / UiLocale.lua next to this
-- module. They contain broad partial-label replacements that can corrupt exact
-- CSV translations (for example "Power Charges" -> mixed Japanese/English).

if type(_G.charm) == "table" then
	M.wrapCharm(_G.charm)
else
	_G.charm = {
		Translate = M.tDisplay,
		TranslateMatch = M.translateMatch,
	}
end

return M
