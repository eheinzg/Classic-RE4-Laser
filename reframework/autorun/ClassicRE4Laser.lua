if reframework:get_game_name() ~= "re4" then
  return
end

-- Signal to other scripts that Classic RE4 Laser is present
_G.__classic_re4_laser_present = true

local re4 = require("utility/RE4")
local hk = require("Hotkeys/Hotkeys")
local CastRays = require("utility/CastRays")

local laser_toggle_action = "ToggleLaserTrail"
local laser_toggle_modifier = "ToggleLaserTrail_$"

-- Default hotkey settings
local Laser_default_settings = {
    use_modifier = true,
    use_pad_modifier = true,
    hotkeys = {
        ["Laser Modifier"] = "R Mouse",
        ["Laser Toggle"] = "EX1",
        ["Pad Laser Modifier"] = "LT (L2)",
        ["Pad Laser Toggle"] = "A (X)",
    }
}

-- Load settings with proper fallback
local Laser_settings = hk.merge_tables({}, Laser_default_settings) and hk.recurse_def_settings(json.load_file("ClassicLaser/Laser_Hotkey_Settings.json") or {}, Laser_default_settings)
hk.setup_hotkeys(Laser_settings.hotkeys)

local changed = false
local wc = false

local show_laser_dot = true -- Controls dot/crosshair visibility
local hide_dot_when_no_muzzle = false -- Hide reticle/dot when no muzzle is found

re4.crosshair_pos = Vector3f.new(0, 0, 0)
re4.crosshair_normal = Vector3f.new(0, 0, 0)

local gameobject_get_transform = sdk.find_type_definition("via.GameObject"):get_method("get_Transform")

local joint_get_position = sdk.find_type_definition("via.Joint"):get_method("get_Position")
local joint_get_rotation = sdk.find_type_definition("via.Joint"):get_method("get_Rotation")

local CollisionLayer = CastRays.CollisionLayer
local CollisionFilter = CastRays.CollisionFilter

local crosshair_bullet_ray_result = nil
local crosshair_attack_ray_result = nil
local last_crosshair_time = os.clock()
local last_crosshair_pos = Vector3f.new(0, 0, 0)
local last_muzzle_pos = Vector3f.new(0, 0, 0)
local crosshair_frozen_time = 0

local vec3_t = sdk.find_type_definition("via.vec3")
local quat_t = sdk.find_type_definition("via.Quaternion")
local raycastHit_t = sdk.find_type_definition(sdk.game_namespace("RaycastHit"))

global_intersection_point = nil

-- Global flag for other mods to check if Classic RE4 Style mode is active
-- When true, bullet spawn is handled by ClassicRE4Laser (not IronSight.lua)
_G.classic_re4_laser_bullet_spawn_active = false

local scene = nil
local gun_obj = nil

-- Global variables for laser trail offset calculations
local current_weapon_id = nil
local current_muzzle_joint = nil

local reticleValue = 4        

local hasRunInitially = false

local scene_manager = nil
local gui_initialized = false
local minRange = 0
local maxRange = 5
dot_scale = 0.85  -- Default dot scale
knife_dot_scale = 0.85  -- Default knife dot scale
local min_scale = 0.3
local max_scale = 1.25
local config_file = "ClassicLaser\\LaserSettings.json"

local character_ids = {
"ch3a8z0_head", "ch6i0z0_head", "ch6i1z0_head", "ch6i2z0_head",
"ch6i3z0_head", "ch3a8z0_MC_head", "ch6i5z0_head"
}
local disable_shoulder_corrector = false 

local crosshair_saturation = 20.0  -- Crosshair color saturation (glow)

-- Weapon names for UI display
local weapon_names = {
  [4000] = "SG-09 R",
  [4001] = "Punisher",
  [4002] = "Red9",
  [4003] = "Blacktail",
  [4004] = "Matilda",
  [4100] = "W-870",
  [4101] = "Riot Gun",
  [4102] = "Striker",
  [4200] = "TMP",
  [4201] = "Chicago Sweeper",
  [4202] = "LE 5",
  [4400] = "SR M1903",
  [4401] = "Stingray",
  [4402] = "CQBR Assault Rifle",
  [4500] = "Broken Butterfly",
  [4501] = "Killer7",
  [4502] = "Handcannon",
  [4600] = "Bolt Thrower",
  [4900] = "Rocket Launcher",
  [4901] = "Rocket Launcher (Special)",
  [4902] = "Infinite Rocket Launcher",
  [6000] = "Sentinel Nine",
  [6001] = "Skull Shaker",
  [6100] = "Sawed-off W-870",
  [6101] = "Chicago Sweeper SW",
  [6102] = "Blast Crossbow",
  [6103] = "Blacktail AC",
  [6104] = "TMP SW",
  [6105] = "Stingray SW",
  [6106] = "Rocket Launcher SW",
  [6111] = "Infinite Rocket Launcher SW",
  [6112] = "Punisher MC",
  [6113] = "Red9 SW",
  [6114] = "SR M1903 SW",
  [6300] = "XM96E1",
  [6304] = "EJF-338 Compound Bow",
}

-- Weapon categories for organized display
local weapon_categories = {
    {name = "Handguns", ids = {4000, 4001, 4002, 4003, 4004, 6000, 6001, 6112, 6300}},
    {name = "Shotguns", ids = {4100, 4101, 4102, 6100, 6101, 6102}},
    {name = "SMGs", ids = {4200, 4201, 4202, 6103, 6104}},
    {name = "Rifles", ids = {4400, 4401, 4402, 6105, 6114}},
    {name = "Magnums", ids = {4500, 4501, 4502, 6113, 6304}},
    {name = "Special", ids = {4600, 4900, 4901, 4902, 6106, 6111}},
}

-- Per-weapon laser trail enable (default all enabled)
local weapon_laser_enabled = {}

-- Persistent color arrays for imgui.color_edit4
local laser_beam_color_array = {1.0, 0.0, 0.0, 1.0}  -- RGBA values for laser beam (0.0-1.0)
local laser_dot_color_array = {1.0, 0.0, 0.0, 1.0}   -- RGBA values for laser dot (0.0-1.0)
local knife_dot_color_array = {1.0, 1.0, 1.0, 1.0}   -- RGBA values for knife/no-muzzle dot (0.0-1.0)
local static_reticle_color_array = {1.0, 1.0, 1.0, 1.0}  -- RGBA values for static reticle when weapon laser disabled (0.0-1.0)
local laser_color_array = laser_dot_color_array       -- Legacy compatibility


local static_center_dot = false  -- New option for static center dot
local simple_static_mode = false  -- New option for completely static dot with no custom calculations
local cached_static_intersection_point = nil  -- Cache for camera-based intersection
local cached_static_surface_distance = 10.0  -- Cache for original surface distance
local cached_static_camera_pos = nil  -- Cache for camera position used in static dot
local static_attack_ray_result = nil  -- Persistent ray result for attack layer
local static_bullet_ray_result = nil  -- Persistent ray result for bullet layer
local stored_static_center_dot = nil  -- Cache user preference when forced overrides run
local force_classic_re4_prev = false  -- Track previous force state to restore preference
local force_disable_shoulder_prev = false  -- Track previous force disable state (IronSight or FP mode)
local stored_disable_shoulder_corrector = nil  -- Cache shoulder corrector preference across forced states
local SHOULDER_RESTORE_DELAY_FRAMES = 30 -- Frames to wait before restoring shoulder corrector
local shoulder_restore_frames = 0
local pending_shoulder_restore = nil

-- Static center dot positioning variables
local static_target_intersection_point = nil  -- Target position from raycast

-- Unified offset constants to avoid redundancy
local SURFACE_OFFSET = 1.0  -- Distance to pull dot away from surfaces
local TRAIL_OFFSET = 0.1    -- Small adjustment for trail positioning
local CAMERA_RAYCAST_OFFSET = 2.0  -- Camera forward offset for raycast origin

-- Default laser origin offsets for each weapon
local default_laser_origin_offsets = {
    ["4000"] = {x = 0.0, y = -0.04529999941587448, z = -0.007300000172108412},
    ["4001"] = {x = 0.0, y = -0.04540000110864639, z = 0.004100000020116568},
    ["4002"] = {x = 0.0, y = -0.02199999988079071, z = -0.060600001364946365},
    ["4003"] = {x = 0.0, y = -0.05150000038146973, z = 0.0},
    ["4004"] = {x = 0.0, y = -0.05260000038146973, z = -0.0494999997317791},
    ["4100"] = {x = 0.0, y = -0.029500000178813934, z = -0.006800000090152025},
    ["4101"] = {x = 0.0, y = -0.028699999675154686, z = -0.1889999955892563},
    ["4102"] = {x = 0.0, y = -0.027800000250339508, z = 0.0},
    ["4200"] = {x = -0.029400000348687172, y = 0.012900000438094139, z = -0.04780000075697899},
    ["4201"] = {x = 0.0, y = -0.04780000075697899, z = -0.04780000075697899},
    ["4202"] = {x = 0.0, y = 0.02850000001490116, z = -0.04830000177025795},
    ["4400"] = {x = -0.027000000298023224, y = 0.007200000072002888, z = -0.0638000023841858},
    ["4401"] = {x = -0.030500000342726707, y = 0.016499999910593033, z = -0.16910000145435333},
    ["4402"] = {x = 0.0, y = -0.04479999840259552, z = -0.1324000060558319},
    ["4500"] = {x = 0.0, y = -0.028999999165534973, z = -0.09700000286102295},
    ["4501"] = {x = 0.0, y = 0.03999999910593033, z = -0.010999999940395355},
    ["4502"] = {x = 0.0, y = -0.03280000016093254, z = -0.210999995470047},
    ["4600"] = {x = 0.0, y = -0.02550000083446503, z = 0.0},
    ["4900"] = {x = 0.060499999672174454, y = -0.017999999225139618, z = -0.2922000007629395},
    ["4901"] = {x = 0.060499999672174454, y = -0.017000000149011612, z = -0.30590000009536743},
    ["4902"] = {x = 0.060499999672174454, y = -0.017999999225139618, z = -0.2922000007629395},
    ["6000"] = {x = 0.0, y = -0.049400001764297485, z = -0.043299999088048935},
    ["6001"] = {x = 0.0, y = -0.04780000075697899, z = -0.04780000075697899},
    ["6100"] = {x = 0.0, y = -0.03350000083446503, z = -0.0924000007629395},
    ["6101"] = {x = 0.0, y = -0.0199000000298023224, z = -0.012199999988079071},
    ["6102"] = {x = -0.04800000041723251, y = 0.013500000350177288, z = -0.050999999046325684},
    ["6103"] = {x = 0.0, y = -0.05119999870657921, z = -0.013100000098347664},
    ["6104"] = {x = -0.029400000348687172, y = 0.012900000438094139, z = -0.04820000007748604},
    ["6105"] = {x = -0.030500000342726707, y = 0.016499999910593033, z = -0.17640000581741333},
    ["6106"] = {x = 0.060499999672174454, y = -0.017999999225139618, z = -0.30140000581741333},
    ["6111"] = {x = 0.060499999672174454, y = -0.017999999225139618, z = -0.30140000581741333},
    ["6112"] = {x = 0.0, y = -0.04540000110864639, z = 0.0044999998062849045},
    ["6113"] = {x = 0.0, y = -0.023600000888109207, z = -0.14149999618530273},
    ["6114"] = {x = -0.027000000298023224, y = 0.007200000072002888, z = -0.0638000023841858},
    ["6300"] = {x = 0.0, y = -0.04740000143647194, z = -0.003700000001117587},
    ["6304"] = {x = -0.07500000298023224, y = 0.0010000000474974513, z = -0.05010000019073486}
}

-- Table for per-weapon laser origin offsets (initialize with defaults)
laser_origin_offsets = laser_origin_offsets or {}
-- Apply defaults for any missing weapon offsets
for weapon_id, offset in pairs(default_laser_origin_offsets) do
    if not laser_origin_offsets[weapon_id] then
        laser_origin_offsets[weapon_id] = {x = offset.x, y = offset.y, z = offset.z}
    end
end

-- Laser trail variables
local enable_laser_trail = true  -- Enable/disable laser trail
local laser_trail_scale = 1.5   -- Scale of the laser trail
local laser_trail_gameobject = nil  -- Reference to the laser trail game object
local laser_mesh_resource = sdk.create_resource("via.render.MeshResource", "_chainsaw/character/wp/wp40/wp4000/21/wp4000_22.mesh")  -- Laser mesh resource
local laser_material_resource = sdk.create_resource("via.render.MeshMaterialResource", "LaserColors/classicRE4LaserMaterial.mdf2")  -- Laser material resource

