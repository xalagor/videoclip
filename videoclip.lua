--[[
Videoclip - mp4/webm clips creator for mpv.

Copyright (C) 2021 Ren Tatsumoto

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
]]

local NAME = 'videoclip'
local mp = require('mp')
local mpopt = require('mp.options')
local utils = require('mp.utils')
local p = require('platform')
local h = require('helpers')
local encoder = require('encoder')
local OSD = require('osd_styler')
local Timings = require('timings_mgr')
local cropper = require('cropper')

------------------------------------------------------------
-- System-dependent variables

-- Options can be changed here or in a separate config file.
-- Config path: ~/.config/mpv/script-opts/videoclip.conf
local config = {
    -- absolute paths
    -- relative paths (e.g. ~ for home dir) do NOT work.
    video_folder_path = p.default_video_folder,
    audio_folder_path = p.default_audio_folder,
    -- The range of the CRF scale is 0–51, where 0 is lossless,
    -- 23 is the default, and 51 is worst quality possible.
    -- Insane values like 9999 still work but produce the worst quality.
    video_quality = 23,
    -- Use the slowest preset that you have patience for.
    -- https://trac.ffmpeg.org/wiki/Encode/H.264
    preset = 'faster',
    video_format = 'mp4', -- mp4, vp9, vp8
    video_bitrate = '1M',
    video_width = -2,
    video_height = 480,
    video_fps = 'auto',
    audio_format = 'opus', -- aac, opus
    audio_bitrate = '32k', -- 32k, 64k, 128k, 256k. aac requires higher bitrates.
    font_size = 24,
    -- ASS \an tag of the corner overlay menu. 9 = top right (default, so the card
    -- does not cover the top-left title/playlist overlay drawn by the mpv UI
    -- script), 7 = top left (the original placement), 1 = bottom left.
    -- https://aegisub.org/docs/3.2/ASS_Tags/#\an
    osd_align = 9,
    osd_outline = 1.5,
    clean_filename = true,
    -- Whether to upload to catbox (permanent) or litterbox (temporary)
    litterbox = true,
    -- Determines expire time of files uploaded to litterbox
    litterbox_expire = '72h', -- 1h, 12h, 24h, 72h
    sub_font = 'Noto Sans CJK JP',

    -- Custom upload command. %f will be replaced with the file path.
    -- Example for 0x0.st: curl -F'file=@%f' https://0x0.st
    custom_upload_command = '',

    -- Filename format
    -- Available tags: %n = filename, %t = title, %s = start, %e = end, %d = duration,
    --                 %Y = year, %M = months, %D = day, %H = hours (24), %I = hours (12),
    --                 %P = am/pm %N = minutes, %S = seconds
    filename_template = '%n_%s-%e',

    video_codec = '',
    audio_codec = '',
    -- Upload destination settings
    upload_dest = 'litterbox', -- litterbox, catbox, anytype
    anytype_api_url = 'http://127.0.0.1:31009',
    anytype_api_key = '',
    anytype_space_id = '',
    anytype_version = '2025-11-08',
    use_ffmpeg = true,
    ffmpeg_path = 'ffmpeg',
    ffmpeg_video_codec = 'libsvtav1',
    ffmpeg_video_crf = '24',
    ffmpeg_preset = '5',
    ffmpeg_audio_codec = 'libopus',
    ffmpeg_audio_bitrate = '128k',
}

mpopt.read_options(config, NAME)

local allowed_presets = {
    ultrafast = true,
    superfast = true,
    veryfast = true,
    faster = true,
    fast = true,
    medium = true,
    slow = true,
    slower = true,
    veryslow = true,
}

------------------------------------------------------------
-- Utility functions

local function force_resolution(width, height, clip_fn, ...)
    local cached_prefs = {
        video_width = config.video_width,
        video_height = config.video_height,
    }
    config.video_width = width
    config.video_height = height
    clip_fn(...)
    config.video_width = cached_prefs.video_width
    config.video_height = cached_prefs.video_height
end

