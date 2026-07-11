--[[--
WordReview: spaced-repetition-style "word of the day" companion for the
Floating Dictionary plugin.

Every time the user opens a book, WordReview shows one word from that book's
own lookup history (favoring, but not restricting itself to, words looked up
more often), using the exact same floating popup the plugin already uses for
normal lookups. If the book has no lookup history yet (first ever open, or no
searches performed so far), it falls back to a random entry from the user's
installed dictionaries, so there is always something useful to see.

Kept in its own module (separate from main.lua) so it can be reasoned about,
tested, and extended independently -- e.g. a future spaced-repetition
scheduler, streaks, or export can be layered on top of the same history file
without touching the popup/rendering code in main.lua at all.

Persistence: one plain Lua-table history file per book, stored inside that
book's own .sdr sidecar directory (via DocSettings:getSidecarDir), exactly
like every other piece of per-book KOReader state. Uses the same dump/loadfile
approach as DocSettings itself, so no extra dependency is introduced.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local datetime = require("datetime")
local Device = require("device")
local DocSettings = require("docsettings")
local dump = require("dump")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local lfs = require("libs/libkoreader-lfs")
local LineWidget = require("ui/widget/linewidget")
local logger = require("logger")
local RenderText = require("ui/rendertext")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local util = require("util")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local T = require("ffi/util").template
local _ = require("l10n").gettext

local Screen = Device.screen

local WordReview = {}

-------------------------------------------------------------------------------
-- Kindle Vocabulary Builder-style UI kit
-------------------------------------------------------------------------------
--
-- Everything in this section is purely cosmetic plumbing for the "Word
-- Review" list screen and the "Flashcards" screen below (see
-- showManageWordsScreen / showFlashcardsScreen further down this file). No
-- data logic lives here: these helpers only ever take already-computed rows/
-- strings/callbacks and turn them into thin-bordered, sharp-cornered,
-- shadow-free widgets in the spirit of Kindle's Vocabulary Builder --
-- deliberately plain so the screen reads as a native KOReader tool rather
-- than an app-like overlay.
local UI_FONT_SIZE = 20
local HAIRLINE = Size.border.thin or math.max(1, Screen:scaleBySize(1))
local COLOR_LINE = Blitbuffer.COLOR_GRAY
local COLOR_MUTED = Blitbuffer.COLOR_GRAY
-- Shared color for the two nav/action labels that must always read as the
-- same visual weight ("Exit Flashcards" and "Mark as Mastered" -- see the
-- header of showFlashcardsScreen below). Kept as one explicit constant,
-- rather than each button separately defaulting to the widget's own
-- default color, so the two can never drift apart again.
local COLOR_NAV_TEXT = Blitbuffer.COLOR_BLACK

local SIDE_MARGIN = Screen:scaleBySize(18)
local TOP_BAR_HEIGHT = Screen:scaleBySize(44)
local SUBBAR_HEIGHT = Screen:scaleBySize(34)
local BOTTOM_BUTTON_HEIGHT = Screen:scaleBySize(54)
local SECTION_GAP = Screen:scaleBySize(8)

-- Kindle Vocabulary Builder-style word grid: fixed number of equal-width
-- columns, each word inside a short horizontal rectangle (barely taller
-- than the word itself) rather than a square -- word boxes never resize to
-- fit their content (see fitWordInBox below, which truncates instead).
local GRID_COLS = 3
local GRID_GAP = Screen:scaleBySize(10)

-- Wraps an already-built widget (anything with a getSize()) so it becomes
-- tappable/holdable, without pulling in a whole custom widget class per
-- button. Mirrors the same dimen-from-getSize()-only convention already used
-- by every other ad-hoc tappable widget in this plugin (see main.lua's
-- PreviewButton), so it behaves identically once placed by a parent
-- container/UIManager.
local function wrapTappable(widget, callback, hold_callback)
	if not callback and not hold_callback then
		return widget
	end
	local wrapper = InputContainer:new({
		dimen = widget:getSize(),
		widget,
	})
	wrapper.ges_events = {}
	if callback then
		wrapper.ges_events.Tap = {
			GestureRange:new({ ges = "tap", range = wrapper.dimen }),
		}
		wrapper.onTap = function()
			callback()
			return true
		end
	end
	if hold_callback then
		wrapper.ges_events.Hold = {
			GestureRange:new({ ges = "hold", range = wrapper.dimen }),
		}
		wrapper.onHold = function()
			hold_callback()
			return true
		end
	end
	return wrapper
end

-- Same idea as wrapTappable, but for a horizontal swipe gesture -- used to
-- flip between installed dictionaries in the Flashcards "See Definition"
-- view (see showFlashcardsScreen below), the same gesture KOReader's own
-- dictionary popup uses for the same purpose.
local function wrapSwipeable(widget, on_swipe_left, on_swipe_right)
	local wrapper = InputContainer:new({
		dimen = widget:getSize(),
		widget,
	})
	wrapper.ges_events = {
		Swipe = { GestureRange:new({ ges = "swipe", range = wrapper.dimen }) },
	}
	wrapper.onSwipe = function(_, _, ges)
		if ges.direction == "west" and on_swipe_left then
			on_swipe_left()
		elseif ges.direction == "east" and on_swipe_right then
			on_swipe_right()
		end
		return true
	end
	return wrapper
end

local function hairline(width, color)
	return LineWidget:new({
		background = color or COLOR_LINE,
		dimen = Geom:new({ w = width, h = HAIRLINE }),
	})
end

-- Lays `left` and `right` out at the opposite ends of a `width`-wide row,
-- vertically centered to `height` -- the building block for every header/
-- sub-bar row in both screens below (title + close, "Words" + filter,
-- "Exit Flashcards" + "Words mastered", card header, etc).
local function edgeRow(left, right, width, height)
	local left_size = left and left:getSize() or { w = 0, h = 0 }
	local right_size = right and right:getSize() or { w = 0, h = 0 }
	local gap_w = math.max(0, width - left_size.w - right_size.w)
	local widgets = {}
	if left then
		table.insert(widgets, CenterContainer:new({ dimen = Geom:new({ w = left_size.w, h = height }), left }))
	end
	table.insert(widgets, HorizontalSpan:new({ width = gap_w }))
	if right then
		table.insert(widgets, CenterContainer:new({ dimen = Geom:new({ w = right_size.w, h = height }), right }))
	end
	return HorizontalGroup:new(widgets)
end

-- Same idea as edgeRow, but with a third, horizontally-centered piece in the
-- middle (e.g. the "Word Review" title, flanked by the menu icon and the ✕
-- close button) -- the remaining width is split so the center widget is
-- always dead-center of the full `width`, regardless of how wide the two
-- side widgets are.
local function threeRow(left, center, right, width, height)
	local left_w = left and left:getSize().w or 0
	local right_w = right and right:getSize().w or 0
	local center_w = math.max(0, width - left_w - right_w)
	return HorizontalGroup:new({
		CenterContainer:new({ dimen = Geom:new({ w = left_w, h = height }), left or HorizontalSpan:new({ width = 0 }) }),
		CenterContainer:new({ dimen = Geom:new({ w = center_w, h = height }), center }),
		CenterContainer:new({ dimen = Geom:new({ w = right_w, h = height }), right or HorizontalSpan:new({ width = 0 }) }),
	})
end

-- A plain, borderless piece of tappable text (title-bar icons, "Words",
-- filter labels, "See Definition", "Mark as Mastered", arrows, ...). Kept
-- deliberately text-only -- no icon glyphs, no background chip -- to match
-- the flat, native-reader look the redesign asks for.
local function textButton(text, size, bold, color, callback, hold_callback)
	local widget = TextWidget:new({
		text = text,
		face = Font:getFace("cfont", size or UI_FONT_SIZE),
		bold = bold,
		fgcolor = color,
	})
	return wrapTappable(widget, callback, hold_callback)
end

-- Fits `word` inside `max_w` pixels at `face`, never growing the box to
-- accommodate it: if it doesn't fit as-is, it's cut down and a literal
-- "..." is appended (e.g. "automatic" -> "automati...", never the
-- single-glyph "…" RenderText would otherwise use), so every box in the
-- grid keeps exactly the same footprint no matter how long the word is.
local ELLIPSIS = "..."
local function fitWordInBox(word, face, max_w)
	if not word or word == "" then return word end
	local full_w = RenderText:sizeUtf8Text(0, nil, face, word).x
	if full_w <= max_w then
		return word
	end
	local dots_w = RenderText:sizeUtf8Text(0, nil, face, ELLIPSIS).x
	local budget = math.max(0, max_w - dots_w)
	local sub = RenderText:getSubTextByWidth(word, face, budget, false, false)
	return sub .. ELLIPSIS
end

-- Picks the largest font size (from max_size down to min_size) at which
-- `text` still fits within `max_w` at `font_name` -- used for the
-- Flashcards card's headline word (see showFlashcardsScreen below) so a
-- long word shrinks to stay on one line and fully readable instead of
-- ever overflowing the card horizontally (which fitWordInBox's ellipsis
-- truncation would otherwise do -- undesirable here since the whole point
-- of the card is to show the complete word).
local function fitFaceToWidth(text, font_name, max_w, max_size, min_size)
	local size = max_size
	while size > min_size do
		local face = Font:getFace(font_name, size)
		if RenderText:sizeUtf8Text(0, nil, face, text or "").x <= max_w then
			return face, size
		end
		size = size - 1
	end
	return Font:getFace(font_name, min_size), min_size
end

-- Lays any number of items out as equal-width tabs across `width` (the last
-- tab absorbs any leftover pixel from integer division) -- used for the
-- Words / Random / Mastered pestañas below, so all three always look and
-- behave like one consistent set of navigation buttons.
local function tabRow(items, width, height)
	local seg_w = math.floor(width / #items)
	local widgets = {}
	for i, item in ipairs(items) do
		local w = (i == #items) and (width - seg_w * (#items - 1)) or seg_w
		table.insert(widgets, CenterContainer:new({ dimen = Geom:new({ w = w, h = height }), item }))
	end
	return HorizontalGroup:new(widgets)
end

-- A single word-list box: a thin-bordered, sharp-cornered horizontal
-- rectangle exactly `box_w` by `box_h` (box_h just tall enough for one line
-- of text -- see the caller, which derives it from the label's own font
-- metrics), the word centered inside, with a small muted checkmark in the
-- corner when the word has been marked as mastered (row.mastered) -- the
-- "discreet" mastered indicator asked for. The box itself never resizes for
-- long words -- see fitWordInBox above, which truncates the label instead
-- so every box in the grid stays identical. `dimmed` greys the row out
-- while it's selected in multi-select mode, the same visual convention
-- KOReader's own Menu uses for selected items.
local function buildWordRow(row, box_w, box_h, dimmed, callback, hold_callback)
	local inner_w = box_w - 2 * HAIRLINE
	local inner_h = box_h - 2 * HAIRLINE

	local label_face = Font:getFace("cfont", UI_FONT_SIZE - 1)
	local mark_w = 0
	local mark
	if row.mastered then
		mark = TextWidget:new({
			text = "✓",
			face = Font:getFace("cfont", UI_FONT_SIZE - 4),
			fgcolor = COLOR_MUTED,
		})
		mark_w = mark:getSize().w + Screen:scaleBySize(10)
	end

	local label_max_w = math.max(0, inner_w - mark_w - Screen:scaleBySize(8))
	local label = TextWidget:new({
		text = fitWordInBox(row.word, label_face, label_max_w),
		face = label_face,
		fgcolor = dimmed and COLOR_MUTED or Blitbuffer.COLOR_BLACK,
	})

	local content
	if mark then
		content = HorizontalGroup:new({
			CenterContainer:new({ dimen = Geom:new({ w = inner_w - mark_w, h = inner_h }), label }),
			CenterContainer:new({ dimen = Geom:new({ w = mark_w, h = inner_h }), mark }),
		})
	else
		content = CenterContainer:new({ dimen = Geom:new({ w = inner_w, h = inner_h }), label })
	end

	local frame = FrameContainer:new({
		background = dimmed and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
		bordersize = HAIRLINE,
		color = COLOR_LINE,
		radius = 0,
		padding = 0,
		content,
	})

	return wrapTappable(frame, callback, hold_callback)
end

-- Strips the target word down to just its letters/digits, lowercased, so it
-- can be compared against a word encountered inside a paragraph regardless
-- of surrounding punctuation or case (e.g. "them," or "Them" both match
-- "them").
local function normalizeForMatch(str)
	return (str or ""):lower():gsub("[^%w]", "")
end

-- Renders `text` word-wrapped inside `width`, exactly like a plain
-- TextBoxWidget would, except that any token whose letters match
-- `target_word` (case/punctuation-insensitive) is drawn in italics instead
-- of the regular face -- e.g. with target_word = "them":
--   "I really need them," said Amy decidedly.
-- becomes the same sentence with only "them" in italics, everything else
-- untouched. Falls back to a plain TextBoxWidget if no italic face is
-- available or no token matches, so this never breaks rendering.
-- `centered`, when true, horizontally centers each wrapped line within
-- `width` instead of the default left alignment -- used by the Flashcards
-- card (see showFlashcardsScreen below) to keep the context paragraph
-- visually centered together with the word above it, per the card's
-- centered layout.
local function buildHighlightedParagraph(text, target_word, width, face, italic_face, fgcolor, centered)
	local plain_alignment = centered and "center" or "left"
	if not text or text == "" then
		return TextBoxWidget:new({ text = "", face = face, width = width, alignment = plain_alignment, fgcolor = fgcolor })
	end

	local target_norm = normalizeForMatch(target_word)
	if not italic_face or not target_norm or target_norm == "" then
		return TextBoxWidget:new({ text = text, face = face, width = width, alignment = plain_alignment, fgcolor = fgcolor })
	end

	local space_w = RenderText:sizeUtf8Text(0, nil, face, " ").x
	local line_h = 0
	local tokens = {}
	for token in text:gmatch("%S+") do
		-- The looked-up word itself is shown in italics AND bold, so it
		-- stands out clearly from the rest of the context paragraph.
		local is_target = normalizeForMatch(token) == target_norm
		local use_face = is_target and italic_face or face
		-- Safety clamp: an unusually long single token (a long compound
		-- word, a URL, ...) that's wider than the whole available width on
		-- its own would otherwise sit on its own line and still overflow
		-- it -- truncate it (same ellipsis convention as fitWordInBox)
		-- rather than ever letting a line exceed `width`.
		local display_token = fitWordInBox(token, use_face, width)
		local widget = TextWidget:new({ text = display_token, face = use_face, fgcolor = fgcolor, bold = is_target or nil })
		local size = widget:getSize()
		line_h = math.max(line_h, size.h)
		table.insert(tokens, { widget = widget, w = size.w })
	end

	local lines = {}
	local current_line, current_w = {}, 0
	for _, tok in ipairs(tokens) do
		local added_w = (#current_line > 0 and (current_w + space_w) or current_w) + tok.w
		if #current_line > 0 and added_w > width then
			table.insert(lines, current_line)
			current_line, current_w = { tok }, tok.w
		else
			if #current_line > 0 then current_w = current_w + space_w end
			table.insert(current_line, tok)
			current_w = current_w + tok.w
		end
	end
	if #current_line > 0 then table.insert(lines, current_line) end

	local line_groups = {}
	for i, line in ipairs(lines) do
		local pieces = {}
		for j, tok in ipairs(line) do
			table.insert(pieces, tok.widget)
			if j < #line then
				table.insert(pieces, HorizontalSpan:new({ width = space_w }))
			end
		end
		local line_group = HorizontalGroup:new(pieces)
		if centered then
			line_group = CenterContainer:new({ dimen = Geom:new({ w = width, h = line_h }), line_group })
		end
		table.insert(line_groups, line_group)
		if i < #lines then
			table.insert(line_groups, VerticalSpan:new({ width = Screen:scaleBySize(4) }))
		end
	end

	return VerticalGroup:new(line_groups)
end

-- Best-effort plain-text flattening of the sdcv-style dictionary results
-- returned by ReaderDictionary:startSdcv (see showFlashcardsScreen's
-- seeDefinition below) -- strips the light HTML markup those definitions
-- normally carry so it can be dropped straight into a plain TextBoxWidget,
-- the same widget already used for the context paragraph.
local function stripHtml(text)
	if not text then return "" end
	text = text:gsub("<[^>]*>", "")
	text = text:gsub("&nbsp;", " ")
	text = text:gsub("&amp;", "&")
	text = text:gsub("&lt;", "<")
	text = text:gsub("&gt;", ">")
	text = text:gsub("&quot;", "\"")
	text = text:gsub("&#39;", "'")
	return text:gsub("^%s+", ""):gsub("%s+$", "")
end

-- Full-bleed, single-purpose screen container shared by both the word list
-- and the flashcards view: white background, no title bar of its own (each
-- caller builds its own header row as part of `body`), closes on outside
-- tap/Back key, same convention as every other full-screen panel already in
-- this plugin.
local FullScreenPanel = InputContainer:extend({
	body = nil,
	close_callback = nil,
	-- Optional: the ScrollableContainer instance embedded in `body`, if any
	-- (see the word grid in showManageWordsScreen below). ScrollableContainer
	-- looks this up via its show_parent to redraw only the scrolled region
	-- instead of the whole screen.
	cropping_widget = nil,
})

function FullScreenPanel:init()
	local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
	-- Deliberately no whole-screen "tap to close" gesture here: unlike a
	-- centered popup card, this panel covers the entire screen, so there is
	-- no "outside" region to tap -- and grabbing the whole area would steal
	-- taps meant for the rows/buttons inside `body`. Closing happens only
	-- through each screen's own explicit close target (the ✕/"Exit
	-- Flashcards" button built into `body`) or the Back key below.
	if Device:hasKeys() then
		self.key_events = { Close = { { Device.input.group.Back } } }
	end
	self.covers_fullscreen = true
	self[1] = FrameContainer:new({
		background = Blitbuffer.COLOR_WHITE,
		bordersize = 0,
		padding = 0,
		width = screen_w,
		height = screen_h,
		self.body,
	})
	self.dimen = Geom:new({ x = 0, y = 0, w = screen_w, h = screen_h })
end

function FullScreenPanel:onShow()
	UIManager:setDirty(self, "full")
end

function FullScreenPanel:onCloseWidget()
	UIManager:setDirty(nil, "full")
end

function FullScreenPanel:onClose()
	UIManager:close(self)
	if self.close_callback then
		self.close_callback()
	end
	return true
end

WordReview.HISTORY_FILENAME = "wordreview_history.lua"

-- Persisted, user-facing toggles: whether the review popup should be shown
-- automatically when a book is opened, and/or whenever KOReader wakes up
-- from suspend. Two fully independent settings -- either, both, or neither
-- can be on at once. Off by default would defeat the point of a discovery
-- feature, so both default to *on* (nilOrTrue), same convention as every
-- other boolean setting in this plugin.
WordReview.SETTING_ENABLED_ON_OPEN = "floatingdictionary_wordreview_on_open"
WordReview.SETTING_ENABLED_ON_RESUME = "floatingdictionary_wordreview_on_resume"

-- Where review words are allowed to come from. Three independent modes:
--   "saved"  -- only words the user explicitly added via the small
--              selection menu's "Save for review" button (see
--              main.lua:addSelectionToWordReview / recordLookup below).
--   "random" -- only random headwords pulled from the installed
--              dictionaries (pickFallbackWord), same as this feature's
--              original behavior.
--   "both"   -- try the user's saved words first, falling back to a random
--              headword when there's nothing saved yet for this book.
-- Defaults to "both" so the feature still shows something useful before the
-- user has manually saved any word.
WordReview.SETTING_REVIEW_SOURCE_MODE = "floatingdictionary_wordreview_source_mode"
WordReview.SOURCE_MODE_SAVED = "saved"
WordReview.SOURCE_MODE_RANDOM = "random"
WordReview.SOURCE_MODE_BOTH = "both"

local VALID_SOURCE_MODES = {
	[WordReview.SOURCE_MODE_SAVED] = true,
	[WordReview.SOURCE_MODE_RANDOM] = true,
	[WordReview.SOURCE_MODE_BOTH] = true,
}

function WordReview:getReviewSourceMode()
	local saved = G_reader_settings:readSetting(self.SETTING_REVIEW_SOURCE_MODE)
	if type(saved) == "string" and VALID_SOURCE_MODES[saved] then
		return saved
	end
	return self.SOURCE_MODE_BOTH
end

function WordReview:setReviewSourceMode(mode)
	if not VALID_SOURCE_MODES[mode] then
		mode = self.SOURCE_MODE_BOTH
	end
	G_reader_settings:saveSetting(self.SETTING_REVIEW_SOURCE_MODE, mode)
end

-- How many words to consider "first-run/no-history" fallback candidates in
-- one go when picking a random dictionary entry (see pickFallbackWord).
local FALLBACK_SAMPLE_ATTEMPTS = 6

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

function WordReview:isEnabledOnOpen()
	return G_reader_settings:nilOrTrue(self.SETTING_ENABLED_ON_OPEN)
end

function WordReview:setEnabledOnOpen(enabled)
	G_reader_settings:saveSetting(self.SETTING_ENABLED_ON_OPEN, enabled and true or false)
end

function WordReview:isEnabledOnResume()
	return G_reader_settings:nilOrTrue(self.SETTING_ENABLED_ON_RESUME)
end

function WordReview:setEnabledOnResume(enabled)
	G_reader_settings:saveSetting(self.SETTING_ENABLED_ON_RESUME, enabled and true or false)
end

-- Menu items for the "Word review" submenu, to be nested under the plugin's
-- existing "Floating Dictionary" menu (see main.lua:addToMainMenu). Two
-- independent checkboxes, one per trigger, so the user can enable either,
-- both, or neither.
--
-- `plugin` is the FloatingDictionary instance (same object every other
-- WordReview method expects), needed here so the "Manage saved words" entry
-- below can open its screen with access to plugin.ui (to resolve the
-- currently open book, if any -- see getKnownBookFiles).
function WordReview:genMenu(plugin)
	return {
		{
			text = _("Manage saved words"),
			keep_menu_open = true,
			callback = function()
				self:showManageWordsScreen(plugin)
			end,
			separator = true,
		},
		{
			text = _("Show review word when opening a book"),
			checked_func = function()
				return self:isEnabledOnOpen()
			end,
			callback = function()
				self:setEnabledOnOpen(not self:isEnabledOnOpen())
			end,
		},
		{
			text = _("Show review word when waking from sleep"),
			checked_func = function()
				return self:isEnabledOnResume()
			end,
			callback = function()
				self:setEnabledOnResume(not self:isEnabledOnResume())
			end,
			separator = true,
		},
		{
			text_func = function()
				local mode = self:getReviewSourceMode()
				local label = _("Both")
				if mode == self.SOURCE_MODE_SAVED then
					label = _("Only saved words")
				elseif mode == self.SOURCE_MODE_RANDOM then
					label = _("Only random words")
				end
				return T(_("Word source: %1"), label)
			end,
			sub_item_table = {
				{
					text = _("Only saved words"),
					radio = true,
					checked_func = function()
						return self:getReviewSourceMode() == self.SOURCE_MODE_SAVED
					end,
					callback = function()
						self:setReviewSourceMode(self.SOURCE_MODE_SAVED)
					end,
				},
				{
					text = _("Only random words"),
					radio = true,
					checked_func = function()
						return self:getReviewSourceMode() == self.SOURCE_MODE_RANDOM
					end,
					callback = function()
						self:setReviewSourceMode(self.SOURCE_MODE_RANDOM)
					end,
				},
				{
					text = _("Both"),
					radio = true,
					checked_func = function()
						return self:getReviewSourceMode() == self.SOURCE_MODE_BOTH
					end,
					callback = function()
						self:setReviewSourceMode(self.SOURCE_MODE_BOTH)
					end,
				},
			},
		},
	}
end

-------------------------------------------------------------------------------
-- Per-book history storage
-------------------------------------------------------------------------------

-- Returns the .sdr sidecar directory for the currently open document, or nil
-- if there isn't one (e.g. no document, or a document without a real file
-- path, such as some synthetic/virtual documents).
function WordReview:getSidecarDir(plugin)
	local doc = plugin.ui and plugin.ui.document
	local file = doc and doc.file
	if not file or file == "" then
		return nil
	end

	local ok, dir = pcall(function()
		return DocSettings:getSidecarDir(file)
	end)
	if not ok or not dir or dir == "" then
		return nil
	end
	return dir
end

function WordReview:getHistoryPath(plugin)
	local sidecar_dir = self:getSidecarDir(plugin)
	if not sidecar_dir then
		return nil
	end
	return sidecar_dir .. "/" .. self.HISTORY_FILENAME
end

-- Loads { words = { [normalized_word] = { word = "...", count = n, last_ts = n } } }
-- from disk. Always returns a well-formed table, even if nothing has ever
-- been saved yet or the file is missing/corrupt (never errors out to callers).
function WordReview:loadHistory(plugin)
	local path = self:getHistoryPath(plugin)
	if not path or lfs.attributes(path, "mode") ~= "file" then
		return { words = {} }
	end

	local ok, chunk_or_err = pcall(loadfile, path)
	if not ok or not chunk_or_err then
		logger.warn("WordReview: failed to load history file:", path, chunk_or_err)
		return { words = {} }
	end

	local ok2, data = pcall(chunk_or_err)
	if not ok2 or type(data) ~= "table" then
		logger.warn("WordReview: history file did not evaluate to a table:", path)
		return { words = {} }
	end

	if type(data.words) ~= "table" then
		data.words = {}
	end

	return data
end

function WordReview:saveHistory(plugin, history)
	local sidecar_dir = self:getSidecarDir(plugin)
	if not sidecar_dir then
		return false
	end

	local ok_dir = pcall(function()
		DocSettings:ensureSidecar(sidecar_dir)
	end)
	if not ok_dir then
		-- Fall back to a manual mkdir if DocSettings:ensureSidecar isn't
		-- available on this KOReader version for some reason.
		if lfs.attributes(sidecar_dir, "mode") ~= "directory" then
			pcall(lfs.mkdir, sidecar_dir)
		end
	end

	local path = self:getHistoryPath(plugin)
	if not path then
		return false
	end

	local serialized, err = dump(history)
	if not serialized then
		logger.warn("WordReview: failed to serialize history:", err)
		return false
	end

	local tmp_path = path .. ".tmp"
	local f, open_err = io.open(tmp_path, "w")
	if not f then
		logger.warn("WordReview: failed to open history file for writing:", tmp_path, open_err)
		return false
	end
	f:write("return ")
	f:write(serialized)
	f:close()

	-- Atomic-ish replace: write to a temp file first, then rename over the
	-- real one, so a crash mid-write never leaves a half-written, unreadable
	-- history file behind.
	local ok_rename = os.rename(tmp_path, path)
	if not ok_rename then
		logger.warn("WordReview: failed to replace history file:", path)
		os.remove(tmp_path)
		return false
	end

	return true
end

-- Normalizes a word for use as a history key: trimmed and lowercased, so
-- e.g. "Casa" and "casa" (or trailing punctuation from a fuzzy selection)
-- collapse into the same history entry instead of silently fragmenting the
-- count across near-duplicate keys.
function WordReview:normalizeKey(word)
	word = tostring(word or "")
	if util and util.stripPunctuation then
		local ok, stripped = pcall(util.stripPunctuation, word)
		if ok and stripped then
			word = stripped
		end
	end
	word = word:match("^%s*(.-)%s*$") or word
	return word:lower()
end

-- Records (or updates) a single manually-saved word. Unlike the original
-- version of this feature, this is now called ONLY from the small selection
-- menu's dedicated "Save for review" button (see main.lua:
-- addSelectionToWordReview) -- never automatically on every dictionary
-- lookup. This is the single point of truth for the book's saved-word list,
-- so it always stays in sync with what the user actually chose to keep.
-- `context`, if given, is a short snippet of surrounding text captured at
-- save time (see main.lua:FloatingDictionary:getSelectionContext) -- purely
-- informational, shown by the "Manage saved words" screen so the user can
-- remember where/how they encountered the word. Optional and best-effort:
-- a nil/empty context here just means none was available for this save
-- (e.g. no live text selection behind it), never an error condition.
function WordReview:recordLookup(plugin, word, context)
	if not word or word == "" then
		return
	end

	local key = self:normalizeKey(word)
	if key == "" then
		return
	end

	if context and context == "" then
		context = nil
	end

	local history = self:loadHistory(plugin)
	local entry = history.words[key]
	if entry then
		entry.count = (entry.count or 1) + 1
		entry.last_ts = os.time()
		-- Keep the most recently-seen casing/spelling as the display form;
		-- purely cosmetic, doesn't affect the key or the count.
		entry.word = word
		-- Refresh the context to the most recent occurrence when one was
		-- captured this time; if this particular save didn't manage to
		-- capture one (context == nil), keep whatever was already stored
		-- rather than erasing it.
		if context then
			entry.context = context
		end
	else
		history.words[key] = {
			word = word,
			count = 1,
			last_ts = os.time(),
			context = context,
		}
	end

	self:saveHistory(plugin, history)
end

-------------------------------------------------------------------------------
-- Word selection
-------------------------------------------------------------------------------

-- Weighted-but-varied pick from the book's history: frequently-looked-up
-- words get a modestly higher chance of being chosen, without ever
-- guaranteeing they always win, so review stays a mix of old favorites and
-- rarer words instead of endlessly repeating the single most-searched word.
--
-- Approach: each entry's weight is 1 + log(count), rather than count itself.
-- A word queried 12 times against others queried once would be ~13x more
-- likely under a raw-count scheme (which the person explicitly said they
-- don't want); under 1 + ln(count) it's only about 1 + ln(12) ≈ 3.5x more
-- likely than a weight-1 word -- noticeably favored, but far from dominant,
-- and the gap shrinks further (proportionally) as more words accumulate
-- history. This keeps the distribution gentle at both small and large
-- history sizes without needing any hand-tuned cap.
function WordReview:pickFromHistory(history)
	local entries = {}
	local keys = {}
	for key, entry in pairs(history.words or {}) do
		table.insert(entries, entry)
		table.insert(keys, key)
	end

	if #entries == 0 then
		return nil
	end

	local weights = {}
	local total_weight = 0
	for i, entry in ipairs(entries) do
		local count = math.max(1, tonumber(entry.count) or 1)
		local weight = 1 + math.log(count)
		weights[i] = weight
		total_weight = total_weight + weight
	end

	local roll = math.random() * total_weight
	local running = 0
	for i, entry in ipairs(entries) do
		running = running + weights[i]
		if roll <= running then
			return entry, keys[i]
		end
	end

	-- Floating point safety net: should be unreachable, but guarantees a
	-- word is always returned rather than nil if rounding ever leaves a
	-- sliver of `roll` unaccounted for.
	return entries[#entries], keys[#entries]
end

-- Locates the on-disk .ifo file for a given dictionary display name (the
-- same "bookname=" value getInstalledDictionaryNames reads), by scanning the
-- same data directories that function already knows about. Kept here as a
-- small, self-contained scan using only lfs/io, rather than reusing any
-- internal FastDict engine state this module has no visibility into.
local function findIfoFileForDictionary(data_dirs, wanted_bookname)
	local function scanDir(path)
		local ok, iter, dir_obj = pcall(lfs.dir, path)
		if not ok then
			return nil
		end
		for name in iter, dir_obj do
			if name ~= "." and name ~= ".." and name ~= "res" then
				local fullpath = path .. "/" .. name
				local attr = lfs.attributes(fullpath)
				if attr and attr.mode == "directory" then
					local found = scanDir(fullpath)
					if found then
						return found
					end
				elseif attr and attr.mode == "file" and fullpath:match("%.ifo$") then
					local f = io.open(fullpath, "r")
					if f then
						local content = f:read("*all")
						f:close()
						local bookname = content:match("\nbookname=(.-)\r?\n")
							or content:match("^bookname=(.-)\r?\n")
						if bookname == wanted_bookname then
							return fullpath
						end
					end
				end
			end
		end
		return nil
	end

	for _, dir in ipairs(data_dirs) do
		local found = scanDir(dir)
		if found then
			return found
		end
	end
	return nil
end

-- Reads a random headword straight out of an *uncompressed* StarDict .idx
-- file (format: repeated [word]\0[offset:4 bytes][size:4 bytes], per the
-- StarDict file format spec). Only handles this one, common, uncompressed
-- layout deliberately -- compressed .idx.gz indexes or 64-bit-offset
-- variants are simply skipped (return nil) rather than guessed at, since
-- getting the binary layout wrong would silently produce garbage "words".
-- This only ever needs to return *a* plausible word to look up through the
-- normal, already-robust startSdcv path below, so skipping unsupported
-- variants in favor of trying the next dictionary is perfectly safe.
local function randomWordFromIdx(ifo_path)
	local idx_path = ifo_path:gsub("%.ifo$", ".idx")
	if lfs.attributes(idx_path, "mode") ~= "file" then
		return nil -- likely a compressed .idx.gz variant; not handled here
	end

	local f = io.open(idx_path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*all")
	f:close()
	if not data or #data == 0 then
		return nil
	end

	-- Collect the byte offset of the start of every entry's word string, by
	-- scanning for word\0 followed by 8 more bytes (offset+size) and
	-- advancing past each entry as we go. Bails out (returns nil) on any
	-- unexpected structure rather than risking a runaway loop or reading
	-- past the end of the buffer.
	local positions = {}
	local pos = 1
	local len = #data
	local guard = 0
	while pos <= len do
		guard = guard + 1
		if guard > 2000000 then
			break -- sanity cap; should never trigger on a real dictionary
		end
		local nul_pos = data:find("\0", pos, true)
		if not nul_pos then
			break
		end
		local word_len = nul_pos - pos
		if word_len <= 0 or word_len > 512 then
			-- Not a plausible headword length for this format; treat the
			-- whole file as unsupported/unrecognized rather than guessing.
			return nil
		end
		table.insert(positions, pos)
		pos = nul_pos + 1 + 8 -- skip the NUL + 4-byte offset + 4-byte size
	end

	if #positions == 0 then
		return nil
	end

	local chosen_pos = positions[math.random(1, #positions)]
	local nul_pos = data:find("\0", chosen_pos, true)
	if not nul_pos then
		return nil
	end
	local word = data:sub(chosen_pos, nul_pos - 1)
	if not word or word == "" then
		return nil
	end
	return word
end

-- First-run / empty-history fallback: picks a genuinely random headword out
-- of one of the user's installed dictionaries, so the feature always shows
-- *something* useful even before the user has looked up a single word in
-- this book. Tries a handful of times, and a handful of dictionaries, before
-- giving up -- dictionaries with a compressed or otherwise-unsupported index
-- are simply skipped in favor of the next one.
--
-- Returns { word = "...", from_fallback = true } or nil if no dictionary
-- could produce anything at all (e.g. no dictionaries installed, or only
-- compressed-index ones present).
function WordReview:pickFallbackWord(plugin)
	local rd = plugin.ui and plugin.ui.dictionary
	if not rd then
		return nil
	end

	local data_dirs = { rd.data_dir }
	if rd.data_dir then
		local ext_dir = rd.data_dir .. "_ext"
		if lfs.attributes(ext_dir, "mode") == "directory" then
			table.insert(data_dirs, ext_dir)
		end
	end

	-- Respects the user's configured dictionary priority order: dictionaries
	-- are tried in that exact order (rather than picked uniformly at random
	-- across all installed dictionaries), so which dictionary the fallback
	-- word happens to come from is consistent with the rest of the plugin's
	-- behavior, even though the word itself is randomly chosen.
	local order = plugin:getDictionaryOrderSetting()

	for _ = 1, FALLBACK_SAMPLE_ATTEMPTS do
		for _, dict_name in ipairs(order) do
			local ok, ifo_path = pcall(findIfoFileForDictionary, data_dirs, dict_name)
			if ok and ifo_path then
				local ok2, word = pcall(randomWordFromIdx, ifo_path)
				if ok2 and word and word ~= "" then
					return { word = word, from_fallback = true }
				end
			end
		end
	end

	return nil
end

-- Top-level entry point: returns { word = "...", from_fallback = bool,
-- history_key = "..." or nil } for the word to review right now, or nil if
-- nothing could be found at all (no history and no usable dictionary -- an
-- edge case, but handled so the caller can simply skip showing anything
-- rather than crash). history_key is only set when the word came from this
-- book's history (never for a fallback pick), and lets maybeShowReview
-- correct that entry in place if the dictionary resolves it to a different
-- headword (see the migration comment in maybeShowReview).
--
-- Which sources are even tried is gated by getReviewSourceMode():
--   * SOURCE_MODE_RANDOM skips the saved-history lookup entirely, going
--     straight to a random dictionary word every time.
--   * SOURCE_MODE_SAVED never falls back to a random word -- if the user
--     hasn't manually saved anything yet (via the small selection menu's
--     "Save for review" button), this simply returns nil and no review
--     popup is shown at all, rather than silently substituting a random
--     word the user didn't ask for.
--   * SOURCE_MODE_BOTH (default) is the original behavior: prefer a saved
--     word, fall back to random when there isn't one yet.
function WordReview:pickWordToReview(plugin)
	local mode = self:getReviewSourceMode()

	if mode ~= self.SOURCE_MODE_RANDOM then
		local history = self:loadHistory(plugin)
		local from_history, history_key = self:pickFromHistory(history)
		if from_history then
			return { word = from_history.word, from_fallback = false, history_key = history_key }
		end
	end

	if mode == self.SOURCE_MODE_SAVED then
		return nil
	end

	return self:pickFallbackWord(plugin)
end

-------------------------------------------------------------------------------
-- Triggering the review popup on book open
-------------------------------------------------------------------------------

-- Lazily migrates one history entry from an old, inflected-form key/word
-- (e.g. "sensata", saved before this fix) to the real dictionary headword
-- the current lookup just resolved to (e.g. "sensatez"). Called only right
-- after a *successful* real lookup for a word that came from this book's own
-- history (never for a fallback pick, which has no history entry to begin
-- with), so it always has a freshly-confirmed-good replacement in hand.
--
-- Deliberately incremental rather than a one-time bulk pass over every
-- book's history file: it piggybacks on a lookup that's already happening
-- (review picked this word, so it was already being searched), costs
-- nothing extra, and self-heals the file a little more each time a
-- previously-mis-recorded word happens to come up for review again. A word
-- that never comes up again simply keeps its old form forever -- harmless,
-- since it only means that one entry doesn't benefit from the fix, not that
-- anything breaks.
--
-- Preserves count/last_ts (this is a correction, not a new lookup) and, if
-- the resolved word normalizes to a key that already exists (e.g. two old
-- entries both actually resolve to the same headword), merges into that
-- entry instead of overwriting it, summing counts and keeping the more
-- recent last_ts -- so no history is silently lost to a collision.
--
-- old_word is the exact word this lookup was actually performed for
-- (choice.word); old_key must still resolve, via normalizeKey, to that same
-- word, and the entry stored under old_key must still be the one this pick
-- came from. This guards against ever renaming/merging the wrong entry --
-- e.g. if the history changed between picking the word and this callback
-- running (a concurrent lookup elsewhere, or the entry already having been
-- migrated in the meantime) -- so a mismatch is simply skipped rather than
-- risking a wrong edit. Combined with the new_key == old_key early return
-- below, this also guarantees an already-correct entry is never rewritten,
-- and a once-migrated entry (whose key no longer matches what an older,
-- stale `choice` thinks it is) is never reprocessed.
function WordReview:correctHistoryEntry(plugin, old_key, old_word, resolved_word)
	if not old_key or old_key == "" or not resolved_word or resolved_word == "" then
		return
	end

	if self:normalizeKey(old_word) ~= old_key then
		return -- stale reference; old_key no longer describes old_word
	end

	local new_key = self:normalizeKey(resolved_word)
	if new_key == "" or new_key == old_key then
		return -- already correct, or nothing sensible to migrate to
	end

	local history = self:loadHistory(plugin)
	local old_entry = history.words[old_key]
	if not old_entry or self:normalizeKey(old_entry.word) ~= old_key then
		return -- already migrated (or changed) since old_key was picked
	end

	local existing = history.words[new_key]
	if existing then
		existing.count = (tonumber(existing.count) or 1) + (tonumber(old_entry.count) or 1)
		existing.last_ts = math.max(tonumber(existing.last_ts) or 0, tonumber(old_entry.last_ts) or 0)
		existing.word = resolved_word
		if old_entry.context and old_entry.context ~= "" and (not existing.context or existing.context == "") then
			existing.context = old_entry.context
		end
	else
		history.words[new_key] = {
			word = resolved_word,
			count = old_entry.count,
			last_ts = old_entry.last_ts,
			context = old_entry.context,
		}
	end

	history.words[old_key] = nil
	self:saveHistory(plugin, history)
end

-- Called from main.lua's onReaderReady and onResume. Looks up the chosen
-- review word through the normal dictionary machinery and, on success,
-- shows it using the plugin's existing floating popup -- with the
-- breadcrumb replaced by a left-aligned "Word to review" title (see
-- main.lua:showReviewPopup) and no cascade/history side effects (this
-- lookup must not itself get recorded as a "consultation" in the history
-- file, or every review would inflate its own count).
--
-- `trigger` identifies which event asked for this: "open" (book just
-- opened) or "resume" (device just woke up). Each has its own independent
-- on/off setting, so the two can be enabled separately, together, or not at
-- all -- this is the single place that decides whether to actually proceed,
-- based on whichever one fired.
function WordReview:maybeShowReview(plugin, trigger)
	if trigger == "resume" then
		if not self:isEnabledOnResume() then
			return
		end
	else
		if not self:isEnabledOnOpen() then
			return
		end
	end

	local rd = plugin.ui and plugin.ui.dictionary
	if not rd then
		return
	end

	local choice = self:pickWordToReview(plugin)
	if not choice or not choice.word or choice.word == "" then
		return
	end

	-- Full lookup across every installed dictionary (not restricted to a
	-- single one), same as a normal search, so the review card shows every
	-- dictionary's entry for the word exactly like a real lookup would --
	-- just as the user asked for ("Debe mostrar todos los diccionarios
	-- exactamente igual que una búsqueda normal").
	local order = plugin:getDictionaryOrderSetting()
	local saved_msg = rd.lookup_progress_msg
	rd.lookup_progress_msg = nil
	local ok, results = pcall(function()
		return rd:startSdcv(choice.word, order, false)
	end)
	rd.lookup_progress_msg = saved_msg

	if not ok or not results or type(results) ~= "table" or #results == 0 then
		logger.warn("WordReview: lookup failed for review word:", choice.word)
		return
	end

	-- Lazy history migration: if this word came from the book's own history
	-- (not a fallback pick) and the dictionary just resolved it to a
	-- different headword than what was stored (e.g. the history still has
	-- the old inflected form "sensata" from before this fix, and the
	-- dictionary resolves it to "sensatez"), correct that entry in place so
	-- future reviews search the real entry instead of repeating the same
	-- failed lookup. Best-effort: never blocks showing the review popup.
	--
	-- The resolved headword is picked with plugin:getResolvedLookupWord,
	-- the exact same dictionary-ranking/language-mode-aware logic the real
	-- popup uses to decide which result is shown first -- not just the
	-- first raw entry in `results` -- so the migration picks the same
	-- headword a normal lookup would show, regardless of which dictionary
	-- type or language is involved (definition dictionaries, StarDict
	-- translation dictionaries, or any other format sdcv/KOReader
	-- supports, all report `word` on their result the same way).
	if choice.history_key then
		local ok_resolve, resolved_word = pcall(function()
			return plugin:getResolvedLookupWord(choice.word, results)
		end)
		if ok_resolve and resolved_word and resolved_word ~= "" then
			local ok_migrate, err_migrate = pcall(function()
				self:correctHistoryEntry(plugin, choice.history_key, choice.word, resolved_word)
			end)
			if not ok_migrate then
				logger.warn("WordReview: history migration failed:", err_migrate)
			end
		end
	end

	plugin:showReviewPopup(choice.word, results)
end

-------------------------------------------------------------------------------
-- Cross-book word management ("Manage saved words")
-------------------------------------------------------------------------------
--
-- Everything above this section deals with exactly one book at a time (the
-- book currently open), reading/writing its history file via
-- getSidecarDir(plugin). The management screen below is different: it needs
-- to find and edit the saved-word history of *every* book the user has ever
-- opened, not just the current one, so a book doesn't need to be open at all
-- for its saved words to show up or be deleted here.
--
-- To do that without needing every book to be currently open, this section
-- works from plain file paths instead of from plugin.ui.document:
--   * getKnownBookFiles() asks KOReader's own ReadHistory (the same list
--     that powers the stock "History" screen) for every file path KOReader
--     has ever opened, plus the currently open book (in case it's brand new
--     and not saved to ReadHistory yet).
--   * findHistoryPathForBook() re-derives each book's .sdr sidecar
--     directory straight from its file path via DocSettings:getSidecarDir,
--     exactly like getSidecarDir(plugin) does for the current book, except
--     it tries all three possible sidecar locations ("doc", "dir", "hash")
--     since the user's "where to store sidecar files" setting may have
--     changed over time and different books' sidecars can legitimately live
--     in different places.
--   * loadHistoryFromPath()/saveHistoryToPath() are the same load/save
--     logic as loadHistory()/saveHistory() above, just parameterized on an
--     explicit path instead of derived from plugin.

-- Every location DocSettings:getSidecarDir() knows how to compute a sidecar
-- directory for. Order doesn't matter here (unlike DocSettings's own
-- priority list) since we're only checking "does a history file exist
-- here", not deciding where to write a new one.
local SIDECAR_LOCATIONS = { "doc", "dir", "hash" }

-- Returns every book file path KOReader knows about: everything in
-- ReadHistory (opened at some point, whether or not it still exists on
-- disk), plus the currently open book if it's not in there yet. Order is
-- whatever ReadHistory provides (most-recently-opened first) with the
-- current book appended last if it needed adding; the management screen
-- re-sorts its own rows anyway, so this order is not user-visible.
function WordReview:getKnownBookFiles(plugin)
	local files = {}
	local seen = {}

	local ok, ReadHistory = pcall(require, "readhistory")
	if ok and ReadHistory then
		pcall(function() ReadHistory:reload() end)
		for _, v in ipairs(ReadHistory.hist or {}) do
			if v.file and v.file ~= "" and not seen[v.file] then
				seen[v.file] = true
				table.insert(files, v.file)
			end
		end
	end

	local doc = plugin and plugin.ui and plugin.ui.document
	local current_file = doc and doc.file
	if current_file and current_file ~= "" and not seen[current_file] then
		seen[current_file] = true
		table.insert(files, current_file)
	end

	return files
end

-- Finds this book's wordreview_history.lua on disk, if it has one, by
-- trying every sidecar location it could plausibly be in. Returns the full
-- path, or nil if this book has no saved words at all (no history file in
-- any location).
function WordReview:findHistoryPathForBook(file)
	if not file or file == "" then
		return nil
	end

	for _, location in ipairs(SIDECAR_LOCATIONS) do
		local ok, sidecar_dir = pcall(function()
			return DocSettings:getSidecarDir(file, location)
		end)
		if ok and sidecar_dir and sidecar_dir ~= "" then
			local path = sidecar_dir .. "/" .. self.HISTORY_FILENAME
			if lfs.attributes(path, "mode") == "file" then
				return path
			end
		end
	end

	return nil
end

-- Same as loadHistory() above, but for an explicit path rather than one
-- derived from plugin.ui.document. Same guarantees: always returns a
-- well-formed { words = {} } table, never errors out.
function WordReview:loadHistoryFromPath(path)
	if not path or lfs.attributes(path, "mode") ~= "file" then
		return { words = {} }
	end

	local ok, chunk_or_err = pcall(loadfile, path)
	if not ok or not chunk_or_err then
		logger.warn("WordReview: failed to load history file:", path, chunk_or_err)
		return { words = {} }
	end

	local ok2, data = pcall(chunk_or_err)
	if not ok2 or type(data) ~= "table" then
		logger.warn("WordReview: history file did not evaluate to a table:", path)
		return { words = {} }
	end

	if type(data.words) ~= "table" then
		data.words = {}
	end

	return data
end

-- Same as saveHistory() above, but writes to an explicit path (the sidecar
-- directory is simply path's parent directory) instead of deriving one from
-- plugin.ui.document. Same atomic-replace-via-temp-file approach.
function WordReview:saveHistoryToPath(path, history)
	if not path or path == "" then
		return false
	end

	local sidecar_dir = path:match("^(.*)/[^/]+$")
	if sidecar_dir then
		local ok_dir = pcall(function()
			DocSettings:ensureSidecar(sidecar_dir)
		end)
		if not ok_dir and lfs.attributes(sidecar_dir, "mode") ~= "directory" then
			pcall(lfs.mkdir, sidecar_dir)
		end
	end

	local serialized, err = dump(history)
	if not serialized then
		logger.warn("WordReview: failed to serialize history:", err)
		return false
	end

	local tmp_path = path .. ".tmp"
	local f, open_err = io.open(tmp_path, "w")
	if not f then
		logger.warn("WordReview: failed to open history file for writing:", tmp_path, open_err)
		return false
	end
	f:write("return ")
	f:write(serialized)
	f:close()

	local ok_rename = os.rename(tmp_path, path)
	if not ok_rename then
		logger.warn("WordReview: failed to replace history file:", path)
		os.remove(tmp_path)
		return false
	end

	return true
end

-- Best-effort book display name: tries the book's own doc_props (title,
-- and author if present) via DocSettings, exactly like KOReader's own
-- History/Collections screens do, falling back to the bare filename (no
-- extension) if this book has no readable metadata at all -- e.g. a book
-- that was opened once, deleted, and only survives here because it still
-- has a saved word. Deliberately only called for books that already passed
-- findHistoryPathForBook (i.e. actually have saved words), since opening
-- DocSettings for every book in ReadHistory regardless would be wasteful.
function WordReview:getBookDisplayTitle(file)
	local ok, doc_settings = pcall(function()
		return DocSettings:open(file)
	end)
	if ok and doc_settings then
		local ok2, doc_props = pcall(function()
			return doc_settings:readSetting("doc_props")
		end)
		if ok2 and type(doc_props) == "table" and doc_props.title and doc_props.title ~= "" then
			return doc_props.title, doc_props.authors
		end
	end

	local base = file:match("([^/]+)$") or file
	base = base:gsub("%.%w+$", "")
	return base, nil
end

-- The single source of truth for the management screen: scans every known
-- book (see getKnownBookFiles), loads whichever of them actually have a
-- saved-word history, and flattens all of it into one flat list of rows --
-- one row per saved word, each carrying enough to both display it (word,
-- book title/author, save date, times saved) and delete it again
-- (history_path + key identify exactly which file and entry to edit).
--
-- Sorted most-recently-saved first, which is the most useful default for a
-- "manage everything I've saved" screen -- new words naturally show up at
-- the top instead of the user having to hunt for them.
function WordReview:collectSavedWordRows(plugin)
	local rows = {}

	for _, file in ipairs(self:getKnownBookFiles(plugin)) do
		local history_path = self:findHistoryPathForBook(file)
		if history_path then
			local history = self:loadHistoryFromPath(history_path)
			local book_title, book_author = self:getBookDisplayTitle(file)
			for key, entry in pairs(history.words or {}) do
				table.insert(rows, {
					history_path = history_path,
					book_file = file,
					book_title = book_title,
					book_author = book_author,
					key = key,
					word = entry.word or key,
					count = tonumber(entry.count) or 1,
					last_ts = tonumber(entry.last_ts) or 0,
					context = entry.context,
					mastered = entry.mastered and true or false,
				})
			end
		end
	end

	table.sort(rows, function(a, b)
		if a.last_ts ~= b.last_ts then
			return a.last_ts > b.last_ts
		end
		return (a.word or "") < (b.word or "")
	end)

	return rows
end

-- Deletes a batch of rows (as produced by collectSavedWordRows) from disk.
-- Rows are grouped by history_path first so a book with several selected
-- words only gets its history file loaded and re-saved once, not once per
-- word. Best-effort per file: a save failure for one book's history doesn't
-- stop the others from being processed.
function WordReview:deleteWordRows(rows_to_delete)
	local keys_by_path = {}
	for _, row in ipairs(rows_to_delete) do
		local keys = keys_by_path[row.history_path]
		if not keys then
			keys = {}
			keys_by_path[row.history_path] = keys
		end
		keys[row.key] = true
	end

	for path, keys in pairs(keys_by_path) do
		local history = self:loadHistoryFromPath(path)
		for key in pairs(keys) do
			history.words[key] = nil
		end
		self:saveHistoryToPath(path, history)
	end
end

-- Toggles the "mastered" flag for a single saved word (a row as produced by
-- collectSavedWordRows), used by the Flashcards screen's "Mark as Mastered"
-- button. Purely a per-word boolean on that word's own history entry, in the
-- same book history file every other per-word field already lives in --
-- doesn't affect count/last_ts/context, and doesn't remove the word from the
-- saved list (mastered words simply grow a small checkmark in the list, and
-- can still be reviewed/unmastered later). Updates `row.mastered` in place
-- on success so the caller's already-built row list stays in sync without
-- needing a full reload.
function WordReview:setWordMastered(row, mastered)
	if not row or not row.history_path or not row.key then
		return false
	end

	local history = self:loadHistoryFromPath(row.history_path)
	local entry = history.words[row.key]
	if not entry then
		return false
	end

	entry.mastered = mastered and true or false
	local ok = self:saveHistoryToPath(row.history_path, history)
	if ok then
		row.mastered = entry.mastered
	end
	return ok
end

-- Builds the one-line-per-word right-hand label: book title (plus author,
-- if known), the save date, and, if the word was looked up more than once,
-- how many times -- everything collectSavedWordRows has available besides
-- the word itself.
function WordReview:formatRowMandatory(row)
	local book_part = row.book_title or ""
	if row.book_author and row.book_author ~= "" then
		book_part = book_part .. " (" .. row.book_author .. ")"
	end

	local date_part = nil
	if row.last_ts and row.last_ts > 0 then
		local ok, formatted = pcall(datetime.secondsToDateTime, row.last_ts)
		if ok and formatted then
			date_part = formatted
		end
	end

	local count_part = nil
	if row.count and row.count > 1 then
		count_part = T(_("seen %1×"), row.count)
	end

	local parts = {}
	if book_part ~= "" then table.insert(parts, book_part) end
	if date_part then table.insert(parts, date_part) end
	if count_part then table.insert(parts, count_part) end

	return table.concat(parts, "  ·  ")
end

-- Row identity used by the list screen's multi-select mode below: nil ==
-- not in select mode; a set of these ids == select mode, with each
-- currently-checked row's id present as a key.
function WordReview:rowId(row)
	return row.history_path .. "\1" .. row.key
end

-------------------------------------------------------------------------------
-- "Word Review" list screen (Kindle Vocabulary Builder-style)
-------------------------------------------------------------------------------
--
-- Entry point, called from the "Manage saved words" menu item (see genMenu
-- above). Every word ever saved, across every book, as one flat, always-
-- freshly-reloaded-from-disk list -- same data and same actions as the
-- screen this replaces (view, delete one at a time, multi-select + bulk
-- delete, delete everything), just laid out and styled to match Kindle's
-- Vocabulary Builder: a plain title bar, a thin-bordered rectangle per word,
-- and one big "Flashcards" button pinned near the bottom that opens the new
-- flashcards screen (see showFlashcardsScreen) over whichever words are
-- currently in view (respecting the All/Learning/Mastered filter below).
--
-- All state (rows, filter, selection, page) is kept local to this call
-- rather than on self/WordReview, so the screen is always rebuilt fresh from
-- disk each time it's opened and never leaks stale state between visits.
function WordReview:showManageWordsScreen(plugin)
	local screen
	local rows = {}
	local selected = nil -- nil == not in select mode; table == select mode, set of row ids

	-- Whether a book is currently open at all -- when it isn't (opened from
	-- the docless mini-menu, see item 16/17), there is no "This Book" tab:
	-- only "All" and "Mastered" make sense.
	local current_book_file = plugin and plugin.ui and plugin.ui.document and plugin.ui.document.file
	local has_book = current_book_file ~= nil and current_book_file ~= ""

	-- Three tabs: "book" (this book's pending words), "all" (every book's
	-- pending words), "mastered" (every mastered word, from any book).
	local filter = has_book and "book" or "all" -- "book" | "all" | "mastered"

	local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
	local content_w = screen_w - 2 * SIDE_MARGIN

	local rebuild -- forward declaration

	local function sortAlpha(list)
		table.sort(list, function(a, b)
			return (a.word or ""):lower() < (b.word or ""):lower()
		end)
		return list
	end

	-- This Book / All always show words alphabetically (A -> Z); Mastered
	-- keeps the original most-recently-saved-first order.
	local function filteredRows()
		local out = {}
		for _, row in ipairs(rows) do
			if filter == "mastered" then
				if row.mastered then table.insert(out, row) end
			elseif filter == "book" then
				if not row.mastered and row.book_file == current_book_file then
					table.insert(out, row)
				end
			else -- "all"
				if not row.mastered then table.insert(out, row) end
			end
		end
		if filter ~= "mastered" then
			sortAlpha(out)
		end
		return out
	end

	local function bookCount()
		local n = 0
		for _, row in ipairs(rows) do
			if not row.mastered and row.book_file == current_book_file then n = n + 1 end
		end
		return n
	end

	local function allPendingCount()
		local n = 0
		for _, row in ipairs(rows) do
			if not row.mastered then n = n + 1 end
		end
		return n
	end

	local function masteredCount()
		local n = 0
		for _, row in ipairs(rows) do
			if row.mastered then n = n + 1 end
		end
		return n
	end

	local function reloadRows()
		rows = self:collectSavedWordRows(plugin)
		if selected then
			local still_present = {}
			for _, row in ipairs(rows) do
				local id = self:rowId(row)
				if selected[id] then
					still_present[id] = true
				end
			end
			selected = still_present
		end
	end

	local function exitSelectMode()
		selected = nil
	end

	local function enterSelectMode()
		selected = {}
	end

	local function confirmAndDelete(rows_to_delete, message)
		UIManager:show(ConfirmBox:new({
			text = message,
			ok_text = _("Delete"),
			ok_callback = function()
				self:deleteWordRows(rows_to_delete)
				exitSelectMode()
				reloadRows()
				rebuild()
			end,
		}))
	end

	-- Item 10: lets the Flashcards screen's "Words mastered" button jump
	-- straight back here on the Mastered tab.
	local function jumpToMastered()
		if selected then exitSelectMode() end
		filter = "mastered"
		reloadRows()
		rebuild()
	end

	-- Tapping a single word (outside select mode) now reuses the exact same
	-- Flashcard-screen design (see showFlashcardsScreen) instead of the old
	-- text-heavy confirm dialog -- same card, same border, same spacing,
	-- with the date/time and "Remove this word..." copy simply gone (the
	-- Flashcards screen never had them), and a "Delete" action wired in via
	-- opts.on_delete so the word can still be removed from here.
	--
	-- `list` is the full set of words currently shown for the active tab
	-- (This Book / All / Mastered -- i.e. shown_rows at tap time) and
	-- `start_index` is the tapped word's own position within it, so the
	-- Flashcard screen opens with the WHOLE tab's collection loaded (not
	-- just the one tapped word) and can navigate -- circularly -- through
	-- every other word in that same tab via swipe.
	local function showRowActions(row, list, start_index)
		self:showFlashcardsScreen(plugin, list, function()
			reloadRows()
			rebuild()
		end, {
			start_index = start_index,
			on_delete = function(current_row)
				self:deleteWordRows({ current_row })
			end,
			on_view_mastered = jumpToMastered,
		})
	end

	local function showSelectModeActions()
		local selected_rows = {}
		for _, row in ipairs(rows) do
			if selected[self:rowId(row)] then
				table.insert(selected_rows, row)
			end
		end
		local count = #selected_rows
		local actions_enabled = count > 0

		local dialog
		dialog = ButtonDialog:new({
			title = actions_enabled and T(_("%1 word(s) selected"), count) or _("No words selected"),
			title_align = "center",
			buttons = {
				{
					{
						text = _("Select all"),
						callback = function()
							UIManager:close(dialog)
							for _, row in ipairs(filteredRows()) do
								selected[self:rowId(row)] = true
							end
							rebuild()
						end,
					},
					{
						text = _("Deselect all"),
						enabled = actions_enabled,
						callback = function()
							UIManager:close(dialog)
							selected = {}
							rebuild()
						end,
					},
				},
				{
					{
						text = _("Delete selected"),
						enabled = actions_enabled,
						callback = function()
							UIManager:close(dialog)
							confirmAndDelete(selected_rows, T(_("Delete %1 selected word(s)?"), count))
						end,
					},
				},
				{
					{
						text = _("Exit select mode"),
						callback = function()
							UIManager:close(dialog)
							exitSelectMode()
							rebuild()
						end,
					},
				},
			},
		})
		UIManager:show(dialog)
	end

	local function showMainActions()
		local dialog
		dialog = ButtonDialog:new({
			title = _("Word Review"),
			title_align = "center",
			buttons = {
				{
					{
						text = _("Select multiple"),
						enabled = #rows > 0,
						callback = function()
							UIManager:close(dialog)
							enterSelectMode()
							rebuild()
						end,
					},
				},
				{
					{
						text = _("Delete all saved words"),
						enabled = #rows > 0,
						callback = function()
							UIManager:close(dialog)
							confirmAndDelete(rows, _("Delete ALL saved words, from every book?\nThis cannot be undone."))
						end,
					},
				},
			},
		})
		UIManager:show(dialog)
	end

	local function openFlashcards()
		local study_rows = filteredRows()
		if #study_rows == 0 then
			plugin:notify(_("No words to review."))
			return
		end
		self:showFlashcardsScreen(plugin, study_rows, function()
			reloadRows()
			rebuild()
		end, { on_view_mastered = jumpToMastered })
	end

	-- Item 14: each of This Book / All has its own Random button, picking
	-- only from that scope's pending (non-mastered) words -- never a
	-- separate "Random" tab.
	local function openRandomBook()
		local pool = {}
		for _, row in ipairs(rows) do
			if not row.mastered and row.book_file == current_book_file then
				table.insert(pool, row)
			end
		end
		if #pool == 0 then
			plugin:notify(_("No words to review."))
			return
		end
		local start_index = math.random(1, #pool)
		self:showFlashcardsScreen(plugin, pool, function()
			reloadRows()
			rebuild()
		end, { start_index = start_index, on_view_mastered = jumpToMastered })
	end

	local function openRandomAll()
		local pool = {}
		for _, row in ipairs(rows) do
			if not row.mastered then table.insert(pool, row) end
		end
		if #pool == 0 then
			plugin:notify(_("No words to review."))
			return
		end
		local start_index = math.random(1, #pool)
		self:showFlashcardsScreen(plugin, pool, function()
			reloadRows()
			rebuild()
		end, { start_index = start_index, on_view_mastered = jumpToMastered })
	end

	-- Builds the whole screen fresh from current (rows, filter, selected) --
	-- same rebuild-from-scratch convention already used by this plugin's
	-- other ad-hoc popups (see main.lua's showButtonSettingsMenu/rebuild),
	-- so every bit of state is always reflected immediately without any
	-- partial-widget bookkeeping. Returns (body, scroll_container) -- the
	-- latter, if any, is wired into FullScreenPanel.cropping_widget by
	-- rebuild() below.
	local function buildBody()
		local shown_rows = filteredRows()
		local mastered_n = masteredCount()
		local book_n = bookCount()
		local all_n = allPendingCount()

		-- Title bar: hamburger (select/delete actions) -- "Word Review (N)" -- ✕.
		local menu_icon = textButton("≡", UI_FONT_SIZE + 2, true, nil, function()
			if selected then
				showSelectModeActions()
			else
				showMainActions()
			end
		end)
		local close_icon = textButton("✕", UI_FONT_SIZE + 2, false, nil, function()
			if selected then
				-- Inside multi-select mode, the ✕ only deselects everything
				-- and returns to the normal list -- it must never close Word
				-- Review itself (that used to happen because this button
				-- unconditionally called screen:onClose()).
				exitSelectMode()
				rebuild()
			else
				screen:onClose()
			end
		end)
		local title_widget = TextWidget:new({
			text = T(_("Word Review (%1)"), #rows),
			face = Font:getFace("cfont", UI_FONT_SIZE),
			bold = true,
		})
		local top_bar = threeRow(menu_icon, title_widget, close_icon, content_w, TOP_BAR_HEIGHT)

		-- Sub-bar: This Book / All / Mastered -- three same-styled navigation
		-- tabs. "This Book" only exists while a book is actually open (see
		-- item 17); "Words" has been renamed to "This Book" since that's
		-- what it always meant.
		local tabs = {}
		if has_book then
			local book_tab = textButton(T(_("This Book (%1)"), book_n), UI_FONT_SIZE - 2,
				filter == "book", filter == "book" and COLOR_NAV_TEXT or COLOR_MUTED, function()
					if selected then return end
					filter = "book"
					rebuild()
				end)
			table.insert(tabs, book_tab)
		end
		local all_tab = textButton(T(_("All (%1)"), all_n), UI_FONT_SIZE - 2,
			filter == "all", filter == "all" and COLOR_NAV_TEXT or COLOR_MUTED, function()
				if selected then return end
				filter = "all"
				rebuild()
			end)
		table.insert(tabs, all_tab)
		local mastered_tab = textButton(T(_("Mastered (%1)"), mastered_n), UI_FONT_SIZE - 2,
			filter == "mastered", filter == "mastered" and COLOR_NAV_TEXT or COLOR_MUTED, function()
				if selected then return end
				filter = "mastered"
				rebuild()
			end)
		table.insert(tabs, mastered_tab)
		local sub_bar = tabRow(tabs, content_w, SUBBAR_HEIGHT)

		-- Item 14: a small "Random" action, scoped to whichever tab is
		-- active -- This Book picks only from this book's pending words,
		-- All picks from the whole pending collection. Not shown on
		-- Mastered (there's nothing to "study" there). Always reserves the
		-- same row height either way, so the grid below never shifts.
		local random_action
		if filter == "book" then
			random_action = textButton(_("Random"), UI_FONT_SIZE - 2, false, COLOR_NAV_TEXT, openRandomBook)
		elseif filter == "all" then
			random_action = textButton(_("Random"), UI_FONT_SIZE - 2, false, COLOR_NAV_TEXT, openRandomAll)
		end
		local action_row = CenterContainer:new({
			dimen = Geom:new({ w = content_w, h = SUBBAR_HEIGHT }),
			random_action or HorizontalSpan:new({ width = 0 }),
		})

		-- Word grid: fixed GRID_COLS-wide columns of same-size horizontal
		-- rectangles (see buildWordRow), scrolling vertically instead of
		-- paging once there are more words than fit on screen. Filled
		-- strictly in row-major order -- left, then center, then right,
		-- then wrap to the next row -- by simply walking `shown_rows` in
		-- order and appending each box to the current row until it holds
		-- GRID_COLS boxes; it never starts a row from the middle column.
		local grid_inner_w = content_w
		local box_w = math.floor((grid_inner_w - (GRID_COLS - 1) * GRID_GAP) / GRID_COLS)
		local box_h = Font:getFace("cfont", UI_FONT_SIZE - 1).orig_size + Screen:scaleBySize(18)

		local reserved_h = SIDE_MARGIN -- top margin
			+ TOP_BAR_HEIGHT + SECTION_GAP
			+ SUBBAR_HEIGHT + SECTION_GAP
			+ SUBBAR_HEIGHT + SECTION_GAP
			+ HAIRLINE + SECTION_GAP
			+ BOTTOM_BUTTON_HEIGHT + SIDE_MARGIN
		local list_area_h = math.max(box_h, screen_h - reserved_h)

		local grid_rows = {}
		if #shown_rows == 0 then
			local empty_label = TextWidget:new({
				text = #rows == 0 and _("No words saved yet") or _("No words in this view"),
				face = Font:getFace("cfont", UI_FONT_SIZE - 2),
				fgcolor = COLOR_MUTED,
			})
			table.insert(grid_rows, CenterContainer:new({
				dimen = Geom:new({ w = grid_inner_w, h = box_h }),
				empty_label,
			}))
		else
			local col = 0
			local current_row_children = {}
			for idx, row in ipairs(shown_rows) do
				local id = self:rowId(row)
				local is_dimmed = selected and selected[id] and true or false
				local box = buildWordRow(row, box_w, box_h, is_dimmed, function()
					if selected then
						if selected[id] then
							selected[id] = nil
						else
							selected[id] = true
						end
						rebuild()
					else
						showRowActions(row, shown_rows, idx)
					end
				end, function()
					if not selected then
						enterSelectMode()
					end
					selected[id] = true
					rebuild()
				end)
				table.insert(current_row_children, box)
				col = col + 1
				if col < GRID_COLS then
					table.insert(current_row_children, HorizontalSpan:new({ width = GRID_GAP }))
				end
				if col == GRID_COLS or idx == #shown_rows then
					local row_group = HorizontalGroup:new(current_row_children)
					if col == GRID_COLS then
						-- box_w is floor()'d (grid_inner_w isn't always
						-- evenly divisible by GRID_COLS), so a FULL row of
						-- boxes can end up a pixel or two narrower than
						-- grid_inner_w. Centering only a full row -- instead
						-- of leaving it flush against the left edge --
						-- splits that leftover evenly on both sides, so the
						-- middle column's box always sits exactly on the
						-- interface's true center rather than drifting
						-- left/right by however many pixels floor() dropped.
						table.insert(grid_rows, CenterContainer:new({
							dimen = Geom:new({ w = grid_inner_w, h = row_group:getSize().h }),
							row_group,
						}))
					else
						-- A PARTIAL final row (fewer than GRID_COLS words --
						-- e.g. just 1 or 2 total words) must never be
						-- centered: it always starts filling from the first
						-- (leftmost) column, left-aligned, exactly like a
						-- full row would.
						table.insert(grid_rows, row_group)
					end
					if idx < #shown_rows then
						table.insert(grid_rows, VerticalSpan:new({ width = GRID_GAP }))
					end
					current_row_children = {}
					col = 0
				end
			end
		end
		local grid_content = VerticalGroup:new(grid_rows)

		local scroll_container
		local list_widget
		if grid_content:getSize().h > list_area_h then
			scroll_container = ScrollableContainer:new({
				dimen = Geom:new({ w = content_w, h = list_area_h }),
				grid_content,
			})
			list_widget = scroll_container
		else
			-- Top-aligned: the grid sits right under the tabs and grows
			-- downward, with the leftover room (if any) pushed below it as
			-- plain empty space -- never vertically centered. The total
			-- height still equals list_area_h, so the Flashcards button
			-- below stays anchored to the bottom exactly as before.
			local filler_h = math.max(0, list_area_h - grid_content:getSize().h)
			list_widget = VerticalGroup:new({
				grid_content,
				VerticalSpan:new({ width = filler_h }),
			})
		end

		-- One big "Flashcards" button, nearly full width, pinned near the
		-- bottom of the screen (a flexible spacer above it soaks up whatever
		-- room the grid didn't use, so the button always sits at the bottom
		-- instead of right after a short grid).
		local flashcards_enabled = #shown_rows > 0
		local flashcards_label = TextWidget:new({
			text = _("Flashcards"),
			face = Font:getFace("cfont", UI_FONT_SIZE + 1),
			bold = true,
			fgcolor = flashcards_enabled and Blitbuffer.COLOR_BLACK or COLOR_MUTED,
		})
		local flashcards_inner = CenterContainer:new({
			dimen = Geom:new({ w = content_w - 2 * HAIRLINE, h = BOTTOM_BUTTON_HEIGHT - 2 * HAIRLINE }),
			flashcards_label,
		})
		local flashcards_frame = FrameContainer:new({
			background = Blitbuffer.COLOR_WHITE,
			bordersize = HAIRLINE,
			color = COLOR_LINE,
			radius = 0,
			padding = 0,
			flashcards_inner,
		})
		local flashcards_button = wrapTappable(flashcards_frame, flashcards_enabled and openFlashcards or nil)

		local used_h = SIDE_MARGIN
			+ TOP_BAR_HEIGHT + SECTION_GAP
			+ SUBBAR_HEIGHT + SECTION_GAP
			+ SUBBAR_HEIGHT + SECTION_GAP
			+ HAIRLINE + SECTION_GAP
			+ list_area_h
		local remaining = screen_h - used_h - BOTTOM_BUTTON_HEIGHT - SIDE_MARGIN
		local spacer_h = math.max(SECTION_GAP, remaining)

		local column = {
			VerticalSpan:new({ width = SIDE_MARGIN }),
			top_bar,
			VerticalSpan:new({ width = SECTION_GAP }),
			sub_bar,
			VerticalSpan:new({ width = SECTION_GAP }),
			action_row,
			VerticalSpan:new({ width = SECTION_GAP }),
			hairline(content_w),
			VerticalSpan:new({ width = SECTION_GAP }),
			list_widget,
			VerticalSpan:new({ width = spacer_h }),
			flashcards_button,
			VerticalSpan:new({ width = SIDE_MARGIN }),
		}

		local body = HorizontalGroup:new({
			HorizontalSpan:new({ width = SIDE_MARGIN }),
			VerticalGroup:new(column),
			HorizontalSpan:new({ width = SIDE_MARGIN }),
		})

		return body, scroll_container
	end

	rebuild = function()
		if screen then
			pcall(function() UIManager:close(screen) end)
		end
		local body, scroll_container = buildBody()
		screen = FullScreenPanel:new({ body = body, cropping_widget = scroll_container })
		if scroll_container then
			scroll_container.show_parent = screen
		end
		UIManager:show(screen)
	end

	reloadRows()
	rebuild()
end

-------------------------------------------------------------------------------
-- Flashcards screen (Kindle Vocabulary Builder-style)
-------------------------------------------------------------------------------
--
-- Opened from the Word Review screen's "Flashcards" button, over whichever
-- rows are currently in view there (see openFlashcards above). One word per
-- card: the word itself, the context sentence captured when it was saved
-- (wordreview.lua's existing row.context -- reused here as-is, never
-- generated or altered), the book it came from, and a "Mark as Mastered"
-- toggle that flips the same row.mastered flag the list screen's checkmark
-- reads (see setWordMastered above). "See Definition" performs a real
-- dictionary lookup and shows it in the plugin's own existing floating
-- popup -- the exact same lookup/popup path WordReview:maybeShowReview
-- already uses for the automatic review card, just triggered by a tap here
-- instead of automatically on book open.
--
-- `rows` is a plain array (order = study order); `on_close` is called once,
-- when the user exits back to the list screen, so it can refresh row data
-- (mastered flags, counts) there. `opts` (optional) may contain:
--   start_index -- 1-based index into `rows` to open on (used by the
--                  "Random" tab to land straight on the chosen word)
--   on_delete    -- if set, a "Delete" action is shown on the card, calling
--                  on_delete(current_row) then closing the screen (used by
--                  the Word Review list's single-word tap -- see
--                  showRowActions above)
function WordReview:showFlashcardsScreen(plugin, rows, on_close, opts)
	if not rows or #rows == 0 then
		if plugin.notify then plugin:notify(_("No words to review.")) end
		return
	end
	opts = opts or {}

	local screen
	local index = 1
	if opts.start_index and opts.start_index >= 1 and opts.start_index <= #rows then
		index = opts.start_index
	end
	-- Whether the card is currently showing a real dictionary definition
	-- (via "See Definition") instead of the saved context paragraph -- see
	-- seeDefinition below. Freely toggles back and forth (Flashcard -> See
	-- Definition -> Back to Context -> See Definition -> ... as many times
	-- as the user likes) and always resets to the context view whenever the
	-- word changes, so a fresh word never opens on a stale definition.
	-- definition_entries is an array of { dict = <dictionary name>, text =
	-- <plain-text definition> }, one per installed dictionary that returned
	-- a result for the current word; dict_index selects which one is shown,
	-- switchable by tap or swipe -- see switchDict below -- the same way
	-- the plugin's own dictionary popup lets you flip between dictionaries.
	local definition_mode = false
	local definition_entries = nil
	local dict_index = 1

	local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
	local content_w = screen_w - 2 * SIDE_MARGIN
	-- Horizontal padding stays generous (this is what keeps the context/
	-- definition text away from the left/right border); top and bottom are
	-- their own, much smaller, values so the header row and the Mastered/
	-- Delete row sit right against the card's own top/bottom border instead
	-- of floating in extra whitespace -- these are now the ONLY top/bottom
	-- spacing (see the FrameContainer below, which no longer adds its own
	-- uniform padding on top of these).
	local CARD_PADDING = Screen:scaleBySize(18)
	local CARD_HEADER_TOP_PAD = Screen:scaleBySize(4)
	local CARD_BOTTOM_PAD = Screen:scaleBySize(4)
	-- No more side arrow buttons (navigation is swipe-only, see
	-- onCardSwipeLeft/onCardSwipeRight below) -- the space they used to
	-- occupy is reclaimed by the card itself. ARROW_RECLAIM_W is roughly
	-- half of the old 60px-wide arrow zone, added back on *each* side, so
	-- the card grows into about half of the space the arrows used to take
	-- up rather than swallowing all of it.
	local CARD_GAP = Screen:scaleBySize(10) -- now just the card's side margin from the screen edge
	local ARROW_RECLAIM_W = Screen:scaleBySize(30)
	local CARD_WIDTH = math.min(
		math.floor(screen_w * 0.82) + 2 * ARROW_RECLAIM_W,
		screen_w - 2 * CARD_GAP
	)

	local rebuild -- forward declaration

	local function masteredCount()
		local all_rows = self:collectSavedWordRows(plugin)
		local n = 0
		for _, r in ipairs(all_rows) do
			if r.mastered then n = n + 1 end
		end
		return n
	end

	local function exit()
		screen:onClose()
	end

	local function resetCardView()
		definition_mode = false
		definition_entries = nil
		dict_index = 1
	end

	local function goPrev()
		index = index > 1 and (index - 1) or #rows
		resetCardView()
		rebuild()
	end

	local function goNext()
		index = index < #rows and (index + 1) or 1
		resetCardView()
		rebuild()
	end

	local function toggleMastered()
		local row = rows[index]
		self:setWordMastered(row, not row.mastered)
		rebuild()
	end

	local function confirmDelete()
		local row = rows[index]
		UIManager:show(ConfirmBox:new({
			text = T(_("Delete \"%1\" from your saved words?"), row.word),
			ok_text = _("Delete"),
			ok_callback = function()
				opts.on_delete(row)
				exit()
			end,
		}))
	end

	-- Flips between the context card and the definition card, any number of
	-- times, in either direction -- tapping "See Definition" does a real
	-- dictionary lookup (once per visit) the first time, then swaps this
	-- SAME card's body to show it; tapping "Back to Context" (same button,
	-- relabeled) just swaps the body back, no new lookup needed.
	local function seeDefinition()
		if definition_mode then
			resetCardView()
			rebuild()
			return
		end
		local row = rows[index]
		local rd = plugin.ui and plugin.ui.dictionary
		if not rd then return end
		local order = plugin:getDictionaryOrderSetting()
		local ok, results = pcall(function()
			return rd:startSdcv(row.word, order, false)
		end)
		local entries = {}
		if ok and results and type(results) == "table" then
			for _, r in ipairs(results) do
				if r and r.definition and r.definition ~= "" then
					local text = stripHtml(r.definition)
					if text ~= "" then
						table.insert(entries, { dict = r.dict or "", text = text })
					end
				end
			end
		end
		if #entries > 0 then
			definition_entries = entries
			dict_index = 1
			definition_mode = true
			rebuild()
		elseif plugin.notify then
			plugin:notify(T(_("No definition found for \"%1\"."), row.word))
		end
	end

	-- Cycles through definition_entries -- one per installed dictionary that
	-- had a result -- the same "flip to the next dictionary" gesture as the
	-- plugin's own dictionary popup (see the swipe wiring on body_widget in
	-- buildBody below).
	local function switchDict(delta)
		if not definition_entries or #definition_entries <= 1 then return end
		dict_index = ((dict_index - 1 + delta) % #definition_entries) + 1
		rebuild()
	end

	local function buildBody()
		local row = rows[index]

		local exit_btn = textButton("‹  " .. _("Exit Flashcards"), UI_FONT_SIZE - 1, false, COLOR_NAV_TEXT, exit)
		local mastered_label = textButton(
			T(_("Words mastered: %1"), masteredCount()),
			UI_FONT_SIZE - 2, false, COLOR_NAV_TEXT,
			opts.on_view_mastered and function()
				screen:onClose()
				opts.on_view_mastered()
			end or nil
		)
		local top_bar = edgeRow(exit_btn, mastered_label, content_w, TOP_BAR_HEIGHT)

		local card_inner_w = CARD_WIDTH - 2 * CARD_PADDING - 2 * HAIRLINE

		local see_def_label = definition_mode and ("‹  " .. _("Context")) or _("See Definition")
		local see_def_btn = textButton(see_def_label, UI_FONT_SIZE - 3, false, nil, seeDefinition)

		-- Right side of the card header: the word's position in this study
		-- session while looking at the context, or -- while looking at a
		-- definition -- which installed dictionary (by index only, not by
		-- name, so this row never has to fight a long dictionary name for
		-- space on small screens) is currently shown, with small tap
		-- targets to flip between them when there's more than one (mirrors
		-- switchDict).
		local header_right
		if definition_mode and definition_entries then
			local dict_face = Font:getFace("cfont", UI_FONT_SIZE - 3)
			local counter_text = T(_("%1/%2"), dict_index, #definition_entries)
			if #definition_entries > 1 then
				local counter_widget = TextWidget:new({ text = counter_text, face = dict_face, fgcolor = COLOR_NAV_TEXT })
				local prev_dict_btn = textButton("‹", UI_FONT_SIZE - 2, true, COLOR_NAV_TEXT, function() switchDict(-1) end)
				local next_dict_btn = textButton("›", UI_FONT_SIZE - 2, true, COLOR_NAV_TEXT, function() switchDict(1) end)
				header_right = HorizontalGroup:new({
					prev_dict_btn,
					HorizontalSpan:new({ width = Screen:scaleBySize(6) }),
					counter_widget,
					HorizontalSpan:new({ width = Screen:scaleBySize(6) }),
					next_dict_btn,
				})
			else
				header_right = TextWidget:new({ text = counter_text, face = dict_face, fgcolor = COLOR_NAV_TEXT })
			end
		else
			header_right = TextWidget:new({
				text = T(_("%1/%2"), index, #rows),
				face = Font:getFace("cfont", UI_FONT_SIZE - 3),
				fgcolor = COLOR_NAV_TEXT,
			})
		end
		local card_header = edgeRow(see_def_btn, header_right, card_inner_w, Screen:scaleBySize(28))

		local word_face = fitFaceToWidth(row.word, "cfont", card_inner_w, 34, 18)
		local word_widget = TextWidget:new({
			text = row.word,
			face = word_face,
			bold = true,
		})
		local word_row = CenterContainer:new({
			dimen = Geom:new({ w = card_inner_w, h = word_widget:getSize().h }),
			word_widget,
		})

		-- The context paragraph, with the looked-up word itself shown in
		-- italics -- also doubles as the reference size for the definition
		-- body below, so a definition card stays practically the same size
		-- as its context card instead of stretching into a tall rectangle.
		local context_text = (row.context and row.context ~= "")
			and row.context
			or _("(no context saved for this word)")
		local italic_face = Font:getFace("NotoSans-Italic.ttf", 16)
		local context_widget = buildHighlightedParagraph(
			context_text, row.word, card_inner_w, Font:getFace("cfont", 16), italic_face, nil, true)
		local reference_body_h = math.max(context_widget:getSize().h, Screen:scaleBySize(90)) * 1.45

		local body_widget
		local body_scroll_container
		if definition_mode then
			local def_widget = TextBoxWidget:new({
				text = definition_entries[dict_index].text,
				face = Font:getFace("cfont", 16),
				width = card_inner_w,
				alignment = "left",
			})
			if def_widget:getSize().h > reference_body_h then
				body_scroll_container = ScrollableContainer:new({
					dimen = Geom:new({ w = card_inner_w, h = reference_body_h }),
					def_widget,
				})
				body_widget = body_scroll_container
			else
				body_widget = def_widget
			end
		else
			body_widget = context_widget
		end

		local mastered_text = row.mastered and ("↩ " .. _("Move to Review")) or _("Mark as Mastered")
		local mastered_btn = textButton(mastered_text, UI_FONT_SIZE - 2, row.mastered and true or false, COLOR_NAV_TEXT, toggleMastered)
		local delete_btn = opts.on_delete and textButton(_("Delete"), UI_FONT_SIZE - 2, false, nil, confirmDelete) or nil

		local bottom_row_inner
		if delete_btn then
			local side_by_side = HorizontalGroup:new({
				mastered_btn,
				HorizontalSpan:new({ width = Screen:scaleBySize(24) }),
				delete_btn,
			})
			-- Guard against horizontal overflow on narrow cards/long
			-- translated labels: if "Mark as Mastered" + "Delete" side by
			-- side would be wider than the card's own inner width, stack
			-- them instead -- this must never cause a horizontal scroll,
			-- under any circumstance.
			if side_by_side:getSize().w > card_inner_w then
				bottom_row_inner = VerticalGroup:new({
					CenterContainer:new({ dimen = Geom:new({ w = card_inner_w, h = mastered_btn:getSize().h }), mastered_btn }),
					VerticalSpan:new({ width = Screen:scaleBySize(6) }),
					CenterContainer:new({ dimen = Geom:new({ w = card_inner_w, h = delete_btn:getSize().h }), delete_btn }),
				})
			else
				bottom_row_inner = side_by_side
			end
		else
			bottom_row_inner = mastered_btn
		end
		local mastered_row = CenterContainer:new({
			dimen = Geom:new({ w = card_inner_w, h = bottom_row_inner:getSize().h }),
			bottom_row_inner,
		})

		-- The book/author line only makes sense next to the saved context,
		-- not next to a dictionary definition -- and definition_mode no
		-- longer shows any label in its place (no more redundant
		-- "Dictionary definition" caption), so the card body goes straight
		-- from the definition text to the Mastered/Delete row.
		local card_children = {
			card_header,
			VerticalSpan:new({ width = SECTION_GAP }),
			hairline(card_inner_w),
			VerticalSpan:new({ width = SECTION_GAP * 4 }),
			word_row,
			VerticalSpan:new({ width = SECTION_GAP * 4 }),
			body_widget,
		}
		if not definition_mode then
			local book_label = row.book_title or ""
			if row.book_author and row.book_author ~= "" then
				book_label = book_label .. " (" .. row.book_author .. ")"
			end
			local book_widget = TextBoxWidget:new({
				text = book_label ~= "" and book_label or _("Unknown book"),
				face = Font:getFace("cfont", 14),
				width = card_inner_w,
				alignment = "center",
				fgcolor = COLOR_NAV_TEXT,
			})
			table.insert(card_children, VerticalSpan:new({ width = SECTION_GAP * 4 }))
			table.insert(card_children, book_widget)
		end
		table.insert(card_children, VerticalSpan:new({ width = SECTION_GAP * 3 }))
		table.insert(card_children, hairline(card_inner_w))
		table.insert(card_children, VerticalSpan:new({ width = SECTION_GAP }))
		table.insert(card_children, mastered_row)

		local card_body = VerticalGroup:new(card_children)

		local card = FrameContainer:new({
			background = Blitbuffer.COLOR_WHITE,
			bordersize = HAIRLINE,
			color = COLOR_LINE,
			radius = 0,
			padding_left = CARD_PADDING,
			padding_right = CARD_PADDING,
			padding_top = CARD_HEADER_TOP_PAD,
			padding_bottom = CARD_BOTTOM_PAD,
			card_body,
		})

		-- One single swipe handler for the whole card -- never more than one
		-- gesture registration on the same area, which is what caused the
		-- crash after a few dictionary switches (see item 4): the old code
		-- wrapped the dictionary text AND the whole nav row separately,
		-- so a single swipe fired both switchDict and goNext/goPrev at
		-- once, corrupting dict_index/definition_entries against a word
		-- that had just changed out from under it.
		local function onCardSwipeLeft()
			if definition_mode and definition_entries and #definition_entries > 1 then
				switchDict(1)
			else
				goNext()
			end
		end
		local function onCardSwipeRight()
			if definition_mode and definition_entries and #definition_entries > 1 then
				switchDict(-1)
			else
				goPrev()
			end
		end
		card = wrapSwipeable(card, onCardSwipeLeft, onCardSwipeRight)

		-- No side arrow buttons any more -- navigation is swipe (or any
		-- other existing gesture) only, and the card itself now occupies
		-- the extra width those arrows used to take up (see CARD_WIDTH
		-- above).
		local nav_row = card

		local top_used_h = SIDE_MARGIN + TOP_BAR_HEIGHT + SECTION_GAP + HAIRLINE
		local remaining_h = math.max(nav_row:getSize().h, screen_h - top_used_h - SIDE_MARGIN)
		local centered_nav_row = CenterContainer:new({
			dimen = Geom:new({ w = screen_w, h = remaining_h }),
			nav_row,
		})

		local body = VerticalGroup:new({
			VerticalSpan:new({ width = SIDE_MARGIN }),
			HorizontalGroup:new({
				HorizontalSpan:new({ width = SIDE_MARGIN }),
				top_bar,
				HorizontalSpan:new({ width = SIDE_MARGIN }),
			}),
			VerticalSpan:new({ width = SECTION_GAP }),
			hairline(screen_w),
			centered_nav_row,
		})

		return body, body_scroll_container
	end

	rebuild = function()
		if screen then
			pcall(function() UIManager:close(screen) end)
		end
		local body, scroll_container = buildBody()
		screen = FullScreenPanel:new({
			body = body,
			cropping_widget = scroll_container,
			close_callback = function()
				if on_close then on_close() end
			end,
		})
		if scroll_container then
			scroll_container.show_parent = screen
		end
		UIManager:show(screen)
	end

	rebuild()
end

return WordReview