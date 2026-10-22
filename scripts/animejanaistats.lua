local open = io.open

local showingMessage = false
local MAX_DURATION = 2147483

-- Function to be called when the custom action is triggered
function show_animejanai_stats()
    if mp.get_property_native('idle-active') then
        mp.osd_message('请先打开视频，再查看 AnimeJaNai 超分状态。', 3)
        return
    end
    if showingMessage then
        mp.osd_message("")  -- Clear the OSD message
        showingMessage = false
    else
        local message = ""

        local has_ai = false
        for _, f in ipairs(mp.get_property_native("vf") or {}) do
            if f.label == "aji" and f.enabled ~= false then has_ai = true end
        end
        if not has_ai then
            message = "Upscaling is disabled"
        else
            local data_file_path = (mp.command_native({'expand-path', "~~/../animejanai/currentanimejanai.log"}))
            message = read_file(data_file_path)

            if message == "" then
                message = "Error during upscale; press ~ to view error in console"
            end
        end
        
        mp.osd_message(message, MAX_DURATION)
        showingMessage = true
    end
end

function read_file(path)
    local file = open(path, "r") -- r read mode and b binary mode
    if not file then return "" end
    local content = file:read "*a" -- *a or *all reads the whole file
    file:close()
    return content
end


-- Register the custom action to a key binding (e.g., "Ctrl+Shift+C")
mp.add_key_binding("Ctrl+j", "show_animejanai_stats", show_animejanai_stats)
