local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FontList = require("fontlist")
local IconWidget = require("ui/widget/iconwidget")
local Menu = require("ui/widget/menu")
local TextWidget = require("ui/widget/textwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Event = require("ui/event")
local util = require("util")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local Notification = require("ui/widget/notification")
local _ = require("gettext")

local Screen = Device.screen

local FloatingDictionary = WidgetContainer:extend({
	name = "floatingdictionary",
	is_doc_only = true,
})

-- UI constants ---------------------------------------------------------------

local UI_FONT_FACE = "Noto Sans"
local UI_FONT_SIZE = 20

local PANEL_MAX_HEIGHT_RATIO = 0.38
local MIN_CONTENT_WIDTH = Screen:scaleBySize(120)

local KOREADER_ICON_SIZE = Screen:scaleBySize(24)
local BUTTON_HEIGHT = Screen:scaleBySize(46)
local BUTTON_SEPARATOR_WIDTH = math.max(1, Screen:scaleBySize(1))

-- Card look: the panel floats slightly above the bottom edge and is inset
-- from the sides so its rounded corners are actually visible.
local CARD_OUTER_SIDE_MARGIN = Screen:scaleBySize(10)
local CARD_OUTER_BOTTOM_MARGIN = Screen:scaleBySize(10)
local CARD_BORDER_SIZE = Size.border.thin
local CARD_RADIUS = Screen:scaleBySize(14)

local PANEL_PADDING_TOP = Screen:scaleBySize(10)
local PANEL_PADDING_BOTTOM = Screen:scaleBySize(6)
local TEXT_BUTTON_GAP = Screen:scaleBySize(6)
local CONTENT_PADDING_LEFT = Screen:scaleBySize(18)
local CONTENT_PADDING_RIGHT = Screen:scaleBySize(14)

local ICON_SEARCH = "appbar.search"
local ICON_SETTINGS = "appbar.settings"
local ICON_PREVIOUS = "chevron.left"
local ICON_NEXT = "chevron.right"

local SETTING_ENABLED = "floatingdictionary_enabled"
local SETTING_VISIBLE_ACTIONS = "floatingdictionary_visible_actions"
local SETTING_ACTIONS_ORDER = "floatingdictionary_actions_order"
local SETTING_SHOW_EXTERNAL_BUTTONS = "floatingdictionary_show_external_buttons"
local SETTING_FONT_SIZE_DELTA = "floatingdictionary_font_size_delta"
-- Name (not path) of a font face the user picked from the settings menu to
-- always use in the preview, overriding the book/global-CRE font detection
-- done by getDocFontFamily(). nil/unset means "use the book's font" (default).
local SETTING_FONT_FAMILY = "floatingdictionary_font_family"

-- How much A+/A- changes the popup's text size by, and how far it can go
-- in either direction relative to UI_FONT_SIZE. Does not affect the footer
-- buttons, which always use UI_FONT_SIZE.
local FONT_SIZE_STEP = 2
local FONT_SIZE_DELTA_MIN = -6
local FONT_SIZE_DELTA_MAX = 16

local ACTION_HIGHLIGHT = "highlight"
local ACTION_SEARCH_BOOK = "search_book"
local ACTION_WIKIPEDIA = "wikipedia"
local ACTION_VOCABULARY = "vocabulary"
local ACTION_TRANSLATE = "translate"
local ACTION_NAV_PREV = "nav_prev"
local ACTION_NAV_NEXT = "nav_next"
local ACTION_EXTERNAL = "external_plugins"

-- Order here is also the default order buttons are drawn in the footer
-- (the user can reorder and hide them from the gear-icon settings popup).
-- "kind" marks the few entries that aren't plain toggleable dictionary
-- actions: the dictionary-navigation arrows and the external-plugins group
-- each need special handling when the footer is actually built.
local ACTIONS = {
	{ id = ACTION_NAV_PREV, label = _("Previous result"), short_label = _("Prev"), kind = "nav_prev" },
	{ id = ACTION_HIGHLIGHT, label = _("Highlight"), short_label = _("Highlight") },
	{ id = ACTION_SEARCH_BOOK, label = _("Fulltext search"), short_label = _("Search") },
	{ id = ACTION_WIKIPEDIA, label = _("Wikipedia"), short_label = _("Wiki") },
	{ id = ACTION_VOCABULARY, label = _("Add to vocabulary builder"), short_label = _("+Vocab") },
	{ id = ACTION_TRANSLATE, label = _("Translate"), short_label = _("Translate") },
	{ id = ACTION_EXTERNAL, label = _("Buttons from other plugins"), short_label = "+", kind = "external" },
	{ id = ACTION_NAV_NEXT, label = _("Next result"), short_label = _("Next"), kind = "nav_next" },
}

local ACTION_BY_ID = {}
for _, action in ipairs(ACTIONS) do
	ACTION_BY_ID[action.id] = action
end

-- Text-fallback footer buttons (used when no icon file is available) show
-- only the capitalized first letter of the label, so they always fit the
-- narrow button width regardless of translation length (e.g. "Highlight" ->
-- "H") instead of being clipped mid-word.
local function getButtonInitial(text)
	if type(text) ~= "string" or text == "" then
		return "?"
	end
	return text:sub(1, 1):upper()
end

local PLUGIN_ICON_EXTENSIONS = { ".svg", ".png" }
local PLUGIN_ICON_CANDIDATES = {
	[ACTION_HIGHLIGHT] = { "highlight", "floatingdictionary.highlight" },
	[ACTION_WIKIPEDIA] = { "wikipedia", "floatingdictionary.wikipedia" },
	[ACTION_VOCABULARY] = { "vocabulary", "floatingdictionary.vocabulary" },
	[ACTION_TRANSLATE] = { "translate", "floatingdictionary.translate" },
}

-- Small helpers --------------------------------------------------------------

local function trim(text)
	return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function fileExists(path)
	if not path or path == "" then
		return false
	end

	local file = io.open(path, "rb")
	if file then
		file:close()
		return true
	end

	return false
end

local function copyTable(value, seen)
	if type(value) ~= "table" then
		return value
	end

	seen = seen or {}
	if seen[value] then
		return seen[value]
	end

	local copy = {}
	seen[value] = copy

	for key, item in pairs(value) do
		copy[copyTable(key, seen)] = copyTable(item, seen)
	end

	return copy
end

local function htmlEscape(text)
	text = tostring(text or "")
	text = text:gsub("&", "&amp;")
	text = text:gsub("<", "&lt;")
	text = text:gsub(">", "&gt;")
	text = text:gsub('"', "&quot;")
	return text
end

local function looksLikeHtml(text)
	return tostring(text or ""):find("<%s*[%a/][^>]*>") ~= nil
end

local function plainTextToHtml(text)
	text = htmlEscape(text)
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	text = text:gsub("\n\n+", "</p><p>"):gsub("\n", "<br/>")
	return "<p>" .. text .. "</p>"
end

local function normalizeDictionaryHtml(definition)
	definition = tostring(definition or "")

	if definition == "" then
		return "<p>" .. htmlEscape(_("No definition.")) .. "</p>"
	end

	if looksLikeHtml(definition) then
		return definition
	end

	return plainTextToHtml(definition)
end

local function appendStyleAttr(attrs, style)
	attrs = attrs or ""

	if attrs:find("style%s*=") then
		return attrs:gsub('style%s*=%s*"([^"]*)"', 'style="%1; ' .. style .. '"', 1)
	end

	return attrs .. ' style="' .. style .. '"'
end

-- Fallback HTML normalization ------------------------------------------------
-- Used only when a dictionary result does not provide its own CSS. Some
-- dictionaries use heading tags for long grammatical forms; without CSS these
-- headings become too large in the preview panel.

local dictionary_class_styles = {
	hw = "font-size:1.15em; font-weight:bold;",
	ctx = "font-size:0.85em; font-style:italic;",
	pron = "font-size:0.9em;",
	gr = "font-size:0.85em; font-style:italic;",
	use = "font-size:0.85em; font-style:italic;",
	ge = "font-size:0.85em; font-style:italic;",
	la = "font-size:0.85em; font-style:italic;",
	d = "font-size:0.85em;",
	num = "font-size:0.95em; font-weight:bold;",
	rm = "font-size:1em; font-weight:bold;",
	s1 = "display:block; margin:0.15em 0 0.35em 0;",
	ib = "display:block; margin:0.25em 0 0.45em 0.8em; font-size:0.92em;",
	ql = "display:inline;",
	q = "display:inline;",
	a = "font-size:0.9em; font-weight:bold;",
	w = "font-size:0.9em; font-style:italic;",
	phg = "display:block; margin-top:0.6em; font-size:0.95em;",
	sub = "display:block; margin-left:0.8em; margin-top:0.15em;",
	et = "display:block; margin-top:0.5em; font-size:0.92em;",
	xr = "font-style:italic;",
}

local function buildStyleFromClassList(classes)
	local style_parts = {}

	for class_name in tostring(classes or ""):gmatch("%S+") do
		if dictionary_class_styles[class_name] then
			table.insert(style_parts, dictionary_class_styles[class_name])
		end
	end

	if #style_parts == 0 then
		return nil
	end

	return table.concat(style_parts, " ")
end

local function normalizeHeadingTags(html)
	html = html:gsub("<%s*[hH][1-6]([^>]*)>", function(attrs)
		return "<div"
			.. appendStyleAttr(attrs, "font-size:1em; line-height:1.25; margin:0.35em 0 0.25em 0; font-weight:normal;")
			.. ">"
	end)

	return html:gsub("</%s*[hH][1-6]%s*>", "</div>")
end

local function normalizeDictionaryClasses(html)
	return html:gsub('(<%w+)([^>]-class%s*=%s*"([^"]*)"[^>]*)(>)', function(tag, attrs, classes, close)
		local style = buildStyleFromClassList(classes)
		if style then
			return tag .. appendStyleAttr(attrs, style) .. close
		end
		return tag .. attrs .. close
	end)
end

local function normalizeDictionaryLists(html)
	html = html:gsub("<%s*[uU][lL]([^>]*)>", function(attrs)
		return "<ul" .. appendStyleAttr(attrs, "margin:0.25em 0 0.35em 1.1em; padding:0;") .. ">"
	end)

	html = html:gsub("<%s*[oO][lL]([^>]*)>", function(attrs)
		return "<ol" .. appendStyleAttr(attrs, "margin:0.25em 0 0.35em 1.1em; padding:0;") .. ">"
	end)

	return html:gsub("<%s*[lL][iI]([^>]*)>", function(attrs)
		return "<li" .. appendStyleAttr(attrs, "margin:0.18em 0;") .. ">"
	end)
end

local function shouldNormalizeFloatingDictionaryHtml(html)
	return html:find("<%s*[hH][1-6]")
		or html:find('class%s*=%s*"hw"')
		or html:find('class%s*=%s*"pron"')
		or html:find('class%s*=%s*"ctx"')
		or html:find('class%s*=%s*"ib"')
		or html:find('class%s*=%s*"ql"')
		or html:find('class%s*=%s*"phg"')
end

local function normalizeFloatingDictionaryHtml(definition)
	local html = normalizeDictionaryHtml(definition)

	if not shouldNormalizeFloatingDictionaryHtml(html) then
		return html
	end

	html = normalizeHeadingTags(html)
	html = normalizeDictionaryClasses(html)
	return normalizeDictionaryLists(html)
end

-- CSS ------------------------------------------------------------------------

-- Mirrors the approach used by xray_ui.lua: prefer the font family of the
-- book currently open (as tracked by ReaderFont), then fall back to the
-- user's global CRE font setting, and finally to our own UI default.
local function getDocFontFamily(plugin)
	if G_reader_settings then
		local override = G_reader_settings:readSetting(SETTING_FONT_FAMILY)
		if override and override ~= "" then
			return override
		end
	end
	if plugin and plugin.ui and plugin.ui.font then
		local family = plugin.ui.font.font_face
		if family and family ~= "" then
			return family
		end
	end
	if G_reader_settings then
		local family = G_reader_settings:readSetting("cre_font_family")
		if family and family ~= "" then
			return family
		end
	end
	return nil
end

-- Resolves the book's font family to an actual Font face object, for widgets
-- that need a real bitmap face (e.g. TextWidget-based buttons) rather than a
-- CSS font-family string. Mirrors the getFontSafe() approach in xray_ui.lua.
local function getDocFontFace(plugin, size)
	local font_family = getDocFontFamily(plugin)

	if font_family and font_family ~= "" then
		local ok, credoc = pcall(require, "document/credocument")
		if ok and credoc and credoc.engineInit then
			local ok2, cre = pcall(credoc.engineInit, credoc)
			if ok2 and cre and cre.getFontFaceFilenameAndFaceIndex then
				local filename, faceindex = cre.getFontFaceFilenameAndFaceIndex(font_family)
				if not filename then
					filename, faceindex = cre.getFontFaceFilenameAndFaceIndex(font_family, nil, true)
				end
				if filename then
					local face_ok, face = pcall(Font.getFace, Font, filename, size, faceindex)
					if face_ok and face then
						return face
					end
				end
			end
		end
	end

	return Font:getFace("cfont", size)
end

-- MuPDF (which renders our HTML popup body) silently ignores a plain
-- `font-family: 'Some Font'` CSS rule unless that exact name happens to be
-- one MuPDF already knows internally — this is a documented MuPDF
-- limitation (naming a system font by name in CSS doesn't work), confirmed
-- against KOReader's own HtmlBoxWidget behaviour. The only reliable way to
-- get an arbitrary CRE-known font to actually render is to declare it via
-- @font-face with `src: url(...)` pointing straight at its file on disk,
-- then reference that alias instead of the real font name. Same technique
-- the community's 2-custom-ui-fonts.lua patch uses for dictionary popups.
local FONT_FACE_ALIAS = "FloatingDictionaryFace"

local function buildFontFaceCss(font_family)
	if not font_family or font_family == "" then
		return nil
	end

	local ok, credoc = pcall(require, "document/credocument")
	if not ok or not credoc or not credoc.engineInit then
		return nil
	end
	local ok2, cre = pcall(credoc.engineInit, credoc)
	if not ok2 or not cre or not cre.getFontFaceFilenameAndFaceIndex then
		return nil
	end

	local ok3, base_filename = pcall(cre.getFontFaceFilenameAndFaceIndex, font_family)
	if not ok3 or not base_filename then
		ok3, base_filename = pcall(cre.getFontFaceFilenameAndFaceIndex, font_family, nil, true)
	end
	if not ok3 or not base_filename then
		return nil
	end

	local seen = { [base_filename] = true }
	local css = "@font-face { font-family: '" .. FONT_FACE_ALIAS .. "'; src: url('" .. base_filename .. "') }\n"

	-- Also register the bold/italic/bold-italic variants under the same
	-- alias when CRE actually has separate files for them, so the popup's
	-- bold word title and any <em>/<strong> in the definition still look
	-- right instead of only ever using the regular weight.
	local variants = {
		{ bold = false, italic = true, style = "; font-style: italic" },
		{ bold = true, italic = false, style = "; font-weight: bold" },
		{ bold = true, italic = true, style = "; font-weight: bold; font-style: italic" },
	}
	for _, v in ipairs(variants) do
		local ok4, path = pcall(cre.getFontFaceFilenameAndFaceIndex, font_family, v.bold, v.italic)
		if ok4 and path and not seen[path] then
			seen[path] = true
			css = css .. "@font-face { font-family: '" .. FONT_FACE_ALIAS .. "'; src: url('" .. path .. "')" .. v.style .. " }\n"
		end
	end

	return css
end

-- Resolves a font family name to what should actually be written into CSS
-- `font-family` rules: the @font-face block (or "" if none could be built)
-- plus the name to reference (the alias if the block was built, otherwise
-- the original name/fallback, which at least keeps prior behaviour for
-- whatever cases buildFontFaceCss can't resolve).
local function resolveCssFont(font_family)
	local face_css = buildFontFaceCss(font_family)
	if face_css then
		return face_css, FONT_FACE_ALIAS
	end
	return "", font_family or UI_FONT_FACE
end

local function getBaseCss(font_family)
	local face_css, face = resolveCssFont(font_family)
	return face_css .. [[
@page {
    margin: 0;
    font-family: ']] .. face .. [[';
}
body {
    margin: 0;
    padding: 0;
    line-height: 1.3;
    font-family: ']] .. face .. [[';
}
p, h1, h2, h3, h4, h5, h6, ol, ul, dl, dd {
    margin: 0;
}
ul, ol {
    padding-left: 1.1em;
}
a {
    color: black;
}
.floatingdictionary-word {
    font-size: 1.18em;
    font-weight: bold;
    line-height: 1.15;
}
.floatingdictionary-meta {
    margin-top: 0.08em;
    font-size: 0.78em;
    color: black;
    font-style: italic;
    letter-spacing: 0.02em;
    text-transform: uppercase;
}
.floatingdictionary-separator {
    border-top: 1px solid #ddd;
    margin: 0.35em 0 0.4em 0;
}
]]
end

local FALLBACK_CSS = getBaseCss()

local function hasDictionaryCss(result)
	return result and result.css and result.css ~= "" and looksLikeHtml(result.definition)
end

local function getDictionaryPanelCss(result, font_family)
	local css_justify = G_reader_settings:nilOrTrue("dict_justify") and "text-align: justify;" or ""
	local face_css, face = resolveCssFont(font_family)

	local css = face_css .. [[
@page {
    margin: 0;
    font-family: ']] .. face .. [[';
}
body {
    margin: 0;
    padding: 0;
    line-height: 1.3;
    font-family: ']] .. face .. [[';
]] .. css_justify .. [[
}
blockquote, dd {
    margin: 0 1em;
}
ol, ul, menu {
    margin: 0;
    padding: 0 1.7em;
}
a {
    color: black;
}
.floatingdictionary-word {
    font-size: 1.18em;
    font-weight: bold;
    line-height: 1.15;
}
.floatingdictionary-meta {
    margin-top: 0.08em;
    font-size: 0.78em;
    color: black;
    font-style: italic;
    letter-spacing: 0.02em;
    text-transform: uppercase;
}
.floatingdictionary-separator {
    border-top: 1px solid #ddd;
    margin: 0.35em 0 0.4em 0;
}
]]

	if result and result.css and result.css ~= "" then
		css = css .. "\n" .. result.css
	end

	return css
end

-- Height estimation ----------------------------------------------------------

local function stripHtmlForLineEstimate(html)
	html = tostring(html or "")
	html = html:gsub("<%s*[bB][rR]%s*/?%s*>", "\n")
	html = html:gsub("</%s*[pP]%s*>", "\n")
	html = html:gsub("</%s*[dD][iI][vV]%s*>", "\n")
	html = html:gsub("</%s*[lL][iI]%s*>", "\n")
	html = html:gsub("</%s*[uU][lL]%s*>", "\n")
	html = html:gsub("</%s*[oO][lL]%s*>", "\n")
	html = html:gsub("</%s*[hH][1-6]%s*>", "\n")
	html = html:gsub("<[^>]+>", "")
	html = html:gsub("&nbsp;", " ")
	html = html:gsub("&amp;", "&")
	html = html:gsub("&lt;", "<")
	html = html:gsub("&gt;", ">")
	html = html:gsub("&quot;", '"')
	return html
end

local function estimateHtmlLineCount(html, content_width, font_size)
	local text = stripHtmlForLineEstimate(html)
	local average_char_width = math.max(1, font_size * 0.50)
	local chars_per_line = math.max(12, math.floor(content_width / average_char_width))
	local lines = 0

	text = text:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"

	for raw_line in text:gmatch("(.-)\n") do
		local line = trim(raw_line)
		if line ~= "" then
			lines = lines + math.max(1, math.ceil(#line / chars_per_line))
		end
	end

	return math.max(1, lines)
end

local function getHtmlHeightProfile(html, content_width, font_size, max_html_height)
	local estimated_lines = estimateHtmlLineCount(html, content_width, font_size)
	local line_height = math.ceil(font_size * 1.30)
	local safety_lines = estimated_lines <= 2 and 0.08 or estimated_lines <= 3 and 0.18 or 0.35
	local estimated_height = math.ceil((estimated_lines + safety_lines) * line_height + Screen:scaleBySize(1))
	local base_height = math.max(Screen:scaleBySize(22), math.ceil(font_size * 1.10))
	local min_height = math.max(base_height, estimated_height)

	if max_html_height and max_html_height > 0 then
		min_height = math.min(max_html_height, min_height)
	end

	local compact_cap
	if estimated_lines <= 3 then
		compact_cap = math.ceil((estimated_lines + 0.35) * line_height + Screen:scaleBySize(4))
	end

	return {
		estimated_lines = estimated_lines,
		min_height = min_height,
		compact_cap = compact_cap,
	}
end

-- Button helpers -------------------------------------------------------------
-- ButtonTable only supports icons from KOReader's global icon search path.
-- This small button keeps the same visual structure but can also render an
-- SVG/PNG from this plugin's own icons/ folder via IconWidget's file field.

local PreviewButton = InputContainer:extend({
	text = nil,
	icon = nil,
	icon_file = nil,
	face = nil, -- optional Font face for the text fallback label; defaults to cfont
	disabled = false, -- greys the icon out and makes the tap a no-op
	width = nil,
	height = Screen:scaleBySize(48),
	icon_width = KOREADER_ICON_SIZE,
	icon_height = KOREADER_ICON_SIZE,
	align = "center", -- "center" (default, used for footer icons) or "left" (text rows)
	bold = true, -- text-label buttons are bold by default; pass false for a plain-weight label
	callback = nil,
	show_parent = nil,
})

function PreviewButton:init()
	-- Borderless buttons: keep the touch area, but remove the visible
	-- button frame so the footer looks like a native icon toolbar.
	local bordersize = 0
	local padding_h = Size.padding.button
	local padding_v = Size.padding.button
	local outer_w = self.width or Screen:scaleBySize(80)
	local outer_h = self.height or Screen:scaleBySize(48)
	local inner_w = math.max(1, outer_w - 2 * bordersize - 2 * padding_h)
	local inner_h = math.max(1, outer_h - 2 * bordersize - 2 * padding_v)
	local label
	local is_text_label = not self.icon_file and not self.icon

	if self.icon_file then
		label = IconWidget:new({
			file = self.icon_file,
			width = self.icon_width,
			height = self.icon_height,
			alpha = true,
			is_icon = true,
			-- Very light gray when there's nothing to do, full black/solid
			-- once the action becomes available again.
			dim = self.disabled,
		})
	elseif self.icon then
		label = IconWidget:new({
			icon = self.icon,
			width = self.icon_width,
			height = self.icon_height,
			alpha = true,
			dim = self.disabled,
		})
	else
		label = TextWidget:new({
			text = self.text or "",
			face = self.face or Font:getFace("cfont", UI_FONT_SIZE),
			bold = self.bold,
			max_width = inner_w,
			fgcolor = self.disabled and Blitbuffer.COLOR_LIGHT_GRAY or nil,
		})
	end

	self.label_widget = label

	local content
	if self.align == "left" and is_text_label then
		-- Pad the label out to the full row width with an invisible span
		-- instead of centering it, so text (like a row's name/checkbox)
		-- hugs the left edge while the row itself still reserves the same
		-- fixed width as any other chip next to it.
		local label_size = label:getSize()
		local spacer_width = math.max(0, inner_w - (label_size and label_size.w or 0))
		content = CenterContainer:new({
			dimen = Geom:new({ w = inner_w, h = inner_h }),
			HorizontalGroup:new({
				label,
				HorizontalSpan:new({ width = spacer_width }),
			}),
		})
	else
		content = CenterContainer:new({
			dimen = Geom:new({ w = inner_w, h = inner_h }),
			label,
		})
	end

	self.frame = FrameContainer:new({
		show_parent = self.show_parent,
		bordersize = bordersize,
		background = Blitbuffer.COLOR_WHITE,
		padding_left = padding_h,
		padding_right = padding_h,
		padding_top = padding_v,
		padding_bottom = padding_v,
		content,
	})

	self.dimen = self.frame:getSize()
	self[1] = self.frame
	self.ges_events = {
		TapSelectButton = {
			GestureRange:new({
				ges = "tap",
				range = self.dimen,
			}),
		},
	}
end

function PreviewButton:onTapSelectButton()
	if self.disabled then
		return true
	end
	if self.callback then
		self.callback()
	end
	return true
end

-- Preview popup --------------------------------------------------------------

local FloatingDictionaryPopup = InputContainer:extend({
	html_body = nil,
	css = nil,
	html_resource_directory = nil,
	dialog = nil,
	doc_font_size = Screen:scaleBySize(18),
	button_face = nil, -- resolved Font face matching the book's typeface, used for text-fallback buttons
	button_icon_size = nil, -- scaled with A+/A-; falls back to KOREADER_ICON_SIZE
	button_row_height = nil, -- scaled with A+/A-; falls back to BUTTON_HEIGHT
	open_button_settings_callback = nil, -- called after closing, from the gear button
	open_callback = nil,
	actions = nil, -- ordered list of { spec = {icon|icon_file|text}, callback = function() ... end }
	prev_callback = nil,
	next_callback = nil,
	close_preview_callback = nil,
	result_count = 1,
	anchor_top = false, -- true when the selection sits low on screen and the
	                    -- panel would otherwise cover it; anchors to the top instead.
})

function FloatingDictionaryPopup:init()
	local screen_width = Screen:getWidth()
	local screen_height = Screen:getHeight()

	-- Inset the card from the screen edges so the rounded corners read as a
	-- floating card rather than a full-bleed bar.
	self.width = screen_width - 2 * CARD_OUTER_SIDE_MARGIN

	local max_popup_height = math.floor(screen_height * PANEL_MAX_HEIGHT_RATIO) - CARD_OUTER_BOTTOM_MARGIN

	if Device:isTouchDevice() then
		local range = Geom:new({ x = 0, y = 0, w = screen_width, h = screen_height })
		self.ges_events = {
			TapClose = { GestureRange:new({ ges = "tap", range = range }) },
			SwipeFollow = { GestureRange:new({ ges = "swipe", range = range }) },
		}
	end

	if Device:hasKeys() then
		self.key_events = {
			Close = { { Device.input.group.Back } },
			Follow = { { "Press" } },
		}
	end

	local content_width = math.max(MIN_CONTENT_WIDTH, self.width - CONTENT_PADDING_LEFT - CONTENT_PADDING_RIGHT)
	local buttons = self:makeButtons(content_width)
	local buttons_height = self:getWidgetHeight(buttons, self.button_row_height or BUTTON_HEIGHT)
	local fixed_height = PANEL_PADDING_TOP + TEXT_BUTTON_GAP + buttons_height + PANEL_PADDING_BOTTOM
		+ 2 * CARD_BORDER_SIZE
	local max_html_height = max_popup_height - fixed_height
	local height_profile = getHtmlHeightProfile(self.html_body, content_width, self.doc_font_size, max_html_height)

	if max_html_height < height_profile.min_height then
		max_html_height = height_profile.min_height
	end

	local htmlwidget, htmlwidget_height =
		self:makeSizedHtmlWidget(content_width, max_html_height, height_profile)
	self.htmlwidget = htmlwidget
	self.height = fixed_height + htmlwidget_height

	self.container = FrameContainer:new({
		background = Blitbuffer.COLOR_WHITE,
		bordersize = CARD_BORDER_SIZE,
		color = Blitbuffer.COLOR_DARK_GRAY,
		radius = CARD_RADIUS,
		margin = 0,
		padding = 0,
		VerticalGroup:new({
			VerticalSpan:new({ width = PANEL_PADDING_TOP }),
			HorizontalGroup:new({
				HorizontalSpan:new({ width = CONTENT_PADDING_LEFT }),
				self.htmlwidget,
				HorizontalSpan:new({ width = CONTENT_PADDING_RIGHT }),
			}),
			VerticalSpan:new({ width = TEXT_BUTTON_GAP }),
			HorizontalGroup:new({
				HorizontalSpan:new({ width = CONTENT_PADDING_LEFT }),
				buttons,
				HorizontalSpan:new({ width = CONTENT_PADDING_RIGHT }),
			}),
			VerticalSpan:new({ width = PANEL_PADDING_BOTTOM }),
		}),
	})

	local card_row = HorizontalGroup:new({
		HorizontalSpan:new({ width = CARD_OUTER_SIDE_MARGIN }),
		self.container,
		HorizontalSpan:new({ width = CARD_OUTER_SIDE_MARGIN }),
	})

	if self.anchor_top then
		-- Selection sits low on screen: float the card near the top edge
		-- instead, so it doesn't cover the highlighted word.
		self[1] = TopContainer:new({
			dimen = Screen:getSize(),
			VerticalGroup:new({
				VerticalSpan:new({ width = CARD_OUTER_BOTTOM_MARGIN }),
				card_row,
			}),
		})
	else
		self[1] = BottomContainer:new({
			dimen = Screen:getSize(),
			VerticalGroup:new({
				card_row,
				VerticalSpan:new({ width = CARD_OUTER_BOTTOM_MARGIN }),
			}),
		})
	end
end

function FloatingDictionaryPopup:makeButtons(width)
	local button_height = self.button_row_height or BUTTON_HEIGHT
	local icon_size = self.button_icon_size or KOREADER_ICON_SIZE
	local separator_width = BUTTON_SEPARATOR_WIDTH
	local button_specs = {}

	-- Dictionary-navigation (prev/next) and external-plugin buttons now
	-- arrive as ordinary entries inside self.actions, in whatever order and
	-- visibility the user picked from the settings popup, so they aren't
	-- hardcoded here anymore. Only A-/A+ and the settings gear stay fixed.
	for index, action in ipairs(self.actions or {}) do
		table.insert(button_specs, {
			spec = action.spec or { icon = ICON_SEARCH },
			callback = function()
				return self:onActionButton(index)
			end,
		})
	end

	table.insert(button_specs, {
		spec = { text = "A-" },
		callback = function()
			return self:onDecreaseFontSize()
		end,
	})

	table.insert(button_specs, {
		spec = { text = "A+" },
		callback = function()
			return self:onIncreaseFontSize()
		end,
	})

	-- Always present, never hidden and never listed in the button-visibility
	-- menu it opens: this is the control for that menu, not one of the
	-- toggleable actions.
	table.insert(button_specs, {
		spec = { icon = ICON_SETTINGS },
		callback = function()
			return self:onShowButtonSettings()
		end,
	})

	local button_count = #button_specs
	local separator_count = math.max(0, button_count - 1)
	local available_button_width = math.max(1, width - separator_width * separator_count)
	local button_width = math.floor(available_button_width / button_count)
	local remainder = available_button_width - (button_width * button_count)

	local function makeButton(spec, callback, extra_width)
		spec = spec or {}
		return PreviewButton:new({
			text = spec.text,
			icon = spec.icon,
			icon_file = spec.icon_file,
			face = self.button_face,
			disabled = spec.disabled,
			width = button_width + (extra_width or 0),
			height = button_height,
			icon_width = icon_size,
			icon_height = icon_size,
			show_parent = self,
			callback = callback,
		})
	end

	local function makeSeparator()
		return LineWidget:new({
			background = Blitbuffer.COLOR_LIGHT_GRAY,
			dimen = Geom:new({
				w = separator_width,
				h = button_height,
			}),
		})
	end

	local widgets = {}
	for index, item in ipairs(button_specs) do
		if index > 1 then
			table.insert(widgets, makeSeparator())
		end

		table.insert(widgets, makeButton(
			item.spec,
			item.callback,
			index <= remainder and 1 or 0
		))
	end

	return HorizontalGroup:new(widgets)
end

function FloatingDictionaryPopup:getWidgetHeight(widget, fallback)
	local ok, size = pcall(function()
		return widget:getSize()
	end)

	if ok and size and size.h then
		return size.h
	end

	return fallback
end

function FloatingDictionaryPopup:makeHtmlWidget(content_width, height)
	return ScrollHtmlWidget:new({
		html_body = self.html_body,
		is_xhtml = true,
		css = self.css or FALLBACK_CSS,
		html_resource_directory = self.html_resource_directory,
		default_font_size = self.doc_font_size,
		width = content_width,
		height = height,
		scroll_bar_width = Screen:scaleBySize(6),
		text_scroll_span = Screen:scaleBySize(8),
		dialog = self.dialog,
		highlight_text_selection = true,
	})
end

function FloatingDictionaryPopup:makeSizedHtmlWidget(content_width, max_height, height_profile)
	local min_height = height_profile.min_height
	local compact_cap = height_profile.compact_cap
	local is_compact = compact_cap ~= nil
	local measure_height = is_compact and compact_cap or max_height
	measure_height = math.max(1, math.min(max_height, measure_height))

	local htmlwidget = self:makeHtmlWidget(content_width, measure_height)
	local height = is_compact and measure_height or min_height

	local ok, single_page_height = pcall(function()
		return htmlwidget:getSinglePageHeight()
	end)

	if ok and type(single_page_height) == "number" and single_page_height > 0 then
		local measurement_safety = is_compact and 0 or math.ceil(self.doc_font_size * 0.35)
		height = math.ceil(single_page_height + measurement_safety)
		height = math.max(min_height, math.min(max_height, height))

		if is_compact then
			height = math.max(1, math.min(height, compact_cap))
		end
	else
		height = math.max(1, math.min(max_height, height))
	end

	if height ~= measure_height then
		htmlwidget = self:makeHtmlWidget(content_width, height)
	end

	return htmlwidget, height
end

function FloatingDictionaryPopup:onShow()
	UIManager:setDirty(self.dialog, function()
		return "ui", self.container.dimen
	end)
end

function FloatingDictionaryPopup:onCloseWidget()
	UIManager:setDirty(self.dialog, function()
		return "partial", self.container.dimen
	end)
end

function FloatingDictionaryPopup:onClose()
	UIManager:close(self)
	if self.close_preview_callback then
		return self.close_preview_callback()
	end
	return true
end

function FloatingDictionaryPopup:onClosePreview()
	return self:onClose()
end

function FloatingDictionaryPopup:onActionButton(action_index)
	UIManager:close(self)
	local entry = self.actions and self.actions[action_index]
	if entry and entry.callback then
		return entry.callback()
	end
	return true
end


function FloatingDictionaryPopup:onPrevDictionary()
	if not self.result_count or self.result_count <= 1 then
		return true
	end

	UIManager:close(self)
	if self.prev_callback then
		return self.prev_callback()
	end
	return true
end

function FloatingDictionaryPopup:onNextDictionary()
	if not self.result_count or self.result_count <= 1 then
		return true
	end

	UIManager:close(self)
	if self.next_callback then
		return self.next_callback()
	end
	return true
end

function FloatingDictionaryPopup:onDecreaseFontSize()
	UIManager:close(self)
	if self.decrease_font_callback then
		return self.decrease_font_callback()
	end
	return true
end

function FloatingDictionaryPopup:onIncreaseFontSize()
	UIManager:close(self)
	if self.increase_font_callback then
		return self.increase_font_callback()
	end
	return true
end

function FloatingDictionaryPopup:onShowButtonSettings()
	UIManager:close(self)
	if self.open_button_settings_callback then
		return self.open_button_settings_callback()
	end
	return true
end

function FloatingDictionaryPopup:onTapClose(_arg, ges)
	if
		ges
		and ges.pos
		and self.container
		and self.container.dimen
		and ges.pos:notIntersectWith(self.container.dimen)
	then
		return self:onClosePreview()
	end

	return false
end

function FloatingDictionaryPopup:onSwipeFollow(_arg, ges)
	if not ges or not ges.direction then
		return false
	end

	if ges.direction == "west" then
		return self:onNextDictionary()
	elseif ges.direction == "east" then
		return self:onPrevDictionary()
	elseif ges.direction == (self.anchor_top and "north" or "south") then
		-- Swipe away from wherever the card is currently anchored: down to
		-- dismiss a bottom card, up to dismiss a top card.
		return self:onClosePreview()
	end

	return false
end

-- Button-settings popup ------------------------------------------------------
-- A small centered card, built the same way as FloatingDictionaryPopup (white
-- FrameContainer, whole-screen tap-outside-to-close, Back key to close), but
-- listing one row per footer button. Each row is itself a HorizontalGroup of
-- independently tappable chips (reusing PreviewButton): a wide label chip
-- that toggles visibility, plus a ↑ and/or ↓ chip that reorders the button.
-- Only the arrow(s) that would actually do something are shown, so the first
-- button in the list only gets ↓, the last one only gets ↑, and everything
-- in between gets both.

local FloatingDictionaryButtonSettingsPopup = InputContainer:extend({
	body = nil, -- prebuilt VerticalGroup of rows (title, dividers, action rows, external toggle)
	close_callback = nil,
	on_swipe = nil, -- optional callback(ges), only fired for swipes landing on the card
})

function FloatingDictionaryButtonSettingsPopup:init()
	local screen_width = Screen:getWidth()
	local screen_height = Screen:getHeight()

	if Device:isTouchDevice() then
		local range = Geom:new({ x = 0, y = 0, w = screen_width, h = screen_height })
		self.ges_events = {
			TapClose = { GestureRange:new({ ges = "tap", range = range }) },
			-- Same west/east paging gesture FloatingDictionaryPopup uses to
			-- flip between dictionary results, reused here so a long Font
			-- tab list can be paged with a swipe instead of only the arrows.
			SwipePage = { GestureRange:new({ ges = "swipe", range = range }) },
		}
	end

	if Device:hasKeys() then
		self.key_events = {
			Close = { { Device.input.group.Back } },
		}
	end

	self.card = FrameContainer:new({
		background = Blitbuffer.COLOR_WHITE,
		bordersize = CARD_BORDER_SIZE,
		color = Blitbuffer.COLOR_DARK_GRAY,
		radius = CARD_RADIUS,
		padding = Screen:scaleBySize(10),
		self.body,
	})

	self[1] = CenterContainer:new({
		dimen = Geom:new({ w = screen_width, h = screen_height }),
		self.card,
	})
end

function FloatingDictionaryButtonSettingsPopup:onShow()
	UIManager:setDirty(self, function()
		return "ui", self.card.dimen
	end)
end

function FloatingDictionaryButtonSettingsPopup:onCloseWidget()
	UIManager:setDirty(self, function()
		return "partial", self.card.dimen
	end)
end

function FloatingDictionaryButtonSettingsPopup:onClose()
	UIManager:close(self)
	if self.close_callback then
		return self.close_callback()
	end
	return true
end

function FloatingDictionaryButtonSettingsPopup:onTapClose(_arg, ges)
	if ges and ges.pos and self.card and self.card.dimen and ges.pos:notIntersectWith(self.card.dimen) then
		return self:onClose()
	end
	return false
end

function FloatingDictionaryButtonSettingsPopup:onSwipePage(_arg, ges)
	-- Ignore swipes that started outside the card (e.g. dismissing via
	-- swipe elsewhere on screen shouldn't also page the Font list).
	if not self.on_swipe or not ges or not ges.direction or not ges.pos then
		return false
	end
	if not (self.card and self.card.dimen and ges.pos:intersectWith(self.card.dimen)) then
		return false
	end
	return self.on_swipe(ges.direction)
end

-- Plugin lifecycle -----------------------------------------------------------

function FloatingDictionary:init()
	self.enabled = self:isPreviewEnabled()
	self.current_popup = nil
	self.original_showDict = nil
	self.patched_dictionary = nil
	self.opening_original_popup = false
	self.native_dict_popup_active = false
	self.native_dict_popup_count = 0
	self.selection_snapshot = nil
	self.plugin_icon_cache = {}

	if self.ui and self.ui.menu then
		self.ui.menu:registerToMainMenu(self)
	end

	self:patchDictionary()
end

function FloatingDictionary:addToMainMenu(menu_items)
	menu_items.floatingdictionary = {
		text = _("Floating Dictionary"),
		sorting_hint = "setting",
		sub_item_table = {
			{
				text = _("Enable Floating Dictionary"),
				checked_func = function()
					return self:isPreviewEnabled()
				end,
				callback = function()
					self:setPreviewEnabled(not self:isPreviewEnabled())
				end,
			},
			{
				text_func = function()
					local override = self:getFontFamilyOverride()
					if override then
						return T(_("Preview font: %1"), override)
					end
					return _("Preview font")
				end,
				sub_item_table_func = function()
					return self:genFontFamilyMenu()
				end,
			},
			{
				text = _("Buttons shown in preview"),
				sub_item_table_func = function()
					return self:genVisibleActionsMenu()
				end,
			},
			{
				text = _("Show buttons from other dictionary plugins"),
				checked_func = function()
					return self:isShowExternalButtonsEnabled()
				end,
				callback = function()
					self:setShowExternalButtonsEnabled(not self:isShowExternalButtonsEnabled())
				end,
				separator = true,
			},
		},
	}
end

function FloatingDictionary:isPreviewEnabled()
	return G_reader_settings:nilOrTrue(SETTING_ENABLED)
end

function FloatingDictionary:setPreviewEnabled(enabled)
	self.enabled = enabled and true or false
	G_reader_settings:saveSetting(SETTING_ENABLED, self.enabled)
end

-- A+/A- adjustment, relative to UI_FONT_SIZE. Persisted so it's remembered
-- across lookups and app restarts. Only affects the word/meta/definition
-- text (rendered via CSS); footer buttons always keep UI_FONT_SIZE.
function FloatingDictionary:getFontSizeDelta()
	return G_reader_settings:readSetting(SETTING_FONT_SIZE_DELTA) or 0
end

function FloatingDictionary:setFontSizeDelta(delta)
	delta = math.max(FONT_SIZE_DELTA_MIN, math.min(FONT_SIZE_DELTA_MAX, delta or 0))
	G_reader_settings:saveSetting(SETTING_FONT_SIZE_DELTA, delta)
	return delta
end

-- Preview font family override -------------------------------------------

-- Returns the font *name* the user picked from the settings menu, or nil if
-- they haven't picked one (in which case getDocFontFamily() falls back to
-- the book's font, then the global CRE font, then our own default).
function FloatingDictionary:getFontFamilyOverride()
	local name = G_reader_settings:readSetting(SETTING_FONT_FAMILY)
	if name and name ~= "" then
		return name
	end
	return nil
end

function FloatingDictionary:setFontFamilyOverride(name)
	if name and name ~= "" then
		G_reader_settings:saveSetting(SETTING_FONT_FAMILY, name)
	else
		G_reader_settings:delSetting(SETTING_FONT_FAMILY)
	end
end

-- Builds the "Preview font" radio-button submenu, listing every font face
-- CRE knows about (same list ReaderFont's own font menu uses) plus a
-- "Use book font" entry at the top to go back to the automatic behaviour.
function FloatingDictionary:genFontFamilyMenu()
	local items = {}

	table.insert(items, {
		text = _("Use book font (default)"),
		radio = true,
		checked_func = function()
			return self:getFontFamilyOverride() == nil
		end,
		callback = function()
			self:setFontFamilyOverride(nil)
		end,
	})

	local ok, credoc = pcall(require, "document/credocument")
	if not ok or not credoc or not credoc.engineInit then
		return items
	end
	local ok2, cre = pcall(credoc.engineInit, credoc)
	if not ok2 or not cre or not cre.getFontFaces then
		return items
	end

	local ok3, fonts = pcall(cre.getFontFaces)
	if not ok3 or not fonts then
		return items
	end
	table.sort(fonts, function(a, b)
		return a:lower() < b:lower()
	end)

	for _, font_name in ipairs(fonts) do
		local font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(font_name)
		if not font_filename then
			font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(font_name, nil, true)
		end

		table.insert(items, {
			text_func = function()
				local text = font_name
				if font_filename and font_faceindex and FontList and FontList.getLocalizedFontName then
					local ok4, localized = pcall(FontList.getLocalizedFontName, FontList, font_filename, font_faceindex)
					if ok4 and localized then
						text = localized
					end
				end
				return text
			end,
			radio = true,
			checked_func = function()
				return self:getFontFamilyOverride() == font_name
			end,
			callback = function()
				self:setFontFamilyOverride(font_name)
			end,
		})
	end

	items.max_per_page = 8
	return items
end

function FloatingDictionary:getVisibleActionsSetting()
	local saved = G_reader_settings:readSetting(SETTING_VISIBLE_ACTIONS)
	if type(saved) ~= "table" then
		saved = {}
	end
	return saved
end

function FloatingDictionary:isActionVisible(action_id)
	if action_id == ACTION_NAV_PREV or action_id == ACTION_NAV_NEXT then
		return true -- navigation arrows can be reordered but never hidden
	end
	if action_id == ACTION_EXTERNAL then
		return self:isShowExternalButtonsEnabled()
	end
	local saved = self:getVisibleActionsSetting()
	if saved[action_id] == nil then
		return true -- shown by default
	end
	return saved[action_id] and true or false
end

function FloatingDictionary:setActionVisible(action_id, visible)
	if action_id == ACTION_NAV_PREV or action_id == ACTION_NAV_NEXT then
		return -- can't be hidden, only reordered
	end
	if action_id == ACTION_EXTERNAL then
		self:setShowExternalButtonsEnabled(visible)
		return
	end
	local saved = self:getVisibleActionsSetting()
	saved[action_id] = visible and true or false
	G_reader_settings:saveSetting(SETTING_VISIBLE_ACTIONS, saved)
end

-- Persisted footer button order. Falls back to the default ACTIONS order,
-- and stays in sync with ACTIONS even if it changes between versions: any
-- id missing from the saved order is appended, and any id no longer in
-- ACTIONS (e.g. a removed action) is dropped.
function FloatingDictionary:getActionOrderSetting()
	local saved = G_reader_settings:readSetting(SETTING_ACTIONS_ORDER)
	if type(saved) ~= "table" then
		saved = {}
	end

	local seen = {}
	local order = {}
	for _, action_id in ipairs(saved) do
		if ACTION_BY_ID[action_id] and not seen[action_id] then
			seen[action_id] = true
			table.insert(order, action_id)
		end
	end

	for _, action in ipairs(ACTIONS) do
		if not seen[action.id] then
			seen[action.id] = true
			table.insert(order, action.id)
		end
	end

	return order
end

function FloatingDictionary:setActionOrderSetting(order)
	G_reader_settings:saveSetting(SETTING_ACTIONS_ORDER, order)
end

-- ACTIONS reordered per the persisted user order (all actions, regardless
-- of visibility; getVisibleActions filters that afterwards).
function FloatingDictionary:getOrderedActions()
	local order = self:getActionOrderSetting()
	local ordered = {}
	for _, action_id in ipairs(order) do
		table.insert(ordered, ACTION_BY_ID[action_id])
	end
	return ordered
end

-- Swaps action_id with its neighbor in the given direction (-1 = up/earlier,
-- 1 = down/later) and persists the new order. No-op at either end of the list.
function FloatingDictionary:moveAction(action_id, direction)
	local order = self:getActionOrderSetting()

	local current_pos
	for pos, id in ipairs(order) do
		if id == action_id then
			current_pos = pos
			break
		end
	end
	if not current_pos then
		return
	end

	local target_pos = current_pos + direction
	if target_pos < 1 or target_pos > #order then
		return
	end

	order[current_pos], order[target_pos] = order[target_pos], order[current_pos]
	self:setActionOrderSetting(order)
end

function FloatingDictionary:isShowExternalButtonsEnabled()
	return G_reader_settings:nilOrTrue(SETTING_SHOW_EXTERNAL_BUTTONS)
end

function FloatingDictionary:setShowExternalButtonsEnabled(enabled)
	G_reader_settings:saveSetting(SETTING_SHOW_EXTERNAL_BUTTONS, enabled and true or false)
end

-- The vocabulary-builder button only makes sense if that plugin is enabled.
function FloatingDictionary:hasVocabBuilder()
	return self.ui and self.ui.vocabbuilder ~= nil
end

-- Ordered list of actions that should currently render as footer buttons.
function FloatingDictionary:getVisibleActions()
	local visible = {}
	for _, action in ipairs(self:getOrderedActions()) do
		local available = action.id ~= ACTION_VOCABULARY or self:hasVocabBuilder()
		if available and self:isActionVisible(action.id) then
			table.insert(visible, action)
		end
	end
	return visible
end

function FloatingDictionary:getPluginIconFile(action_id)
	self.plugin_icon_cache = self.plugin_icon_cache or {}
	if self.plugin_icon_cache[action_id] ~= nil then
		return self.plugin_icon_cache[action_id] or nil
	end

	local candidates = PLUGIN_ICON_CANDIDATES[action_id]
	if not candidates or not self.path or self.path == "" then
		self.plugin_icon_cache[action_id] = false
		return nil
	end

	local icons_dir = self.path .. "/icons"
	for _, basename in ipairs(candidates) do
		for _, ext in ipairs(PLUGIN_ICON_EXTENSIONS) do
			local path = icons_dir .. "/" .. basename .. ext
			if fileExists(path) then
				self.plugin_icon_cache[action_id] = path
				return path
			end
		end
	end

	self.plugin_icon_cache[action_id] = false
	return nil
end

-- Icon (or text-fallback) spec for a single footer button.
function FloatingDictionary:getActionIconSpec(action_id)
	local action = ACTION_BY_ID[action_id]
	if not action then
		return { icon = ICON_SEARCH }
	end

	if action_id == ACTION_SEARCH_BOOK then
		return { icon = ICON_SEARCH }
	end

	local plugin_icon = self:getPluginIconFile(action_id)
	if plugin_icon then
		return { icon_file = plugin_icon }
	end

	-- Fallback intentionally uses gettext labels from KOReader's catalog.
	-- This avoids showing an untranslated custom string when the optional
	-- SVG/PNG is not present in icons/. Reduced to a single capitalized
	-- initial so it always fits the button instead of being cut off.
	return { text = getButtonInitial(action.short_label or action.label) }
end

function FloatingDictionary:genVisibleActionsMenu()
	local items = {}

	for _, action in ipairs(self:getOrderedActions()) do
		-- Navigation arrows and the external-plugins group have their own
		-- dedicated handling (swipe gestures always work regardless of
		-- footer visibility; the external toggle already has its own menu
		-- entry above), so only the plain dictionary actions show up here.
		-- All of them, including these, are still reorderable from the
		-- gear-icon settings popup shown from the preview itself.
		if not action.kind then
			table.insert(items, {
				text = action.label,
				enabled_func = function()
					return action.id ~= ACTION_VOCABULARY or self:hasVocabBuilder()
				end,
				checked_func = function()
					return self:isActionVisible(action.id)
				end,
				callback = function()
					self:setActionVisible(action.id, not self:isActionVisible(action.id))
				end,
			})
		end
	end

	return items
end

-- Centered popup opened from the gear button next to the word: one row per
-- footer button, showing its compact letter, its full name, and an explicit
-- checkbox (checked = shown, empty = hidden), plus its own ↑/↓ chips to
-- reorder it. The whole popup is rebuilt after every tap so the checkbox and
-- arrows immediately reflect the new state. Reuses the same persisted
-- settings as the plugin submenu (genVisibleActionsMenu).
function FloatingDictionary:showButtonSettingsMenu(on_close)
	local CHECKBOX_ON = "☑"
	local CHECKBOX_OFF = "☐"
	local RADIO_ON = "●"
	local RADIO_OFF = "○"
	local ROW_HEIGHT = Screen:scaleBySize(50)
	local ARROW_WIDTH = Screen:scaleBySize(50)
	-- Narrower than ARROW_WIDTH since "<<"/">>" is a shorter label than the
	-- ‹›-style icon chips; keeps the page-number label from getting too
	-- cramped in between all four pager chips.
	local JUMP_WIDTH = Screen:scaleBySize(38)
	local POPUP_WIDTH = math.floor(Screen:getWidth() * 0.82)
	local TAB_WIDTH = math.floor(POPUP_WIDTH / 2)
	local row_face = Font:getFace("cfont", UI_FONT_SIZE)
	local popup

	-- Which of the two tabs is currently shown. Persists only for the
	-- lifetime of this popup (not saved), so it always opens on "buttons".
	local current_tab = "buttons"
	-- Current page within the Font tab's list (reset to 1 every time the
	-- Font tab is entered). Paginated, rather than scrollable, so the
	-- popup's box is always exactly the same size as the Buttons tab.
	local font_page = 1

	local function closePopup()
		if popup then
			pcall(function()
				UIManager:close(popup)
			end)
			popup = nil
		end
	end

	local function makeChip(text, width, callback, align, bold, disabled)
		return PreviewButton:new({
			text = text,
			face = row_face,
			width = width,
			height = ROW_HEIGHT,
			align = align or "center",
			callback = callback,
			bold = bold,
			disabled = disabled,
		})
	end

	local function makeIconChip(icon, width, callback)
		return PreviewButton:new({
			icon = icon,
			width = width,
			height = ROW_HEIGHT,
			icon_width = KOREADER_ICON_SIZE,
			icon_height = KOREADER_ICON_SIZE,
			callback = callback,
		})
	end

	local function makeSeparatorLine()
		return LineWidget:new({
			background = Blitbuffer.COLOR_LIGHT_GRAY,
			dimen = Geom:new({ w = POPUP_WIDTH, h = BUTTON_SEPARATOR_WIDTH }),
		})
	end

	local function makeBlankRow()
		return HorizontalGroup:new({ makeChip("", POPUP_WIDTH, nil, "left") })
	end

	-- Number of rows the Buttons tab shows (fixed for a given install: all
	-- actions plus the two nav arrows and the external-plugins group, minus
	-- Vocabulary if that plugin isn't present). Used as the Font tab's page
	-- size too, so both tabs always render the exact same box size.
	local function getButtonsTabRowCount()
		local ordered_actions = self:getOrderedActions()
		local count = 0
		for _, action in ipairs(ordered_actions) do
			if action.id ~= ACTION_VOCABULARY or self:hasVocabBuilder() then
				count = count + 1
			end
		end
		return count
	end

	local rebuild -- forward declaration, referenced by row callbacks below

	-- Header ("Floating Dictionary buttons" + close) plus the two-tab bar
	-- used by both tabs' content.
	local function buildHeaderRows()
		local rows = {}

		table.insert(rows, HorizontalGroup:new({
			makeChip(_("Floating Dictionary settings"), POPUP_WIDTH - ARROW_WIDTH, nil, "left"),
			makeChip("✕", ARROW_WIDTH, function()
				popup:onClose()
			end),
		}))
		table.insert(rows, makeSeparatorLine())

		-- Active tab is marked with a bullet and bold text; tapping either
		-- tab (even the active one) just re-renders that tab's content.
		local buttons_label = (current_tab == "buttons" and "● " or "") .. _("Buttons")
		local font_label = (current_tab == "font" and "● " or "") .. _("Font")
		table.insert(rows, HorizontalGroup:new({
			makeChip(buttons_label, TAB_WIDTH, function()
				current_tab = "buttons"
				rebuild()
			end, "center", current_tab == "buttons"),
			makeChip(font_label, POPUP_WIDTH - TAB_WIDTH, function()
				if current_tab ~= "font" then
					font_page = 1
				end
				current_tab = "font"
				rebuild()
			end, "center", current_tab == "font"),
		}))
		table.insert(rows, makeSeparatorLine())

		return rows
	end

	local function buildButtonRows()
		local rows = {}

		local ordered_actions = self:getOrderedActions()
		local visible_ids = {}
		for _, action in ipairs(ordered_actions) do
			if action.id ~= ACTION_VOCABULARY or self:hasVocabBuilder() then
				table.insert(visible_ids, action.id)
			end
		end

		for list_pos, action_id in ipairs(visible_ids) do
			local action = ACTION_BY_ID[action_id]
			local initial = getButtonInitial(action.short_label or action.label)
			local is_navigation = action.id == ACTION_NAV_PREV or action.id == ACTION_NAV_NEXT
			local is_first = list_pos == 1
			local is_last = list_pos == #visible_ids
			local arrow_count = (is_first and 0 or 1) + (is_last and 0 or 1)

			local row_widgets = {}

			if is_navigation then
				-- Show the actual chevron icon used in the footer (not just
				-- its name), so it's obvious at a glance which button this
				-- row refers to. Navigation arrows can be reordered but
				-- never hidden, so there's no checkbox and no tap-to-toggle.
				local nav_icon = action.id == ACTION_NAV_PREV and ICON_PREVIOUS or ICON_NEXT
				table.insert(row_widgets, makeIconChip(nav_icon, ARROW_WIDTH, nil))
				table.insert(row_widgets, makeChip(
					action.label,
					POPUP_WIDTH - ARROW_WIDTH - arrow_count * ARROW_WIDTH,
					nil,
					"left"
				))
			else
				local checkbox = self:isActionVisible(action.id) and CHECKBOX_ON or CHECKBOX_OFF
				table.insert(row_widgets, makeChip(
					string.format("%s  %s  %s", checkbox, initial, action.label),
					POPUP_WIDTH - arrow_count * ARROW_WIDTH,
					function()
						self:setActionVisible(action.id, not self:isActionVisible(action.id))
						rebuild()
					end,
					"left"
				))
			end

			-- ↑ and ↓ are two separate tappable chips (not one shared zone),
			-- so either can be pressed on its own, and they always sit at
			-- the right edge of the row. Whichever direction has nowhere
			-- left to go is simply left out.
			if not is_first then
				table.insert(row_widgets, makeChip("↑", ARROW_WIDTH, function()
					self:moveAction(action.id, -1)
					rebuild()
				end))
			end
			if not is_last then
				table.insert(row_widgets, makeChip("↓", ARROW_WIDTH, function()
					self:moveAction(action.id, 1)
					rebuild()
				end))
			end

			table.insert(rows, HorizontalGroup:new(row_widgets))
			table.insert(rows, makeSeparatorLine())
		end

		return rows
	end

	-- Reuses genFontFamilyMenu()'s items (built for the native KOReader
	-- menu) so the font list logic only lives in one place; here we just
	-- render each item as a full-width tappable row instead. Paginated to
	-- exactly getButtonsTabRowCount() rows per page (blank rows pad out a
	-- short last page), so this tab is always the same box size as Buttons.
	-- Shared by buildFontRows() and the swipe handler so both agree on how
	-- many pages the Font tab currently has.
	local function getFontTotalPages()
		local per_page = math.max(1, getButtonsTabRowCount())
		local count = #self:genFontFamilyMenu()
		return math.max(1, math.ceil(count / per_page))
	end

	local function buildFontRows()
		local rows = {}
		local font_items = self:genFontFamilyMenu()
		local per_page = math.max(1, getButtonsTabRowCount())
		local total_pages = getFontTotalPages()
		if font_page > total_pages then
			font_page = total_pages
		end

		local start_idx = (font_page - 1) * per_page + 1
		local end_idx = math.min(#font_items, start_idx + per_page - 1)

		for idx = start_idx, end_idx do
			local item = font_items[idx]
			local label = item.text_func and item.text_func() or item.text
			local checked = item.checked_func and item.checked_func()
			local marker = checked and RADIO_ON or RADIO_OFF

			table.insert(rows, HorizontalGroup:new({
				makeChip(
					string.format("%s  %s", marker, label),
					POPUP_WIDTH,
					function()
						if item.callback then
							item.callback()
						end
						-- Selecting a font shouldn't require closing this
						-- menu to see it take effect: refresh the dictionary
						-- popup underneath immediately, then rebuild() puts
						-- this settings card back on top of it.
						if on_close then
							on_close()
						end
						rebuild()
					end,
					"left"
				),
			}))
			table.insert(rows, makeSeparatorLine())
		end

		-- Pad a short last page with blank rows so every page (and the
		-- Buttons tab) renders at exactly the same height.
		local shown = math.max(0, end_idx - start_idx + 1)
		for _ = shown + 1, per_page do
			table.insert(rows, makeBlankRow())
			table.insert(rows, makeSeparatorLine())
		end

		if total_pages > 1 then
			table.insert(rows, HorizontalGroup:new({
				makeChip("<<", JUMP_WIDTH, function()
					if font_page > 1 then
						font_page = 1
						rebuild()
					end
				end, "center", false, font_page <= 1),
				makeIconChip(ICON_PREVIOUS, ARROW_WIDTH, function()
					if font_page > 1 then
						font_page = font_page - 1
						rebuild()
					end
				end),
				makeChip(
					string.format("%d / %d", font_page, total_pages),
					POPUP_WIDTH - 2 * ARROW_WIDTH - 2 * JUMP_WIDTH,
					nil
				),
				makeIconChip(ICON_NEXT, ARROW_WIDTH, function()
					if font_page < total_pages then
						font_page = font_page + 1
						rebuild()
					end
				end),
				makeChip(">>", JUMP_WIDTH, function()
					if font_page < total_pages then
						font_page = total_pages
						rebuild()
					end
				end, "center", false, font_page >= total_pages),
			}))
		end

		return rows
	end

	local function buildRows()
		local rows = buildHeaderRows()
		if current_tab == "font" then
			for _, row in ipairs(buildFontRows()) do
				table.insert(rows, row)
			end
		else
			for _, row in ipairs(buildButtonRows()) do
				table.insert(rows, row)
			end
		end
		return rows
	end

	rebuild = function()
		closePopup()
		popup = FloatingDictionaryButtonSettingsPopup:new({
			body = VerticalGroup:new(buildRows()),
			close_callback = on_close,
			-- West/east swipe pages the Font list, same convention the
			-- dictionary popup uses to flip between results. Only wired up
			-- while the Font tab is showing; ignored on the Buttons tab.
			on_swipe = function(direction)
				if current_tab ~= "font" then
					return false
				end

				local total_pages = getFontTotalPages()
				if direction == "west" and font_page < total_pages then
					font_page = font_page + 1
					rebuild()
					return true
				elseif direction == "east" and font_page > 1 then
					font_page = font_page - 1
					rebuild()
					return true
				end

				return false
			end,
		})
		UIManager:show(popup)
	end

	rebuild()
end

function FloatingDictionary:destroy()
	if self.current_popup then
		UIManager:close(self.current_popup)
		self.current_popup = nil
	end

	if self.patched_dictionary and self.original_showDict and self.patched_dictionary._floatingdictionary_patched then
		self.patched_dictionary.showDict = self.original_showDict
		self.patched_dictionary._floatingdictionary_patched = nil
	end

	self.original_showDict = nil
	self.patched_dictionary = nil
	self.selection_snapshot = nil
	self.plugin_icon_cache = nil
	self:resetNativeDictionaryPopupGuard()

	if WidgetContainer.destroy then
		WidgetContainer.destroy(self)
	end
end

-- Dictionary interception ----------------------------------------------------

function FloatingDictionary:patchDictionary()
	local dictionary = self.ui and self.ui.dictionary

	if not dictionary then
		logger.warn("FloatingDictionary: ReaderDictionary not available.")
		return
	end

	if dictionary._floatingdictionary_patched then
		return
	end

	self.original_showDict = dictionary.showDict
	self.patched_dictionary = dictionary

	local plugin = self

	dictionary.showDict = function(dict_self, word, results, boxes, link, dict_close_callback)
		plugin.enabled = plugin:isPreviewEnabled()
		if not plugin.enabled or plugin.opening_original_popup or not results or not results[1] then
			return plugin.original_showDict(dict_self, word, results, boxes, link, dict_close_callback)
		end

		if plugin.native_dict_popup_active then
			local wrapped_close_callback = plugin:beginNativeDictionaryPopup(dict_close_callback)
			return plugin.original_showDict(dict_self, word, results, boxes, link, wrapped_close_callback)
		end

		plugin:rememberSelection(dict_self)

		if dict_self.dismissLookupInfo then
			pcall(function()
				dict_self:dismissLookupInfo()
			end)
		end

		return plugin:showPreview(dict_self, word, results, boxes, link, dict_close_callback)
	end

	dictionary._floatingdictionary_patched = true
end

function FloatingDictionary:beginNativeDictionaryPopup(dict_close_callback)
	self.native_dict_popup_count = (self.native_dict_popup_count or 0) + 1
	self.native_dict_popup_active = true

	local plugin = self
	local closed = false

	return function(...)
		if not closed then
			closed = true
			plugin.native_dict_popup_count = math.max(0, (plugin.native_dict_popup_count or 1) - 1)
			plugin.native_dict_popup_active = plugin.native_dict_popup_count > 0
		end

		if dict_close_callback then
			return dict_close_callback(...)
		end
	end
end

function FloatingDictionary:resetNativeDictionaryPopupGuard()
	self.native_dict_popup_count = 0
	self.native_dict_popup_active = false
end

function FloatingDictionary:showOriginalDictionaryPopup(dict_self, word, results, boxes, link, dict_close_callback)
	if not self.original_showDict then
		return true
	end

	self.opening_original_popup = true
	local wrapped_close_callback = self:beginNativeDictionaryPopup(dict_close_callback)

	local ok, err = pcall(function()
		self.original_showDict(dict_self, word, results, boxes, link, wrapped_close_callback)
	end)

	self.opening_original_popup = false

	if not ok then
		self:resetNativeDictionaryPopupGuard()
		logger.warn("FloatingDictionary: failed to open original dictionary popup:", err)
	end

	return true
end

-- Reader interactions --------------------------------------------------------

function FloatingDictionary:clearOriginalHighlight(dict_self)
	local highlight = dict_self and dict_self.highlight
	if not highlight then
		return
	end

	local ok, clear_id = pcall(function()
		return highlight:getClearId()
	end)

	if ok and clear_id then
		pcall(function()
			highlight:clear(clear_id)
		end)
	else
		pcall(function()
			highlight:clear()
		end)
	end

	dict_self.highlight = nil
end

function FloatingDictionary:clearSelection()
	if self.ui and self.ui.handleEvent then
		pcall(function()
			self.ui:handleEvent(Event:new("ClearSelection"))
		end)
	end
end

function FloatingDictionary:getInterfaceFontSize()
	return Screen:scaleBySize(UI_FONT_SIZE + self:getFontSizeDelta())
end

function FloatingDictionary:getSearchText(word, result)
	result = result or {}
	local text = word or result.word or ""

	if type(text) == "table" then
		text = text.text or text.word or ""
	end

	text = tostring(text or "")

	if util and util.stripPunctuation then
		local ok, stripped = pcall(function()
			return util.stripPunctuation(text)
		end)

		if ok and stripped and stripped ~= "" then
			text = stripped
		end
	end

	return trim(text)
end

function FloatingDictionary:showSearchDialog(search_text)
	search_text = trim(search_text)
	if search_text == "" then
		return true
	end

	local function openSearchInput()
		if self.ui and self.ui.search and type(self.ui.search.onShowFulltextSearchInput) == "function" then
			local ok, err = pcall(function()
				self.ui.search:onShowFulltextSearchInput(search_text)
			end)
			if ok then
				return true
			end
			logger.warn("FloatingDictionary: direct search input failed:", err)
		end

		if self.ui and self.ui.handleEvent then
			local ok, err = pcall(function()
				self.ui:handleEvent(Event:new("ShowFulltextSearchInput", search_text))
			end)
			if ok then
				return true
			end
			logger.warn("FloatingDictionary: search input event failed:", err)
		end

		if self.ui and self.ui.search and type(self.ui.search.searchText) == "function" then
			local ok, err = pcall(function()
				self.ui.search:searchText(search_text)
			end)
			if ok then
				return true
			end
			logger.warn("FloatingDictionary: direct search execution failed:", err)
		end

		if self.ui and self.ui.handleEvent then
			local ok, err = pcall(function()
				self.ui:handleEvent(Event:new("ShowSearchDialog", search_text, 0, false, true))
			end)
			if not ok then
				logger.warn("FloatingDictionary: search dialog fallback failed:", err)
			end
		end

		return true
	end

	local ok = pcall(function()
		UIManager:scheduleIn(0.05, openSearchInput)
	end)

	if not ok then
		openSearchInput()
	end

	return true
end


function FloatingDictionary:getActiveHighlight(dict_self)
	-- Depending on the KOReader path that opened the dictionary, the active
	-- ReaderHighlight instance may be stored on ReaderDictionary or only on
	-- the reader UI. Prefer an instance that still has a live selection.
	local candidates = {}
	if dict_self and dict_self.highlight then
		table.insert(candidates, dict_self.highlight)
	end
	if self.ui and self.ui.highlight then
		table.insert(candidates, self.ui.highlight)
	end
	if dict_self and dict_self.ui and dict_self.ui.highlight then
		table.insert(candidates, dict_self.ui.highlight)
	end

	local fallback
	for _, highlight in ipairs(candidates) do
		if highlight then
			if highlight.selected_text or highlight.hold_pos then
				return highlight
			end

			if not fallback
				and (type(highlight.showHighlightPrompt) == "function"
					or type(highlight.lookupWikipedia) == "function") then
				fallback = highlight
			end
		end
	end

	return fallback
end

function FloatingDictionary:rememberSelection(dict_self)
	local highlight = self:getActiveHighlight(dict_self)
	if not highlight then
		self.selection_snapshot = nil
		return nil
	end

	-- In the dictionary-on-single-word flow, KOReader may later clear the
	-- live selection when the dictionary lookup UI is dismissed. Store a copy
	-- now so the configurable Highlight action can restore it when pressed.
	if not highlight.selected_text
		and highlight.hold_pos
		and type(highlight.highlightFromHoldPos) == "function" then
		pcall(function()
			highlight:highlightFromHoldPos()
		end)
	end

	self.selection_snapshot = {
		highlight = highlight,
		selected_text = copyTable(highlight.selected_text),
		hold_pos = copyTable(highlight.hold_pos),
		selected_link = copyTable(highlight.selected_link),
		is_word_selection = highlight.is_word_selection,
	}

	return self.selection_snapshot
end

function FloatingDictionary:restoreSelection(dict_self)
	local snapshot = self.selection_snapshot
	local highlight = snapshot and snapshot.highlight or self:getActiveHighlight(dict_self)

	if not highlight then
		return nil
	end

	if snapshot then
		if snapshot.selected_text then
			highlight.selected_text = copyTable(snapshot.selected_text)
		end
		if snapshot.hold_pos then
			highlight.hold_pos = copyTable(snapshot.hold_pos)
		end
		if snapshot.selected_link then
			highlight.selected_link = copyTable(snapshot.selected_link)
		end

		-- The original lookup may have been a single-word dictionary lookup.
		-- For the highlight action we need to treat the restored selection as a
		-- highlightable text selection, not as another dictionary lookup trigger.
		highlight.is_word_selection = false
	end

	if not highlight.selected_text
		and highlight.hold_pos
		and type(highlight.highlightFromHoldPos) == "function" then
		pcall(function()
			highlight:highlightFromHoldPos()
		end)
	end

	return highlight
end

function FloatingDictionary:hasHighlightSelection(highlight)
	return highlight and (highlight.selected_text or highlight.hold_pos) ~= nil
end

function FloatingDictionary:notify(message)
	UIManager:show(Notification:new({ text = message }))
	return true
end

function FloatingDictionary:highlightSelection(dict_self, dict_close_callback)
	local highlight = self:restoreSelection(dict_self)

	if not highlight then
		return self:notify(_("No selection to highlight."))
	end

	if not highlight.selected_text
		and highlight.hold_pos
		and type(highlight.highlightFromHoldPos) == "function" then
		pcall(function()
			highlight:highlightFromHoldPos()
		end)
	end

	if not (highlight.selected_text and highlight.selected_text.pos0 and highlight.selected_text.pos1) then
		return self:notify(_("No selection to highlight."))
	end

	UIManager:scheduleIn(0.05, function()
		local ok, err = pcall(function()
			if type(highlight.showHighlightPrompt) == "function" then
				highlight:showHighlightPrompt(function(...)
					self.selection_snapshot = nil
					if dict_close_callback then
						pcall(dict_close_callback, ...)
					end
				end)
			elseif type(highlight.saveHighlight) == "function" then
				local index = highlight:saveHighlight(true)
				if type(highlight.clear) == "function" then
					highlight:clear()
				end
				self.selection_snapshot = nil
				if dict_close_callback then
					pcall(dict_close_callback, index)
				end
			end
		end)

		if not ok then
			logger.warn("FloatingDictionary: highlight action failed:", err)
		end
	end)

	return true
end

function FloatingDictionary:lookupWikipedia(dict_self, search_text)
	local highlight = self:restoreSelection(dict_self)

	if highlight and type(highlight.lookupWikipedia) == "function" and self:hasHighlightSelection(highlight) then
		UIManager:scheduleIn(0.05, function()
			local ok, err = pcall(function()
				if not highlight.selected_text
					and highlight.hold_pos
					and type(highlight.highlightFromHoldPos) == "function" then
					highlight:highlightFromHoldPos()
				end
				highlight:lookupWikipedia()
				self.selection_snapshot = nil
			end)

			if not ok then
				logger.warn("FloatingDictionary: Wikipedia action failed:", err)
			end
		end)
		return true
	end

	search_text = trim(search_text)
	if search_text ~= "" and self.ui and self.ui.handleEvent then
		self.ui:handleEvent(Event:new("LookupWikipedia", search_text))
		return true
	end

	return self:notify(_("No selection to look up."))
end

-- Translates the looked-up word/phrase using KOReader's own built-in
-- translator (frontend/ui/translator.lua). This is a core module present in
-- every KOReader install -- not a separate plugin file -- so there is
-- nothing extra to import: it already knows the user's configured source/
-- target languages (Settings > Dictionary/Translation > Translate settings,
-- the same menu the stock "Translate" button in the original dictionary
-- popup uses), and shows its results in KOReader's own translation viewer
-- popup layered on top of this one.
function FloatingDictionary:translateText(search_text)
	search_text = trim(search_text)
	if search_text == "" then
		return self:notify(_("No text to translate."))
	end

	local ok, err = pcall(function()
		local Translator = require("ui/translator")
		-- (text, detailed_view, source_lang, target_lang, from_highlight, index)
		-- Leaving source/target nil makes it fall back to the user's saved
		-- translator_from_language / translator_to_language settings.
		Translator:showTranslation(search_text, true, nil, nil, false)
	end)

	if not ok then
		logger.warn("FloatingDictionary: translate action failed:", err)
		return self:notify(_("Could not translate this word."))
	end

	return true
end

-- Adds the current word to the Vocabulary Builder plugin, using the same
-- "WordLookedUp" event that plugins/vocabbuilder.koplugin's own dictionary
-- button fires. This only runs when that plugin is actually enabled.
function FloatingDictionary:addToVocabBuilder(dict_self, search_text)
	if not self:hasVocabBuilder() then
		return self:notify(_("Vocabulary builder is not available."))
	end

	search_text = trim(search_text)
	if search_text == "" then
		return self:notify(_("No word to add."))
	end

	local book_title = (self.ui.doc_props and self.ui.doc_props.display_title) or _("Dictionary lookup")

	local ok, err = pcall(function()
		self.ui:handleEvent(Event:new("WordLookedUp", search_text, book_title, true))
	end)

	if not ok then
		logger.warn("FloatingDictionary: failed to add word to vocabulary builder:", err)
		return self:notify(_("Could not add word to vocabulary builder."))
	end

	return self:notify(_("Added to vocabulary builder."))
end

-- Best-effort discovery of buttons that other installed plugins would add to
-- the *original* dictionary popup via KOReader's "DictButtonsReady" event
-- (the same core event plugins/vocabbuilder.koplugin and xray.koplugin use;
-- see frontend/ui/widget/dictquicklookup.lua, where the real DictQuickLookup
-- fires: self.ui:handleEvent(Event:new("DictButtonsReady", self, buttons))
-- with `self` being the fully-built popup widget itself).
--
-- Since we never construct the real popup, we fire this event ourselves with
-- a stand-in object that mirrors the *real* field set DictQuickLookup has at
-- that point in its lifecycle:
--   - word          : original lookup word (set by ReaderDictionary:showDict)
--   - lookupword    : headword of the *currently shown* result
--                      (real code: self.lookupword = self.results[index].word)
--   - dictionary    : name of the currently shown dictionary
--                      (real code: self.dictionary = self.results[index].dict)
--   - lang          : language of the currently shown result
--   - dict_index    : index of the currently shown result
--   - ui/highlight/dialog/results/word_boxes/selected_link/is_wiki
--                    : same fields ReaderDictionary:showDict passes into
--                      DictQuickLookup:new{...}
-- Any handler reaching for a field we still don't provide fails silently
-- (caught below) instead of crashing the reader.
function FloatingDictionary:discoverExternalButtons(dict_self, word, result, result_index, results, boxes, link)
	if not self:isShowExternalButtonsEnabled() then
		return {}
	end

	if not (self.ui and self.ui.handleEvent) then
		return {}
	end

	result = result or {}

	-- Harmless stand-in for the real ButtonTable widget. Covers third-party
	-- callbacks that poke at self.button_table (e.g. to refresh a button's
	-- label) without crashing them.
	local dummy_button = {
		setText = function() end,
		refresh = function() end,
		enable = function() end,
		disable = function() end,
	}
	local fake_button_table = {
		button_by_id = {},
		getButtonById = function() return dummy_button end,
	}

	local fake_popup = {
		ui = self.ui,
		dialog = dict_self and dict_self.dialog,
		highlight = dict_self and dict_self.highlight,

		word = word,
		lookupword = result.word or word,
		results = results,
		word_boxes = boxes,
		selected_link = link,
		is_wiki = false,

		dict_index = result_index or 1,
		dictionary = result.dict,
		lang = result.lang,

		button_table = fake_button_table,
	}

	local button_rows = {}

	local ok, err = pcall(function()
		self.ui:handleEvent(Event:new("DictButtonsReady", fake_popup, button_rows))
	end)

	if not ok then
		logger.warn("FloatingDictionary: DictButtonsReady discovery failed:", err)
		return {}
	end

	local discovered = {}
	for _, row in ipairs(button_rows) do
		if type(row) == "table" then
			for _, spec in ipairs(row) do
				-- Skip the vocabulary button: we already surface it as a
				-- first-class, icon-capable action above.
				if type(spec) == "table"
					and spec.id ~= ACTION_VOCABULARY
					and type(spec.callback) == "function" then
					table.insert(discovered, spec)
				end
			end
		end
	end

	return discovered
end

function FloatingDictionary:runAction(action_id, dict_self, search_text, dict_close_callback)
	self.current_popup = nil

	if action_id == ACTION_HIGHLIGHT then
		-- Do not clear the selection before highlighting. ReaderHighlight needs
		-- the original selected_text/hold_pos to create the annotation.
		return self:highlightSelection(dict_self, dict_close_callback)
	elseif action_id == ACTION_WIKIPEDIA then
		return self:lookupWikipedia(dict_self, search_text)
	elseif action_id == ACTION_VOCABULARY then
		local result = self:addToVocabBuilder(dict_self, search_text)
		-- Keep the selection/highlight state around: unlike Highlight/Search,
		-- adding to the vocabulary builder doesn't consume the selection.
		return result
	elseif action_id == ACTION_TRANSLATE then
		-- Keep the selection/highlight state around, same reasoning as
		-- ACTION_VOCABULARY: translating doesn't consume the selection, and
		-- the translation viewer is a separate popup layered on top.
		return self:translateText(search_text)
	end

	-- Default: fulltext search in the book.
	self.selection_snapshot = nil
	self:clearOriginalHighlight(dict_self)
	self:clearSelection()
	if dict_close_callback then
		pcall(dict_close_callback)
	end
	return self:showSearchDialog(search_text)
end

-- Preview construction -------------------------------------------------------

function FloatingDictionary:buildPreviewPayload(word, result, result_index, result_count)
	result = result or {}

	local shown_word = result.word or word or _("Dictionary")
	local dict_name = result.dict or _("Dictionary")
	local definition_html
	local css

	-- Match the popup's typeface to whatever font the currently open book
	-- is using, instead of a fixed UI font (same approach as xray_ui.lua) —
	-- unless the user picked an explicit override in the Font tab, which
	-- always wins.
	local doc_font_family = self:getFontFamilyOverride() or getDocFontFamily(self)
	local font_size_delta = self:getFontSizeDelta()
	-- A+/A- now also scales the footer buttons (icon size, row height, and
	-- text-fallback font) by the same ratio as the text, so the whole preview
	-- grows/shrinks together instead of the buttons staying a fixed size.
	local button_scale = (UI_FONT_SIZE + font_size_delta) / UI_FONT_SIZE
	local button_face = getDocFontFace(self, UI_FONT_SIZE + font_size_delta)
	local button_icon_size = Screen:scaleBySize(24 * button_scale)
	local button_row_height = Screen:scaleBySize(46 * button_scale)

	if result.no_result then
		dict_name = _("Dictionary")
		definition_html = "<p>" .. htmlEscape(_("No definition found.")) .. "</p>"
		css = getBaseCss(doc_font_family)
	elseif hasDictionaryCss(result) then
		definition_html = normalizeDictionaryHtml(result.definition)
		css = getDictionaryPanelCss(result, doc_font_family)
	else
		definition_html = normalizeFloatingDictionaryHtml(result.definition)
		css = getBaseCss(doc_font_family)
	end

	if not result.no_result and result_count and result_count > 1 then
		dict_name = string.format("%s · %d/%d", dict_name, result_index or 1, result_count)
	end

	return {
		html_body = table.concat({
			'<div class="floatingdictionary-word">',
			htmlEscape(shown_word),
			"</div>",
			'<div class="floatingdictionary-meta">',
			htmlEscape(dict_name),
			"</div>",
			'<div class="floatingdictionary-separator"></div>',
			definition_html,
		}, "\n"),
		css = css,
		html_resource_directory = result.dictionary_resource_directory,
		button_face = button_face,
		button_icon_size = button_icon_size,
		button_row_height = button_row_height,
	}
end

local function getResultCount(results)
	if type(results) ~= "table" then
		return 0
	end
	return #results
end

local function buildPreviewResults(results)
	local preview_results = {}

	if type(results) ~= "table" then
		return preview_results
	end

	-- Ignore no-result placeholders when at least one dictionary has a real
	-- definition. This keeps navigation focused only on usable dictionary hits.
	for index, result in ipairs(results) do
		if result and not result.no_result then
			table.insert(preview_results, {
				result = result,
				source_index = index,
			})
		end
	end

	-- When no dictionary matched, keep a single placeholder preview so the user
	-- can still use the left action or open the original dictionary popup.
	if #preview_results == 0 and results[1] then
		table.insert(preview_results, {
			result = results[1],
			source_index = 1,
		})
	end

	return preview_results
end

local function normalizeResultIndex(index, count)
	if not count or count <= 0 then
		return 1
	end

	index = tonumber(index) or 1

	if index < 1 then
		return count
	elseif index > count then
		return 1
	end

	return index
end

local function reorderResultsFromIndex(results, index)
	local count = getResultCount(results)
	if count <= 1 or index == 1 then
		return results
	end

	local reordered = {}
	for i = index, count do
		table.insert(reordered, results[i])
	end
	for i = 1, index - 1 do
		table.insert(reordered, results[i])
	end
	return reordered
end

-- Decides whether the preview card should float near the top of the screen
-- instead of the bottom. This matters when the highlighted selection sits in
-- the lower part of the screen: a bottom-anchored card would land right on
-- top of the very word the user just selected.
local function shouldAnchorTop(boxes)
	if type(boxes) ~= "table" or #boxes == 0 then
		return false
	end

	local selection_bottom
	for _, box in ipairs(boxes) do
		if type(box) == "table" and box.y and box.h then
			local box_bottom = box.y + box.h
			if not selection_bottom or box_bottom > selection_bottom then
				selection_bottom = box_bottom
			end
		end
	end

	if not selection_bottom then
		return false
	end

	-- If the selection's lowest edge is already past the screen midpoint,
	-- a bottom-anchored card (which sits in that same lower half) would
	-- very likely cover it. Anchor to the top instead in that case.
	return selection_bottom > (Screen:getHeight() / 2)
end

function FloatingDictionary:showPreview(dict_self, word, results, boxes, link, dict_close_callback)
	local preview_results = buildPreviewResults(results)
	local anchor_top = shouldAnchorTop(boxes)
	local preview_count = #preview_results

	if preview_count <= 0 then
		return true
	end

	if self.current_popup then
		UIManager:close(self.current_popup)
		self.current_popup = nil
	end

	local popup
	local opened_full_popup = false
	local current_index = 1

	local function closeCurrentPopup()
		if popup then
			pcall(function()
				UIManager:close(popup)
			end)
			popup = nil
		end
		self.current_popup = nil
	end

	local function openFullPopup(index)
		opened_full_popup = true
		closeCurrentPopup()

		local preview_index = normalizeResultIndex(index or current_index, preview_count)
		local source_index = preview_results[preview_index] and preview_results[preview_index].source_index or 1
		local selected_results = reorderResultsFromIndex(results, source_index)
		return self:showOriginalDictionaryPopup(dict_self, word, selected_results, boxes, link, dict_close_callback)
	end

	local function closePreview()
		if not opened_full_popup then
			self.current_popup = nil
			self.selection_snapshot = nil
			self:clearOriginalHighlight(dict_self)
			self:clearSelection()
			if dict_close_callback then
				pcall(dict_close_callback)
			end
		end
		return true
	end

	local function showResult(index)
		current_index = normalizeResultIndex(index, preview_count)
		local preview_entry = preview_results[current_index] or preview_results[1] or {}
		local result = preview_entry.result or {}
		local search_text = self:getSearchText(word, result)
		local preview_payload = self:buildPreviewPayload(word, result, current_index, preview_count)

		local action_specs = {}
		local external_specs
		for _, action in ipairs(self:getVisibleActions()) do
			if action.kind == "nav_prev" then
				table.insert(action_specs, {
					spec = { icon = ICON_PREVIOUS, disabled = preview_count <= 1 },
					callback = function()
						if preview_count > 1 then
							return showResult(current_index - 1)
						end
					end,
				})
			elseif action.kind == "nav_next" then
				table.insert(action_specs, {
					spec = { icon = ICON_NEXT, disabled = preview_count <= 1 },
					callback = function()
						if preview_count > 1 then
							return showResult(current_index + 1)
						end
					end,
				})
			elseif action.kind == "external" then
				external_specs = external_specs
					or self:discoverExternalButtons(dict_self, word, result, current_index, results, boxes, link)
				for _, extern_spec in ipairs(external_specs) do
					table.insert(action_specs, {
						spec = { text = getButtonInitial(extern_spec.text) },
						callback = function()
							local ok, err = pcall(extern_spec.callback)
							if not ok then
								logger.warn("FloatingDictionary: external dict button failed:", err)
							end
						end,
					})
				end
			else
				table.insert(action_specs, {
					spec = self:getActionIconSpec(action.id),
					callback = function()
						return self:runAction(action.id, dict_self, search_text, dict_close_callback)
					end,
				})
			end
		end

		closeCurrentPopup()

		popup = FloatingDictionaryPopup:new({
			html_body = preview_payload.html_body,
			css = preview_payload.css,
			html_resource_directory = preview_payload.html_resource_directory,
			button_face = preview_payload.button_face,
			button_icon_size = preview_payload.button_icon_size,
			button_row_height = preview_payload.button_row_height,
			doc_font_size = self:getInterfaceFontSize(),
			dialog = dict_self and dict_self.dialog,
			result_count = preview_count,
			anchor_top = anchor_top,
			actions = action_specs,
			open_callback = function()
				return openFullPopup(current_index)
			end,
			prev_callback = function()
				return showResult(current_index - 1)
			end,
			next_callback = function()
				return showResult(current_index + 1)
			end,
			decrease_font_callback = function()
				self:setFontSizeDelta(self:getFontSizeDelta() - FONT_SIZE_STEP)
				return showResult(current_index)
			end,
			increase_font_callback = function()
				self:setFontSizeDelta(self:getFontSizeDelta() + FONT_SIZE_STEP)
				return showResult(current_index)
			end,
			open_button_settings_callback = function()
				return self:showButtonSettingsMenu(function()
					return showResult(current_index)
				end)
			end,
			close_preview_callback = closePreview,
		})

		self.current_popup = popup
		UIManager:show(popup)
		return true
	end

	return showResult(1)
end

-- Backwards-compatible alias for older local edits/references.
FloatingDictionary.showFootnotePreview = FloatingDictionary.showPreview

return FloatingDictionary
