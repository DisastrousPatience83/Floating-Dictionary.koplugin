-- updater.lua — Floating Dictionary OTA Updater
-- Checks GitHub Releases for a newer version, informs the user,
-- and downloads + installs it in place.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger      = require("logger")
local L10n        = require("l10n")
local _           = L10n.gettext
local T           = require("ffi/util").template

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------
local GITHUB_OWNER = "DisastrousPatience83"
local GITHUB_REPO  = "Floating-Dictionary.koplugin"
local ASSET_NAME   = "floatingdictionary.koplugin.zip"

-- Cache validity time in seconds. 0 = disable cache.
local CACHE_TTL    = 3600  -- 1 hour

-- ---------------------------------------------------------------------------
-- Internals
-- ---------------------------------------------------------------------------

local M = {}

-- Plugin directory (resolved from this file's path)
local _plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")
    or "/mnt/us/extensions/floatingdictionary.koplugin"

local function _apiUrl(use_beta)
    if use_beta then
        return string.format(
            "https://api.github.com/repos/%s/%s/releases",
            GITHUB_OWNER, GITHUB_REPO
        )
    end
    return string.format(
        "https://api.github.com/repos/%s/%s/releases/latest",
        GITHUB_OWNER, GITHUB_REPO
    )
end

local function _cacheFile(use_beta)
    local suffix = use_beta and "_beta" or ""
    local ok, DS = pcall(require, "datastorage")
    if ok and DS then
        return DS:getSettingsDir() .. "/floatingdictionary_update_cache" .. suffix .. ".json"
    end
    return "/tmp/floatingdictionary_update_cache" .. suffix .. ".json"
end

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

local function _loadCache(use_beta)
    if CACHE_TTL <= 0 then return nil end
    local path = _cacheFile(use_beta)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local raw = fh:read("*a")
    fh:close()
    local ok_j, json = pcall(require, "json")
    if not ok_j then return nil end
    local ok_d, data = pcall(json.decode, raw)
    if not ok_d or type(data) ~= "table" then return nil end
    if (os.time() - (data.timestamp or 0)) > CACHE_TTL then return nil end
    -- A cached release without a download URL was saved by an older version
    -- of this updater (which only accepted one exact asset name). Ignore it
    -- so the fixed logic re-reads the release instead of reusing that miss.
    if type(data.payload) ~= "table" or not data.payload.download_url then
        return nil
    end
    return data.payload
end

local function _saveCache(payload, use_beta)
    if CACHE_TTL <= 0 then return end
    local ok_j, json = pcall(require, "json")
    if not ok_j then return end
    local ok_e, encoded = pcall(json.encode, { timestamp = os.time(), payload = payload })
    if not ok_e then return end
    local fh = io.open(_cacheFile(use_beta), "w")
    if fh then
        fh:write(encoded)
        fh:close()
    end
end

local function _clearCache(use_beta)
    pcall(os.remove, _cacheFile(use_beta))
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function _currentVersion()
    local meta_path = _plugin_dir .. "/_meta.lua"
    local ok, meta = pcall(dofile, meta_path)
    if ok and type(meta) == "table" and meta.version then
        return meta.version
    end
    return "0.0.0"
end

local function _versionLessThan(a, b)
    local function isBeta(v)
        return v:lower():find("beta") ~= nil
    end

    local function parts(v)
        local t_parts = {}
        if not v then return t_parts end
        for n in v:gmatch("(%d+)") do
            t_parts[#t_parts + 1] = tonumber(n)
        end
        return t_parts
    end

    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local va = pa[i] or 0
        local vb = pb[i] or 0
        if va < vb then return true end
        if va > vb then return false end
    end

    local betaA = isBeta(a)
    local betaB = isBeta(b)
    if betaA and not betaB then
        return true
    end

    return false
end

local function _toast(msg, timeout)
    local w = InfoMessage:new{ text = msg, timeout = timeout or 4 }
    UIManager:show(w)
    return w
end

local function _closeWidget(w)
    if w then UIManager:close(w) end
end

-- ---------------------------------------------------------------------------
-- HTTP with socketutil
-- ---------------------------------------------------------------------------

local function _httpGet(url)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local ltn12  = require("ltn12")
    local socket = require("socket")

    if ok_su then
        socketutil:set_timeout(
            socketutil.LARGE_BLOCK_TIMEOUT,
            socketutil.LARGE_TOTAL_TIMEOUT
        )
    end

    local chunks = {}
    local code, headers, status = socket.skip(1, http.request({
        url      = url,
        method   = "GET",
        headers  = {
            ["User-Agent"] = "KOReader-FloatingDictionary-Updater/1.0",
            ["Accept"]     = "application/vnd.github.v3+json",
        },
        sink     = ltn12.sink.table(chunks),
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end

    if ok_su and (
        code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    ) then
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if headers == nil then
        return nil, "network error (" .. tostring(code or status) .. ")"
    end

    if code == 200 then
        return table.concat(chunks)
    end
    return nil, string.format("HTTP %s", tostring(code))
end

local function _httpGetToFile(url, dest_path)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http   = require("socket/http")
    local ltn12  = require("ltn12")
    local socket = require("socket")

    local fh, err_open = io.open(dest_path, "wb")
    if not fh then
        return nil, "Could not create file: " .. tostring(err_open)
    end

    if ok_su then
        socketutil:set_timeout(
            socketutil.FILE_BLOCK_TIMEOUT,
            socketutil.FILE_TOTAL_TIMEOUT
        )
    end

    local code, headers, status = socket.skip(1, http.request({
        url      = url,
        method   = "GET",
        headers  = { ["User-Agent"] = "KOReader-FloatingDictionary-Updater/1.0" },
        sink     = ltn12.sink.file(fh),
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end

    if ok_su and (
        code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    ) then
        pcall(os.remove, dest_path)
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if headers == nil then
        pcall(os.remove, dest_path)
        return nil, "network error (" .. tostring(code or status) .. ")"
    end

    if code == 200 then return true end
    pcall(os.remove, dest_path)
    return nil, string.format("HTTP %s", tostring(code))
end

-- ---------------------------------------------------------------------------
-- JSON parsing
-- ---------------------------------------------------------------------------

local function _cleanReleaseNotes(raw_notes)
    if not raw_notes or raw_notes == "" then return nil end
    local notes = raw_notes
    notes = notes:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
    notes = notes:gsub("#+%s*", "")
    notes = notes:gsub("%*%*(.-)%*%*", "%1")
    notes = notes:gsub("%*(.-)%*", "%1")
    notes = notes:gsub("`(.-)`", "%1")
    notes = notes:gsub("\r\n", "\n"):gsub("\r", "\n")
    notes = notes:gsub("\n%s*\n%s*\n+", "\n\n")
    notes = notes:match("^%s*(.-)%s*$")
    if not notes or notes == "" then return nil end
    if #notes > 4000 then
        notes = notes:sub(1, 3997) .. "..."
    end
    return notes
end

local function _parseRelease(body, use_beta)
    local ok_j, json = pcall(require, "json")

    if not ok_j then
        logger.warn("floatingdictionary updater: json module not available, using fallback regex")
        local function jsonStr(key)
            return body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
        end
        local tag = jsonStr("tag_name")
        if not tag then return nil, "could not parse tag_name" end
        local download_url = body:match(
            '"browser_download_url"%s*:%s*"([^"]*'
            .. ASSET_NAME:gsub("%.", "%%.") .. '[^"]*)"'
        ) or body:match('"zipball_url"%s*:%s*"([^"]*)"')
        local notes = body:match('"body"%s*:%s*"(.-)"[,}]')
        if notes then
            notes = notes:gsub("\\n", "\n"):gsub("\\r", ""):gsub('\\"', '"'):gsub("\\\\", "\\")
            notes = _cleanReleaseNotes(notes)
        end
        return {
            version      = tag:match("v?(.*)"),
            download_url = download_url,
            notes        = notes,
        }
    end

    local ok_d, data = pcall(json.decode, body)
    if not ok_d or type(data) ~= "table" then
        return nil, "JSON parse error: " .. tostring(data)
    end

    if data.message and not data.tag_name and not (use_beta and data[1]) then
        return nil, "GitHub API error: " .. tostring(data.message)
    end

    local release_data = data
    if use_beta then
        if type(data) == "table" and data[1] then
            release_data = data[1]
        elseif type(data) == "table" and #data == 0 then
            return nil, "No releases found in repository"
        else
            return nil, "Unexpected API response format (expected array)"
        end
    end

    local tag = release_data.tag_name
    if not tag then return nil, "tag_name missing from API response" end

    -- Where to download from, in order of preference:
    --   1. the asset named exactly ASSET_NAME,
    --   2. any other .zip attached to the release,
    --   3. GitHub's auto-generated source zip (zipball_url), which EVERY
    --      release has, so a release published without attaching a zip
    --      still installs instead of "No installable package found".
    local download_url = nil
    for _, asset in ipairs(release_data.assets or {}) do
        if type(asset.name) == "string" and asset.name == ASSET_NAME then
            download_url = asset.browser_download_url
            break
        end
    end
    if not download_url then
        for _, asset in ipairs(release_data.assets or {}) do
            if type(asset.name) == "string" and asset.name:lower():match("%.zip$") then
                download_url = asset.browser_download_url
                break
            end
        end
    end
    if not download_url then
        download_url = release_data.zipball_url
    end

    local notes = _cleanReleaseNotes(release_data.body)

    return {
        version      = tag:match("v?(.*)"),
        download_url = download_url,
        notes        = notes,
        html_url     = release_data.html_url,
    }
end

-- ---------------------------------------------------------------------------
-- Unzip
-- ---------------------------------------------------------------------------

-- Extracts `zip_path` INTO the plugin folder `dest_dir`.
--
-- Uses KOReader's own ffi/archiver (libarchive) instead of the external
-- `unzip` binary, which many e-readers don't ship.
--
-- Works with both zip layouts:
--   * wrapped in one top-level folder (GitHub's zipball, or a zip that
--     contains floatingdictionary.koplugin/...): that folder is stripped;
--   * flat (main.lua at the zip root): extracted as is.
-- Before writing anything it checks the package really contains main.lua,
-- so a wrong zip fails cleanly instead of leaving a half-broken plugin.
local function _unpack(zip_path, dest_dir)
    local ok_req, Archiver = pcall(require, "ffi/archiver")
    if not (ok_req and Archiver and Archiver.Reader) then
        return nil, "archive extractor unavailable"
    end

    local function openArchive()
        local arc = Archiver.Reader:new()
        if not arc:open(zip_path) then
            local e = arc.err
            arc:close()
            return nil, e or "could not open archive"
        end
        return arc
    end

    -- Pass 1: detect the wrapper folder and validate.
    local arc, open_err = openArchive()
    if not arc then return nil, open_err end
    local root, single_root = nil, true
    local has_main_wrapped, has_main_flat = false, false
    for entry in arc:iterate() do
        local p = entry.path
        if p and p ~= "" then
            local first, rest = p:match("^([^/]+)/(.*)$")
            if first then
                if root == nil then
                    root = first
                elseif root ~= first then
                    single_root = false
                end
                if rest == "main.lua" then has_main_wrapped = true end
            else
                single_root = false
                if p == "main.lua" then has_main_flat = true end
            end
        end
    end
    arc:close()

    local strip = single_root and root ~= nil
    if not ((strip and has_main_wrapped) or (not strip and has_main_flat)) then
        return nil, "package does not contain main.lua"
    end

    -- Pass 2: extract.
    arc, open_err = openArchive()
    if not arc then return nil, open_err end
    local extract_err
    for entry in arc:iterate() do
        local p = entry.path
        if p and p ~= "" then
            local rel = p
            if strip then rel = p:match("^[^/]+/(.+)$") end
            -- Skip directory entries (libarchive creates parent dirs when
            -- writing files) and refuse paths that try to climb out.
            if rel and rel ~= "" and rel:sub(-1) ~= "/" then
                if rel:find("..", 1, true) then
                    extract_err = "unsafe path in archive: " .. rel
                    break
                end
                if not arc:extractToPath(p, dest_dir .. "/" .. rel) then
                    extract_err = arc.err or "extract failed"
                    break
                end
            end
        end
    end
    arc:close()
    if extract_err then return nil, extract_err end
    return true
end

-- ---------------------------------------------------------------------------
-- Download & Install
-- ---------------------------------------------------------------------------

local function _tmpZipPath()
    local ok, DS = pcall(require, "datastorage")
    if ok and DS then
        return DS:getSettingsDir() .. "/floatingdictionary_update.zip"
    end
    local probe = "/tmp/.floatingdictionary_probe"
    local fh = io.open(probe, "w")
    if fh then fh:close(); os.remove(probe); return "/tmp/floatingdictionary_update.zip" end
    return _plugin_dir .. "/floatingdictionary_update.zip"
end

local function _applyUpdate(download_url, new_version)
    local tmp_zip    = _tmpZipPath()

    local progress_msg = _toast(
        T(_("Downloading Floating Dictionary %1…"), new_version), 120
    )

    local ok_tr, Trapper = pcall(require, "ui/trapper")

    local function doDownloadAndInstall()
        -- 1. Download the update zip
        local dl_ok, dl_err = _httpGetToFile(download_url, tmp_zip)
        if not dl_ok then
            return { success = false, stage = "download", err = dl_err }
        end

        -- 2. Extract over the existing plugin folder.
        -- NOTE: all of this plugin's settings live in G_reader_settings
        -- (not in a file inside the plugin folder), so there is nothing to
        -- back up/restore across the overwrite.
        local uz_ok, uz_err = _unpack(tmp_zip, _plugin_dir)
        os.remove(tmp_zip)
        if not uz_ok then
            return { success = false, stage = "unzip", err = uz_err }
        end

        return { success = true }
    end

    local function handleInstallResult(result)
        _closeWidget(progress_msg)
        if not result or not result.success then
            local stage = result and result.stage or "unknown"
            local err   = result and result.err   or "unknown error"
            logger.err("floatingdictionary updater: failed at", stage, "-", err)
            if stage == "download" then
                _toast(T(_("Update download failed: %1"), tostring(err)))
            else
                _toast(T(_("Update install failed: %1"), tostring(err)))
            end
            return
        end
        _clearCache(true)
        _clearCache(false)
        local ButtonDialog = require("ui/widget/buttondialog")
        local success_dlg
        success_dlg = ButtonDialog:new{
            title = T(_("Floating Dictionary updated to %1.\nRestart KOReader to finish."), new_version),
            buttons = {{
                {
                    text = _("Later"),
                    callback = function()
                        UIManager:close(success_dlg)
                    end,
                },
                {
                    text = _("Restart now"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(success_dlg)
                        UIManager:restartKOReader()
                    end,
                },
            }},
        }
        UIManager:show(success_dlg)
    end

    if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(
            doDownloadAndInstall,
            progress_msg,
            function(res) handleInstallResult(res) end
        )
        if completed and result then
            UIManager:scheduleIn(0.2, function() handleInstallResult(result) end)
        elseif completed == false then
            _closeWidget(progress_msg)
            pcall(os.remove, tmp_zip)
            _toast(_("Update cancelled."))
        end
    else
        UIManager:scheduleIn(0.3, function()
            handleInstallResult(doDownloadAndInstall())
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Release notes formatting / dialogs
-- ---------------------------------------------------------------------------

local function _formatInlineNotes(notes, screen_h)
    if not notes or notes == "" then
        return nil, false
    end

    local cleaned = notes:gsub("^[Ww]hat'?s%s+[Nn]ew[:%s]*\n*", "")
    cleaned = cleaned:match("^%s*(.-)%s*$") or cleaned
    if cleaned == "" then
        return nil, false
    end

    local max_lines
    local max_chars
    if screen_h < 700 then
        max_lines = 3
        max_chars = 140
    elseif screen_h < 900 then
        max_lines = 5
        max_chars = 220
    else
        max_lines = 7
        max_chars = 320
    end

    local raw_lines = {}
    for line in (cleaned .. "\n"):gmatch("([^\n]*)\n") do
        if #raw_lines > 0 or line:match("%S") then
            table.insert(raw_lines, line)
        end
    end
    while #raw_lines > 0 and raw_lines[#raw_lines]:match("^%s*$") do
        table.remove(raw_lines)
    end

    local result_lines = {}
    local total_chars = 0
    local is_truncated = false

    for _, line in ipairs(raw_lines) do
        if #result_lines >= max_lines then
            is_truncated = true
            break
        end
        if total_chars + #line > max_chars then
            if #result_lines == 0 then
                local sub = line:sub(1, max_chars)
                local last_space = sub:match("^.*()%s")
                if last_space and last_space > 20 then
                    sub = sub:sub(1, last_space - 1)
                end
                table.insert(result_lines, sub .. "...")
            end
            is_truncated = true
            break
        end
        table.insert(result_lines, line)
        total_chars = total_chars + #line + 1
    end

    if #raw_lines > #result_lines then
        is_truncated = true
    end

    local preview = table.concat(result_lines, "\n"):match("^%s*(.-)%s*$")
    if is_truncated and preview then
        if not preview:match("%.%.%.$") then
            preview = preview .. "\n..."
        end
    end

    return preview, is_truncated
end

local function _showFullNotesViewer(title_str, full_notes, download_url, latest_version, parent_dialog)
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    local viewer_buttons = {{
        {
            text = _("Back"),
            callback = function()
                UIManager:close(viewer)
            end,
        },
    }}
    if download_url then
        table.insert(viewer_buttons[1], {
            text = _("Download"),
            is_enter_default = true,
            callback = function()
                UIManager:close(viewer)
                if parent_dialog then
                    UIManager:close(parent_dialog)
                end
                _applyUpdate(download_url, latest_version)
            end,
        })
    end
    viewer = TextViewer:new{
        title = title_str,
        text = full_notes,
        buttons_table = viewer_buttons,
    }
    UIManager:show(viewer)
end

local function _showUpdateDialog(release, current)
    local latest       = release.version
    local download_url = release.download_url
    local notes        = release.notes

    if not _versionLessThan(current, latest) then
        logger.info("floatingdictionary updater: up to date (" .. current .. ")")
        _toast(T(_("Floating Dictionary is up to date (%1)."), current))
        return
    end

    logger.info("floatingdictionary updater: new version available:", latest)

    local ok_dev, Device = pcall(require, "device")
    local Screen = ok_dev and Device and Device.screen
    local screen_h = (Screen and Screen.getHeight and Screen:getHeight()) or 800

    local header = T(_("Floating Dictionary %1 is available (you have %2)."), latest, current)
    local footer = "\n\n" .. _("Download and install now?")

    local inline_notes, has_more_notes = _formatInlineNotes(notes, screen_h)
    local notes_block = inline_notes
        and ("\n\n" .. _("What's new:") .. "\n" .. inline_notes)
        or  ""

    local notes_viewer_title = T(_("Floating Dictionary %1 – Release notes"), latest)

    local ButtonDialog = require("ui/widget/buttondialog")
    if not download_url then
        local no_asset_dlg
        local no_asset_buttons = {}
        if has_more_notes and notes then
            table.insert(no_asset_buttons, {
                {
                    text = _("View full release notes"),
                    callback = function()
                        _showFullNotesViewer(notes_viewer_title, notes, nil, latest, no_asset_dlg)
                    end,
                },
            })
        end
        table.insert(no_asset_buttons, {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(no_asset_dlg)
                end,
            },
            {
                text = _("Open in browser"),
                is_enter_default = true,
                callback = function()
                    UIManager:close(no_asset_dlg)
                    if ok_dev and Device and Device.canOpenLink and Device:canOpenLink() then
                        Device:openLink(release.html_url or string.format(
                            "https://github.com/%s/%s/releases/latest",
                            GITHUB_OWNER, GITHUB_REPO
                        ))
                    end
                end,
            },
        })

        local dlg_props = {
            title = header .. notes_block .. "\n\n" .. _("No installable package found in this release."),
            buttons = no_asset_buttons,
        }
        if screen_h < 700 then
            local ok_f, Font = pcall(require, "ui/font")
            if ok_f and Font then
                dlg_props.info_face = Font:getFace("x_smallinfofont")
            end
        end
        no_asset_dlg = ButtonDialog:new(dlg_props)
        UIManager:show(no_asset_dlg)
        return
    end

    local update_dlg
    local update_buttons = {}
    if has_more_notes and notes then
        table.insert(update_buttons, {
            {
                text = _("View full release notes"),
                callback = function()
                    _showFullNotesViewer(notes_viewer_title, notes, download_url, latest, update_dlg)
                end,
            },
        })
    end
    table.insert(update_buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(update_dlg)
            end,
        },
        {
            text = _("Download"),
            is_enter_default = true,
            callback = function()
                UIManager:close(update_dlg)
                _applyUpdate(download_url, latest)
            end,
        },
    })

    local dlg_props = {
        title = header .. notes_block .. footer,
        buttons = update_buttons,
    }
    if screen_h < 700 then
        local ok_f, Font = pcall(require, "ui/font")
        if ok_f and Font then
            dlg_props.info_face = Font:getFace("x_smallinfofont")
        end
    end
    update_dlg = ButtonDialog:new(dlg_props)
    UIManager:show(update_dlg)
end

-- ---------------------------------------------------------------------------
-- Fetch / public API
-- ---------------------------------------------------------------------------

local function _doFetch(use_beta)
    local cached = _loadCache(use_beta)
    if cached then
        logger.info("floatingdictionary updater: using cache (" .. (use_beta and "beta" or "stable") .. ")")
        return cached
    end
    local body, err = _httpGet(_apiUrl(use_beta))
    if not body then return { error = err } end
    local release, parse_err = _parseRelease(body, use_beta)
    if not release then return { error = "parse error: " .. tostring(parse_err) } end
    _saveCache(release, use_beta)
    return release
end

function M._doCheckForUpdates(current, use_beta)
    local checking_msg = _toast(_("Checking for updates…"), 15)
    local ok_tr, Trapper = pcall(require, "ui/trapper")

    local function handleCheckResult(release)
        _closeWidget(checking_msg)
        if not release then
            _toast(_("Could not check for updates."))
            return
        end
        if release.error then
            logger.err("floatingdictionary updater: check error:", release.error)
            _toast(T(_("Could not check for updates: %1"), tostring(release.error)))
            return
        end
        _showUpdateDialog(release, current)
    end

    if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(
            function() return _doFetch(use_beta) end,
            checking_msg,
            function(res) handleCheckResult(res) end
        )
        if completed and result then
            UIManager:scheduleIn(0.2, function() handleCheckResult(result) end)
        elseif completed == false then
            _closeWidget(checking_msg)
            _toast(_("Update check cancelled."))
        end
    else
        UIManager:scheduleIn(0.3, function()
            handleCheckResult(_doFetch(use_beta))
        end)
    end
end

--- Shows "checking…" feedback and an update dialog if one is available.
-- Call this from a menu item (e.g. "Check for updates").
-- @param use_beta if true, checks the newest release/pre-release instead
--   of only the latest stable release.
function M.checkForUpdates(use_beta)
    local current = _currentVersion()
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(function()
            M._doCheckForUpdates(current, use_beta)
        end)
        return
    end
    M._doCheckForUpdates(current, use_beta)
end

--- Silent check: only pops a dialog if a newer version is actually found,
-- no "checking..." toast. Safe to call on plugin init/on-document-open.
function M.checkSilentForUpdates(use_beta)
    local current = _currentVersion()
    local release = _doFetch(use_beta)

    if release and not release.error then
        if _versionLessThan(current, release.version) then
            _showUpdateDialog(release, current)
        end
    end
end

M._cleanReleaseNotes = _cleanReleaseNotes
M._formatInlineNotes = _formatInlineNotes
M._showUpdateDialog = _showUpdateDialog

return M
