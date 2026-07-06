local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
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
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Notification = require("ui/widget/notification")
local _ = require("gettext")

local Screen = Device.screen

-- =============================================================================
-- Embedded page-turn "wipe" animation (adapted from the standalone
-- `2-Page-turn-animation.lua` patch), self-contained so this plugin does not
-- depend on that patch being installed separately.
--
-- Only the minimum needed is monkey-patched onto Screen/UIManager, and only
-- once (idempotent guard below), so re-loading this plugin is safe. The
-- actual animation is only ever triggered when *this* plugin explicitly
-- arms it (via FloatingDictAnim.animateShow/animateClose helpers below),
-- so it never fires for unrelated page turns or other UI.
-- =============================================================================
local FloatingDictAnim = {}

if not UIManager._floatingdictionary_repaint_patched then
	UIManager._floatingdictionary_repaint_patched = true

	local userpatch = require("userpatch")
	local dbg = require("dbg")

	-- Framebuffer snapshot + explicit swipe-state setters, same as the patch.
	if not Screen.beforePaint then
		Screen.beforePaint = function(self)
			if not self.painting then
				self.painting = true
				if self.swipe_animations then
					if self.saved_bb then self.saved_bb:free() end
					self.saved_bb = self.bb:copy()
				end
			end
		end
	end

	if not Screen.afterPaint then
		Screen.afterPaint = function(self)
			self.painting = false
		end
	end

	if not Screen.setSwipeAnimations then
		Screen.setSwipeAnimations = function(self, enabled)
			self.swipe_animations = enabled
		end
	end

	if not Screen.setSwipeDirection then
		Screen.setSwipeDirection = function(self, direction)
			self.swipe_forward = direction
		end
	end

	local orig_repaint = UIManager._repaint
	local refresh_methods = userpatch.getUpValue(orig_repaint, "refresh_methods")
	local update_dither = userpatch.getUpValue(orig_repaint, "update_dither")

	local FLOATINGDICT_ANIM_STEPS = 10

	UIManager._repaint = function(self)
		local dirty = false
		local dithered = false

		local start_idx = 1
		for i = #self._window_stack, 1, -1 do
			if self._window_stack[i].widget.covers_fullscreen then
				start_idx = i
				break
			end
		end

		for i = start_idx, #self._window_stack do
			local window = self._window_stack[i]
			local widget = window.widget
			if dirty or self._dirty[widget] then
				Screen:beforePaint()
				widget:paintTo(Screen.bb, window.x, window.y, self._dirty[widget])
				self._dirty[widget] = nil
				dirty = true
				if widget.dithered then
					dithered = true
				end
			end
		end

		for _, refreshfunc in ipairs(self._refresh_func_stack) do
			local refreshtype, region, dither = refreshfunc()
			dither = update_dither(dither, dithered)
			if refreshtype then
				self:_refresh(refreshtype, region, dither)
			end
		end
		self._refresh_func_stack = {}

		if dirty and not self._refresh_stack[1] then
			logger.dbg("no refresh got enqueued. Will do a partial full screen refresh, which might be inefficient")
			self:_refresh("partial")
		end

		-- === software swipe animation (armed only by FloatingDictAnim) ===
		local software_animate = false
		if Screen.swipe_animations then
			local is_mtk = Screen.device and Screen.device.isMTK and Screen.device:isMTK()
			if not is_mtk then
				software_animate = true
			end
		end

		if software_animate then
			Screen.swipe_animations = false
			local saved_bb = Screen.saved_bb
			Screen.saved_bb = nil
			if saved_bb then
				local new_bb = Screen.bb:copy()
				local steps = FLOATINGDICT_ANIM_STEPS
				local screen_w = Screen.bb:getWidth()
				local screen_h = Screen.bb:getHeight()
				local swipe_forward = Screen.swipe_forward
				local prev_dx = 0

				for i = 1, steps do
					local progress = i / steps
					local dx = math.floor(screen_w * progress)
					local strip_w = dx - prev_dx

					if swipe_forward then
						Screen.bb:blitFrom(saved_bb, 0, 0, 0, 0, screen_w - dx, screen_h)
						Screen.bb:blitFrom(new_bb, screen_w - dx, 0, screen_w - dx, 0, dx, screen_h)

						if i < steps then
							if strip_w > 0 then
								Screen:refreshUI(screen_w - dx, 0, strip_w, screen_h)
								self:yieldToEPDC(40000)
							end
						else
							Screen:refreshUI(0, 0, screen_w, screen_h)
						end
					else
						Screen.bb:blitFrom(new_bb, 0, 0, 0, 0, dx, screen_h)
						Screen.bb:blitFrom(saved_bb, dx, 0, dx, 0, screen_w - dx, screen_h)

						if i < steps then
							if strip_w > 0 then
								Screen:refreshUI(prev_dx, 0, strip_w, screen_h)
								self:yieldToEPDC(40000)
							end
						else
							Screen:refreshUI(0, 0, screen_w, screen_h)
						end
					end

					prev_dx = dx
				end

				local kept_refreshes = {}
				for _, refresh in ipairs(self._refresh_stack) do
					if refresh.mode == "full" then
						table.insert(kept_refreshes, refresh)
					end
				end
				self._refresh_stack = kept_refreshes

				new_bb:free()
				saved_bb:free()
			end
		end
		-- === end software swipe animation ===

		for _, refresh in ipairs(self._refresh_stack) do
			refresh.dither = update_dither(refresh.dither, dithered)
			if not Screen.hw_dithering then
				refresh.dither = nil
			end
			dbg:v("triggering refresh", refresh)
			refresh_methods[refresh.mode](Screen,
				refresh.region.x, refresh.region.y,
				refresh.region.w, refresh.region.h,
				refresh.dither)
		end

		if dirty then
			Screen:afterPaint()
		end

		self._refresh_stack = {}
		self.refresh_counted = false
	end
