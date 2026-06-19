local is_enabled = true
local auto_x = true
local auto_y = true
local auto_z = false
local auto_rot = true
local target_x = 0.0
local target_y = -0.15
local target_z = 0.0
local smooth_speed = 10.0
local rot_smooth_speed = 1.3
local swap_cooldown_duration = 0.5
local rot_aim_delay = 0.3
local rot_swap_cooldown_duration = swap_cooldown_duration + rot_aim_delay
local allow_third_person = false
local hide_crosshair = false

local current_fov_display = 46.0
local _cached_fov_accessor = nil

local cur_x, cur_y, cur_z = 0, 0, 0
local cur_rot_delta = {w=1, x=0, y=0, z=0}
local cam_euler_display = {0, 0, 0}
local wep_euler_display = {0, 0, 0}
local auto_detected_offset = {0, 0, 0}
local is_aiming = false
local was_aiming = false
local aiming_start_time = 0.0
local last_eid = nil
local swap_cooldown_end = 0
local rot_swap_cooldown_end = 0

local debug_cached_player = nil

local function get_active_weapon_transform(scene, player)
    local pe = player:call("getComponent(System.Type)", sdk.typeof("app.PlayerEquipment"))
    if pe then
        local ok_eid, eid = pcall(pe.get_field, pe, "<EquipWeaponID>k__BackingField")
        if ok_eid and eid then
            local ok_s, eid_str = pcall(eid.call, eid, "ToString()")
            if not ok_s or not eid_str then
                local ok_v, val = pcall(eid.get_field, eid, "value__")
                if ok_v then eid_str = tostring(val) end
            end
            if eid_str then
                eid_str = eid_str:lower()
                local wep_go = scene:call("findGameObject(System.String)", eid_str)
                if wep_go then
                    return wep_go, eid_str
                end
            end
        end
    end
    -- -- Fallback: try to find common weapon names
    -- for _, name in ipairs({"arm0000", "arm0001", "arm0003", "arm0004", "arm0005", 
    --                         "arm0006", "arm0007", "arm0100", "arm0103", "arm0104", 
    --                         "arm0400_leon", "arm0400_grace", "arm0500", "arm0501", 
    --                         "arm0503", "arm0505", "arm0600", "arm0601"}) do
    --     local w = scene:call("findGameObject(System.String)", name)
    --     if w then return w:call("get_Transform") end
    -- end
    -- return nil
end

local function inverse_quat(q)
    return { w = q.w, x = -q.x, y = -q.y, z = -q.z }
end

local function quat_mul(q1, q2)
    return {
        w = q1.w*q2.w - q1.x*q2.x - q1.y*q2.y - q1.z*q2.z,
        x = q1.w*q2.x + q1.x*q2.w + q1.y*q2.z - q1.z*q2.y,
        y = q1.w*q2.y - q1.x*q2.z + q1.y*q2.w + q1.z*q2.x,
        z = q1.w*q2.z + q1.x*q2.y - q1.y*q2.x + q1.z*q2.w
    }
end

local function euler_to_quat(x, y, z)
    local cx = math.cos(x * 0.5); local sx = math.sin(x * 0.5)
    local cy = math.cos(y * 0.5); local sy = math.sin(y * 0.5)
    local cz = math.cos(z * 0.5); local sz = math.sin(z * 0.5)
    return {
        w = cx * cy * cz + sx * sy * sz,
        x = sx * cy * cz - cx * sy * sz,
        y = cx * sy * cz + sx * cy * sz,
        z = cx * cy * sz - sx * sy * cz,
    }
end

local function quat_to_euler(q)
    local x, y, z
    local sinr_cosp = 2 * (q.w * q.x + q.y * q.z)
    local cosr_cosp = 1 - 2 * (q.x * q.x + q.y * q.y)
    x = math.atan(sinr_cosp, cosr_cosp)
    
    local sinp = 2 * (q.w * q.y - q.z * q.x)
    if math.abs(sinp) >= 1 then
        y = math.pi / 2 * (sinp > 0 and 1 or -1)
    else
        y = math.asin(sinp)
    end
    
    local siny_cosp = 2 * (q.w * q.z + q.x * q.y)
    local cosy_cosp = 1 - 2 * (q.y * q.y + q.z * q.z)
    z = math.atan(siny_cosp, cosy_cosp)
    
    return math.deg(x), math.deg(y), math.deg(z)
