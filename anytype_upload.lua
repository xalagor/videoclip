-- anytype_upload.lua: Upload the currently playing video/image to Anytype
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local function upload_current_file()
    local filepath = mp.get_property("path")
    if not filepath or filepath == "" then
        mp.osd_message("No open file to upload", 3)
        return
    end

    -- Skip network streams
    if filepath:find("://") and not filepath:find("file://") then
        mp.osd_message("Cannot upload network streams to Anytype", 3)
        return
    end

    mp.osd_message("Uploading to Anytype...", 10)

    local cmd = {
        "C:\\Projects\\Thaumcraft\\apps\\service\\bin\\thaumctl.exe",
        "kb",
        "upload",
        filepath,
        "--link",
        "--add-to-captures"
    }

    local r = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = cmd
    })

    if r.status ~= 0 then
        msg.error("Upload failed: status=" .. tostring(r.status) .. ", stderr=" .. (r.stderr or ""))
        mp.osd_message("Upload failed! Check console logs.", 4)
        return
    end

    local link = r.stdout
    if link then
        link = link:gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace
    end

    if not link or link == "" or not link:find("anytype://") then
        msg.error("Invalid response: " .. (r.stdout or ""))
        mp.osd_message("Upload failed: no link returned", 4)
        return
    end

    -- Copy to clipboard using PowerShell (with single quotes around the URL to handle special characters)
    local clip_cmd = {
        "powershell",
        "-NoProfile",
        "-Command",
        "Set-Clipboard -Value '" .. link .. "'"
    }
    local clip_r = mp.command_native({
        name = "subprocess",
        playback_only = false,
        args = clip_cmd
    })

    if clip_r.status == 0 then
        mp.osd_message("Uploaded to Anytype!\nLink copied to clipboard.", 4)
    else
        mp.osd_message("Uploaded, but failed to copy link to clipboard.", 4)
    end
end

mp.add_key_binding("u", "anytype_upload", upload_current_file)