-- Manual origin offset controls for different weapon laser modules
local laser_origin_offset_x = 0.0  -- X-axis offset from muzzle position
local laser_origin_offset_y = 0.0  -- Y-axis offset from muzzle position  
local laser_origin_offset_z = 0.0  -- Z-axis offset from muzzle position

-- Caching variables for performance optimization
local cached_pl_head = nil
local cached_gun_obj = nil
local cached_weapon_id = nil
local cached_laser_sight_obj = nil
local cache_refresh_time = 0
local cache_refresh_interval = 1.0  -- Refresh cache every 1 second
local is_non_muzzle_weapon = false

-- Global variable to track hold variation state
local is_hold_variation = false

-- Hook management variables
local is_hooks_active = false
local bullet_hook = nil
local last_hook_conditions = false -- Track previous state to detect changes

-- Weapon firing hook functions for hold variation correction
local function on_pre_request_fire(args)
  local shell_generator = sdk.to_managed_object(args[2])
  local arrow_shell_generator = sdk.to_managed_object(args[2])
  local gun = shell_generator:get_field("_OwnerInterface")
  local muzzle_joint = gun:call("getMuzzleJoint")
    if not muzzle_joint then
      
    end
  local owner = shell_generator:get_field("_Owner")
  local name = owner:call("get_Name")

  if not muzzle_joint then
    local gun_transforms = owner:get_Transform()
    muzzle_joint = gun_transforms:call("getJointByName", "vfx_muzzle")
end

  if muzzle_joint ~= nil then
    local muzzle_pos = muzzle_joint:call("get_Position")
    local muzzle_rot = muzzle_joint:call("get_Rotation")
    local set_item = vec3_t:get_method("set_Item(System.Int32, System.Single)")
    local pos_addr = sdk.to_ptr(sdk.to_int64(args[3]))
    set_item:call(pos_addr, 0, muzzle_pos.x)
    set_item:call(pos_addr, 1, muzzle_pos.y)
    set_item:call(pos_addr, 2, muzzle_pos.z)

    if global_intersection_point then
      local direction_to_intersection = (global_intersection_point - muzzle_pos):normalized()
      local new_rotation = direction_to_intersection:to_quat()

      local set_item = quat_t:get_method("set_Item(System.Int32, System.Single)")
      local rot_addr = sdk.to_ptr(sdk.to_int64(args[4]))
      set_item:call(rot_addr, 0, new_rotation.x)
      set_item:call(rot_addr, 1, new_rotation.y)
      set_item:call(rot_addr, 2, new_rotation.z)
      set_item:call(rot_addr, 3, new_rotation.w)
    end
  end
end

local function on_post_request_fire(retval)
  return retval
end

--hook for bullet shell generation only used for bolt thrower mine since there is a bug when setting in weapon catalog
local function hook_request_fire()
  if is_hooks_active then
    return -- Already hooked
  end
  
  local bullet_shell_generator_t = sdk.find_type_definition(sdk.game_namespace("BulletShellGenerator"))
  bullet_hook = sdk.hook(bullet_shell_generator_t:get_method("requestFire"), on_pre_request_fire, on_post_request_fire)
  
  is_hooks_active = true
end

local function unhook_request_fire()
  if not is_hooks_active then
    return -- Already unhooked
  end
  
  if bullet_hook then
    bullet_hook:unhook()
    bullet_hook = nil
  end
  
  is_hooks_active = false
end

-- Function to manage hooks based on conditions (only when conditions change)
local function manage_hooks(force_check)
  -- Don't apply hook logic if static center dot (RE4 Remake style) is enabled
  if static_center_dot then
    -- If hooks are currently active but static mode is enabled, unhook them
    if is_hooks_active then
      unhook_request_fire()
    end
    last_hook_conditions = false
    return
  end
  
  local should_hook = is_hold_variation and current_weapon_id == 4600
  
  -- Only do something if the conditions have changed OR if forced
  if should_hook ~= last_hook_conditions or force_check then
    if should_hook and not is_hooks_active then
      hook_request_fire()
    elseif not should_hook and is_hooks_active then
      unhook_request_fire()
    end
    last_hook_conditions = should_hook
  end
end

local function save_config()
  local data = {
      max_scale = max_scale,
      min_scale = min_scale,
      dot_scale = dot_scale,
      dot_color_r = dot_color_r,
      dot_color_g = dot_color_g,
      dot_color_b = dot_color_b,
      crosshair_saturation = crosshair_saturation,
      static_center_dot = static_center_dot,  -- Add this line
      simple_static_mode = simple_static_mode,  -- Add simple static mode
      hide_dot_when_no_muzzle = hide_dot_when_no_muzzle,  -- Hide dot when no muzzle found
      enable_laser_trail = enable_laser_trail,  -- Add laser trail settings
      laser_trail_scale = laser_trail_scale,
      knife_dot_scale = knife_dot_scale,  -- Add knife dot scale
      laser_origin_offsets = laser_origin_offsets,    -- Persist weapon-specific offsets
      laser_mat_params = _G.laser_mat_params,        -- Persist material editor params
      disable_shoulder_corrector = disable_shoulder_corrector,  -- Save shoulder corrector disable state
      -- Separate beam and dot colors
      laser_beam_color_array = laser_beam_color_array,
      laser_dot_color_array = laser_dot_color_array,
      knife_dot_color_array = knife_dot_color_array,
      static_reticle_color_array = static_reticle_color_array,  -- Static reticle color when weapon laser disabled
      laser_color_array = laser_color_array, -- Keep for legacy compatibility
      weapon_laser_enabled = weapon_laser_enabled,  -- Per-weapon laser enable
  }
  local success, err = pcall(json.dump_file, config_file, data)
  if not success then
      --log.info("OGRE4LaserDot: Error saving config: " .. tostring(err))
  end
end


-- Apply loaded laser trail material params to the mesh/material
local function apply_laser_trail_settings()
  if not laser_trail_gameobject then return end
  local mesh_component = laser_trail_gameobject:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
  if not mesh_component then return end
  if _G.laser_mat_params then
    for matName, params in pairs(_G.laser_mat_params) do
      for paramName, value in pairs(params) do
        local matCount = mesh_component:get_MaterialNum()
        for j = 0, matCount - 1 do
          if mesh_component:getMaterialName(j) == matName then
            local matParam = mesh_component:getMaterialVariableNum(j)
            for k = 0, matParam - 1 do
              if mesh_component:getMaterialVariableName(j, k) == paramName then
                local paramType = mesh_component:getMaterialVariableType(j, k)
                if paramType == 1 then
                  mesh_component:setMaterialFloat(j, k, value)
                elseif paramType == 4 and type(value) == "table" then
                  mesh_component:setMaterialFloat4(j, k, Vector4f.new(value[1], value[2], value[3], value[4]))
                end
              end
            end
          end
        end
      end
    end
  end
end

-- Function to apply beam color to the laser trail material
local function apply_beam_color(color_array)
  if not laser_trail_gameobject then return end
  local mesh_component = laser_trail_gameobject:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
  if not mesh_component or not mesh_component.setMaterialFloat4 then return end
  
  local matCount = mesh_component:get_MaterialNum()
  for j = 0, matCount - 1 do
    local matName = mesh_component:getMaterialName(j)
    local matParam = mesh_component:getMaterialVariableNum(j)
    for k = 0, matParam - 1 do
      local paramName = mesh_component:getMaterialVariableName(j, k)
      if paramName == "EmissiveColor" then
        local color_vector = Vector4f.new(color_array[1], color_array[2], color_array[3], color_array[4])
        mesh_component:setMaterialFloat4(j, k, color_vector)
        -- Also update the stored parameter
        if not _G.laser_mat_params then _G.laser_mat_params = {} end
        if not _G.laser_mat_params[matName] then _G.laser_mat_params[matName] = {} end
        _G.laser_mat_params[matName][paramName] = {color_array[1], color_array[2], color_array[3], color_array[4]}
        break
      end
    end
  end
end

-- Function to apply dot color (affects crosshair)
local function apply_dot_color(color_array)
  -- Store the dot color for use in re.on_pre_gui_draw_element
  laser_dot_color_array = {color_array[1], color_array[2], color_array[3], color_array[4]}
  laser_color_array = laser_dot_color_array -- Keep legacy compatibility
end

local function load_config()
  local status, data = pcall(json.load_file, config_file)
  if not status or not data then
      save_config()
      return true 
  end
  if type(data) ~= "table" then
      save_config()
      return true
  end
  max_scale = data.max_scale or max_scale
  min_scale = data.min_scale or min_scale
  dot_scale = data.dot_scale or dot_scale
  disable_shoulder_corrector = data.disable_shoulder_corrector or disable_shoulder_corrector
  dot_color_r = data.dot_color_r or dot_color_r
  dot_color_g = data.dot_color_g or dot_color_g
  dot_color_b = data.dot_color_b or dot_color_b
  crosshair_saturation = data.crosshair_saturation or crosshair_saturation
  static_center_dot = data.static_center_dot or static_center_dot
  simple_static_mode = data.simple_static_mode or simple_static_mode
  hide_dot_when_no_muzzle = data.hide_dot_when_no_muzzle or hide_dot_when_no_muzzle
  enable_laser_trail = data.enable_laser_trail or enable_laser_trail
  laser_trail_scale = data.laser_trail_scale or laser_trail_scale
  knife_dot_scale = data.knife_dot_scale or knife_dot_scale
  
  -- Load separate beam and dot colors
  if data.laser_beam_color_array then
    laser_beam_color_array = data.laser_beam_color_array
  end
  if data.laser_dot_color_array then
    laser_dot_color_array = data.laser_dot_color_array
  end
  if data.knife_dot_color_array then
    knife_dot_color_array = data.knife_dot_color_array
  end
  if data.static_reticle_color_array then
    static_reticle_color_array = data.static_reticle_color_array
  end
  -- Legacy compatibility - if old laser_color_array exists but new ones don't
  if data.laser_color_array and not data.laser_beam_color_array and not data.laser_dot_color_array then
    laser_beam_color_array = {data.laser_color_array[1], data.laser_color_array[2], data.laser_color_array[3], data.laser_color_array[4]}
    laser_dot_color_array = {data.laser_color_array[1], data.laser_color_array[2], data.laser_color_array[3], data.laser_color_array[4]}
  end
  laser_color_array = laser_dot_color_array -- Keep legacy compatibility
  
  if data.laser_origin_offsets then
    laser_origin_offsets = data.laser_origin_offsets
  end
  if data.laser_mat_params then
    _G.laser_mat_params = data.laser_mat_params
  end
  if data.weapon_laser_enabled then
    weapon_laser_enabled = data.weapon_laser_enabled
  end
  
  -- Update global flag for other mods to know Classic RE4 Style bullet spawn is active
  _G.classic_re4_laser_bullet_spawn_active = (not static_center_dot)
  
  apply_laser_trail_settings()
  return true
end

local function write_valuetype(parent_obj, offset, value)                       
  for i = 0, value.type:get_valuetype_size() - 1 do
    parent_obj:write_byte(offset + i, value:read_byte(i))
  end
end

local cast_ray_async = CastRays.cast_ray_async

-- Laser trail management functions

local function create_laser_trail()
  if not scene or not enable_laser_trail or laser_trail_gameobject then
    return
  end

  -- Create the laser trail game object
  local create_method = sdk.find_type_definition("via.GameObject"):get_method("create(System.String)")
  if not create_method then
    return
  end

  laser_trail_gameobject = create_method:call(nil, "LaserTrail")
  if not laser_trail_gameobject then
    return
  end

  -- Create mesh component and load resources
  pcall(function()
    local mesh_component = laser_trail_gameobject:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    if mesh_component then
      mesh_component:set_DrawShadowCast(false)
      -- Load the specific laser mesh you requested
      if not laser_mesh_resource then
        laser_mesh_resource = sdk.create_resource("via.render.MeshResource", "_chainsaw/character/wp/wp40/wp4000/21/wp4000_22.mesh")
        if laser_mesh_resource then
          laser_mesh_resource:add_ref()
        end
      end
      
      if laser_mesh_resource then
        local mesh_resource_holder = sdk.create_instance("via.render.MeshResourceHolder", true)
        if mesh_resource_holder then
          mesh_resource_holder:add_ref()
          mesh_resource_holder:write_qword(0x10, laser_mesh_resource:get_address())
          mesh_component:setMesh(mesh_resource_holder)
        end
      end
      
      -- Load and apply the specific material you requested
      if not laser_material_resource then
        laser_material_resource = sdk.create_resource("via.render.MeshMaterialResource", "LaserColors/classicRE4LaserMaterial.mdf2")  -- Laser material resource
        if laser_material_resource then
          laser_material_resource:add_ref()
        end
      end
      
      if laser_material_resource then
        -- Create material holder and apply material using set_Material()
        local material_holder = sdk.create_instance("via.render.MeshMaterialResourceHolder", true)
        if material_holder then
          material_holder:add_ref()
          material_holder:write_qword(0x10, laser_material_resource:get_address())
          mesh_component:set_Material(material_holder)
        end
      end
    end
  end)
  -- Apply loaded material params immediately after mesh is created
  apply_laser_trail_settings()
  
  -- Apply initial beam color from laser_beam_color_array to ensure beam starts with correct color
  apply_beam_color(laser_beam_color_array)
