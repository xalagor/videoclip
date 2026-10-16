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
local anytype_upload = require('anytype_upload')

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
    -- Corner of the video the menu card is anchored to: ASS \an tag.
    -- 7 = top left, 9 = top right (the default), 1 = bottom left.
    -- The card sizes, colours and font follow uosc's own configuration, so
    -- restyling uosc restyles the card. https://aegisub.org/docs/3.2/ASS_Tags/#\an
    osd_align = 9,
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

local function upload_video(outfile)
    if config.upload_dest == 'anytype' then
        anytype_upload.upload_to_anytype(outfile, nil, nil)
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
    if config.upload_dest == 'custom' then
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
-- Card styling, matched to uosc
--
-- uosc 5.x exposes no API for a caller-supplied corner text layer: its menu is
-- always a window and this version has no flash-overlay element. What it does
-- offer is a look, so the card is our own ASS overlay drawn with uosc's own
-- values -- its font, its menu font-size formula, its palette, its text border.
-- With `top_bar=no-border` uosc draws its title straight onto the video that
-- way, and the card sits in the corner next to it.

-- uosc's own defaults for the keys the card cares about. Options overridden on
-- the command line (`script-opts-uosc=`) are not visible here, but they are rare
-- and these match uosc's built-in values.
local uosc_config = {
    scale = 1,
    scale_fullscreen = 1.3,
    font_scale = 1,
    font_bold = false,
    text_border = 1.2,
    menu_item_height = 36,
    top_bar_size = 40,
    color = '',
}

-- uosc.conf is parsed by hand rather than through mp.options: mp.options treats
-- every key absent from our table as unknown and warns about it, which floods
-- the log with warnings for all of uosc's other options.
do
    local path = mp.command_native({ 'expand-path', '~~/script-opts/uosc.conf' })
    local handle = path and io.open(path, 'r')
    if handle then
        for line in handle:lines() do
            local key, value = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
            local default = key and uosc_config[key]
            if default ~= nil then
                if type(default) == 'number' then
                    uosc_config[key] = tonumber(value) or default
                elseif type(default) == 'boolean' then
                    uosc_config[key] = value == 'yes'
                else
                    uosc_config[key] = value
                end
            end
        end
        handle:close()
    end
end

-- uosc's `color` override is a positional list; these are its documented slots.
local COLOR_SLOTS = {
    foreground = 1,
    background = 3,
    success = 6,
    error = 7,
    accent = 9,
}

local palette = {
    foreground = 'ffffff',
    background = '000000',
    success = 'a5e075',
    error = 'ff616e',
    accent = '00adee',
    dim = '9a9a9a',
}

do
    local overrides = {}
    for value in tostring(uosc_config.color or ''):gmatch('[^,]+') do
        overrides[#overrides + 1] = value:gsub('^#', '')
    end
    for key, slot in pairs(COLOR_SLOTS) do
        local hex = overrides[slot]
        if hex and #hex == 6 then
            palette[key] = hex
        end
    end
end

local function ui_scale()
    if mp.get_property_native('fullscreen') or mp.get_property_native('maximized') then
        return uosc_config.scale_fullscreen
    end
    return uosc_config.scale
end

-- The same formula uosc uses for its own menu items, so the card's type matches
-- the menus and the top bar around it.
local function card_font_size()
    return math.floor(uosc_config.menu_item_height * ui_scale() * 0.48 * uosc_config.font_scale + 0.5)
end

-- ASS colours are &Hbbggrr&.
local function bgr(hex)
    hex = tostring(hex):gsub('#', '')
    return hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2)
end

-- Anchor to the configured corner, keeping clear of uosc's top bar when the card
-- sits at the top.
local function card_anchor(align)
    local width, height = mp.get_osd_size()
    if not width or not height or width <= 0 or height <= 0 then
        return nil
    end
    local margin_x = mp.get_property_number('osd-margin-x') or 22
    local margin_y = mp.get_property_number('osd-margin-y') or 22
    if align == 1 then
        return string.format('{\\pos(%.0f,%.0f)', margin_x, height - margin_y)
    end
    local y = margin_y + uosc_config.top_bar_size * ui_scale()
    if align == 7 then
        return string.format('{\\pos(%.0f,%.0f)', margin_x, y)
    end
    return string.format('{\\pos(%.0f,%.0f)', width - margin_x, y)
end

