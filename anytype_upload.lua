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

    -- Load config from videoclip.conf to share api details
    local config = {
        anytype_api_url = 'http://127.0.0.1:31009',
        anytype_api_key = '',
        anytype_space_id = '',
        anytype_version = '2025-11-08',
    }
    require('mp.options').read_options(config, "videoclip")

    if not config.anytype_api_key or config.anytype_api_key == '' then
        config.anytype_api_key = os.getenv("ANYTYPE_APP_KEY") or os.getenv("ANYTYPE_API_KEY") or ''
    end
    if not config.anytype_space_id or config.anytype_space_id == '' then
        config.anytype_space_id = os.getenv("ANYTYPE_SPACE_ID") or ''
    end

    if config.anytype_api_key == '' or config.anytype_space_id == '' then
        msg.error("Anytype config missing: set anytype_api_key and anytype_space_id in videoclip.conf or via environment variables")
        mp.osd_message("Anytype upload failed: Config missing.", 4)
        return
    end

    mp.osd_message("Uploading to Anytype...", 10)

    local base_url = config.anytype_api_url:gsub("/+$", "")
    local headers = {
        "-H", "Authorization: Bearer " .. config.anytype_api_key,
        "-H", "Anytype-Version: " .. config.anytype_version,
    }

    -- Step 1: Upload file to v2 API
    local upload_url = string.format("%s/v2/spaces/%s/files", base_url, config.anytype_space_id)
    local upload_cmd = {
        "curl", "-s",
        "-X", "POST",
        upload_url,
    }
    for _, header in ipairs(headers) do
        table.insert(upload_cmd, header)
    end
    table.insert(upload_cmd, "-F")
    table.insert(upload_cmd, "file=@" .. filepath)

    local upload_r = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = upload_cmd
    })

    if upload_r.status ~= 0 then
        msg.error("Anytype upload stderr: " .. (upload_r.stderr or ""))
        msg.error("Upload failed: status=" .. tostring(upload_r.status))
        mp.osd_message("Upload failed! Check console logs.", 4)
        return
    end

    local upload_out = upload_r.stdout
    if not upload_out or upload_out == "" then
        msg.error("Upload failed: empty response")
        mp.osd_message("Upload failed: empty response", 4)
        return
    end

    local file_id = upload_out:match('"file_id"%s*:%s*"([^"]+)"')
        or upload_out:match('"id"%s*:%s*"([^"]+)"')
    if not file_id then
        msg.error("Anytype upload stdout: " .. upload_out)
        msg.error("Invalid response: " .. upload_out)
        mp.osd_message("Upload failed: invalid response", 4)
        return
    end

    msg.info("Anytype file uploaded, file_id: " .. file_id)

    -- Step 2: Create Bookmark object with v2 API
    local objects_url = string.format("%s/v2/spaces/%s/objects", base_url, config.anytype_space_id)
    local clip_name = mp.get_property("media-title", "clip")

    local properties = {}
    if file_id then
        properties.files = { file_id }
    end

    local obj_body = utils.format_json({
        type = "Bookmark",
        name = clip_name,
        properties = properties,
    })

    local create_cmd = {
        "curl", "-s",
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

    local create_r = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = create_cmd
    })

    if create_r.status ~= 0 then
        msg.error("Anytype object creation stderr: " .. (create_r.stderr or ""))
        msg.error("Object creation failed: status=" .. tostring(create_r.status))
        mp.osd_message("Upload failed! Check console logs.", 4)
        return
    end

    local create_out = create_r.stdout
    if not create_out or create_out == "" then
        msg.error("Object creation failed: empty response")
        mp.osd_message("Upload failed: empty response", 4)
        return
    end

    local object_id = create_out:match('"id"%s*:%s*"([^"]+)"')
        or create_out:match('"object_id"%s*:%s*"([^"]+)"')
    if not object_id then
        msg.error("Anytype object creation stdout: " .. create_out)
        msg.error("Invalid response: " .. create_out)
        mp.osd_message("Upload failed: invalid response", 4)
        return
    end

    msg.info("Anytype Bookmark object created, object_id: " .. object_id)

    local link = string.format("anytype://object?objectId=%s&spaceId=%s", object_id, config.anytype_space_id)

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
