-- anytype_upload.lua: Anytype upload integration for mpv-videoclip
local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local h = require 'helpers'
local p = require 'platform'

local anytype_upload = {}
local logged_endpoint = false

local function get_config()
    local config = {
        anytype_api_url = 'http://127.0.0.1:31009',
        anytype_api_key = '',
        anytype_space_id = '',
        anytype_version = '2025-11-08',
    }
    require('mp.options').read_options(config, "videoclip")
    return config
end

-- Resolve endpoint, key, and space id.
-- Endpoint comes only from anytype_api_url option (default http://127.0.0.1:31009), never from ANYTYPE_API_URL.
-- Key and space id prefer environment variables first, then configuration options.
local function resolve_anytype_config(cfg)
    cfg = cfg or get_config()
    local endpoint = (cfg.anytype_api_url and cfg.anytype_api_url ~= '') and cfg.anytype_api_url or 'http://127.0.0.1:31009'
    endpoint = endpoint:gsub("/+$", "")

    local env_key = os.getenv("ANYTYPE_API_KEY")
    if not env_key or env_key == '' then
        env_key = os.getenv("ANYTYPE_APP_KEY")
    end
    local api_key = (env_key and env_key ~= '') and env_key or (cfg.anytype_api_key or '')

    local env_space_id = os.getenv("ANYTYPE_SPACE_ID")
    local space_id = (env_space_id and env_space_id ~= '') and env_space_id or (cfg.anytype_space_id or '')

    return endpoint, api_key, space_id
end

local function log_endpoint_once(endpoint)
    if not logged_endpoint then
        msg.info(string.format("Resolved Anytype endpoint: %s", endpoint))
        logged_endpoint = true
    end
end

-- Parse curl output formatted with --write-out "\n%{http_code}"
local function parse_curl_output(stdout)
    if not stdout or stdout == "" then
        return "", nil
    end
    local trimmed = stdout:gsub("%s+$", "")
    local body, status_str = trimmed:match("^(.-)\r?\n(%d%d%d)$")
    if body and status_str then
        return body, tonumber(status_str)
    end
    status_str = trimmed:match("^(%d%d%d)$")
    if status_str then
        return "", tonumber(status_str)
    end
    return trimmed, nil
end

local function execute_request(args, endpoint, file_path, action_name)
    local r = h.subprocess(args)
    local body, status_code = parse_curl_output(r.stdout)

    -- Case 1: curl failed to connect (unreachable endpoint / network failure)
    if r.status ~= 0 and (not status_code or status_code == 0) then
        local err_text = string.format("Could not reach Anytype endpoint %s", endpoint)
        if file_path then
            err_text = err_text .. string.format("\nFile kept: %s", file_path)
        end
        msg.error(string.format("Anytype %s failed: could not reach endpoint %s (exit %s): %s",
            action_name, endpoint, tostring(r.status), (r.stderr or ""):gsub("%s+$", "")))
        h.notify_error(err_text, "error", 6)
        return false, nil, status_code
    end

    -- Case 2: HTTP status is not 2xx
    if not status_code or status_code < 200 or status_code >= 300 then
        local api_msg = body:match('"message"%s*:%s*"([^"]+)"')
        local detail = api_msg and string.format("HTTP %d: %s", status_code or 0, api_msg)
            or string.format("HTTP %d", status_code or 0)
        local err_text = string.format("Anytype %s failed: %s", action_name, detail)
        if file_path then
            err_text = err_text .. string.format("\nFile kept: %s", file_path)
        end
        msg.error(string.format("Anytype %s failed (HTTP %s). Response body: %s",
            action_name, tostring(status_code), body))
        if r.stderr and r.stderr ~= "" then
            msg.error(string.format("Anytype %s stderr: %s", action_name, (r.stderr or ""):gsub("%s+$", "")))
        end
        h.notify_error(err_text, "error", 6)
        return false, body, status_code
    end

    return true, body, status_code
end

-- Upload media file and create a Bookmark in Anytype.
-- delete_after controls whether file_path is removed upon successful completion (defaults to true).
-- On any failure, the file is retained and its path reported in the error message.
local function upload_to_anytype(file_path, source_url, content_from_id, delete_after)
    if delete_after == nil then
        delete_after = true
    end

    msg.info(string.format(
        "upload_to_anytype called: file_path=%s, source_url=%s, content_from_id=%s, delete_after=%s",
        tostring(file_path), tostring(source_url), tostring(content_from_id), tostring(delete_after)
    ))

    if not file_path or file_path == "" then
        msg.error("Anytype upload failed: no file path specified")
        h.notify_error("Anytype upload failed: no file path specified", "error", 4)
        return false
    end

    local cfg = get_config()
    local endpoint, api_key, space_id = resolve_anytype_config(cfg)

    -- Clean refusal if credentials are not configured
    if api_key == '' or space_id == '' then
        local missing = {}
        if api_key == '' then
            table.insert(missing, "anytype_api_key (or ANYTYPE_API_KEY/ANYTYPE_APP_KEY)")
        end
        if space_id == '' then
            table.insert(missing, "anytype_space_id (or ANYTYPE_SPACE_ID)")
        end
        local err_msg = "Anytype config missing: set " .. table.concat(missing, " and ")
        err_msg = err_msg .. string.format("\nFile kept: %s", file_path)
        msg.error(err_msg)
        h.notify_error(err_msg, "error", 6)
        return false
    end

    log_endpoint_once(endpoint)
    h.notify("Uploading to Anytype via REST API...", "info", 9999)

    local headers = {
        "-H", "Authorization: Bearer " .. api_key,
        "-H", "Anytype-Version: " .. (cfg.anytype_version or "2025-11-08"),
    }

    -- Step 1: Upload file to v2 API
    local upload_url = string.format("%s/v2/spaces/%s/files", endpoint, space_id)
    local upload_cmd = {
        p.curl_exe, "-s", "-S",
        "-w", "\n%{http_code}",
        "-X", "POST",
        upload_url,
    }
    for _, header in ipairs(headers) do
        table.insert(upload_cmd, header)
    end
    table.insert(upload_cmd, "-F")
    table.insert(upload_cmd, "file=@" .. file_path)

    local ok_upload, upload_out, _ = execute_request(upload_cmd, endpoint, file_path, "file upload")
    if not ok_upload then
        return false
    end

    local file_id = upload_out:match('"file_id"%s*:%s*"([^"]+)"')
        or upload_out:match('"id"%s*:%s*"([^"]+)"')
    if not file_id then
        local err_msg = string.format("Anytype file upload failed: invalid response\nFile kept: %s", file_path)
        msg.error(string.format("Anytype file upload invalid response: %s", upload_out))
        h.notify_error(err_msg, "error", 6)
        return false
    end

    msg.info("Anytype file uploaded, file_id: " .. file_id)

    -- Step 2: Create Bookmark object with v2 API
    local objects_url = string.format("%s/v2/spaces/%s/objects", endpoint, space_id)
    local clip_name = h.clean_forbidden_characters(
        mp.get_property("media-title", "clip")
    )
    if not clip_name or clip_name == "" then
        clip_name = "clip"
    end

    local properties = {}
    if source_url and source_url ~= "" then
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
        p.curl_exe, "-s", "-S",
        "-w", "\n%{http_code}",
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

    local ok_create, create_out, _ = execute_request(create_cmd, endpoint, file_path, "object creation")
    if not ok_create then
        return false
    end

    local object_id = create_out:match('"id"%s*:%s*"([^"]+)"')
        or create_out:match('"object_id"%s*:%s*"([^"]+)"')
    if not object_id then
        local err_msg = string.format("Anytype object creation failed: invalid response\nFile kept: %s", file_path)
        msg.error(string.format("Anytype object creation invalid response: %s", create_out))
        h.notify_error(err_msg, "error", 6)
        return false
    end

    msg.info("Anytype Bookmark object created, object_id: " .. object_id)

    -- Step 3: Patch object with Content From relation if provided
    if content_from_id and content_from_id ~= "" then
        local patch_url = string.format("%s/v2/spaces/%s/objects/%s", endpoint, space_id, object_id)
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
            p.curl_exe, "-s", "-S",
            "-w", "\n%{http_code}",
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
            msg.warn("Anytype object patch failed (content_from): " .. (patch_r.stderr or ""))
        else
            msg.info("Anytype Bookmark patched with content_from: " .. content_from_id)
        end
    end

    -- Copy link to clipboard
    local link = string.format("anytype://object?objectId=%s&spaceId=%s", object_id, space_id)
    local cb = p.clipboard.copy(link)
    if cb and cb.status ~= 0 then
        h.notify("Uploaded to Anytype!\nFailed to copy link to clipboard.", "warn", 4)
    else
        h.notify("Uploaded to Anytype!\nLink copied to clipboard.", "info", 4)
    end

    -- Delete local file only on complete success
    if delete_after then
        local deleted, err = os.remove(file_path)
        if not deleted then
            msg.error("Failed to delete local file: " .. (err or ""))
        end
    end

    return true, object_id, link
end

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

    upload_to_anytype(filepath, nil, nil, false)
end

mp.add_key_binding("u", "anytype_upload", upload_current_file)

anytype_upload.resolve_anytype_config = resolve_anytype_config
anytype_upload.upload_to_anytype = upload_to_anytype

return anytype_upload
