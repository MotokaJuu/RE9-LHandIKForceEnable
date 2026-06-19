-- LiveStateViewer.lua
local is_enabled = true
local debug_cached_player = nil

re.on_frame(function()
    if not is_enabled then return end
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        if not sm then return end
        local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        if not scene then return end
        local player = scene:call("findGameObject(System.String)", "Player")
        if not player then
            for _, name in ipairs({"cp_A000", "cp_A100", "cp_A110", "ch000", "ch0000"}) do
                player = scene:call("findGameObject(System.String)", name)
                if player then break end
            end
        end
        debug_cached_player = player
    end)
end)

-- Draw a single component's boolean fields and get_Is... getters
local function draw_comp(comp)
    local ok_t, t = pcall(function() return comp:get_type_definition() end)
    if not ok_t or not t then return end
    local comp_name = t:get_full_name()
    if imgui.tree_node(comp_name) then
        -- Boolean fields
        local ok_f, fields = pcall(function() return t:get_fields() end)
        if ok_f and fields then
            for _, f in ipairs(fields) do
                local ok_ft, ftype = pcall(function() return f:get_type():get_full_name() end)
                if ok_ft and ftype == "System.Boolean" then
                    local fname = f:get_name()
                    local ok_v, fval = pcall(comp.get_field, comp, fname)
                    if ok_v then
                        if fval then imgui.text_colored(fname .. ": true",  0xFF00FF00)
                        else          imgui.text(fname .. ": false") end
                    end
                end
            end
        end
        -- get_Is.../get_is... boolean getter methods
        local ok_m, methods = pcall(function() return t:get_methods() end)
        if ok_m and methods then
            for _, m in ipairs(methods) do
                local mname = m:get_name()
                local ok_r, rtype = pcall(function() return m:get_return_type():get_full_name() end)
                if (mname:find("get_Is") or mname:find("get_is"))
                    and ok_r and rtype == "System.Boolean"
                    and m:get_num_params() == 0 then
                    local ok_v, mval = pcall(comp.call, comp, mname)
                    if ok_v then
                        if mval then imgui.text_colored(mname .. "(): true",  0xFF00FF00)
                        else          imgui.text(mname .. "(): false") end
                    end
                end
            end
        end
        imgui.tree_pop()
    end
end

re.on_draw_ui(function()
    if imgui.tree_node("Live State Viewer (Advanced Debugger)") then
        local changed, val = imgui.checkbox("Enable Viewer", is_enabled)
        if changed then is_enabled = val end

        if is_enabled and debug_cached_player then
            -- get_Components returns a SystemArray; get_elements() converts it to a Lua table
            local ok_ca, comp_array = pcall(function()
                return debug_cached_player:call("get_Components")
            end)
            if ok_ca and comp_array then
                local ok_el, elements = pcall(function() return comp_array:get_elements() end)
                if ok_el and elements then
                    for _, comp in ipairs(elements) do
                        if comp then draw_comp(comp) end
                    end
                else
                    -- fallback: iterate by index
                    local ok_sz, sz = pcall(function() return comp_array:get_size() end)
                    if ok_sz and sz then
                        for i = 0, sz - 1 do
                            local ok_e, comp = pcall(function() return comp_array:get_element(i) end)
                            if ok_e and comp then draw_comp(comp) end
                        end
                    else
                        imgui.text_colored("Cannot iterate comp_array: " .. tostring(comp_array), 0xFF0000FF)
                    end
                end
            else
                imgui.text_colored("get_Components failed", 0xFF0000FF)
            end
        elseif is_enabled then
            imgui.text("Player not found in scene.")
        end

        imgui.tree_pop()
    end
end)