local function set_encoding_settings()
    if config.video_codec == '' then
        if config.video_format == 'mp4' then
            config.video_codec = p.platform == p.Platform.windows and 'h264_mf' or 'libx264'
        elseif config.video_format == 'vp9' then
            config.video_codec = 'libvpx-vp9'
        else
            config.video_codec = 'libvpx'
        end
    end

    if config.video_format == 'mp4' then
        config.video_extension = '.mp4'
    elseif config.video_format == 'vp9' then
        config.video_extension = '.webm'
    else
        config.video_extension = '.webm'
    end

    if config.audio_codec == '' then
        if config.audio_format == 'aac' then
            config.audio_codec = 'aac'
        else
            config.audio_codec = p.platform == p.Platform.windows and 'opus' or 'libopus'
        end
    end

    if config.audio_format == 'aac' then
        config.audio_extension = '.aac'
    else
        config.audio_extension = '.opus'
    end
end

local function validate_config()
    -- Migration: if legacy litterbox=false and upload_dest is default 'litterbox', switch to catbox
    if config.litterbox == false and config.upload_dest == 'litterbox' then
        config.upload_dest = 'catbox'
    end

    if not config.audio_bitrate:match('^%d+[kK]$') then
        config.audio_bitrate = (tonumber(config.audio_bitrate) or 32) .. 'k'
    end

    if not config.video_bitrate:match('^%d+[kKmM]$') then
        config.video_bitrate = '1M'
    end

    if not allowed_presets[config.preset] then
        config.preset = 'faster'
    end

    set_encoding_settings()
end

local function upload_to_catbox(outfile)
    local endpoint = config.litterbox and 'https://litterbox.catbox.moe/resources/internals/api.php' or 'https://catbox.moe/user/api.php'
    h.notify("Uploading to " .. (config.litterbox and "litterbox.catbox.moe..." or "catbox.moe..."), "info", 9999)

    -- This uses cURL to send a request to the cat-/litterbox API.
    -- cURL is included on Windows 10 and up, most Linux distributions and macOS.

    local r = h.subprocess({ -- This is technically blocking, but I don't think it has any real consequences ..?
        p.curl_exe, '-s',
        '-F', 'reqtype=fileupload',
        '-F', 'time=' .. config['litterbox_expire'],
        '-F', 'fileToUpload=@"' .. outfile .. '"',
        endpoint
    })

    -- Exit codes in the range [0, 99] are returned by cURL itself.
    -- Any other exit code means the shell failed to execute cURL.
    if r.status < 0 or r.status > 99 then
        h.notify_error("Error: Failed to upload. Make sure cURL is installed and in your PATH.", "error", 3)
        return
    elseif r.status ~= 0 then
        h.notify_error("Error: Failed to upload to " .. (config.litterbox and "litterbox.catbox.moe" or "catbox.moe"), "error", 2)
        return
    end

    mp.msg.info("Catbox URL: " .. r.stdout)
    -- Copy to clipboard
    p.copy_or_open_url(r.stdout)
end

local function parse_command_args(cmd_str)
    local args = {}

    local buffer = ""
    local in_quote = false
    for i = 1, #cmd_str do
        local c = cmd_str:sub(i, i)

        if c == '"' then
            in_quote = not in_quote
        elseif c:match("%s") and not in_quote then
            if buffer ~= "" then
                table.insert(args, buffer)
                buffer = ""
            end
        else
            buffer = buffer .. c
        end
    end

    if buffer ~= "" then
        table.insert(args, buffer)
    end

    return args
end

local function upload_to_custom(outfile)
    h.notify("Upload to custom destination", "info", 9999)

    local raw_args = parse_command_args(config.custom_upload_command)
    local exec_args = {}

    for _, arg in ipairs(raw_args) do
        local clean_arg = arg:gsub('%%f', function()
            return outfile
        end)
        table.insert(exec_args, clean_arg)
    end

    local r = h.subprocess(exec_args)

    if r.status ~= 0 then
        h.notify_error("Error: Upload failed with exit code " .. r.status, "error", 2)
        mp.msg.error("Upload stderr: " .. (r.stderr or ""))
        return
    end

    -- Assumes the command outputs the URL to stdout
    mp.msg.info("Upload URL: " .. r.stdout)
    local url = h.strip(r.stdout)
    p.copy_or_open_url(url)
end