end

local function destroy_laser_trail()
if laser_trail_gameobject then
  pcall(function()
    laser_trail_gameobject:call("destroy", laser_trail_gameobject)
  end)
  laser_trail_gameobject = nil
end
end


local function update_crosshair_world_pos(start_pos, end_pos)
if crosshair_attack_ray_result == nil or crosshair_bullet_ray_result == nil then
  crosshair_attack_ray_result = cast_ray_async(crosshair_attack_ray_result, start_pos, end_pos, 5)
  crosshair_bullet_ray_result = cast_ray_async(crosshair_bullet_ray_result, start_pos, end_pos, 10)
  crosshair_attack_ray_result:add_ref()
  crosshair_bullet_ray_result:add_ref()
end

local finished = crosshair_attack_ray_result:call("get_Finished") == true and crosshair_bullet_ray_result:call("get_Finished") == true
local attack_hit = finished and crosshair_attack_ray_result:call("get_NumContactPoints") > 0
local any_hit = finished and (attack_hit or crosshair_bullet_ray_result:call("get_NumContactPoints") > 0)
local both_hit = finished and crosshair_attack_ray_result:call("get_NumContactPoints") > 0 and crosshair_bullet_ray_result:call("get_NumContactPoints") > 0

if finished and any_hit then
  local best_result = nil

  if both_hit then
    local attack_distance = crosshair_attack_ray_result:call("getContactPoint(System.UInt32)", 0):get_field("Distance")
    local bullet_distance = crosshair_bullet_ray_result:call("getContactPoint(System.UInt32)", 0):get_field("Distance")
    if attack_distance < bullet_distance then
      best_result = crosshair_attack_ray_result
    else
      best_result = crosshair_bullet_ray_result
    end
  else
    best_result = attack_hit and crosshair_attack_ray_result or crosshair_bullet_ray_result
  end

  local contact_point = best_result:call("getContactPoint(System.UInt32)", 0)
  if contact_point then
    local contact_distance = contact_point:get_field("Distance")
    
    -- Sky distance threshold: if hit is beyond 100m, clamp to 100m
    local sky_distance_threshold = 100.0
    if contact_distance and contact_distance > sky_distance_threshold then
      contact_distance = sky_distance_threshold
    end
    
    re4.crosshair_dir = re4.crosshair_dir:normalized()
    re4.crosshair_pos = start_pos + (re4.crosshair_dir * re4.crosshair_distance * 1)
    re4.crosshair_dir = (end_pos - start_pos):normalized()
    re4.crosshair_normal = contact_point:get_field("Normal")
    re4.crosshair_distance = contact_distance
  end
elseif finished and not any_hit then
  -- Raycast finished but no hit (sky/empty space) - use default distance
  local sky_distance = 100.0
  re4.crosshair_dir = (end_pos - start_pos):normalized()
  re4.crosshair_distance = sky_distance
  re4.crosshair_pos = start_pos + (re4.crosshair_dir * sky_distance)
else
  -- Raycast still pending - keep updating position along current direction
  re4.crosshair_dir = (end_pos - start_pos):normalized()
  if re4.crosshair_distance then
    re4.crosshair_pos = start_pos + (re4.crosshair_dir * re4.crosshair_distance)
  else
    re4.crosshair_pos = start_pos + (re4.crosshair_dir * 10.0)
    re4.crosshair_distance = 10.0
  end
end

-- Always restart the raycast when finished (whether hit or not)
if finished then
  cast_ray_async(crosshair_attack_ray_result, start_pos, end_pos, 5, CollisionFilter.DamageCheckOtherThanPlayer)
  cast_ray_async(crosshair_bullet_ray_result, start_pos, end_pos, 10)
end

global_intersection_point = re4.crosshair_pos
end

local function update_muzzle_and_laser_data()
if not scene then
  return
end

-- Use cached objects to avoid expensive findGameObject calls
local current_time = os.clock()

-- Skip processing when shooting is not enabled (cutscenes, menus, etc.)
if not _G.is_aim then
  -- Clear caches to avoid stale object references
  cached_pl_head = nil
  cached_gun_obj = nil
  cached_weapon_id = nil
  cached_laser_sight_obj = nil
  return
end

if not cached_pl_head or (current_time - cache_refresh_time) > cache_refresh_interval then
  cached_pl_head = scene:call("findGameObject(System.String)", "ch0a0z0_head")
  if not cached_pl_head then
    for _, character_id in ipairs(character_ids) do
      cached_pl_head = scene:call("findGameObject(System.String)", character_id)
      if cached_pl_head then
        break
      end
    end
  end
  cache_refresh_time = current_time
end
if not cached_pl_head then
  return
end

local player_equip = nil
local equip_weapon = nil
pcall(function()
  player_equip = cached_pl_head:call("getComponent(System.Type)", sdk.typeof("chainsaw.PlayerEquipment"))
  if player_equip then
    equip_weapon = player_equip:call("get_EquipWeaponID()")
  end
end)
if not player_equip or not equip_weapon then
  return
end

-- Store weapon ID globally for laser trail offset calculations
local prev_weapon_id = current_weapon_id
current_weapon_id = equip_weapon

-- Only check hooks if switching away from weapon 4600 (when hooks might be active)
if prev_weapon_id == 4600 and current_weapon_id ~= 4600 and is_hooks_active then
  manage_hooks()
end

-- Use cached weapon object or refresh if weapon changed
if not cached_gun_obj or cached_weapon_id ~= equip_weapon or (current_time - cache_refresh_time) > cache_refresh_interval then
  pcall(function()
    cached_gun_obj = scene:call("findGameObject(System.String)", "wp" .. tostring(equip_weapon))
    if not cached_gun_obj then
      cached_gun_obj = scene:call("findGameObject(System.String)", "wp" .. tostring(equip_weapon) .. "_AO")
    end
    if not cached_gun_obj then
      cached_gun_obj = scene:call("findGameObject(System.String)", "wp" .. tostring(equip_weapon) .. "_MC")
    end
  end)
  cached_weapon_id = equip_weapon
  cache_refresh_time = current_time
end
if not cached_gun_obj then
  return
end

local bt_gun = nil
local bt_arms = nil
local muzzle_joint = nil
pcall(function()
  bt_gun = cached_gun_obj:call("getComponent(System.Type)", sdk.typeof("chainsaw.Gun"))
  bt_arms = cached_gun_obj:call("getComponent(System.Type)", sdk.typeof("chainsaw.Arms"))
  if bt_arms then
    muzzle_joint = bt_arms:call("getMuzzleJoint")
  end
  if not muzzle_joint then
    local gun_transforms = cached_gun_obj:get_Transform()
    if gun_transforms then
      muzzle_joint = gun_transforms:call("getJointByName", "vfx_muzzle")
    end
  end
end)

if muzzle_joint then
  -- Has muzzle - normal weapon
  is_non_muzzle_weapon = false
  current_muzzle_joint = muzzle_joint  -- Store globally for laser trail offsets
  pcall(function()
    local muzzle_position = joint_get_position(muzzle_joint)
    re4.last_muzzle_pos = muzzle_position
    re4.last_muzzle_forward = muzzle_joint:call("get_AxisZ")
    re4.last_shoot_dir = re4.last_muzzle_forward
    local muzzle_offset = 0.1
    re4.last_shoot_pos = re4.last_muzzle_pos + (re4.last_muzzle_forward * muzzle_offset)
    re4.last_muzzle_joint = muzzle_joint -- Store the joint for local offset use
  end)
else
  -- No muzzle - non-muzzle weapon (knife, etc.)
  is_non_muzzle_weapon = true
  current_muzzle_joint = nil  -- No joint for non-muzzle weapons
  pcall(function()
    local camera_mat = sdk.get_primary_camera():get_WorldMatrix()
    re4.last_muzzle_pos = camera_mat[3]
    re4.last_muzzle_pos.w = 1.0
    local muzzle_rot = camera_mat:to_quat()
    re4.last_muzzle_forward = (muzzle_rot * Vector3f.new(0, 0, -1)):normalized()
    re4.last_shoot_dir = re4.last_muzzle_forward
    local camera_offset = 2
    re4.last_shoot_pos = re4.last_muzzle_pos + (re4.last_muzzle_forward )
    re4.last_muzzle_joint = nil -- No joint for non-muzzle weapons
  end)
end
end

local function update_static_dot_interpolation()
  -- Update static dot interpolation once per frame for perfect sync between dot and trail
  if not static_center_dot or not _G.is_aim then
    return
  end
  
  -- Get current camera position and direction for raycast
  local camera = sdk.get_primary_camera()
  if not camera then return end
  
  local camera_gameobject = camera:call("get_GameObject")
  if not camera_gameobject then return end
  
  local camera_transform = camera_gameobject:get_Transform()
  if not camera_transform then return end
  
  local camera_joints = camera_transform:call("get_Joints")
  if not camera_joints or not camera_joints[0] then return end
  
  local camera_joint = camera_joints[0]
  local camera_pos = joint_get_position(camera_joint)
  cached_static_camera_pos = camera_pos -- Cache camera position for GUI scaling
  local camera_rot = joint_get_rotation(camera_joint)
  local camera_forward = camera_rot:to_mat4()[2] * -1.0  -- Forward direction

  -- Add camera offset for raycast origin (reduce to 0 in first person mode)
  local fp_active = rawget(_G, "standalone_first_person_active") == true
  local raycast_offset = fp_active and 0.0 or CAMERA_RAYCAST_OFFSET
  local offset_camera_pos = camera_pos + (camera_forward * raycast_offset)
  
  -- Calculate end point like working crosshair
  local cam_end = offset_camera_pos + (camera_forward * 8192.0)
  
  -- Create separate async raycast for static dot to get natural delay
  if static_attack_ray_result == nil or static_bullet_ray_result == nil then
    static_attack_ray_result = cast_ray_async(static_attack_ray_result, offset_camera_pos, cam_end, 5)
    static_bullet_ray_result = cast_ray_async(static_bullet_ray_result, offset_camera_pos, cam_end, 10)
    if static_attack_ray_result then static_attack_ray_result:add_ref() end
    if static_bullet_ray_result then static_bullet_ray_result:add_ref() end
  end
  
  local static_finished = static_attack_ray_result and static_bullet_ray_result and 
                         static_attack_ray_result:call("get_Finished") == true and 
                         static_bullet_ray_result:call("get_Finished") == true
  
  if static_finished then
    local static_attack_hit = static_attack_ray_result:call("get_NumContactPoints") > 0
    local static_any_hit = static_attack_hit or static_bullet_ray_result:call("get_NumContactPoints") > 0
    
    if static_any_hit then
      local static_best_result = static_attack_hit and static_attack_ray_result or static_bullet_ray_result
      local static_contact_point = static_best_result:call("getContactPoint(System.UInt32)", 0)
      
      if static_contact_point then
        -- Use contact point position directly for natural async delay
        local contact_position = static_contact_point:get_field("Position")
        local contact_distance = static_contact_point:get_field("Distance")
        
        -- If contact distance is very far (sky/skybox), use default distance instead
        local sky_distance_threshold = 100.0  -- Treat anything beyond 100m as "sky"
        local actual_distance = contact_distance or (contact_position - camera_pos):length()
        
        if actual_distance > sky_distance_threshold then
          -- Aiming at sky or very far away - use default distance
          static_target_intersection_point = camera_pos + (camera_forward * sky_distance_threshold)
        else
          -- Apply surface offset from contact point (using unified constant)
          local new_target_intersection = contact_position - (camera_forward * SURFACE_OFFSET)
          
          -- Hard limit: ensure dot never goes closer than 1.6 meters from camera
          local min_distance_from_camera = 1.5
          local camera_to_dot = new_target_intersection - camera_pos
          local distance_from_camera = camera_to_dot:length()
          if distance_from_camera < min_distance_from_camera then
            static_target_intersection_point = camera_pos + (camera_forward * min_distance_from_camera)
          else
            static_target_intersection_point = new_target_intersection
          end
        end
      else
        -- Contact point was nil - use default distance
        static_target_intersection_point = camera_pos + (camera_forward * 100.0)
      end
    else
      -- No contact point found (aiming at sky/empty space) - use default distance
      local default_distance = 100.0  -- Default distance when no collision
      local fallback_position = camera_pos + (camera_forward * default_distance)
      static_target_intersection_point = fallback_position
    end
    
    -- Restart the async raycast for continuous updates
    cast_ray_async(static_attack_ray_result, offset_camera_pos, cam_end, 5, CollisionFilter.DamageCheckOtherThanPlayer)
    cast_ray_async(static_bullet_ray_result, offset_camera_pos, cam_end, 10)
  end
  
  -- Set position instantly (no interpolation)
  if static_target_intersection_point then
    -- Always set to target position immediately
    cached_static_intersection_point = static_target_intersection_point
  end