-- `lines` is a list of rows, each a list of { text, color, bold, size } spans.
local function render_card(lines, align)
    local scale = ui_scale()
    local fs = card_font_size()

    local tags = {}
    local anchor = card_anchor(align)
    if anchor then
        table.insert(tags, anchor)
    end

    table.insert(tags, string.format('{\\an%d\\fs%d', align, fs))
    local font = mp.get_property('options/osd-font')
    if font and font ~= '' then
        table.insert(tags, string.format('\\fn%s', font))
    end
    if uosc_config.font_bold then
        table.insert(tags, '\\b1')
    end
    table.insert(tags, string.format('\\bord%.1f', uosc_config.text_border * scale))
    table.insert(tags, '\\shad0')
    -- uosc outlines text drawn on the video with its background colour.
    table.insert(tags, string.format('\\3c&H%s&\\1c&H%s&}', bgr(palette.background), bgr(palette.foreground)))

    for i, row in ipairs(lines) do
        if i > 1 then
            table.insert(tags, '\\N')
        end
        for _, span in ipairs(row) do
            table.insert(tags, string.format('{\\1c&H%s&\\b%d\\fs%d}',
                bgr(span.color or palette.foreground), span.bold and 1 or 0, span.size or fs))
            table.insert(tags, span.text)
        end
    end

    return table.concat(tags)
end

local function card_section(lines, title)
    table.insert(lines, { { text = title, color = palette.dim, bold = true } })
end

-- `value` is rendered as a hint, the way uosc renders a menu item's hint.
local function card_item(lines, key, text, value, value_color)
    local row = {
        { text = key, color = palette.accent, bold = true },
        { text = '\\h ' .. text, color = palette.foreground },
    }
    if value then
        row[3] = { text = '\\h ' .. value, color = value_color or palette.dim, size = card_font_size() - 1 }
    end
    table.insert(lines, row)
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
    self:overlay_draw(render_card({}, config.osd_align))
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
        anytype_upload.upload_to_anytype(file_path, encoder.get_youtube_url(), nil)
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
    encoder.extract_screenshot("video", function(file_path)
        if config.upload_dest == 'anytype' then
            anytype_upload.upload_to_anytype(file_path, encoder.get_youtube_url(), nil)
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
    local lines = {}

    if encoder.alive == false then
        table.insert(lines, { { text = 'mpv is not found in the PATH.', color = palette.error, bold = true } })
        card_section(lines, '')
    end

    card_section(lines, 'Timings')
    card_item(lines, 's', 'start time', h.human_readable_time(self.timings['start']))
    card_item(lines, 'e', 'end time', h.human_readable_time(self.timings['end']))
    card_item(lines, 'r', 'reset')

    card_section(lines, 'Create clip')
    card_item(lines, 'c', 'video clip')
    card_item(lines, 'C', 'video clip 1080p')
    card_item(lines, 'a', 'audio clip')
    card_item(lines, 'f', 'screenshot')
    card_item(lines, 'x', 'video clip to', fmt_upload_dest())

    card_section(lines, 'Crop')
    card_item(lines, 'k', 'select crop zone', current_crop_text())
    card_item(lines, 'd', 'clear crop')

    card_section(lines, 'Options')
    card_item(lines, 'p', 'preferences')
    card_item(lines, 'o', 'open streamable.com')
    card_item(lines, 'ESC', 'close')

    self:overlay_draw(render_card(lines, config.osd_align))
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

    local lines = {}
    card_section(lines, 'Preferences')
    card_item(lines, 'r', 'video resolution', self:get_selected_resolution())
    card_item(lines, 'f', 'video format', config.video_format)
    card_item(lines, 'a', 'audio format', config.audio_format)
    card_item(lines, 'b', 'video bitrate', config.video_bitrate)
    card_item(lines, 'B', 'audio bitrate', config.audio_bitrate)
    card_item(lines, 'm', 'mute audio', mp.get_property("mute"))
    card_item(lines, 'e', 'embed subtitles', mp.get_property("sub-visibility"))

    card_section(lines, 'Upload')
    card_item(lines, 'u', 'destination', fmt_upload_dest())
    if config.upload_dest == 'litterbox' then
        card_item(lines, 'z', 'litterbox expires after', config.litterbox_expire)
    else
        card_item(lines, 'z', 'litterbox expires after', 'N/A')
    end

    card_section(lines, 'Save')
    card_item(lines, 's', 'save preferences')
    card_item(lines, 'ESC', 'back')

    self:overlay_draw(render_card(lines, config.osd_align))
end

------------------------------------------------------------
-- Entry point

validate_config()
encoder.init(config, main_menu.timings)
mp.add_key_binding('c', 'videoclip-menu-open', main_menu.open)
mp.msg.warn("Press 'c' to open the videoclip menu.")

mp.register_script_message("videoclip-screenshot", function(mode)
    mode = (mode and mode ~= "") and mode or "video"
    encoder.extract_screenshot(mode, function(file_path)
        anytype_upload.upload_to_anytype(file_path, encoder.get_youtube_url(), nil)
    end)
end)