local function resolve_anytype_config()
    local api_key = config.anytype_api_key
    if not api_key or api_key == '' then
        api_key = os.getenv("ANYTYPE_APP_KEY") or os.getenv("ANYTYPE_API_KEY") or ''
    end
    local space_id = config.anytype_space_id
    if not space_id or space_id == '' then
        space_id = os.getenv("ANYTYPE_SPACE_ID") or ''
    end
    return api_key, space_id
end

local function upload_to_anytype(file_path, source_url, content_from_id)
    mp.msg.info(string.format(
        "upload_to_anytype called: file_path=%s, source_url=%s, content_from_id=%s",
        file_path, tostring(source_url), tostring(content_from_id)
    ))

    local api_key, space_id = resolve_anytype_config()
    if api_key == '' or space_id == '' then
        h.notify_error("Anytype config missing: set anytype_api_key and anytype_space_id", "error", 4)
        return
    end

    h.notify("Uploading to Anytype via REST API...", "info", 9999)
    local base_url = config.anytype_api_url:gsub("/+$", "")
    local headers = {
        "-H", "Authorization: Bearer " .. api_key,
        "-H", "Anytype-Version: " .. config.anytype_version,
    }

    -- Step 1: Upload file to v2 API
    local upload_url = string.format("%s/v2/spaces/%s/files", base_url, space_id)
    local upload_cmd = {
        p.curl_exe, "-s",
        "-X", "POST",
        upload_url,
    }
    for _, header in ipairs(headers) do
        table.insert(upload_cmd, header)
    end
    table.insert(upload_cmd, "-F")
    table.insert(upload_cmd, "file=@" .. file_path)

    local upload_r = h.subprocess(upload_cmd)
    if upload_r.status ~= 0 then
        h.notify_error("Error: Anytype file upload failed. Status: " .. tostring(upload_r.status), "error", 4)
        mp.msg.error("Anytype upload stderr: " .. (upload_r.stderr or ""))
        return
    end

    local upload_out = upload_r.stdout
    if not upload_out or upload_out == "" then
        h.notify_error("Error: Anytype file upload returned empty response.", "error", 4)
        return
    end

    local file_id = upload_out:match('"file_id"%s*:%s*"([^"]+)"')
        or upload_out:match('"id"%s*:%s*"([^"]+)"')
    if not file_id then
        h.notify_error("Error: Anytype file upload returned invalid response.", "error", 4)
        mp.msg.error("Anytype upload stdout: " .. upload_out)
        return
    end

    mp.msg.info("Anytype file uploaded, file_id: " .. file_id)

    -- Step 2: Create Bookmark object with v2 API
    local objects_url = string.format("%s/v2/spaces/%s/objects", base_url, space_id)
    local clip_name = h.clean_forbidden_characters(
        mp.get_property("media-title", "clip")
    )

    local properties = {}
    if source_url then
        properties.source = source_url
    end
    if file_id then
        properties.files = { file_id }
    end

    local obj_body = utils.format_json({
        type = "Bookmark",
        name = clip_name,
        properties = properties,
    })

    local create_cmd = {
        p.curl_exe, "-s",
        "-X", "POST",
        objects_url,
    }
    for _, header in ipairs(headers) do
        table.insert(create_cmd, header)
    end
    table.insert(create_cmd, "-H")
    table.insert(create_cmd, "Content-Type: application/json")
    table.insert(create_cmd, "-d")
    table.insert(create_cmd, obj_body)

    local create_r = h.subprocess(create_cmd)
    if create_r.status ~= 0 then
        h.notify_error("Error: Anytype object creation failed. Status: " .. tostring(create_r.status), "error", 4)
        mp.msg.error("Anytype object creation stderr: " .. (create_r.stderr or ""))
        os.remove(file_path)
        return
    end

    local create_out = create_r.stdout
    if not create_out or create_out == "" then
        h.notify_error("Error: Anytype object creation returned empty response.", "error", 4)
        os.remove(file_path)
        return
    end

    local object_id = create_out:match('"id"%s*:%s*"([^"]+)"')
        or create_out:match('"object_id"%s*:%s*"([^"]+)"')
    if not object_id then
        h.notify_error("Error: Anytype object creation returned invalid response.", "error", 4)
        mp.msg.error("Anytype object creation stdout: " .. create_out)
        os.remove(file_path)
        return
    end

    mp.msg.info("Anytype Bookmark object created, object_id: " .. object_id)

    -- Step 3: Patch object with Content From relation if provided
    if content_from_id then
        local patch_url = string.format("%s/v2/spaces/%s/objects/%s", base_url, space_id, object_id)
        local patch_body = utils.format_json({
            ops = {
                {
                    op = "set_properties",
                    set = {
                        content_from = content_from_id,
                    },
                },
            },
        })

        local patch_cmd = {
            p.curl_exe, "-s",
            "-X", "PATCH",
            patch_url,
        }
        for _, header in ipairs(headers) do
            table.insert(patch_cmd, header)
        end
        table.insert(patch_cmd, "-H")
        table.insert(patch_cmd, "Content-Type: application/json")
        table.insert(patch_cmd, "-d")
        table.insert(patch_cmd, patch_body)

        local patch_r = h.subprocess(patch_cmd)
        if patch_r.status ~= 0 then
            mp.msg.warn("Anytype object patch failed (content_from): " .. (patch_r.stderr or ""))
        else
            mp.msg.info("Anytype Bookmark patched with content_from: " .. content_from_id)
        end
    end

    -- Copy link to clipboard
    local link = string.format("anytype://object?objectId=%s&spaceId=%s", object_id, space_id)
    local cb = p.clipboard.copy(link)
    if cb.status ~= 0 then
        h.notify("Uploaded to Anytype!\nFailed to copy link to clipboard.", "warn", 4)
    else
        h.notify("Uploaded to Anytype!\nLink copied to clipboard.", "info", 4)
    end

    -- Delete local file
    local deleted, err = os.remove(file_path)
    if not deleted then
        mp.msg.error("Failed to delete local file: " .. (err or ""))
    end