end

local function quat_nlerp(q1, q2, t)
    local dot = q1.x*q2.x + q1.y*q2.y + q1.z*q2.z + q1.w*q2.w
    local q2_sign = dot < 0 and -1 or 1
    
    local nx = q1.x + (q2.x * q2_sign - q1.x) * t
    local ny = q1.y + (q2.y * q2_sign - q1.y) * t
    local nz = q1.z + (q2.z * q2_sign - q1.z) * t
    local nw = q1.w + (q2.w * q2_sign - q1.w) * t
    
    local len = math.sqrt(nx*nx + ny*ny + nz*nz + nw*nw)
    if len < 0.000001 then return {x=0, y=0, z=0, w=1} end
    return { x = nx/len, y = ny/len, z = nz/len, w = nw/len }
end

local function quat_mul_vec3(q, v)
    local qv = { x = q.x, y = q.y, z = q.z }
    local uv = {
        x = qv.y * v.z - qv.z * v.y,
        y = qv.z * v.x - qv.x * v.z,
        z = qv.x * v.y - qv.y * v.x
    }
    local uuv = {
        x = qv.y * uv.z - qv.z * uv.y,
        y = qv.z * uv.x - qv.x * uv.z,
        z = qv.x * uv.y - qv.y * uv.x
    }
    return {
        x = v.x + ((uv.x * q.w) + uuv.x) * 2.0,
        y = v.y + ((uv.y * q.w) + uuv.y) * 2.0,
        z = v.z + ((uv.z * q.w) + uuv.z) * 2.0
    }
end

local function apply_joint_offset(transform, joint_name, world_delta)
    local joint = transform:call("getJointByName", joint_name)
    if not joint then return end
    
    local parent = joint:call("get_Parent")
    if not parent then return end
    
    local p_rot = parent:call("get_Rotation")
    if not p_rot then return end
    
    local inv_p_rot = inverse_quat(p_rot)
    local local_delta = quat_mul_vec3(inv_p_rot, world_delta)
    local cur_local = joint:call("get_LocalPosition")
    if not cur_local then return end
    
    joint:call("set_LocalPosition", Vector3f.new(
        cur_local.x + local_delta.x,
        cur_local.y + local_delta.y,
        cur_local.z + local_delta.z
    ))
end

local function apply_joint_rotation(transform, joint_name, world_rot_delta)
    local joint = transform:call("getJointByName", joint_name)
    if not joint then return end
    local j_rot = joint:call("get_Rotation")
    if not j_rot then return end
    local new_rot = quat_mul(world_rot_delta, j_rot)
    joint:call("set_Rotation", Vector4f.new(new_rot.x, new_rot.y, new_rot.z, new_rot.w))
end

