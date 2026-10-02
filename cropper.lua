local mp = require('mp')
local assdraw = require('mp.assdraw')

local M = {}

local active = false
local crop_first_corner = nil
local needs_drawing = false
local cursor = {x = 0, y = 0}

local function redraw()
    needs_drawing = true
end

local function clamp(low, value, high)
    if value <= low then return low end
    if value >= high then return high end
    return value
end

local function screen_to_video_norm(x, y, dim)
    return {
        x = (x - dim.ml) / (dim.w - dim.ml - dim.mr),
        y = (y - dim.mt) / (dim.h - dim.mt - dim.mb)
    }
end

local function video_norm_to_screen(x, y, dim)
    return {
        x = math.floor(x * (dim.w - dim.ml - dim.mr) + dim.ml + 0.5),
        y = math.floor(y * (dim.h - dim.mt - dim.mb) + dim.mt + 0.5)
    }
end

local function draw_crop_zone()
    if not needs_drawing then return end
    needs_drawing = false

    local dim = mp.get_property_native("osd-dimensions")
    if not dim then return end

    local mx = clamp(dim.ml, cursor.x, dim.w - dim.mr)
    local my = clamp(dim.mt, cursor.y, dim.h - dim.mb)

    local ass = assdraw.ass_new()
    if crop_first_corner then
        local c1 = video_norm_to_screen(crop_first_corner.x, crop_first_corner.y, dim)
        local c2 = {x = mx, y = my}
        
        local left = math.min(c1.x, c2.x)
        local right = math.max(c1.x, c2.x)
        local top = math.min(c1.y, c2.y)
        local bottom = math.max(c1.y, c2.y)

        ass:new_event()
        ass:pos(0, 0)
        ass:append("{\\an7\\bord0\\shad0\\c&H00A0FF&\\1a&H00&\\2a&HFF&\\3a&HFF&\\4a&HFF&}")
        local b = 2
        ass:draw_start()
        ass:rect_cw(left, top - b, right + b, top)
        ass:rect_cw(right, top, right + b, bottom + b)
        ass:rect_cw(left - b, bottom, right, bottom + b)
        ass:rect_cw(left - b, top - b, left, bottom)
        ass:draw_stop()
    end
    
    mp.set_osd_ass(dim.w, dim.h, ass.text)
end

local function apply_crop()
    local dim = mp.get_property_native("osd-dimensions")
    if not dim then return end

    local mx = clamp(dim.ml, cursor.x, dim.w - dim.mr)
    local my = clamp(dim.mt, cursor.y, dim.h - dim.mb)
    
    local c2 = screen_to_video_norm(mx, my, dim)
    local c1 = crop_first_corner
    
    local x1 = math.min(c1.x, c2.x)
    local y1 = math.min(c1.y, c2.y)
    local x2 = math.max(c1.x, c2.x)
    local y2 = math.max(c1.y, c2.y)
    
    local vop = mp.get_property_native("video-out-params")
    if not vop then return end
    
    local x = math.floor(x1 * vop.w + 0.5)
    local y = math.floor(y1 * vop.h + 0.5)
    local w = math.floor((x2 - x1) * vop.w + 0.5)
    local h = math.floor((y2 - y1) * vop.h + 0.5)
    
    local vf_table = mp.get_property_native("vf") or {}
    -- Remove old crop if exists
    local new_vf = {}
    for _, filter in ipairs(vf_table) do
        if filter.name ~= "crop" then
            table.insert(new_vf, filter)
        end
    end
    table.insert(new_vf, {
        name="crop",
        params= { x = tostring(x), y = tostring(y), w = tostring(w), h = tostring(h) }
    })
    mp.set_property_native("vf", new_vf)
    mp.osd_message(string.format("Cropped: %dx%d at %d,%d", w, h, x, y), 3)
end

local function on_mouse_move()
    cursor.x, cursor.y = mp.get_mouse_pos()
    redraw()
end

local function on_mouse_click()
    if not crop_first_corner then
        local dim = mp.get_property_native("osd-dimensions")
        if not dim then return end
        local mx = clamp(dim.ml, cursor.x, dim.w - dim.mr)
        local my = clamp(dim.mt, cursor.y, dim.h - dim.mb)
        crop_first_corner = screen_to_video_norm(mx, my, dim)
        redraw()
    else
        apply_crop()
        M.stop()
    end
end

function M.start()
    if active then return end
    active = true
    crop_first_corner = nil
    cursor.x, cursor.y = mp.get_mouse_pos()
    redraw()
    
    mp.add_forced_key_binding("MOUSE_BTN0", "cropper-click", on_mouse_click)
    mp.add_forced_key_binding("MOUSE_MOVE", "cropper-move", on_mouse_move)
    mp.add_forced_key_binding("ESC", "cropper-cancel", M.stop)
    
    mp.register_idle(draw_crop_zone)
    mp.observe_property("osd-dimensions", nil, redraw)
    
    mp.commandv("script-message-to", "uosc", "disable-elements", "videoclip_crop", "window_border,top_bar,timeline,controls,volume,idle_indicator,audio_indicator,buffering_indicator,pause_indicator")
    
    mp.osd_message("Crop Mode: Click to set first corner, click again to finish. ESC to cancel.", 5)
    mp.set_property_native("pause", true)
end

function M.stop()
    if not active then return end
    active = false
    mp.remove_key_binding("cropper-click")
    mp.remove_key_binding("cropper-move")
    mp.remove_key_binding("cropper-cancel")
    mp.unregister_idle(draw_crop_zone)
    mp.unobserve_property(redraw)
    mp.set_osd_ass(1280, 720, '')
    
    mp.commandv("script-message-to", "uosc", "disable-elements", "videoclip_crop", "")
end

function M.clear_crop()
    local vf_table = mp.get_property_native("vf")
    if not vf_table then return end
    local new_vf = {}
    local cleared = false
    for _, filter in ipairs(vf_table) do
        if filter.name ~= "crop" then
            table.insert(new_vf, filter)
        else
            cleared = true
        end
    end
    if cleared then
        mp.set_property_native("vf", new_vf)
        mp.osd_message("Crop cleared", 2)
    end
end

return M