end

local function upload_video(outfile)
    if config.upload_dest == 'anytype' then
        upload_to_anytype(outfile, nil, nil)
    elseif config.upload_dest == 'custom' or config.custom_upload_command ~= '' then
        upload_to_custom(outfile)
    elseif config.upload_dest == 'catbox' then
        local old_litterbox = config.litterbox
        config.litterbox = false
        upload_to_catbox(outfile)
        config.litterbox = old_litterbox
    else
        local old_litterbox = config.litterbox
        config.litterbox = true
        upload_to_catbox(outfile)
        config.litterbox = old_litterbox
    end
end

local function fmt_upload_dest()
    local upload_dest
    if config.custom_upload_command ~= '' then
        upload_dest = 'custom upload'
    elseif config.upload_dest == 'anytype' then
        upload_dest = 'Anytype'
    elseif config.upload_dest == 'litterbox' then
        upload_dest = 'litterbox.catbox.moe (' .. config.litterbox_expire .. ')'
    else
        upload_dest = 'catbox.moe'
    end

    return upload_dest
end

------------------------------------------------------------
-- Menu interface
--
-- A Menu owns one ASS overlay, shared with its parent when it has one, and
-- binds its hotkeys with mp.add_forced_key_binding only while it is visible.
-- Closing releases them, so the plugin keeps the original single-key UX and
-- the user's own mpv bindings come back on ESC.

local Menu = {}
Menu.__index = Menu

local main_menu, pref_menu

function Menu:new(parent)
    local o = {
        parent = parent,
        overlay = parent and parent.overlay or mp.create_osd_overlay('ass-events'),
        keybindings = {},
    }
    return setmetatable(o, self)
end

function Menu:overlay_draw(text)
    self.overlay.data = text
    self.overlay:update()
end

function Menu:open()
    if self.parent then
        self.parent:close()
    end
    for _, val in pairs(self.keybindings) do
        mp.add_forced_key_binding(val.key, val.key, val.fn)
    end
    self:update()
end

function Menu:close()
    for _, val in pairs(self.keybindings) do
        mp.remove_key_binding(val.key)
    end
    if self.parent then
        self.parent:open()
    else
        self.overlay:remove()
    end
end

function Menu:update()
    local osd = OSD:new():config(config)
    osd:append('Dummy menu.'):newline()
    self:overlay_draw(osd:get_text())
end

------------------------------------------------------------
-- Media generation callbacks

-- Keep the result locally. The encoder already reported where it saved the file.
local function save_locally(_) end