re.on_application_entry("LateUpdateBehavior", function()
    if not is_enabled then return end

    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return end
    local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return end
    
    local player = scene:call("findGameObject(System.String)", "Player")
    debug_cached_player = player
    if not player then
        for _, name in ipairs({"cp_A000", "cp_A100", "cp_A110"}) do
            player = scene:call("findGameObject(System.String)", name)
            if player then break end
        end
    end
    if not player then return end

    local pos_setting = player:call("getComponent(System.Type)", sdk.typeof("app.PlayerCameraPositionSetting"))
    is_aiming = false
    
    local char_mgr = sdk.get_managed_singleton("app.CharacterManager")
    if char_mgr and pos_setting then
        local ok_ctx, ctx = pcall(char_mgr.call, char_mgr, "get_PlayerContextFast")
        if ok_ctx and ctx then
            local ok_vm, view_mode = pcall(ctx.get_field, ctx, "<CurrentViewMode>k__BackingField")
            local is_first_person = (ok_vm and tonumber(view_mode) == 1)
            
            if is_first_person or allow_third_person then
                local ok_h, is_hold = pcall(pos_setting.get_field, pos_setting, "_IsHold")
                if ok_h and is_hold == true then
                    is_aiming = true
                end
            end
        end
    end

    local cam = sdk.get_primary_camera()
    if not cam then return end
    local wep_go, current_eid = get_active_weapon_transform(scene, player)
    if not wep_go or not current_eid then return end

    if last_eid ~= nil and last_eid ~= current_eid then
        -- Weapon changed! Start a cooldown where aim offset is suspended
        swap_cooldown_end = os.clock() + swap_cooldown_duration
        rot_swap_cooldown_end = os.clock() + rot_swap_cooldown_duration
    end
    last_eid = current_eid

    local cam_go = cam:call("get_GameObject")
    if not cam_go then return end
    local cam_xform = cam_go:call("get_Transform")
    if not cam_xform then return end
    local c_rot = cam_xform:call("get_Rotation")
    if not c_rot then return end

    local wep_xform = wep_go:call("get_Transform")
    
    if is_aiming then
        if not wep_xform then
            is_aiming = false
        else
            local wep_go = wep_xform:call("get_GameObject")
            if wep_go then
                local wep_name = string.lower(wep_go:call("get_Name") or "")
                -- Ignore grenades (arm02) and melee weapons (arm03)
                if string.find(wep_name, "^arm02") or string.find(wep_name, "^arm03") then
                    is_aiming = false
                end
            end
        end
    end

    if is_aiming and not was_aiming then
        aiming_start_time = os.clock()
    end
    was_aiming = is_aiming

    local pos_active = is_aiming and (os.clock() >= swap_cooldown_end)
    local rot_active = is_aiming and auto_rot and (os.clock() >= rot_swap_cooldown_end) and (os.clock() >= aiming_start_time + rot_aim_delay)

    local w_rot = wep_xform:call("get_Rotation")
    if c_rot then
        local cx, cy, cz = quat_to_euler(c_rot)
        cam_euler_display = {cx, cy, cz}
    end
    if w_rot then
        local wx, wy, wz = quat_to_euler(w_rot)
        wep_euler_display = {wx, wy, wz}
    end

    if rot_active then
        local target_D = {w=1, x=0, y=0, z=0}
        if w_rot and c_rot then
            local current_offset = quat_mul(inverse_quat(c_rot), w_rot)
            local ox, oy, oz = quat_to_euler(current_offset)
            
            -- Auto-snap to nearest 90 degrees to find the structural model axes
            local snap_x = math.floor((ox + 45) / 90) * 90
            local snap_y = math.floor((oy + 45) / 90) * 90
            local snap_z = math.floor((oz + 45) / 90) * 90
            
            auto_detected_offset = {snap_x, snap_y, snap_z}
            
            local fixed_offset = euler_to_quat(math.rad(snap_x), math.rad(snap_y), math.rad(snap_z))
            
            -- Directly use the camera's rotation (which already contains its own sway/recoil)
            local desired_w_rot = quat_mul(c_rot, fixed_offset)
            
            target_D = quat_mul(desired_w_rot, inverse_quat(w_rot))
        end
        -- Use rot_smooth_speed to allow independent control of rotation snap vs position snap
        cur_rot_delta = quat_nlerp(cur_rot_delta, target_D, rot_smooth_speed * 0.016)
    else
        cur_rot_delta = quat_nlerp(cur_rot_delta, {w=1, x=0, y=0, z=0}, smooth_speed * 0.016)
    end

    if pos_active then
        local c_pos = cam_xform:call("get_Position")
        local w_pos = wep_xform:call("get_Position")

        if not c_pos or not w_pos then return end

        local predicted_w_pos = w_pos
        if math.abs(cur_rot_delta.x) > 0.001 or math.abs(cur_rot_delta.y) > 0.001 or math.abs(cur_rot_delta.z) > 0.001 then
            local player_xform = player:call("get_Transform")
            local r_clav = player_xform and player_xform:call("getJointByName", "R_Arm_Clavicle")
            if r_clav then
                local clav_pos = r_clav:call("get_Position")
                if clav_pos then
                    local w_rel_clav = { x = w_pos.x - clav_pos.x, y = w_pos.y - clav_pos.y, z = w_pos.z - clav_pos.z }
                    local w_rel_clav_rot = quat_mul_vec3(cur_rot_delta, w_rel_clav)
                    predicted_w_pos = {
                        x = clav_pos.x + w_rel_clav_rot.x,
                        y = clav_pos.y + w_rel_clav_rot.y,
                        z = clav_pos.z + w_rel_clav_rot.z
                    }
                end
            end
        end

        -- X offset is relative to the actual Camera (to ensure crosshair alignment)
        local w_rel_cam = {
            x = predicted_w_pos.x - c_pos.x,
            y = predicted_w_pos.y - c_pos.y,
            z = predicted_w_pos.z - c_pos.z
        }
        local c_rot_inv = inverse_quat(c_rot)
        local w_local_cam = quat_mul_vec3(c_rot_inv, w_rel_cam)

        -- FOV-based Screen Placement
        local fov = 46.0
        
        -- Reflectively find the correct FOV accessor (method or field) just once
        if _cached_fov_accessor == nil then
            _cached_fov_accessor = "NONE"
            local t = cam:get_type_definition()
            -- Try methods
            for _, m in ipairs(t:get_methods()) do
                local name = m:get_name()
                if (name:find("Fov") or name:find("FOV")) and name:find("get") then
                    _cached_fov_accessor = { type = "method", name = name }
                    break
                end
            end
            -- Try fields if no method
            if _cached_fov_accessor == "NONE" then
                for _, f in ipairs(t:get_fields()) do
                    local name = f:get_name()
                    if name == "FOV" or name == "Fov" or name == "vFOV" then
                        _cached_fov_accessor = { type = "field", name = name }
                        break
                    end
                end
            end
        end
        
        -- Retrieve FOV
        if type(_cached_fov_accessor) == "table" then
            local ok_fov, val
            if _cached_fov_accessor.type == "method" then
                ok_fov, val = pcall(cam.call, cam, _cached_fov_accessor.name)
            else
                ok_fov, val = pcall(cam.get_field, cam, _cached_fov_accessor.name)
            end
            
            if ok_fov and type(val) == "number" then 
                fov = val
                -- RE Engine usually returns FOV in degrees, but if it's exceptionally small, it's radians
                if fov < 5.0 then fov = math.deg(fov) end
            end
        end

        current_fov_display = fov
        
        -- Calculate FOV scale relative to the base 46 FOV
        local base_fov = 46.0
        local fov_scale = math.tan(math.rad(fov) / 2.0) / math.tan(math.rad(base_fov) / 2.0)
        
        local scaled_target_x = target_x * fov_scale
        local scaled_target_y = target_y * fov_scale

        -- Calculate target offsets
        local to_x = auto_x and (w_local_cam.x - scaled_target_x) or 0.0
        local to_y = auto_y and (w_local_cam.y - scaled_target_y) or 0.0
        
        local desired_z = w_local_cam.z
        if auto_z then 
            -- Scale Z inversely to maintain identical apparent visual size across different FOVs
            desired_z = target_z / fov_scale 
        end

        -- Hard constraint: Weapon Z must be strictly in front of the TRUE camera lens to avoid clipping
        -- In RE Engine camera local space, the lens is at Z=0 and forward is -Z.
        -- We force the weapon to be at least 10cm (-0.15) in front of the true lens.
        if desired_z > -0.15 then
            desired_z = -0.15
        end

        local to_z = w_local_cam.z - desired_z

        -- Smooth interpolation
        cur_x = cur_x + (to_x - cur_x) * smooth_speed * 0.016
        cur_y = cur_y + (to_y - cur_y) * smooth_speed * 0.016
        cur_z = cur_z + (to_z - cur_z) * smooth_speed * 0.016
    else
        cur_x = cur_x + (0 - cur_x) * smooth_speed * 0.016
        cur_y = cur_y + (0 - cur_y) * smooth_speed * 0.016
        cur_z = cur_z + (0 - cur_z) * smooth_speed * 0.016
    end

    if not pos_active and not rot_active then
        -- Stop updating if we are virtually back to normal
        if math.abs(cur_x) < 0.001 and math.abs(cur_y) < 0.001 and math.abs(cur_z) < 0.001 and
           math.abs(cur_rot_delta.x) < 0.001 and math.abs(cur_rot_delta.y) < 0.001 and math.abs(cur_rot_delta.z) < 0.001 then
            cur_x, cur_y, cur_z = 0, 0, 0
            cur_rot_delta = {w=1, x=0, y=0, z=0}
            return
        end
    end

    -- The required offset to the arms is the INVERSE of the camera offset
    local world_offset = quat_mul_vec3(c_rot, {x = -cur_x, y = -cur_y, z = -cur_z})
    
    local player_xform = player:call("get_Transform")
    if player_xform then
        apply_joint_rotation(player_xform, "R_Arm_Clavicle", cur_rot_delta)
        apply_joint_rotation(player_xform, "L_Arm_Clavicle", cur_rot_delta)
        
        apply_joint_offset(player_xform, "R_Arm_Clavicle", world_offset)
        apply_joint_offset(player_xform, "L_Arm_Clavicle", world_offset)
    end
end)