end

local function update_laser_trail()
-- Update laser trail (now separate function again)  
-- Only show the laser trail if aiming, enabled, and has valid muzzle
-- Hide trail when simple static mode is enabled AND laser is toggled off (showing backup dot)
-- Hide trail when static mode is enabled and there's no new muzzle data
local has_stale_muzzle_data = static_center_dot and (os.clock() - last_crosshair_time) > 0.25

-- Check if laser is enabled for current weapon (default to enabled if not set)
local weapon_id_str = tostring(current_weapon_id)
local laser_enabled_for_weapon = weapon_laser_enabled[weapon_id_str] ~= false  -- Default true if nil

if not enable_laser_trail or not re4.last_muzzle_pos or is_non_muzzle_weapon or not _G.is_aim or (simple_static_mode and not show_laser_dot) or has_stale_muzzle_data or not laser_enabled_for_weapon then
  if laser_trail_gameobject then
    laser_trail_gameobject:set_DrawSelf(false)
  end
  return
end

-- Always create trail if missing when aiming resumes
if not laser_trail_gameobject then
  create_laser_trail()
end

if not laser_trail_gameobject then
  return
end

-- Check if the game object is still valid before accessing it
if not laser_trail_gameobject:get_Valid() then
  laser_trail_gameobject = nil
  return
end

-- Always show the trail when aiming and all conditions are met
laser_trail_gameobject:set_DrawSelf(true)

local laser_transform = laser_trail_gameobject:get_Transform()
if not laser_transform then
  return
end

-- Use the same intersection and direction as the dot (shared muzzle data)
pcall(function()
  local equipped_weapon_id = tostring(current_weapon_id)
  local offset_tbl = (equipped_weapon_id and laser_origin_offsets and laser_origin_offsets[equipped_weapon_id]) or {x=laser_origin_offset_x, y=laser_origin_offset_y, z=laser_origin_offset_z}
  local offset_x = offset_tbl.x or 0.0
  local offset_y = offset_tbl.y or 0.0
  local offset_z = offset_tbl.z or 0.0
  local adjusted_muzzle_pos = re4.last_muzzle_pos

  if current_muzzle_joint then
    local axis_x = current_muzzle_joint:call("get_AxisX")
    local axis_y = current_muzzle_joint:call("get_AxisY")
    local axis_z = current_muzzle_joint:call("get_AxisZ")
    adjusted_muzzle_pos = adjusted_muzzle_pos
      + (axis_x * offset_x)
      + (axis_y * offset_y)
      + (axis_z * offset_z)
  else
    adjusted_muzzle_pos = Vector3f.new(
      re4.last_muzzle_pos.x + offset_x,
      re4.last_muzzle_pos.y + offset_y,
      re4.last_muzzle_pos.z + offset_z
    )
  end

  -- Calculate endpoint: use same async method as static dot for consistent behavior
  local start_point = adjusted_muzzle_pos
  local end_point

  if static_center_dot and _G.is_aim and _G.is_reticle_displayed and (_G.is_active ~= false) then
    -- For static mode, use the same cached intersection from the static dot's async raycast
    if cached_static_intersection_point then
      -- Use the same intersection point that the static dot is using
      end_point = cached_static_intersection_point
    else
      -- Fallback to crosshair position if cached intersection not available yet
      end_point = re4.crosshair_pos
    end
  else
    -- Use crosshair position for dynamic mode with unified trail offset
    end_point = re4.crosshair_pos - (re4.crosshair_dir * TRAIL_OFFSET)
  end

  -- Apply weapon-specific endpoint offset for laser trail only (does not affect dot)
  if current_weapon_id == 6102 then
    -- Distance-based offset for weapon 6102 trail endpoint
    local distance_to_target = (end_point - start_point):length()
    local offset_y
    if distance_to_target > 10.0 then
      offset_y = -0.05  -- Over 10m
    elseif distance_to_target > 5.0 then
      offset_y = -0.0175  -- 5-10m
    else
      offset_y = -0.015  -- Under 5m
    end
    local trail_offset = Vector3f.new(0, offset_y, 0)
    end_point = end_point + trail_offset
  end

  -- Ensure start point doesn't go behind the muzzle
  local muzzle_to_start = start_point - adjusted_muzzle_pos
  local forward_projection = muzzle_to_start:dot(re4.crosshair_dir)
  if forward_projection < 0 then
    start_point = adjusted_muzzle_pos
  end

  local distance = (end_point - start_point):length()
  
  laser_transform:set_Position(start_point)
  local beam_direction = (end_point - start_point):normalized()
  local default_forward = Vector3f.new(0, 0, 1)
  local rotation_quat = default_forward:to_quat():slerp(beam_direction:to_quat(), 1.0)
  laser_transform:set_Rotation(rotation_quat)
  local beam_scale = laser_trail_scale
  laser_transform:set_LocalScale(Vector3f.new(beam_scale, beam_scale, distance/7.7)) --maybe change mesh size instead of dividing
end)
end

re.on_pre_application_entry("LockScene", function()
-- Determine aiming state (is_aim) using CharacterContext, similar to reference
pcall(function()
  local character_manager = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
  local CharacterContext = nil
  if character_manager then
    CharacterContext = character_manager:call("getPlayerContextRef")
  end
  if CharacterContext then
    _G.is_aim = CharacterContext:call("get_IsShootEnable")
    _G.is_reticle_displayed = CharacterContext:call("get_IsReticleDisp")
    --_G.is_shoot_inhibited = CharacterContext:call("get_IsShootInhibit")
    
    -- Check for hold variation state
    pcall(function()
      local prev_hold_variation = is_hold_variation
      is_hold_variation = CharacterContext:call("get_IsHoldVariation") or false
      -- Only check hooks if hold variation state changed AND we're using weapon 4600
      if prev_hold_variation ~= is_hold_variation and current_weapon_id == 4600 then
        manage_hooks()
      end
    end)
  else
    _G.is_aim = false
    _G.is_reticle_displayed = false
    --_G.is_shoot_inhibited = false
    local prev_hold_variation = is_hold_variation
    is_hold_variation = false
    -- Only check hooks if hold variation state changed AND we had weapon 4600
    if prev_hold_variation ~= is_hold_variation and current_weapon_id == 4600 then
      manage_hooks()
    end
  end
end)

local force_classic = (_G.force_classic_re4_style == true)
local fp_active = (rawget(_G, "standalone_first_person_active") == true)

-- When using first person mode with preset A or B active, also force Classic RE4 Style
local preset_a_active = (rawget(_G, "custom_aim_preset_a_active") == true)
local preset_b_active = (rawget(_G, "custom_aim_preset_b_active") == true)
local fp_preset_ab_force_classic = fp_active and (preset_a_active or preset_b_active)

local force_disable_shoulder = force_classic or fp_active

if force_disable_shoulder then
  pending_shoulder_restore = nil
  shoulder_restore_frames = 0
  if not disable_shoulder_corrector then
    disable_shoulder_corrector = true
    hasRunInitially = false
  end
else
  -- When iron sight or first person mode is toggled off, always uncheck Disable Shoulder Corrector
  if force_disable_shoulder_prev then
    pending_shoulder_restore = false  -- Always restore to unchecked
    shoulder_restore_frames = SHOULDER_RESTORE_DELAY_FRAMES
  end
end

-- Handle force_classic separately for static_center_dot restoration
-- This allows restoring RE4 Remake Style when iron sight is toggled off, even if FP mode is still active
-- Also force Classic RE4 Style when first person mode + preset A or B is active
local should_force_classic = force_classic or fp_preset_ab_force_classic
if should_force_classic then
  if not force_classic_re4_prev then
    -- Just entered force_classic - store current state
    stored_static_center_dot = static_center_dot
  end
  if static_center_dot then
    static_center_dot = false
    _G.classic_re4_laser_bullet_spawn_active = true  -- Classic RE4 Style handles bullet spawn
    hasRunInitially = false
    manage_hooks(true)
  end
else
  -- force_classic is false - check if we need to restore
  if force_classic_re4_prev then
    -- Just exited force_classic - restore previous state
    if stored_static_center_dot ~= nil and static_center_dot ~= stored_static_center_dot then
      static_center_dot = stored_static_center_dot
      _G.classic_re4_laser_bullet_spawn_active = (not static_center_dot)  -- Update based on restored state
      hasRunInitially = false
      manage_hooks(true)
    end
    stored_static_center_dot = nil
  end
end

if not force_disable_shoulder and pending_shoulder_restore ~= nil then
  if shoulder_restore_frames > 0 then
    shoulder_restore_frames = shoulder_restore_frames - 1
  else
    if disable_shoulder_corrector ~= pending_shoulder_restore then
      disable_shoulder_corrector = pending_shoulder_restore
      hasRunInitially = false
    end
    pending_shoulder_restore = nil
  end
end

force_disable_shoulder_prev = force_disable_shoulder
force_classic_re4_prev = should_force_classic

if (os.clock() - last_crosshair_time) < 1.0 then
  update_muzzle_and_laser_data()
  if re4.last_shoot_pos then
    local pos = re4.last_shoot_pos + (re4.last_shoot_dir * 0.05)
    update_crosshair_world_pos(pos, pos + (re4.last_shoot_dir * 1000.0))
    
  end
  update_laser_trail() -- Keep trail and muzzle data in sync
else
  update_muzzle_and_laser_data()

  -- Even when crosshair data is stale, still update muzzle position and laser trail
  pcall(function()
    if not scene then
      return
    end
  end)
end



-- Check for laser/dot toggle hotkey
local KM_controls = ((not Laser_settings.use_modifier or hk.check_hotkey("Laser Modifier", false)) and hk.check_hotkey("Laser Toggle")) or (hk.check_hotkey("Laser Modifier", true) and hk.check_hotkey("Laser Toggle"))
local PAD_controls = ((not Laser_settings.use_pad_modifier or hk.check_hotkey("Pad Laser Modifier", false)) and hk.check_hotkey("Pad Laser Toggle")) or (hk.check_hotkey("Pad Laser Modifier", true) and hk.check_hotkey("Pad Laser Toggle"))

if KM_controls or PAD_controls then
    enable_laser_trail = not enable_laser_trail
    show_laser_dot = not show_laser_dot
    if laser_trail_gameobject then
      laser_trail_gameobject:set_DrawSelf(enable_laser_trail)
    end
    save_config()
end

end)

local reticle_names = {
"Gui_ui2040", "Gui_ui2042"
}
for i, v in ipairs(reticle_names) do
reticle_names[v] = true
end

local function write_vec4(obj, vec, offset)
obj:write_float(offset, vec.x)
obj:write_float(offset + 4, vec.y)
obj:write_float(offset + 8, vec.z)
obj:write_float(offset + 12, vec.w)
end