-- Upload to the configured destination. Anytype gets the embedded file and
-- the source URL; no Content From relation is set, because the media search
-- that used to supply it is disabled.
local function upload_to_dest(file_path)
    if config.upload_dest == 'anytype' then
        upload_to_anytype(file_path, encoder.get_youtube_url(), nil)
    else
        upload_video(file_path)
    end
end

------------------------------------------------------------
-- Main menu

main_menu = Menu:new()
main_menu.timings = Timings:new()

local function current_crop_text()
    local vf_table = mp.get_property_native("vf") or {}
    for _, filter in ipairs(vf_table) do
        if filter.name == "crop" and filter.params then
            local cp = filter.params
            return string.format('%sx%s at %s,%s', cp.w or '?', cp.h or '?', cp.x or '0', cp.y or '0')
        end
    end
    return 'none'
end

main_menu.keybindings = {
    { key = 's', fn = function()
        main_menu:set_time('start')
    end },
    { key = 'e', fn = function()
        main_menu:set_time('end')
    end },
    { key = 'S', fn = function()
        main_menu:set_time_sub('start')
    end },
    { key = 'E', fn = function()
        main_menu:set_time_sub('end')
    end },
    { key = 'r', fn = function()
        main_menu:reset_timings()
    end },
    { key = 'c', fn = function()
        main_menu:create_clip('video')
    end },
    { key = 'C', fn = function()
        main_menu:create_clip('video-fullhd')
    end },
    { key = 'a', fn = function()
        main_menu:create_clip('audio')
    end },
    { key = 'x', fn = function()
        main_menu:create_clip('video', true)
    end },
    { key = 'f', fn = function()
        main_menu:take_screenshot()
    end },
    { key = 'k', fn = function()
        main_menu:start_crop()
    end },
    { key = 'd', fn = function()
        main_menu:clear_crop()
    end },
    { key = 'p', fn = function()
        pref_menu:open()
    end },
    { key = 'o', fn = function()
        p.open('https://streamable.com/')
    end },
    { key = 'ESC', fn = function()
        main_menu:close()
    end },
}

function main_menu:set_time(property)
    local time_pos = mp.get_property_number('time-pos')
    if time_pos == nil then
        h.notify_error("Warning: No media loaded.", "warn", 2)
        return
    end
    self.timings[property] = math.max(0, time_pos)
    self:update()
end

function main_menu:set_time_sub(property)
    local sub_delay = mp.get_property_native("sub-delay") or 0
    local time_pos = mp.get_property_number(string.format("sub-%s", property))

    if time_pos == nil then
        h.notify_error("Warning: No subtitles visible.", "warn", 2)
        return
    end

    self.timings[property] = math.max(0, time_pos + sub_delay)
    self:update()
end

function main_menu:reset_timings()
    self.timings:reset()
    self:update()
end

-- clip_type is 'video', 'audio' or 'video-fullhd'. When upload is true the
-- result is sent to the configured destination instead of only being saved.
function main_menu:create_clip(clip_type, upload)
    local on_complete = upload and upload_to_dest or save_locally
    self:close()

    if clip_type == 'video-fullhd' then
        force_resolution(1920, -2, encoder.create_clip, "video", on_complete)
    else
        encoder.create_clip(clip_type, on_complete)
    end
end

function main_menu:take_screenshot()
    self:close()
    encoder.extract_screenshot(function(file_path)
        if config.upload_dest == 'anytype' then
            upload_to_anytype(file_path, encoder.get_youtube_url(), nil)
        end
    end)
end

function main_menu:start_crop()
    self:close()
    cropper.start()
end

function main_menu:clear_crop()
    cropper.clear_crop()
    self:update()
end

main_menu.open = function()
    Menu.open(main_menu)
end

