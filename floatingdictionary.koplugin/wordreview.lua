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

local DocSettings = require("docsettings")
local dump = require("dump")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local WordReview = {}

WordReview.HISTORY_FILENAME = "wordreview_history.lua"

-- Persisted, user-facing toggles: whether the review popup should be shown
-- automatically when a book is opened, and/or whenever KOReader wakes up
-- from suspend. Two fully independent settings -- either, both, or neither
-- can be on at once. Off by default would defeat the point of a discovery
-- feature, so both default to *on* (nilOrTrue), same convention as every
-- other boolean setting in this plugin.
WordReview.SETTING_ENABLED_ON_OPEN = "floatingdictionary_wordreview_on_open"
WordReview.SETTING_ENABLED_ON_RESUME = "floatingdictionary_wordreview_on_resume"

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
function WordReview:genMenu()
	return {
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

-- Records (or updates) a single lookup. Called every time the dictionary is
-- successfully queried for a real word, regardless of which popup ends up
-- displaying it (floating card or native KOReader popup) -- this is the
-- single point of truth for the book's vocabulary history, so it always
-- stays in sync with actual dictionary usage. Cheap enough to call on every
-- lookup: a small per-book file read + rewrite.
function WordReview:recordLookup(plugin, word)
	if not word or word == "" then
		return
	end

	local key = self:normalizeKey(word)
	if key == "" then
		return
	end

	local history = self:loadHistory(plugin)
	local entry = history.words[key]
	if entry then
		entry.count = (entry.count or 1) + 1
		entry.last_ts = os.time()
		-- Keep the most recently-seen casing/spelling as the display form;
		-- purely cosmetic, doesn't affect the key or the count.
		entry.word = word
	else
		history.words[key] = {
			word = word,
			count = 1,
			last_ts = os.time(),
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
	for _, entry in pairs(history.words or {}) do
		table.insert(entries, entry)
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
			return entry
		end
	end

	-- Floating point safety net: should be unreachable, but guarantees a
	-- word is always returned rather than nil if rounding ever leaves a
	-- sliver of `roll` unaccounted for.
	return entries[#entries]
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

-- Top-level entry point: returns { word = "...", from_fallback = bool } for
-- the word to review right now, or nil if nothing could be found at all
-- (no history and no usable dictionary -- an edge case, but handled so the
-- caller can simply skip showing anything rather than crash).
function WordReview:pickWordToReview(plugin)
	local history = self:loadHistory(plugin)
	local from_history = self:pickFromHistory(history)
	if from_history then
		return { word = from_history.word, from_fallback = false }
	end

	return self:pickFallbackWord(plugin)
end

-------------------------------------------------------------------------------
-- Triggering the review popup on book open
-------------------------------------------------------------------------------

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

	plugin:showReviewPopup(choice.word, results)
end

return WordReview