-- Update the re.on_pre_gui_draw_element function to respect show_laser_dot
re.on_pre_gui_draw_element(function(element, context)
  local game_object = element:call("get_GameObject")
  local name = game_object and game_object:call("get_Name")
  
  -- Check if laser is enabled for current weapon (default to enabled if not set)
  local weapon_id_str = tostring(current_weapon_id)
  local laser_enabled_for_weapon = weapon_laser_enabled[weapon_id_str] ~= false
  
  -- Handle reticle visibility based on simple static mode functionality
  -- Note: When laser is disabled for a weapon in settings, we still show the dot (only hide trail)
  if not show_laser_dot and enable_laser_trail and laser_enabled_for_weapon and not (simple_static_mode and not show_laser_dot) then
    if reticle_names[name] then
      return false -- Hide reticle when laser is off via hotkey, UNLESS simple static mode is enabled (then show white dot)
    end
  end
  
  -- Hide reticle when no muzzle is found (if option is enabled)
  if hide_dot_when_no_muzzle and (not current_muzzle_joint or is_non_muzzle_weapon) then
    if reticle_names[name] then
      return false -- Hide reticle when no muzzle is detected
    end
  end
local distance = re4.crosshair_distance or 1
  local base_multiplier = 0.075
local scale_distance = distance * base_multiplier
local game_object = element:call("get_GameObject")
if game_object == nil then return true end

local name = game_object:call("get_Name")

if reticle_names[name] then
  local reticle_behavior = game_object:call("getComponent(System.Type)", sdk.typeof("chainsaw.ReticleGuiBehavior"))
  if reticle_behavior then
    local color_panel = reticle_behavior:get_field("ColorPanel")
    if color_panel then
      color_panel:call("set_Saturation", crosshair_saturation)
      
      -- Set the scale using the GUI value - use different scales for knife vs regular weapons
      local current_scale = is_non_muzzle_weapon and knife_dot_scale or dot_scale
      local scale_vec = Vector3f.new(current_scale, current_scale, current_scale)
      color_panel:call("set_Scale", scale_vec)
    end
  end
  
  local type_panel = reticle_behavior:get_field("TypePanel")
  if type_panel then
    -- Use different scales for knife vs regular weapons
    local current_scale = is_non_muzzle_weapon and knife_dot_scale or dot_scale
    local scale_vec = Vector3f.new(current_scale, current_scale, current_scale)
    type_panel:call("set_Scale", scale_vec)
    
    local current_color = type_panel:call("get_ColorScale")
    if current_color then
      -- Only apply color and alpha changes for muzzle weapons (guns)
      if not is_non_muzzle_weapon then
        -- Use laser_color_array directly (already in 0-1 range)
        -- Handle dot visibility based on hotkey state and weapon laser settings
        if not laser_enabled_for_weapon then
          -- Weapon has laser disabled in settings: show static colored dot with separate color
          current_color.x = static_reticle_color_array[1] or 1.0
          current_color.y = static_reticle_color_array[2] or 1.0
          current_color.z = static_reticle_color_array[3] or 1.0
          current_color.w = 1.0  -- Fully visible
        elseif not show_laser_dot then
          -- Laser is toggled OFF via hotkey
          if simple_static_mode then
            -- Simple static mode enabled: show custom colored backup dot
            current_color.x = laser_color_array[1] or 1.0
            current_color.y = laser_color_array[2] or 0.0
            current_color.z = laser_color_array[3] or 0.0
            current_color.w = 1.0  -- Fully visible
          else
            -- Normal behavior when laser is off: hide dot
            current_color.x = 0
            current_color.y = 0
            current_color.z = 0
            current_color.w = 0.0  -- Fully hidden when toggled off
          end
        else
          -- Laser is toggled ON via hotkey: show normal colored dot regardless of simple static mode
          current_color.x = laser_color_array[1] or 1.0
          current_color.y = laser_color_array[2] or 0.0
          current_color.z = laser_color_array[3] or 0.0
          current_color.w = 1.0   -- Fully visible
        end
        type_panel:call("set_ColorScale", current_color)
      else
        -- Non-muzzle weapons: always visible when hide_dot_when_no_muzzle is false
        if not hide_dot_when_no_muzzle then
          current_color.x = knife_dot_color_array[1] or 1.0
          current_color.y = knife_dot_color_array[2] or 1.0
          current_color.z = knife_dot_color_array[3] or 1.0
          current_color.w = 1.0   -- Always fully visible for non-muzzle weapons when hide option is off
          type_panel:call("set_ColorScale", current_color)
        end
      end
    end
  end

  -- Detect _IsActive state for beam/trail behavior
  local is_active = true  -- Default to active
  pcall(function()
    is_active = reticle_behavior:call('get_IsActive')
    if is_active == nil then is_active = true end
  end)
  _G.is_active = is_active

  last_crosshair_time = os.clock()
  
  -- Get transform and GUI component once for all positioning modes
  local transform = game_object:call("get_Transform")
  if not transform then
    return true
  end
  
  local gui_comp = re4.get_component(game_object, "via.gui.GUI")
  if not gui_comp then
    return true
  end
  
  local view = gui_comp:call("get_View")
  if not view then
    return true
  end
  
  -- Handle positioning: prioritize simple static mode when laser is off, then static center vs dynamic
  -- Also treat weapons with laser disabled in settings like simple_static_mode (static dot only)
  if (simple_static_mode and not show_laser_dot) or not laser_enabled_for_weapon then
    -- Simple static mode with laser OFF or weapon laser disabled: use basic game positioning for static dot
    view:call("set_ViewType", 0) -- Use game's default view type
    view:call("set_Overlay", true) -- Use game's default overlay
    view:call("set_Detonemap", true)
    view:call("set_DepthTest", true)
  elseif is_non_muzzle_weapon and not hide_dot_when_no_muzzle then
    -- No muzzle weapon with hide option OFF: use basic game positioning for default dot appearance
    view:call("set_ViewType", 0) -- Use game's default view type  
    view:call("set_Overlay", true) -- Use game's default overlay
    view:call("set_Detonemap", true)
    view:call("set_DepthTest", true)
  elseif static_center_dot and _G.is_aim and (_G.is_active) then
    -- Static center positioning - use pre-computed cached intersection from update_static_dot_interpolation()
    if cached_static_intersection_point and re4.crosshair_dir then
      view:call("set_ViewType", 1) -- world space
      if is_non_muzzle_weapon then
        view:call("set_Overlay", true)
      else
        view:call("set_Overlay", false)
      end
      view:call("set_Detonemap", true)
      view:call("set_DepthTest", false)
        
        -- Use proven distance-based scaling from working crosshair system
        local new_mat = re4.crosshair_dir:to_quat():to_mat4()

        -- Clamp the distance for scaling to avoid flicker/oversize at close range

        local base_multiplier = 0.075
        local min_distance_from_camera = 1.5 -- must match static dot logic
        local actual_distance = re4.crosshair_distance
        if static_center_dot and cached_static_intersection_point and cached_static_camera_pos then
          -- Use the distance from cached camera to static dot, clamped to min
          local camera_to_dot = cached_static_intersection_point - cached_static_camera_pos
          actual_distance = math.max(camera_to_dot:length(), min_distance_from_camera)
        end
        local distance = actual_distance * base_multiplier

        -- Use same clamping as dynamic dot
        if distance < min_scale then
          distance = min_scale
        elseif distance > max_scale then  
          distance = max_scale
        end

        local crosshair_pos = Vector4f.new(cached_static_intersection_point.x, cached_static_intersection_point.y, cached_static_intersection_point.z, 1.0)

        write_vec4(transform, new_mat[0] * distance, 0x80)
        write_vec4(transform, new_mat[1] * distance, 0x90)
        write_vec4(transform, new_mat[2] * distance, 0xA0)
        write_vec4(transform, crosshair_pos, 0xB0)
    end
  else
    -- Dynamic positioning (original behavior, when not aiming in static mode and not using simple static backup)
    if global_intersection_point then
      -- Normal dynamic positioning with custom calculations
      view:call("set_ViewType", 1) -- world space
      if is_non_muzzle_weapon then
        view:call("set_Overlay", true)
      else
        view:call("set_Overlay", false)
      end
      view:call("set_Detonemap", true)
      view:call("set_DepthTest", true)
        
      local new_mat = re4.crosshair_dir:to_quat():to_mat4()

      if scale_distance < min_scale then
        scale_distance = min_scale
      elseif scale_distance > max_scale then  
        scale_distance = max_scale
      end

      local offset = 0.1
      local adjusted_crosshair_pos = re4.crosshair_pos - (re4.crosshair_dir * offset)
      local crosshair_pos = Vector4f.new(adjusted_crosshair_pos.x, adjusted_crosshair_pos.y, adjusted_crosshair_pos.z, 1.0)

      write_vec4(transform, new_mat[0] * scale_distance, 0x80)
      write_vec4(transform, new_mat[1] * scale_distance, 0x90)
      write_vec4(transform, new_mat[2] * scale_distance, 0xA0)
      write_vec4(transform, crosshair_pos, 0xB0)
    end
  end
end
return true
end)