function main_menu:update()
    local osd = OSD:new():config(config)
    if encoder.alive == false then
        osd:red("Error: "):append("mpv is not found in the PATH."):newline()
    end
    osd:submenu('Timings '):italics('(+shift use sub timings)'):newline()
    osd:tab():item('s: '):append('start time '):item(h.human_readable_time(self.timings['start'])):newline()
    osd:tab():item('e: '):append('end time '):item(h.human_readable_time(self.timings['end'])):newline()
    osd:tab():item('r: '):append('reset'):newline()
    osd:submenu('Create clip '):italics('(+shift to force fullHD preset)'):newline()
    osd:tab():item('c: '):append('video clip'):newline()
    osd:tab():item('a: '):append('audio clip'):newline()
    osd:tab():item('f: '):append('screenshot'):newline()
    osd:tab():item('x: '):append('video clip to ' .. fmt_upload_dest()):newline()
    osd:submenu('Crop '):newline()
    osd:tab():item('k: '):append('select crop zone (currently '):append(current_crop_text()):append(')'):newline()
    osd:tab():item('d: '):append('clear crop'):newline()
    osd:submenu('Options '):newline()
    osd:tab():item('p: '):append('Open preferences'):newline()
    osd:tab():item('o: '):append('Open streamable.com'):newline()
    osd:tab():item('ESC: '):append('Close'):newline()
    self:overlay_draw(osd:get_text())
end

------------------------------------------------------------
-- Preferences

pref_menu = Menu:new(main_menu)

pref_menu.resolutions = {
    { w = -2, h = -2 },
    { w = -2, h = 240 },
    { w = -2, h = 360 },
    { w = -2, h = 480 },
    { w = -2, h = 720 },
    { w = -2, h = 1080 },
    { w = -2, h = 1440 },
    { w = -2, h = 2160 },
    selected = 1,
}
pref_menu.video_bitrates = { '500k', '1M', '2M', '4M', '8M', '16M', selected = 1 }
pref_menu.audio_bitrates = { '32k', '64k', '128k', '192k', '256k', '384k', selected = 1 }
pref_menu.vid_formats = { 'mp4', 'vp9', 'vp8' }
pref_menu.aud_formats = { 'aac', 'opus' }
pref_menu.upload_dests = { 'litterbox', 'catbox', 'anytype' }
pref_menu.litterbox_expirations = { '1h', '12h', '24h', '72h' }

pref_menu.keybindings = {
    { key = 'r', fn = function()
        pref_menu:cycle_resolutions()
    end },
    { key = 'f', fn = function()
        pref_menu:cycle_formats('video_format')
    end },
    { key = 'a', fn = function()
        pref_menu:cycle_formats('audio_format')
    end },
    { key = 'b', fn = function()
        pref_menu:cycle_list('video_bitrates', 'video_bitrate')
    end },
    { key = 'B', fn = function()
        pref_menu:cycle_list('audio_bitrates', 'audio_bitrate')
    end },
    { key = 'm', fn = function()
        mp.commandv("cycle", "mute")
        pref_menu:update()
    end },
    { key = 'e', fn = function()
        mp.commandv("cycle", "sub-visibility")
        pref_menu:update()
    end },
    { key = 'u', fn = function()
        pref_menu:cycle_upload_dests()
    end },
    { key = 'z', fn = function()
        pref_menu:cycle_litterbox_expirations()
    end },
    { key = 's', fn = function()
        pref_menu:save()
    end },
    { key = 'q', fn = function()
        pref_menu:close()
    end },
    { key = 'ESC', fn = function()
        pref_menu:close()
    end },
}

-- Select the entry that matches the current config value, so the card always
-- opens showing the value that is actually in effect.
local function sync_selected(list, list_name, current)
    for i, value in ipairs(list) do
        if value == current then
            list.selected = i
            return
        end
    end
    list.selected = 1
end

function pref_menu:sync_from_config()
    local res = pref_menu.resolutions
    for i, r in ipairs(res) do
        if r.w == config.video_width and r.h == config.video_height then
            res.selected = i
            break
        end
    end
    sync_selected(pref_menu.vid_formats, 'vid_formats', config.video_format)
    sync_selected(pref_menu.aud_formats, 'aud_formats', config.audio_format)
    sync_selected(pref_menu.video_bitrates, 'video_bitrates', config.video_bitrate)
    sync_selected(pref_menu.audio_bitrates, 'audio_bitrates', config.audio_bitrate)
    sync_selected(pref_menu.upload_dests, 'upload_dests', config.upload_dest)
    sync_selected(pref_menu.litterbox_expirations, 'litterbox_expirations', config.litterbox_expire)
end