end

-- Arms the wipe animation (direction = true for left-to-right, false for
-- right-to-left) and shows the widget. Falls back to a plain UIManager:show
-- if the device can't do the software animation.
function FloatingDictAnim.animateShow(widget, forward)
	if Device.canDoSwipeAnimation and Device:canDoSwipeAnimation() and Screen.setSwipeAnimations then
		Screen:setSwipeDirection(forward)
		Screen:setSwipeAnimations(true)
	end
	UIManager:show(widget)
end

-- Arms the wipe animation and closes the widget.
function FloatingDictAnim.animateClose(widget, forward)
	if Device.canDoSwipeAnimation and Device:canDoSwipeAnimation() and Screen.setSwipeAnimations then
		Screen:setSwipeDirection(forward)
		Screen:setSwipeAnimations(true)
	end
	UIManager:close(widget)
end

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
local BUTTON_HEIGHT = Screen:scaleBySize(32)
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

-- Cascade breadcrumb: a thin strip glued to the top of the card, above the
-- word/definition area, showing the trail of lookups that led to the one
-- currently shown (e.g. "... -> Patas -> Pelo -> ADN -> Vivo -> Hidrocarburo").
local BREADCRUMB_FONT_SIZE = 15
local BREADCRUMB_GAP = Screen:scaleBySize(4) -- space between breadcrumb strip and separator below it
local BREADCRUMB_BOTTOM_MARGIN = Screen:scaleBySize(4)
local BREADCRUMB_ARROW_TEXT = " \xE2\x86\x92 " -- " -> " (U+2192 RIGHTWARDS ARROW)
local BREADCRUMB_ELLIPSIS_TEXT = "..."
-- Hard cap on how many cards a cascade session keeps stacked at once. Once a
-- new lookup would exceed this, the oldest (bottom of the stack) card is
-- dropped to make room, sliding the window forward -- this is what keeps an
-- overeager chain of cross-references ("word -> word -> word -> ...") from
-- growing without bound. The breadcrumb's leading "..." communicates that
-- older steps exist even when they're no longer literally in the stack.
local CASCADE_MAX_DEPTH = 4
local ICON_SEARCH = "appbar.search"
local ICON_SETTINGS = "appbar.settings"
local ICON_PREVIOUS = "chevron.left"
local ICON_NEXT = "chevron.right"

local SETTING_ENABLED = "floatingdictionary_enabled"
local SETTING_VISIBLE_ACTIONS = "floatingdictionary_visible_actions"
local SETTING_ACTIONS_ORDER = "floatingdictionary_actions_order"
local SETTING_SHOW_EXTERNAL_BUTTONS = "floatingdictionary_show_external_buttons"
local SETTING_FONT_SIZE_DELTA = "floatingdictionary_font_size_delta"
-- Cascading lookups (tapping a cross-reference link inside a definition,
-- which KOReader re-routes through ReaderDictionary:showDict, same as any
-- other lookup) always stack on top of the previous lookup with a
-- breadcrumb trail; this is no longer a user-configurable option.
-- Name (not path) of a font face the user picked from the settings menu to
-- always use in the preview, overriding the book/global-CRE font detection
-- done by getDocFontFamily(). nil/unset means "use the book's font" (default).
local SETTING_FONT_FAMILY = "floatingdictionary_font_family"
-- Translation dictionaries are no longer picked by the user: the plugin
-- auto-detects the looked-up word's language from its own spelling and
-- automatically prefers whichever installed dictionaries look like
-- translation dictionaries for that language pair. See guessWordLanguage()
-- and getTranslationDictionaries() below.

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
local ACTION_FONT_DECREASE = "font_decrease"
local ACTION_FONT_INCREASE = "font_increase"

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
	{ id = ACTION_FONT_DECREASE, label = _("Decrease font size"), short_label = "A-", kind = "font_decrease" },
	{ id = ACTION_FONT_INCREASE, label = _("Increase font size"), short_label = "A+", kind = "font_increase" },
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

-- Breadcrumb word: a bare tappable label (no border/background/padding),
-- used for each clickable step of the cascade breadcrumb trail. The last
-- word in the trail is rendered bold and passed no callback (it's the
-- current lookup, not a place to go "back" to).
local BreadcrumbWord = InputContainer:extend({
	text = nil,
	face = nil,
	bold = false,
	callback = nil,
})

function BreadcrumbWord:init()
	local label = TextWidget:new({
		text = self.text or "",
		face = self.face,
		bold = self.bold,
	})
	self.label_widget = label
	self.dimen = label:getSize()
	self[1] = label

	if self.callback then
		self.ges_events = {
			TapBreadcrumbWord = {
				GestureRange:new({ ges = "tap", range = self.dimen }),
			},
		}
	end
end

function BreadcrumbWord:onTapBreadcrumbWord()
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
	breadcrumb_labels = nil, -- ordered list of strings for the cascade trail; nil/short = hidden
	breadcrumb_callback = nil, -- function(index) called when a non-last breadcrumb word is tapped
	lookup_word_callback = nil, -- function(text) called when the user holds/selects a word in the definition body
})