local function updateReticles()
  scene_manager = sdk.get_native_singleton("via.SceneManager")
  if not scene_manager then
      return
  end

  scene = sdk.call_native_func(scene_manager, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
  if not scene then
      return
  end

  if scene:call("findGameObject(System.String)", "WeaponCatalog") then
      weaponCatalog = scene:call("findGameObject(System.String)", "WeaponCatalog")
  end

  if scene:call("findGameObject(System.String)", "WeaponCatalog_AO") then
      weaponCatalog = scene:call("findGameObject(System.String)", "WeaponCatalog_AO")
  end

  if not scene:call("findGameObject(System.String)", "WeaponCatalog") and not scene:call("findGameObject(System.String)", "WeaponCatalog_AO") then
      weaponCatalog = scene:call("findGameObject(System.String)", "WeaponCatalog_MC")      
      weaponCatalog2 = scene:call("findGameObject(System.String)", "WeaponCatalog_MC_2nd") 
      weaponCatalogRegister2 = weaponCatalog2:call("getComponent(System.Type)", sdk.typeof("chainsaw.WeaponCatalogRegister"))
      WeaponEquipParamCatalogUserData2 = weaponCatalogRegister2:call("get_WeaponEquipParamCatalogUserData")
      weaponDataTables2 = WeaponEquipParamCatalogUserData2:get_field("_DataTable")
  end

  local weaponCatalogRegister = weaponCatalog:call("getComponent(System.Type)", sdk.typeof("chainsaw.WeaponCatalogRegister"))
  
  if not weaponCatalogRegister then
      return
  end

  if scene:call("findGameObject(System.String)", "WeaponCustomCatalog") then
      weaponCustomCatalog = scene:call("findGameObject(System.String)", "WeaponCustomCatalog")
  end

  if scene:call("findGameObject(System.String)", "WeaponCustomCatalog_AO") then
      weaponCustomCatalog = scene:call("findGameObject(System.String)", "WeaponCustomCatalog_AO")
  end

  if not scene:call("findGameObject(System.String)", "WeaponCustomCatalog") and not scene:call("findGameObject(System.String)", "WeaponCustomCatalog_AO") then
      weaponCustomCatalog = scene:call("findGameObject(System.String)", "WeaponCustomCatalog_MC")      
  end
  local weaponCustomCatalogRegister = weaponCustomCatalog:call("getComponent(System.Type)", sdk.typeof("chainsaw.WeaponCustomCatalogRegister"))

  if not weaponCustomCatalogRegister then
      return
  end

  local weaponDetailCustomUserdata = weaponCustomCatalogRegister:call("get_WeaponDetailCustomUserdata")
  local weaponDetailStages = weaponDetailCustomUserdata:get_field("_WeaponDetailStages")

  local weaponEquipParamCatalogUserData = weaponCatalogRegister:call("get_WeaponEquipParamCatalogUserData")
  local weaponDataTables = weaponEquipParamCatalogUserData:get_field("_DataTable")

  if weaponDetailStages then
    for i = 0, weaponDetailStages:call("get_Count") - 1 do
      local weaponData = weaponDetailStages:call("get_Item", i)
      local weaponID = weaponData:get_field("_WeaponID")

      local weaponDetailCustom = weaponData:get_field("_WeaponDetailCustom")
      if weaponDetailCustom then
        local attachmentCustoms = weaponDetailCustom:get_field("_AttachmentCustoms")
        if attachmentCustoms then
          for i = 0, attachmentCustoms:call("get_Count") - 1 do
            local itemData = attachmentCustoms:call("get_Item", i)
            local itemID = itemData:get_field("_ItemID")
            if itemID == 116008000 then
              local attachmentParams = itemData:get_field("_AttachmentParams")
              if attachmentParams then
                for i = 0, attachmentParams:call("get_Count") - 1 do
                  local attachmentData = attachmentParams:call("get_Item", i)
                  local attachmentID = attachmentData:get_field("_AttachmentParamName")
                  if attachmentID == 501 then
                    attachmentData:set_field("_ReticleGuiType", reticleValue)
                  end
                end
              end
            end
            if itemID == 116006400 or itemID == 116001600 or itemID == 116009600 then
              local attachmentParams = itemData:get_field("_AttachmentParams")
              if attachmentParams then
                for i = 0, attachmentParams:call("get_Count") - 1 do
                  local attachmentData = attachmentParams:call("get_Item", i)
                  local attachmentID = attachmentData:get_field("_AttachmentParamName")
                  local weaponHandshakeParamtable = attachmentData:get_field("_WeaponHandShakeParam")

                  if weaponHandshakeParamtable then
                    local curve = weaponHandshakeParamtable:get_field("Curve")
                    if curve then
                      curve:call("set_MaxValue", 0.05)
                    end
                  end

                  local reticleFitParamCustom = attachmentData:get_field("_ReticleFitParam")
                  if reticleFitParamCustom then
                    local pointRange = reticleFitParamCustom:get_field("_PointRange")
                    if pointRange then
                      pointRange.s = 100
                      pointRange.r = 100
                      write_valuetype(reticleFitParamCustom, 0x10, pointRange)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  -- Define weapon config table for ShoulderCorrectorParamTable settings (shared between both data tables)
  local weaponConfigs = {
    -- Handguns
    [4000] = {maxY=0.5, maxX=0.0, minY=7.0, minX=2.0},
    [4001] = {maxY=0.5, maxX=0.0, minY=7.0, minX=2.0},
    [4002] = {maxY=0.5, maxX=0.0, minY=7.0, minX=2.0},
    [4003] = {maxY=0.5, maxX=0.0, minY=7.0, minX=2.0},
    [4004] = {maxY=0.5, maxX=0.0, minY=7.0, minX=2.0},
    -- Ada
    [6001] = {maxY=0.5, maxX=0.0, minY=9.0, minX=1.0},
    [6102] = {maxY=1.0, maxX=0.0, minY=0.0, minX=2.0},
    [6103] = {maxY=0.5, maxX=0.0, minY=7.0, minX=1.0},
    [6106] = {maxY=0.0, maxX=0.0, minY=9.0, minX=0.0},
    [6111] = {maxY=1.0, maxX=0.0, minY=9.0, minX=0.0},
    [6112] = {maxY=0.5, maxX=0.0, minY=7.0, minX=1.0},
    [6113] = {maxY=4.0, maxX=0.0, minY=7.0, minX=1.0},
    -- Shotguns
    [4100] = {maxY=0.5, maxX=0.0, minY=7.0, minX=2.0},
    [4101] = {maxY=0.5, maxX=0.0, minY=7.0, minX=2.0},
    [4102] = {maxY=0.5, maxX=1.0, minY=7.0, minX=7.5},
    [6100] = {maxY=0.0, maxX=0.0, minY=9.0, minX=10.0},
    -- TMP
    [4200] = {maxY=0.5, maxX=0.0, minY=6.0, minX=3.5},
    [6104] = {maxY=0.5, maxX=0.0, minY=6.0, minX=3.5},
    -- Chicago Sweeper
    [4201] = {maxY=0.0, maxX=0.0, minY=6.0, minX=1.0},
    [6101] = {maxY=0.0, maxX=0.0, minY=6.0, minX=1.0},
    -- LE5
    [4202] = {maxY=0.3, maxX=0.0, minY=6.0, minX=1.0},
    -- Magnums
    [4500] = {maxY=0.5, maxX=0.0, minY=7.0, minX=2.0},
    [4501] = {maxY=0.5, maxX=0.0, minY=7.0, minX=2.0},
    [4502] = {maxY=1.0, maxX=0.0, minY=9.0, minX=2.0},
    -- Bolt Thrower
    [4600] = {maxY=0.0, maxX=0.0, minY=7.0, minX=1.0},
    -- Rockets
    [4900] = {maxY=0.0, maxX=0.0, minY=10.0, minX=0.0},
    [4901] = {maxY=0.0, maxX=0.0, minY=10.0, minX=0.0},
    [4902] = {maxY=0.0, maxX=0.0, minY=10.0, minX=0.0},
    -- Sentinel Nine
    [6000] = {maxY=0.5, maxX=0.0, minY=7.0, minX=1.0},
    -- wp6001
    [6001] = {maxY=0.5, maxX=0.0, minY=9.0, minX=1.0},
    -- XBow
    [6304] = {maxY=0.5, maxX=0.0, minY=7.0, minX=1.0},
    -- wp6300
    [6300] = {maxY=0.25, maxX=0.0, minY=7.0, minX=1.0},
  }

  -- Shared function for setting shoulder corrector parameters
  local function setShoulderCorrectorParams(ShoulderCorrectorParamTable, config)
    if not ShoulderCorrectorParamTable or not config then return end

    local correctorDistance = ShoulderCorrectorParamTable:get_field("_WeaponShoulderCorrectorEnableDistance")
    if correctorDistance then
      correctorDistance.s = minRange
      correctorDistance.r = maxRange
      write_valuetype(ShoulderCorrectorParamTable, 0x10, correctorDistance)
    end

    -- Check if shoulder corrector should be disabled
    -- Also force disable when FirstPersonMode is active
    local fp_active = rawget(_G, "standalone_first_person_active") == true
    local should_disable = disable_shoulder_corrector or fp_active
    
    if should_disable then
      -- Set all values to 0 to disable shoulder correction
      local correctorFields = {
        "_WeaponShoulderCorrectorMaxAngleY",
        "_WeaponShoulderCorrectorMaxAngleX", 
        "_WeaponShoulderCorrectorMinAngleY",
        "_WeaponShoulderCorrectorMinAngleX"
      }
      for _, field in ipairs(correctorFields) do
        if ShoulderCorrectorParamTable:get_field(field) then
          ShoulderCorrectorParamTable:set_field(field, 0.0)
        end
      end
    else
      -- Use the config values (default behavior)
      local correctorMappings = {
        {field = "_WeaponShoulderCorrectorMaxAngleY", value = config.maxY},
        {field = "_WeaponShoulderCorrectorMaxAngleX", value = config.maxX},
        {field = "_WeaponShoulderCorrectorMinAngleY", value = config.minY},
        {field = "_WeaponShoulderCorrectorMinAngleX", value = config.minX}
      }
      for _, mapping in ipairs(correctorMappings) do
        if ShoulderCorrectorParamTable:get_field(mapping.field) then
          ShoulderCorrectorParamTable:set_field(mapping.field, mapping.value)
        end
      end
    end

    -- Set delay rates
    local delayFields = {
      {field = "_WeaponShoulderCorrectorDelayRateFast", value = 0.05},
      {field = "_WeaponShoulderCorrectorDelayRateSlow", value = 0.05},
      {field = "_WeaponShoulderCorrectorDelayRateChangeDistance", value = 1.0}
    }
    for _, delay in ipairs(delayFields) do
      if ShoulderCorrectorParamTable:get_field(delay.field) then
        ShoulderCorrectorParamTable:set_field(delay.field, delay.value)
      end
    end
  end

  -- Shared function to process weapon data
  local function processWeaponData(weaponData)
    local weaponID = weaponData:get_field("_WeaponID")
    
    -- Set follow target based on static center dot setting
    weaponData:set_field("_GenerateFollowTarget", static_center_dot and 0 or 1)

    -- Handle handshake parameters
    local handshakeParamtable = weaponData:get_field("_HandShakeParam")
    if handshakeParamtable then
      local curve = handshakeParamtable:get_field("Curve")
      if curve then
        -- Use different handshake values for specific weapons
        local specialHandshakeWeapons = {4400, 4401, 4402, 6105, 6114}
        local useSpecialValue = false
        for _, id in ipairs(specialHandshakeWeapons) do
          if weaponID == id then
            useSpecialValue = true
            break
          end
        end
        
        if useSpecialValue then
          curve:call("set_MaxValue", 0.075)
        else
          curve:call("set_MaxValue", 0.05)
        end
      end
    end

    -- Apply shoulder corrector settings
    local config = weaponConfigs[weaponID]
    if config then
      local ShoulderCorrectorParamTable = weaponData:get_field("_ShoulderCorrectorParam")
      setShoulderCorrectorParams(ShoulderCorrectorParamTable, config)
    end

    -- Handle reticle fit parameters for specific weapons
    local reticleWeapons = {4400, 4401, 4402, 6105, 6114, 6304, 6102, 4501}
    for _, id in ipairs(reticleWeapons) do
      if weaponID == id then
        local reticleFitParamTable = weaponData:get_field("_ReticleFitParamTable")
        if reticleFitParamTable then
          reticleFitParamTable:set_field("_ReticleShape", reticleValue)
          local defaultParam = reticleFitParamTable:get_field("_DefaultParam")
          if defaultParam then
            local pointRange = defaultParam:get_field("_PointRange")
            if pointRange then
              pointRange.s = 100
              pointRange.r = 100
              write_valuetype(defaultParam, 0x10, pointRange)
            end
          end
        end
        break
      end
    end
  end

  -- Process both weapon data tables using the shared function
  local weaponTables = {weaponDataTables, weaponDataTables2}
  for _, weaponTable in ipairs(weaponTables) do
    if weaponTable then
      for i = 0, weaponTable:call("get_Count") - 1 do
        local weaponData = weaponTable:call("get_Item", i)
        processWeaponData(weaponData)
      end
    end
  end
end

local function resetValues()        
  scene_manager = nil
  scene = nil
  hasRunInitially = false
  destroy_laser_trail()  -- Clean up laser trail when resetting
end

re.on_pre_application_entry("LockScene", function()
  if re4.player == nil then       
      resetValues()
      return
  end
  if re4.body == nil then        
      resetValues()
      return
  end

  local camera = sdk.get_primary_camera()    
  if not camera then
      resetValues()
      return
  end

  if not hasRunInitially then    
      updateReticles()
      hasRunInitially = true     
  end
  
  -- Always update muzzle and laser every frame  
    update_muzzle_and_laser_data()

  if (static_center_dot) then
    update_static_dot_interpolation() -- Update static dot sync once per frame
  end

  if re4.last_shoot_pos then
    local pos = re4.last_shoot_pos + (re4.last_shoot_dir * 0.05)
    update_crosshair_world_pos(pos, pos + (re4.last_shoot_dir * 1000.0))
  end

  update_laser_trail() -- Keep trail and muzzle data in sync
end)

re.on_draw_ui(function()
  if imgui.tree_node("Classic RE4 Laser Settings") then
    imgui.begin_rect()
    -- Laser Style Selection
    imgui.text_colored(" Laser Behavior:", 0xFFFFFFAA)
    imgui.same_line()
    if static_center_dot then
        imgui.text_colored("RE4 Remake Style", 0xAA0000FF)
    else
        imgui.text_colored("Classic RE4 Style", 0xAA0000FF)
    end
    if simple_static_mode then
      imgui.same_line()
      imgui.text_colored("+ Dot Crosshair", 0xAA00FF00)
    end
    if disable_shoulder_corrector then
      imgui.same_line()
      imgui.text_colored("+ No Shoulder Correction", 0xFFFF8800)
    end
    if hide_dot_when_no_muzzle then
      imgui.same_line()
      imgui.text_colored("+ Hide Knife Dot", 0xFFFF00FF)
    end
    
    imgui.spacing()
    
    if not static_center_dot then
        imgui.push_style_color(2, 0.2, 0.8, 0.2, 1.0) -- Green background for active
    end
    local classic_pressed = imgui.button("Classic RE4 Style", 200, 0)
    if not static_center_dot then
        imgui.pop_style_color(1)
    end
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Laser follows muzzle direction")
    end
    
    imgui.same_line()
    if static_center_dot then
        imgui.push_style_color(2, 0.2, 0.8, 0.2, 1.0) -- Green background for active
    end
    local remake_pressed = imgui.button("RE4 Remake Style", 200, 0)
    if static_center_dot then
        imgui.pop_style_color(1)
    end
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Laser always centered on screen")
    end
    
    -- Handle button presses
    if classic_pressed and static_center_dot then
        static_center_dot = false
        _G.classic_re4_laser_bullet_spawn_active = true  -- Classic RE4 Style handles bullet spawn
        save_config()
        hasRunInitially = false
        manage_hooks(true)  -- Force check hooks when switching to dynamic mode
    elseif remake_pressed and not static_center_dot then
        static_center_dot = true
        _G.classic_re4_laser_bullet_spawn_active = false  -- RE4 Remake Style - let other mods handle bullet spawn
        dot_scale = 0.85
        save_config()
        hasRunInitially = false
        manage_hooks(true)  -- Force check hooks when switching to static mode
    end
    
    -- Quick Options
    imgui.begin_rect()
    local simple_static_changed = false
    simple_static_changed, simple_static_mode = imgui.checkbox("Enable dot reticle", simple_static_mode)
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Enable completely static dot reticle when laser is off")
    end
    if simple_static_changed then
        save_config()
    end
    
    imgui.same_line()
    corrector_changed, disable_shoulder_corrector = imgui.checkbox("Disable Shoulder Corrector", disable_shoulder_corrector)
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Disable weapon shoulder correction (removes auto centering of the arms and laser dot when aiming for Classic RE4 Laser. Has no effect on laser positioning for RE4 Remake Style)")
    end
    if corrector_changed then
        save_config()
        hasRunInitially = false
    end
    
    local hide_muzzle_changed = false
    hide_muzzle_changed, hide_dot_when_no_muzzle = imgui.checkbox("Hide dot when using knife", hide_dot_when_no_muzzle)
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Hide the laser dot/reticle when no weapon muzzle is detected (useful for clean screenshots or cutscenes)")
    end
    if hide_muzzle_changed then
        save_config()
    end
    
    imgui.end_rect(1)
  
  imgui.spacing()
  
  -- Color Presets Section
  imgui.begin_rect()
  imgui.text_colored(" Color Presets:", 0xFFFFFFAA)
  if imgui.button("Red##red_preset") then
      laser_beam_color_array = {1.0, 0.0, 0.0, 1.0}
      laser_dot_color_array = {1.0, 0.0, 0.0, 1.0}
      laser_color_array = laser_dot_color_array
      apply_beam_color(laser_beam_color_array)
      apply_dot_color(laser_dot_color_array)
      save_config()
  end
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Set both laser beam and dot color to red")
  end
  imgui.same_line()
  if imgui.button("Blue##blue_preset") then
      laser_beam_color_array = {0.02, 0.2, 0.6, 1.0}
      laser_dot_color_array = {0.0, 0.75, 1.0, 1.0}
      laser_color_array = laser_dot_color_array
      apply_beam_color(laser_beam_color_array)
      apply_dot_color(laser_dot_color_array)
      save_config()
  end
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Set both laser beam and dot color to blue")
  end
  imgui.same_line()
  if imgui.button("Green##green_preset") then
      laser_beam_color_array = {0.0, 1.0, 0.0, 1.0}
      laser_dot_color_array = {0.0, 1.0, 0.0, 1.0}
      laser_color_array = laser_dot_color_array
      apply_beam_color(laser_beam_color_array)
      apply_dot_color(laser_dot_color_array)
      save_config()
  end
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Set both laser beam and dot color to green")
  end
  imgui.same_line()
  if imgui.button("Purple##purple_preset") then
      laser_beam_color_array = {1.0, 0.0, 1.0, 1.0}
      laser_dot_color_array = {1.0, 0.0, 1.0, 1.0}
      laser_color_array = laser_dot_color_array
      apply_beam_color(laser_beam_color_array)
      apply_dot_color(laser_dot_color_array)
      save_config()
  end
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Set both laser beam and dot color to purple")
  end
  
  -- Second row of color presets
  if imgui.button("Cyan##cyan_preset") then
      laser_beam_color_array = {0.0, 1.0, 1.0, 1.0}
      laser_dot_color_array = {0.0, 1.0, 1.0, 1.0}
      laser_color_array = laser_dot_color_array
      apply_beam_color(laser_beam_color_array)
      apply_dot_color(laser_dot_color_array)
      save_config()
  end
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Set both laser beam and dot color to cyan")
  end
  imgui.same_line()
  if imgui.button("Orange##orange_preset") then
      laser_beam_color_array = {0.75, 0.1, 0.0, 1.0}
      laser_dot_color_array = {1.0, 0.9, 0.0, 1.0}
      laser_color_array = laser_dot_color_array
      apply_beam_color(laser_beam_color_array)
      apply_dot_color(laser_dot_color_array)
      save_config()
  end
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Set both laser beam and dot color to orange")
  end
  imgui.same_line()
  if imgui.button("White##white_preset") then
      laser_beam_color_array = {1.0, 1.0, 1.0, 1.0}
      laser_dot_color_array = {1.0, 1.0, 1.0, 1.0}
      laser_color_array = laser_dot_color_array
      apply_beam_color(laser_beam_color_array)
      apply_dot_color(laser_dot_color_array)
      save_config()
  end
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Set both laser beam and dot color to white (Glow does not work with white)")
  end
  
  imgui.spacing()
  imgui.text_colored(" Custom Colors:", 0xFFFFFFAA)
  
  -- Color Pickers side by side - Dot first, then Beam
  local dot_color_changed, new_dot_color = nil, nil
  local success_dot = pcall(function()
      dot_color_changed, new_dot_color = imgui.color_edit3("Dot##dot_picker", laser_dot_color_array, 4194304 | 32)
  end)
  
  if not success_dot then
      local dot_color_array_4f = Vector4f.new(laser_dot_color_array[1], laser_dot_color_array[2], laser_dot_color_array[3], laser_dot_color_array[4] or 1.0)
      dot_color_changed, new_dot_color = imgui.color_edit4("Dot##dot_picker", dot_color_array_4f, 4194304 | 32)
      if new_dot_color then
          laser_dot_color_array[1] = new_dot_color.x
          laser_dot_color_array[2] = new_dot_color.y
          laser_dot_color_array[3] = new_dot_color.z
          laser_dot_color_array[4] = new_dot_color.w
      end
  else
      if new_dot_color then
          laser_dot_color_array = new_dot_color
      end
  end
  
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Click to open color picker - adjust laser dot color (RGB values)")
  end
  
  if dot_color_changed then
      apply_dot_color(laser_dot_color_array)
      save_config()
  end
  
  imgui.same_line()
  local beam_color_changed, new_beam_color = nil, nil
  local success_beam = pcall(function()
      beam_color_changed, new_beam_color = imgui.color_edit3("Beam##beam_picker", laser_beam_color_array, 4194304 | 32)
  end)
  
  if not success_beam then
      local beam_color_array_4f = Vector4f.new(laser_beam_color_array[1], laser_beam_color_array[2], laser_beam_color_array[3], laser_beam_color_array[4] or 1.0)
      beam_color_changed, new_beam_color = imgui.color_edit4("Beam##beam_picker", beam_color_array_4f, 4194304 | 32)
      if new_beam_color then
          laser_beam_color_array[1] = new_beam_color.x
          laser_beam_color_array[2] = new_beam_color.y
          laser_beam_color_array[3] = new_beam_color.z
          laser_beam_color_array[4] = new_beam_color.w
      end
  else
      if new_beam_color then
          laser_beam_color_array = new_beam_color
      end
  end
  
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Click to open color picker - adjust laser beam color (RGB values)")
  end
  
  if beam_color_changed then
      apply_beam_color(laser_beam_color_array)
      save_config()
  end
  
  imgui.same_line()
  local knife_color_changed, new_knife_color
  local success_knife = pcall(function()
      knife_color_changed, new_knife_color = imgui.color_edit3("Knife##knife_picker", knife_dot_color_array, 4194304 | 32)
  end)
  
  if not success_knife then
      local knife_color_array_4f = Vector4f.new(knife_dot_color_array[1], knife_dot_color_array[2], knife_dot_color_array[3], knife_dot_color_array[4] or 1.0)
      knife_color_changed, new_knife_color = imgui.color_edit4("Knife##knife_picker", knife_color_array_4f, 4194304 | 32)
      if new_knife_color then
          knife_dot_color_array[1] = new_knife_color.x
          knife_dot_color_array[2] = new_knife_color.y
          knife_dot_color_array[3] = new_knife_color.z
          knife_dot_color_array[4] = new_knife_color.w
      end
  else
      if new_knife_color then
          knife_dot_color_array = new_knife_color
      end
  end
  
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Click to open color picker - adjust knife dot color (RGB values)")
  end
  
  if knife_color_changed then
      save_config()
  end
  
  -- Static reticle color (when weapon laser is disabled)
  local static_reticle_color_changed, new_static_reticle_color
  local success_static = pcall(function()
      static_reticle_color_changed, new_static_reticle_color = imgui.color_edit3("Static Reticle##static_reticle_picker", static_reticle_color_array, 4194304 | 32)
  end)
  
  if not success_static then
      local static_reticle_color_array_4f = Vector4f.new(static_reticle_color_array[1], static_reticle_color_array[2], static_reticle_color_array[3], static_reticle_color_array[4] or 1.0)
      static_reticle_color_changed, new_static_reticle_color = imgui.color_edit4("Static Reticle##static_reticle_picker", static_reticle_color_array_4f, 4194304 | 32)
      if new_static_reticle_color then
          static_reticle_color_array[1] = new_static_reticle_color.x
          static_reticle_color_array[2] = new_static_reticle_color.y
          static_reticle_color_array[3] = new_static_reticle_color.z
          static_reticle_color_array[4] = new_static_reticle_color.w
      end
  else
      if new_static_reticle_color then
          static_reticle_color_array = new_static_reticle_color
      end
  end
  
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Color of the static reticle when weapon does not have laser enabled")
  end
  
  if static_reticle_color_changed then
      save_config()
  end
  imgui.end_rect(1)
  
  imgui.spacing()
  
  -- Laser/Knife Dot Settings
  imgui.begin_rect()
  imgui.text_colored(" Laser/Knife Dot Settings:", 0xFFFFFFAA)
  max_changed, max_scale = imgui.slider_float("Max Scale", max_scale, 0.4, 2.0, "%.2f")
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Maximum size of the laser dot at far distances (Set this equal to min scale for realistic scaling)")
  end
  if max_changed then
      save_config()
  end
  
  min_changed, min_scale = imgui.slider_float("Min Scale", min_scale, 0.1, 1.0, "%.2f")
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Minimum size of the laser dot at close distances (Set this equal to max scale for realistic scaling)")
  end
  if min_changed then
      save_config()
  end
  
  scale_changed, dot_scale = imgui.slider_float("Dot Scale", dot_scale, 0.1, 10.0, "%.2f")
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Overall scale multiplier for the laser dot size")
  end
  if scale_changed then
      save_config()
  end
  
  local knife_scale_changed
  knife_scale_changed, knife_dot_scale = imgui.slider_float("Knife Dot Scale", knife_dot_scale, 0.1, 10.0, "%.2f")
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Scale multiplier for the knife/no-muzzle dot size")
  end
  if knife_scale_changed then
      save_config()
  end
  
  saturation_changed, crosshair_saturation = imgui.slider_float("Glow", crosshair_saturation, 0.0, 100.0, "%.1f")
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Glow/saturation of the laser dot")
  end
  if saturation_changed then
      save_config()
  end
  imgui.end_rect(1)
  
  imgui.spacing()
  
  -- Laser Beam Settings
  imgui.begin_rect()
  imgui.text_colored(" Laser Beam Settings:", 0xFFFFFFAA)
  local scale_changed = false
  scale_changed, laser_trail_scale = imgui.slider_float("Beam Width", laser_trail_scale, 0.0, 10.0, "%.2f")
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Thickness of the laser beam. Set to 0 to hide beam")
  end
  if scale_changed then
      save_config()
  end
  
  -- Laser Beam Material Editor (simplified)
  if laser_trail_gameobject then
    local mesh_component = laser_trail_gameobject:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    if mesh_component and mesh_component.get_MaterialNum and mesh_component.getMaterialName and mesh_component.getMaterialVariableNum and mesh_component.getMaterialVariableName and mesh_component.getMaterialVariableType and mesh_component.getMaterialFloat and mesh_component.getMaterialFloat4 and mesh_component.setMaterialFloat and mesh_component.setMaterialFloat4 then
      local matCount = mesh_component:get_MaterialNum()
     
      _G.laser_mat_params = _G.laser_mat_params or {}
      _G.laser_mat_params_defaults = _G.laser_mat_params_defaults or {}
      for j = 0, matCount - 1 do
        local matName = mesh_component:getMaterialName(j)
        local matParam = mesh_component:getMaterialVariableNum(j)
        if not _G.laser_mat_params[matName] then _G.laser_mat_params[matName] = {} end
        if not _G.laser_mat_params_defaults[matName] then _G.laser_mat_params_defaults[matName] = {} end
        
        for k = 0, matParam - 1 do
          local paramName = mesh_component:getMaterialVariableName(j, k)
          local paramType = mesh_component:getMaterialVariableType(j, k)
          
          if _G.laser_mat_params_defaults[matName][paramName] == nil then
            if paramType == 1 then
              _G.laser_mat_params_defaults[matName][paramName] = mesh_component:getMaterialFloat(j, k)
            elseif paramType == 4 then
              local curVal = mesh_component:getMaterialFloat4(j, k)
              _G.laser_mat_params_defaults[matName][paramName] = {curVal.x, curVal.y, curVal.z, curVal.w}
            end
          end
          
          if paramType == 1 then -- float
            local curVal = mesh_component:getMaterialFloat(j, k)
            if _G.laser_mat_params[matName][paramName] == nil then _G.laser_mat_params[matName][paramName] = curVal end
            
            local minVal, maxVal
            if paramName == "SmokeContrast_Add" then
              minVal, maxVal = 0, 10
            elseif paramName == "GradationRate" then
              minVal, maxVal = 0, 30
            elseif paramName == "SmokeDetailSpeed" then
              minVal, maxVal = 0, 15
            elseif paramName == "SmokeDetailScale" then
              minVal, maxVal = 0, 2000
            elseif paramName == "SmokeContrast_Pow" then
              minVal, maxVal = 0, 100
            elseif paramName == "AlphaRate" then
              minVal, maxVal = 0, 1
            elseif paramName == "EmissiveIntensity" then
            minVal, maxVal = 0, 100
            else
              minVal, maxVal = -10, 100
            end
            
            local changed, newVal = imgui.slider_float(paramName, _G.laser_mat_params[matName][paramName], minVal, maxVal, "%.2f")
            if imgui.is_item_hovered() then
                if paramName == "AlphaRate" then
                    imgui.set_tooltip("Adjust the transparency of the laser beam")
                elseif paramName == "SmokeDetailSpeed" then
                    imgui.set_tooltip("Adjust the speed of the particles in the laser beam")
                elseif paramName == "SmokeDetailScale" then
                    imgui.set_tooltip("Adjust the size of the particles in the laser beam")
                elseif paramName == "EmissiveIntensity" then
                    imgui.set_tooltip("Adjust the glow of the laser beam")
                elseif paramName == "GradationRate" then
                    imgui.set_tooltip("Adjust the gradient transition or falloff pattern of the laser beam's visual effects")
                end
            end
            if changed then
              _G.laser_mat_params[matName][paramName] = newVal
              mesh_component:setMaterialFloat(j, k, newVal)
              save_config()
            end
          end
        end
      end
    else
      imgui.text(" Laser trail mesh/material not available.")
    end
  else
    imgui.text(" Laser trail not active.")
  end
  imgui.end_rect(1)
  
  imgui.spacing()
  
  -- Weapon-Specific Offsets
  imgui.begin_rect()
  imgui.text_colored(" Weapon-Specific Laser Origin Offsets:", 0xFFFFFFAA)
  local weapon_ids = {
      4000,4001,4002,4003,4004,4100,4101,4102,4200,4201,4202,4400,4401,4402,
      4500,4501,4502,4600,4900,4901,4902,6000,6001,6100,6101,6102,6103,6104,6105,6106,6111,6112,6113,6114,6300,6304
  }
  
  -- Weapon names array for offset editor (use separate table to avoid shadowing global weapon_names)
  local offset_weapon_names = {
      "SG-09 R",              -- 4000
      "Punisher",             -- 4001  
      "Red9",                 -- 4002
      "Blacktail",            -- 4003
      "Matilda",              -- 4004
      "W-870",                -- 4100
      "Riot Gun",             -- 4101
      "Striker",              -- 4102
      "TMP",                  -- 4200
      "Chicago Sweeper",      -- 4201
      "LE 5",                 -- 4202
      "SR M1903",             -- 4400
      "Stingray",             -- 4401
      "CQBR Assault Rifle",   -- 4402
      "Broken Butterfly",     -- 4500
      "Killer7",              -- 4501
      "Handcannon",           -- 4502
      "Bolt Thrower",         -- 4600
      "Rocket Launcher",      -- 4900
      "Rocket Launcher (Special)", -- 4901
      "Infinite Rocket Launcher", -- 4902
      "Sentinel Nine",        -- 6000
      "Skull Shaker",         -- 6001
      "Sawed-off W-870",      -- 6100
      "Chicago Sweeper SW",   -- 6101
      "Blast Crossbow",       -- 6102
      "Blacktail AC",         -- 6103
      "TMP SW",               -- 6104
      "Stingray SW",          -- 6105
      "Rocket Launcher SW",   -- 6106
      "Infinite Rocket Launcher SW", -- 6111
      "Punisher MC",          -- 6112
      "Red9 SW",              -- 6113
      "SR M1903 SW",          -- 6114
      "XM96E1",               -- 6300
      "EJF-338 Compound Bow"  -- 6304
  }
  
  -- Generate weapon labels with both name and ID
  local weapon_labels = {}
    for i, id in ipairs(weapon_ids) do
      local name = offset_weapon_names[i] or ("Unknown Weapon")
      weapon_labels[i] = name --.. " (" .. tostring(id) .. ")"
  end
  if not _G.selected_weapon_idx then _G.selected_weapon_idx = 1 end
  local changed, new_idx = imgui.combo("Select Weapon", _G.selected_weapon_idx, weapon_labels)
  if changed then
      _G.selected_weapon_idx = new_idx
  end
  local selected_id = tostring(weapon_ids[_G.selected_weapon_idx])
  local offset = laser_origin_offsets[selected_id] or {x=0, y=0, z=0}
  local changed_x, new_x = imgui.slider_float("X Offset", offset.x, -1, 1, "%.4f")
  local changed_y, new_y = imgui.slider_float("Y Offset", offset.y, -1, 1, "%.4f")
  local changed_z, new_z = imgui.slider_float("Z Offset", offset.z, -1, 1, "%.4f")
  if changed_x or changed_y or changed_z then
      laser_origin_offsets[selected_id] = {x=new_x, y=new_y, z=new_z}
      save_config()
  end
  imgui.end_rect(1)
  
  imgui.spacing()
  
  -- Reset Buttons
  imgui.begin_rect()
  if imgui.button("Reset dot to default") then
      max_scale = 1.25
      min_scale = 0.3
      dot_scale = 0.85
      knife_dot_scale = 1.0
      crosshair_saturation = 20.0
      static_center_dot = false
      _G.classic_re4_laser_bullet_spawn_active = true  -- Classic RE4 Style handles bullet spawn
      simple_static_mode = false
      disable_shoulder_corrector = false
      hide_dot_when_no_muzzle = false
      laser_dot_color_array = {1.0, 0.0, 0.0, 1.0}
      knife_dot_color_array = {1.0, 1.0, 1.0, 1.0}
      laser_color_array = laser_dot_color_array
      apply_dot_color(laser_dot_color_array)
      save_config()
  end
  
  imgui.same_line()
  if imgui.button("Reset beam to default") then
    -- Reset beam color to red
    laser_beam_color_array = {1.0, 0.0, 0.0, 1.0}
    apply_beam_color(laser_beam_color_array)
    
    if laser_trail_gameobject then
      local mesh_component = laser_trail_gameobject:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
      if mesh_component then
        local matCount = mesh_component:get_MaterialNum()
        for j2 = 0, matCount - 1 do
          local matName2 = mesh_component:getMaterialName(j2)
          local matParam2 = mesh_component:getMaterialVariableNum(j2)
          for k2 = 0, matParam2 - 1 do
            local paramName2 = mesh_component:getMaterialVariableName(j2, k2)
            local paramType2 = mesh_component:getMaterialVariableType(j2, k2)
            local def = _G.laser_mat_params_defaults[matName2] and _G.laser_mat_params_defaults[matName2][paramName2]
            if def ~= nil then
              if paramType2 == 1 then
                mesh_component:setMaterialFloat(j2, k2, def)
                if not _G.laser_mat_params[matName2] then _G.laser_mat_params[matName2] = {} end
                _G.laser_mat_params[matName2][paramName2] = def
              elseif paramType2 == 4 then
                mesh_component:setMaterialFloat4(j2, k2, Vector4f.new(def[1], def[2], def[3], def[4]))
                if not _G.laser_mat_params[matName2] then _G.laser_mat_params[matName2] = {} end
                _G.laser_mat_params[matName2][paramName2] = {def[1], def[2], def[3], def[4]}
              end
            end
          end
        end
        laser_trail_scale = 1.5  -- Reset beam width to default
        save_config()
      end
    end
  end
  imgui.end_rect(1)

  imgui.spacing()

  imgui.begin_rect()
  if imgui.button("Reset ALL laser settings to defaults") then
      max_scale = 1.25
      min_scale = 0.3
      dot_scale = 0.85
      knife_dot_scale = 1.0
      disable_shoulder_corrector = false
      hide_dot_when_no_muzzle = false
      laser_beam_color_array = {1.0, 0.0, 0.0, 1.0}
      laser_dot_color_array = {1.0, 0.0, 0.0, 1.0}
      knife_dot_color_array = {1.0, 1.0, 1.0, 1.0}
      laser_color_array = {1.0, 0.0, 0.0, 1.0}
      crosshair_saturation = 20.0
      static_center_dot = false
      _G.classic_re4_laser_bullet_spawn_active = true  -- Classic RE4 Style handles bullet spawn
      static_lerp_speed = 50.0
      simple_static_mode = false
      enable_laser_trail = true
      laser_trail_scale = 1.5
      hide_dot_when_no_muzzle = false
      -- Reset laser origin offsets to defaults
      laser_origin_offsets = {}
      for weapon_id, offset in pairs(default_laser_origin_offsets) do
          laser_origin_offsets[weapon_id] = {x = offset.x, y = offset.y, z = offset.z}
      end
      
      -- Reset beam material parameters if laser trail exists (before clearing defaults)
      if laser_trail_gameobject then
        local mesh_component = laser_trail_gameobject:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        if mesh_component and _G.laser_mat_params_defaults then
          local matCount = mesh_component:get_MaterialNum()
          for j2 = 0, matCount - 1 do
            local matName2 = mesh_component:getMaterialName(j2)
            local matParam2 = mesh_component:getMaterialVariableNum(j2)
            for k2 = 0, matParam2 - 1 do
              local paramName2 = mesh_component:getMaterialVariableName(j2, k2)
              local paramType2 = mesh_component:getMaterialVariableType(j2, k2)
              local def = _G.laser_mat_params_defaults[matName2] and _G.laser_mat_params_defaults[matName2][paramName2]
              if def ~= nil then
                if paramType2 == 1 then
                  mesh_component:setMaterialFloat(j2, k2, def)
                elseif paramType2 == 4 then
                  mesh_component:setMaterialFloat4(j2, k2, Vector4f.new(def[1], def[2], def[3], def[4]))
                end
              end
            end
          end
        end
      end
      
      -- Apply beam color reset
      apply_beam_color(laser_beam_color_array)
      
      _G.laser_mat_params = nil
      _G.laser_mat_params_defaults = nil
      save_config()
      hasRunInitially = false
  end
  imgui.end_rect(1)
  
  imgui.spacing()
  
  -- Weapon Laser Enable Settings
  if imgui.tree_node("Weapon Laser Settings") then
    imgui.begin_rect()
    imgui.text_colored(" Select weapons to show laser trail:", 0xFFFFFFAA)
    imgui.text_colored(" (Unchecked weapons will only show dot reticle)", 0xFFAAAA00)
    imgui.spacing()
    
    -- Enable All / Disable All buttons
    if imgui.button("Enable All") then
      for _, category in ipairs(weapon_categories) do
        for _, id in ipairs(category.ids) do
          weapon_laser_enabled[tostring(id)] = true
        end
      end
      save_config()
    end
    imgui.same_line()
    if imgui.button("Disable All") then
      for _, category in ipairs(weapon_categories) do
        for _, id in ipairs(category.ids) do
          weapon_laser_enabled[tostring(id)] = false
        end
      end
      save_config()
    end
    
    imgui.spacing()
    
    -- Flat list of weapons (no categories) showing names only
    local ordered_ids = {}
    for _, category in ipairs(weapon_categories) do
      for _, id in ipairs(category.ids) do
        table.insert(ordered_ids, id)
      end
    end

    for _, id in ipairs(ordered_ids) do
      local id_str = tostring(id)
      local name = weapon_names[id] or ("Unknown (" .. id_str .. ")")
      -- Default to true if not set
      if weapon_laser_enabled[id_str] == nil then
        weapon_laser_enabled[id_str] = true
      end
      local changed, new_val = imgui.checkbox(name .. "##wp" .. id_str, weapon_laser_enabled[id_str])
      if changed then
        weapon_laser_enabled[id_str] = new_val
        save_config()
      end
    end
    
    imgui.end_rect(1)
    imgui.tree_pop()
  end
  
  imgui.spacing()
  
  -- Hotkey Settings
  if imgui.tree_node("Hotkey Settings For Laser Toggle") then
    local changed = false
    local wc = false
    
    imgui.begin_rect()
    if imgui.button("Reset Hotkeys to Defaults") then
        Laser_settings = hk.recurse_def_settings({}, Laser_default_settings)
        wc = true  -- Force a save since we're resetting
        hk.reset_from_defaults_tbl(Laser_default_settings.hotkeys)
    end
    
    imgui.text_colored(" Keyboard and Mouse:", 0xFFFFFFAA)
    changed, Laser_settings.use_modifier = imgui.checkbox("Use Modifier##kb_mod", Laser_settings.use_modifier); wc = wc or changed
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Require that you hold down this button")
    end
    imgui.same_line()
    changed = hk.hotkey_setter("Laser Modifier") or false; wc = wc or changed
    changed = hk.hotkey_setter("Laser Toggle", Laser_settings.use_modifier and "Laser Modifier") or false; wc = wc or changed
    
    imgui.text_colored(" Gamepad:", 0xFFFFFFAA)
    changed, Laser_settings.use_pad_modifier = imgui.checkbox("Use Modifier##pad_mod", Laser_settings.use_pad_modifier); wc = wc or changed
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Require that you hold down this button")
    end
    imgui.same_line()
    changed = hk.hotkey_setter("Pad Laser Modifier") or false; wc = wc or changed
    changed = hk.hotkey_setter("Pad Laser Toggle", Laser_settings.use_pad_modifier and "Pad Laser Modifier") or false; wc = wc or changed
    
    if changed or wc then
        hk.update_hotkey_table(Laser_settings.hotkeys)
        json.dump_file("ClassicLaser/Laser_Hotkey_Settings.json", Laser_settings)
        changed = false
        wc = false
    end
    imgui.end_rect(1)
    
    imgui.tree_pop()
  end
  imgui.end_rect(1)
  imgui.tree_pop()
  end
end)

load_config()