function pref_menu:get_selected_resolution()
    local res = self.resolutions[self.resolutions.selected]
    return string.format(
        '%s x %s',
        res.w == -2 and 'auto' or tostring(res.w),
        res.h == -2 and 'auto' or tostring(res.h)
    )
end

function pref_menu:cycle_resolutions()
    local res = self.resolutions
    res.selected = res.selected + 1 > #res and 1 or res.selected + 1
    config.video_width = res[res.selected].w
    config.video_height = res[res.selected].h
    self:update()
end

-- Advance a list-based setting, writing the new value into config_key.
function pref_menu:cycle_list(list_name, config_key)
    local list = self[list_name]
    list.selected = list.selected + 1 > #list and 1 or list.selected + 1
    config[config_key] = list[list.selected]
    if config_key == 'video_format' or config_key == 'audio_format' then
        set_encoding_settings()
    end
    self:update()
end

function pref_menu:cycle_formats(config_key)
    self:cycle_list(config_key == 'video_format' and 'vid_formats' or 'aud_formats', config_key)
end

function pref_menu:cycle_upload_dests()
    local dests = self.upload_dests
    dests.selected = dests.selected + 1 > #dests and 1 or dests.selected + 1
    config.upload_dest = dests[dests.selected]
    self:update()
end

function pref_menu:cycle_litterbox_expirations()
    local expirations = self.litterbox_expirations
    expirations.selected = expirations.selected + 1 > #expirations and 1 or expirations.selected + 1
    config.litterbox_expire = expirations[expirations.selected]
    self:update()
end

function pref_menu:save()
    local function lua_to_mpv(config_value)
        if type(config_value) == 'boolean' then
            return config_value and 'yes' or 'no'
        else
            return tostring(config_value)
        end
    end

    local ignore_list = {
        video_extension = true,
        audio_extension = true,
        video_codec = true,
        audio_codec = true,
        anytype_version = true,
    }

    local mpv_dirpath = string.gsub(mp.get_script_directory(), "scripts[\\/][^\\/]+", "")
    local config_filepath = utils.join_path(utils.join_path(mpv_dirpath, "script-opts"), string.format('%s.conf', NAME))

    local handle = io.open(config_filepath, 'w')
    if handle ~= nil then
        handle:write(string.format("# Written by %s on %s.\n", NAME, os.date()))
        for key, value in pairs(config) do
            if ignore_list[key] == nil then
                handle:write(string.format('%s=%s\n', key, lua_to_mpv(value)))
            end
        end
        handle:close()
        h.notify("Settings saved.", "info", 2)
    else
        h.notify_error(string.format("Couldn't open %s.", config_filepath), "error", 4)
    end
    self:update()
end

function pref_menu:update()
    self:sync_from_config()

    local osd = OSD:new():config(config)
    osd:submenu('Preferences'):newline()
    osd:tab():item('r: Video resolution: '):append(self:get_selected_resolution()):newline()
    osd:tab():item('f: Video format: '):append(config.video_format):newline()
    osd:tab():item('a: Audio format: '):append(config.audio_format):newline()
    osd:tab():item('b: Video bitrate: '):append(config.video_bitrate):newline()
    osd:tab():item('B: Audio bitrate: '):append(config.audio_bitrate):newline()
    osd:tab():item('m: Mute audio: '):append(mp.get_property("mute")):newline()
    osd:tab():item('e: Embed subtitles: '):append(mp.get_property("sub-visibility")):newline()
    osd:submenu('Upload'):newline()
    osd:tab():item('u: Destination: '):append(fmt_upload_dest()):newline()
    if config.upload_dest == 'litterbox' then
        osd:tab():item('z: Litterbox expires after: '):append(config.litterbox_expire):newline()
    else
        osd:tab():color("b0b0b0"):text('z: Litterbox expires after: '):append('N/A'):newline()
    end
    osd:submenu('Save'):newline()
    osd:tab():item('s: Save preferences'):newline()
    osd:tab():item('ESC: Back to main menu'):newline()
    self:overlay_draw(osd:get_text())
end

------------------------------------------------------------
-- Entry point

validate_config()
encoder.init(config, main_menu.timings)
mp.add_key_binding('c', 'videoclip-menu-open', main_menu.open)
mp.msg.warn("Press 'c' to open the videoclip menu.")

