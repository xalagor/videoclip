-- For compatibility, allow running videoclip
-- by placing the project folder in mpv's scripts directory (e.g. ~/.config/mpv/scripts).

local mp = require('mp')
local utils = require('mp.utils')
local dir = mp.get_script_directory() or "."
local src_root = utils.join_path(dir, "videoclip")

-- Add src subfolder and root folder to Lua search path
package.path = string.format("%s/?.lua;%s/?.lua;%s", src_root, dir, package.path)
mp.msg.debug("package.path = %s", package.path)

-- Run the main script
dofile(utils.join_path(src_root, "main.lua"))
