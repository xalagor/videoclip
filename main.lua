local dir = mp.get_script_directory()
if dir then
    local sep = (dir:sub(-1) == '/' or dir:sub(-1) == '\\') and '' or '/'
    package.path = package.path .. ';' .. dir .. sep .. '?.lua'
end
require('videoclip')
require('anytype_upload')
