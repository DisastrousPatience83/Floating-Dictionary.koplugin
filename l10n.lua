--[[--
l10n.lua -- Self-contained GNU gettext (.po) loader for the Floating
Dictionary plugin, with an in-plugin "Language" setting.

WHY THIS EXISTS
KOReader's own `gettext` module follows the *device's* system language and
reads .po files from KOReader's own l10n/ tree. This plugin instead wants an
independent "Language" option inside its own settings menu, selectable
regardless of what language the rest of KOReader is running in. This module
provides that, reading .po files bundled with the plugin itself
(<plugin_dir>/l10n/<code>.po).

CONVENTION (standard GNU gettext, same as KOReader itself)
The msgid is the literal English source string used in the code, e.g.:

    _("Highlight")

...and each language file maps that exact string to its translation:

    msgid "Highlight"
    msgstr "Resaltar"

Keeping msgid == English source text (instead of a made-up short key) means
the English text in the code IS the fallback translation, so nothing ever
shows up blank even if a .po file is missing an entry, and translators can
work from self-explanatory source strings.

USAGE
    local _ = require("l10n").gettext
    local T = require("ffi/util").template
    ...
    text = _("Highlight")
    text = T(_("Card height: %1 %% of screen"), value)

ADDING A NEW LANGUAGE
    1. Copy l10n/en.po to l10n/<code>.po (e.g. l10n/fr.po).
    2. Translate every msgstr value; leave every msgid untouched.
    3. Add { code = "<code>", name = "<Native name>" } to
       L.AVAILABLE_LANGUAGES below. Nothing else needs to change: the
       language will automatically appear in the plugin's Language menu.
--]]--

local logger = require("logger")

local L = {}

-- Languages the plugin ships translations for. Order here is the order
-- shown in the "Language" selection menu.
L.AVAILABLE_LANGUAGES = {
	{ code = "en", name = "English" },
	{ code = "es", name = "Español" },
}

L.DEFAULT_LANGUAGE = "en"

local SETTING_LANGUAGE = "floatingdictionary_language"

-- Populated lazily by loadLanguage(). Keyed by language code, each value a
-- table of { [msgid] = msgstr }.
local catalog_cache = {}

-- Directory this module lives in (the plugin's own folder), so .po files
-- are found regardless of KOReader's current working directory.
local function pluginDir()
	local info = debug.getinfo(1, "S")
	local src = info and info.source or ""
	src = src:gsub("^@", "")
	local dir = src:match("^(.*)[/\\][^/\\]+$")
	return dir or "."
end

local PLUGIN_DIR = pluginDir()

local function unescape(s)
	s = s:gsub("\\n", "\n")
	s = s:gsub("\\t", "\t")
	s = s:gsub('\\"', '"')
	s = s:gsub("\\\\", "\\")
	return s
end

-- Extracts every consecutive "..." quoted segment starting at position i in
-- text (gettext allows a msgid/msgstr value to be split across several
-- quoted lines); returns the concatenated, unescaped value and the index
-- just after the last quote consumed.
local function readQuotedValue(text, i)
	local n = #text
	local value = {}
	while true do
		local ws_e = select(2, text:find("^%s*", i))
		if ws_e then i = ws_e + 1 end
		if text:sub(i, i) ~= '"' then break end
		local j = i + 1
		local buf = {}
		while j <= n do
			local c = text:sub(j, j)
			if c == "\\" then
				table.insert(buf, text:sub(j, j + 1))
				j = j + 2
			elseif c == '"' then
				break
			else
				table.insert(buf, c)
				j = j + 1
			end
		end
		table.insert(value, unescape(table.concat(buf)))
		i = j + 1
	end
	return table.concat(value), i
end

-- Minimal but correct .po parser: handles multi-line msgid/msgstr strings,
-- standard C-style escapes, and skips comments and the header block (empty
-- msgid). Returns a table mapping msgid -> msgstr.
local function parsePoFile(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local content = file:read("*a")
	file:close()
	content = content:gsub("\r\n", "\n")

	local catalog = {}
	local i = 1
	local n = #content
	while i <= n do
		local mid_s, mid_e = content:find("msgid%s+", i)
		if not mid_s then break end
		local msgid, after_id = readQuotedValue(content, mid_e + 1)

		local mstr_s, mstr_e = content:find("^%s*msgstr%s+", after_id)
		local msgstr = ""
		local next_i = after_id
		if mstr_s then
			msgstr, next_i = readQuotedValue(content, mstr_e + 1)
		end

		if msgid ~= "" then
			catalog[msgid] = msgstr
		end
		i = math.max(next_i, mid_e + 1)
	end

	return catalog
end

local function loadLanguage(code)
	if catalog_cache[code] then
		return catalog_cache[code]
	end
	local path = PLUGIN_DIR .. "/l10n/" .. code .. ".po"
	local catalog = parsePoFile(path)
	if not catalog then
		logger.warn("l10n: could not read", path)
		catalog = {}
	end
	catalog_cache[code] = catalog
	return catalog
end

-- Returns the currently selected language code, falling back to the
-- default if nothing has been chosen yet or the saved choice is no longer
-- shipped with the plugin.
function L.getLanguage()
	local code = G_reader_settings and G_reader_settings:readSetting(SETTING_LANGUAGE)
	if not code then
		return L.DEFAULT_LANGUAGE
	end
	for _, lang in ipairs(L.AVAILABLE_LANGUAGES) do
		if lang.code == code then
			return code
		end
	end
	return L.DEFAULT_LANGUAGE
end

function L.setLanguage(code)
	if G_reader_settings then
		G_reader_settings:saveSetting(SETTING_LANGUAGE, code)
	end
end

-- Core lookup, drop-in replacement for gettext's _(). msgid is the literal
-- English source string. Falls back to English, then to msgid itself, so a
-- missing translation never shows a blank string.
function L.gettext(msgid)
	local code = L.getLanguage()
	if code == L.DEFAULT_LANGUAGE then
		local catalog = loadLanguage(code)
		local value = catalog[msgid]
		if value ~= nil and value ~= "" then
			return value
		end
		return msgid
	end

	local catalog = loadLanguage(code)
	local value = catalog[msgid]
	if value ~= nil and value ~= "" then
		return value
	end
	return msgid
end

return L
