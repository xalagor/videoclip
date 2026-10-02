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
    osd_align = 7, -- https://aegisub.org/docs/3.2/ASS_Tags/#\an
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

-- anytype_search: query the Anytype v2 search endpoint for Movie, Series, Game types
-- Returns parsed results as a list of {id, name, type_key} tables via callback
local function anytype_search(query, callback)
    local api_key, space_id = resolve_anytype_config()
    if api_key == '' or space_id == '' then
        mp.msg.error("Anytype config missing: cannot search")
        if callback then callback({}) end
        return
    end

    if not query or query == "" then
        mp.msg.info("Anytype search: empty query, returning all Movie/Series/Game")
    else
        mp.msg.info("Anytype search: " .. query)
    end

    local base_url = config.anytype_api_url:gsub("/+$", "")
    local search_url = string.format("%s/v2/spaces/%s/search", base_url, space_id)

    local search_body = {
        fields = { "name", "type" },
    }
    if query and query ~= "" then
        search_body.query = query
    end
    -- Type filter: Movie, Series, Game — use compact filter string
    search_body.filter = 'type IN ("movie", "series", "game")'

    local cmd = {
        p.curl_exe, "-s",
        "-X", "POST",
        search_url,
        "-H", "Authorization: Bearer " .. api_key,
        "-H", "Anytype-Version: " .. config.anytype_version,
        "-H", "Content-Type: application/json",
        "-d", utils.format_json(search_body),
    }

    local r = h.subprocess(cmd)
    if r.status ~= 0 then
        mp.msg.error("Anytype search failed. Status: " .. tostring(r.status))
        mp.msg.error("Anytype search stderr: " .. (r.stderr or ""))
        if callback then callback({}) end
        return
    end

    local out = r.stdout
    if not out or out == "" then
        mp.msg.error("Anytype search returned empty response.")
        if callback then callback({}) end
        return
    end

    local parsed = utils.parse_json(out)
    if not parsed or not parsed.data then
        mp.msg.error("Anytype search: could not parse response. stdout: " .. out)
        if callback then callback({}) end
        return
    end

    local results = {}
    for _, item in ipairs(parsed.data) do
        table.insert(results, {
            id = item.id,
            name = item.name,
            type_key = item.type,
        })
    end

    mp.msg.info(string.format("Anytype search returned %d results.", #results))
    if callback then callback(results) end
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
-- State for async upload flow and uosc menus

local timings = Timings:new()
local search_menu_active = false
local pending_upload = {
    file_path = nil,
    source_url = nil,
    content_from_id = nil,
    encoding_done = false,
    search_done = false,
    cancelled = false,
}

------------------------------------------------------------
-- uosc Menu helpers

local function open_uosc_menu(menu_data_json)
    mp.commandv('script-message-to', 'uosc', 'open-menu', menu_data_json)
end

local function update_uosc_menu(type, items)
    local json = utils.format_json({ type = type, items = items })
    mp.commandv('script-message-to', 'uosc', 'update-menu', json)
end

local function close_uosc_menu()
    mp.commandv('script-message-to', 'uosc', 'close-menu')
end

------------------------------------------------------------
-- uosc Main Menu

function show_main_menu()
    local start_str = h.human_readable_time(timings['start'])
    local end_str = h.human_readable_time(timings['end'])

    local items = {
        { title = "Start: " .. start_str, icon = "play_arrow", value = "script-message vc-set-start" },
        { title = "End: " .. end_str, icon = "stop", value = "script-message vc-set-end" },
        { title = "Start (subs)", icon = "play_circle", value = "script-message vc-set-start-sub" },
        { title = "End (subs)", icon = "stop_circle", value = "script-message vc-set-end-sub" },
        { title = "Reset Timings", icon = "refresh", value = "script-message vc-reset-timings" },
        { separator = true },
    }

    if encoder.alive == false then
        table.insert(items, { title = "Warning: mpv encoder not found in PATH", icon = "warning", selectable = false })
        table.insert(items, { separator = true })
    end

    table.insert(items, { title = "Video Clip", icon = "movie", value = "script-message vc-create-clp video" })
    table.insert(items, { title = "Video Clip (Full HD)", icon = "fullscreen", value = "script-message vc-create-clp video-fullhd" })
    table.insert(items, { title = "Audio Clip", icon = "music_note", value = "script-message vc-create-clp audio" })
    table.insert(items, { title = "Screenshot", icon = "camera_alt", value = "script-message vc-screenshot" })
    table.insert(items, { separator = true })

    table.insert(items, { title = "Select Crop Zone", icon = "crop", value = "script-message vc-start-crop" })
    table.insert(items, { title = "Clear Crop", icon = "crop_free", value = "script-message vc-clear-crop" })
    table.insert(items, { separator = true })

    table.insert(items, { title = "Preferences", icon = "tune", value = "script-message vc-show-prefs" })
    table.insert(items, { title = "Open Streamable.com", icon = "public", value = "script-message vc-open-streamable" })
    table.insert(items, { title = "Close", icon = "close", value = "script-message vc-close-menu" })

    local menu_data = utils.format_json({
        type = "vc-main",
        title = "Videoclip",
        search_style = "disabled",
        items = items,
    })

    open_uosc_menu(menu_data)
end

------------------------------------------------------------
-- uosc Search Menu

function show_search_menu()
    search_menu_active = true
    pending_upload = {
        file_path = nil,
        source_url = nil,
        content_from_id = nil,
        encoding_done = false,
        search_done = false,
        cancelled = false,
    }

    local menu_data = utils.format_json({
        type = "vc-search",
        title = "Search Media (Movie/Series/Game)",
        search_style = "palette",
        on_search = "script-message vc-anytype-search",
        on_close = "script-message vc-search-cancelled",
        items = {},
    })

    open_uosc_menu(menu_data)
end

------------------------------------------------------------
-- Script message handlers

mp.register_script_message('vc-set-start', function()
    timings['start'] = math.max(0, mp.get_property_number('time-pos'))
    show_main_menu()
end)

mp.register_script_message('vc-set-end', function()
    timings['end'] = math.max(0, mp.get_property_number('time-pos'))
    show_main_menu()
end)

mp.register_script_message('vc-set-start-sub', function()
    local sub_delay = mp.get_property_native("sub-delay")
    local time_pos = mp.get_property_number("sub-start")
    if time_pos == nil then
        h.notify_error("Warning: No subtitles visible.", "warn", 2)
        return
    end
    timings['start'] = math.max(0, time_pos + sub_delay)
    show_main_menu()
end)

mp.register_script_message('vc-set-end-sub', function()
    local sub_delay = mp.get_property_native("sub-delay")
    local time_pos = mp.get_property_number("sub-end")
    if time_pos == nil then
        h.notify_error("Warning: No subtitles visible.", "warn", 2)
        return
    end
    timings['end'] = math.max(0, time_pos + sub_delay)
    show_main_menu()
end)

mp.register_script_message('vc-reset-timings', function()
    timings:reset()
    show_main_menu()
end)

mp.register_script_message('vc-create-clp', function(clip_type)
    if not timings:validate() then
        h.notify_error("Wrong timings. Aborting.", "warn", 2)
        return
    end

    if clip_type == "video-fullhd" then
        force_resolution(1920, -2, do_create_clip, "video")
    else
        do_create_clip(clip_type)
    end
end)

mp.register_script_message('vc-screenshot', function()
    if config.upload_dest == 'anytype' then
        encoder.extract_screenshot(on_media_generated)
        show_search_menu()
    else
        encoder.extract_screenshot(function(filepath)
            h.notify(string.format("Screenshot saved to %s.", filepath), "info", 2)
        end)
    end
end)

mp.register_script_message('vc-start-crop', function()
    close_uosc_menu()
    cropper.start()
end)

mp.register_script_message('vc-clear-crop', function()
    cropper.clear_crop()
    show_main_menu()
end)

mp.register_script_message('vc-show-prefs', function()
    show_preferences_menu()
end)

mp.register_script_message('vc-open-streamable', function()
    p.open('https://streamable.com/')
end)

mp.register_script_message('vc-close-menu', function()
    close_uosc_menu()
end)

mp.register_script_message('vc-main-menu', function()
    show_main_menu()
end)

-- Create clip handler: starts encoding and, if destination is Anytype,
-- opens the search menu for media association
function do_create_clip(clip_type)
    if config.upload_dest == 'anytype' then
        encoder.create_clip(clip_type, on_media_generated)
        show_search_menu()
    else
        encoder.create_clip(clip_type, function(filepath)
            h.notify(string.format("Clip saved to %s.", filepath), "info", 2)
        end)
    end
end

-- Called when a clip or screenshot finishes generating
function on_media_generated(file_path)
    mp.msg.info("Media generated: " .. file_path)
    pending_upload.file_path = file_path
    pending_upload.source_url = encoder.get_youtube_url()
    pending_upload.encoding_done = true
    try_complete_upload()
end

-- Called when a user selects a media object from the search menu
mp.register_script_message('vc-select-media', function(content_from_id)
    search_menu_active = false
    close_uosc_menu()

    pending_upload.search_done = true
    pending_upload.cancelled = false
    if content_from_id and content_from_id ~= "" then
        pending_upload.content_from_id = content_from_id
        mp.msg.info("Selected content_from_id: " .. content_from_id)
    end
    try_complete_upload()
end)

-- Called when the search menu is closed without an explicit selection (Esc, click outside)
mp.register_script_message('vc-search-cancelled', function()
    if not search_menu_active then return end
    search_menu_active = false
    pending_upload.search_done = true
    pending_upload.cancelled = true
    try_complete_upload()
end)

-- Search handler: queries Anytype as the user types in the search menu
mp.register_script_message('vc-anytype-search', function(...)
    if not search_menu_active then return end

    local args = { ... }
    -- uosc concatenates params with spaces: "script-message vc-anytype-search <query words...> <menu_id>"
    -- The last arg is always the menu_id; everything before it is the search query.
    local query = ""
    if #args >= 2 then
        local query_parts = {}
        for i = 1, #args - 1 do
            query_parts[i] = args[i]
        end
        query = table.concat(query_parts, " ")
    end

    anytype_search(query, function(results)
        if not search_menu_active then return end

        local items = {}
        for _, r in ipairs(results) do
            table.insert(items, {
                title = r.name,
                hint = r.type_key,
                icon = "movie",
                value = "script-message vc-select-media " .. r.id,
            })
        end
        if #items == 0 then
            table.insert(items, {
                title = "No results found",
                icon = "search_off",
                selectable = false,
            })
        else
            table.insert(items, 1, {
                title = "Cancel (no media)",
                icon = "close",
                value = "script-message vc-select-media ",
            })
        end

        update_uosc_menu("vc-search", items)
    end)
end)

-- Check if both encoding is done and media selection is finalized,
-- then trigger the Anytype upload (or notify on cancel)
function try_complete_upload()
    if pending_upload.cancelled then
        if pending_upload.encoding_done and pending_upload.file_path then
            h.notify("Upload cancelled. Clip kept locally: " .. pending_upload.file_path, "warn", 3)
        end
        return
    end
    if not pending_upload.encoding_done or not pending_upload.search_done then
        return
    end
    if not pending_upload.file_path then
        return
    end
    finish_upload()
end

function finish_upload()
    local file_path = pending_upload.file_path
    local source_url = pending_upload.source_url
    local content_from_id = pending_upload.content_from_id

    pending_upload = {
        file_path = nil,
        source_url = nil,
        content_from_id = nil,
        encoding_done = false,
        search_done = false,
        cancelled = false,
    }

    if search_menu_active then
        close_uosc_menu()
        search_menu_active = false
    end

    upload_to_anytype(file_path, source_url, content_from_id)
end

------------------------------------------------------------
-- Preferences Menu (uosc)

local pref_resolutions = {
    { w = config.video_width, h = config.video_height },
    { w = -2, h = -2 },
    { w = -2, h = 240 },
    { w = -2, h = 360 },
    { w = -2, h = 480 },
    { w = -2, h = 720 },
    { w = -2, h = 1080 },
    { w = -2, h = 1440 },
    { w = -2, h = 2160 },
}
local pref_resolutions_selected = 1

local pref_audio_bitrates = { config.audio_bitrate, '32k', '64k', '128k', '192k', '256k', '384k' }
local pref_audio_bitrates_selected = 1

local pref_video_bitrates = { config.video_bitrate, '500k', '1M', '2M', '4M', '8M', '16M' }
local pref_video_bitrates_selected = 1

local pref_vid_formats = { 'mp4', 'vp9', 'vp8' }
local pref_vid_formats_selected = 1

local pref_aud_formats = { 'aac', 'opus' }
local pref_aud_formats_selected = 1

local pref_upload_dests = { 'litterbox', 'catbox', 'anytype' }
local pref_upload_dests_selected = 1

local pref_litterbox_expirations = { '1h', '12h', '24h', '72h' }
local pref_litterbox_expirations_selected = 1

local function get_selected_resolution_text()
    local res = pref_resolutions[pref_resolutions_selected]
    return string.format(
        '%s x %s',
        res.w == -2 and 'auto' or tostring(res.w),
        res.h == -2 and 'auto' or tostring(res.h)
    )
end

function show_preferences_menu()
    -- Sync selected indices with current config
    pref_resolutions_selected = 1
    for i, res in ipairs(pref_resolutions) do
        if res.w == config.video_width and res.h == config.video_height then
            pref_resolutions_selected = i
            break
        end
    end

    pref_vid_formats_selected = 1
    for i, fmt in ipairs(pref_vid_formats) do
        if config.video_format == fmt then
            pref_vid_formats_selected = i
            break
        end
    end

    pref_aud_formats_selected = 1
    for i, fmt in ipairs(pref_aud_formats) do
        if config.audio_format == fmt then
            pref_aud_formats_selected = i
            break
        end
    end

    pref_audio_bitrates_selected = 1
    for i, br in ipairs(pref_audio_bitrates) do
        if config.audio_bitrate == br then
            pref_audio_bitrates_selected = i
            break
        end
    end

    pref_video_bitrates_selected = 1
    for i, br in ipairs(pref_video_bitrates) do
        if config.video_bitrate == br then
            pref_video_bitrates_selected = i
            break
        end
    end

    pref_upload_dests_selected = 1
    for i, dest in ipairs(pref_upload_dests) do
        if config.upload_dest == dest then
            pref_upload_dests_selected = i
            break
        end
    end

    pref_litterbox_expirations_selected = 1
    for i, exp in ipairs(pref_litterbox_expirations) do
        if config.litterbox_expire == exp then
            pref_litterbox_expirations_selected = i
            break
        end
    end

    local items = {}

    table.insert(items, { title = "Video Resolution", hint = get_selected_resolution_text(), icon = "desktop", value = "script-message vc-cycle-resolution" })
    table.insert(items, { title = "Video Format", hint = config.video_format, icon = "video_library", value = "script-message vc-cycle-video-format" })
    table.insert(items, { title = "Audio Format", hint = config.audio_format, icon = "audiotrack", value = "script-message vc-cycle-audio-format" })
    table.insert(items, { title = "Video Bitrate", hint = config.video_bitrate, icon = "speed", value = "script-message vc-cycle-video-bitrate" })
    table.insert(items, { title = "Audio Bitrate", hint = config.audio_bitrate, icon = "volume_down", value = "script-message vc-cycle-audio-bitrate" })
    table.insert(items, { title = "Mute Audio", hint = tostring(mp.get_property("mute")), icon = "volume_off", value = "script-message vc-toggle-mute" })
    table.insert(items, { title = "Embed Subtitles", hint = tostring(mp.get_property("sub-visibility")), icon = "subtitles", value = "script-message vc-toggle-subs" })
    table.insert(items, { separator = true })

    table.insert(items, { title = "Upload Destination", hint = config.upload_dest, icon = "cloud_upload", value = "script-message vc-cycle-upload-dest" })

    if config.upload_dest == 'litterbox' then
        table.insert(items, { title = "Litterbox Expiry", hint = config.litterbox_expire, icon = "schedule", value = "script-message vc-cycle-litterbox-expire" })
    end

    table.insert(items, { separator = true })
    table.insert(items, { title = "Save Preferences", icon = "save", value = "script-message vc-save-prefs" })
    table.insert(items, { title = "Back", icon = "arrow_back", value = "script-message vc-main-menu" })

    local menu_data = utils.format_json({
        type = "vc-prefs",
        title = "Preferences",
        search_style = "disabled",
        items = items,
    })

    open_uosc_menu(menu_data)
end

mp.register_script_message('vc-cycle-resolution', function()
    pref_resolutions_selected = pref_resolutions_selected + 1 > #pref_resolutions and 1 or pref_resolutions_selected + 1
    local res = pref_resolutions[pref_resolutions_selected]
    config.video_width = res.w
    config.video_height = res.h
    show_preferences_menu()
end)

mp.register_script_message('vc-cycle-video-format', function()
    pref_vid_formats_selected = pref_vid_formats_selected + 1 > #pref_vid_formats and 1 or pref_vid_formats_selected + 1
    config.video_format = pref_vid_formats[pref_vid_formats_selected]
    set_encoding_settings()
    show_preferences_menu()
end)

mp.register_script_message('vc-cycle-audio-format', function()
    pref_aud_formats_selected = pref_aud_formats_selected + 1 > #pref_aud_formats and 1 or pref_aud_formats_selected + 1
    config.audio_format = pref_aud_formats[pref_aud_formats_selected]
    set_encoding_settings()
    show_preferences_menu()
end)

mp.register_script_message('vc-cycle-video-bitrate', function()
    pref_video_bitrates_selected = pref_video_bitrates_selected + 1 > #pref_video_bitrates and 1 or pref_video_bitrates_selected + 1
    config.video_bitrate = pref_video_bitrates[pref_video_bitrates_selected]
    show_preferences_menu()
end)

mp.register_script_message('vc-cycle-audio-bitrate', function()
    pref_audio_bitrates_selected = pref_audio_bitrates_selected + 1 > #pref_audio_bitrates and 1 or pref_audio_bitrates_selected + 1
    config.audio_bitrate = pref_audio_bitrates[pref_audio_bitrates_selected]
    show_preferences_menu()
end)

mp.register_script_message('vc-toggle-mute', function()
    mp.commandv("cycle", "mute")
    show_preferences_menu()
end)

mp.register_script_message('vc-toggle-subs', function()
    mp.commandv("cycle", "sub-visibility")
    show_preferences_menu()
end)

mp.register_script_message('vc-cycle-upload-dest', function()
    pref_upload_dests_selected = pref_upload_dests_selected + 1 > #pref_upload_dests and 1 or pref_upload_dests_selected + 1
    config.upload_dest = pref_upload_dests[pref_upload_dests_selected]
    show_preferences_menu()
end)

mp.register_script_message('vc-cycle-litterbox-expire', function()
    if config.upload_dest ~= 'litterbox' then return end
    pref_litterbox_expirations_selected = pref_litterbox_expirations_selected + 1 > #pref_litterbox_expirations and 1 or pref_litterbox_expirations_selected + 1
    config.litterbox_expire = pref_litterbox_expirations[pref_litterbox_expirations_selected]
    show_preferences_menu()
end)

mp.register_script_message('vc-save-prefs', function()
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
    show_preferences_menu()
end)

------------------------------------------------------------
-- Entry point

validate_config()
encoder.init(config, timings)
mp.add_key_binding('c', 'videoclip-menu-open', show_main_menu)
mp.msg.warn("Press 'c' to open the videoclip menu.")