local reticle_names = {
    ["ReticleGUI"] = true,
    ["CH8ReticleGUI"] = true,
    ["CH9ReticleGUI"] = true,
    ["GUIReticle"] = true,
    ["GUI_Reticle"] = true,
    ["Gui_ui2020"] = true
}

re.on_pre_gui_draw_element(function(element, context)
    if not hide_crosshair then return true end

    local game_object = element:call("get_GameObject")
    if game_object == nil then return true end

    local name = game_object:call("get_Name")
    if reticle_names[name] then
        -- Return false to prevent the crosshair from being drawn while aiming
        return false
    end

    return true
end)

re.on_draw_ui(function()
    if imgui.collapsing_header("Dynamic Auto-Centering Aim") then
        local changed, val = imgui.checkbox("Enable Dynamic Aim Fix", is_enabled)
        if changed then is_enabled = val end

        imgui.text("Status: " .. (is_aiming and "AIMING" or "IDLE"))
        imgui.text(string.format("Current Native FOV: %.2f", current_fov_display))

        imgui.separator()
        imgui.text("Settings:")
        
        local c3, v3 = imgui.checkbox("Allow in Third Person (Funny Glitch)", allow_third_person)
        if c3 then allow_third_person = v3 end

        local hc, hv = imgui.checkbox("Hide Crosshair (Iron Sights)", hide_crosshair)
        if hc then hide_crosshair = hv end

        local cx, vx = imgui.checkbox("Enable X Alignment (Horizontal)", auto_x)
        if cx then auto_x = vx end
        if auto_x then
            local px, p_vx = imgui.slider_float("  Target X (Right Offset)", target_x, -0.5, 0.5)
            if px then target_x = p_vx end
        end

        local cy, vy = imgui.checkbox("Enable Y Alignment (Vertical)", auto_y)
        if cy then auto_y = vy end
        if auto_y then
            local py, p_vy = imgui.slider_float("  Target Y (Down Offset)", target_y, -0.5, 0.5)
            if py then target_y = p_vy end
        end

        local cz, vz = imgui.checkbox("Auto-Align Z (Override Distance)", auto_z)
        if cz then auto_z = vz end
        if auto_z then
            local tz, t_vz = imgui.slider_float("  Target Z (Distance from Cam)", target_z, -1.0, 1.0)
            if tz then target_z = t_vz end
        end

        local cr, vr = imgui.checkbox("Enable Rotation Alignment (Angle)", auto_rot)
        if cr then auto_rot = vr end
        
        -- if auto_rot then
        --     imgui.text_colored(string.format("Auto-Snapped Model Axes: P %d, Y %d, R %d", auto_detected_offset[1], auto_detected_offset[2], auto_detected_offset[3]), 0xFF00FFFF)
        -- end
        
        -- imgui.spacing()
        -- imgui.text(string.format("Camera Angle: Pitch %.1f, Yaw %.1f, Roll %.1f", cam_euler_display[1], cam_euler_display[2], cam_euler_display[3]))
        -- imgui.text(string.format("Weapon Angle: Pitch %.1f, Yaw %.1f, Roll %.1f", wep_euler_display[1], wep_euler_display[2], wep_euler_display[3]))

        -- local ts, vs = imgui.slider_float("Positional Swap Cooldown (s)", swap_cooldown_duration, 0.0, 5.0)
        -- if ts then swap_cooldown_duration = vs end

        -- local rts, rvs = imgui.slider_float("Rotation Swap Cooldown (s)", rot_swap_cooldown_duration, 0.0, 5.0)
        -- if rts then rot_swap_cooldown_duration = rvs end

        -- local rtd, rvtd = imgui.slider_float("Rotation Aim Delay (s)", rot_aim_delay, 0.0, 2.0)
        -- if rtd then rot_aim_delay = rvtd end
        -- if imgui.is_item_hovered() then
        --     imgui.set_tooltip("Delays rotation alignment upon aiming to prevent twisting during the transition.")
        -- end

        -- local cs, vs2 = imgui.slider_float("Positional Transition Speed", smooth_speed, 1.0, 30.0)
        -- if cs then smooth_speed = vs2 end

        -- local crs, vrs = imgui.slider_float("Rotation Stiffness", rot_smooth_speed, 0.1, 30.0)
        -- if crs then rot_smooth_speed = vrs end
        -- if imgui.is_item_hovered() then
        --     imgui.set_tooltip("Lower values preserve natural weapon sway & recoil. Higher values lock it rigidly to the camera.")
        -- end

        -- imgui.separator()
        -- if imgui.tree_node("Advanced Debugger (Live State Viewer)") then
        --     if debug_cached_player then
        --         local function draw_debug_component(comp_name)
        --             if imgui.tree_node(comp_name) then
        --                 local comp = debug_cached_player:call("getComponent(System.Type)", sdk.typeof(comp_name))
        --                 if comp then
        --                     local t = comp:get_type_definition()
        --                     for _, f in ipairs(t:get_fields()) do
        --                         if f:get_type():get_full_name() == "System.Boolean" then
        --                             local name = f:get_name()
        --                             local ok, val = pcall(comp.get_field, comp, name)
        --                             if ok then
        --                                 if val == true then
        --                                     imgui.text_colored(name .. ": true", 0xFF00FF00)
        --                                 else
        --                                     imgui.text(name .. ": false")
        --                                 end
        --                             end
        --                         end
        --                     end
        --                     for _, m in ipairs(t:get_methods()) do
        --                         local name = m:get_name()
        --                         if (name:find("get_Is") or name:find("get_is")) and m:get_return_type():get_full_name() == "System.Boolean" and m:get_num_params() == 0 then
        --                             local ok, val = pcall(comp.call, comp, name)
        --                             if ok then
        --                                 if val == true then
        --                                     imgui.text_colored(name .. "(): true", 0xFF00FF00)
        --                                 else
        --                                     imgui.text(name .. "(): false")
        --                                 end
        --                             end
        --                         end
        --                     end
        --                 else
        --                     imgui.text_colored("Component not found on Player", 0xFF0000FF)
        --                 end
        --                 imgui.tree_pop()
        --             end
        --         end

        --         draw_debug_component("app.PlayerCameraPositionSetting")
        --         draw_debug_component("app.PlayerCondition")
        --         draw_debug_component("app.CharacterStatus")
        --         draw_debug_component("app.PlayerStatus")
        --         draw_debug_component("app.PlayerGunState")
        --     else
        --         imgui.text("Player not found in scene.")
        --     end
        --     imgui.tree_pop()
        -- end
    end
end)
