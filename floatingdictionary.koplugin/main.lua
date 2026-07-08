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
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
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

-- FastDict: in-process StarDict engine used to answer instant dictionary
-- lookups (see the "FastDict" section near the end of this file). Pure
-- LuaJIT module, no unconditional KOReader dependency of its own.
local engine_mod = require("engine")

-- WordReview: "Palabra recordada" -- per-book spaced-repetition-style word
-- review shown automatically when a book is opened (see the "Word review"
-- section near the end of this file). Self-contained module so it can be
-- extended independently of the popup/cascade code above.
local WordReview = require("wordreview")

local Screen = Device.screen

-- Declared up-front (before FloatingDictAnim below) so that
-- FloatingDictAnim.isEnabled() closes over this actual local instead of
-- accidentally reading a global of the same name (which would always be
-- nil, making the animations toggle silently no-op).
local SETTING_ANIMATIONS_ENABLED = "floatingdictionary_animations_enabled"

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

-- Whether the user has animations enabled. Defaults to on (matches the
-- plugin's previous, always-on behaviour) so upgrading users see no change
-- until they explicitly opt out via the menu option.
function FloatingDictAnim.isEnabled()
	return G_reader_settings:nilOrTrue(SETTING_ANIMATIONS_ENABLED)
end

-- Arms the wipe animation (direction = true for left-to-right, false for
-- right-to-left) and shows the widget. Falls back to a plain UIManager:show
-- if the device can't do the software animation, or if animations have been
-- disabled by the user in the plugin settings.
function FloatingDictAnim.animateShow(widget, forward)
	if FloatingDictAnim.isEnabled()
		and Device.canDoSwipeAnimation and Device:canDoSwipeAnimation() and Screen.setSwipeAnimations then
		Screen:setSwipeDirection(forward)
		Screen:setSwipeAnimations(true)
	end
	UIManager:show(widget)
end

-- Arms the wipe animation and closes the widget. No-ops the animation (but
-- still closes the widget, instantly) when animations are disabled.
function FloatingDictAnim.animateClose(widget, forward)
	if FloatingDictAnim.isEnabled()
		and Device.canDoSwipeAnimation and Device:canDoSwipeAnimation() and Screen.setSwipeAnimations then
		Screen:setSwipeDirection(forward)
		Screen:setSwipeAnimations(true)
	end
	UIManager:close(widget)
end

-- =============================================================================
-- Embedded fancy highlight styles (adapted from the standalone
-- `2-fancy-highlight-styles.lua` patch), merged directly into this plugin so
-- it is fully self-contained: no separate file needs to live in
-- koreader/patches for the extra styles (Solid medium, Solid light, Dotted,
-- Diagonal thin, Diagonal thick, Grid thin, Outline thick, Grid thick,
-- Crosshatch) to be available.
--
-- This section only teaches KOReader how to *draw* highlights in the new
-- styles and registers their names in the style picker (ReaderHighlight
-- .getHighlightStyles()). It does not touch text selection, hold/hold_pan
-- gesture handling, or ReaderHighlight's own highlight-creation logic in any
-- way, so it cannot interfere with word-selection (dictionary lookup) or
-- phrase-selection (highlight) behaviour elsewhere in this plugin. Applied
-- once per app run via an idempotent guard, same pattern as the embedded
-- page-turn animation above, so re-loading this plugin (e.g. switching
-- documents) is safe.
--
-- The line-thickness values below are the only user-facing "settings" this
-- patch has. They live in a module-level table (LINE_THICKNESS, defined
-- here so the addToMainMenu() code further down in this file can read/edit
-- them and persist changes via G_reader_settings), instead of being locals
-- trapped inside the pcall below. This is purely a relocation of where the
-- numbers live so they can be exposed as a Floating Dictionary submenu
-- entry; the drawing logic and default values are unchanged.
-- =============================================================================
local SETTING_FANCY_HIGHLIGHT_THICKNESS = "floatingdictionary_fancy_highlight_thickness"

local FANCY_HIGHLIGHT_STYLE_LIST = {
	{ _("Crosshatch"),        "crosshatch" },
	{ _("Dash underline"),    "dash_underline" },
	{ _("Diagonal thick"),    "diagonal_thick" },
	{ _("Diagonal thin"),     "diagonal_thin" },
	{ _("Dotted"),            "dotted_fill" },
	{ _("Dotted underline"),  "dotted_underline" },
	{ _("Fine underline"),    "fine_underline" },
	{ _("Grid thick"),        "grid_thick" },
	{ _("Grid thin"),         "grid_thin" },
	{ _("Outline thick"),     "outline_thick" },
	{ _("Plain underline"),   "plain_underline" },
	{ _("Solid light"),       "solid_light" },
	{ _("Solid medium"),      "solid_medium" },
	{ _("Thick underline"),   "thick_underline" },
	{ _("Wavy fill"),         "wavy_fill" },
	{ _("Wavy underline"),    "wavy_underline" },
}

-- Default thickness (in pixels) for each fancy highlight style's
-- line/border/pattern stroke.
local FANCY_HIGHLIGHT_THICKNESS_DEFAULTS = {
	solid_medium    = 2,  -- unused (solid fill has no stroke), kept for menu symmetry
	solid_light     = 2,  -- unused (solid fill has no stroke), kept for menu symmetry
	dotted_fill     = 2,  -- diameter of each dot in the fill pattern
	diagonal_thin   = 1,  -- thickness of each thin diagonal line
	diagonal_thick  = 3,  -- thickness of each thick diagonal line
	grid_thin       = 1,  -- thickness of each grid line
	outline_thick   = 3,  -- thickness of the outline border
	grid_thick      = 2,  -- thickness of each grid line
	crosshatch      = 1,  -- thickness of each crosshatch line
	plain_underline  = 2,  -- thickness of the plain underline
	dash_underline   = 2,  -- thickness of each dash
	thick_underline  = 4,  -- thickness of the thick underline
	dotted_underline = 2,  -- diameter of each dot
	fine_underline   = 1,  -- thickness of the fine underline
	wavy_underline   = 2,  -- thickness of the wave line (bottom only)
	wavy_fill        = 1,  -- thickness of the wave lines (filled band)
}

-- Loads any previously saved thickness overrides, falling back to defaults
-- for anything not yet saved. Shared table, read by the drawer function
-- below and read/written by the Floating Dictionary menu.
local function loadFancyHighlightThickness()
	local saved = (G_reader_settings and G_reader_settings:readSetting(SETTING_FANCY_HIGHLIGHT_THICKNESS)) or {}
	local thickness = {}
	for style_id, default_value in pairs(FANCY_HIGHLIGHT_THICKNESS_DEFAULTS) do
		thickness[style_id] = saved[style_id] or default_value
	end
	return thickness
end

if not UIManager._floatingdictionary_fancy_highlight_thickness then
	UIManager._floatingdictionary_fancy_highlight_thickness = loadFancyHighlightThickness()
end
local LINE_THICKNESS = UIManager._floatingdictionary_fancy_highlight_thickness

local function saveFancyHighlightThickness()
	if G_reader_settings then
		G_reader_settings:saveSetting(SETTING_FANCY_HIGHLIGHT_THICKNESS, LINE_THICKNESS)
	end
end

if not UIManager._floatingdictionary_highlight_styles_patched then
	UIManager._floatingdictionary_highlight_styles_patched = true

	local ok_styles, err_styles = pcall(function()
		local ReaderView = require("apps/reader/modules/readerview")
		local ReaderHighlight = require("apps/reader/modules/readerhighlight")

		-- ─────────────────────────────────────────────────────────────────
		-- ⚙️  SETTINGS -- line thickness is now configurable from the
		-- Floating Dictionary menu (see LINE_THICKNESS above). The other
		-- shape parameters below are still fixed constants, unchanged from
		-- the original standalone patch.
		-- ─────────────────────────────────────────────────────────────────

		-- Stripe gap (pixels) used by the three solid-fill styles: smaller
		-- gap = denser strokes = visually darker fill.
		local SOLID_MEDIUM_GAP = 2
		local SOLID_LIGHT_GAP  = 4

		-- Spacing (pixels between dot centers) for "Dotted" fill.
		local DOTTED_FILL_SPACING = 6

		-- Spacing (pixels between line centers, measured perpendicular to
		-- the line) for the two diagonal-hatch styles and the crosshatch.
		local DIAGONAL_THIN_SPACING  = 6
		local DIAGONAL_THICK_SPACING = 8
		local CROSSHATCH_SPACING     = 7

		-- Spacing (pixels between grid lines) for the two grid styles.
		local GRID_THIN_SPACING  = 6
		local GRID_THICK_SPACING = 9

		-- Length of each dash / gap for "Dash underline", in pixels
		local DASH_UNDERLINE_SIZE = { dash = 8, gap = 4 }

		-- Length of each dot / gap for "Dotted underline", in pixels
		local DOTTED_UNDERLINE_SIZE = { dot = 3, gap = 3 }

		-- Size of one wave cycle for "Wavy underline"/"Wavy fill", in
		-- pixels (width, height)
		local WAVY_SIZE = { w = 7, h = 4 }
		-- Vertical gap between wave cycles when filling a band (Wavy fill)
		local WAVY_FILL_ROW_GAP = 4
		-- ─────────────────────────────────────────────────────────────────

		-- ── Register the new style names so they show up in the style picker ──
		-- Uses the same FANCY_HIGHLIGHT_STYLE_LIST table defined at module
		-- level above (also used by the Floating Dictionary settings menu),
		-- so the two stay in sync automatically instead of listing the 7
		-- styles twice.
		local highlight_styles = ReaderHighlight.getHighlightStyles()

		for _, new_style in ipairs(FANCY_HIGHLIGHT_STYLE_LIST) do
			local already_added = false
			for _, style in ipairs(highlight_styles) do
				if style[2] == new_style[2] then
					already_added = true
					break
				end
			end
			if not already_added then
				table.insert(highlight_styles, new_style)
			end
		end

		-- ── Teach KOReader how to actually draw the new styles ─────────────
		local orig_drawHighlightRect = ReaderView.drawHighlightRect

		local custom_drawers = {
			solid_medium = true,
			solid_light = true,
			dotted_fill = true,
			diagonal_thin = true,
			diagonal_thick = true,
			grid_thin = true,
			outline_thick = true,
			grid_thick = true,
			crosshatch = true,
			plain_underline = true,
			dash_underline = true,
			thick_underline = true,
			dotted_underline = true,
			fine_underline = true,
			wavy_underline = true,
			wavy_fill = true,
		}

		ReaderView.drawHighlightRect = function(self, bb, _x, _y, rect, drawer, color, draw_note_mark)
			if not custom_drawers[drawer] then
				-- Not one of ours: fall back to KOReader's normal drawing
				-- (this covers Shade, Invert, Underline, and anything else,
				-- including any drawer this plugin doesn't know about).
				return orig_drawHighlightRect(self, bb, _x, _y, rect, drawer, color, draw_note_mark)
			end

			local x, y, w, h = rect.x, rect.y, rect.w, rect.h
			color = color or Blitbuffer.COLOR_BLACK
			local is_color8 = Blitbuffer.isColor8(color)

			local function paint(px, py, pw, ph)
				if is_color8 then
					bb:paintRect(px, py, pw, ph, color)
				else
					bb:paintRectRGB32(px, py, pw, ph, color)
				end
			end

			-- Outline-drawing helper for Rectangle: draws a border "thick"
			-- pixels wide using the same paint() used everywhere else, so it
			-- works on both color8 and RGB32 buffers.
			local function paintBorder(bx, by, bw, bh, thick)
				if bb.paintBorder then
					bb:paintBorder(bx, by, bw, bh, thick, color)
				else
					paint(bx, by, bw, thick)                     -- top
					paint(bx, by + bh - thick, bw, thick)         -- bottom
					paint(bx, by, thick, bh)                      -- left
					paint(bx + bw - thick, by, thick, bh)         -- right
				end
			end

			-- Fills (px,py,pw,ph) with "color" so the covered text stays
			-- legible, used by the three solid-fill styles. KOReader's
			-- Blitbuffer has no blendRect/opacity-aware paintRect (calling
			-- those crashes the native reader instead of raising a Lua
			-- error), so instead of faking translucency we vary how dense
			-- the paint is: darker styles use closer-packed horizontal
			-- strokes, lighter styles use sparser ones. Same paint()/color
			-- path as every other style here, just a different density.
			local function paintBlend(px, py, pw, ph, stripe_gap)
				for row = 0, ph - 1, stripe_gap do
					paint(px, py + row, pw, 1)
				end
			end

			-- Draws a full diagonal hatch (single direction, bottom-left to
			-- top-right) across the whole highlight rect. "spacing" is the
			-- perpendicular distance between line centers; "thick" is line
			-- thickness. Lines are drawn as 1px-wide diagonal steps, offset
			-- across the box width, so it works identically on color8 and
			-- RGB32 buffers without needing a native line primitive.
			local function paintDiagonalHatch(spacing, thick)
				local half = math.floor(thick / 2)
				for offset = -h, w, spacing do
					for i = 0, h - 1 do
						local px = x + offset + i
						local py = y + h - 1 - i
						if px >= x and px < x + w then
							paint(px - half, py, thick, 1)
						end
					end
				end
			end

			-- Draws an evenly-spaced grid (horizontal + vertical lines)
			-- across the whole highlight rect.
			local function paintGrid(spacing, thick)
				for gy = 0, h, spacing do
					paint(x, y + math.min(gy, h - thick), w, thick)
				end
				for gx = 0, w, spacing do
					paint(x + math.min(gx, w - thick), y, thick, h)
				end
			end

			-- Draws an evenly-spaced field of small square dots across the
			-- whole highlight rect.
			local function paintDots(spacing, dot_size)
				for gy = math.floor(spacing / 2), h, spacing do
					for gx = math.floor(spacing / 2), w, spacing do
						paint(x + gx, y + gy, dot_size, dot_size)
					end
				end
			end

			if drawer == "solid_medium" then
				paintBlend(x, y, w, h, SOLID_MEDIUM_GAP)

			elseif drawer == "solid_light" then
				paintBlend(x, y, w, h, SOLID_LIGHT_GAP)

			elseif drawer == "dotted_fill" then
				local thick = LINE_THICKNESS.dotted_fill
				paintDots(DOTTED_FILL_SPACING, thick)

			elseif drawer == "diagonal_thin" then
				local thick = LINE_THICKNESS.diagonal_thin
				paintDiagonalHatch(DIAGONAL_THIN_SPACING, thick)

			elseif drawer == "diagonal_thick" then
				local thick = LINE_THICKNESS.diagonal_thick
				paintDiagonalHatch(DIAGONAL_THICK_SPACING, thick)

			elseif drawer == "grid_thin" then
				local thick = LINE_THICKNESS.grid_thin
				paintGrid(GRID_THIN_SPACING, thick)

			elseif drawer == "outline_thick" then
				local thick = LINE_THICKNESS.outline_thick
				paintBorder(x, y, w, h, thick)

			elseif drawer == "grid_thick" then
				local thick = LINE_THICKNESS.grid_thick
				paintGrid(GRID_THICK_SPACING, thick)

			elseif drawer == "crosshatch" then
				local thick = LINE_THICKNESS.crosshatch
				paintDiagonalHatch(CROSSHATCH_SPACING, thick)
				-- Second pass, mirrored, to cross the first set of lines.
				for offset = -h, w, CROSSHATCH_SPACING do
					for i = 0, h - 1 do
						local px = x + offset + i
						local py = y + i
						if px >= x and px < x + w then
							local half = math.floor(thick / 2)
							paint(px - half, py, thick, 1)
						end
					end
				end

			elseif drawer == "plain_underline" then
				local thick = LINE_THICKNESS.plain_underline
				paint(x, y + h - thick, w, thick)

			elseif drawer == "dash_underline" then
				local thick = LINE_THICKNESS.dash_underline
				local dash_len, gap_len = DASH_UNDERLINE_SIZE.dash, DASH_UNDERLINE_SIZE.gap
				for i = 0, w, dash_len + gap_len do
					local dw = math.min(dash_len, w - i)
					if dw > 0 then
						paint(x + i, y + h - thick, dw, thick)
					end
				end

			elseif drawer == "thick_underline" then
				local thick = LINE_THICKNESS.thick_underline
				paint(x, y + h - thick, w, thick)

			elseif drawer == "dotted_underline" then
				local thick = LINE_THICKNESS.dotted_underline
				local dot_len, gap_len = DOTTED_UNDERLINE_SIZE.dot, DOTTED_UNDERLINE_SIZE.gap
				for i = 0, w, dot_len + gap_len do
					local dw = math.min(dot_len, w - i)
					if dw > 0 then
						paint(x + i, y + h - thick, dw, thick)
					end
				end

			elseif drawer == "fine_underline" then
				local thick = LINE_THICKNESS.fine_underline
				paint(x, y + h - thick, w, thick)

			elseif drawer == "wavy_underline" then
				local thick = LINE_THICKNESS.wavy_underline
				local wave_w, wave_h = WAVY_SIZE.w, WAVY_SIZE.h
				local cy = y + h - 2
				for i = 0, w - 1 do
					local dy = math.floor(math.sin(i / wave_w * math.pi) * wave_h + 0.5)
					paint(x + i, cy + dy, 1, thick)
				end

			elseif drawer == "wavy_fill" then
				local thick = LINE_THICKNESS.wavy_fill
				local wave_w, wave_h = WAVY_SIZE.w, WAVY_SIZE.h
				local row = 0
				while row < h do
					local cy = y + row + wave_h
					for i = 0, w - 1 do
						local dy = math.floor(math.sin(i / wave_w * math.pi) * wave_h + 0.5)
						local py = cy + dy
						if py < y + h then
							paint(x + i, py, 1, thick)
						end
					end
					row = row + wave_h * 2 + WAVY_FILL_ROW_GAP
				end
			end

			-- Preserve the little note-mark indicator KOReader draws when a
			-- highlight has an attached note, so that still works normally.
			if self.highlight.note_mark ~= nil and draw_note_mark ~= nil then
				if self.highlight.note_mark == "underline" then
					paint(x, y + h - 1, w, Size.line.medium)
				end
			end
		end
	end)

	if not ok_styles then
		logger.warn("FloatingDictionary: fancy highlight styles failed to load:", err_styles)
	end
end

local FloatingDictionary = WidgetContainer:extend({
	name = "floatingdictionary",
	is_doc_only = true,
})

-- UI constants ---------------------------------------------------------------

local UI_FONT_FACE = "Noto Sans"
local UI_FONT_SIZE = 20

-- Default card height (fraction of screen height) and the selectable range
-- exposed in the KOReader settings menu. The actual value in effect is
-- read from SETTING_CARD_HEIGHT_RATIO via FloatingDictionary:getCardHeightRatio().
local PANEL_MAX_HEIGHT_RATIO = 0.38
local CARD_HEIGHT_RATIO_MIN = 0.20
local CARD_HEIGHT_RATIO_MAX = 0.70
local MIN_CONTENT_WIDTH = Screen:scaleBySize(120)

local KOREADER_ICON_SIZE = Screen:scaleBySize(24)
local BUTTON_HEIGHT = Screen:scaleBySize(12)
local BUTTON_SEPARATOR_WIDTH = math.max(1, Screen:scaleBySize(1))

-- Card look: the panel floats slightly above the bottom edge and is inset
-- from the sides so its rounded corners are actually visible.
local CARD_OUTER_SIDE_MARGIN = Screen:scaleBySize(10)
local CARD_OUTER_BOTTOM_MARGIN = Screen:scaleBySize(10)
local CARD_RADIUS = Screen:scaleBySize(14)

-- Popup border thickness/darkness: user-configurable from the settings menu
-- (same SpinWidget dialog KOReader itself uses for things like "Gray
-- highlight opacity"), applied to every dictionary popup card (the main
-- preview card and the footer button-settings card). Thickness is in
-- pixels; darkness is 0.0 (white/invisible) - 1.0 (solid black), converted
-- to a grayscale color via Blitbuffer.Color8 wherever the border is drawn.
local SETTING_POPUP_BORDER_THICKNESS = "floatingdictionary_popup_border_thickness"
local SETTING_POPUP_BORDER_DARKNESS = "floatingdictionary_popup_border_darkness"
local POPUP_BORDER_THICKNESS_DEFAULT = Size.border.thin
local POPUP_BORDER_THICKNESS_MIN = 0
local POPUP_BORDER_THICKNESS_MAX = 10
local POPUP_BORDER_DARKNESS_DEFAULT = 1.0 -- matches the previous fixed Blitbuffer.COLOR_DARK_GRAY look
local POPUP_BORDER_DARKNESS_MIN = 0.0
local POPUP_BORDER_DARKNESS_MAX = 1.0
local POPUP_BORDER_DARKNESS_STEP = 0.1

local PANEL_PADDING_TOP = Screen:scaleBySize(10)
local PANEL_PADDING_BOTTOM = Screen:scaleBySize(6)
local TEXT_BUTTON_GAP = Screen:scaleBySize(6)
local BUTTON_ROW_SEPARATOR_WIDTH = math.max(1, Screen:scaleBySize(1.5)) -- thicker/darker than the thin breadcrumb divider, so the button bar reads as a distinct footer, per reference image
local BUTTON_ROW_SEPARATOR_GAP = 0 -- no gap: vertical button separators must join flush with this line, forming one continuous divider
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
-- Per-action custom footer button labels. Only actions that render as a
-- text-fallback button (see getActionIconSpec/getButtonInitial) are
-- affected; an empty/unset entry means "use the default initial letter".
local SETTING_ACTION_CUSTOM_LABELS = "floatingdictionary_action_custom_labels"
-- Per-action custom SVG icon, chosen from floatingdictionary-images/. When
-- set for an action, it takes priority over that action's custom text label
-- (see getActionIconSpec/getActionCustomIcon below); when the referenced
-- file is missing (e.g. deleted after being selected), the button falls
-- back to the text label, then to the default initial letter, exactly as
-- if no icon had ever been chosen.
local SETTING_ACTION_CUSTOM_ICONS = "floatingdictionary_action_custom_icons"
-- Name of the folder (inside the plugin's own directory) the user drops
-- their own .svg files into for use as button icons.
local CUSTOM_ICONS_DIR_NAME = "floatingdictionary-images"

-- Persisted, user-defined display order for *installed dictionaries*
-- (definitions, translations, synonyms, antonyms, etymology, conjugations,
-- pronunciation, usage examples, thesauri, or any other kind KOReader can
-- query). Stored as a plain array of dictionary display names (the same
-- strings returned by getInstalledDictionaryNames/reported in result.dict),
-- most-preferred first. This intentionally does NOT try to auto-classify
-- dictionaries into fixed "kinds": the previous definition/translation-only
-- split doesn't generalize to the many dictionary types users may install,
-- while a plain user-ranked list scales to any number of dictionaries of any
-- type without the plugin ever needing to know what they are. See
-- getDictionaryOrderSetting/moveDictionaryInOrder/genDictionaryOrderMenu and
-- sortResultsByDictionaryOrder below.
local SETTING_DICTIONARY_ORDER = "floatingdictionary_dictionary_order"
local SETTING_SHOW_EXTERNAL_BUTTONS = "floatingdictionary_show_external_buttons"
local SETTING_FONT_SIZE_DELTA = "floatingdictionary_font_size_delta"
-- Card height as a fraction of the screen height, user-configurable from the
-- KOReader settings menu so small screens (e.g. 6") and large ones (10"+)
-- can each pick a card size that fits them well. Replaces the old fixed
-- PANEL_MAX_HEIGHT_RATIO constant, which is now only the default value.
local SETTING_CARD_HEIGHT_RATIO = "floatingdictionary_card_height_ratio"
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

-- Display mode: a single exclusive choice (radio-style, not independent
-- switches) that layers a few opinionated overrides on top of whatever the
-- user already configured via "Buttons shown in preview" / "Show buttons
-- from other dictionary plugins" / etc. Switching modes takes effect
-- immediately since every render path re-reads it live (getVisibleActions,
-- buildPreviewResults) instead of it being baked into any cached state.
--   DISPLAY_MODE_PERSONAL - no override: the plugin behaves exactly as
--                           configured by the individual settings above.
--                           This is the only mode the user can edit --
--                           every popup appearance/behavior setting always
--                           saves into this mode, and selecting it always
--                           applies exactly that saved configuration
--                           (default).
--   DISPLAY_MODE_FULL     - forces every dictionary/button/tool visible, in
--                           the user-configured dictionary order. Fixed
--                           preset, not editable.
--   DISPLAY_MODE_MINIMAL  - hides the entire footer action bar. Fixed
--                           preset, not editable.
--   DISPLAY_MODE_LANGUAGE - prioritizes translation dictionaries over
--                           definition ones, then monolingual definition
--                           dictionaries; hides Wikipedia and fulltext
--                           search. Fixed preset, not editable.
local SETTING_DISPLAY_MODE = "floatingdictionary_display_mode"
local DISPLAY_MODE_PERSONAL = "personal"
local DISPLAY_MODE_FULL = "full"
local DISPLAY_MODE_MINIMAL = "minimal"
local DISPLAY_MODE_LANGUAGE = "language"

-- Order here is also the order the modes are listed in the settings menu:
-- Personal (the only editable/custom profile) first, then the three fixed
-- presets.
local DISPLAY_MODES = {
	{ id = DISPLAY_MODE_PERSONAL, text = _("Personal") },
	{ id = DISPLAY_MODE_MINIMAL, text = _("Minimal") },
	{ id = DISPLAY_MODE_FULL, text = _("Full") },
	{ id = DISPLAY_MODE_LANGUAGE, text = _("Language learner") },
}

-- FastDict: whether instant (in-process) lookups are enabled. When on, the
-- patched ReaderDictionary:rawSdcv (installed by patchFastDict below) tries
-- to answer exact-search lookups itself before sdcv is ever spawned; any
-- fuzzy search, special query syntax, unsupported dictionary, or engine
-- error transparently falls through to the original sdcv path, so enabling
-- this can only ever speed lookups up, never break them.
local SETTING_FASTDICT_ENABLED = "floatingdictionary_fastdict_enabled"

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
-- only the capitalized first letter of the label by default, so they always
-- fit the narrow button width regardless of translation length (e.g.
-- "Highlight" -> "H") instead of being clipped mid-word. The user can
-- override this per-button with their own short text from "Buttons shown in
-- preview" -- see getActionButtonLabel/getActionIconSpec below; an empty or
-- reset field simply falls back to this same initial-letter behavior.
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
	center_on_screen = false, -- true to center the card both horizontally and
	                    -- vertically instead of anchoring to top/bottom (used
	                    -- by the word-review popup); takes priority over
	                    -- anchor_top, since the two are mutually exclusive
	                    -- positioning modes.
	card_height_ratio = nil, -- fraction of screen height for the card's max
	                         -- height, as chosen by the user in the KOReader
	                         -- settings menu; falls back to PANEL_MAX_HEIGHT_RATIO.
	border_thickness = nil, -- popup border thickness in pixels, as chosen by
	                         -- the user in the settings menu; falls back to
	                         -- POPUP_BORDER_THICKNESS_DEFAULT.
	border_color = nil, -- popup border color (Blitbuffer color), derived from
	                     -- the user's configured border darkness; falls back
	                     -- to POPUP_BORDER_DARKNESS_DEFAULT's color.
	breadcrumb_labels = nil, -- ordered list of strings for the cascade trail; nil/short = hidden
	breadcrumb_callback = nil, -- function(index) called when a non-last breadcrumb word is tapped
	lookup_word_callback = nil, -- function(text) called when the user holds/selects a word in the definition body
	custom_title = nil, -- string; when set, replaces the breadcrumb strip with a
	                    -- plain left-aligned title (used by the word-review
	                    -- popup instead of the cascade breadcrumb/navigation).
})

function FloatingDictionaryPopup:init()
	-- ScrollHtmlWidget/HtmlBoxWidget (built below via makeHtmlWidget) keeps
	-- its own reference to `dialog` and uses it internally on every
	-- swipe-to-change-dictionary and scroll/pan-a-long-definition gesture
	-- (to trigger its own redraw/dirty handling). The real, normal-lookup
	-- popup always supplies a live widget here (dialog = dict_self.dialog);
	-- the word-review popup, which has no real dict_self/lookup context
	-- behind it, was being built with dialog = nil, and those exact two
	-- gestures crashing the whole reader traced back to that nil reference.
	-- Falling back to the popup itself -- it's the actual top-level widget
	-- that ends up shown via UIManager:show(), so it's just as live and
	-- valid a reference as dict_self.dialog is for the normal popup -- fixes
	-- this at the source, for every construction site, current and future.
	self.dialog = self.dialog or self

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

	local height_ratio = self.card_height_ratio or PANEL_MAX_HEIGHT_RATIO
	local max_popup_height = math.floor(screen_height * height_ratio) - edge_margin

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
	local buttons_full_width = math.max(1, self.width - 2 * (self.border_thickness or POPUP_BORDER_THICKNESS_DEFAULT))
	local buttons = self:makeButtons(buttons_full_width)
	local buttons_height = self:getWidgetHeight(buttons, self.button_row_height or BUTTON_HEIGHT)

	-- Breadcrumb strip: only built (and only takes up space) when there's an
	-- actual cascade trail (2+ steps) to show. Sits glued to the top of the
	-- card, above the word/definition area, with its own thin separator line.
	--
	-- custom_title (used by the word-review popup) reuses this exact same
	-- slot -- same height accounting, same separator line below it -- but
	-- renders a plain left-aligned label instead of the tappable cascade
	-- trail, and is never combined with an actual breadcrumb (a review card
	-- never has cascade history of its own).
	local breadcrumb = not self.custom_title and self:makeBreadcrumb(content_width) or nil
	local title_widget = self.custom_title and TextWidget:new({
		text = self.custom_title,
		face = Font:getFace("cfont", BREADCRUMB_FONT_SIZE),
		bold = true,
	}) or nil
	local breadcrumb_rows = {}
	local breadcrumb_extra_height = 0
	if breadcrumb or title_widget then
		local top_widget = breadcrumb or title_widget
		local top_height = self:getWidgetHeight(top_widget, Screen:scaleBySize(BREADCRUMB_FONT_SIZE + 6))
		table.insert(breadcrumb_rows, HorizontalGroup:new({
			HorizontalSpan:new({ width = CONTENT_PADDING_LEFT }),
			top_widget,
			HorizontalSpan:new({ width = CONTENT_PADDING_RIGHT }),
		}))
		table.insert(breadcrumb_rows, VerticalSpan:new({ width = BREADCRUMB_GAP }))
		table.insert(breadcrumb_rows, LineWidget:new({
			background = Blitbuffer.COLOR_GRAY,
			dimen = Geom:new({ w = self.width - 2 * (self.border_thickness or POPUP_BORDER_THICKNESS_DEFAULT), h = BUTTON_ROW_SEPARATOR_WIDTH }),
		}))
		table.insert(breadcrumb_rows, VerticalSpan:new({ width = BREADCRUMB_BOTTOM_MARGIN }))
		breadcrumb_extra_height = top_height + BREADCRUMB_GAP + BUTTON_ROW_SEPARATOR_WIDTH + BREADCRUMB_BOTTOM_MARGIN
	end

	local border_thickness = self.border_thickness or POPUP_BORDER_THICKNESS_DEFAULT
	local border_color = self.border_color or Blitbuffer.Color8(math.floor((1 - POPUP_BORDER_DARKNESS_DEFAULT) * 255 + 0.5))

	local fixed_height = PANEL_PADDING_TOP + breadcrumb_extra_height + TEXT_BUTTON_GAP
		+ BUTTON_ROW_SEPARATOR_WIDTH + BUTTON_ROW_SEPARATOR_GAP + buttons_height
		+ PANEL_PADDING_BOTTOM + 2 * border_thickness
	local min_html_height = Screen:scaleBySize(40)
	local max_html_height = math.max(max_popup_height - fixed_height, min_html_height)

	-- Dynamic height: `max_html_height` (derived from the user's configured
	-- max-height setting, card_height_ratio) is now a ceiling, not a fixed
	-- size. We first build the html widget at that ceiling -- this is also
	-- the final widget used whenever we can't safely tell how tall the
	-- content actually is -- and then, when possible, measure the content's
	-- own natural height and shrink down to it so short
	-- definitions/translations/synonyms/error messages ("No hay
	-- coincidencias", etc.) don't leave a big empty gap under the text.
	-- Content taller than the ceiling is left exactly as before: clamped to
	-- max_html_height with the html widget's own scrolling (swipe/tap or the
	-- scroll bar), unchanged.
	self.htmlwidget = self:makeHtmlWidget(content_width, max_html_height, self.html_body)
	local html_height = max_html_height

	local natural_height = self:getHtmlContentHeight(self.htmlwidget)
		or self:estimateHtmlContentHeight(content_width, self.html_body)
	if natural_height and natural_height < max_html_height then
		html_height = math.max(min_html_height, math.ceil(natural_height) + Screen:scaleBySize(4))
		html_height = math.min(html_height, max_html_height)
		if html_height < max_html_height then
			-- Rebuild at the tighter height so the frame and the
			-- scrollable viewport actually match the shorter content,
			-- instead of just visually cropping a taller widget.
			self.htmlwidget = self:makeHtmlWidget(content_width, html_height, self.html_body)
		end
	end

	self.height = fixed_height + html_height

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
	table.insert(body_rows, LineWidget:new({
		background = Blitbuffer.COLOR_GRAY,
		dimen = Geom:new({ w = self.width - 2 * border_thickness, h = BUTTON_ROW_SEPARATOR_WIDTH }),
	}))
	table.insert(body_rows, VerticalSpan:new({ width = BUTTON_ROW_SEPARATOR_GAP }))
	table.insert(body_rows, buttons)
	table.insert(body_rows, VerticalSpan:new({ width = PANEL_PADDING_BOTTOM }))

	self.container = FrameContainer:new({
		background = Blitbuffer.COLOR_WHITE,
		bordersize = border_thickness,
		color = border_color,
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

	if self.center_on_screen then
		-- Word-review popup: centered exactly in the middle of the screen,
		-- both horizontally and vertically, instead of anchored to an edge.
		self[1] = CenterContainer:new({
			dimen = Screen:getSize(),
			card_row,
		})
	elseif self.anchor_top then
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
	local separator_width = BUTTON_ROW_SEPARATOR_WIDTH
	local button_specs = {}

	-- Dictionary-navigation (prev/next) and external-plugin buttons now
	-- arrive as ordinary entries inside self.actions, in whatever order and
	-- visibility the user picked from the KOReader settings menu, so they
	-- aren't hardcoded here anymore. The settings gear button has been
	-- removed from this popup; all configuration is managed exclusively
	-- from the KOReader menu.
	for index, action in ipairs(self.actions or {}) do
		table.insert(button_specs, {
			spec = action.spec or { icon = ICON_SEARCH },
			callback = function()
				return self:onActionButton(index)
			end,
		})
	end

	local button_count = #button_specs
	if button_count == 0 then
		-- No footer actions to show at all (e.g. Minimalist display mode):
		-- render an empty, zero-height row instead of dividing by zero below.
		return HorizontalGroup:new({})
	end
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
			background = Blitbuffer.COLOR_GRAY,
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

-- Attempts to read the natural (unclamped) rendered height of an already
-- constructed ScrollHtmlWidget -- i.e. how tall its html content actually is,
-- regardless of the `height` it was given to fit inside. This is what lets
-- the popup shrink to short content (a brief definition, "No hay
-- coincidencias", a one-line error, ...) instead of always reserving the
-- user-configured maximum height.
--
-- KOReader's ScrollHtmlWidget/HtmlBoxWidget (frontend/ui/widget/htmlboxwidget.lua)
-- exposes exactly one public API for this: `getSinglePageHeight()`. It lays
-- out the html at the widget's current width/height, and returns the actual
-- used (ink) height of the content *only* when everything fits on a single
-- MuPDF "page" inside the box we gave it (i.e. page_count == 1); it returns
-- nil when the content needs more than one page, meaning it's taller than
-- the box we built it with and would need to scroll. That nil case is
-- exactly the signal we want too: "don't shrink, this content needs the
-- full ceiling (or more, via scrolling)".
--
-- (Earlier versions of this function tried to read internal fields such as
-- `_h_content`, `content_height`, or `htmlbox_widget:getSize()`. None of
-- those exist on ScrollHtmlWidget/HtmlBoxWidget, so that code always fell
-- through to nil and the popup always fell back to the much rougher
-- plain-text estimateHtmlContentHeight() below -- which is the bug this
-- fixes.)
--
-- Every access is still pcall-guarded and falls back to returning nil
-- (meaning "unknown, use the estimator or the ceiling instead") on any
-- error, so a KOReader version where this internal differs simply keeps the
-- previous fixed-max-height behaviour instead of breaking.
function FloatingDictionaryPopup:getHtmlContentHeight(widget)
	if not widget or not widget.getSinglePageHeight then
		return nil
	end

	local ok, h = pcall(function()
		return widget:getSinglePageHeight()
	end)

	if ok and type(h) == "number" and h > 0 then
		return h
	end

	return nil
end

-- Rough but entirely self-contained estimate of how tall `html_body` will
-- render at `content_width` with this plugin's own font size, expressed in
-- the same scaled-pixel units as `self.height`.
--
-- Unlike `getHtmlContentHeight` above, this never depends on any
-- KOReader-internal widget field (those vary across versions/devices, and
-- when absent silently leave the popup always at the full max height). It
-- only strips the html down to plain text and does simple line-wrapping
-- arithmetic using metrics that mirror the CSS this plugin itself renders
-- with (body { line-height: 1.3 }, no extra body/paragraph padding or
-- margin -- see getBaseCss()). It deliberately errs toward a slightly
-- *taller* estimate rather than a shorter one: an estimate that's a bit too
-- tall just leaves a little unused space, while one that's too short would
-- clip the last line of text.
function FloatingDictionaryPopup:estimateHtmlContentHeight(content_width, html_body)
	if not html_body or html_body == "" or not content_width or content_width <= 0 then
		return nil
	end

	local text = html_body

	-- Block-level tags force a line break; turn each into "\n" *before*
	-- stripping tags, so paragraph/list-item/heading boundaries aren't lost.
	text = text:gsub("<%s*br%s*/?%s*>", "\n")
	text = text:gsub("<%s*/?%s*p[^>]*>", "\n")
	text = text:gsub("<%s*/?%s*div[^>]*>", "\n")
	text = text:gsub("<%s*/?%s*li[^>]*>", "\n")
	text = text:gsub("<%s*/?%s*h[1-6][^>]*>", "\n")
	-- Strip every remaining tag (inline formatting, spans, links, etc.).
	text = text:gsub("<[^>]+>", "")
	-- Decode the handful of entities that actually show up in this plugin's
	-- own generated markup.
	text = text:gsub("&nbsp;", " ")
	text = text:gsub("&amp;", "&")
	text = text:gsub("&lt;", "<")
	text = text:gsub("&gt;", ">")
	text = text:gsub("&quot;", '"')
	text = text:gsub("&#39;", "'")
	-- Trim leading/trailing blank lines so a single paragraph/list item at
	-- the very start or end of the markup doesn't add a spurious extra
	-- blank line to the count.
	text = text:gsub("^%s*\n+", "")
	text = text:gsub("\n+%s*$", "")

	local font_size = self.doc_font_size or Screen:scaleBySize(18)
	-- Average glyph advance width for a proportional latin font, as a
	-- fraction of the font size. Deliberately generous (assumes slightly
	-- *wider* characters than typical) so the estimated line count -- and
	-- therefore height -- errs tall rather than short.
	local avg_char_width = font_size * 0.62
	local chars_per_line = math.max(1, math.floor(content_width / avg_char_width))
	local line_height = font_size * 1.3 -- matches this plugin's own body { line-height: 1.3 }

	local total_lines = 0
	local saw_content = false
	local prev_blank = false
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
		if trimmed == "" then
			-- Collapse runs of consecutive blank lines down to a single
			-- blank line's worth of height (normal whitespace-collapsing
			-- behaviour), and ignore leading blank lines entirely.
			if saw_content and not prev_blank then
				total_lines = total_lines + 1
				prev_blank = true
			end
		else
			local wrapped = math.max(1, math.ceil(#trimmed / chars_per_line))
			total_lines = total_lines + wrapped
			saw_content = true
			prev_blank = false
		end
	end

	if not saw_content or total_lines <= 0 then
		return nil
	end

	-- Small safety buffer for rounding/descenders/inline images.
	return math.ceil(total_lines * line_height) + Screen:scaleBySize(6)
end

function FloatingDictionaryPopup:makeHtmlWidget(content_width, height, html_body)
	return ScrollHtmlWidget:new({
		html_body = html_body or self.html_body,
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
	if self.container and self.container.dimen and ges and ges.pos
		and ges.pos:notIntersectWith(self.container.dimen) then
		-- Hold started outside the card itself (e.g. on the book text behind
		-- it): let it fall through to the reader instead of being swallowed
		-- here, so the user can select a brand new word in the book while
		-- this popup is open. showPreview/renderCascadeFrame already treat
		-- any such fresh (non-cascade) lookup as the start of a new trail,
		-- closing this whole cascade and starting the breadcrumb over.
		return false
	end

	local box = self.htmlwidget and self.htmlwidget.htmlbox_widget
	if not box or not box.onHoldStartText then
		return false
	end
	return box:onHoldStartText(_arg, ges)
end

function FloatingDictionaryPopup:onHoldPanText(_arg, ges)
	if self.container and self.container.dimen and ges and ges.pos
		and ges.pos:notIntersectWith(self.container.dimen) then
		return false
	end

	local box = self.htmlwidget and self.htmlwidget.htmlbox_widget
	if not box or not box.onHoldPanText then
		return false
	end
	return box:onHoldPanText(_arg, ges)
end

function FloatingDictionaryPopup:onHoldReleaseText(_arg, ges)
	if self.container and self.container.dimen and ges and ges.pos
		and ges.pos:notIntersectWith(self.container.dimen) then
		return false
	end

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
	elseif self.center_on_screen and (ges.direction == "north" or ges.direction == "south") then
		-- Centered card: either vertical swipe direction dismisses it, since
		-- there's no bottom/top edge it's anchored to.
		return self:onClosePreview()
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
	border_thickness = nil, -- popup border thickness in pixels, as chosen by
	                         -- the user in the settings menu; falls back to
	                         -- POPUP_BORDER_THICKNESS_DEFAULT.
	border_color = nil, -- popup border color (Blitbuffer color), derived from
	                     -- the user's configured border darkness; falls back
	                     -- to POPUP_BORDER_DARKNESS_DEFAULT's color.
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

	local border_thickness = self.border_thickness or POPUP_BORDER_THICKNESS_DEFAULT
	local border_color = self.border_color or Blitbuffer.Color8(math.floor((1 - POPUP_BORDER_DARKNESS_DEFAULT) * 255 + 0.5))

	self.card = FrameContainer:new({
		background = Blitbuffer.COLOR_WHITE,
		bordersize = border_thickness,
		color = border_color,
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
	self.close_review_popup = nil
	self._suspended = false
	self.pending_word_review_task = nil

	-- Cascade state: ordered list of frames { word, results, boxes, link,
	-- dict_close_callback } representing the trail of lookups in the current
	-- session, plus the dict_self/anchor decided by the *root* lookup (reused
	-- for every cascaded step so the card doesn't jump top/bottom mid-trail).
	self.cascade_history = {}
	self.cascade_anchor_top = false
	self.cascade_dict_self = nil
	self.pending_cascade_step = false -- set true right before triggering a lookup from a held/selected word inside a popup, so showPreview treats it as a cascade push instead of a fresh root lookup

	-- Word review: guards against onReaderReady firing more than once for
	-- the same book-open (KOReader can, in some flows, re-fire ready events,
	-- e.g. after certain settings changes). Only onReaderReady checks/sets
	-- this -- onResume deliberately ignores it, since the requested behavior
	-- there is "show the popup every single time the device wakes up",
	-- however many times that happens during one reading session.
	self.word_review_shown_for_this_book = false

	if self.ui and self.ui.menu then
		self.ui.menu:registerToMainMenu(self)
	end

	self:patchDictionary()
	self:patchFastDict()
	self:patchHighlightMenu()
end

-- Fired once by KOReader after a document has finished loading and the
-- reader UI is fully ready. This -- not onShowingReader or page-turn events
-- -- is the single correct hook for "just opened this book": it fires
-- exactly once per open (including re-opening a book that was just closed),
-- and never fires again on ordinary page turns or while reading, which is
-- exactly the behavior requested for the review popup.
function FloatingDictionary:onReaderReady()
	if self.word_review_shown_for_this_book then
		return
	end
	self.word_review_shown_for_this_book = true
	self:scheduleWordReview(false)
end

-- Fired by KOReader every time the device wakes up from suspend (sleep),
-- whether or not a book was ever closed in between -- this is the correct,
-- documented hook for "device went to sleep, then woke back up" (confirmed
-- against KOReader's own AutoSuspend/AutoWarmth plugins, which use this same
-- event for their own onResume housekeeping). Unlike onReaderReady, this is
-- deliberately NOT gated by word_review_shown_for_this_book: the requested
-- behavior is one popup per wake-up, every single time the device resumes
-- (even if it was asleep for only a few seconds), not just once per book
-- session.
--
-- Scheduled with a short scheduleIn delay rather than nextTick/immediately:
-- right after a resume, KOReader is still closing the screensaver widget,
-- repainting the screen, and re-enabling input handling (all logged
-- separately, slightly after the Resume event itself fires) -- showing the
-- popup immediately races that in-progress teardown and can result in it
-- being covered or its first paint discarded, which is why it previously
-- appeared not to show up at all. A short delay lets that settle first.
function FloatingDictionary:onResume()
	self._suspended = false
	self:scheduleWordReview(true)
end

-- Fired by KOReader right before/when the device goes to sleep (screen off,
-- suspend, or lock). Without this, any floating dictionary popup(s) left open
-- at suspend time stay in UIManager's window stack: the screen simply turns
-- back on later with them still there. Repeating the screen-off/screen-on
-- cycle without ever dismissing a popup in between would then let a new
-- lookup stack a fresh popup on top of the still-open old one(s) each time,
-- producing the duplicated/overlapping popups described in the bug report.
--
-- popCard() (used elsewhere for a normal tap-outside/swipe/Back dismissal)
-- closes the *entire* cascade stack in one call, however many cards are
-- currently open, so this is robust regardless of how many popups have
-- accumulated or how many suspend/resume cycles have happened. It's wrapped
-- in pcall so a failure here (e.g. nothing open, or a widget already mid
-- teardown) can never block or break the suspend process itself.
function FloatingDictionary:onSuspend()
	self._suspended = true

	-- Cancel any word-review popup still waiting on its 1s post-resume delay
	-- (scheduleWordReview/onResume). Without this, a quick screen-off ->
	-- screen-on -> screen-off again inside that window would let the
	-- scheduled task fire *after* this suspend, popping up a brand new
	-- review card while the screen is off -- which then survives straight
	-- through to the next wake, exactly like the bug being fixed here.
	if self.pending_word_review_task then
		pcall(function()
			UIManager:unschedule(self.pending_word_review_task)
		end)
		self.pending_word_review_task = nil
	end

	if self.popup_stack and #self.popup_stack > 0 then
		pcall(function()
			self:popCard()
		end)
	end
	-- The "Word to review" popup (shown by WordReview:maybeShowReview via
	-- showReviewPopup) is deliberately its own self-contained card, kept
	-- outside popup_stack/cascade_history, so popCard() above never touches
	-- it. Close it separately here for the same reason: otherwise it would
	-- survive a screen-off/screen-on cycle exactly like the bug being fixed,
	-- and could pile up alongside/underneath a new one shown on the next wake.
	if self.close_review_popup then
		pcall(self.close_review_popup)
	end
end

-- Shared by onReaderReady and onResume. immediate_call decides how long to
-- wait before actually looking up and showing the review popup:
--   * onReaderReady (book just opened): the reader's own initial page has
--     already painted by the time this fires, so a same-tick nextTick is
--     enough to avoid racing that one paint.
--   * onResume (device just woke up): several more KOReader-internal steps
--     (screensaver close, repaint, input handling restore) are still
--     in-flight right as Resume fires, so a slightly longer, explicit delay
--     is used instead to reliably land after all of that has settled.
function FloatingDictionary:scheduleWordReview(is_resume)
	local trigger = is_resume and "resume" or "open"
	local function doShow()
		self.pending_word_review_task = nil
		-- If the device suspended again while this was still waiting to
		-- fire (e.g. screen turned off, briefly on, then off again inside
		-- the 1s delay below), don't show a brand new popup into a screen
		-- that's already off again -- it would otherwise leak straight
		-- through into the next wake-up exactly like the bug being fixed.
		if self._suspended then
			return
		end
		local ok, err = pcall(function()
			WordReview:maybeShowReview(self, trigger)
		end)
		if not ok then
			logger.warn("FloatingDictionary: word review failed:", err)
		end
	end

	if is_resume then
		self.pending_word_review_task = doShow
		UIManager:scheduleIn(1, doShow)
	else
		UIManager:nextTick(doShow)
	end
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
				text_func = function()
					local percent = math.floor(self:getCardHeightRatio() * 100 + 0.5)
					return T(_("Card height: %1 % of screen"), percent)
				end,
				keep_menu_open = true,
				callback = function(touchmenu_instance)
					self:showCardHeightDialog(touchmenu_instance)
				end,
			},
			{
				text_func = function()
					return T(_("Popup border thickness: %1"), self:getPopupBorderThickness())
				end,
				keep_menu_open = true,
				callback = function(touchmenu_instance)
					self:showPopupBorderThicknessDialog(touchmenu_instance)
				end,
			},
			{
				text_func = function()
					local percent = math.floor(self:getPopupBorderDarkness() * 100 + 0.5)
					return T(_("Popup border darkness: %1 %"), percent)
				end,
				keep_menu_open = true,
				callback = function(touchmenu_instance)
					self:showPopupBorderDarknessDialog(touchmenu_instance)
				end,
			},
			{
				text_func = function()
					for _idx, display_mode in ipairs(DISPLAY_MODES) do
						if display_mode.id == self:getDisplayMode() then
							return T(_("Display mode: %1"), display_mode.text)
						end
					end
					return _("Display mode")
				end,
				sub_item_table_func = function()
					return self:genDisplayModeMenu()
				end,
				separator = true,
			},
			{
				text = _("Buttons shown in preview"),
				sub_item_table_func = function()
					return self:genVisibleActionsMenu()
				end,
			},
			{
				text = _("Dictionary order"),
				sub_item_table_func = function()
					return self:genDictionaryOrderMenu()
				end,
			},
			{
				text = _("Word Review"),
				sub_item_table_func = function()
					return WordReview:genMenu()
				end,
			},
			{
				-- Absorbs KOReader's own "Highlights" menu (style, color,
				-- gray opacity, line height, note marker, "apply to all",
				-- and the PDF write-in toggle) so it lives inside Floating
				-- Dictionary instead of appearing as its own top-level menu.
				-- native_highlight_sub_items (captured below, right after
				-- this table literal) holds the actual sub_item_table that
				-- ReaderHighlight:addToMainMenu() built, so this still works
				-- correctly however the value in menu_items is disposed of
				-- afterwards.
				text = _("Highlight styles"),
				sub_item_table_func = function()
					return self:genMergedHighlightStylesMenu()
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
			},
			{
				text = _("Enable card transition animations"),
				checked_func = function()
					return self:areAnimationsEnabled()
				end,
				callback = function()
					self:setAnimationsEnabled(not self:areAnimationsEnabled())
				end,
				separator = true,
			},
			{
				text_func = function()
					if self:isFastDictEnabled() then
						return _("Fast lookups (FastDict): on")
					end
					return _("Fast lookups (FastDict): off")
				end,
				sub_item_table_func = function()
					return self:genFastDictMenu()
				end,
			},
		},
	}
end

function FloatingDictionary:areAnimationsEnabled()
	return G_reader_settings:nilOrTrue(SETTING_ANIMATIONS_ENABLED)
end

function FloatingDictionary:setAnimationsEnabled(enabled)
	G_reader_settings:saveSetting(SETTING_ANIMATIONS_ENABLED, enabled and true or false)
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

-- Card height, as a fraction of the screen height. Persisted so it's
-- remembered across lookups and app restarts. Lets the user fit the card to
-- small screens (e.g. 6" readers) or large ones (10"+ tablets).
function FloatingDictionary:getCardHeightRatio()
	local saved = G_reader_settings:readSetting(SETTING_CARD_HEIGHT_RATIO)
	if type(saved) ~= "number" then
		return PANEL_MAX_HEIGHT_RATIO
	end
	return math.max(CARD_HEIGHT_RATIO_MIN, math.min(CARD_HEIGHT_RATIO_MAX, saved))
end

function FloatingDictionary:setCardHeightRatio(ratio)
	ratio = math.max(CARD_HEIGHT_RATIO_MIN, math.min(CARD_HEIGHT_RATIO_MAX, ratio or PANEL_MAX_HEIGHT_RATIO))
	G_reader_settings:saveSetting(SETTING_CARD_HEIGHT_RATIO, ratio)
	return ratio
end

-- Popup border thickness (pixels) and darkness (0.0-1.0), both persisted so
-- they're remembered across lookups and app restarts. Applied to every
-- dictionary popup card (see getPopupBorderColor below for the darkness ->
-- color conversion).
function FloatingDictionary:getPopupBorderThickness()
	local saved = G_reader_settings:readSetting(SETTING_POPUP_BORDER_THICKNESS)
	if type(saved) ~= "number" then
		return POPUP_BORDER_THICKNESS_DEFAULT
	end
	return math.floor(math.max(POPUP_BORDER_THICKNESS_MIN, math.min(POPUP_BORDER_THICKNESS_MAX, saved)) + 0.5)
end

function FloatingDictionary:setPopupBorderThickness(thickness)
	thickness = math.floor(math.max(POPUP_BORDER_THICKNESS_MIN, math.min(POPUP_BORDER_THICKNESS_MAX, thickness or POPUP_BORDER_THICKNESS_DEFAULT)) + 0.5)
	G_reader_settings:saveSetting(SETTING_POPUP_BORDER_THICKNESS, thickness)
	return thickness
end

function FloatingDictionary:getPopupBorderDarkness()
	local saved = G_reader_settings:readSetting(SETTING_POPUP_BORDER_DARKNESS)
	if type(saved) ~= "number" then
		return POPUP_BORDER_DARKNESS_DEFAULT
	end
	return math.max(POPUP_BORDER_DARKNESS_MIN, math.min(POPUP_BORDER_DARKNESS_MAX, saved))
end

function FloatingDictionary:setPopupBorderDarkness(darkness)
	darkness = math.max(POPUP_BORDER_DARKNESS_MIN, math.min(POPUP_BORDER_DARKNESS_MAX, darkness or POPUP_BORDER_DARKNESS_DEFAULT))
	G_reader_settings:saveSetting(SETTING_POPUP_BORDER_DARKNESS, darkness)
	return darkness
end

-- Converts the persisted 0.0-1.0 darkness into the grayscale Blitbuffer
-- color used by the popup FrameContainers: 1.0 (fully dark) maps to black
-- (0), 0.0 (fully light) maps to white (255), matching how "Gray highlight
-- opacity" maps its own 0.0-1.0 setting to a paint intensity.
function FloatingDictionary:getPopupBorderColor()
	local darkness = self:getPopupBorderDarkness()
	local level = math.floor((1 - darkness) * 255 + 0.5)
	level = math.max(0, math.min(255, level))
	return Blitbuffer.Color8(level)
end

-- Display mode (Personal / Minimal / Full / Language learner) -------------
-- A single persisted, exclusive choice -- never independent toggles. Picking
-- one mode always implies the others are off, since they all share this one
-- setting slot. Personal is the only mode backed by the individually
-- editable settings above; Minimal/Full/Language learner are fixed presets
-- that always apply the same overrides regardless of those settings.
function FloatingDictionary:getDisplayMode()
	local saved = G_reader_settings:readSetting(SETTING_DISPLAY_MODE)
	for _idx, mode in ipairs(DISPLAY_MODES) do
		if mode.id == saved then
			return saved
		end
	end
	return DISPLAY_MODE_PERSONAL
end

function FloatingDictionary:setDisplayMode(mode_id)
	local valid = false
	for _idx, mode in ipairs(DISPLAY_MODES) do
		if mode.id == mode_id then
			valid = true
			break
		end
	end
	if not valid then
		mode_id = DISPLAY_MODE_PERSONAL
	end
	G_reader_settings:saveSetting(SETTING_DISPLAY_MODE, mode_id)
end

-- Radio-button submenu listing the four mutually exclusive display modes.
-- Selecting one immediately persists it (replacing whatever was selected
-- before) and every render path re-reads getDisplayMode() live, so the
-- effect is applied on the very next popup shown -- no restart needed.
function FloatingDictionary:genDisplayModeMenu()
	local items = {}
	for _idx, mode in ipairs(DISPLAY_MODES) do
		table.insert(items, {
			text = mode.text,
			radio = true,
			checked_func = function()
				return self:getDisplayMode() == mode.id
			end,
			callback = function()
				self:setDisplayMode(mode.id)
			end,
		})
	end
	return items
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

-- Fancy highlight styles menu ----------------------------------------------
-- Lists the extra highlight/underline styles this plugin registers and lets
-- the user adjust each one's line thickness (except for the styles in
-- THICKNESS_MENU_EXCLUDED, which have no user-facing thickness control).
-- This is purely a settings UI on top of the LINE_THICKNESS table defined
-- earlier in this file (used by the embedded fancy-highlight drawer); it
-- does not add, remove, or rename any style, and does not touch how styles
-- are picked when creating a highlight -- that picker is still KOReader's
-- own, listing these styles alongside the stock Shade/Invert/Underline ones
-- exactly as before.
local THICKNESS_MENU_EXCLUDED = {
	solid_medium = true,
	grid_thick = true,
	outline_thick = true,
	crosshatch = true,
	thick_underline = true,
	dash_underline = true,
	diagonal_thick = true,
	diagonal_thin = true,
	dotted_fill = true,
	dotted_underline = true,
	fine_underline = true,
	grid_thin = true,
	plain_underline = true,
	solid_light = true,
	wavy_fill = true,
	wavy_underline = true,
}

function FloatingDictionary:genFancyHighlightStylesMenu()
	local items = {}
	for _idx, style in ipairs(FANCY_HIGHLIGHT_STYLE_LIST) do
		local style_name, style_id = style[1], style[2]
		if not THICKNESS_MENU_EXCLUDED[style_id] then
			table.insert(items, {
				text_func = function()
					return T(_("%1 (thickness: %2)"), style_name, LINE_THICKNESS[style_id])
				end,
				keep_menu_open = true,
				callback = function(touchmenu_instance)
					self:showFancyHighlightThicknessDialog(style_id, style_name, touchmenu_instance)
				end,
			})
		end
	end
	return items
end

-- Merged "Highlight styles" menu ---------------------------------------------
-- What actually appears under Floating Dictionary -> Highlight styles.
-- Combines two things, in this order:
--   1. Every item from KOReader's own native "Highlights" menu (captured by
--      patchHighlightMenu -- style radio buttons with the ★ default marker,
--      color, gray opacity, line height, note marker, "apply to all", PDF
--      write-in toggle), completely unchanged: same text, same
--      checked/radio state, same callbacks (now trimmed: color, gray
--      opacity, line height and note marker removed; style names shown as
--      plain text; "Apply to all" moved to the front). This is the menu
--      that used to show up on its own at the top level; it now only shows
--      up here.
--   2. This plugin's own line-thickness controls for the fancy styles it
--      adds to that same style picker, via genFancyHighlightStylesMenu.
-- If the native items haven't been captured yet (e.g. this submenu is
-- opened before any menu has triggered ReaderHighlight:addToMainMenu at
-- least once), only the fancy-style thickness controls are shown; opening
-- the settings menu again after that will include the native items too.
function FloatingDictionary:genMergedHighlightStylesMenu()
	local items = {}

	if self.native_highlight_sub_items then
		for _idx, item in ipairs(self.native_highlight_sub_items) do
			table.insert(items, item)
		end
		if #items > 0 then
			items[#items].separator = true
		end
	end

	local fancy_items = self:genFancyHighlightStylesMenu()
	for _idx, item in ipairs(fancy_items) do
		table.insert(items, item)
	end

	return items
end
-- picking the line thickness, in pixels, of a single fancy highlight style.
function FloatingDictionary:showFancyHighlightThicknessDialog(style_id, style_name, touchmenu_instance)
	local min_thickness, max_thickness = 1, 20
	local current_thickness = LINE_THICKNESS[style_id]

	local dialog
	dialog = InputDialog:new{
		title = T(_("%1 thickness"), style_name),
		description = T(
			_("Line thickness in pixels (%1-%2)."),
			min_thickness, max_thickness
		),
		input = tostring(current_thickness),
		input_type = "number",
		input_hint = T(_("%1 - %2"), min_thickness, max_thickness),
		buttons = {
			{
				{
					text = _("Cancel"),
					id = "close",
					callback = function()
						UIManager:close(dialog)
					end,
				},
				{
					text = _("Save"),
					is_enter_default = true,
					callback = function()
						local input_text = dialog:getInputText()
						local value = input_text and tonumber(input_text)
						if not value then
							UIManager:show(Notification:new{
								text = _("Please enter a valid number."),
							})
							return
						end
						local clamped = math.floor(math.max(min_thickness, math.min(max_thickness, value)) + 0.5)
						LINE_THICKNESS[style_id] = clamped
						saveFancyHighlightThickness()
						UIManager:close(dialog)
						if touchmenu_instance then
							touchmenu_instance:updateItems()
						end
					end,
				},
			},
		},
	}
	UIManager:show(dialog)
	dialog:onShowKeyboard()
end

-- Card height dialog -------------------------------------------------------
-- Small numeric input box (the same kind of widget KOReader itself uses for
-- things like font size or margins) where the user types any percentage of
-- the screen height they want the card to use, instead of picking from a
-- fixed list of presets. Lets the user fit the card to small screens (e.g.
-- 6" readers) or large ones (10"+ tablets) with a value of their choosing.
function FloatingDictionary:showCardHeightDialog(touchmenu_instance)
	local min_percent = math.floor(CARD_HEIGHT_RATIO_MIN * 100 + 0.5)
	local max_percent = math.floor(CARD_HEIGHT_RATIO_MAX * 100 + 0.5)
	local current_percent = math.floor(self:getCardHeightRatio() * 100 + 0.5)

	-- "dialog" is declared as its own local first, then assigned to the
	-- InputDialog instance. The button callbacks below reference "dialog"
	-- to close it -- they must close over *this* local, not over a global.
	-- Writing `local dialog = InputDialog:new{ ... uses dialog ... }` as a
	-- single statement is the classic bug here: the right-hand side is
	-- evaluated before the new local "dialog" comes into scope, so the
	-- callbacks would instead capture an unrelated (nil) global. The dialog
	-- would still open normally, but pressing any button would then call
	-- UIManager:close(nil), which errors inside the UI event loop and
	-- crashes KOReader back to the firmware -- exactly the symptom this is
	-- fixing.
	local dialog
	dialog = InputDialog:new{
		title = _("Card height"),
		description = T(
			_("Percentage of the screen height used by the dictionary card (%1-%2)."),
			min_percent, max_percent
		),
		input = tostring(current_percent),
		input_type = "number",
		input_hint = T(_("%1 - %2"), min_percent, max_percent),
		buttons = {
			{
				{
					text = _("Cancel"),
					id = "close",
					callback = function()
						UIManager:close(dialog)
					end,
				},
				{
					text = _("Save"),
					is_enter_default = true,
					callback = function()
						local input_text = dialog:getInputText()
						local value = input_text and tonumber(input_text)
						if not value then
							UIManager:show(Notification:new{
								text = _("Please enter a valid number."),
							})
							return
						end
						local clamped_percent = math.max(min_percent, math.min(max_percent, value))
						self:setCardHeightRatio(clamped_percent / 100)
						UIManager:close(dialog)
						if touchmenu_instance then
							touchmenu_instance:updateItems()
						end
					end,
				},
			},
		},
	}
	UIManager:show(dialog)
	dialog:onShowKeyboard()
end

-- Popup border dialogs -------------------------------------------------------
-- Same SpinWidget-based picker (increment/decrement + confirm) KOReader's
-- own "Gray highlight opacity" setting uses, reused here for consistency
-- with the rest of the KOReader UI. Applies to every dictionary popup card
-- (see getPopupBorderColor/getPopupBorderThickness, read fresh each time a
-- popup is built, so the new value takes effect immediately on the very
-- next popup shown -- no restart needed).
function FloatingDictionary:showPopupBorderThicknessDialog(touchmenu_instance)
	UIManager:show(SpinWidget:new{
		title_text = _("Popup border thickness"),
		info_text = T(
			_("Border thickness, in pixels, for every dictionary popup (%1-%2)."),
			POPUP_BORDER_THICKNESS_MIN, POPUP_BORDER_THICKNESS_MAX
		),
		value = self:getPopupBorderThickness(),
		value_min = POPUP_BORDER_THICKNESS_MIN,
		value_max = POPUP_BORDER_THICKNESS_MAX,
		value_step = 1,
		value_hold_step = 2,
		ok_text = _("Set"),
		callback = function(spin)
			self:setPopupBorderThickness(spin.value)
			if touchmenu_instance then
				touchmenu_instance:updateItems()
			end
		end,
	})
end

function FloatingDictionary:showPopupBorderDarknessDialog(touchmenu_instance)
	UIManager:show(SpinWidget:new{
		title_text = _("Popup border darkness"),
		info_text = _("Border darkness for every dictionary popup, from 0 (white/invisible) to 1 (solid black)."),
		value = self:getPopupBorderDarkness(),
		value_min = POPUP_BORDER_DARKNESS_MIN,
		value_max = POPUP_BORDER_DARKNESS_MAX,
		value_step = POPUP_BORDER_DARKNESS_STEP,
		value_hold_step = POPUP_BORDER_DARKNESS_STEP * 2,
		precision = "%.1f",
		ok_text = _("Set"),
		callback = function(spin)
			self:setPopupBorderDarkness(spin.value)
			if touchmenu_instance then
				touchmenu_instance:updateItems()
			end
		end,
	})
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

-- Custom footer button labels ------------------------------------------------
-- Lets the user replace the single-letter fallback text of a footer button
-- (e.g. "H" for Highlight) with their own short text of choice. Purely
-- cosmetic: it only changes what getActionIconSpec renders as the button's
-- text-fallback label, never the action itself, its icon (when a plugin
-- icon file is present, that still wins over any text label, exactly as
-- before), its visibility, or its order. Stored as {action_id -> string},
-- trimmed on save; an empty/whitespace-only value is treated as "not set"
-- so the button reverts to the default initial letter, matching the
-- "leave blank or reset to restore default" behavior asked for.
function FloatingDictionary:getActionCustomLabelsSetting()
	local saved = G_reader_settings:readSetting(SETTING_ACTION_CUSTOM_LABELS)
	if type(saved) ~= "table" then
		saved = {}
	end
	return saved
end

-- Returns the user's custom label for action_id, or nil if none is set (in
-- which case callers should fall back to the default initial letter).
function FloatingDictionary:getActionCustomLabel(action_id)
	local saved = self:getActionCustomLabelsSetting()
	local label = saved[action_id]
	if type(label) ~= "string" then
		return nil
	end
	label = trim(label)
	if label == "" then
		return nil
	end
	return label
end

-- Saves (or clears, when new_label is empty/nil) the custom label for
-- action_id.
function FloatingDictionary:setActionCustomLabel(action_id, new_label)
	local saved = self:getActionCustomLabelsSetting()
	local trimmed = trim(new_label)
	if trimmed == "" then
		saved[action_id] = nil
	else
		saved[action_id] = trimmed
	end
	G_reader_settings:saveSetting(SETTING_ACTION_CUSTOM_LABELS, saved)
end

-- The text actually shown on a text-fallback footer button: the user's
-- custom label when set, otherwise the default single-letter initial.
function FloatingDictionary:getActionButtonLabel(action)
	if not action then
		return "?"
	end
	local custom = self:getActionCustomLabel(action.id)
	if custom then
		return custom
	end
	return getButtonInitial(action.short_label or action.label)
end

-- Custom footer button SVG icons ---------------------------------------------
-- Lets the user pick a .svg file from floatingdictionary-images/ (a folder
-- living directly inside the plugin's own install directory, alongside
-- main.lua) to use as a button's icon instead of a text label. Selecting an
-- icon does not erase any custom text the user previously typed for that
-- button (see showActionCustomLabelDialog) -- it simply takes priority over
-- it while set (getActionIconSpec below), exactly the same relationship the
-- plugin's own bundled icons/ already had with text labels. Clearing the
-- icon (via "None (use text)") reveals that text label again unchanged.
function FloatingDictionary:getCustomIconsDir()
	if not self.path or self.path == "" then
		return nil
	end
	return self.path .. "/" .. CUSTOM_ICONS_DIR_NAME
end

-- Scans floatingdictionary-images/ for .svg files and returns their plain
-- filenames (no path, no extension needed by the user), sorted
-- alphabetically, so the picker menu below never requires typing a
-- filename or path by hand. Missing/unreadable directory simply yields an
-- empty list rather than erroring.
function FloatingDictionary:getAvailableCustomIcons()
	local dir = self:getCustomIconsDir()
	local names = {}
	if not dir then
		return names
	end

	local ok, iter, dir_obj = pcall(lfs.dir, dir)
	if not ok then
		return names
	end

	for entry in iter, dir_obj do
		if entry ~= "." and entry ~= ".." then
			local fullpath = dir .. "/" .. entry
			local attr = lfs.attributes(fullpath)
			if attr and attr.mode == "file" and entry:lower():match("%.svg$") then
				table.insert(names, entry)
			end
		end
	end

	table.sort(names, function(a, b)
		return a:lower() < b:lower()
	end)
	return names
end

function FloatingDictionary:getActionCustomIconsSetting()
	local saved = G_reader_settings:readSetting(SETTING_ACTION_CUSTOM_ICONS)
	if type(saved) ~= "table" then
		saved = {}
	end
	return saved
end

-- Returns the full path to action_id's chosen icon file, or nil if none is
-- set *or* the previously chosen file no longer exists on disk -- the
-- caller (getActionIconSpec) treats both cases identically, which is what
-- gives the "deleted file -> automatically falls back" behavior asked for.
-- Deliberately does not delete the now-dangling setting entry here: if the
-- file reappears later (e.g. restored from a backup), the plugin picks it
-- back up automatically with no extra step from the user.
function FloatingDictionary:getActionCustomIcon(action_id)
	local saved = self:getActionCustomIconsSetting()
	local filename = saved[action_id]
	if type(filename) ~= "string" or filename == "" then
		return nil
	end

	local dir = self:getCustomIconsDir()
	if not dir then
		return nil
	end

	local fullpath = dir .. "/" .. filename
	if not fileExists(fullpath) then
		return nil
	end
	return fullpath
end

-- Saves (or clears, when filename is empty/nil) the chosen icon filename
-- for action_id. Only the bare filename is stored (never a full path), so
-- the plugin can be moved/reinstalled to a different directory without
-- breaking the setting.
function FloatingDictionary:setActionCustomIcon(action_id, filename)
	local saved = self:getActionCustomIconsSetting()
	if type(filename) == "string" and filename ~= "" then
		saved[action_id] = filename
	else
		saved[action_id] = nil
	end
	G_reader_settings:saveSetting(SETTING_ACTION_CUSTOM_ICONS, saved)
end

-- Dictionary display order -------------------------------------------------
-- User-ranked list of installed dictionaries (see SETTING_DICTIONARY_ORDER
-- above for the full rationale). Any dictionary present on disk but missing
-- from the saved order is appended at the end (alphabetically, keeping
-- getInstalledDictionaryNames's own sort), and any name in the saved order
-- that no longer corresponds to an installed dictionary (uninstalled since)
-- is silently dropped -- exactly the same "stays in sync automatically"
-- behavior already used for the footer-button order.
function FloatingDictionary:getDictionaryOrderSetting()
	local installed = self:getInstalledDictionaryNames()
	local installed_set = {}
	for _, name in ipairs(installed) do
		installed_set[name] = true
	end

	local saved = G_reader_settings:readSetting(SETTING_DICTIONARY_ORDER)
	if type(saved) ~= "table" then
		saved = {}
	end

	local seen = {}
	local order = {}
	for _, name in ipairs(saved) do
		if installed_set[name] and not seen[name] then
			seen[name] = true
			table.insert(order, name)
		end
	end

	for _, name in ipairs(installed) do
		if not seen[name] then
			seen[name] = true
			table.insert(order, name)
		end
	end

	return order
end

function FloatingDictionary:setDictionaryOrderSetting(order)
	G_reader_settings:saveSetting(SETTING_DICTIONARY_ORDER, order)
end

-- Swaps dict_name with its neighbor in the given direction (-1 = up/earlier,
-- 1 = down/later) and persists the new order. No-op at either end, or if
-- dict_name isn't currently in the (synced) order for any reason.
function FloatingDictionary:moveDictionaryInOrder(dict_name, direction)
	local order = self:getDictionaryOrderSetting()

	local current_pos
	for pos, name in ipairs(order) do
		if name == dict_name then
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
	self:setDictionaryOrderSetting(order)
end

-- Returns { [dict_name] = rank_number, ... } for O(1) lookups when sorting
-- lookup results (sortResultsByDictionaryOrder below), rank 1 = shown first.
-- Kept separate from getDictionaryOrderSetting so callers that just need to
-- test membership/position don't all re-walk the ordered array themselves.
function FloatingDictionary:getDictionaryRankMap()
	local order = self:getDictionaryOrderSetting()
	local ranks = {}
	for pos, name in ipairs(order) do
		ranks[name] = pos
	end
	return ranks
end

-- Submenu (plain native KOReader Menu items, same family of widgets as
-- genDisplayModeMenu/genVisibleActionsMenu above -- no custom widget code)
-- opened from the "Dictionary order" entry: one row per installed
-- dictionary, showing its current rank ("1.", "2.", ...) and its name, plus
-- a "Move up" / "Move down" pair of rows right underneath acting on
-- whichever dictionary the user tapped last. This is the single place users
-- set display priority for definitions, translations, synonyms, antonyms,
-- etymology, conjugations, pronunciation, usage examples, thesauri, or any
-- other dictionary type: every installed dictionary is treated the same way
-- here, regardless of what kind of content it contains, so the menu scales
-- to however many the user has installed without needing to recognize what
-- any of them are.
--
-- KOReader's touch-menu doesn't have a drag-and-drop reorder widget, and a
-- pair of always-visible per-row ↑/↓ chips (as used for footer buttons)
-- would need a bespoke widget popup to lay out reliably for an
-- open-ended, potentially long dictionary list. Tapping a row to "select"
-- it, then using two ordinary menu rows to nudge that selection, reuses
-- plain Menu items end to end and reads clearly at any list length: the
-- selected dictionary is marked, and "Move up"/"Move down" always describe
-- exactly what they'll do to it.
--
-- IMPORTANT re: touchmenu_instance:updateItems() -- that call only repaints
-- the rows already sitting in touchmenu_instance.item_table; it does NOT
-- re-invoke this function. Each row's text_func/checked_func is a closure
-- captured once, at the moment `items` below is built, over that specific
-- call's `pos`/`dict_name` locals. So a callback that mutates the saved
-- order and then only calls updateItems() repaints the *same, now-stale*
-- closures -- the settings do change, but the visible rows never do,
-- which is exactly the "buttons appear but don't move anything" bug this
-- replaces. The fix is to rebuild item_table from a fresh call to this
-- function first (so every row's closure is recreated against the new
-- order), and only then call updateItems() to repaint with those fresh
-- rows -- both steps are required.
function FloatingDictionary:genDictionaryOrderMenu()
	local order = self:getDictionaryOrderSetting()

	if #order == 0 then
		return {
			{
				text = _("No dictionaries found. Install or enable a dictionary first."),
				enabled = false,
			},
		}
	end

	-- Remembers which dictionary is "selected" for the Move up/down rows
	-- below, for the lifetime of this menu instance. Defaults to the first
	-- (highest-priority) dictionary so Move up/down are meaningful right
	-- away without an extra tap.
	self._dict_order_selected = self._dict_order_selected or order[1]

	-- Drop the selection if that dictionary was uninstalled since the menu
	-- was last opened.
	local selected_still_installed = false
	for _, name in ipairs(order) do
		if name == self._dict_order_selected then
			selected_still_installed = true
			break
		end
	end
	if not selected_still_installed then
		self._dict_order_selected = order[1]
	end

	-- Rebuilds touchmenu_instance's visible rows from scratch (fresh
	-- closures over the current order/selection) and repaints. Every
	-- callback below calls this instead of touchmenu_instance:updateItems()
	-- directly, so the rows the user sees always match the just-changed
	-- state -- see the note above the function for why calling
	-- updateItems() alone is not enough.
	local function refresh(touchmenu_instance)
		if not touchmenu_instance then
			return
		end
		touchmenu_instance.item_table = self:genDictionaryOrderMenu()
		touchmenu_instance:updateItems()
	end

	local items = {}

	table.insert(items, {
		text = _("Tap a dictionary to select it, then use \"Move up\" / \"Move down\" below to set its priority. Dictionaries higher on this list appear first when you look up a word."),
		enabled = false,
		separator = true,
	})

	table.insert(items, {
		text_func = function()
			return T(_("Move up: %1"), self._dict_order_selected)
		end,
		keep_menu_open = true,
		callback = function(touchmenu_instance)
			self:moveDictionaryInOrder(self._dict_order_selected, -1)
			refresh(touchmenu_instance)
		end,
	})
	table.insert(items, {
		text_func = function()
			return T(_("Move down: %1"), self._dict_order_selected)
		end,
		keep_menu_open = true,
		separator = true,
		callback = function(touchmenu_instance)
			self:moveDictionaryInOrder(self._dict_order_selected, 1)
			refresh(touchmenu_instance)
		end,
	})

	for pos, dict_name in ipairs(order) do
		table.insert(items, {
			text_func = function()
				return T("%1. %2", pos, dict_name)
			end,
			radio = true,
			checked_func = function()
				return self._dict_order_selected == dict_name
			end,
			keep_menu_open = true,
			callback = function(touchmenu_instance)
				self._dict_order_selected = dict_name
				refresh(touchmenu_instance)
			end,
		})
	end

	return items
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
-- Display mode overrides are applied on top of the user's individually
-- configured visibility/order (they never alter those persisted settings,
-- so switching back to Personal mode restores the exact previous setup):
--   Minimal         -> entire footer hidden (returns no actions at all).
--   Full            -> every available action forced visible, regardless
--                      of what's individually hidden.
--   Language learner -> Wikipedia and fulltext search are forced hidden.
function FloatingDictionary:getVisibleActions()
	local mode = self:getDisplayMode()

	if mode == DISPLAY_MODE_MINIMAL then
		return {}
	end

	local visible = {}
	for _, action in ipairs(self:getOrderedActions()) do
		local available = action.id ~= ACTION_VOCABULARY or self:hasVocabBuilder()
		local hidden_by_language_mode = mode == DISPLAY_MODE_LANGUAGE
			and (action.id == ACTION_WIKIPEDIA or action.id == ACTION_SEARCH_BOOK)

		if available and not hidden_by_language_mode then
			if mode == DISPLAY_MODE_FULL or self:isActionVisible(action.id) then
				table.insert(visible, action)
			end
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

-- Icon (or text-fallback) spec for a single footer button. Priority order:
-- 1. User-chosen custom SVG icon (floatingdictionary-images/), if set and
--    the file still exists.
-- 2. This plugin's own bundled icon (icons/), if present for this action.
-- 3. Text label -- the user's custom text if set, otherwise the default
--    single-letter initial.
-- A custom icon whose file has since been deleted is treated as "not set"
-- by getActionCustomIcon, so step 3 (not a blank/broken button) is what the
-- user sees in that case. Every action in ACTIONS goes through this same
-- three-step chain -- none is hardcoded to a fixed icon/text anymore, so
-- every button is equally customizable via "Buttons shown in preview".
function FloatingDictionary:getActionIconSpec(action_id)
	local action = ACTION_BY_ID[action_id]
	if not action then
		return { icon = ICON_SEARCH }
	end

	local custom_icon = self:getActionCustomIcon(action_id)
	if custom_icon then
		return { icon_file = custom_icon }
	end

	local plugin_icon = self:getPluginIconFile(action_id)
	if plugin_icon then
		return { icon_file = plugin_icon }
	end

	-- Fallback intentionally uses gettext labels from KOReader's catalog,
	-- unless the user has set their own custom text for this button (see
	-- getActionButtonLabel). Reduced to a single capitalized initial by
	-- default so it always fits the button instead of being cut off; a
	-- custom label is shown as-is (long ones are elegantly truncated with
	-- an ellipsis by the button's own TextWidget, see PreviewButton above).
	return { text = self:getActionButtonLabel(action) }
end

-- Same pattern as genDictionaryOrderMenu: tap a row (radio) to select a
-- button, then "Move up"/"Move down" reorders it. Visibility keeps its own
-- explicit checkbox-style row (independent of selection) so hiding/showing
-- a button doesn't require selecting it first. Every callback rebuilds
-- touchmenu_instance.item_table from a fresh call to this function before
-- calling updateItems() -- calling updateItems() alone would repaint the
-- same stale closures (captured over the old order) without moving
-- anything, exactly like the earlier dictionary-order bug.
function FloatingDictionary:genVisibleActionsMenu()
	local orderable = {}
	for _, action in ipairs(self:getOrderedActions()) do
		if action.kind ~= "external" then
			table.insert(orderable, action)
		end
	end

	if #orderable == 0 then
		return {
			{
				text = _("No buttons available."),
				enabled = false,
			},
		}
	end

	self._action_order_selected = self._action_order_selected or orderable[1].id
	local selected_still_present = false
	for _, action in ipairs(orderable) do
		if action.id == self._action_order_selected then
			selected_still_present = true
			break
		end
	end
	if not selected_still_present then
		self._action_order_selected = orderable[1].id
	end

	local function refresh(touchmenu_instance)
		if not touchmenu_instance then
			return
		end
		touchmenu_instance.item_table = self:genVisibleActionsMenu()
		touchmenu_instance:updateItems()
	end

	local items = {}

	table.insert(items, {
		text = _("Tap a button to select it, then use \"Move up\" / \"Move down\" to set its position. Use the checkbox row to show/hide it."),
		enabled = false,
		separator = true,
	})

	table.insert(items, {
		text_func = function()
			local action = ACTION_BY_ID[self._action_order_selected]
			return T(_("Move up: %1"), action and action.label or self._action_order_selected)
		end,
		keep_menu_open = true,
		callback = function(touchmenu_instance)
			self:moveAction(self._action_order_selected, -1)
			refresh(touchmenu_instance)
		end,
	})
	table.insert(items, {
		text_func = function()
			local action = ACTION_BY_ID[self._action_order_selected]
			return T(_("Move down: %1"), action and action.label or self._action_order_selected)
		end,
		keep_menu_open = true,
		callback = function(touchmenu_instance)
			self:moveAction(self._action_order_selected, 1)
			refresh(touchmenu_instance)
		end,
	})
	table.insert(items, {
		text_func = function()
			local action = ACTION_BY_ID[self._action_order_selected]
			local visible = self:isActionVisible(self._action_order_selected)
			return T(visible and _("Hide: %1") or _("Show: %1"), action and action.label or self._action_order_selected)
		end,
		keep_menu_open = true,
		callback = function(touchmenu_instance)
			self:setActionVisible(self._action_order_selected, not self:isActionVisible(self._action_order_selected))
			refresh(touchmenu_instance)
		end,
	})
	table.insert(items, {
		text_func = function()
			local action = ACTION_BY_ID[self._action_order_selected]
			local custom = self:getActionCustomLabel(self._action_order_selected)
			local current = custom or (action and getButtonInitial(action.short_label or action.label)) or "?"
			return T(_("Button text: %1 (currently \"%2\")"),
				action and action.label or self._action_order_selected, current)
		end,
		keep_menu_open = true,
		callback = function(touchmenu_instance)
			self:showActionCustomLabelDialog(self._action_order_selected, touchmenu_instance)
		end,
	})
	table.insert(items, {
		text_func = function()
			local action = ACTION_BY_ID[self._action_order_selected]
			local icon_path = self:getActionCustomIcon(self._action_order_selected)
			local current = icon_path and icon_path:match("([^/]+)$") or _("none, using text")
			return T(_("Button icon: %1 (currently: %2)"),
				action and action.label or self._action_order_selected, current)
		end,
		separator = true,
		keep_menu_open = true,
		sub_item_table_func = function()
			return self:genActionCustomIconMenu(self._action_order_selected)
		end,
	})

	for pos, action in ipairs(orderable) do
		local action_id = action.id
		table.insert(items, {
			text_func = function()
				local visibility = self:isActionVisible(action_id) and _("shown") or _("hidden")
				return T("%1. %2 (%3)", pos, action.label, visibility)
			end,
			radio = true,
			enabled_func = function()
				return action_id ~= ACTION_VOCABULARY or self:hasVocabBuilder()
			end,
			checked_func = function()
				return self._action_order_selected == action_id
			end,
			keep_menu_open = true,
			callback = function(touchmenu_instance)
				self._action_order_selected = action_id
				refresh(touchmenu_instance)
			end,
		})
	end

	return items
end

-- Small text-input dialog for setting (or clearing) one footer button's
-- custom label. Reuses the same InputDialog pattern as the other numeric
-- dialogs above (showCardHeightDialog, etc.), just with a plain text field
-- instead of input_type = "number". Leaving the field blank and saving
-- clears the custom label, which makes the button fall back to its default
-- initial letter -- exactly the "leave empty to reset" behavior asked for.
-- A separate "Reset to default" button is also offered for a one-tap clear
-- without having to manually empty the field first.
function FloatingDictionary:showActionCustomLabelDialog(action_id, touchmenu_instance)
	local action = ACTION_BY_ID[action_id]
	if not action then
		return
	end

	local current = self:getActionCustomLabel(action_id)

	local dialog
	dialog = InputDialog:new{
		title = T(_("Button text: %1"), action.label),
		description = _("Text shown on this button in the popup. Leave blank to use the default single-letter icon."),
		input = current or "",
		input_hint = getButtonInitial(action.short_label or action.label),
		buttons = {
			{
				{
					text = _("Cancel"),
					id = "close",
					callback = function()
						UIManager:close(dialog)
					end,
				},
				{
					text = _("Reset to default"),
					callback = function()
						self:setActionCustomLabel(action_id, nil)
						UIManager:close(dialog)
						if touchmenu_instance then
							touchmenu_instance.item_table = self:genVisibleActionsMenu()
							touchmenu_instance:updateItems()
						end
					end,
				},
				{
					text = _("Save"),
					is_enter_default = true,
					callback = function()
						local input_text = dialog:getInputText()
						self:setActionCustomLabel(action_id, input_text)
						UIManager:close(dialog)
						if touchmenu_instance then
							touchmenu_instance.item_table = self:genVisibleActionsMenu()
							touchmenu_instance:updateItems()
						end
					end,
				},
			},
		},
	}
	UIManager:show(dialog)
	dialog:onShowKeyboard()
end

-- Radio-button submenu for picking a button's icon: "None (use text)" at
-- the top, then one entry per .svg file found in floatingdictionary-images/
-- (scanned fresh every time the submenu opens, so a file dropped in or
-- removed since the menu was last opened is picked up immediately, no
-- restart needed). The user never types a filename or path -- they just tap
-- the icon they want from the list, exactly like picking a font from
-- "Preview font" (genFontFamilyMenu) above. Plain text rows (filename only)
-- are used rather than an inline graphical preview: KOReader's touchmenu
-- item format has no standard field for embedding an arbitrary widget in a
-- menu row, and a filename-only radio list is what genFontFamilyMenu and
-- genDictionaryOrderMenu already do elsewhere in this same settings menu,
-- so it stays visually consistent with the rest of the plugin.
function FloatingDictionary:genActionCustomIconMenu(action_id)
	local items = {}

	table.insert(items, {
		text = _("None (use text)"),
		radio = true,
		checked_func = function()
			return self:getActionCustomIcon(action_id) == nil
		end,
		callback = function()
			self:setActionCustomIcon(action_id, nil)
		end,
	})

	local dir = self:getCustomIconsDir()
	local icons = self:getAvailableCustomIcons()

	if #icons == 0 then
		table.insert(items, {
			text = dir
				and T(_("No .svg files found in %1"), CUSTOM_ICONS_DIR_NAME)
				or _("Plugin folder not found."),
			enabled = false,
		})
		return items
	end

	for _, filename in ipairs(icons) do
		local fullpath = dir .. "/" .. filename
		table.insert(items, {
			text = filename,
			radio = true,
			checked_func = function()
				return self:getActionCustomIcon(action_id) == fullpath
			end,
			callback = function()
				self:setActionCustomIcon(action_id, filename)
			end,
		})
	end

	items.max_per_page = 8
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
			local initial = self:getActionButtonLabel(action)
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
			border_thickness = self:getPopupBorderThickness(),
			border_color = self:getPopupBorderColor(),
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
		-- Nothing left in popup_stack to animate/close (e.g. this card was
		-- already hidden earlier by hideOlderStackCards when a newer cascade
		-- step was shown on top of it). Still pop the matching cascade_history
		-- frame so the two stay in lockstep, but skip the animation/close of
		-- an already-gone widget: animating a widget that isn't actually the
		-- current top of UIManager's window stack corrupts its repaint state
		-- and is what was causing the freeze/crash when returning via the
		-- breadcrumb.
		local frame = table.remove(self.cascade_history)
		if invoke_callback ~= false and frame and frame.dict_close_callback then
			pcall(frame.dict_close_callback)
		end
		return frame
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
	if self.pending_word_review_task then
		pcall(function()
			UIManager:unschedule(self.pending_word_review_task)
		end)
		self.pending_word_review_task = nil
	end
	if self.close_review_popup then
		pcall(self.close_review_popup)
	end

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
	self.word_review_shown_for_this_book = false
	self:resetNativeDictionaryPopupGuard()

	if WidgetContainer.destroy then
		WidgetContainer.destroy(self)
	end
end

-- Highlight menu absorption --------------------------------------------------
-- KOReader's own ReaderHighlight module normally adds a top-level
-- "Highlights" entry to the settings menu (style picker, color, gray
-- opacity, line height, note marker, "apply to all", PDF write-in toggle).
-- This wraps ReaderHighlight:addToMainMenu so that, right after it builds
-- that entry as usual (nothing about how it's built changes), this plugin:
--   1. Captures its sub_item_table so Floating Dictionary's own
--      "Highlight styles" entry (see genMergedHighlightStylesMenu) can show
--      the exact same items, with the exact same callbacks -- no
--      duplication, no reimplementation, no behavior change.
--   2. Removes the top-level menu_items.highlight_options entry so
--      "Highlights" no longer appears as its own independent menu.
-- Wrapping (rather than editing readerhighlight.lua directly) means this
-- keeps working across KOReader updates to that file, and wrapping happens
-- once per ReaderHighlight instance via an idempotency guard, so re-opening
-- the menu repeatedly or switching documents is safe.
function FloatingDictionary:patchHighlightMenu()
	local highlight = self.ui and self.ui.highlight

	if not highlight then
		logger.warn("FloatingDictionary: ReaderHighlight not available.")
		return
	end

	if highlight._floatingdictionary_menu_patched then
		return
	end
	highlight._floatingdictionary_menu_patched = true

	local original_addToMainMenu = highlight.addToMainMenu
	local plugin = self

	highlight.addToMainMenu = function(highlight_self, menu_items)
		-- Let ReaderHighlight build menu_items.highlight_options exactly as
		-- it always has -- same items, same callbacks, same behavior.
		original_addToMainMenu(highlight_self, menu_items)

		local ok, err = pcall(function()
			if menu_items.highlight_options and menu_items.highlight_options.sub_item_table then
				-- Fix a stock KOReader bug in "Apply current style and color
				-- to all highlights": unlike the per-item style/color editor
				-- (ReaderHighlight:editHighlightStyle / editHighlightColor,
				-- which both fire an "AnnotationsModified" event after
				-- changing an item), the "apply to all" callback only calls
				-- UIManager:setDirty(self.dialog, "ui") after updating every
				-- annotation's drawer/color. setDirty alone does not
				-- invalidate crengine's own highlight render cache, so nothing
				-- visibly changes -- not even after turning pages -- even
				-- though the underlying annotation data was updated
				-- correctly. Wrapping this one item's callback (found by its
				-- known text, since it isn't its own named function) to also
				-- fire "AnnotationsModified" for every touched annotation,
				-- exactly like the individual editors do, is the minimal fix:
				-- it does not touch how the confirmation dialog or the
				-- counting/notification logic work, only adds the missing
				-- refresh step after they run.
				for _idx, item in ipairs(menu_items.highlight_options.sub_item_table) do
					if item.text == _("Apply current style and color to all highlights")
						and type(item.callback) == "function" and not item._floatingdictionary_refresh_patched then
						local original_callback = item.callback
						item._floatingdictionary_refresh_patched = true
						item.callback = function(...)
							-- The original callback shows a ConfirmBox and
							-- only updates annotations inside *its*
							-- ok_callback, once the user actually confirms.
							-- To fire the refresh at the right time (after
							-- confirmation, not right after the dialog is
							-- merely shown), this temporarily wraps
							-- UIManager:show for the duration of the
							-- original callback: if the widget it's asked to
							-- show is a ConfirmBox with an ok_callback (which
							-- is exactly what the original callback creates),
							-- that ok_callback is wrapped to run the refresh
							-- afterwards. Any other widget shown during this
							-- window (there shouldn't be any) passes through
							-- untouched.
							local original_show = UIManager.show
							UIManager.show = function(ui_self, widget, ...)
								local ok_wrap, err_wrap = pcall(function()
									if widget and widget.ok_callback and type(widget.ok_callback) == "function"
										and not widget._floatingdictionary_refresh_patched then
										local original_ok_callback = widget.ok_callback
										widget._floatingdictionary_refresh_patched = true
										widget.ok_callback = function(...)
											original_ok_callback(...)
											local ok_refresh, err_refresh = pcall(function()
												if highlight_self.ui and highlight_self.ui.annotation and highlight_self.ui.annotation.annotations then
													for _, annotation in ipairs(highlight_self.ui.annotation.annotations) do
														if annotation.drawer then
															highlight_self.ui:handleEvent(Event:new("AnnotationsModified", { annotation }))
														end
													end
												end
											end)
											if not ok_refresh then
												logger.warn("FloatingDictionary: failed to refresh highlights after 'apply to all':", err_refresh)
											end
										end
									end
								end)
								if not ok_wrap then
									logger.warn("FloatingDictionary: failed to wrap 'apply to all' confirmation:", err_wrap)
								end
								return original_show(ui_self, widget, ...)
							end

							local ok_call, err_call = pcall(original_callback, ...)

							UIManager.show = original_show

							if not ok_call then
								logger.warn("FloatingDictionary: 'apply to all' callback failed:", err_call)
							end
						end
					end
				end

				-- Re-captured every time this runs, so it always reflects
				-- current native items (e.g. the PDF write-in toggle,
				-- which only appears for is_pdf documents).
				local sub_items = menu_items.highlight_options.sub_item_table

				-- Drop the trailing " ★" default-style marker from the style
				-- radio buttons' text_func (e.g. "Lighten ★" -> "Lighten"),
				-- leaving the plain style name with no extra decoration.
				for _idx, item in ipairs(sub_items) do
					if item.radio and type(item.text_func) == "function" and not item._floatingdictionary_star_stripped then
						local original_text_func = item.text_func
						item._floatingdictionary_star_stripped = true
						item.text_func = function()
							local text = original_text_func()
							text = text:gsub("%s*\xE2\x98\x85%s*$", "")
							return text
						end
					end
				end

				-- Remove the items this plugin's simplified menu no longer
				-- needs: Highlight colour, Gray highlight opacity, Highlight
				-- line height, and Note marker. Matched by their known
				-- text/text_func output so this keeps working even if
				-- ReaderHighlight reorders its own sub_item_table, and
				-- doesn't touch anything else (style radios, "Apply to all",
				-- PDF write-in) since those are left in place untouched.
				local HIDDEN_NATIVE_PREFIXES = {
					_("Highlight color: "), -- KOReader menu text (US spelling)
					_("Gray highlight opacity: "),
					_("Highlight line height: "),
					_("Note marker: "),
				}
				local filtered_items = {}
				for _idx, item in ipairs(sub_items) do
					local item_text = item.text
					if not item_text and type(item.text_func) == "function" then
						local ok_text, text_result = pcall(item.text_func)
						if ok_text then
							item_text = text_result
						end
					end
					local hidden = false
					if item_text then
						for _, prefix in ipairs(HIDDEN_NATIVE_PREFIXES) do
							if item_text:sub(1, #prefix) == prefix then
								hidden = true
								break
							end
						end
					end
					if not hidden then
						table.insert(filtered_items, item)
					end
				end

				-- Move "Apply current style and color to all highlights" to
				-- the very front of the menu, ahead of the style radios and
				-- everything else, per the requested menu ordering. Every
				-- other item keeps its existing relative order.
				local apply_index = nil
				for idx, item in ipairs(filtered_items) do
					if item.text == _("Apply current style and color to all highlights") then
						apply_index = idx
						break
					end
				end
				if apply_index then
					local apply_item = table.remove(filtered_items, apply_index)
					apply_item.separator = true
					table.insert(filtered_items, 1, apply_item)
				end

				-- Clear any leftover separator on what is now the last item
				-- (it may have been "Apply to all"'s old neighbour) so the
				-- menu doesn't end with a stray divider line, then restore
				-- the separator that used to follow the style radio group.
				for idx, item in ipairs(filtered_items) do
					if item.radio and (not filtered_items[idx + 1] or not filtered_items[idx + 1].radio) then
						item.separator = true
					end
				end

				plugin.native_highlight_sub_items = filtered_items
			end
			-- Hide the independent top-level entry; it now lives inside
			-- Floating Dictionary -> Highlight styles instead.
			menu_items.highlight_options = nil
		end)
		if not ok then
			logger.warn("FloatingDictionary: failed to fold Highlights menu into Floating Dictionary:", err)
		end
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

		-- Word review history: recorded here, the single point every real
		-- dictionary lookup passes through, regardless of which popup ends up
		-- showing it (floating card below, or the native popup via the
		-- native_dict_popup_active branch just below) or whether it's a fresh
		-- lookup or a cascaded cross-reference. Kept a plain best-effort call
		-- (never blocks or fails the actual lookup) since history bookkeeping
		-- should never be able to break normal dictionary use.
		local ok_record, err_record = pcall(function()
			WordReview:recordLookup(plugin, plugin:getSearchText(word, results[1]))
		end)
		if not ok_record then
			logger.warn("FloatingDictionary: WordReview:recordLookup failed:", err_record)
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

	local header_html = table.concat({
		'<div class="floatingdictionary-word">',
		htmlEscape(shown_word),
		"</div>",
		'<div class="floatingdictionary-meta">',
		htmlEscape(dict_name),
		"</div>",
		'<div class="floatingdictionary-separator"></div>',
	}, "\n")

	return {
		html_body = header_html .. definition_html,
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

-- translation_first (default false) swaps which group leads when
-- rank_map is nil/empty: the Language learner display mode passes true so
-- translation dictionaries come first, then monolingual definition
-- dictionaries. This is only a *fallback* grouping used for dictionaries
-- the user hasn't explicitly ranked (see rank_map below); it preserves the
-- exact previous behavior for anyone who hasn't touched the new "Dictionary
-- order" setting.
--
-- rank_map (optional) is the { [dict_name] = rank_number } table built by
-- FloatingDictionary:getDictionaryRankMap(), reflecting the user's manually
-- configured "Dictionary order" (see genDictionaryOrderMenu). When present,
-- it takes priority over the definition/translation split above: results
-- are primarily ordered by ascending rank (lower number = shown first),
-- which works uniformly for definitions, translations, synonyms, antonyms,
-- etymology, conjugations, pronunciation, usage examples, thesauri, or any
-- other dictionary type -- the plugin never needs to know which kind a
-- dictionary is to place it correctly. Any result whose dictionary isn't in
-- rank_map (e.g. getDictionaryRankMap was unavailable, or a dictionary was
-- installed after the map was built) keeps its relative order via the
-- definition/translation fallback grouping, and sorts after every ranked
-- result -- so an incomplete or missing rank_map degrades gracefully to the
-- previous behavior instead of hiding anything.
local function buildPreviewResults(results, translation_first, rank_map)
	local preview_results = {}

	if type(results) ~= "table" then
		return preview_results
	end

	-- Split into "definition" and "translation-looking" dictionary results,
	-- based on the dictionary's own name (classifyDictionaryName): even if
	-- the user has a translation dictionary enabled as a regular KOReader
	-- dictionary (mixed in with normal definition dictionaries), it gets
	-- pushed to the end of the navigable pages instead of interleaved. Used
	-- as the ordering when rank_map is absent, and as the tie-break/fallback
	-- ordering for unranked results when rank_map is present.
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

	local first_group = translation_first and translation_results or definition_results
	local second_group = translation_first and definition_results or translation_results

	for _, entry in ipairs(first_group) do
		table.insert(preview_results, entry)
	end
	for _, entry in ipairs(second_group) do
		table.insert(preview_results, entry)
	end

	-- Manual "Dictionary order" takes priority when available: stable-sort
	-- (Lua's table.sort isn't guaranteed stable, so ties are broken by the
	-- fallback position computed above) by ascending rank, unranked results
	-- keep their fallback position and sort after every ranked one.
	if type(rank_map) == "table" and next(rank_map) ~= nil then
		for fallback_pos, entry in ipairs(preview_results) do
			entry.fallback_pos = fallback_pos
			entry.rank = rank_map[entry.result.dict]
		end
		table.sort(preview_results, function(a, b)
			local rank_a = a.rank or math.huge
			local rank_b = b.rank or math.huge
			if rank_a ~= rank_b then
				return rank_a < rank_b
			end
			return a.fallback_pos < b.fallback_pos
		end)
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

	local preview_results = buildPreviewResults(
		results,
		self:getDisplayMode() == DISPLAY_MODE_LANGUAGE,
		self:getDictionaryRankMap()
	)
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

	-- Visually hides every other card currently in popup_stack (older cascade
	-- steps) *without* touching cascade_history: that list is the sole source
	-- of truth for the breadcrumb trail and for what gets rebuilt when the
	-- user taps a breadcrumb word or navigates back, so it's left completely
	-- untouched here. This only closes the on-screen widgets so that, now
	-- that cards can be shorter than the configured max height (dynamic
	-- popup height), a short new card never leaves an older, differently
	-- sized card peeking out from behind it.
	--
	-- Since onBreadcrumbSelect / renderCascadeFrame always rebuild the target
	-- card from cascade_history rather than assuming it's still alive
	-- underneath, hiding these older widgets here is safe: going back via the
	-- breadcrumb re-renders that step fresh instead of depending on it having
	-- stayed open.
	local function hideOlderStackCards()
		local stack = self.popup_stack
		if not stack then
			return
		end
		for i = #stack, 1, -1 do
			local old_popup = stack[i]
			pcall(function()
				UIManager:close(old_popup)
			end)
			table.remove(stack, i)
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
				local spec = self:getActionIconSpec(action.id)
				spec.disabled = preview_count <= 1
				table.insert(action_specs, {
					spec = spec,
					callback = function()
						if preview_count > 1 then
							return showResult(current_index - 1)
						end
					end,
				})
			elseif action.kind == "nav_next" then
				local spec = self:getActionIconSpec(action.id)
				spec.disabled = preview_count <= 1
				table.insert(action_specs, {
					spec = spec,
					callback = function()
						if preview_count > 1 then
							return showResult(current_index + 1)
						end
					end,
				})
			elseif action.kind == "font_decrease" then
				table.insert(action_specs, {
					spec = self:getActionIconSpec(action.id),
					callback = function()
						self:setFontSizeDelta(self:getFontSizeDelta() - FONT_SIZE_STEP)
						return showResult(current_index)
					end,
				})
			elseif action.kind == "font_increase" then
				table.insert(action_specs, {
					spec = self:getActionIconSpec(action.id),
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
			card_height_ratio = self:getCardHeightRatio(),
			border_thickness = self:getPopupBorderThickness(),
			border_color = self:getPopupBorderColor(),
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

		if is_new_card then
			-- This is a brand new cascade step (a fresh lookup pushed on top,
			-- or the target card after a breadcrumb tap): hide every other
			-- card still sitting in popup_stack first, so this new card is
			-- always the only one visible on screen. Their data stays intact
			-- in cascade_history, so the breadcrumb trail and "go back" both
			-- keep working exactly as before -- only the stale on-screen
			-- widgets (which, with dynamic popup height, could otherwise peek
			-- out from behind a shorter new card) are removed.
			hideOlderStackCards()
		end

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

-- =============================================================================
-- Word review ("Palabra recordada")
-- =============================================================================
--
-- Shows one word from the current book's own lookup history (see
-- wordreview.lua) using the exact same floating popup as a normal lookup --
-- same dictionaries, same order, same max-height/scroll behavior -- but:
--   * no breadcrumb/cascade navigation (this isn't part of any lookup trail)
--   * a left-aligned title identifying it as a review, instead
--   * this lookup itself is never recorded into the history (it would
--     otherwise inflate the reviewed word's own count every time it's shown)
--
-- Entirely independent of cascade_history/popup_stack/cascade_dict_self:
-- a review card is deliberately its own, self-contained little session, so
-- it can never interfere with (or be interfered with by) an in-progress
-- cascade of real lookups, and closing it never needs to touch that state.
function FloatingDictionary:showReviewPopup(word, results)
	local preview_results = buildPreviewResults(
		results,
		self:getDisplayMode() == DISPLAY_MODE_LANGUAGE,
		self:getDictionaryRankMap()
	)
	local preview_count = #preview_results
	if preview_count <= 0 then
		return true
	end

	local review_popup
	local current_index = 1

	local function closeReviewPopup()
		if review_popup then
			pcall(function()
				UIManager:close(review_popup)
			end)
			review_popup = nil
		end
		if self.close_review_popup == closeReviewPopup then
			self.close_review_popup = nil
		end
	end

	-- Exposed on self (not just as a local) so onSuspend -- which has no
	-- other reference to this review card, since it's deliberately kept
	-- outside popup_stack/cascade_history -- can still find and close it
	-- when the device goes to sleep.
	self.close_review_popup = closeReviewPopup

	local function showReviewResult(index)
		current_index = normalizeResultIndex(index, preview_count)
		local preview_entry = preview_results[current_index] or preview_results[1] or {}
		local result = preview_entry.result or {}
		local preview_payload = self:buildPreviewPayload(word, result, current_index, preview_count)

		-- Only paging and font-size actions are offered here: every other
		-- action (highlight, add to vocabulary, translate, search-in-book,
		-- external dictionary buttons) is built around a real text
		-- selection/dict_self context from an actual lookup, which a review
		-- card -- deliberately triggered on book open, with no selection
		-- involved -- never has. Rather than risk a broken or misleading
		-- action, the review card's footer simply doesn't offer them.
		local action_specs = {}
		for _, action in ipairs(self:getVisibleActions()) do
			if action.kind == "nav_prev" then
				local spec = self:getActionIconSpec(action.id)
				spec.disabled = preview_count <= 1
				table.insert(action_specs, {
					spec = spec,
					callback = function()
						if preview_count > 1 then
							return showReviewResult(current_index - 1)
						end
					end,
				})
			elseif action.kind == "nav_next" then
				local spec = self:getActionIconSpec(action.id)
				spec.disabled = preview_count <= 1
				table.insert(action_specs, {
					spec = spec,
					callback = function()
						if preview_count > 1 then
							return showReviewResult(current_index + 1)
						end
					end,
				})
			elseif action.kind == "font_decrease" then
				table.insert(action_specs, {
					spec = self:getActionIconSpec(action.id),
					callback = function()
						self:setFontSizeDelta(self:getFontSizeDelta() - FONT_SIZE_STEP)
						return showReviewResult(current_index)
					end,
				})
			elseif action.kind == "font_increase" then
				table.insert(action_specs, {
					spec = self:getActionIconSpec(action.id),
					callback = function()
						self:setFontSizeDelta(self:getFontSizeDelta() + FONT_SIZE_STEP)
						return showReviewResult(current_index)
					end,
				})
			end
		end

		closeReviewPopup()

		review_popup = FloatingDictionaryPopup:new({
			html_body = preview_payload.html_body,
			css = preview_payload.css,
			html_resource_directory = preview_payload.html_resource_directory,
			button_face = preview_payload.button_face,
			button_icon_size = preview_payload.button_icon_size,
			button_row_height = preview_payload.button_row_height,
			card_height_ratio = self:getCardHeightRatio(),
			border_thickness = self:getPopupBorderThickness(),
			border_color = self:getPopupBorderColor(),
			doc_font_size = self:getInterfaceFontSize(),
			dialog = nil,
			result_count = preview_count,
			anchor_top = false,
			center_on_screen = true,
			custom_title = _("Word to review"),
			actions = action_specs,
			open_callback = nil,
			prev_callback = function()
				return showReviewResult(current_index - 1)
			end,
			next_callback = function()
				return showReviewResult(current_index + 1)
			end,
			decrease_font_callback = function()
				self:setFontSizeDelta(self:getFontSizeDelta() - FONT_SIZE_STEP)
				return showReviewResult(current_index)
			end,
			increase_font_callback = function()
				self:setFontSizeDelta(self:getFontSizeDelta() + FONT_SIZE_STEP)
				return showReviewResult(current_index)
			end,
			open_button_settings_callback = function()
				return self:showButtonSettingsMenu(function()
					return showReviewResult(current_index)
				end)
			end,
			close_preview_callback = function()
				-- Must actually close the on-screen widget here (same as the
				-- normal cascade popup's closePreview), not just clear the
				-- local reference -- otherwise the card never leaves the
				-- window/event stack, stays visible forever, and swallows
				-- all taps/gestures for the rest of the reading session.
				closeReviewPopup()
				return true
			end,
		})

		-- The real, normal-lookup popup always gets a live dialog widget
		-- here (dialog = dict_self.dialog), because ScrollHtmlWidget/
		-- HtmlBoxWidget uses that reference internally whenever a swipe
		-- (change dictionary) or a scroll/pan (long definitions) triggers
		-- one of its own redraw/dirty calls. The review popup has no
		-- dict_self at all (it isn't triggered by a real lookup), so it was
		-- built with dialog = nil; ScrollHtmlWidget reaching into that nil
		-- reference during exactly those two gestures -- swipe between
		-- dictionaries, or pan/scroll a long definition -- is what crashed
		-- the whole reader. See FloatingDictionaryPopup:init() below, which
		-- now falls back to using the popup itself as the dialog whenever
		-- none was supplied, so the html widget is built with a valid,
		-- always-live reference from the start instead of nil.

		UIManager:show(review_popup)
		return true
	end

	return showReviewResult(1)
end

-- =============================================================================
-- FastDict: instant (in-process) dictionary lookups.
--
-- Hooks ReaderDictionary.rawSdcv -- a layer *below* the showDict patch this
-- plugin already installs above -- and answers exact-search lookups with
-- the in-process StarDict engine (engine.lua/stardict.lua/dictzip.lua).
-- Fuzzy searches, special query syntax, unsupported dictionaries, and any
-- engine error fall through to the original sdcv code path unchanged, so
-- this can only ever speed lookups up: the showDict patch above still sees
-- exactly the same shape of results it always did, from whichever path
-- produced them, and renders the floating popup exactly as before.
--
-- Kept as its own clearly-delimited section so it can be read/maintained
-- independently of the popup/rendering code above: nothing in this section
-- touches popup_stack, cascade state, or any display-mode logic, and
-- nothing above this line depends on FastDict being present.
-- =============================================================================

-- Shared across FloatingDictionary instances (a new instance is created per
-- document, but the rawSdcv hook -- like the showDict one above -- must
-- only ever be installed once per app run).
local fastdict_shared = {
	engine = nil,
	orig_rawSdcv = nil,
	session_disabled = false,
}

function FloatingDictionary:isFastDictEnabled()
	return G_reader_settings:nilOrTrue(SETTING_FASTDICT_ENABLED)
end

function FloatingDictionary:setFastDictEnabled(enabled)
	G_reader_settings:saveSetting(SETTING_FASTDICT_ENABLED, enabled and true or false)
	fastdict_shared.session_disabled = false
end

-- Builds (memoized) the engine for a given ReaderDictionary instance: dict
-- dirs are its data_dir plus a sibling "_ext" dir when present, matching
-- how KOReader itself locates user-installed dictionaries alongside the
-- built-in ones.
function FloatingDictionary:getFastDictEngine(rd)
	if not fastdict_shared.engine then
		local dict_dirs = { rd.data_dir }
		local dict_ext = rd.data_dir .. "_ext"
		if lfs.attributes(dict_ext, "mode") == "directory" then
			table.insert(dict_dirs, dict_ext)
		end
		local cache_dir = DataStorage:getDataDir() .. "/cache"
		util.makePath(cache_dir)
		fastdict_shared.engine = engine_mod.new({
			dict_dirs = dict_dirs,
			cache_dir = cache_dir,
		})
	end
	return fastdict_shared.engine
end

-- Installs the rawSdcv hook exactly once per app run (idempotent, like
-- patchDictionary above), regardless of how many FloatingDictionary
-- instances get init()ed across documents.
function FloatingDictionary:patchFastDict()
	if fastdict_shared.orig_rawSdcv then
		return
	end

	local ReaderDictionary = self.ui and self.ui.dictionary and self.ui.dictionary.class
	if not ReaderDictionary then
		-- Fall back to requiring the module directly: works whether or not
		-- self.ui.dictionary exposes its own class table.
		local ok, mod = pcall(require, "apps/reader/modules/readerdictionary")
		if not ok or not mod then
			logger.warn("FastDict: ReaderDictionary module not available, instant lookups disabled.")
			return
		end
		ReaderDictionary = mod
	end

	fastdict_shared.orig_rawSdcv = ReaderDictionary.rawSdcv
	local plugin = self

	ReaderDictionary.rawSdcv = function(rd, words, dict_names, fuzzy_search, lookup_progress_msg)
		if plugin:isFastDictEnabled() and not fastdict_shared.session_disabled and not fuzzy_search then
			local t0 = os.clock()
			local ok, results_or_err, reason = pcall(function()
				return plugin:getFastDictEngine(rd):lookup_words(words, dict_names)
			end)
			if ok then
				if results_or_err then
					logger.dbg(string.format(
						"FastDict: answered lookup in %.1f ms", (os.clock() - t0) * 1000))
					return false, results_or_err
				end
				logger.dbg("FastDict: deferring to sdcv:", reason)
			else
				logger.warn("FastDict: engine error, disabled for this session:", results_or_err)
				fastdict_shared.session_disabled = true
			end
		end
		return fastdict_shared.orig_rawSdcv(rd, words, dict_names, fuzzy_search, lookup_progress_msg)
	end
end

-- Builds (or rebuilds) the sidecar offset caches for every installed
-- dictionary. Runs on UIManager:nextTick so the "building…" InfoMessage
-- actually gets painted before the (potentially slow, first-run-only) scan
-- blocks the UI thread.
function FloatingDictionary:buildFastDictCaches(rebuild)
	local rd = self.ui and self.ui.dictionary
	if not rd then
		return
	end
	local info = InfoMessage:new({ text = _("FastDict: building dictionary index caches…") })
	UIManager:show(info)
	UIManager:forceRePaint()
	UIManager:nextTick(function()
		local engine = self:getFastDictEngine(rd)
		local t0 = os.clock()
		local ok, err
		if rebuild then
			ok, err = engine:rebuild_all()
		else
			ok, err = engine:build_all()
		end
		UIManager:close(info)
		if ok then
			UIManager:show(InfoMessage:new({
				text = T(_("FastDict: caches ready (%1 s)."),
					string.format("%.1f", os.clock() - t0)),
			}))
		else
			UIManager:show(InfoMessage:new({
				text = T(_("FastDict: cache build failed: %1"), tostring(err)),
			}))
		end
	end)
end

-- Radio-free (independent) submenu for FastDict, nested under "Floating
-- Dictionary" in the KOReader menu: FastDict is a lookup-speed optimization
-- layered underneath the popup/display-mode features above it, not another
-- exclusive display mode, so it gets its own toggle rather than joining the
-- Display mode radio group.
function FloatingDictionary:genFastDictMenu()
	return {
		{
			text = _("Enable instant lookups"),
			checked_func = function()
				return self:isFastDictEnabled()
			end,
			callback = function()
				self:setFastDictEnabled(not self:isFastDictEnabled())
			end,
		},
		{
			text = _("Build index caches now"),
			callback = function()
				self:buildFastDictCaches(false)
			end,
		},
		{
			text = _("Rebuild index caches"),
			callback = function()
				self:buildFastDictCaches(true)
			end,
			separator = true,
		},
		{
			text_func = function()
				if fastdict_shared.session_disabled then
					return _("Status: error — using sdcv (see log)")
				end
				if not fastdict_shared.engine then
					return _("Status: idle (loads on first lookup)")
				end
				local n_ok, n_bad = 0, 0
				for _, s in ipairs(fastdict_shared.engine:status()) do
					if s.supported then
						n_ok = n_ok + 1
					else
						n_bad = n_bad + 1
					end
				end
				return T(_("Status: %1 dictionaries via FastDict, %2 via sdcv"), n_ok, n_bad)
			end,
			keep_menu_open = true,
			callback = function() end,
		},
	}
end

return FloatingDictionary