function FloatingDictionaryPopup:init()
	local screen_width = Screen:getWidth()
	local screen_height = Screen:getHeight()

	-- All cascade cards now share the exact same position and size (no
	-- per-depth inset/peek-behind effect); a new card fully replaces the
	-- previous one visually instead of nesting inside it.
	local side_margin = CARD_OUTER_SIDE_MARGIN
	local edge_margin = CARD_OUTER_BOTTOM_MARGIN

	-- Inset the card from the screen edges so the rounded corners read as a
	-- floating card rather than a full-bleed bar.
	self.width = screen_width - 2 * side_margin

	local max_popup_height = math.floor(screen_height * PANEL_MAX_HEIGHT_RATIO) - edge_margin

	if Device:isTouchDevice() then
		local range = Geom:new({ x = 0, y = 0, w = screen_width, h = screen_height })
		self.ges_events = {
			TapClose = { GestureRange:new({ ges = "tap", range = range }) },
			SwipeFollow = { GestureRange:new({ ges = "swipe", range = range }) },
			HoldStartText = { GestureRange:new({ ges = "hold", range = range }) },
			HoldPanText = { GestureRange:new({ ges = "hold_pan", range = range }) },
			HoldReleaseText = { GestureRange:new({ ges = "hold_release", range = range }) },
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

	-- Breadcrumb strip: only built (and only takes up space) when there's an
	-- actual cascade trail (2+ steps) to show. Sits glued to the top of the
	-- card, above the word/definition area, with its own thin separator line.
	local breadcrumb = self:makeBreadcrumb(content_width)
	local breadcrumb_rows = {}
	local breadcrumb_extra_height = 0
	if breadcrumb then
		local breadcrumb_height = self:getWidgetHeight(breadcrumb, Screen:scaleBySize(BREADCRUMB_FONT_SIZE + 6))
		table.insert(breadcrumb_rows, HorizontalGroup:new({
			HorizontalSpan:new({ width = CONTENT_PADDING_LEFT }),
			breadcrumb,
			HorizontalSpan:new({ width = CONTENT_PADDING_RIGHT }),
		}))
		table.insert(breadcrumb_rows, VerticalSpan:new({ width = BREADCRUMB_GAP }))
		table.insert(breadcrumb_rows, LineWidget:new({
			background = Blitbuffer.COLOR_LIGHT_GRAY,
			dimen = Geom:new({ w = self.width, h = BUTTON_SEPARATOR_WIDTH }),
		}))
		table.insert(breadcrumb_rows, VerticalSpan:new({ width = BREADCRUMB_BOTTOM_MARGIN }))
		breadcrumb_extra_height = breadcrumb_height + BREADCRUMB_GAP + BUTTON_SEPARATOR_WIDTH + BREADCRUMB_BOTTOM_MARGIN
	end

	local fixed_height = PANEL_PADDING_TOP + breadcrumb_extra_height + TEXT_BUTTON_GAP + buttons_height
		+ PANEL_PADDING_BOTTOM + 2 * CARD_BORDER_SIZE
	local max_html_height = math.max(max_popup_height - fixed_height, Screen:scaleBySize(40))

	-- Every card uses the same fixed overall size (max_popup_height) instead
	-- of shrinking/growing to fit its own definition text: shorter
	-- definitions leave blank space below them, longer ones scroll (swipe/tap
	-- or the scroll bar) via the html widget's own paging, exactly like the
	-- root lookup already did.
	self.htmlwidget = self:makeHtmlWidget(content_width, max_html_height)
	self.height = fixed_height + max_html_height

	local body_rows = {}
	table.insert(body_rows, VerticalSpan:new({ width = PANEL_PADDING_TOP }))
	for _, row in ipairs(breadcrumb_rows) do
		table.insert(body_rows, row)
	end
	table.insert(body_rows, HorizontalGroup:new({
		HorizontalSpan:new({ width = CONTENT_PADDING_LEFT }),
		self.htmlwidget,
		HorizontalSpan:new({ width = CONTENT_PADDING_RIGHT }),
	}))
	table.insert(body_rows, VerticalSpan:new({ width = TEXT_BUTTON_GAP }))
	table.insert(body_rows, HorizontalGroup:new({
		HorizontalSpan:new({ width = CONTENT_PADDING_LEFT }),
		buttons,
		HorizontalSpan:new({ width = CONTENT_PADDING_RIGHT }),
	}))
	table.insert(body_rows, VerticalSpan:new({ width = PANEL_PADDING_BOTTOM }))

	self.container = FrameContainer:new({
		background = Blitbuffer.COLOR_WHITE,
		bordersize = CARD_BORDER_SIZE,
		color = Blitbuffer.COLOR_DARK_GRAY,
		radius = CARD_RADIUS,
		margin = 0,
		padding = 0,
		VerticalGroup:new(body_rows),
	})

	local card_row = HorizontalGroup:new({
		HorizontalSpan:new({ width = side_margin }),
		self.container,
		HorizontalSpan:new({ width = side_margin }),
	})

	if self.anchor_top then
		-- Selection sits low on screen: float the card near the top edge
		-- instead, so it doesn't cover the highlighted word.
		self[1] = TopContainer:new({
			dimen = Screen:getSize(),
			VerticalGroup:new({
				VerticalSpan:new({ width = edge_margin }),
				card_row,
			}),
		})
	else
		self[1] = BottomContainer:new({
			dimen = Screen:getSize(),
			VerticalGroup:new({
				card_row,
				VerticalSpan:new({ width = edge_margin }),
			}),
		})
	end
end

-- Builds the cascade breadcrumb strip (e.g. "... -> Patas -> Pelo -> ADN ->
-- Vivo -> Hidrocarburo"), or returns nil when there's nothing to show (fewer
-- than 2 steps in the trail). Words are built from the *end* backwards so the
-- most recent lookup (always kept, always bold) is guaranteed to fit; older
-- words are added while there's still room, and a leading "..." replaces
-- whatever didn't fit. The whole thing never exceeds `width`.
function FloatingDictionaryPopup:makeBreadcrumb(width)
	local labels = self.breadcrumb_labels
	if type(labels) ~= "table" or #labels <= 1 then
		return nil
	end

	local face = Font:getFace("cfont", BREADCRUMB_FONT_SIZE)
	local count = #labels

	local function measure(text, bold)
		local probe = TextWidget:new({ text = text, face = face, bold = bold })
		local w = probe:getSize().w
		probe:free()
		return w
	end

	local arrow_w = measure(BREADCRUMB_ARROW_TEXT, false)
	local ellipsis_w = measure(BREADCRUMB_ELLIPSIS_TEXT, false)

	-- Walk backwards from the last (current, bold) word, greedily including
	-- older steps while they still fit alongside their arrow.
	local included_from = count + 1 -- lowest index included so far (exclusive bound)
	local used_width = 0

	for i = count, 1, -1 do
		local is_last = (i == count)
		local word_w = measure(labels[i], is_last)
		local arrow_cost = is_last and 0 or arrow_w
		local candidate_width = used_width + word_w + arrow_cost

		-- Reserve room for a leading "... -> " unless this is already word 1
		-- (in which case there's nothing left to truncate, so no ellipsis
		-- needed and the full trail is used as-is).
		local reserve = (i > 1) and (ellipsis_w + arrow_w) or 0

		if i < count and candidate_width + reserve > width then
			break
		end

		used_width = candidate_width
		included_from = i
	end

	-- Degenerate case: even the single last word doesn't fit the width on its
	-- own. Show just the word (unbounded), rather than nothing at all.
	if included_from > count then
		included_from = count
	end

	local widgets = {}
	local truncated = included_from > 1

	if truncated then
		table.insert(widgets, TextWidget:new({ text = BREADCRUMB_ELLIPSIS_TEXT, face = face }))
		table.insert(widgets, TextWidget:new({ text = BREADCRUMB_ARROW_TEXT, face = face }))
	end

	for i = included_from, count do
		local is_last = (i == count)
		if is_last then
			table.insert(widgets, TextWidget:new({ text = labels[i], face = face, bold = true }))
		else
			table.insert(widgets, BreadcrumbWord:new({
				text = labels[i],
				face = face,
				bold = false,
				callback = self.breadcrumb_callback and function()
					self.breadcrumb_callback(i)
				end,
			}))
			table.insert(widgets, TextWidget:new({ text = BREADCRUMB_ARROW_TEXT, face = face }))
		end
	end

	return HorizontalGroup:new(widgets)
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
	if self.close_preview_callback then
		return self.close_preview_callback()
	end
	UIManager:close(self)
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

function FloatingDictionaryPopup:onHoldStartText(_arg, ges)
	local box = self.htmlwidget and self.htmlwidget.htmlbox_widget
	if not box or not box.onHoldStartText then
		return false
	end
	return box:onHoldStartText(_arg, ges)
end

function FloatingDictionaryPopup:onHoldPanText(_arg, ges)
	local box = self.htmlwidget and self.htmlwidget.htmlbox_widget
	if not box or not box.onHoldPanText then
		return false
	end
	return box:onHoldPanText(_arg, ges)
end

function FloatingDictionaryPopup:onHoldReleaseText(_arg, ges)
	local box = self.htmlwidget and self.htmlwidget.htmlbox_widget
	if not box or not box.onHoldReleaseText then
		return false
	end

	local selected_text
	local ok = box:onHoldReleaseText(function(text)
		selected_text = text
	end, ges)

	if selected_text and selected_text ~= "" and self.lookup_word_callback then
		self.lookup_word_callback(selected_text)
	end

	return ok
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
	self.current_popup = nil -- kept for backwards compatibility; always mirrors the stack's top
	self.popup_stack = {} -- ordered list of currently shown preview cards, bottom to top
	self.original_showDict = nil
	self.patched_dictionary = nil
	self.opening_original_popup = false
	self.native_dict_popup_active = false
	self.native_dict_popup_count = 0
	self.selection_snapshot = nil
	self.plugin_icon_cache = {}

	-- Cascade state: ordered list of frames { word, results, boxes, link,
	-- dict_close_callback } representing the trail of lookups in the current
	-- session, plus the dict_self/anchor decided by the *root* lookup (reused
	-- for every cascaded step so the card doesn't jump top/bottom mid-trail).
	self.cascade_history = {}
	self.cascade_anchor_top = false
	self.cascade_dict_self = nil
	self.pending_cascade_step = false -- set true right before triggering a lookup from a held/selected word inside a popup, so showPreview treats it as a cascade push instead of a fresh root lookup

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
		-- The external-plugins group has its own dedicated toggle entry
		-- above, so it's skipped here. Navigation arrows and font size
		-- buttons (A+/A-) have a `kind` too but are now plain toggleable
		-- actions like Highlight, so they're included.
		local is_external = action.kind == "external"
		if not is_external then
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
			local is_first = list_pos == 1
			local is_last = list_pos == #visible_ids
			local arrow_count = (is_first and 0 or 1) + (is_last and 0 or 1)

			local row_widgets = {}

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

-- Cascade stack helpers -------------------------------------------------
-- These operate on self.popup_stack / self.cascade_history, which are kept
-- in lockstep: popup_stack[i] is always the card currently showing
-- cascade_history[i]. self.current_popup is kept pointing at the top of the
-- stack purely for backwards compatibility with older code paths.

-- Closes and removes the single topmost card, without touching anything
-- below it (which is already alive and simply becomes visible again).
-- Returns the cascade_history frame that was removed, if any.
-- @param invoke_callback (default true) whether to fire that frame's own
--        dict_close_callback; pass false when ownership of it is being
--        handed off elsewhere (e.g. to the native dictionary popup).
function FloatingDictionary:closeStackTop(invoke_callback)
	local stack = self.popup_stack
	if not stack or #stack == 0 then
		return nil
	end

	local popup = table.remove(stack)
	pcall(function()
		FloatingDictAnim.animateClose(popup, true)
	end)
	self.current_popup = stack[#stack]

	local frame = table.remove(self.cascade_history)
	if invoke_callback ~= false and frame and frame.dict_close_callback then
		pcall(frame.dict_close_callback)
	end
	return frame
end

-- Closes every card in the stack, bottom to top. Used when a brand new
-- (non-cascaded) lookup starts and should replace the whole trail.
function FloatingDictionary:closeAllCards(invoke_callbacks)
	while self.popup_stack and #self.popup_stack > 0 do
		self:closeStackTop(invoke_callbacks)
	end
end

-- Dismisses the current topmost card (tap-outside/swipe/Back on it). If that
-- was the last card in the stack, ends the whole lookup session: clears the
-- book highlight/selection tied to the root lookup. Otherwise, the card
-- below it is simply left showing -- no rebuild needed.
-- Dismisses the whole cascade (tap-outside/swipe/Back on the topmost card):
-- closes every card in the stack and ends the lookup session, clearing the
-- book highlight/selection tied to the root lookup.
function FloatingDictionary:popCard()
	local dict_self = self.cascade_dict_self
	self:closeAllCards()
	self.cascade_history = {}
	self.cascade_dict_self = nil
	self.selection_snapshot = nil
	self:clearOriginalHighlight(dict_self)
	self:clearSelection()

	return true
end

function FloatingDictionary:destroy()
	self:closeAllCards(false)

	if self.patched_dictionary and self.original_showDict and self.patched_dictionary._floatingdictionary_patched then
		self.patched_dictionary.showDict = self.original_showDict
		self.patched_dictionary._floatingdictionary_patched = nil
	end

	self.original_showDict = nil
	self.patched_dictionary = nil
	self.selection_snapshot = nil
	self.plugin_icon_cache = nil
	self.cascade_history = {}
	self.cascade_dict_self = nil
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
	-- The card that triggered this was already closed by onActionButton;
	-- any cards still stacked underneath it are no longer needed either,
	-- since choosing an action (Highlight, Wikipedia, Search, ...) ends the
	-- whole lookup session. Their own dict_close_callbacks are skipped since
	-- dict_close_callback (this action's own) is about to run instead.
	self:closeAllCards(false)

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

-- Extracts a short "quick translation" string out of a translation
-- dictionary's (usually HTML) definition, for display as
-- "word &#8594; translation" next to the headword. Tries a few structural
-- patterns common in bilingual sdcv dictionaries before falling back to
-- just taking the first line of plain text.
function FloatingDictionary:extractPrimaryTranslation(definition)
	if not definition or definition == "" then
		return ""
	end

	-- 1. Strip <font class="grammar">...</font>-style tags and similar.
	local clean_html = definition:gsub("<font[^>]*>.-</font>", "")

	-- 2. First try inside <li><div>...</div></li> list items.
	for match in clean_html:gmatch("<li>%s*<div[^>]*>%s*([^<]+)%s*</div>%s*</li>") do
		local trimmed = match:match("^%s*(.-)%s*$")
		if trimmed and #trimmed > 0 then
			return trimmed
		end
	end

	-- 3. Then try plain <div>...</div> blocks.
	for match in clean_html:gmatch("<div[^>]*>%s*([^<]+)%s*</div>") do
		local trimmed = match:match("^%s*(.-)%s*$")
		if trimmed and #trimmed > 0 then
			return trimmed
		end
	end

	-- 4. Fallback: first line of the plain-text definition.
	local plain_text = definition:gsub("<[^>]+>", ""):match("^%s*(.-)%s*$")
	if plain_text and #plain_text > 0 then
		local first_line = plain_text:match("([^\r\n]+)")
		if first_line then
			return first_line:match("^%s*(.-)%s*$")
		end
		return plain_text
	end

	return ""
end

-- Translation-dictionary auto-detection -----------------------------------
-- Independent from the definition dictionaries already used for the card
-- body: this automatically decides which installed sdcv dictionary(ies)
-- are queried for the short "word -> translation" quick preview next to
-- the headword, based purely on the detected language of the looked-up
-- word -- no user configuration involved (see below).

-- Language auto-detection ------------------------------------------------
-- The plugin no longer asks the user to pick translation dictionaries by
-- hand. Instead it guesses the looked-up word's language from its own
-- spelling, then automatically figures out which installed dictionaries are
-- "translation dictionaries" (bilingual, e.g. an English->Spanish sdcv
-- dictionary) and prioritizes the ones matching the detected language pair.
-- This is designed to scale to more languages later without any settings
-- UI: adding a new language just means adding its detection rule and
-- dictionary-name hints below.

-- Small per-language detection rules. Each entry provides:
--   code       ISO-ish short code used internally (also often what shows up
--              in dictionary names, e.g. "es-en", "EN-ES", "spa-eng").
--   chars      a UTF-8 byte-class matching characters distinctive of this
--              language (accented letters, special punctuation, etc.).
--   words      common short function words/particles for this language.
--   endings    common word endings for this language.
--   names      extra name fragments/aliases used to recognize this language
--              in dictionary booknames (ISO 639-1/639-2 codes, English and
--              native language names, etc.).
local LANGUAGE_RULES = {
	{
		code = "es",
		chars = "[\xC3\xA1\xC3\xA9\xC3\xAD\xC3\xB3\xC3\xBA\xC3\xB1\xC2\xBF\xC2\xA1]", -- á é í ó ú ñ ¿ ¡
		words = { "^el ", "^la ", "^los ", "^las ", "^un ", "^una ", "^de ", "^que " },
		endings = { "ci\xC3\xB3n$", "mente$", "^ll" },
		names = { "es", "spa", "spanish", "espa\xC3\xB1ol", "castellano" },
	},
	{
		code = "en",
		chars = nil,
		words = { "^the ", "^an? ", "^of " },
		endings = { "ing$", "tion$", "ly$" },
		names = { "en", "eng", "english", "ingl\xC3\xA9s" },
	},
}

local DEFAULT_LANGUAGE = "en"

-- Rough heuristic to guess a looked-up word/phrase's language, purely from
-- its own spelling -- no book metadata involved. Falls back to
-- DEFAULT_LANGUAGE when nothing distinctive is found, since sdcv will
-- simply return no_result if that guess is wrong and nothing gets shown.
function FloatingDictionary:guessWordLanguage(word)
	word = tostring(word or ""):lower()
	if word == "" then
		return DEFAULT_LANGUAGE
	end

	for _, rule in ipairs(LANGUAGE_RULES) do
		if rule.chars and word:find(rule.chars) then
			return rule.code
		end
	end

	for _, rule in ipairs(LANGUAGE_RULES) do
		for _, pattern in ipairs(rule.words or {}) do
			if word:find(pattern) then
				return rule.code
			end
		end
		for _, pattern in ipairs(rule.endings or {}) do
			if word:find(pattern) then
				return rule.code
			end
		end
	end

	return DEFAULT_LANGUAGE
end

-- Tries to recognize a language code/name fragment inside an installed
-- dictionary's display name (e.g. "English-Spanish", "es-en Diccionario",
-- "Spanish Translation Dictionary"). Returns the LANGUAGE_RULES code, or
-- nil if nothing recognizable was found.
local function findLanguageInDictName(lower_name, rule)
	for _, alias in ipairs(rule.names or {}) do
		-- Match as a whole "word" (surrounded by non-letters or string
		-- edges) so e.g. "es" doesn't match inside "best" or "testing".
		if lower_name:find("%f[%a]" .. alias .. "%f[%A]") then
			return true
		end
	end
	return false
end

-- Heuristically decides whether an installed dictionary looks like a
-- bilingual "translation dictionary" (as opposed to a monolingual
-- definitions dictionary), and if so, which language(s) it connects.
-- A dictionary counts as a translation dictionary when its name mentions
-- two different known languages (e.g. "English-Spanish"), or the word
-- "translation"/"traducci\xC3\xB3n" together with at least one known language.
local function classifyDictionaryName(dict_name)
	local lower_name = tostring(dict_name or ""):lower()
	local matched_codes = {}

	for _, rule in ipairs(LANGUAGE_RULES) do
		if findLanguageInDictName(lower_name, rule) then
			table.insert(matched_codes, rule.code)
		end
	end

	local mentions_translation = lower_name:find("translat")
		or lower_name:find("traducc")
		or lower_name:find("traduc")

	local is_translation_dict = (#matched_codes >= 2) or (mentions_translation and #matched_codes >= 1)

	return is_translation_dict, matched_codes
end

-- Scans installed dictionaries and automatically builds the list to query
-- for the quick "word -> translation" preview: every installed dictionary
-- that looks like a translation dictionary (see classifyDictionaryName)
-- and is relevant to the detected source language, ordered so the best
-- language match comes first. No user configuration involved.
function FloatingDictionary:getTranslationDictionaries(word)
	local source_lang = self:guessWordLanguage(word)
	local installed = self:getInstalledDictionaryNames()

	local matching = {}
	local other_translation = {}

	for _, dict_name in ipairs(installed) do
		local is_translation_dict, matched_codes = classifyDictionaryName(dict_name)
		if is_translation_dict then
			local matches_source = false
			for _, code in ipairs(matched_codes) do
				if code == source_lang then
					matches_source = true
					break
				end
			end
			if matches_source then
				table.insert(matching, dict_name)
			else
				table.insert(other_translation, dict_name)
			end
		end
	end

	-- Dictionaries matching the detected source language first, then any
	-- other translation dictionaries as a fallback (e.g. only one
	-- translation dictionary is installed and the language guess was off).
	local ordered = {}
	for _, name in ipairs(matching) do
		table.insert(ordered, name)
	end
	for _, name in ipairs(other_translation) do
		table.insert(ordered, name)
	end

	return ordered
end

-- Scans the StarDict data directories (same layout ReaderDictionary uses)
-- for installed dictionaries' display names, so the settings menu can list
-- them as checkable options without the user typing anything by hand.
function FloatingDictionary:getInstalledDictionaryNames()
	local names = {}
	local seen = {}

	if self.ui and self.ui.dictionary and self.ui.dictionary.enabled_dict_names then
		for _, name in ipairs(self.ui.dictionary.enabled_dict_names) do
			if not seen[name] then
				table.insert(names, name)
				seen[name] = true
			end
		end
	end

	local data_dir = (self.ui and self.ui.dictionary and self.ui.dictionary.data_dir)
		or (G_defaults and G_defaults:readSetting("STARDICT_DATA_DIR"))
		or (os.getenv("STARDICT_DATA_DIR"))
		or (DataStorage:getDataDir() .. "/data/dict")

	local function scanDir(path)
		local ok, iter, dir_obj = pcall(lfs.dir, path)
		if ok then
			for name in iter, dir_obj do
				if name ~= "." and name ~= ".." and name ~= "res" then
					local fullpath = path .. "/" .. name
					local attr = lfs.attributes(fullpath)
					if attr and attr.mode == "directory" then
						scanDir(fullpath)
					elseif attr and attr.mode == "file" and fullpath:match("%.ifo$") then
						local f = io.open(fullpath, "r")
						if f then
							local content = f:read("*all")
							f:close()
							local dictname = content:match("\nbookname=(.-)\r?\n") or content:match("^bookname=(.-)\r?\n")
							if dictname and not seen[dictname] then
								table.insert(names, dictname)
								seen[dictname] = true
							end
						end
					end
				end
			end
		end
	end

	scanDir(data_dir)
	scanDir(data_dir .. "_ext")
	table.sort(names)
	return names
end

-- Runs an sdcv lookup restricted to `dictionary_list`, returning the first
-- non-empty result. Compares dictionary names trimmed (not exact-string)
-- since sdcv's own res.dict can differ slightly from the .ifo bookname
-- shown in the settings menu; if nothing matches by name, falls back to the
-- first real result anyway, since sdcv was already restricted to this list.
function FloatingDictionary:lookupInDictionaryList(word, dictionary_list)
	if not word or word == "" or type(dictionary_list) ~= "table" or #dictionary_list == 0 then
		return nil
	end

	local dict_inst = self.ui and self.ui.dictionary
	if not dict_inst or not dict_inst.startSdcv then
		return nil
	end

	local saved_msg = dict_inst.lookup_progress_msg
	dict_inst.lookup_progress_msg = nil

	local ok, results = pcall(function()
		return dict_inst:startSdcv(word, dictionary_list, false)
	end)

	dict_inst.lookup_progress_msg = saved_msg

	if not ok or not results or type(results) ~= "table" or #results == 0 then
		return nil
	end

	for _, wanted_dict in ipairs(dictionary_list) do
		local wanted_trimmed = trim(wanted_dict)
		for _, res in ipairs(results) do
			local definition = tostring(res.definition or ""):match("^%s*(.-)%s*$")
			if trim(res.dict or "") == wanted_trimmed and not res.no_result and definition ~= "" then
				return res
			end
		end
	end

	for _, res in ipairs(results) do
		local definition = tostring(res.definition or ""):match("^%s*(.-)%s*$")
		if not res.no_result and definition ~= "" then
			return res
		end
	end

	return nil
end

-- Preview construction -------------------------------------------------------

function FloatingDictionary:buildPreviewPayload(word, result, result_index, result_count)
	result = result or {}

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


	local shown_word = result.word or word or _("Dictionary")
	local dict_name = result.dict or _("Dictionary")
	local definition_html
	local css

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

	-- Split into "definition" and "translation-looking" dictionary results,
	-- based on the dictionary's own name (classifyDictionaryName): even if
	-- the user has a translation dictionary enabled as a regular KOReader
	-- dictionary (mixed in with normal definition dictionaries), it gets
	-- pushed to the end of the navigable pages instead of interleaved.
	local definition_results = {}
	local translation_results = {}

	-- Ignore no-result placeholders when at least one dictionary has a real
	-- definition. This keeps navigation focused only on usable dictionary hits.
	for index, result in ipairs(results) do
		if result and not result.no_result then
			local entry = { result = result, source_index = index }
			local is_translation_dict = classifyDictionaryName(result.dict)
			if is_translation_dict then
				table.insert(translation_results, entry)
			else
				table.insert(definition_results, entry)
			end
		end
	end

	for _, entry in ipairs(definition_results) do
		table.insert(preview_results, entry)
	end
	for _, entry in ipairs(translation_results) do
		table.insert(preview_results, entry)
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

-- Entry point called by the patched ReaderDictionary:showDict, for *every*
-- lookup: the original one triggered by selecting/holding text in the book,
-- and any follow-up triggered by tapping a cross-reference link inside a
-- definition we're already showing (KOReader routes both through the same
-- showDict call; the follow-up case is recognizable because `link` is set
-- and a cascade is already in progress). We only decide here whether this
-- is a new root lookup or a continuation of the current cascade; the actual
-- popup construction lives in renderCascadeFrame() so a breadcrumb tap can
-- reuse it without re-running this decision.
function FloatingDictionary:showPreview(dict_self, word, results, boxes, link, dict_close_callback)
	if #buildPreviewResults(results) <= 0 then
		return true
	end

	-- Cascading is always on: any follow-up lookup stacks on top of the
	-- previous one instead of just replacing it.
	local is_cascade_step = (link ~= nil or self.pending_cascade_step)
		and #self.cascade_history > 0
	self.pending_cascade_step = false

	local frame = {
		word = word,
		results = results,
		boxes = boxes,
		link = link,
		dict_close_callback = dict_close_callback,
	}

	if is_cascade_step then
		-- Continuing an existing cascade: this new card stacks *on top of*
		-- the one currently shown, which stays open underneath it (renderCascadeFrame
		-- pushes rather than replaces). Don't touch popup_stack here.
		table.insert(self.cascade_history, frame)

		-- Depth cap: rather than growing forever, slide the window forward
		-- by dropping the oldest (bottom-most, most hidden) card.
		if #self.cascade_history > CASCADE_MAX_DEPTH then
			table.remove(self.cascade_history, 1)
			local dropped = table.remove(self.popup_stack, 1)
			if dropped then
				pcall(function()
					UIManager:close(dropped)
				end)
			end
		end
	else
		-- Brand new (non-cascaded) lookup: close the whole stack and start
		-- (or restart) the trail fresh. Its own selection boxes decide
		-- top/bottom anchoring for the whole session.
		self:closeAllCards()
		self.cascade_history = { frame }
		self.cascade_anchor_top = shouldAnchorTop(boxes)
	end

	self.cascade_dict_self = dict_self

	return self:renderCascadeFrame()
end

-- Fired by a popup's onHoldReleaseText when the user selects a word inside an
-- already-open definition. Routes through the same ui:handleEvent("LookupWord")
-- path KOReader's own text selection uses, so it reuses stock sdcv/wiki lookup
-- logic; the patched showDict then picks up the result. pending_cascade_step
-- tells showPreview to push this as a new cascade frame instead of treating it
-- as a fresh root lookup that would wipe the stack.
function FloatingDictionary:lookupSelectedWord(dict_self, text)
	if not text or text == "" then
		return true
	end
	dict_self = dict_self or (self.ui and self.ui.dictionary)
	if not dict_self or type(dict_self.onLookupWord) ~= "function" then
		return true
	end

	local highlight = self.ui and self.ui.highlight

	-- onLookupWord's signature has changed across KOReader versions:
	--   older: (word, box, highlight, link)
	--   newer: (word, is_sane, box, highlight, link, dict_close_callback)
	-- debug.getinfo tells us how many declared params this build has (the
	-- colon-defined method includes an implicit leading `self`), so we call
	-- with the matching shape instead of guessing and risking a double fire.
	local nparams
	local info_ok, info = pcall(debug.getinfo, dict_self.onLookupWord, "u")
	if info_ok and info then
		nparams = info.nparams
	end
	logger.warn("FloatingDictionary: lookupSelectedWord text=", text, "nparams=", nparams, "highlight=", highlight)

	self.pending_cascade_step = true
	local ok, err
	if nparams and nparams >= 6 then
		ok, err = pcall(function()
			dict_self:onLookupWord(text, false, nil, highlight, nil)
		end)
	else
		ok, err = pcall(function()
			dict_self:onLookupWord(text, nil, highlight, nil)
		end)
	end
	logger.warn("FloatingDictionary: onLookupWord call ok=", ok, "err=", err)
	if not ok then
		self.pending_cascade_step = false
	end

	return true
end

-- Tapping a non-current breadcrumb word: close every card cascaded after it,
-- then re-render that card. The target may or may not still be alive
-- underneath (it survives unless it was dropped by the CASCADE_MAX_DEPTH
-- limit), so this always explicitly re-renders it instead of assuming it's
-- already showing. Tapping the current (bold, last) word is a no-op.
function FloatingDictionary:onBreadcrumbSelect(index)
	if type(index) ~= "number" or index < 1 or index >= #self.cascade_history then
		return true
	end

	while #self.cascade_history > index do
		self:closeStackTop()
	end

	return self:renderCascadeFrame(true)
end

-- Builds and shows a new card for whatever was just pushed onto (or is now
-- the tail of) self.cascade_history, stacking it on top of any earlier
-- cascade cards -- which stay open underneath, untouched. Pure rendering
-- for that one new card: does not itself touch earlier stack entries.
function FloatingDictionary:renderCascadeFrame(open_forward)
	if open_forward == nil then
		open_forward = false
	end
	local depth = #self.cascade_history
	local top = self.cascade_history[depth]
	if not top then
		return true
	end

	local dict_self = self.cascade_dict_self
	local word, results, boxes, link, dict_close_callback =
		top.word, top.results, top.boxes, top.link, top.dict_close_callback

	local preview_results = buildPreviewResults(results)
	local anchor_top = self.cascade_anchor_top
	local preview_count = #preview_results

	if preview_count <= 0 then
		return true
	end

	-- Only from the 2nd step onward.
	local breadcrumb_labels = nil
	if depth > 1 then
		breadcrumb_labels = {}
		for _, cascade_frame in ipairs(self.cascade_history) do
			table.insert(breadcrumb_labels, cascade_frame.word or "")
		end
	end

	local popup
	local opened_full_popup = false
	local current_index = 1
	local stack_had_this_frame = false

	-- Replaces *this* card in place (same cascade level: paging between
	-- dictionary results, changing font size, etc.) -- not a stack push.
	-- On the very first call for this frame, `popup` is still nil, so this
	-- is a no-op and the card below ends up freshly pushed further down.
	local function closeCurrentPopup()
		if popup then
			pcall(function()
				UIManager:close(popup)
			end)
			local stack = self.popup_stack
			if stack[#stack] == popup then
				table.remove(stack)
			end
			popup = nil
		end
	end

	local function openFullPopup(index)
		opened_full_popup = true
		-- Escalating to the full native dictionary window ends the whole
		-- cascade: close every stacked card (this one and any older ones
		-- still underneath it). Their dict_close_callbacks are skipped;
		-- this frame's own dict_close_callback is handed off below instead.
		self:closeAllCards(false)
		popup = nil

		local preview_index = normalizeResultIndex(index or current_index, preview_count)
		local source_index = preview_results[preview_index] and preview_results[preview_index].source_index or 1
		local selected_results = reorderResultsFromIndex(results, source_index)
		self.cascade_history = {}
		return self:showOriginalDictionaryPopup(dict_self, word, selected_results, boxes, link, dict_close_callback)
	end

	-- Fired by the card's own tap-outside/swipe/Back dismissal. Pops just
	-- this one card; if there's a cascade card underneath, it's simply left
	-- showing (already alive, nothing to rebuild). Only ends the whole
	-- session (clearing highlight/selection) if this was the last card.
	local function closePreview()
		if not opened_full_popup then
			self:popCard()
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
			elseif action.kind == "font_decrease" then
				table.insert(action_specs, {
					spec = { text = "A-" },
					callback = function()
						self:setFontSizeDelta(self:getFontSizeDelta() - FONT_SIZE_STEP)
						return showResult(current_index)
					end,
				})
			elseif action.kind == "font_increase" then
				table.insert(action_specs, {
					spec = { text = "A+" },
					callback = function()
						self:setFontSizeDelta(self:getFontSizeDelta() + FONT_SIZE_STEP)
						return showResult(current_index)
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
			breadcrumb_labels = breadcrumb_labels,
			breadcrumb_callback = function(index)
				return self:onBreadcrumbSelect(index)
			end,
			lookup_word_callback = function(text)
				return self:lookupSelectedWord(dict_self, text)
			end,
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

		local is_new_card = not stack_had_this_frame
		stack_had_this_frame = true

		table.insert(self.popup_stack, popup)
		self.current_popup = popup
		if is_new_card then
			-- Brand new card for this cascade frame: left-to-right when it's
			-- a fresh cascade step (root lookup or selecting a word), or
			-- right-to-left when it's re-rendered after going back via the
			-- breadcrumb.
			FloatingDictAnim.animateShow(popup, open_forward)
		else
			-- Same cascade level being redrawn in place (paging results,
			-- font size change, etc.): no transition, just show.
			UIManager:show(popup)
		end
		return true
	end

	return showResult(1)
end

-- Backwards-compatible alias for older local edits/references.
FloatingDictionary.showFootnotePreview = FloatingDictionary.showPreview

return FloatingDictionary
