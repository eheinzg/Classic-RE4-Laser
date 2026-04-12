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
local show_per_weapon_popup = false -- Per-weapon laser popup window open state
local post_shot_pw_popup_weapon_idx = 1 -- 1-based index into post-shot-by-weapon popup weapon combo (REFramework imgui.combo)
local hide_dot_when_no_muzzle = false -- Hide reticle/dot when no muzzle is found
local show_default_crosshair_laser_off = true -- Show game's default crosshair when laser is disabled for a weapon (default on)

local default_crosshair_color_array = {1.0, 1.0, 1.0, 1.0} -- RGBA for crosshair when laser is off + show default crosshair
local default_crosshair_match_laser = false -- Use laser dot color instead of custom crosshair color
local default_crosshair_saturation =1.0 -- Glow/saturation for the default crosshair
local default_crosshair_view_type = 1 -- combo: 0 = 3D Crosshair, 1 = Default
local default_crosshair_overlay = true
local default_crosshair_detonemap = true
local default_crosshair_depth_test = false

-- Debug DrawView overrides (applied after normal logic when enabled)

re4.crosshair_pos = Vector3f.new(0, 0, 0)
re4.crosshair_normal = Vector3f.new(0, 0, 0)

local gameobject_get_transform = sdk.find_type_definition("via.GameObject"):get_method("get_Transform")

local joint_get_position = sdk.find_type_definition("via.Joint"):get_method("get_Position")
local joint_get_rotation = sdk.find_type_definition("via.Joint"):get_method("get_Rotation")

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

-- Cached methods for performance (avoid get_method calls in hot paths)
local vec3_set_item = vec3_t and vec3_t:get_method("set_Item(System.Int32, System.Single)")
local quat_set_item = quat_t and quat_t:get_method("set_Item(System.Int32, System.Single)")

global_intersection_point = nil

-- Global flag for other mods to check if Classic RE4 Style mode is active
-- When true, bullet spawn is handled by ClassicRE4Laser (not IronSight.lua)
_G.classic_re4_laser_bullet_spawn_active = false
-- New flag: true when weapon has laser unchecked (forces RE4 Remake spawn, distinct status)
_G.classic_re4_laser_weapon_disabled = false

local scene = nil
local gun_obj = nil

-- Store reference for cleanup on script reset
local laser_trail_table = {}

-- Helper to set global spawn ownership based on current weapon and mode
local function update_spawn_flag()
  if type(weapon_laser_enabled) ~= "table" then
    weapon_laser_enabled = {}
  end
  local weapon_id_str = current_weapon_id and tostring(current_weapon_id) or "unknown"
  local laser_disabled_for_weapon = weapon_laser_enabled[weapon_id_str] == false
  
  -- Set the weapon-disabled flag for other code to detect this distinct state
  _G.classic_re4_laser_weapon_disabled = laser_disabled_for_weapon
  
  -- If weapon is explicitly disabled, force RE4 Remake (camera) spawn regardless of mode
  if laser_disabled_for_weapon then
    _G.classic_re4_laser_bullet_spawn_active = false
    return
  end

  local laser_enabled_for_weapon = weapon_laser_enabled[weapon_id_str] ~= false  -- default true when nil
  -- true  => Classic (muzzle) owns bullet spawn; false => Remake (camera) spawn
  _G.classic_re4_laser_bullet_spawn_active = (not static_center_dot) and laser_enabled_for_weapon
end

-- Global variables for laser trail offset calculations
local current_weapon_id = nil
local current_muzzle_joint = nil

-- Perfect accuracy feature
if _G.classic_re4_laser_perfect_accuracy_enabled == nil then
    _G.classic_re4_laser_perfect_accuracy_enabled = true
end

-- Point range feature (separate from perfect accuracy)
if _G.classic_re4_laser_point_range_enabled == nil then
    _G.classic_re4_laser_point_range_enabled = true
end

-- Spread fields for perfect accuracy
local spread_fields = {
    random = "_RandomRadius",
    randomFit = "_RandomRadius_Fit",
}

-- Spread cache for perfect accuracy (stores _MoveInfo objects from shell data)
local spread_cache = {}
local applied_zero_spread = false
local force_spread_update = false  -- Flag to force reapplication after character change

-- Forward declarations for defaults system (defined later, used early)
local saved_defaults = nil
local defaults_loaded = false
local current_game_mode = "Main"
local capture_defaults_pending = false

local function load_defaults_file()
    if defaults_loaded then return end
    local status, data = pcall(json.load_file, "ClassicLaser\\WeaponDefaults.json")
    if status and data then
        saved_defaults = data
    else
        saved_defaults = {
            Main = {spread = {}, point_range = {}},
            AO = {spread = {}, point_range = {}},
            MC = {spread = {}, point_range = {}}
        }
    end
    if saved_defaults.spread and not saved_defaults.Main then
        local old_data = {spread = saved_defaults.spread, point_range = saved_defaults.point_range}
        saved_defaults = {
            Main = old_data,
            AO = {spread = {}, point_range = {}},
            MC = {spread = {}, point_range = {}}
        }
    end
    defaults_loaded = true
end

local function save_defaults_file()
    if saved_defaults then
        pcall(json.dump_file, "ClassicLaser\\WeaponDefaults.json", saved_defaults)
    end
end

-- Helper to check if managed object is valid
local function is_valid_managed(obj)
    if not obj then return false end
    if tostring(obj) == "nil" then return false end
    if sdk.is_managed_object then
        local result = sdk.is_managed_object(obj)
        if result == false then return false end
    end
    return true
end

-- Read spread field from _MoveInfo param
local function read_spread_field(param, field)
    if not param or not is_valid_managed(param) then return nil end
    local ok, val = pcall(function() return param:get_field(field) end)
    return ok and val or nil
end

-- Write spread field to _MoveInfo param (use direct assignment like DWP)
local function write_spread_field(param, field, value)
    if not param or not is_valid_managed(param) then return end
    pcall(function() param[field] = value end)
end

-- Apply zero spread to _MoveInfo param
local function apply_zero_spread(param)
    if not param or not is_valid_managed(param) then return end
    write_spread_field(param, "_RandomRadius", 0.0)
    write_spread_field(param, "_RandomRadius_Fit", 0.0)
end

-- Restore spread values to _MoveInfo param (uses saved defaults from JSON file)
local function restore_spread(param, values, cache_key)
    if not param or not is_valid_managed(param) then return end
    if not values then return end
    -- Try to get values from saved defaults file first (mode-specific)
    load_defaults_file()
    local mode_defaults = saved_defaults and saved_defaults[current_game_mode]
    local saved_spread = mode_defaults and mode_defaults.spread and mode_defaults.spread[cache_key]
    local random_val = saved_spread and saved_spread.random or values.random
    local randomFit_val = saved_spread and saved_spread.randomFit or values.randomFit
    if random_val ~= nil then
        write_spread_field(param, "_RandomRadius", random_val)
    end
    if randomFit_val ~= nil then
        write_spread_field(param, "_RandomRadius_Fit", randomFit_val)
    end
end

-- Register a _MoveInfo target for spread modification
local function register_spread_target(move_info, weapon_id)
    if not move_info or not is_valid_managed(move_info) then
        return
    end
    local key = tostring(move_info)
    local entry = spread_cache[key]
    if not entry then
        local spread_values = {
            random = read_spread_field(move_info, spread_fields.random),
            randomFit = read_spread_field(move_info, spread_fields.randomFit),
        }
        
        -- If capturing defaults, save current values to file (mode-specific)
        if capture_defaults_pending and weapon_id then
            load_defaults_file()
            if not saved_defaults[current_game_mode] then
                saved_defaults[current_game_mode] = {spread = {}, point_range = {}}
            end
            saved_defaults[current_game_mode].spread[tostring(weapon_id)] = {
                random = spread_values.random,
                randomFit = spread_values.randomFit,
            }
        end
        
        spread_cache[key] = {
            object = move_info,
            values = spread_values,
            weapon_id = weapon_id,
        }
    else
        entry.object = move_info
        entry.weapon_id = weapon_id
    end
end

-- Register spread targets from shell userdata (recursively finds _MoveInfo objects)
local function register_spread_targets_from_shell(shell_userdata, weapon_id)
  if not shell_userdata or not is_valid_managed(shell_userdata) then
    return
  end

  local visited_candidates = {}

  local function handle_candidate(candidate)
    if candidate == nil then
      return
    end

    local candidate_type = type(candidate)

    if candidate_type == "table" then
      if visited_candidates[candidate] then
        return
      end
      visited_candidates[candidate] = true
      for _, element in ipairs(candidate) do
        handle_candidate(element)
      end
      return
    end

    if candidate_type ~= "userdata" then
      return
    end

    if visited_candidates[candidate] then
      return
    end
    visited_candidates[candidate] = true

    if not is_valid_managed(candidate) then
      return
    end

    local move_info = candidate:get_field("_MoveInfo")
    if move_info and is_valid_managed(move_info) then
      register_spread_target(move_info, weapon_id)
      return
    end

    local iterator_success = false

    if type(candidate.get_elements) == "function" then
      local elements = candidate:get_elements()
      if elements then
        iterator_success = true
        for _, element in ipairs(elements) do
          handle_candidate(element)
        end
      end
    end

    if not iterator_success and type(candidate.call) == "function" then
      local count = candidate:call("get_Count")
      if type(count) == "number" and count > 0 then
        iterator_success = true
        for i = 0, count - 1 do
          local item = candidate:call("get_Item", i)
          if item then
            handle_candidate(item)
          end
        end
      end
    end

    if not iterator_success then
      local type_def = candidate:get_type_definition()
      local fields = type_def and type_def:get_fields() or nil
      if fields then
        for _, field in ipairs(fields) do
          if field:get_name():match("ShellInfoUserData") then
            local sub_obj = candidate:get_field(field:get_name())
            if sub_obj then
              handle_candidate(sub_obj)
            end
          end
        end
      end
    end
  end

  local candidate_fields = {
    "_ShellInfoUserData",
    "_CenterShellInfoUserData",
    "_AroundShellInfoUserData",
    "_ShellInfoUserDataList",
    "_ShellInfoUserDataArray",
  }

  for _, field_name in ipairs(candidate_fields) do
    local field_obj = shell_userdata:get_field(field_name)
    if field_obj then
      handle_candidate(field_obj)
    end
  end

  handle_candidate(shell_userdata)
end

-- Track last weapon ID and accuracy state to avoid redundant processing
local last_spread_weapon_id = nil
local last_spread_accuracy_state = nil
-- Cached for update_spread_state pass after update_laser_trail when PA-only-while-laser is on
local spread_refresh_bt_gun = nil
local spread_refresh_weapon_id = nil
-- When true, Perfect Accuracy / Perfect Focus only apply while the classic muzzle laser trail is active (aim + trail rules).
local perfect_accuracy_only_when_laser_active = false
local perfect_focus_only_when_laser_active = false
local classic_laser_trail_effective_prev = nil -- last classic_laser_active_for_perfect; PF reticle refresh + PA spread refresh on change
-- Written each update_laser_trail(): true iff beam would draw or grace (same as should_show || within_grace_period)
local classic_laser_active_for_perfect = false

-- Apply or restore spread based on perfect accuracy setting
local function update_spread_state(bt_gun, weapon_id)
    if not bt_gun or not is_valid_managed(bt_gun) then
        return
    end
    
    -- Check for perfect accuracy
    -- Only check IronSight's flag when IronSight is actually active
    local ironsight_active = rawget(_G, "standalone_iron_sight_active") == true
    local ironsight_pa = ironsight_active and rawget(_G, "standalone_perfect_accuracy_enabled") == true
    local pa_flag = _G.classic_re4_laser_perfect_accuracy_enabled
    local classic_pa = (pa_flag ~= false)
    if perfect_accuracy_only_when_laser_active and not ironsight_pa then
      classic_pa = classic_pa and classic_laser_active_for_perfect
    end
    local should_zero = ironsight_pa or classic_pa
    
    -- Check if weapon changed or cache is empty (need to rebuild)
    local weapon_changed = (weapon_id ~= last_spread_weapon_id)
    local cache_empty = (next(spread_cache) == nil)
    
    -- Skip if nothing changed and state is already correct
    local state_changed = weapon_changed or (should_zero ~= last_spread_accuracy_state) or force_spread_update or cache_empty
    if not state_changed and applied_zero_spread == should_zero then
        return
    end
    force_spread_update = false  -- Clear the force flag after processing
    
    -- Get shell generator and userdata (when weapon changes or cache is empty)
    if weapon_changed or cache_empty then
        -- Clear old cache when weapon changes
        spread_cache = {}
        applied_zero_spread = false
        
        local shell = bt_gun:get_field("<ShellGenerator>k__BackingField")
        if shell and is_valid_managed(shell) then
          local shell_userdata = shell:get_field("_UserData")
          if shell_userdata and is_valid_managed(shell_userdata) then
            register_spread_targets_from_shell(shell_userdata, weapon_id)
          end
        end
    end
    
    -- Update tracking after shell generator check
    last_spread_weapon_id = weapon_id
    last_spread_accuracy_state = should_zero

    -- Apply zero spread if enabled and we have cached objects
    if should_zero and next(spread_cache) ~= nil then
        for spread_key, spread_entry in pairs(spread_cache) do
            local spread_param = spread_entry.object
            if spread_param and is_valid_managed(spread_param) then
                apply_zero_spread(spread_param)
            else
                spread_cache[spread_key] = nil
            end
        end
        applied_zero_spread = true
    elseif not should_zero and applied_zero_spread then
        -- Restore spread values
        for spread_key, spread_entry in pairs(spread_cache) do
            local spread_param = spread_entry.object
            if spread_param and is_valid_managed(spread_param) then
                local cache_key = spread_entry.weapon_id and tostring(spread_entry.weapon_id) or spread_key
                restore_spread(spread_param, spread_entry.values, cache_key)
            end
            spread_cache[spread_key] = nil
        end
        applied_zero_spread = false
    end
end

-- Cache for original point range values per weapon ID
local original_point_ranges = {}

local reticleValue = 4        

local hasRunInitially = false

local scene_manager = nil
local gui_initialized = false
local minRange = 0
local maxRange = 5
dot_scale = 1.0  -- Default dot scale
knife_dot_scale = 1.0  -- Default knife dot scale
local min_scale = 0.3
local max_scale = 1.25
local config_file = "ClassicLaser\\LaserSettings.json"
local defaults_file = "ClassicLaser\\WeaponDefaults.json"

local character_ids = {
"ch3a8z0_head", "ch6i0z0_head", "ch6i1z0_head", "ch6i2z0_head",
"ch6i3z0_head", "ch3a8z0_MC_head", "ch6i5z0_head"
}
local disable_shoulder_corrector = false

-- Default laser dot glow (matches initial crosshair_saturation) and beam MDF params (wp4000_00_Laserbeam)
local LASER_DOT_GLOW_DEFAULT = 20.0
local LASER_BEAM_MATERIAL_DEFAULTS = {
  AlphaRate = 0.009999999776482582,
  EmissiveColor = {1.0, 0.0, 0.0, 1.0},
  EmissiveIntensity = 100.0,
  GradationRate = 1.2100000381469727,
  SmokeContrast_Add = 0.0,
  SmokeContrast_Pow = 5.0,
  SmokeDetailScale = 7.679999828338623,
  SmokeDetailSpeed = 4.769999980926514,
}
local function copy_laser_beam_material_defaults_into(out)
  if not out then return end
  local s = LASER_BEAM_MATERIAL_DEFAULTS
  out.AlphaRate = s.AlphaRate
  out.EmissiveColor = { s.EmissiveColor[1], s.EmissiveColor[2], s.EmissiveColor[3], s.EmissiveColor[4] }
  out.EmissiveIntensity = s.EmissiveIntensity
  out.GradationRate = s.GradationRate
  out.SmokeContrast_Add = s.SmokeContrast_Add
  out.SmokeContrast_Pow = s.SmokeContrast_Pow
  out.SmokeDetailScale = s.SmokeDetailScale
  out.SmokeDetailSpeed = s.SmokeDetailSpeed
end

local crosshair_saturation = LASER_DOT_GLOW_DEFAULT  -- Crosshair color saturation (glow)

-- Weapon names for UI display
local weapon_names = {
  [4000] = "SG-09 R",
  [4001] = "Punisher",
  [4002] = "Red9",
  [4003] = "Blacktail",
  [4004] = "Matilda",
  [4005] = "Minecart Handgun",
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
-- Note: 4005 (Minecart Handgun) is excluded - it uses forced static mode only
local weapon_categories = {
    {name = "Handguns", ids = {4000, 4001, 4002, 4003, 4004, 6000, 6001, 6112, 6300}},
    {name = "Shotguns", ids = {4100, 4101, 4102, 6100, 6101, 6102}},
    {name = "SMGs", ids = {4200, 4201, 4202, 6103, 6104}},
    {name = "Rifles", ids = {4400, 4401, 4402, 6105, 6114}},
    {name = "Magnums", ids = {4500, 4501, 4502, 6113, 6304}},
    {name = "Special", ids = {4600, 4900, 4901, 4902, 6106, 6111}},
}

-- Crosshair type dropdown: same table + order as imgui.combo (REFramework uses 0-based combo index).
local CROSSHAIR_TYPE_COMBO_LABELS = {"3D Crosshair", "Default"}

-- Match visible dropdown row (same index rule as imgui.combo for this script).
local function crosshair_combo_shows_default_crosshair()
  local i = default_crosshair_view_type
  return CROSSHAIR_TYPE_COMBO_LABELS[i + 1] == "Default"
end

-- Opposite of default-crosshair selection (same index rule as crosshair_combo_shows_default_crosshair).
local function crosshair_combo_shows_3d_crosshair()
  return not crosshair_combo_shows_default_crosshair()
end

-- Per-weapon laser trail enable (default all enabled)
local weapon_laser_enabled = {}

-- Persistent color arrays for imgui.color_edit4
local laser_beam_color_array = {1.0, 0.0, 0.0, 1.0}  -- RGBA values for laser beam (0.0-1.0)
local laser_dot_color_array = {1.0, 0.0, 0.0, 1.0}   -- RGBA values for laser dot (0.0-1.0)
local knife_dot_color_array = {1.0, 1.0, 1.0, 1.0}   -- RGBA values for knife/no-muzzle dot (0.0-1.0)
local static_reticle_color_array = {1.0, 1.0, 1.0, 1.0}  -- RGBA values for static reticle when weapon laser disabled (0.0-1.0)
local laser_color_array = laser_dot_color_array       -- Legacy compatibility
-- Focused-aim colors (chainsaw.Gun._IsReticleFitting): one table to stay under Lua's 200 main-chunk locals limit
local focused_laser_colors = {
  enabled = false,
  dot = {0.0, 1.0, 0.0, 1.0},
  beam = {0.0, 1.0, 0.0, 1.0},
  runtime_beam_sig = nil,
  match_focused_dot_beam = false, -- When focused-aim colors active: beam follows dot
  glow = LASER_DOT_GLOW_DEFAULT, -- ColorPanel saturation (dot glow) while focused (_IsReticleFitting)
}

local function sanitize_color_array(arr, fallback)
  local fb = fallback or {1.0, 1.0, 1.0, 1.0}
  if type(arr) ~= "table" then
    return {fb[1], fb[2], fb[3], fb[4] or 1.0}
  end
  return {
    tonumber(arr[1]) or fb[1],
    tonumber(arr[2]) or fb[2],
    tonumber(arr[3]) or fb[3],
    tonumber(arr[4]) or fb[4] or 1.0,
  }
end


local static_center_dot = false  -- New option for static center dot
local simple_static_mode = false  -- New option for completely static dot with no custom calculations
local cached_static_intersection_point = nil  -- Cache for camera-based intersection
local cached_static_surface_distance = 10.0  -- Cache for original surface distance
local cached_static_camera_pos = nil  -- Cache for camera position used in static dot
local static_attack_ray_result = nil  -- Persistent ray result for attack layer
local static_bullet_ray_result = nil  -- Persistent ray result for bullet layer
local stored_static_center_dot = nil  -- Cache user preference when forced overrides run
local stored_classic_for_default_crosshair = nil  -- Cache classic style when 3D Crosshair + laser toggle forces remake
local force_classic_re4_prev = false  -- Track previous force state to restore preference
local any_preset_active_prev = false  -- Track previous preset state to update hooks when presets change
local skip_trail_frames = 0  -- Frame counter to skip drawing trail after mode switch
local iron_sight_active_prev = false  -- Track iron sight active state (aiming) to update hooks
local force_disable_shoulder_prev = false  -- Track previous force disable state (IronSight or FP mode)
local last_crosshair_active_time = 0  -- Track when crosshair was last active for grace period
local last_laser_trail_active_time = 0  -- Track when laser trail was last active for grace period
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
    ["4400"] = {x = -0.027000000298023224, y = -0.0075, z = -0.0638000023841858},
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
    ["6114"] = {x = -0.027000000298023224, y = -0.0075, z = -0.0638000023841858},
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
-- Post-shot hide / dim laser state (single table to stay under Lua's 200 locals-per-chunk limit)
local post_shot = {
  hide_laser = false,
  timer_sec = 0.2,
  effect_until = 0.0,
  restrict_list = false,
  weapon_ids = {},
  firing_weapon_id = nil,
  dim_enabled = false,
  dim_restrict_list = false,
  dim_weapon_ids = {},
  dim_dot_scale = 0.95,
  dim_glow_saturation = 1.0, -- ColorPanel glow while post-shot dim laser is active
  dim_intensity_dim = 1.0, -- EmissiveIntensity during post-shot dim laser (matches material editor slider)
  -- Snapshot of _G.laser_mat_params beam fields per material name (same keys the UI uses); nil = not captured yet
  dim_mat_table_backup = nil,
  firing_mode = nil, -- "hide"|"dim" while post-shot window is active (set from hook)
  per_weapon = {}, -- [weaponIdStr] = { mode="global"|"off"|"hide"|"dim", timer_sec?, dim_dot_scale?, ... }
  match_main_dot_beam = false, -- Custom Colors: beam uses same RGBA as dot (normal aim)
  -- Handguns for hide-crosshair-after-shot only (hardcoded catalog IDs; names in comments)
  crosshair_hide_pistol_ids = {
    [4000] = true, -- SG-09 R
    [4001] = true, -- Punisher
    [4002] = true, -- Red9
    [4003] = true, -- Blacktail
    [4004] = true, -- Matilda
    [4005] = true, -- Minecart Handgun
    [4500] = true, -- Broken Butterfly
    [4501] = true, -- Killer7
    [4502] = true, -- Handcannon
    [6000] = true, -- Sentinel Nine
    [6103] = true, -- Blacktail AC
    [6112] = true, -- Punisher MC
    [6113] = true, -- Red9 SW
    [6300] = true, -- XM96E1
  },
  -- Pistol crosshair hide-after-shot (nested in post_shot for Lua main-chunk local limit)
  crosshair_after = { enabled = false, timer_sec = 0.25, effect_until = 0.0, weapon_id = nil },
}

-- Post-shot dim EmissiveIntensity UI + config use 0.05 steps (0–100)
local function snap_post_shot_dim_emissive(v)
  if type(v) ~= "number" then return v end
  return math.max(0.0, math.min(100.0, math.floor(v / 0.05 + 0.5) * 0.05))
end

local laser_trail_scale = 1.5   -- Scale of the laser trail
local laser_trail_gameobject = nil  -- Reference to the laser trail game object
local laser_mesh_resource = sdk.create_resource("via.render.MeshResource", "_chainsaw/character/wp/wp40/wp4000/21/wp4000_22.mesh")  -- Laser mesh resource
local laser_material_resource = sdk.create_resource("via.render.MeshMaterialResource", "LaserColors/classicRE4LaserMaterial.mdf2")  -- Laser material resource

local apply_laser_trail_settings  -- forward declaration; body assigned after save/load_config

-- Global hide / dim laser applies to every muzzle weapon; use Post-shot by weapon → Off to exclude one.
function post_shot.hide_applies_to_weapon_id_str(_wid_str)
  return true
end

function post_shot.dim_applies_to_weapon_id_str(_wid_str)
  return true
end

function post_shot.resolved_mode_for_weapon_id_str(wid_str)
  local row = post_shot.per_weapon and post_shot.per_weapon[wid_str]
  local m = (row and row.mode) or "global"
  if m == "off" then return "off" end
  -- Explicit per-weapon hide / dim laser: the row targets this weapon id; do not gate on global hide/dim laser.
  if m == "hide" then return "hide" end
  if m == "dim" then return "dim" end
  if post_shot.hide_laser and post_shot.hide_applies_to_weapon_id_str(wid_str) then return "hide" end
  if post_shot.dim_enabled and post_shot.dim_applies_to_weapon_id_str(wid_str) then return "dim" end
  return "off"
end

function post_shot.any_weapon_needs_hook()
  if not post_shot.per_weapon then return false end
  for wid_str, _ in pairs(post_shot.per_weapon) do
    if post_shot.resolved_mode_for_weapon_id_str(wid_str) ~= "off" then return true end
  end
  return false
end

function post_shot.hook_should_run()
  return post_shot.hide_laser or post_shot.dim_enabled or post_shot.any_weapon_needs_hook()
end

function post_shot.request_fire_hook_needed()
  return post_shot.hook_should_run() or (post_shot.crosshair_after and post_shot.crosshair_after.enabled)
end

-- True when the aim laser dot/trail is considered "on" (pistol crosshair hide-after-shot must not apply).
function post_shot.crosshair_reticle_hide_laser_is_on()
  if is_non_muzzle_weapon then return false end
  local wid = current_weapon_id or cached_weapon_id
  if not wid then return false end
  local wstr = tostring(wid)
  if weapon_laser_enabled[wstr] == false then return false end
  if not enable_laser_trail then return false end
  if not show_laser_dot then return false end
  return true
end

function post_shot.crosshair_hide_effectively_active()
  local ch = post_shot.crosshair_after
  if not ch or not ch.enabled then return false end
  if crosshair_combo_shows_3d_crosshair() then return false end
  if not ch.weapon_id or not post_shot.crosshair_hide_pistol_ids[ch.weapon_id] then return false end
  if post_shot.crosshair_reticle_hide_laser_is_on() then return false end
  if ch.effect_until <= 0.0 or os.clock() >= ch.effect_until then return false end
  local wid = current_weapon_id or cached_weapon_id
  if not wid or wid ~= ch.weapon_id then return false end
  return true
end

-- REFramework imgui.combo uses 1-based indices here (same as "Select Weapon" in this file), not 0-based like crosshair_view_type.
function post_shot.pw_mode_to_combo_idx(mode)
  if mode == "off" then return 2 end
  if mode == "hide" then return 3 end
  if mode == "dim" then return 4 end
  return 1
end

function post_shot.pw_combo_idx_to_mode(idx)
  if idx == 2 then return "off" end
  if idx == 3 then return "hide" end
  if idx == 4 then return "dim" end
  return "global"
end

function post_shot.effect_window_active()
  if not enable_laser_trail then return false end
  -- Do not use is_non_muzzle_weapon here: it can be stale for a frame after weapon swap before
  -- update_muzzle_and_laser_data runs, which would block dim try_capture on the same frame as requestFire.
  -- The post-shot hook already skips knives / non-muzzle via the same flag at fire time.
  if not current_weapon_id then return false end
  local wid = tostring(current_weapon_id)
  if weapon_laser_enabled[wid] == false then return false end
  if os.clock() >= post_shot.effect_until then return false end
  if not post_shot.firing_weapon_id or current_weapon_id ~= post_shot.firing_weapon_id then return false end
  if post_shot.firing_mode == "hide" then
    local pw = post_shot.per_weapon and post_shot.per_weapon[wid]
    if pw and pw.mode == "hide" then return true end
    return post_shot.hide_applies_to_weapon_id_str(wid)
  end
  if post_shot.firing_mode == "dim" then
    local pw = post_shot.per_weapon and post_shot.per_weapon[wid]
    if pw and pw.mode == "dim" then return true end
    return post_shot.dim_applies_to_weapon_id_str(wid)
  end
  return false
end

function post_shot.hide_effectively_active()
  return post_shot.firing_mode == "hide" and post_shot.effect_window_active()
end

function post_shot.dim_effectively_active()
  return post_shot.firing_mode == "dim" and post_shot.effect_window_active()
end

local function maybe_refresh_point_range_after_laser_gate_changed()
  if not perfect_focus_only_when_laser_active and not perfect_accuracy_only_when_laser_active then
    return
  end
  local e = classic_laser_active_for_perfect
  if classic_laser_trail_effective_prev == nil then
    classic_laser_trail_effective_prev = e
    return
  end
  if e ~= classic_laser_trail_effective_prev then
    classic_laser_trail_effective_prev = e
    if perfect_focus_only_when_laser_active then
      hasRunInitially = false
    end
    if perfect_accuracy_only_when_laser_active then
      force_spread_update = true
    end
  end
end

function post_shot.effective_dim_intensity()
  local wid = post_shot.firing_weapon_id and tostring(post_shot.firing_weapon_id) or nil
  local row = wid and post_shot.per_weapon and post_shot.per_weapon[wid]
  if row and row.dim_intensity_dim ~= nil then return row.dim_intensity_dim end
  return post_shot.dim_intensity_dim or 0.0
end

function post_shot.effective_dim_dot_scale()
  local wid = post_shot.firing_weapon_id and tostring(post_shot.firing_weapon_id) or nil
  local row = wid and post_shot.per_weapon and post_shot.per_weapon[wid]
  if row and row.dim_dot_scale ~= nil then return row.dim_dot_scale end
  return post_shot.dim_dot_scale
end

function post_shot.effective_dim_glow_saturation()
  local wid = post_shot.firing_weapon_id and tostring(post_shot.firing_weapon_id) or nil
  local row = wid and post_shot.per_weapon and post_shot.per_weapon[wid]
  local v = (row and row.dim_glow_saturation ~= nil) and row.dim_glow_saturation or (post_shot.dim_glow_saturation or 1.0)
  return math.max(1.0, math.min(100.0, v))
end

function post_shot.restore_dim_material_from_saved()
  if not post_shot.dim_mat_table_backup or not next(post_shot.dim_mat_table_backup) then
    post_shot.dim_mat_table_backup = nil
    return
  end
  _G.laser_mat_params = _G.laser_mat_params or {}
  for matName, snap in pairs(post_shot.dim_mat_table_backup) do
    if not _G.laser_mat_params[matName] then _G.laser_mat_params[matName] = {} end
    if snap.EmissiveIntensity ~= nil then
      _G.laser_mat_params[matName].EmissiveIntensity = snap.EmissiveIntensity
    end
  end
  apply_laser_trail_settings()
  -- Direct mesh write using captured indices (covers type-id mismatches apply_laser_trail_settings can miss)
  local go = laser_trail_gameobject
  if go and go.get_Valid and go:get_Valid() then
    local mc = go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    if mc and mc.setMaterialFloat then
      for _, snap in pairs(post_shot.dim_mat_table_backup) do
        if snap.jkI and snap.EmissiveIntensity ~= nil then
          local jj, kk, v = snap.jkI[1], snap.jkI[2], snap.EmissiveIntensity
          pcall(function() mc:setMaterialFloat(jj, kk, v) end)
        end
      end
    end
  end
  post_shot.dim_mat_table_backup = nil
end

-- Same data path as the Laser Beam Material Editor sliders: _G.laser_mat_params + apply_laser_trail_settings()
-- After setMesh/set_Material (trail recreate), (j,k) indices change; refresh from names, keep snapshot restore values.
function post_shot.refresh_dim_jk_indices(mc)
  if not post_shot.dim_mat_table_backup or not mc or not mc.get_MaterialNum or not mc.getMaterialVariableNum
      or not mc.getMaterialVariableName then
    return
  end
  for matName, snap in pairs(post_shot.dim_mat_table_backup) do
    local matCount = mc:get_MaterialNum()
    for j = 0, matCount - 1 do
      if mc:getMaterialName(j) == matName then
        local matParam = mc:getMaterialVariableNum(j)
        for k = 0, matParam - 1 do
          local paramName = mc:getMaterialVariableName(j, k)
          if paramName == "EmissiveIntensity" and snap.EmissiveIntensity ~= nil then
            snap.jkI = { j, k }
          end
        end
        break
      end
    end
  end
end

function post_shot.try_capture_and_dim_emissive()
  if not post_shot.dim_effectively_active() then return end
  local go = laser_trail_gameobject
  if not go or not go.get_Valid or not go:get_Valid() then
    return
  end
  local mc = go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
  if not mc or not mc.get_MaterialNum or not mc.getMaterialVariableNum or not mc.getMaterialVariableName then
    return
  end
  _G.laser_mat_params = _G.laser_mat_params or {}

  if post_shot.dim_mat_table_backup == nil then
    local accum = {}
    local matCount = mc:get_MaterialNum()
    for j = 0, matCount - 1 do
      local matName = mc:getMaterialName(j)
      if matName then
        if not _G.laser_mat_params[matName] then _G.laser_mat_params[matName] = {} end
        local snap = {}
        local matParam = mc:getMaterialVariableNum(j)
        for k = 0, matParam - 1 do
          local paramName = mc:getMaterialVariableName(j, k)
          if paramName == "EmissiveIntensity" and (mc.getMaterialFloat or mc.call) then
            local okf, cur = pcall(function() return mc:getMaterialFloat(j, k) end)
            if (not okf or type(cur) ~= "number") and mc.call then
              okf, cur = pcall(function() return mc:call("getMaterialFloat", j, k) end)
            end
            if okf and type(cur) == "number" then
              if _G.laser_mat_params[matName].EmissiveIntensity == nil then
                _G.laser_mat_params[matName].EmissiveIntensity = cur
              end
              snap.EmissiveIntensity = _G.laser_mat_params[matName].EmissiveIntensity
              snap.jkI = { j, k }
            end
          end
        end
        if snap.EmissiveIntensity ~= nil then
          accum[matName] = snap
        end
      end
    end
    if next(accum) then
      post_shot.dim_mat_table_backup = accum
    end
  else
    post_shot.refresh_dim_jk_indices(mc)
  end

  if post_shot.dim_mat_table_backup and next(post_shot.dim_mat_table_backup) then
    local dim_i = post_shot.effective_dim_intensity()
    for matName, snap in pairs(post_shot.dim_mat_table_backup) do
      if not _G.laser_mat_params[matName] then _G.laser_mat_params[matName] = {} end
      if snap.EmissiveIntensity ~= nil then
        _G.laser_mat_params[matName].EmissiveIntensity = dim_i
      end
    end
    apply_laser_trail_settings()
    -- Direct mesh write (indices from capture; avoids material-name / type-id mismatches)
    if mc.setMaterialFloat then
      for _, snap in pairs(post_shot.dim_mat_table_backup) do
        if snap.jkI then
          local jj, kk = snap.jkI[1], snap.jkI[2]
          pcall(function() mc:setMaterialFloat(jj, kk, dim_i) end)
        end
      end
    end
  end
end

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
local _dot_panel_field = "TYPE01Panel"

-- Global variable to track hold variation state
local is_hold_variation = false

-- Hook management variables
local is_hooks_active = false
local bullet_hook = nil
local last_hook_conditions = false -- Track previous state to detect changes

-- Weapon firing hook functions for hold variation correction
local function on_pre_request_fire(args)
  -- Only modify bullet spawn when conditions are met:
  -- 1. Bolt Thrower hold variation (weapon 4600 with is_hold_variation)
  -- 2. IronSight active + Preset active + laser disabled for weapon
  local is_ironsight_active = (rawget(_G, "standalone_iron_sight_active") == true)
  local preset_a_active = (rawget(_G, "custom_aim_preset_a_active") == true)
  local preset_b_active = (rawget(_G, "custom_aim_preset_b_active") == true)
  local preset_c_active = (rawget(_G, "custom_aim_preset_c_active") == true)
  local preset_d_active = (rawget(_G, "custom_aim_preset_d_active") == true)
  local any_preset_active = preset_a_active or preset_b_active or preset_c_active or preset_d_active
  local weapon_id_str = tostring(current_weapon_id)
  local laser_disabled_for_weapon = weapon_laser_enabled[weapon_id_str] == false
  
  local should_modify = (is_hold_variation and current_weapon_id == 4600) or 
                        (is_ironsight_active and any_preset_active and laser_disabled_for_weapon)
  
  if not should_modify then
    return -- Don't modify bullet spawn
  end
  
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

local post_shot_hide_hooks_installed = false
local function install_post_shot_laser_hide_hooks()
  if post_shot_hide_hooks_installed then return end
  if not post_shot.request_fire_hook_needed() then return end
  -- Pre-requestFire: hide as soon as the game commits a shot (post runs after draw, ~1 frame late).
  local function on_pre_request_fire_hide_laser(args)
    local ps_laser = post_shot.hook_should_run()
    local ch = post_shot.crosshair_after and post_shot.crosshair_after.enabled
    if not ps_laser and not ch then return end
    if ch and not crosshair_combo_shows_3d_crosshair() and not is_non_muzzle_weapon and not post_shot.crosshair_reticle_hide_laser_is_on() then
      local wid = current_weapon_id or cached_weapon_id
      if wid and post_shot.crosshair_hide_pistol_ids[wid] then
        local c = post_shot.crosshair_after
        c.weapon_id = wid
        c.effect_until = os.clock() + math.max(0.01, math.min(10.0, tonumber(c.timer_sec) or 0.25))
      end
    end
    if not ps_laser then return end
    if not current_weapon_id or is_non_muzzle_weapon then return end
    local wid = tostring(current_weapon_id)
    if weapon_laser_enabled[wid] == false then return end
    if not enable_laser_trail then return end
    local resolved = post_shot.resolved_mode_for_weapon_id_str(wid)
    if resolved == "off" then return end
    post_shot.firing_mode = resolved
    post_shot.firing_weapon_id = current_weapon_id
    local pw = post_shot.per_weapon and post_shot.per_weapon[wid]
    local t = post_shot.timer_sec
    if pw and pw.timer_sec ~= nil then
      t = tonumber(pw.timer_sec) or t
    end
    post_shot.effect_until = os.clock() + math.max(0.01, t or 0.01)
    if resolved == "hide" and laser_trail_gameobject and laser_trail_gameobject.get_Valid and laser_trail_gameobject:get_Valid() then
      pcall(function() laser_trail_gameobject:set_DrawSelf(false) end)
    end
    if resolved == "dim" then
      post_shot.try_capture_and_dim_emissive()
    end
  end
  local hooked = false
  pcall(function()
    local td = sdk.find_type_definition(sdk.game_namespace("BulletShellGenerator"))
    if td then
      local m = td:get_method("requestFire")
      if m then sdk.hook(m, on_pre_request_fire_hide_laser, nil); hooked = true end
    end
  end)
  pcall(function()
    local td = sdk.find_type_definition(sdk.game_namespace("ShotgunShellGenerator"))
    if td then
      local m = td:get_method("requestFire")
      if m then sdk.hook(m, on_pre_request_fire_hide_laser, nil); hooked = true end
    end
  end)
  if hooked then post_shot_hide_hooks_installed = true end
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

-- ============================================================================
-- FP Mode Head Spawn Hook
-- Handles head bullet spawn for:
-- 1. Iron sight active (muzzle spawn)
-- 2. Weapon 4005 (Minecart Handgun) when FP mode active (head spawn)
-- 3. Any weapon when FP mode + RE4 Remake style laser active (head spawn)
-- 4. Weapon with laser disabled + preset active (head spawn)
-- 5. Weapon with laser disabled + Classic style (head spawn)
-- ============================================================================
local wp4005_hook = nil
local shotgun_hook = nil  -- Separate hook for shotguns (ShotgunShellGenerator)
local prev_fp_active_for_hook = false  -- Track FP mode state for hook management
local prev_remake_style_for_hook = false  -- Track Remake style state for hook management
local prev_preset_laser_disabled_for_hook = false  -- Track preset + laser disabled state
local prev_classic_laser_disabled_for_hook = false  -- Track Classic style + laser disabled state
local prev_ironsight_laser_disabled_for_hook = false  -- Track iron sight + laser disabled state
local prev_any_preset_for_hook = false  -- Track any preset active state

-- Cached head joint for performance (refreshed when body changes)
local cached_head_joint = nil
local cached_head_joint_body = nil

-- Helper function to get player head joint (cached)
local function get_player_head_joint()
    local body = re4.body
    if not body then 
        cached_head_joint = nil
        cached_head_joint_body = nil
        return nil 
    end
    
    -- Return cached joint if body hasn't changed and joint is still valid
    if cached_head_joint and cached_head_joint_body == body then
        if is_valid_managed(cached_head_joint) then
            return cached_head_joint
        end
    end
    
    -- Need to find the head joint
    local transform = body:call("get_Transform")
    if not transform then return nil end
    
    local joints = transform:call("get_Joints")
    if not joints then return nil end
    
    local count = joints:get_size()
    
    for i = 0, count - 1 do
        local joint = joints:get_element(i)
        if joint then
            local jname = joint:call("get_Name")
            if jname then
                local name_str = tostring(jname):lower()
                if name_str:find("head") then
                    cached_head_joint = joint
                    cached_head_joint_body = body
                    return joint
                end
            end
        end
    end
    return nil
end

-- Alias for backwards compatibility
local function get_player_head_joint_for_4005()
    return get_player_head_joint()
end

-- Helper function to get camera forward direction
local function get_camera_forward_for_4005()
    local camera = sdk.get_primary_camera()
    if not camera then return nil end
    
    local camera_mat = camera:get_WorldMatrix()
    if not camera_mat then return nil end
    
    local camera_rot = camera_mat:to_quat()
    if not camera_rot then return nil end
    
    local forward = (camera_rot * Vector3f.new(0, 0, -1)):normalized()
    return forward
end

-- Hook callback for FP mode bullet spawn
-- Handles:
-- 1. Iron sight active → muzzle spawn
-- 2. Weapon 4005 in FP mode → head spawn
-- 3. Any weapon with FP mode + RE4 Remake style laser → head spawn
-- 4. Weapon with laser disabled + preset active → head spawn
-- 5. Weapon with laser disabled (Classic style) → head spawn
-- 6. Iron sight + laser disabled → muzzle spawn
local function on_pre_request_fire_4005(args)
    local ironsight_active = rawget(_G, "standalone_iron_sight_active") == true
    local fp_active = rawget(_G, "standalone_first_person_active") == true
    
    -- Get weapon ID from shell generator's owner name
    local current_wid = nil
    local shell_generator = sdk.to_managed_object(args[2])
    if shell_generator then
        local owner = shell_generator:get_field("_Owner")
        if owner then
            local owner_name = owner:call("get_Name")
            if owner_name then
                local wid_str = tostring(owner_name):match("wp(%d+)")
                if wid_str then
                    current_wid = tonumber(wid_str)
                end
            end
        end
    end
    
    -- Check if weapon has laser disabled
    local wid_str = current_wid and tostring(current_wid) or "unknown"
    local laser_disabled = weapon_laser_enabled[wid_str] == false
    
    -- Iron sight + laser disabled = muzzle spawn (works without FP mode)
    if ironsight_active and laser_disabled then
        if current_muzzle_joint then
            local spawn_pos = joint_get_position(current_muzzle_joint)
            if spawn_pos then
                local muzzle_forward = current_muzzle_joint:call("get_AxisZ")
                if muzzle_forward then
                    -- Set bullet spawn position to muzzle
                    local pos_addr = sdk.to_ptr(sdk.to_int64(args[3]))
                    if pos_addr and vec3_set_item then
                        vec3_set_item:call(pos_addr, 0, spawn_pos.x)
                        vec3_set_item:call(pos_addr, 1, spawn_pos.y)
                        vec3_set_item:call(pos_addr, 2, spawn_pos.z)
                    end
                    
                    -- Set bullet direction to muzzle forward
                    local rot_addr = sdk.to_ptr(sdk.to_int64(args[4]))
                    if rot_addr and quat_set_item then
                        local new_rotation = muzzle_forward:to_quat()
                        quat_set_item:call(rot_addr, 0, new_rotation.x)
                        quat_set_item:call(rot_addr, 1, new_rotation.y)
                        quat_set_item:call(rot_addr, 2, new_rotation.z)
                        quat_set_item:call(rot_addr, 3, new_rotation.w)
                    end
                end
            end
        end
        return  -- Done with iron sight + laser disabled case
    end
    
    -- If iron sight is active but laser is NOT disabled, don't modify spawn
    if ironsight_active then
        return
    end
    
    -- Remaining logic requires FP mode
    if not fp_active then return end
    
    -- Check other conditions (head spawn)
    local is_4005 = (current_wid == 4005)
    local is_remake_style = static_center_dot == true
    local is_classic_style = not is_remake_style
    
    -- Check if preset is active (for preset + laser disabled condition)
    local preset_a_active = rawget(_G, "custom_aim_preset_a_active") == true
    local preset_b_active = rawget(_G, "custom_aim_preset_b_active") == true
    local preset_c_active = rawget(_G, "custom_aim_preset_c_active") == true
    local preset_d_active = rawget(_G, "custom_aim_preset_d_active") == true
    local any_preset_active = preset_a_active or preset_b_active or preset_c_active or preset_d_active
    local use_head_for_preset_laser_disabled = laser_disabled and any_preset_active
    
    -- Classic style + laser disabled = head spawn (no preset required)
    local use_head_for_classic_laser_disabled = is_classic_style and laser_disabled
    
    -- Determine if we should modify bullet spawn at all
    -- Remake style uses head spawn in FP mode (ironsight handled above)
    local use_head_for_remake = is_remake_style
    local should_use_head = use_head_for_preset_laser_disabled or use_head_for_classic_laser_disabled or is_4005 or use_head_for_remake
    if not should_use_head then return end
    
    -- Get head joint for spawn position
    local head_joint = get_player_head_joint()
    if not head_joint then return end
    local spawn_pos = joint_get_position(head_joint)
    if not spawn_pos then return end
    
    -- Apply head camera offset from FirstPersonMode (in head local space)
    local fp_head_offset = rawget(_G, "standalone_fp_head_offset")
    if fp_head_offset and (fp_head_offset.x ~= 0 or fp_head_offset.y ~= 0 or fp_head_offset.z ~= 0) then
        -- Get axes directly (no pcall closures for performance)
        local axis_x = head_joint:call("get_AxisX")
        local axis_y = head_joint:call("get_AxisY")
        local axis_z = head_joint:call("get_AxisZ")
        
        if axis_x and axis_y and axis_z then
            local offset_world = (axis_x * fp_head_offset.x) + (axis_y * fp_head_offset.y) + (axis_z * fp_head_offset.z)
            spawn_pos = spawn_pos + offset_world
        else
            -- Fallback to world space offset if axes unavailable
            spawn_pos = spawn_pos + Vector3f.new(fp_head_offset.x, fp_head_offset.y, fp_head_offset.z)
        end
    end
    
    local spawn_forward = get_camera_forward_for_4005()
    if not spawn_forward then return end
    
    -- Set bullet spawn position to head (using cached methods for performance)
    local pos_addr = sdk.to_ptr(sdk.to_int64(args[3]))
    if pos_addr and vec3_set_item then
        vec3_set_item:call(pos_addr, 0, spawn_pos.x)
        vec3_set_item:call(pos_addr, 1, spawn_pos.y)
        vec3_set_item:call(pos_addr, 2, spawn_pos.z)
    end
    
    -- Set bullet direction to camera forward (using cached methods for performance)
    local rot_addr = sdk.to_ptr(sdk.to_int64(args[4]))
    if rot_addr and quat_set_item then
        local new_rotation = spawn_forward:to_quat()
        quat_set_item:call(rot_addr, 0, new_rotation.x)
        quat_set_item:call(rot_addr, 1, new_rotation.y)
        quat_set_item:call(rot_addr, 2, new_rotation.z)
        quat_set_item:call(rot_addr, 3, new_rotation.w)
    end
end

local function on_post_request_fire_4005(retval)
    return retval
end

-- Register FP mode head spawn hook (handles 4005 and all weapons with FP + Remake style)
local function init_fp_head_spawn_hook()
    -- Hook BulletShellGenerator (pistols, rifles, etc.)
    if not wp4005_hook then
        local bullet_shell_generator_t = sdk.find_type_definition(sdk.game_namespace("BulletShellGenerator"))
        if bullet_shell_generator_t then
            local method = bullet_shell_generator_t:get_method("requestFire")
            if method then
                wp4005_hook = sdk.hook(method, on_pre_request_fire_4005, on_post_request_fire_4005)
            end
        end
    end
    
    -- Hook ShotgunShellGenerator (shotguns like 4100, 4101, etc.)
    if not shotgun_hook then
        local shotgun_shell_generator_t = sdk.find_type_definition(sdk.game_namespace("ShotgunShellGenerator"))
        if shotgun_shell_generator_t then
            local method = shotgun_shell_generator_t:get_method("requestFire")
            if method then
                shotgun_hook = sdk.hook(method, on_pre_request_fire_4005, on_post_request_fire_4005)
            end
        end
    end
end

-- Alias for backwards compatibility
local function init_4005_hook()
    init_fp_head_spawn_hook()
end

-- Unhook all bullet spawn hooks
local function unhook_4005_hook()
    if wp4005_hook then
        wp4005_hook:unhook()
        wp4005_hook = nil
    end
    if shotgun_hook then
        shotgun_hook:unhook()
        shotgun_hook = nil
    end
end

-- ============================================================================

-- Function to manage hooks based on conditions (only when conditions change)
local function manage_hooks(force_check)
  -- Check if laser is enabled for current weapon
  local weapon_id_str = tostring(current_weapon_id)
  local laser_disabled_for_weapon = weapon_laser_enabled[weapon_id_str] == false
  local laser_enabled_for_weapon = weapon_laser_enabled[weapon_id_str] ~= false  -- Default true if nil
  
  -- Check if IronSight + Preset mode is active (needs hook for muzzle spawns)
  -- Use standalone_iron_sight_active which is set when iron sight is actually active (aiming)
  local is_ironsight_active = (rawget(_G, "standalone_iron_sight_active") == true)
  local fp_active = (rawget(_G, "standalone_first_person_active") == true)
  local preset_a_active = (rawget(_G, "custom_aim_preset_a_active") == true)
  local preset_b_active = (rawget(_G, "custom_aim_preset_b_active") == true)
  local preset_c_active = (rawget(_G, "custom_aim_preset_c_active") == true)
  local preset_d_active = (rawget(_G, "custom_aim_preset_d_active") == true)
  local any_preset_active = preset_a_active or preset_b_active or preset_c_active or preset_d_active
  -- Hook only when IronSight is active AND a preset is active AND laser is disabled for weapon
  local ironsight_preset_override = is_ironsight_active and any_preset_active and laser_disabled_for_weapon
  
  -- Don't apply hook logic if static center dot (RE4 Remake style) is enabled
  -- OR if laser is disabled for current weapon WITHOUT IronSight+Preset override
  if static_center_dot or (laser_disabled_for_weapon and not ironsight_preset_override) then
    -- If hooks are currently active but static/disabled mode is enabled, unhook them
    if is_hooks_active then
      unhook_request_fire()
    end
    last_hook_conditions = false
    return
  end
  
  -- Hook if: Bolt Thrower hold variation OR IronSight+Preset with laser-disabled weapon
  local should_hook = (is_hold_variation and current_weapon_id == 4600) or ironsight_preset_override
  
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
      hide_dot_when_no_muzzle = hide_dot_when_no_muzzle,
      show_default_crosshair_laser_off = show_default_crosshair_laser_off,
      default_crosshair_color_array = default_crosshair_color_array,
      default_crosshair_match_laser = default_crosshair_match_laser,
      default_crosshair_saturation = default_crosshair_saturation,
      default_crosshair_view_type = default_crosshair_view_type,
      default_crosshair_overlay = default_crosshair_overlay,
      default_crosshair_detonemap = default_crosshair_detonemap,
      default_crosshair_depth_test = default_crosshair_depth_test,
      crosshair_hide_after_shot = post_shot.crosshair_after.enabled,
      crosshair_hide_after_shot_timer_sec = post_shot.crosshair_after.timer_sec,
      enable_laser_trail = enable_laser_trail,  -- Add laser trail settings
      laser_trail_scale = laser_trail_scale,
      hide_laser_after_shot = post_shot.hide_laser,
      hide_laser_after_shot_timer_sec = post_shot.timer_sec,
      hide_laser_after_shot_restrict_to_list = false,
      hide_laser_after_shot_weapon_ids = {},
      post_shot_temp_dim_dot_beam = post_shot.dim_enabled,
      post_shot_dim_restrict_to_list = false,
      post_shot_dim_weapon_ids = {},
      post_shot_dim_dot_scale = post_shot.dim_dot_scale,
      post_shot_dim_glow_saturation = post_shot.dim_glow_saturation,
      post_shot_dim_intensity = post_shot.dim_intensity_dim,
      post_shot_per_weapon = post_shot.per_weapon,
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
      focused_laser_separate = focused_laser_colors.enabled,
      focused_laser_dot = focused_laser_colors.dot,
      focused_laser_beam = focused_laser_colors.beam,
      focused_laser_match_dot_beam = focused_laser_colors.match_focused_dot_beam,
      focused_laser_glow = focused_laser_colors.glow,
      match_main_dot_beam = post_shot.match_main_dot_beam,
      weapon_laser_enabled = weapon_laser_enabled,  -- Per-weapon laser enable
      perfect_accuracy_enabled = _G.classic_re4_laser_perfect_accuracy_enabled,  -- Perfect accuracy setting
      point_range_enabled = _G.classic_re4_laser_point_range_enabled,  -- Point range setting
      perfect_accuracy_only_when_laser_active = perfect_accuracy_only_when_laser_active,
      perfect_focus_only_when_laser_active = perfect_focus_only_when_laser_active,
  }
  local success, err = pcall(json.dump_file, config_file, data)
  if not success then
      --log.info("OGRE4LaserDot: Error saving config: " .. tostring(err))
  end
end


-- Apply loaded laser trail material params to the mesh/material
apply_laser_trail_settings = function()
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
                if paramType == 1 and mesh_component.setMaterialFloat then
                  pcall(function() mesh_component:setMaterialFloat(j, k, value) end)
                elseif paramType == 4 and type(value) == "table" and mesh_component.setMaterialFloat4 then
                  local v4 = Vector4f.new(value[1], value[2], value[3], value[4])
                  pcall(function() mesh_component:setMaterialFloat4(j, k, v4) end)
                elseif paramName == "EmissiveIntensity" and type(value) == "number" and mesh_component.setMaterialFloat then
                  -- Some builds report a non-1 type for this float; still push the value (same as material UI intent)
                  pcall(function() mesh_component:setMaterialFloat(j, k, value) end)
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
-- persist_mat_params: when false, only updates the live mesh (runtime reticle-fitting tint); default true also writes _G.laser_mat_params for save/editor.
local function apply_beam_color(color_array, persist_mat_params)
  if persist_mat_params == nil then persist_mat_params = true end
  if not laser_trail_gameobject then return end
  local mesh_component = laser_trail_gameobject:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
  if not mesh_component or not mesh_component.setMaterialFloat4 then return end
  
  local matCount = mesh_component:get_MaterialNum()
  local did_write = false
  for j = 0, matCount - 1 do
    local matName = mesh_component:getMaterialName(j)
    local matParam = mesh_component:getMaterialVariableNum(j)
    for k = 0, matParam - 1 do
      local paramName = mesh_component:getMaterialVariableName(j, k)
      if paramName == "EmissiveColor" then
        local color_vector = Vector4f.new(color_array[1], color_array[2], color_array[3], color_array[4])
        mesh_component:setMaterialFloat4(j, k, color_vector)
        did_write = true
        if persist_mat_params then
          if not _G.laser_mat_params then _G.laser_mat_params = {} end
          if not _G.laser_mat_params[matName] then _G.laser_mat_params[matName] = {} end
          _G.laser_mat_params[matName][paramName] = {color_array[1], color_array[2], color_array[3], color_array[4]}
        end
        break
      end
    end
  end
  if did_write then
    focused_laser_colors.runtime_beam_sig = string.format("%s|%g|%g|%g|%g", tostring(persist_mat_params), color_array[1], color_array[2], color_array[3], color_array[4] or 1.0)
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
  simple_static_mode = false -- disabled; always override any saved value
  hide_dot_when_no_muzzle = data.hide_dot_when_no_muzzle or hide_dot_when_no_muzzle
  if data.show_default_crosshair_laser_off ~= nil then
    show_default_crosshair_laser_off = data.show_default_crosshair_laser_off
  end
  if data.default_crosshair_color_array then
    default_crosshair_color_array = sanitize_color_array(data.default_crosshair_color_array, default_crosshair_color_array)
  end
  if data.default_crosshair_match_laser ~= nil then default_crosshair_match_laser = data.default_crosshair_match_laser end
  if data.default_crosshair_saturation ~= nil then default_crosshair_saturation = data.default_crosshair_saturation end
  if data.default_crosshair_view_type ~= nil then default_crosshair_view_type = data.default_crosshair_view_type end
  if data.default_crosshair_overlay ~= nil then default_crosshair_overlay = data.default_crosshair_overlay end
  if data.default_crosshair_detonemap ~= nil then default_crosshair_detonemap = data.default_crosshair_detonemap end
  if data.default_crosshair_depth_test ~= nil then default_crosshair_depth_test = data.default_crosshair_depth_test end
  if data.crosshair_hide_after_shot ~= nil then post_shot.crosshair_after.enabled = data.crosshair_hide_after_shot == true end
  if data.crosshair_hide_after_shot_timer_sec ~= nil then
    post_shot.crosshair_after.timer_sec = math.max(0.01, math.min(10.0, tonumber(data.crosshair_hide_after_shot_timer_sec) or 0.25))
  end
  enable_laser_trail = data.enable_laser_trail or enable_laser_trail
  laser_trail_scale = data.laser_trail_scale or laser_trail_scale
  if data.hide_laser_after_shot ~= nil then post_shot.hide_laser = data.hide_laser_after_shot end
  if data.hide_laser_after_shot_timer_sec ~= nil then
    post_shot.timer_sec = math.max(0.01, math.min(10.0, tonumber(data.hide_laser_after_shot_timer_sec) or 0.2))
  end
  -- Legacy keys hide_laser_after_shot_restrict_to_list / weapon_ids / dim list: ignored; use per-weapon Off to exclude.
  post_shot.restrict_list = false
  post_shot.dim_restrict_list = false
  post_shot.weapon_ids = {}
  post_shot.dim_weapon_ids = {}
  if data.post_shot_temp_dim_dot_beam ~= nil then post_shot.dim_enabled = data.post_shot_temp_dim_dot_beam == true end
  if data.post_shot_dim_dot_scale ~= nil then
    post_shot.dim_dot_scale = math.max(0.0, math.min(2.0, tonumber(data.post_shot_dim_dot_scale) or post_shot.dim_dot_scale))
  end
  if data.post_shot_dim_glow_saturation ~= nil then
    post_shot.dim_glow_saturation = math.max(1.0, math.min(100.0, tonumber(data.post_shot_dim_glow_saturation) or post_shot.dim_glow_saturation))
  end
  if data.post_shot_dim_intensity ~= nil then
    post_shot.dim_intensity_dim = snap_post_shot_dim_emissive(tonumber(data.post_shot_dim_intensity) or post_shot.dim_intensity_dim)
  end
  post_shot.per_weapon = {}
  if type(data.post_shot_per_weapon) == "table" then
    for k, v in pairs(data.post_shot_per_weapon) do
      if type(k) == "string" and type(v) == "table" then
        local mode = v.mode
        if mode ~= "global" and mode ~= "off" and mode ~= "hide" and mode ~= "dim" then mode = "global" end
        local row = { mode = mode }
        if type(v.timer_sec) == "number" then
          row.timer_sec = math.max(0.01, math.min(10.0, v.timer_sec))
        end
        if type(v.dim_dot_scale) == "number" then
          row.dim_dot_scale = math.max(0.0, math.min(2.0, v.dim_dot_scale))
        end
        if type(v.dim_glow_saturation) == "number" then
          row.dim_glow_saturation = math.max(1.0, math.min(100.0, v.dim_glow_saturation))
        end
        if type(v.dim_intensity_dim) == "number" then
          row.dim_intensity_dim = snap_post_shot_dim_emissive(v.dim_intensity_dim)
        end
        post_shot.per_weapon[k] = row
      end
    end
  end
  knife_dot_scale = data.knife_dot_scale or knife_dot_scale
  
  -- Load separate beam and dot colors
  if data.laser_beam_color_array then
    laser_beam_color_array = sanitize_color_array(data.laser_beam_color_array, laser_beam_color_array)
  else
    laser_beam_color_array = sanitize_color_array(laser_beam_color_array, laser_beam_color_array)
  end
  if data.laser_dot_color_array then
    laser_dot_color_array = sanitize_color_array(data.laser_dot_color_array, laser_dot_color_array)
  else
    laser_dot_color_array = sanitize_color_array(laser_dot_color_array, laser_dot_color_array)
  end
  if data.knife_dot_color_array then
    knife_dot_color_array = sanitize_color_array(data.knife_dot_color_array, knife_dot_color_array)
  else
    knife_dot_color_array = sanitize_color_array(knife_dot_color_array, knife_dot_color_array)
  end
  if data.static_reticle_color_array then
    static_reticle_color_array = sanitize_color_array(data.static_reticle_color_array, static_reticle_color_array)
  else
    static_reticle_color_array = sanitize_color_array(static_reticle_color_array, static_reticle_color_array)
  end
  -- Legacy compatibility - if old laser_color_array exists but new ones don't
  if data.laser_color_array and not data.laser_beam_color_array and not data.laser_dot_color_array then
    laser_beam_color_array = sanitize_color_array({data.laser_color_array[1], data.laser_color_array[2], data.laser_color_array[3], data.laser_color_array[4]}, laser_beam_color_array)
    laser_dot_color_array = sanitize_color_array({data.laser_color_array[1], data.laser_color_array[2], data.laser_color_array[3], data.laser_color_array[4]}, laser_dot_color_array)
  end
  laser_color_array = laser_dot_color_array -- Keep legacy compatibility

  if data.focused_laser_separate ~= nil then
    focused_laser_colors.enabled = data.focused_laser_separate == true
  elseif data.reticle_fitting_laser_colors ~= nil then
    focused_laser_colors.enabled = data.reticle_fitting_laser_colors == true
  end
  if data.focused_laser_dot then
    focused_laser_colors.dot = sanitize_color_array(data.focused_laser_dot, focused_laser_colors.dot)
  elseif data.laser_dot_reticle_fitting_color_array then
    focused_laser_colors.dot = sanitize_color_array(data.laser_dot_reticle_fitting_color_array, focused_laser_colors.dot)
  else
    focused_laser_colors.dot = sanitize_color_array(focused_laser_colors.dot, focused_laser_colors.dot)
  end
  if data.focused_laser_beam then
    focused_laser_colors.beam = sanitize_color_array(data.focused_laser_beam, focused_laser_colors.beam)
  elseif data.laser_beam_reticle_fitting_color_array then
    focused_laser_colors.beam = sanitize_color_array(data.laser_beam_reticle_fitting_color_array, focused_laser_colors.beam)
  else
    focused_laser_colors.beam = sanitize_color_array(focused_laser_colors.beam, focused_laser_colors.beam)
  end
  if data.focused_laser_match_dot_beam ~= nil then
    focused_laser_colors.match_focused_dot_beam = data.focused_laser_match_dot_beam == true
  elseif data.reticle_fitting_match_focused_dot_beam ~= nil then
    focused_laser_colors.match_focused_dot_beam = data.reticle_fitting_match_focused_dot_beam == true
  elseif data.reticle_fitting_match_scoped_dot_beam ~= nil then
    focused_laser_colors.match_focused_dot_beam = data.reticle_fitting_match_scoped_dot_beam == true
  end
  if data.focused_laser_glow ~= nil then
    focused_laser_colors.glow = math.max(0.0, math.min(100.0, tonumber(data.focused_laser_glow) or focused_laser_colors.glow))
  elseif data.reticle_fitting_glow ~= nil then
    focused_laser_colors.glow = math.max(0.0, math.min(100.0, tonumber(data.reticle_fitting_glow) or focused_laser_colors.glow))
  end
  if data.match_main_dot_beam ~= nil then
    post_shot.match_main_dot_beam = data.match_main_dot_beam == true
  end
  if post_shot.match_main_dot_beam then
    laser_beam_color_array = {
      laser_dot_color_array[1], laser_dot_color_array[2], laser_dot_color_array[3],
      laser_dot_color_array[4] or 1.0,
    }
  end
  if focused_laser_colors.match_focused_dot_beam then
    focused_laser_colors.beam = {
      focused_laser_colors.dot[1], focused_laser_colors.dot[2], focused_laser_colors.dot[3],
      focused_laser_colors.dot[4] or 1.0,
    }
  end
  focused_laser_colors.runtime_beam_sig = nil
  
  if data.laser_origin_offsets then
    laser_origin_offsets = data.laser_origin_offsets
  end
  if data.laser_mat_params then
    _G.laser_mat_params = data.laser_mat_params
  end
  if data.weapon_laser_enabled then
    weapon_laser_enabled = data.weapon_laser_enabled
  end
  
  -- Load perfect accuracy setting
  if data.perfect_accuracy_enabled ~= nil then
    _G.classic_re4_laser_perfect_accuracy_enabled = data.perfect_accuracy_enabled
  end
  
  -- Load point range setting
  if data.point_range_enabled ~= nil then
    _G.classic_re4_laser_point_range_enabled = data.point_range_enabled
  end
  if data.perfect_accuracy_only_when_laser_active ~= nil then
    perfect_accuracy_only_when_laser_active = data.perfect_accuracy_only_when_laser_active == true
  end
  if data.perfect_focus_only_when_laser_active ~= nil then
    perfect_focus_only_when_laser_active = data.perfect_focus_only_when_laser_active == true
  end
  classic_laser_trail_effective_prev = nil

  -- Update global flag for other mods to know Classic vs Remake bullet spawn per weapon
  update_spawn_flag()
  
  apply_laser_trail_settings()
  return true
end

local function write_valuetype(parent_obj, offset, value)                       
  for i = 0, value.type:get_valuetype_size() - 1 do
    parent_obj:write_byte(offset + i, value:read_byte(i))
  end
end

-- Perfect accuracy helper function
local function is_perfect_accuracy_enabled()
    -- Only check IronSight's PA flag when IronSight is actually active
    local ironsight_active = rawget(_G, "standalone_iron_sight_active") == true
    if ironsight_active then
        local ironsight_pa = rawget(_G, "standalone_perfect_accuracy_enabled")
        if ironsight_pa == true then
            return true
        end
    end
    
    local flag = _G.classic_re4_laser_perfect_accuracy_enabled
    local base = flag ~= false
    if perfect_accuracy_only_when_laser_active then
      local ironsight_active = rawget(_G, "standalone_iron_sight_active") == true
      local ironsight_pa = ironsight_active and rawget(_G, "standalone_perfect_accuracy_enabled") == true
      if not ironsight_pa then
        base = base and classic_laser_active_for_perfect
      end
    end
    return base
end

local cast_ray_async = CastRays.cast_ray_async

-- Laser trail management functions

local function is_laser_trail_valid()
  if not laser_trail_gameobject then return false end
  local valid = laser_trail_gameobject:get_Valid()
  if not valid then
    laser_trail_gameobject = nil
    laser_mesh_resource = nil
    laser_material_resource = nil
    return false
  end
  return true
end

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
  
  -- Store in table for cleanup on script reset
  laser_trail_table["trail"] = laser_trail_gameobject

  -- Create mesh component and load resources
  local mesh_component = laser_trail_gameobject:call("createComponent(System.Type)", sdk.typeof("via.render.Mesh"))
  if mesh_component then
    mesh_component:set_DrawShadowCast(false)
    -- Always recreate mesh resource to ensure it's valid for this scene
    laser_mesh_resource = sdk.create_resource("via.render.MeshResource", "_chainsaw/character/wp/wp40/wp4000/21/wp4000_22.mesh")
    if laser_mesh_resource then
      laser_mesh_resource:add_ref()
    end
    
    if laser_mesh_resource and laser_mesh_resource:get_address() ~= 0 then
      local mesh_resource_holder = sdk.create_instance("via.render.MeshResourceHolder", true)
      if mesh_resource_holder and mesh_resource_holder:get_address() ~= 0 then
        mesh_resource_holder:add_ref()
        mesh_resource_holder:write_qword(0x10, laser_mesh_resource:get_address())
        -- Only call setMesh if mesh_component has valid address
        if mesh_component:get_address() ~= 0 then
          mesh_component:setMesh(mesh_resource_holder)
        end
      end
    end
    
    -- Always recreate material resource to ensure it's valid for this scene
    laser_material_resource = sdk.create_resource("via.render.MeshMaterialResource", "LaserColors/classicRE4LaserMaterial.mdf2")
    if laser_material_resource then
      laser_material_resource:add_ref()
    end
    
    if laser_material_resource and laser_material_resource:get_address() ~= 0 then
      -- Create material holder and apply material using set_Material()
      local material_holder = sdk.create_instance("via.render.MeshMaterialResourceHolder", true)
      if material_holder and material_holder:get_address() ~= 0 then
        material_holder:add_ref()
        material_holder:write_qword(0x10, laser_material_resource:get_address())
        -- Only call set_Material if mesh_component has valid address
        if mesh_component:get_address() ~= 0 then
          mesh_component:set_Material(material_holder)
        end
      end
    end
  end
  -- Apply loaded material params immediately after mesh is created
  apply_laser_trail_settings()
  
  -- Apply initial beam color from laser_beam_color_array to ensure beam starts with correct color
  apply_beam_color(laser_beam_color_array)
  -- apply_beam_color resets mesh from params; re-apply post-shot dim laser intensity if that window is still active
  if post_shot.dim_effectively_active() then
    post_shot.try_capture_and_dim_emissive()
  end
end

local function destroy_laser_trail()
  if laser_trail_gameobject then
    if post_shot.dim_mat_table_backup and next(post_shot.dim_mat_table_backup) then
      post_shot.restore_dim_material_from_saved()
    end
    laser_trail_gameobject:call("destroy", laser_trail_gameobject)
    laser_trail_gameobject = nil
    focused_laser_colors.runtime_beam_sig = nil
  end
end

-- Clean up laser trail when scripts are reset (prevents frozen leftover trails)
re.on_script_reset(function()
  -- Destroy laser trail table reference
  if laser_trail_table["trail"] then
    laser_trail_table["trail"]:call("destroy", laser_trail_table["trail"])
    laser_trail_table["trail"] = nil
  end
  
  -- Also try the direct reference
  destroy_laser_trail()
  
  -- Reset raycast results
  crosshair_bullet_ray_result = nil
  crosshair_attack_ray_result = nil
  static_attack_ray_result = nil
  static_bullet_ray_result = nil
  
  -- Reset cached objects
  cached_pl_head = nil
  cached_gun_obj = nil
  cached_weapon_id = nil
  cached_laser_sight_obj = nil
  
  -- Reset state variables
  scene_manager = nil
  scene = nil
  hasRunInitially = false
  _G.is_aim = false
  _G.is_reticle_displayed = false
  _G.focused_laser_aim = false
  _G.is_reticle_fitting = false -- legacy alias for mods; mirrors focused_laser_aim
  
  -- Clear the laser trail game object reference
  laser_trail_gameobject = nil
end)


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
_G.focused_laser_aim = false
_G.is_reticle_fitting = false -- legacy alias for mods
spread_refresh_bt_gun = nil
spread_refresh_weapon_id = nil
if not scene then
  return
end

-- Use cached objects to avoid expensive findGameObject calls
local current_time = os.clock()
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

-- Ensure cached head object remains valid
if cached_pl_head.get_Valid and not cached_pl_head:get_Valid() then
  cached_pl_head = nil
  return
end

local player_equip = cached_pl_head:call("getComponent(System.Type)", sdk.typeof("chainsaw.PlayerEquipment"))
local equip_weapon = nil
if player_equip then
  equip_weapon = player_equip:call("get_EquipWeaponID()")
end
if not player_equip or not equip_weapon then
  return
end

-- Skip entire muzzle tracking for weapon 4005 (Minecart Handgun) when FP mode is active
-- Let FirstPersonMode.lua handle bullet spawning completely
-- Clear any muzzle data and temporarily disable laser presence flag so FP mode takes full control
local fp_active = rawget(_G, "standalone_first_person_active") == true
if equip_weapon == 4005 and fp_active then
  -- Clear muzzle data
  re4.last_muzzle_pos = nil
  re4.last_muzzle_forward = nil
  re4.last_shoot_pos = nil
  re4.last_shoot_dir = nil
  re4.last_muzzle_joint = nil
  -- Temporarily make it look like this script isn't present for 4005
  _G.__classic_re4_laser_present = false
  -- Still need to track weapon ID and manage hook before returning
  local prev_weapon_id = current_weapon_id
  current_weapon_id = equip_weapon
  -- Hook 4005 when switching TO 4005 (only on weapon change)
  if current_weapon_id == 4005 and prev_weapon_id ~= 4005 then
    init_4005_hook()
    hasRunInitially = false  -- Force reticle update
  end
  return
end

-- Restore the presence flag for all other weapons
if equip_weapon ~= 4005 then
  _G.__classic_re4_laser_present = true
end

-- Store weapon ID globally for laser trail offset calculations
local prev_weapon_id = current_weapon_id
current_weapon_id = equip_weapon
_dot_panel_field = (equip_weapon == 6304) and "TYPE08Panel" or "TYPE01Panel"

-- Force re-run updateReticles when switching to weapon 4005 (Minecart Handgun)
-- This ensures the dot reticle is enabled even when the game auto-equips 4005 in minecart scene
-- Manage FP head spawn hook based on FP mode state, Remake style, preset, and weapon
local current_fp_active = rawget(_G, "standalone_first_person_active") == true
local current_remake_style = static_center_dot == true

-- Check if laser is disabled for current weapon (needed for multiple conditions)
local weapon_id_str = current_weapon_id and tostring(current_weapon_id) or "unknown"
local current_laser_disabled = weapon_laser_enabled[weapon_id_str] == false

-- Check if iron sight is active + laser disabled (muzzle spawn, works without FP mode)
local current_ironsight_active = rawget(_G, "standalone_iron_sight_active") == true
local current_ironsight_laser_disabled = current_ironsight_active and current_laser_disabled

-- Check if preset is active with laser-disabled weapon
local preset_a = rawget(_G, "custom_aim_preset_a_active") == true
local preset_b = rawget(_G, "custom_aim_preset_b_active") == true
local preset_c = rawget(_G, "custom_aim_preset_c_active") == true
local preset_d = rawget(_G, "custom_aim_preset_d_active") == true
local current_any_preset = preset_a or preset_b or preset_c or preset_d
local current_preset_laser_disabled = current_fp_active and current_laser_disabled and current_any_preset

-- Check if Classic style + laser disabled (no preset required)
local current_classic_laser_disabled = current_fp_active and (not current_remake_style) and current_laser_disabled

-- Conditions for needing the hook:
-- 1. Weapon 4005 (always needs hook)
-- 2. FP mode + Remake style (head spawn)
-- 3. FP mode + preset active + laser disabled (head spawn)
-- 4. FP mode + Classic style + laser disabled (head spawn)
-- 5. Iron sight + laser disabled (muzzle spawn, works without FP mode)
local needs_hook_for_fp_remake = current_fp_active and current_remake_style
local prev_needed_hook_for_fp_remake = prev_fp_active_for_hook and prev_remake_style_for_hook
local needs_hook_now = needs_hook_for_fp_remake or current_preset_laser_disabled or current_classic_laser_disabled or current_ironsight_laser_disabled
local prev_needed_hook = prev_needed_hook_for_fp_remake or prev_preset_laser_disabled_for_hook or prev_classic_laser_disabled_for_hook or prev_ironsight_laser_disabled_for_hook

-- Initialize hook when:
-- 1. Switching to weapon 4005
-- 2. FP mode + Remake style just became active together
-- 3. FP mode + preset + laser disabled just became active
if current_weapon_id == 4005 and prev_weapon_id ~= 4005 then
  hasRunInitially = false
  init_fp_head_spawn_hook()
elseif needs_hook_now and not prev_needed_hook then
  -- Hook conditions just became active - initialize hook
  init_fp_head_spawn_hook()
end

-- Unhook when:
-- 1. Hook conditions become inactive AND not on weapon 4005
-- 2. Switching away from 4005 AND not needing hook
if prev_needed_hook and not needs_hook_now and current_weapon_id ~= 4005 then
  -- Hook conditions just became inactive and not on 4005
  unhook_4005_hook()
elseif prev_weapon_id == 4005 and current_weapon_id ~= 4005 and not needs_hook_now then
  -- Switched away from 4005 and not needing hook
  unhook_4005_hook()
end

-- Update previous states for next frame
prev_fp_active_for_hook = current_fp_active
prev_remake_style_for_hook = current_remake_style
prev_preset_laser_disabled_for_hook = current_preset_laser_disabled
prev_classic_laser_disabled_for_hook = current_classic_laser_disabled
prev_ironsight_laser_disabled_for_hook = current_ironsight_laser_disabled
prev_any_preset_for_hook = current_any_preset

-- Only check hooks if switching away from weapon 4600 (when hooks might be active)
if prev_weapon_id == 4600 and current_weapon_id ~= 4600 and is_hooks_active then
  manage_hooks()
end

-- Use cached weapon object or refresh if weapon changed
if not cached_gun_obj or cached_weapon_id ~= equip_weapon or (current_time - cache_refresh_time) > cache_refresh_interval then
  cached_gun_obj = nil
  local weapon_name = "wp" .. tostring(equip_weapon)

  -- For wp4002, walk ch0a0z0_body direct children to find the player's weapon
  -- This avoids picking up an NPC's duplicate wp4002 via findGameObject
  if equip_weapon == 4002 then
    local player_body_go = re4 and re4.body or nil
    if not player_body_go and scene then
      local ok_find, found = pcall(scene.call, scene, "findGameObject(System.String)", "ch0a0z0_body")
      if ok_find then player_body_go = found end
    end
    if player_body_go and is_valid_managed(player_body_go) then
      local ok_tf, body_tf = pcall(player_body_go.get_Transform, player_body_go)
      if ok_tf and body_tf then
        local ok_ch, child = pcall(body_tf.call, body_tf, "get_Child")
        child = ok_ch and child or nil
        local safety = 0
        while child and safety < 50 do
          local ok_go, child_go = pcall(child.call, child, "get_GameObject")
          if ok_go and child_go then
            local ok_cn, child_name = pcall(child_go.call, child_go, "get_Name")
            if ok_cn and child_name and tostring(child_name) == weapon_name then
              cached_gun_obj = child_go
              break
            end
          end
          local ok_next, next_sib = pcall(child.call, child, "get_Next")
          child = ok_next and next_sib or nil
          safety = safety + 1
        end
      end
    end
  end

  -- Fallback: standard findGameObject (works for all non-duplicate weapons)
  if not cached_gun_obj then
    cached_gun_obj = scene:call("findGameObject(System.String)", weapon_name)
  end
  if not cached_gun_obj then
    cached_gun_obj = scene:call("findGameObject(System.String)", weapon_name .. "_AO")
  end
  if not cached_gun_obj then
    cached_gun_obj = scene:call("findGameObject(System.String)", weapon_name .. "_MC")
  end
  cached_weapon_id = equip_weapon
  cache_refresh_time = current_time
end
if not cached_gun_obj or not is_valid_managed(cached_gun_obj) then
  return
end

local ok_gun, bt_gun = pcall(cached_gun_obj.call, cached_gun_obj, "getComponent(System.Type)", sdk.typeof("chainsaw.Gun"))
local ok_arms, bt_arms = pcall(cached_gun_obj.call, cached_gun_obj, "getComponent(System.Type)", sdk.typeof("chainsaw.Arms"))
if not ok_gun then bt_gun = nil end
if not ok_arms then bt_arms = nil end
if ok_gun and bt_gun and is_valid_managed(bt_gun) then
  local ok_rf, rf = pcall(function() return bt_gun:get_field("_IsReticleFitting") end)
  if (not ok_rf or rf == nil) and bt_gun.call then
    ok_rf, rf = pcall(function() return bt_gun:call("get_IsReticleFitting") end)
  end
  if ok_rf and rf ~= nil then
    _G.focused_laser_aim = (rf == true)
    _G.is_reticle_fitting = _G.focused_laser_aim -- legacy alias for mods (chainsaw.Gun._IsReticleFitting)
  end
end
local muzzle_joint = nil
if bt_arms then
  muzzle_joint = bt_arms:call("getMuzzleJoint")
end
if not muzzle_joint then
  local ok_gt, gun_transforms = pcall(cached_gun_obj.get_Transform, cached_gun_obj)
  if not ok_gt then gun_transforms = nil end
  if gun_transforms then
    local ok_j, j = pcall(gun_transforms.call, gun_transforms, "getJointByName", "vfx_muzzle")
    muzzle_joint = ok_j and j or nil
  end
end

if muzzle_joint then
  -- Has muzzle - normal weapon
  is_non_muzzle_weapon = false
  current_muzzle_joint = muzzle_joint  -- Store globally for laser trail offsets
  -- Skip muzzle data update for weapon 4005 (Minecart Handgun) - let game/FPMode handle it
  if equip_weapon ~= 4005 then
    local muzzle_position = joint_get_position(muzzle_joint)
    re4.last_muzzle_pos = muzzle_position
    re4.last_muzzle_forward = muzzle_joint:call("get_AxisZ")
    re4.last_shoot_dir = re4.last_muzzle_forward
    local muzzle_offset = 0.1
    re4.last_shoot_pos = re4.last_muzzle_pos + (re4.last_muzzle_forward * muzzle_offset)
    re4.last_muzzle_joint = muzzle_joint -- Store the joint for local offset use
  end
elseif equip_weapon ~= 4005 then
  -- No muzzle - non-muzzle weapon (knife, etc.) - skip for 4005
  is_non_muzzle_weapon = true
  current_muzzle_joint = nil  -- No joint for non-muzzle weapons
  local camera_mat = sdk.get_primary_camera():get_WorldMatrix()
  re4.last_muzzle_pos = camera_mat[3]
  re4.last_muzzle_pos.w = 1.0
  local muzzle_rot = camera_mat:to_quat()
  re4.last_muzzle_forward = (muzzle_rot * Vector3f.new(0, 0, -1)):normalized()
  re4.last_shoot_dir = re4.last_muzzle_forward
  local camera_offset = 2
  re4.last_shoot_pos = re4.last_muzzle_pos + (re4.last_muzzle_forward )
  re4.last_muzzle_joint = nil -- No joint for non-muzzle weapons
end

-- Update perfect accuracy spread state (only when weapon or setting changes)
if bt_gun then
  spread_refresh_bt_gun = bt_gun
  spread_refresh_weapon_id = equip_weapon
  if not perfect_accuracy_only_when_laser_active then
    update_spread_state(bt_gun, equip_weapon)
  end
end
end

local function update_spread_state_after_laser_trail_if_needed()
  if not perfect_accuracy_only_when_laser_active then return end
  if spread_refresh_bt_gun and spread_refresh_weapon_id then
    update_spread_state(spread_refresh_bt_gun, spread_refresh_weapon_id)
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

  -- Check if FP mode is active
  local fp_active = rawget(_G, "standalone_first_person_active") == true
  
  -- In FP mode, use Head joint position for raycast origin instead of camera
  local raycast_origin_pos = camera_pos
  if fp_active then
    local head_joint = get_player_head_joint()
    if head_joint then
      local head_pos = joint_get_position(head_joint)
      if head_pos then
        raycast_origin_pos = head_pos
        
        -- Apply head camera offset from FirstPersonMode (in head local space)
        local fp_head_offset = rawget(_G, "standalone_fp_head_offset")
        if fp_head_offset and (fp_head_offset.x ~= 0 or fp_head_offset.y ~= 0 or fp_head_offset.z ~= 0) then
          local axis_x, axis_y, axis_z = nil, nil, nil
          pcall(function() axis_x = head_joint:call("get_AxisX") end)
          pcall(function() axis_y = head_joint:call("get_AxisY") end)
          pcall(function() axis_z = head_joint:call("get_AxisZ") end)
          
          if axis_x and axis_y and axis_z then
            local offset_world = (axis_x * fp_head_offset.x) + (axis_y * fp_head_offset.y) + (axis_z * fp_head_offset.z)
            raycast_origin_pos = raycast_origin_pos + offset_world
          else
            raycast_origin_pos = raycast_origin_pos + Vector3f.new(fp_head_offset.x, fp_head_offset.y, fp_head_offset.z)
          end
        end
      end
    end
  end
  
  -- Add camera offset for raycast origin (reduce to 0 in first person mode)
  local raycast_offset = fp_active and 0.0 or CAMERA_RAYCAST_OFFSET
  local offset_camera_pos = raycast_origin_pos + (camera_forward * raycast_offset)
  
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
        local actual_distance = contact_distance or (contact_position - raycast_origin_pos):length()
        
        if actual_distance > sky_distance_threshold then
          -- Aiming at sky or very far away - use default distance
          static_target_intersection_point = raycast_origin_pos + (camera_forward * sky_distance_threshold)
        else
          -- Apply surface offset from contact point (using unified constant)
          local new_target_intersection = contact_position - (camera_forward * SURFACE_OFFSET)
          
          -- Hard limit: ensure dot never goes closer than 1.5 meters from raycast origin
          local min_distance_from_origin = 1.5
          local origin_to_dot = new_target_intersection - raycast_origin_pos
          local distance_from_origin = origin_to_dot:length()
          if distance_from_origin < min_distance_from_origin then
            static_target_intersection_point = raycast_origin_pos + (camera_forward * min_distance_from_origin)
          else
            static_target_intersection_point = new_target_intersection
          end
        end
      else
        -- Contact point was nil - use default distance
        static_target_intersection_point = raycast_origin_pos + (camera_forward * 100.0)
      end
    else
      -- No contact point found (aiming at sky/empty space) - use default distance
      local default_distance = 100.0  -- Default distance when no collision
      local fallback_position = raycast_origin_pos + (camera_forward * default_distance)
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

-- Clear finished post-shot shot state (so firing_mode does not linger after the window)
if post_shot.firing_weapon_id and post_shot.effect_until > 0.0 and os.clock() >= post_shot.effect_until then
  post_shot.firing_weapon_id = nil
  post_shot.firing_mode = nil
  post_shot.effect_until = 0.0
end

if post_shot.crosshair_after.weapon_id and post_shot.crosshair_after.effect_until > 0.0
    and os.clock() >= post_shot.crosshair_after.effect_until then
  post_shot.crosshair_after.weapon_id = nil
  post_shot.crosshair_after.effect_until = 0.0
end

-- Restore beam material when post-shot dim laser ends (runtime-only; not written to config)
if post_shot.dim_mat_table_backup and next(post_shot.dim_mat_table_backup) and not post_shot.dim_effectively_active() then
  post_shot.restore_dim_material_from_saved()
end

-- Check if laser is enabled for current weapon (default to enabled if not set)
local weapon_id_str = tostring(current_weapon_id)
local laser_enabled_for_weapon = weapon_laser_enabled[weapon_id_str] ~= false  -- Default true if nil
local has_stale_muzzle_data = static_center_dot and (os.clock() - last_crosshair_time) > 0.25
local is_weapon_changing = _G._IsWeaponChanging == true

-- Check if current weapon is a knife (5000 range + specific knife IDs) - instantly disable trail for knives
local is_knife_weapon = current_weapon_id and ((current_weapon_id >= 5000 and current_weapon_id < 6000) or current_weapon_id == 6107)

-- Weapon 4005 always uses simple static mode internally
local effective_simple_static = simple_static_mode or (current_weapon_id == 4005)
local post_shot_hide_active = post_shot.hide_effectively_active()
local should_show = enable_laser_trail and re4.last_muzzle_pos and not is_non_muzzle_weapon and _G.is_aim and not (effective_simple_static and not show_laser_dot) and not has_stale_muzzle_data and laser_enabled_for_weapon and not is_weapon_changing and not is_knife_weapon and not post_shot_hide_active

-- Update last active time when trail should be shown
if should_show then
  last_laser_trail_active_time = os.clock()
end

-- Use 0.15-second grace period after stopping aim, but NOT for knife weapons (instant disable)
-- Do not apply grace during post-shot hide or the trail would turn back on for ~0.15s after each shot.
local within_grace_period = not is_knife_weapon and not post_shot_hide_active and (os.clock() - last_laser_trail_active_time) < 0.15

-- Perfect Accuracy / Focus gate: must match trail intent even when skip_trail_frames hides drawing only.
classic_laser_active_for_perfect = should_show or within_grace_period

-- Skip drawing for several frames after mode switch to prevent stale position flash (does not clear laser gate above)
if skip_trail_frames > 0 then
  skip_trail_frames = skip_trail_frames - 1
  if laser_trail_gameobject then
    laser_trail_gameobject:set_DrawSelf(false)
  end
  return
end

-- Dim laser EmissiveIntensity must run even when the trail is hidden (post-shot hide), before early return
if post_shot.dim_effectively_active() then
  post_shot.try_capture_and_dim_emissive()
end

if not should_show and not within_grace_period then
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

local equipped_weapon_id = tostring(current_weapon_id)
local offset_tbl = (equipped_weapon_id and laser_origin_offsets and laser_origin_offsets[equipped_weapon_id]) or {x=laser_origin_offset_x, y=laser_origin_offset_y, z=laser_origin_offset_z}
local offset_x = offset_tbl.x or 0.0
local offset_y = offset_tbl.y or 0.0
local offset_z = offset_tbl.z or 0.0
local adjusted_muzzle_pos = re4.last_muzzle_pos

if current_muzzle_joint then
  local success, axis_x = pcall(function() return current_muzzle_joint:call("get_AxisX") end)
  if success and axis_x then
    local axis_y = current_muzzle_joint:call("get_AxisY")
    local axis_z = current_muzzle_joint:call("get_AxisZ")
    adjusted_muzzle_pos = adjusted_muzzle_pos
      + (axis_x * offset_x)
      + (axis_y * offset_y)
      + (axis_z * offset_z)
  else
    -- Muzzle joint became invalid, use simple offset
    adjusted_muzzle_pos = Vector3f.new(
      re4.last_muzzle_pos.x + offset_x,
      re4.last_muzzle_pos.y + offset_y,
      re4.last_muzzle_pos.z + offset_z
    )
  end
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
  local offset_y_trail
  if distance_to_target > 10.0 then
    offset_y_trail = -0.05  -- Over 10m
  elseif distance_to_target > 5.0 then
    offset_y_trail = -0.0175  -- 5-10m
  else
    offset_y_trail = -0.015  -- Under 5m
  end
  local trail_offset = Vector3f.new(0, offset_y_trail, 0)
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

local eff_beam = laser_beam_color_array
local persist_beam_params = true
if focused_laser_colors.enabled and _G.focused_laser_aim then
  eff_beam = (focused_laser_colors.match_focused_dot_beam and focused_laser_colors.dot) or focused_laser_colors.beam
  persist_beam_params = false
end
local sig = string.format("%s|%g|%g|%g|%g", tostring(persist_beam_params), eff_beam[1], eff_beam[2], eff_beam[3], eff_beam[4] or 1.0)
if sig ~= focused_laser_colors.runtime_beam_sig then
  apply_beam_color(eff_beam, persist_beam_params)
end
end

re.on_pre_application_entry("LockScene", function()
install_post_shot_laser_hide_hooks()
-- Determine aiming state (is_aim) using CharacterContext, similar to reference
local character_manager = sdk.get_managed_singleton(sdk.game_namespace("CharacterManager"))
local CharacterContext = nil
if character_manager then
  CharacterContext = character_manager:call("getPlayerContextRef")
end
if CharacterContext then
  _G.is_aim = CharacterContext:call("get_IsShootEnable")
  _G.is_reticle_displayed = CharacterContext:call("get_IsReticleDisp")
  _G._IsWeaponChanging = CharacterContext:call("get_IsWeaponChanging") or false
  --_G.is_shoot_inhibited = CharacterContext:call("get_IsShootInhibit")
  
  -- Check for hold variation state
  local prev_hold_variation = is_hold_variation
  is_hold_variation = CharacterContext:call("get_IsHoldVariation") or false
  -- Only check hooks if hold variation state changed AND we're using weapon 4600
  if prev_hold_variation ~= is_hold_variation and current_weapon_id == 4600 then
    manage_hooks()
  end
else
  _G.is_aim = false
  _G.is_reticle_displayed = false
  _G._IsWeaponChanging = false
  --_G.is_shoot_inhibited = false
  local prev_hold_variation = is_hold_variation
  is_hold_variation = false
  -- Only check hooks if hold variation state changed AND we had weapon 4600
  if prev_hold_variation ~= is_hold_variation and current_weapon_id == 4600 then
    manage_hooks()
  end
end

local force_classic = (_G.force_classic_re4_style == true)
local fp_active = (rawget(_G, "standalone_first_person_active") == true)

-- Track preset state for hook management (no longer forces Classic style)
local preset_a_active = (rawget(_G, "custom_aim_preset_a_active") == true)
local preset_b_active = (rawget(_G, "custom_aim_preset_b_active") == true)
local preset_c_active = (rawget(_G, "custom_aim_preset_c_active") == true)
local preset_d_active = (rawget(_G, "custom_aim_preset_d_active") == true)
local any_preset_active_now = preset_a_active or preset_b_active or preset_c_active or preset_d_active

-- Track iron sight active state (aiming) to update hooks when aiming starts/stops
local iron_sight_active_now = (rawget(_G, "standalone_iron_sight_active") == true)
if iron_sight_active_now ~= iron_sight_active_prev then
  iron_sight_active_prev = iron_sight_active_now
  manage_hooks(true)  -- Re-evaluate hooks when iron sight aiming state changes
end

-- Track preset state changes to update hooks when presets toggle while IronSight is already active
if any_preset_active_now ~= any_preset_active_prev then
  any_preset_active_prev = any_preset_active_now
  manage_hooks(true)  -- Re-evaluate hooks when preset state changes
end

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
-- Note: FP mode + preset no longer forces Classic style (head spawn handled separately)
local should_force_classic = force_classic
if should_force_classic then
  if not force_classic_re4_prev then
    -- Just entered force_classic - store current state and update hooks for IronSight/Preset override
    stored_static_center_dot = static_center_dot
    manage_hooks(true)  -- Check if we need to hook for laser-disabled weapons
    -- Skip frames if was in Remake style (static_center_dot was true) - prevents stale position flash
    -- Applies to both FP mode (preset switch) and non-FP mode (iron sight toggle)
    if static_center_dot then
      skip_trail_frames = 5
    end
  end
  if static_center_dot then
    static_center_dot = false
    update_spawn_flag()
    hasRunInitially = false
    manage_hooks(true)
  end
else
  -- force_classic is false - check if we need to restore
  if force_classic_re4_prev then
    -- Just exited force_classic - restore previous state and update hooks
    manage_hooks(true)  -- Check if we need to unhook for laser-disabled weapons
    -- Skip frames if restoring to Remake style - prevents stale position flash
    -- Applies to both FP mode (preset switch) and non-FP mode (iron sight toggle)
    if stored_static_center_dot == true then
      skip_trail_frames = 5
    end
    if stored_static_center_dot ~= nil and static_center_dot ~= stored_static_center_dot then
      static_center_dot = stored_static_center_dot
      update_spawn_flag()
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
  update_spread_state_after_laser_trail_if_needed()
else
  update_muzzle_and_laser_data()

  -- Even when crosshair data is stale, still update muzzle position and laser trail
  if not scene then
    return
  end
  -- Post-shot dim laser / hide must keep running while the effect window is open; otherwise try_capture
  -- and trail visibility stop updating until crosshair data is fresh again.
  if post_shot.firing_weapon_id and post_shot.effect_until > 0.0 and os.clock() < post_shot.effect_until then
    update_laser_trail()
    update_spread_state_after_laser_trail_if_needed()
  end
end

maybe_refresh_point_range_after_laser_gate_changed()

-- Check for laser/dot toggle hotkey
local KM_controls = ((not Laser_settings.use_modifier or hk.check_hotkey("Laser Modifier", false)) and hk.check_hotkey("Laser Toggle")) or (hk.check_hotkey("Laser Modifier", true) and hk.check_hotkey("Laser Toggle"))
local PAD_controls = ((not Laser_settings.use_pad_modifier or hk.check_hotkey("Pad Laser Modifier", false)) and hk.check_hotkey("Pad Laser Toggle")) or (hk.check_hotkey("Pad Laser Modifier", true) and hk.check_hotkey("Pad Laser Toggle"))

if KM_controls or PAD_controls then
    enable_laser_trail = not enable_laser_trail
    show_laser_dot = not show_laser_dot
    -- Clear grace period timer when toggling off to ensure immediate disappearance
    if not enable_laser_trail then
      last_laser_trail_active_time = 0
      reticle_needs_restore = true
    end
    -- Classic→Remake only when the dropdown shows "3D Crosshair"; not when it shows "Default"
    if crosshair_combo_shows_3d_crosshair() then
      if not enable_laser_trail and not static_center_dot then
        stored_classic_for_default_crosshair = true
        static_center_dot = true
        update_spawn_flag()
        hasRunInitially = false
      elseif enable_laser_trail and stored_classic_for_default_crosshair then
        static_center_dot = false
        stored_classic_for_default_crosshair = nil
        update_spawn_flag()
        hasRunInitially = false
      end
    end
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

-- Cached type references for reticle panel visibility override
local T_RETICLE_GUI_BEHAVIOR = sdk.typeof("chainsaw.ReticleGuiBehavior")
local T_SCENE_MANAGER_DEF = sdk.find_type_definition("via.SceneManager")

local ALL_TYPE_PANEL_FIELDS = {
    "TYPE00Panel","TYPE01Panel","TYPE02Panel","TYPE04Panel","TYPE05Panel",
    "TYPE06Panel","TYPE07Panel","TYPE08Panel","TYPE09Panel","TYPE10Panel","TYPE90Panel"
}

-- When set true, a one-shot restore pass hides all TYPE panels so the game's
-- own lateUpdate can reassert the correct weapon panel on the next frame.
local reticle_needs_restore = false

-- Restore all TYPE01Panel GUI children to visible (undo line-hiding)
local function restore_type01_children(behavior)
    pcall(function()
        local t01 = behavior:get_field(_dot_panel_field)
        if not t01 then return end
        local children = {}
        pcall(function()
            local n = t01:call("get_ChildNum")
            for i = 0, math.min((n or 0) - 1, 2) do
                local c = t01:call("get_Child(System.Int32)", i)
                if c then table.insert(children, c) end
            end
        end)
        if #children == 0 then
            pcall(function()
                local c = t01:call("get_Child")
                while c and #children < 3 do
                    table.insert(children, c)
                    c = c:call("get_Next")
                end
            end)
        end
        for _, c in ipairs(children) do
            pcall(function() c:call("set_Visible", true) end)
        end
    end)
end

--[[ # log (commented out)
local _dbg_log_path = "reframework/autorun/debug-6aaffa.log"
local _dbg_log_count = 0
local _dbg_log_max = 120
local _dbg_last_wpn = nil
local function _dbg_log(hypothesis, location, message, data)
    if _dbg_log_count >= _dbg_log_max then return end
    _dbg_log_count = _dbg_log_count + 1
    local entry = '{"sessionId":"6aaffa","hypothesisId":"' .. tostring(hypothesis) .. '","location":"' .. tostring(location) .. '","message":"' .. tostring(message) .. '"'
    if data then
        entry = entry .. ',"data":{'
        local first = true
        for k, v in pairs(data) do
            if not first then entry = entry .. ',' end
            entry = entry .. '"' .. tostring(k) .. '":"' .. tostring(v) .. '"'
            first = false
        end
        entry = entry .. '}'
    end
    entry = entry .. ',"timestamp":' .. tostring(os.clock()) .. '}\n'
    local f = io.open(_dbg_log_path, "a")
    if f then f:write(entry) f:close() end
end
--]] -- #endregion

local function apply_type10_visibility(behavior)
    local target_panel = _dot_panel_field
    if current_weapon_id == 6304 then
        pcall(function()
            local p = behavior:get_field(target_panel)
            if p then p:call("set_Visible", true) end
        end)
        return
    end
    --[[ # log (commented out)
    local t10_field = nil
    local t10_vis_before = nil
    local t10_vis_after = nil
    local cwp_vis_before = nil
    local cwp_vis_after = nil
    local cwp_field = nil
    local panel_count = 0
    local nil_panels = 0
    --]] -- #endregion
    for _, tn in ipairs(ALL_TYPE_PANEL_FIELDS) do
        pcall(function()
            local p = behavior:get_field(tn)
            if p then
                --[[ # log (commented out)
                panel_count = panel_count + 1
                if tn == "TYPE01Panel" then
                    t10_field = tostring(p)
                    local ok_v, vis = pcall(function() return p:call("get_Visible") end)
                    t10_vis_before = ok_v and tostring(vis) or "err"
                end
                --]] -- #endregion
                p:call("set_Visible", tn == target_panel)
                --[[ # log (commented out)
                if tn == "TYPE01Panel" then
                    local ok_v2, vis2 = pcall(function() return p:call("get_Visible") end)
                    t10_vis_after = ok_v2 and tostring(vis2) or "err"
                end
                --]] -- #endregion
            --[[ else
                -- # log (commented out)
                nil_panels = nil_panels + 1
                -- #endregion --]]
            end
        end)
    end
    -- Also explicitly hide CurrWeaponPanel if it differs from TYPE01Panel
    pcall(function()
        local cwp = behavior:get_field("CurrWeaponPanel")
        local t10 = behavior:get_field(target_panel)
        --[[ # log (commented out)
        cwp_field = tostring(cwp)
        local ok_cv, cv = pcall(function() return cwp and cwp:call("get_Visible") end)
        cwp_vis_before = ok_cv and tostring(cv) or "err"
        --]] -- #endregion
        if cwp and t10 and tostring(cwp) ~= tostring(t10) then
            cwp:call("set_Visible", false)
        end
        --[[ # log (commented out)
        local ok_cv2, cv2 = pcall(function() return cwp and cwp:call("get_Visible") end)
        cwp_vis_after = ok_cv2 and tostring(cv2) or "err"
        --]] -- #endregion
    end)
    --[[ # log (commented out)
    _dbg_log("H3_H4", "apply_type10_visibility", "panel_stats", {
        panel_count=panel_count, nil_panels=nil_panels,
        t10_field=tostring(t10_field), t10_vis_before=tostring(t10_vis_before), t10_vis_after=tostring(t10_vis_after),
        cwp_field=tostring(cwp_field), cwp_vis_before=tostring(cwp_vis_before), cwp_vis_after=tostring(cwp_vis_after)
    })
    --]] -- #endregion
    pcall(function()
        local dot_panel = behavior:get_field(target_panel)
        if not dot_panel then return end
        local children = {}
        local ok_enum, err_enum = pcall(function()
            local n = dot_panel:call("get_ChildNum")
            for i = 0, math.min((n or 0) - 1, 2) do
                local c = dot_panel:call("get_Child(System.Int32)", i)
                if c then table.insert(children, c) end
            end
        end)
        if #children == 0 then
            pcall(function()
                local c = dot_panel:call("get_Child")
                while c and #children < 3 do
                    table.insert(children, c)
                    c = c:call("get_Next")
                end
            end)
        end
        for i, c in ipairs(children) do
            pcall(function() c:call("set_Visible", i == 1) end)
        end
    end)
end

local function for_each_reticle_behavior_in_scene(callback)
    if not T_RETICLE_GUI_BEHAVIOR then return end
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm or not T_SCENE_MANAGER_DEF then return end
    local cur_scene = sdk.call_native_func(sm, T_SCENE_MANAGER_DEF, "get_CurrentScene")
    if not cur_scene then return end
    for _, go_name in ipairs(reticle_names) do
        pcall(function()
            local go = cur_scene:call("findGameObject(System.String)", go_name)
            --[[ # log (commented out)
            _dbg_log("H1", "for_each_reticle", "findGameObject", {go_name=go_name, found=tostring(go ~= nil)})
            --]] -- #endregion
            if not go then return end
            local b = go:call("getComponent(System.Type)", T_RETICLE_GUI_BEHAVIOR)
            --[[ # log (commented out)
            _dbg_log("H2", "for_each_reticle", "getComponent", {go_name=go_name, behavior_found=tostring(b ~= nil)})
            --]] -- #endregion
            if b then callback(b) end
        end)
    end
end

-- Undo panel forcing: restore all children visible, show CurrWeaponPanel, hide the dot panel
local function undo_type10_override(behavior)
    restore_type01_children(behavior)
    pcall(function()
        local dp = behavior:get_field(_dot_panel_field)
        if dp then dp:call("set_Visible", false) end
        local cwp = behavior:get_field("CurrWeaponPanel")
        if cwp then cwp:call("set_Visible", true) end
    end)
end

local function apply_reticle_panel_override()
    if reticle_needs_restore then
        reticle_needs_restore = false
        for_each_reticle_behavior_in_scene(undo_type10_override)
        return
    end
    -- Try to activate the reticle by probing _IsEnableOpen and calling open mechanisms
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        if not sm or not T_SCENE_MANAGER_DEF then return end
        local cur_scene = sdk.call_native_func(sm, T_SCENE_MANAGER_DEF, "get_CurrentScene")
        if not cur_scene then return end
        for _, go_name in ipairs(reticle_names) do
            pcall(function()
                local go = cur_scene:call("findGameObject(System.String)", go_name)
                if not go then return end
                local b = go:call("getComponent(System.Type)", T_RETICLE_GUI_BEHAVIOR)
                if not b then return end
                local is_enable_open = b:call("get__IsEnableOpen")
                local go_draw = go:call("get_Draw")
                local curr_step = b:call("get_CurrStep")
                local curr_target_wpn = b:call("get_CurrTargetWeaponID")
                --[[ # log (commented out)
                _dbg_log("H13", "apply_override", "open_state_probe", {
                    go_name=go_name,
                    is_enable_open=tostring(is_enable_open),
                    go_draw=tostring(go_draw),
                    curr_step=tostring(curr_step),
                    curr_target_wpn=tostring(curr_target_wpn)
                })
                --]] -- #endregion
            end)
        end
    end)
    local weapon_id_str = current_weapon_id and tostring(current_weapon_id) or "unknown"
    local laser_on = weapon_laser_enabled[weapon_id_str] ~= false
    local is_knife = current_weapon_id and ((current_weapon_id >= 5000 and current_weapon_id < 6000) or current_weapon_id == 6107)
    --[[ # log (commented out)
    local _wpn_changed = (tostring(current_weapon_id) ~= tostring(_dbg_last_wpn))
    if _wpn_changed or _dbg_log_count < 5 then
        _dbg_last_wpn = current_weapon_id
        _dbg_log("H5", "apply_reticle_panel_override", "entry", {
            weapon_id=tostring(current_weapon_id), laser_on=tostring(laser_on),
            is_knife=tostring(is_knife), is_non_muzzle=tostring(is_non_muzzle_weapon),
            enable_laser_trail=tostring(enable_laser_trail), will_skip=tostring(is_knife == true)
        })
    end
    --]] -- #endregion
    if is_knife then return end
    -- Blast Crossbow (6102) uses its own reticle panel --
    -- undo any leftover TYPE01 forcing so the native panel shows, but never apply it.
    if current_weapon_id == 6102 then
        for_each_reticle_behavior_in_scene(undo_type10_override)
        return
    end
    -- 6304's dot panel (TYPE08) is on a Gui_ui2040 that findGameObject can't reach;
    -- the draw callback handles it via apply_type10_visibility directly.
    if current_weapon_id == 6304 then return end
    if not laser_on or not enable_laser_trail then
        if show_default_crosshair_laser_off then
            for_each_reticle_behavior_in_scene(undo_type10_override)
        else
            for_each_reticle_behavior_in_scene(restore_type01_children)
        end
        return
    end
    for_each_reticle_behavior_in_scene(apply_type10_visibility)
end

--[[ # log (commented out)
pcall(function()
    local td = sdk.find_type_definition("chainsaw.ReticleGuiBehavior")
    if td then
        local methods = td:get_methods()
        local method_names = {}
        for _, m in ipairs(methods) do
            table.insert(method_names, m:get_name())
        end
        _dbg_log("H12e", "method_enum", "ReticleGuiBehavior_methods", {
            count=tostring(#method_names),
            names=table.concat(method_names, "|")
        })
        local fields = td:get_fields()
        local field_names = {}
        for _, f in ipairs(fields) do
            table.insert(field_names, f:get_name())
        end
        _dbg_log("H13_fields", "field_enum", "ReticleGuiBehavior_fields", {
            count=tostring(#field_names),
            names=table.concat(field_names, "|")
        })
    end
    -- Also enumerate the OpenParam type if it exists
    local opd = sdk.find_type_definition("chainsaw.ReticleGuiBehavior.OpenParam")
    if opd then
        local op_fields = opd:get_fields()
        local op_field_names = {}
        for _, f in ipairs(op_fields) do
            table.insert(op_field_names, f:get_name())
        end
        local op_methods = opd:get_methods()
        local op_method_names = {}
        for _, m in ipairs(op_methods) do
            table.insert(op_method_names, m:get_name())
        end
        _dbg_log("H13_openparam", "type_enum", "OpenParam_info", {
            field_count=tostring(#op_field_names),
            fields=table.concat(op_field_names, "|"),
            method_count=tostring(#op_method_names),
            methods=table.concat(op_method_names, "|")
        })
    else
        _dbg_log("H13_openparam", "type_enum", "OpenParam_not_found", {})
    end
end)
--]] -- #endregion

-- Hook lateUpdate post-hook to override panel visibility after the game sets it
pcall(function()
    local td = sdk.find_type_definition("chainsaw.ReticleGuiBehavior")
    --[[ # log (commented out)
    _dbg_log("H7", "hook_setup", "td_check", {td_found=tostring(td ~= nil)})
    --]] -- #endregion
    if not td then return end
    local late_update_method = td:get_method("lateUpdate")
    --[[ # log (commented out)
    _dbg_log("H7", "hook_setup", "method_check", {method_found=tostring(late_update_method ~= nil)})
    --]] -- #endregion
    if not late_update_method then return end
    sdk.hook(
        late_update_method,
        nil,
        function(retval)
            --[[ # log (commented out)
            _dbg_log("H7", "lateUpdate_posthook", "fired", {weapon_id=tostring(current_weapon_id)})
            --]] -- #endregion
            pcall(apply_reticle_panel_override)
            return retval
        end
    )
    --[[ # log (commented out)
    _dbg_log("H7", "hook_setup", "hook_installed", {success="true"})
    --]] -- #endregion
end)

-- Also run after all behaviors have updated, catches cases where lateUpdate
-- hasn't fired yet (e.g. first load before aiming).
re.on_pre_application_entry("LateUpdateBehavior", function()
    pcall(apply_reticle_panel_override)
end)

local function write_vec4(obj, vec, offset)
obj:write_float(offset, vec.x)
obj:write_float(offset + 4, vec.y)
obj:write_float(offset + 8, vec.z)
obj:write_float(offset + 12, vec.w)
end

-- Update the re.on_pre_gui_draw_element function to respect show_laser_dot
re.on_pre_gui_draw_element(function(element, context)
  -- Get game object and name once, reuse throughout function
  local game_object = element:call("get_GameObject")
  local name = game_object and game_object:call("get_Name")

  --[[ Capture all GUI elements for 6304 debug panel (commented out)
  if current_weapon_id == 6304 and game_object and name then
    if not _G._dbg_6304_captured_gos then _G._dbg_6304_captured_gos = {} end
    local dominated = _G._dbg_6304_captured_addrs or {}
    local addr = tostring(game_object)
    if not dominated[addr] then
      dominated[addr] = true
      _G._dbg_6304_captured_addrs = dominated
      table.insert(_G._dbg_6304_captured_gos, {go=game_object, name=name})
    end
  elseif current_weapon_id ~= 6304 then
    _G._dbg_6304_captured_gos = nil
    _G._dbg_6304_captured_addrs = nil
  end
  --]]
  
  --[[ # log (commented out)
  if reticle_names[name] then
    _dbg_log("H9", "on_pre_gui_draw_element", "reticle_seen", {
        go_name=tostring(name), weapon_id=tostring(current_weapon_id),
        is_aim=tostring(_G.is_aim), is_active=tostring(_G.is_active)
    })
  end
  --]] -- #endregion

  -- Apply panel visibility override early, before aim checks, so it takes effect
  -- the very first time the game draws a reticle element (even before aiming).
  if reticle_names[name] and not reticle_needs_restore and enable_laser_trail then
    local wp_str = current_weapon_id and tostring(current_weapon_id) or "unknown"
    local laser_on_early = weapon_laser_enabled[wp_str] ~= false
    if laser_on_early then
      local is_knife_early = current_weapon_id and ((current_weapon_id >= 5000 and current_weapon_id < 6000) or current_weapon_id == 6107)
      local is_blast_crossbow_early = current_weapon_id == 6102
      if not is_knife_early and not is_blast_crossbow_early then
        --[[ # log (commented out)
        _dbg_log("H6_gui_draw", "on_pre_gui_draw_element", "early_override", {
            weapon_id=tostring(current_weapon_id), go_name=tostring(name)
        })
        --]] -- #endregion
        pcall(function()
          local b = game_object:call("getComponent(System.Type)", T_RETICLE_GUI_BEHAVIOR)
          if b then apply_type10_visibility(b) end
        end)
      end
    end
  end

  -- Skip drawing dot for several frames after mode switch to prevent stale position flash
  if skip_trail_frames > 0 then
    if reticle_names[name] then
      return false  -- Block reticle drawing during frame skip
    end
  end

  -- Post-shot laser hide + post-shot pistol crosshair hide: skip draw for laser reticle GUIs (Gui_ui2040 / Gui_ui2042)
  if reticle_names[name] and (post_shot.hide_effectively_active() or post_shot.crosshair_hide_effectively_active()) then
    return false
  end
  
  -- Use 0.15s grace period matching the trail
  -- Weapon 4005 (Minecart Handgun) always processes reticle regardless of aim state
  local within_grace_period = (os.clock() - last_laser_trail_active_time) < 0.15
  local force_process_4005 = (current_weapon_id == 4005)
  if not force_process_4005 and not _G.is_aim and not within_grace_period then
    return true
  end
  
  -- Check if laser is enabled for current weapon (default to enabled if not set)
  local weapon_id_str = tostring(current_weapon_id)
  local laser_enabled_for_weapon = weapon_laser_enabled[weapon_id_str] ~= false
  
  -- Hide dot when laser disabled AND IronSight+Preset is active (early return for performance)
  if not laser_enabled_for_weapon and not is_non_muzzle_weapon then
    local is_ironsight_active = (_G.force_classic_re4_style == true)
    local preset_a_active = (rawget(_G, "custom_aim_preset_a_active") == true)
    local preset_b_active = (rawget(_G, "custom_aim_preset_b_active") == true)
    local preset_c_active = (rawget(_G, "custom_aim_preset_c_active") == true)
    local preset_d_active = (rawget(_G, "custom_aim_preset_d_active") == true)
    local any_preset_active = preset_a_active or preset_b_active or preset_c_active or preset_d_active
    -- Only hide dot when BOTH IronSight AND a preset are active
    if is_ironsight_active and any_preset_active then
      if reticle_names[name] then
        return false -- Hide dot when IronSight+Preset overrides laser-disabled weapon
      end
    end
  end
  
  -- Handle reticle visibility based on simple static mode functionality
  -- Note: When laser is disabled for a weapon in settings, we still show the dot (only hide trail)
  -- Weapon 4005 (Minecart Handgun) always shows dot reticle regardless of settings
  local force_show_dot_4005 = (current_weapon_id == 4005)
  local effective_simple_static = simple_static_mode or force_show_dot_4005
  if not force_show_dot_4005 and not show_laser_dot and enable_laser_trail and laser_enabled_for_weapon and not (effective_simple_static and not show_laser_dot) then
    if reticle_names[name] then
      return false -- Hide reticle when laser is off via hotkey, UNLESS simple static mode is enabled (then show white dot)
    end
  end
  
  -- Hide dot when Iron Sight is active AND laser is disabled for the weapon
  if rawget(_G, "standalone_iron_sight_active") == true and not laser_enabled_for_weapon then
    if reticle_names[name] then
      return false -- Hide reticle when using iron sights with laser disabled
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
  local reticle_behavior = game_object:call("getComponent(System.Type)", T_RETICLE_GUI_BEHAVIOR)
  if reticle_behavior then
    local color_panel = reticle_behavior:get_field("ColorPanel")
    if color_panel then
      local laser_effectively_off_sat = not laser_enabled_for_weapon or not enable_laser_trail
      local sat = (show_default_crosshair_laser_off and laser_effectively_off_sat and not is_non_muzzle_weapon)
                  and default_crosshair_saturation or crosshair_saturation
      if post_shot.dim_effectively_active() and not is_non_muzzle_weapon then
        sat = post_shot.effective_dim_glow_saturation()
      elseif focused_laser_colors.enabled and _G.focused_laser_aim and not is_non_muzzle_weapon then
        sat = focused_laser_colors.glow
      end
      color_panel:call("set_Saturation", sat)
      
      -- Set the scale using the GUI value - use different scales for knife vs regular weapons
      local base_dot_scale = is_non_muzzle_weapon and knife_dot_scale or dot_scale
      local current_scale = (post_shot.dim_effectively_active() and not is_non_muzzle_weapon) and post_shot.effective_dim_dot_scale() or base_dot_scale
      local scale_vec = Vector3f.new(current_scale, current_scale, current_scale)
      color_panel:call("set_Scale", scale_vec)
    end
  end
  
  local type_panel = reticle_behavior:get_field("TypePanel")
  local laser_effectively_off = not laser_enabled_for_weapon or not enable_laser_trail
  local skip_type_panel_override = show_default_crosshair_laser_off and laser_effectively_off and not is_non_muzzle_weapon
  if type_panel and skip_type_panel_override then
    local current_color = type_panel:call("get_ColorScale")
    if current_color then
      local src = default_crosshair_match_laser
          and (((focused_laser_colors.enabled and _G.focused_laser_aim) and focused_laser_colors.dot) or laser_dot_color_array)
          or default_crosshair_color_array
      current_color.x = src[1] or 1.0
      current_color.y = src[2] or 1.0
      current_color.z = src[3] or 1.0
      current_color.w = src[4] or 1.0
      type_panel:call("set_ColorScale", current_color)
    end
  elseif type_panel then
    -- Use different scales for knife vs regular weapons
    local base_dot_scale = is_non_muzzle_weapon and knife_dot_scale or dot_scale
    local current_scale = (post_shot.dim_effectively_active() and not is_non_muzzle_weapon) and post_shot.effective_dim_dot_scale() or base_dot_scale
    local scale_vec = Vector3f.new(current_scale, current_scale, current_scale)
    type_panel:call("set_Scale", scale_vec)
    
    local current_color = type_panel:call("get_ColorScale")
    if current_color then
      -- Only apply color and alpha changes for muzzle weapons (guns)
      if not is_non_muzzle_weapon then
        -- Handle dot visibility based on hotkey state and weapon laser settings
        -- Note: IronSight/FP+Preset hiding is already handled by early return above
        local eff_dot = ((focused_laser_colors.enabled and _G.focused_laser_aim) and focused_laser_colors.dot) or laser_dot_color_array
        
        -- Weapon 4005 (Minecart Handgun) always shows dot reticle
        local force_show_dot_4005 = (current_weapon_id == 4005)
        
        if force_show_dot_4005 then
          -- Always show visible dot for weapon 4005 using Static Reticle color
          current_color.x = static_reticle_color_array[1] or 1.0
          current_color.y = static_reticle_color_array[2] or 1.0
          current_color.z = static_reticle_color_array[3] or 1.0
          current_color.w = 1.0  -- Always fully visible
        elseif not laser_enabled_for_weapon then
          if show_default_crosshair_laser_off then
            -- Let the game render its default crosshair without color override
          else
            -- Weapon has laser disabled in settings: show static colored dot with separate color
            current_color.x = static_reticle_color_array[1] or 1.0
            current_color.y = static_reticle_color_array[2] or 1.0
            current_color.z = static_reticle_color_array[3] or 1.0
            current_color.w = 1.0  -- Fully visible
          end
        elseif not show_laser_dot then
          -- Laser is toggled OFF via hotkey
          -- Weapon 4005 always uses simple static mode internally
          local effective_simple_static = simple_static_mode or (current_weapon_id == 4005)
          if effective_simple_static then
            -- Simple static mode enabled: show custom colored backup dot
            current_color.x = eff_dot[1] or 1.0
            current_color.y = eff_dot[2] or 0.0
            current_color.z = eff_dot[3] or 0.0
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
          current_color.x = eff_dot[1] or 1.0
          current_color.y = eff_dot[2] or 0.0
          current_color.z = eff_dot[3] or 0.0
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
  local is_active = reticle_behavior:call('get_IsActive')
  if is_active == nil then is_active = true end
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

  -- Minecart handgun (4005): this reticle View uses ViewType 0 for flat/center crosshair; force it (saved combo may still say "3D").
  local crosshair_vt = (current_weapon_id == 4005) and 0 or default_crosshair_view_type
  
  local laser_currently_active = laser_enabled_for_weapon and enable_laser_trail and not is_non_muzzle_weapon
  if laser_currently_active then
    view:call("set_Overlay", false)
  elseif show_default_crosshair_laser_off and laser_effectively_off and not is_non_muzzle_weapon then
    view:call("set_ViewType", crosshair_vt)
    view:call("set_Overlay", default_crosshair_overlay)
    view:call("set_Detonemap", default_crosshair_detonemap)
    view:call("set_DepthTest", default_crosshair_depth_test)
  end
  
  -- Handle positioning: prioritize simple static mode when laser is off, then static center vs dynamic
  -- Weapon 4005 always uses simple static mode regardless of checkbox state
  local effective_simple_static = simple_static_mode or (current_weapon_id == 4005)
  if (effective_simple_static and not show_laser_dot) or not laser_enabled_for_weapon or (current_weapon_id == 4005) then
    view:call("set_ViewType", crosshair_vt)
    view:call("set_Overlay", default_crosshair_overlay)
    view:call("set_Detonemap", default_crosshair_detonemap)
    view:call("set_DepthTest", default_crosshair_depth_test)
  elseif is_non_muzzle_weapon and not hide_dot_when_no_muzzle then
    view:call("set_ViewType", 0)
    view:call("set_Overlay", true)
    view:call("set_Detonemap", true)
    view:call("set_DepthTest", true)
  elseif static_center_dot and _G.is_aim and (_G.is_active) then
    -- Static center positioning (RE4 Remake Style)
    local crosshair_active = show_default_crosshair_laser_off and laser_effectively_off and not is_non_muzzle_weapon
    if cached_static_intersection_point and re4.crosshair_dir then
      view:call("set_ViewType", crosshair_active and crosshair_vt or 1)
      if crosshair_active then
        view:call("set_Overlay", default_crosshair_overlay)
        view:call("set_Detonemap", default_crosshair_detonemap)
        view:call("set_DepthTest", default_crosshair_depth_test)
      elseif is_non_muzzle_weapon then
        view:call("set_Overlay", true)
        view:call("set_Detonemap", true)
        view:call("set_DepthTest", false)
      else
        view:call("set_Overlay", false)
        view:call("set_Detonemap", true)
        view:call("set_DepthTest", false)
      end
        
        local new_mat = re4.crosshair_dir:to_quat():to_mat4()

        local base_multiplier = 0.075
        local min_distance_from_camera = 1.5
        local actual_distance = re4.crosshair_distance
        if static_center_dot and cached_static_intersection_point and cached_static_camera_pos then
          local camera_to_dot = cached_static_intersection_point - cached_static_camera_pos
          actual_distance = math.max(camera_to_dot:length(), min_distance_from_camera)
        end
        local distance = actual_distance * base_multiplier

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
    -- Dynamic positioning
    local crosshair_active_dyn = show_default_crosshair_laser_off and laser_effectively_off and not is_non_muzzle_weapon
    if global_intersection_point then
      view:call("set_ViewType", crosshair_active_dyn and crosshair_vt or 1)
      if crosshair_active_dyn then
        view:call("set_Overlay", default_crosshair_overlay)
        view:call("set_Detonemap", default_crosshair_detonemap)
        view:call("set_DepthTest", default_crosshair_depth_test)
      elseif is_non_muzzle_weapon then
        view:call("set_Overlay", true)
        view:call("set_Detonemap", true)
        view:call("set_DepthTest", true)
      else
        view:call("set_Overlay", false)
        view:call("set_Detonemap", true)
        view:call("set_DepthTest", true)
      end
        
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

  -- Pre-load laser trail on scene initialization if enabled
  if enable_laser_trail and not laser_trail_gameobject then
    create_laser_trail()
  end

  -- Detect game mode and set current_game_mode for defaults
  if scene:call("findGameObject(System.String)", "WeaponCatalog") then
      weaponCatalog = scene:call("findGameObject(System.String)", "WeaponCatalog")
      current_game_mode = "Main"
  end

  if scene:call("findGameObject(System.String)", "WeaponCatalog_AO") then
      weaponCatalog = scene:call("findGameObject(System.String)", "WeaponCatalog_AO")
      current_game_mode = "AO"
  end

  if not scene:call("findGameObject(System.String)", "WeaponCatalog") and not scene:call("findGameObject(System.String)", "WeaponCatalog_AO") then
      weaponCatalog = scene:call("findGameObject(System.String)", "WeaponCatalog_MC")      
      weaponCatalog2 = scene:call("findGameObject(System.String)", "WeaponCatalog_MC_2nd") 
      weaponCatalogRegister2 = weaponCatalog2:call("getComponent(System.Type)", sdk.typeof("chainsaw.WeaponCatalogRegister"))
      WeaponEquipParamCatalogUserData2 = weaponCatalogRegister2:call("get_WeaponEquipParamCatalogUserData")
      weaponDataTables2 = WeaponEquipParamCatalogUserData2:get_field("_DataTable")
      current_game_mode = "MC"
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
    
    -- Check if this weapon has laser disabled
    local weapon_id_str = tostring(weaponID)
    local laser_disabled_for_this_weapon = weapon_laser_enabled and weapon_laser_enabled[weapon_id_str] == false
    
    -- Set follow target: 0 = camera spawn (RE4 Remake), 1 = muzzle spawn (Classic)
    -- IronSight.lua will override this when active
    if laser_disabled_for_this_weapon or static_center_dot then
      weaponData:set_field("_GenerateFollowTarget", 0)
    else
      weaponData:set_field("_GenerateFollowTarget", 1)
    end

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
    -- Weapon 4005 (Minecart Handgun) always uses dot reticle
    local reticleWeapons = {4005, 4400, 4401, 4402, 6105, 6114, 6304, 6102, 4501}
    for _, id in ipairs(reticleWeapons) do
      if weaponID == id then
        local reticleFitParamTable = weaponData:get_field("_ReticleFitParamTable")
        if reticleFitParamTable then
          reticleFitParamTable:set_field("_ReticleShape", reticleValue)
        end
        break
      end
    end
    
    -- Point Range: Apply to ALL weapons with caching for restore
    -- Rifles always get 100 point range regardless of setting
    local isRifle = (weaponID == 4400 or weaponID == 4401 or weaponID == 4402 or weaponID == 6105 or weaponID == 6114)
    local reticleFitParamTable = weaponData:get_field("_ReticleFitParamTable")
    if reticleFitParamTable then
      -- Helper function to apply point range to a param object
      local function applyPointRange(param, cacheKey)
        if not param then return end
        local pointRange = param:get_field("_PointRange")
        if pointRange then
          -- If capturing defaults, save current values to file (mode-specific)
          if capture_defaults_pending then
            load_defaults_file()
            if not saved_defaults[current_game_mode] then
                saved_defaults[current_game_mode] = {spread = {}, point_range = {}}
            end
            saved_defaults[current_game_mode].point_range[tostring(cacheKey)] = {s = pointRange.s, r = pointRange.r}
          end
          
          -- Cache original values if not already cached
          if not original_point_ranges[cacheKey] then
            original_point_ranges[cacheKey] = {s = pointRange.s, r = pointRange.r}
          end
          
          local pf_master = _G.classic_re4_laser_point_range_enabled ~= false
          if perfect_focus_only_when_laser_active then
            pf_master = pf_master and classic_laser_active_for_perfect
          end
          if isRifle or pf_master then
            -- Rifles always get 100 point range, others only when Perfect Focus (and laser gate if enabled) applies
            pointRange.s = 100
            pointRange.r = 100
            write_valuetype(param, 0x10, pointRange)
          else
            -- Restore from saved defaults file first (mode-specific), then fallback to runtime cache
            load_defaults_file()
            local mode_defaults = saved_defaults and saved_defaults[current_game_mode]
            local saved_pr = mode_defaults and mode_defaults.point_range and mode_defaults.point_range[tostring(cacheKey)]
            local original = saved_pr or original_point_ranges[cacheKey]
            if original then
              pointRange.s = original.s
              pointRange.r = original.r
              write_valuetype(param, 0x10, pointRange)
            end
          end
        end
      end
      
      -- Apply to _DefaultParam
      local defaultParam = reticleFitParamTable:get_field("_DefaultParam")
      applyPointRange(defaultParam, weaponID)
      
      -- Apply to _CustomParams (some weapons use these instead of or in addition to _DefaultParam)
      local customParams = reticleFitParamTable:get_field("_CustomParams")
      if customParams then
        local customCount = customParams:call("get_Count")
        if customCount then
          for i = 0, customCount - 1 do
            local customParam = customParams:call("get_Item", i)
            if customParam then
              local param = customParam:get_field("_Param")
              if param then
                -- Use a unique cache key for each custom param
                local cacheKey = weaponID .. "_custom_" .. i
                applyPointRange(param, cacheKey)
              end
            end
          end
        end
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
  
  -- If capturing defaults, save to file and clear flag
  if capture_defaults_pending then
    save_defaults_file()
    capture_defaults_pending = false
  end
end

function classic_re4_laser_reset_values()
  scene_manager = nil
  scene = nil
  hasRunInitially = false
  destroy_laser_trail()  -- Clean up laser trail when resetting
  -- Reset spread cache for perfect accuracy
  spread_cache = {}
  applied_zero_spread = false
  last_spread_weapon_id = nil
  last_spread_accuracy_state = nil
  force_spread_update = true  -- Force reapplication when new character loads
  -- Reset point range cache (important for character changes)
  original_point_ranges = {}
  -- Reset weapon ID so 4005 detection works on new scene
  current_weapon_id = nil
end

re.on_pre_application_entry("LockScene", function()
  if re4.player == nil then       
      classic_re4_laser_reset_values()
      return
  end
  if re4.body == nil then        
      classic_re4_laser_reset_values()
      return
  end

  local camera = sdk.get_primary_camera()    
  if not camera then
      classic_re4_laser_reset_values()
      return
  end

  local need_initial_reticles = not hasRunInitially

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
  update_spread_state_after_laser_trail_if_needed()
  maybe_refresh_point_range_after_laser_gate_changed()

  if need_initial_reticles then
    updateReticles()
    hasRunInitially = true
  end

  -- Enforce reticle panel visibility every frame for consistency
  pcall(apply_reticle_panel_override)
end)

re.on_draw_ui(function()
  if imgui.tree_node("Classic RE4 Laser Settings") then
    imgui.begin_rect()
    -- Laser Style Selection
    imgui.text_colored(" Status:", 0xFFFFFFAA)
    imgui.same_line()
    -- Check if current weapon has laser disabled (takes priority over style)
    -- Compute directly here to ensure real-time accuracy
    local weapon_id_str = current_weapon_id and tostring(current_weapon_id) or "unknown"
    local laser_disabled_for_current_weapon = weapon_laser_enabled[weapon_id_str] == false
    if laser_disabled_for_current_weapon then
        imgui.text_colored("Laser Disabled (Camera Spawn)", 0xFFFF6600)
    elseif static_center_dot then
        imgui.text_colored("Laser/Projectile Follows Camera", 0xAA0000FF)
    else
        imgui.text_colored("Laser/Projectile Follows Muzzle", 0xAA0000FF)
    end
    if simple_static_mode then
      imgui.same_line()
      imgui.text_colored("+ Crosshair", 0xAA00FF00)
    end
    if disable_shoulder_corrector then
      imgui.same_line()
      imgui.text_colored("+ No Shoulder Correction", 0xFFFF8800)
    end
    if hide_dot_when_no_muzzle then
      imgui.same_line()
      imgui.text_colored("+ Hide Knife Dot", 0xFFFF00FF)
    end
    if show_default_crosshair_laser_off then
      imgui.same_line()
      imgui.text_colored("+ Crosshair", 0xFF00CCFF)
    end
    if _G.classic_re4_laser_perfect_accuracy_enabled ~= false then
      imgui.same_line()
      imgui.text_colored("+ Perfect Accuracy", 0xFF66EEDD)
    end
    if _G.classic_re4_laser_point_range_enabled ~= false then
      imgui.same_line()
      imgui.text_colored("+ Perfect Focus", 0xFFEECC66)
    end
    if perfect_accuracy_only_when_laser_active then
      imgui.same_line()
      imgui.text_colored("+ PA when laser", 0xFF88CCAA)
    end
    if perfect_focus_only_when_laser_active then
      imgui.same_line()
      imgui.text_colored("+ PF when laser", 0xFFCCAA88)
    end
    
    imgui.spacing()

    imgui.begin_rect()
    imgui.text_colored(" Select Style:", 0xFFFFFFAA)
    imgui.spacing()

    local muzzle_mode = not static_center_dot
    if muzzle_mode then
        imgui.push_style_color(2, 0.2, 0.8, 0.2, 1.0) -- Green tint for active
    end
    local muzzle_changed, muzzle_new = imgui.checkbox("Classic RE4 Style##laser_behavior", muzzle_mode)
    if muzzle_mode then
        imgui.pop_style_color(1)
    end
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Laser follows muzzle direction")
    end
    
    imgui.same_line()
    local camera_mode = static_center_dot
    if camera_mode then
        imgui.push_style_color(2, 0.2, 0.8, 0.2, 1.0) -- Green tint for active
    end
    local camera_changed, camera_new = imgui.checkbox("RE4 Remake Style##laser_behavior", camera_mode)
    if camera_mode then
        imgui.pop_style_color(1)
    end
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Laser always centered on screen")
    end

    imgui.end_rect(1)
    
    if muzzle_changed then
        if muzzle_new then
            static_center_dot = false
        else
            static_center_dot = true
            dot_scale = 1.0
        end
        update_spawn_flag()
        save_config()
        hasRunInitially = false
        manage_hooks(true)
    elseif camera_changed then
        if camera_new then
            static_center_dot = true
            dot_scale = 1.0
        else
            static_center_dot = false
        end
        update_spawn_flag()
        save_config()
        hasRunInitially = false
        manage_hooks(true)
    end
    
    -- Quick Options (Main options)
    imgui.begin_rect()
    imgui.text_colored(" Main options:", 0xFFFFFFAA)
    imgui.spacing()

    imgui.push_id("per_weapon_laser_section")
    -- ImGuiCol_Text=0, ImGuiCol_Button=21; use ARGB u32 (REFramework), not float tuples.
    imgui.push_style_color(0, 0xFF55EE88)
    imgui.push_style_color(21, 0xFF1A3D22)
    if imgui.button("Per-Weapon Laser Enable/Disable...") then
      imgui.open_popup("per_weapon_laser_popup")
    end
    imgui.pop_style_color(2)
    if imgui.is_item_hovered() then
      imgui.set_tooltip("Select which weapons have a laser")
    end
    if imgui.begin_popup("per_weapon_laser_popup") then
      imgui.text_colored(" Select weapons to show laser trail:", 0xFFFFFFAA)
      imgui.text_colored(" (Unchecked = dot reticle only)", 0xFFAAAA00)
      imgui.spacing()
      if imgui.button("Enable All##pw") then
        for _, category in ipairs(weapon_categories) do
          for _, id in ipairs(category.ids) do
            weapon_laser_enabled[tostring(id)] = true
          end
        end
        save_config()
        hasRunInitially = false
        manage_hooks(true)
      end
      imgui.same_line()
      if imgui.button("Disable All##pw") then
        for _, category in ipairs(weapon_categories) do
          for _, id in ipairs(category.ids) do
            weapon_laser_enabled[tostring(id)] = false
          end
        end
        save_config()
        hasRunInitially = false
        manage_hooks(true)
        reticle_needs_restore = true
      end
      imgui.spacing()
      local ordered_ids = {}
      for _, category in ipairs(weapon_categories) do
        for _, id in ipairs(category.ids) do
          table.insert(ordered_ids, id)
        end
      end
      for _, id in ipairs(ordered_ids) do
        if id == 4005 then goto continue_weapon_loop3 end
        local id_str = tostring(id)
        local name = weapon_names[id] or ("Unknown (" .. id_str .. ")")
        if weapon_laser_enabled[id_str] == nil then
          weapon_laser_enabled[id_str] = true
        end
        local changed, new_val = imgui.checkbox(name .. "##wp" .. id_str, weapon_laser_enabled[id_str])
        if changed then
          weapon_laser_enabled[id_str] = new_val
          save_config()
          hasRunInitially = false
          if id == current_weapon_id then
            manage_hooks(true)
            if not new_val then
              reticle_needs_restore = true
            end
          end
        end
        ::continue_weapon_loop3::
      end
      imgui.end_popup()
    end
    imgui.pop_id()
    imgui.spacing()

    -- Check if current weapon has laser disabled (hide Enable Dot Reticle option since dot is always shown)
    local weapon_id_str = current_weapon_id and tostring(current_weapon_id) or "unknown"
    local laser_disabled_for_current_weapon = weapon_laser_enabled[weapon_id_str] == false
    
    --[[ Enable default crosshair (disabled)
    if not laser_disabled_for_current_weapon then
      local simple_static_changed = false
      simple_static_changed, simple_static_mode = imgui.checkbox("Enable default crosshair", simple_static_mode)
      if imgui.is_item_hovered() then
          imgui.set_tooltip("Enable completely static dot reticle when laser is off")
      end
      if simple_static_changed then
          save_config()
      end
      
      imgui.same_line()
    end
    --]]
    
    corrector_changed, disable_shoulder_corrector = imgui.checkbox("Disable Shoulder Corrector", disable_shoulder_corrector)
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Disable weapon shoulder correction (removes auto centering of the arms and laser dot when aiming for Classic RE4 Laser. Has no effect on laser positioning for RE4 Remake Style)")
    end
    if corrector_changed then
        save_config()
        hasRunInitially = false
    end
    
    imgui.same_line()
    
    -- Perfect Accuracy checkbox
    local perfect_accuracy_enabled = _G.classic_re4_laser_perfect_accuracy_enabled ~= false
    local pa_changed, pa_new = imgui.checkbox("Perfect Accuracy##classic_laser_perfect_accuracy", perfect_accuracy_enabled)
    if pa_changed then
        _G.classic_re4_laser_perfect_accuracy_enabled = pa_new
        hasRunInitially = false  -- Force re-run updateReticles to apply/remove zero spread
        save_config()  -- Save the setting immediately
    end
    
    imgui.same_line()
    
    -- Point Range checkbox
    local point_range_enabled = _G.classic_re4_laser_point_range_enabled ~= false
    local pr_changed, pr_new = imgui.checkbox("Perfect Focus##classic_laser_point_range", point_range_enabled)
    if pr_changed then
        _G.classic_re4_laser_point_range_enabled = pr_new
        hasRunInitially = false  -- Force re-run updateReticles to apply point range
        save_config()  -- Save the setting immediately
    end

    local pa_top = _G.classic_re4_laser_perfect_accuracy_enabled ~= false
    local pr_top = _G.classic_re4_laser_point_range_enabled ~= false
    if pa_top or pr_top then
      imgui.spacing()
    end

    if pa_top then
      local pa_laser_only_changed, pa_laser_only_new = imgui.checkbox("Perfect Accuracy only while laser is active##pa_only_when_laser", perfect_accuracy_only_when_laser_active)
      if pa_laser_only_changed then
        perfect_accuracy_only_when_laser_active = pa_laser_only_new
        classic_laser_trail_effective_prev = nil
        force_spread_update = true
        hasRunInitially = false
        save_config()
      end
      if imgui.is_item_hovered() then
        imgui.set_tooltip("When enabled, Perfect Accuracy (zero spread) applies only while the classic muzzle laser trail is visible—aiming, laser not toggled off for the weapon, etc. Does not change Iron Sight mod behavior when its own perfect accuracy is active.")
      end
    end

    if pa_top and pr_top then
      imgui.spacing()
    end

    if pr_top then
      local pf_laser_only_changed, pf_laser_only_new = imgui.checkbox("Perfect Focus only while laser is active##pf_only_when_laser", perfect_focus_only_when_laser_active)
      if pf_laser_only_changed then
        perfect_focus_only_when_laser_active = pf_laser_only_new
        classic_laser_trail_effective_prev = nil
        hasRunInitially = false
        save_config()
      end
      if imgui.is_item_hovered() then
        imgui.set_tooltip("When enabled, Perfect Focus (max point range on non-rifle weapons) applies only while the classic muzzle laser trail is visible. Rifles still always use max point range.")
      end
    end
    
    local hide_muzzle_changed = false
    hide_muzzle_changed, hide_dot_when_no_muzzle = imgui.checkbox("Hide dot when using knife", hide_dot_when_no_muzzle)
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Hide the laser dot/reticle when no weapon muzzle is detected (useful for clean screenshots or cutscenes)")
    end
    if hide_muzzle_changed then
        save_config()
    end
    
    local crosshair_off_changed = false
    crosshair_off_changed, show_default_crosshair_laser_off = imgui.checkbox("Show crosshair when laser off", show_default_crosshair_laser_off)
    if imgui.is_item_hovered() then
        imgui.set_tooltip("When a weapon's laser is toggled off, the crosshair will show. *Laser behavior will temporarily show as Remake Style until laser is toggled back on.*")
    end
    if crosshair_off_changed then
        reticle_needs_restore = true
        save_config()
    end

    imgui.end_rect(1)
    imgui.spacing()
    imgui.begin_rect()
    imgui.text_colored(" Hide/Dim Laser After Shot:", 0xFFFFFFAA)
    imgui.text_colored("Global hide or dim laser applies to all laser enabled weapons unless a weapon is set to Off in Post-shot by weapon…", 0xFF888888)
    imgui.text_colored("Post-shot by weapon… sets mode override, duration, and optional dim laser tuning per gun.", 0xFF888888)
    imgui.spacing()
    local has_changed_top, has_new_top = imgui.checkbox("Hide laser after each shot##hide_laser_after_shot", post_shot.hide_laser)
    if has_changed_top then
        post_shot.hide_laser = has_new_top
        if has_new_top then post_shot.dim_enabled = false end
        save_config()
    end
    if imgui.is_item_hovered() then
        imgui.set_tooltip("After firing, hide the laser beam and dot until the timer below expires (re-enables automatically). Mutually exclusive with post-shot dim laser.")
    end
    local dim_changed_top, dim_new_top = imgui.checkbox("Post-shot dim laser##post_shot_temp_dim_dot_beam", post_shot.dim_enabled)
    if dim_changed_top then
        post_shot.dim_enabled = dim_new_top
        if dim_new_top then post_shot.hide_laser = false end
        save_config()
    end
    if imgui.is_item_hovered() then
        imgui.set_tooltip("After each shot: reticle scale, glow, and laser beam EmissiveIntensity use the dim laser sliders in this section while the effect is active. Beam color unchanged. Mutually exclusive with hide-after-shot.")
    end
    if post_shot.hide_laser or post_shot.dim_enabled or (post_shot.per_weapon and next(post_shot.per_weapon) ~= nil) then
      imgui.set_next_item_width(280)
      local t_changed_top, t_new_top = imgui.drag_float("Post-shot duration (sec)##hide_laser_after_shot_timer", post_shot.timer_sec, 0.01, 0.01, 3.0, "%.2f")
      if t_changed_top then
          post_shot.timer_sec = t_new_top
          save_config()
      end
      if imgui.is_item_hovered() then
          imgui.set_tooltip("Global duration for post-shot hide/dim laser.")
      end
    end
    if post_shot.dim_enabled then
      imgui.spacing()
      imgui.set_next_item_width(280)
      local dim_scale_changed, dim_scale_new = imgui.drag_float("Dim laser: dot / crosshair scale##post_shot_dim_dot_scale", post_shot.dim_dot_scale, 0.005, 0.0, 2.0, "%.2f")
      if dim_scale_changed then
        post_shot.dim_dot_scale = dim_scale_new
        save_config()
      end
      if imgui.is_item_hovered() then
        imgui.set_tooltip("Reticle TypePanel/ColorPanel scale while post-shot dim laser is active (0–2; same axis as Dot/Crosshair Scale).")
      end
      imgui.set_next_item_width(280)
      local dim_glow_changed, dim_glow_new = imgui.drag_float("Dim laser: glow##post_shot_dim_glow", post_shot.dim_glow_saturation, 0.25, 1.0, 100.0, "%.1f")
      if dim_glow_changed then
        post_shot.dim_glow_saturation = dim_glow_new
        save_config()
      end
      if imgui.is_item_hovered() then
        imgui.set_tooltip("ColorPanel glow while post-shot dim laser is active (same idea as the Glow slider).")
      end
      imgui.set_next_item_width(280)
      local dim_int_changed, dim_int_new = imgui.drag_float("Dim laser: EmissiveIntensity##post_shot_dim_intensity", post_shot.dim_intensity_dim, 0.05, 0.0, 100.0, "%.2f")
      if dim_int_changed then
        post_shot.dim_intensity_dim = snap_post_shot_dim_emissive(dim_int_new)
        save_config()
      end
      if imgui.is_item_hovered() then
        imgui.set_tooltip("Laser beam material EmissiveIntensity while post-shot dim laser is active (same range as Laser Beam material editor).")
      end
    end
    imgui.spacing()
    if imgui.button("Per-Weapon Post-Shot Options…##post_shot_per_weapon_btn") then
      local ordered_open = {}
      for _, category in ipairs(weapon_categories) do
        for _, wid in ipairs(category.ids) do
          if wid ~= 4005 then
            table.insert(ordered_open, wid)
          end
        end
      end
      post_shot_pw_popup_weapon_idx = 1
      if current_weapon_id then
        for i, wid in ipairs(ordered_open) do
          if wid == current_weapon_id then
            post_shot_pw_popup_weapon_idx = i
            break
          end
        end
      end
      imgui.open_popup("ClassicRE4Laser_post_shot_per_weapon_popup")
    end
    if imgui.is_item_hovered() then
      imgui.set_tooltip("Choose a weapon, then set mode: Use global, Off, or Hide/Dim laser after shot with optional duration and dim laser tuning.")
    end
    if imgui.begin_popup("ClassicRE4Laser_post_shot_per_weapon_popup") then
      imgui.text_colored("Per-Weapon Post-Shot Options", 0xFFFFFFAA)
      imgui.text_colored("Use global follows the Hide / Dim laser checkboxes for that weapon. Off disables post-shot for that weapon.", 0xFF888888)
      imgui.text("Optional duration and dim laser sliders apply only while that weapon's mode is Hide after shot or Dim laser after shot.")
      imgui.spacing()
      local ordered_pw_ids = {}
      local weapon_combo_labels = {}
      for _, category in ipairs(weapon_categories) do
        for _, wid in ipairs(category.ids) do
          if wid ~= 4005 then
            table.insert(ordered_pw_ids, wid)
            local id_str_l = tostring(wid)
            table.insert(weapon_combo_labels, weapon_names[wid] or ("Unknown (" .. id_str_l .. ")"))
          end
        end
      end
      local pw_n = #ordered_pw_ids
      if pw_n < 1 then
        imgui.text("No weapons in list.")
      else
        if post_shot_pw_popup_weapon_idx > pw_n then post_shot_pw_popup_weapon_idx = pw_n end
        if post_shot_pw_popup_weapon_idx < 1 then post_shot_pw_popup_weapon_idx = 1 end
        imgui.set_next_item_width(320)
        local wcomb, w_new_idx = imgui.combo("Weapon##postshot_pw_weapon", post_shot_pw_popup_weapon_idx, weapon_combo_labels)
        if wcomb then
          post_shot_pw_popup_weapon_idx = w_new_idx
        end
        local wid = ordered_pw_ids[post_shot_pw_popup_weapon_idx]
        local id_str = tostring(wid)
        imgui.push_id("pwpost_" .. id_str)
        imgui.spacing()
        imgui.set_next_item_width(260)
        local row_pre = post_shot.per_weapon and post_shot.per_weapon[id_str]
        local mode_pre = (row_pre and row_pre.mode) or "global"
        local combo_idx = post_shot.pw_mode_to_combo_idx(mode_pre)
        -- Literal label table only: some ImGui bindings iterate with pairs() and must not see post_shot's function keys
        local ccomb, new_idx = imgui.combo("Mode##postshot_pw_mode", combo_idx, { "Use global", "Off", "Hide after shot", "Dim laser after shot" })
        if ccomb then
          post_shot.per_weapon = post_shot.per_weapon or {}
          local nm = post_shot.pw_combo_idx_to_mode(new_idx)
          if nm == "global" then
            post_shot.per_weapon[id_str] = nil
          else
            post_shot.per_weapon[id_str] = post_shot.per_weapon[id_str] or {}
            post_shot.per_weapon[id_str].mode = nm
          end
          save_config()
        end
        local row = post_shot.per_weapon and post_shot.per_weapon[id_str]
        if row and (row.mode == "hide" or row.mode == "dim") then
          imgui.spacing()
          imgui.set_next_item_width(260)
          local dur_val = (row.timer_sec ~= nil) and row.timer_sec or post_shot.timer_sec
          local dch, dnew = imgui.drag_float("Duration (sec)##postshot_pw_dur", dur_val, 0.01, 0.01, 3.0, "%.2f")
          if dch then
            row.timer_sec = dnew
            save_config()
          end
          imgui.same_line()
          if imgui.button("Default##postshot_pw_durclr") then
            row.timer_sec = nil
            save_config()
          end
          if row.mode == "dim" then
            imgui.spacing()
            imgui.set_next_item_width(260)
            local vds = (row.dim_dot_scale ~= nil) and row.dim_dot_scale or post_shot.dim_dot_scale
            local sch, sne = imgui.drag_float("Dim laser: dot scale##postshot_pw_ds", vds, 0.005, 0.0, 2.0, "%.2f")
            if sch then
              row.dim_dot_scale = sne
              save_config()
            end
            imgui.set_next_item_width(260)
            local vgs = (row.dim_glow_saturation ~= nil) and row.dim_glow_saturation or post_shot.dim_glow_saturation
            local gch, gne = imgui.drag_float("Dim laser: glow##postshot_pw_glow", vgs, 0.25, 1.0, 100.0, "%.1f")
            if gch then
              row.dim_glow_saturation = gne
              save_config()
            end
            imgui.set_next_item_width(260)
            local vdi = (row.dim_intensity_dim ~= nil) and row.dim_intensity_dim or post_shot.dim_intensity_dim
            local ich, ine = imgui.drag_float("Dim laser: intensity##postshot_pw_int", vdi, 0.05, 0.0, 100.0, "%.2f")
            if ich then
              row.dim_intensity_dim = snap_post_shot_dim_emissive(ine)
              save_config()
            end
            if imgui.button("Use global dim laser sliders##postshot_pw_dimclr") then
              row.dim_dot_scale = nil
              row.dim_glow_saturation = nil
              row.dim_intensity_dim = nil
              save_config()
            end
          end
        end
        imgui.pop_id()
      end
      imgui.end_popup()
    end
    imgui.end_rect(1)

    --[[
    imgui.spacing()
    imgui.text_colored("Capture Defaults (Mode: " .. current_game_mode .. "):", 0xFFAAAAFF)
    imgui.same_line()
    imgui.text_colored("[?]", 0xFFFFFF88)
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Capture original weapon values for restoring when unchecking Perfect Accuracy / Point Range.\\nUncheck both settings first, then click the button for your current game mode.\\nMain = Leon/Ashley campaign\\nAO = Separate Ways (Ada)\\nMC = Mercenaries")
    end
    
    -- Main capture button
    if imgui.button("Main##capture_main") then
        if current_game_mode == "Main" then
            spread_cache = {}
            applied_zero_spread = false
            original_point_ranges = {}
            load_defaults_file()
            saved_defaults["Main"] = {spread = {}, point_range = {}}
            capture_defaults_pending = true
            hasRunInitially = false
        end
    end
    if imgui.is_item_hovered() then
        local tip = "Capture defaults for Main game (Leon/Ashley)"
        if current_game_mode ~= "Main" then
            tip = tip .. "\\n[Currently in " .. current_game_mode .. " mode - switch to Main first!]"
        end
        imgui.set_tooltip(tip)
    end
    
    imgui.same_line()
    
    -- AO capture button
    if imgui.button("Separate Ways##capture_ao") then
        if current_game_mode == "AO" then
            spread_cache = {}
            applied_zero_spread = false
            original_point_ranges = {}
            load_defaults_file()
            saved_defaults["AO"] = {spread = {}, point_range = {}}
            capture_defaults_pending = true
            hasRunInitially = false
        end
    end
    if imgui.is_item_hovered() then
        local tip = "Capture defaults for Separate Ways (Ada)"
        if current_game_mode ~= "AO" then
            tip = tip .. "\\n[Currently in " .. current_game_mode .. " mode - switch to AO first!]"
        end
        imgui.set_tooltip(tip)
    end
    
    imgui.same_line()
    
    -- MC capture button
    if imgui.button("Mercenaries##capture_mc") then
        if current_game_mode == "MC" then
            spread_cache = {}
            applied_zero_spread = false
            original_point_ranges = {}
            load_defaults_file()
            saved_defaults["MC"] = {spread = {}, point_range = {}}
            capture_defaults_pending = true
            hasRunInitially = false
        end
    end
    if imgui.is_item_hovered() then
        local tip = "Capture defaults for Mercenaries"
        if current_game_mode ~= "MC" then
            tip = tip .. "\\n[Currently in " .. current_game_mode .. " mode - switch to MC first!]"
        end
        imgui.set_tooltip(tip)
    end
    
    imgui.end_rect(1)
  --]]
  
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
  
  -- Ensure color arrays are valid before using imgui pickers
  laser_dot_color_array = sanitize_color_array(laser_dot_color_array, {1.0, 0.0, 0.0, 1.0})
  laser_beam_color_array = sanitize_color_array(laser_beam_color_array, {1.0, 0.0, 0.0, 1.0})
  knife_dot_color_array = sanitize_color_array(knife_dot_color_array, {1.0, 1.0, 1.0, 1.0})
  static_reticle_color_array = sanitize_color_array(static_reticle_color_array, {1.0, 1.0, 1.0, 1.0})

  local mm_changed, mm_new = imgui.checkbox("Match dot & beam color##match_main_dot_beam", post_shot.match_main_dot_beam)
  if mm_changed then
      post_shot.match_main_dot_beam = mm_new
      if post_shot.match_main_dot_beam then
        laser_beam_color_array = {
          laser_dot_color_array[1], laser_dot_color_array[2], laser_dot_color_array[3],
          laser_dot_color_array[4] or 1.0,
        }
        apply_beam_color(laser_beam_color_array)
      end
      focused_laser_colors.runtime_beam_sig = nil
      save_config()
  end
  if imgui.is_item_hovered() then
      imgui.set_tooltip("When enabled, the beam uses the same color as the dot. Changing either picker keeps them in sync.")
  end
  
  -- Color Pickers side by side - Dot first, then Beam
  local dot_color = {
    laser_dot_color_array and laser_dot_color_array[1] or 1.0,
    laser_dot_color_array and laser_dot_color_array[2] or 0.0,
    laser_dot_color_array and laser_dot_color_array[3] or 0.0
  }
  local dot_color_changed, new_dot_color
  local success_dot = pcall(function()
    dot_color_changed, new_dot_color = imgui.color_edit3("Dot##dot_picker", dot_color, 4194304 | 32)
  end)
  if not success_dot then
    local dot_color_array_4f = Vector4f.new(laser_dot_color_array[1], laser_dot_color_array[2], laser_dot_color_array[3], laser_dot_color_array[4] or 1.0)
    dot_color_changed, new_dot_color = imgui.color_edit4("Dot##dot_picker", dot_color_array_4f, 4194304 | 32)
    if new_dot_color then
      laser_dot_color_array = {new_dot_color.x, new_dot_color.y, new_dot_color.z, new_dot_color.w}
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
      if post_shot.match_main_dot_beam then
        laser_beam_color_array = {
          laser_dot_color_array[1], laser_dot_color_array[2], laser_dot_color_array[3],
          laser_dot_color_array[4] or 1.0,
        }
        apply_beam_color(laser_beam_color_array)
      end
      focused_laser_colors.runtime_beam_sig = nil
      save_config()
  end
  
  imgui.same_line()
  local beam_color = {
    laser_beam_color_array and laser_beam_color_array[1] or 1.0,
    laser_beam_color_array and laser_beam_color_array[2] or 0.0,
    laser_beam_color_array and laser_beam_color_array[3] or 0.0
  }
  local beam_color_changed, new_beam_color
  local success_beam = pcall(function()
    beam_color_changed, new_beam_color = imgui.color_edit3("Beam##beam_picker", beam_color, 4194304 | 32)
  end)
  if not success_beam then
    local beam_color_array_4f = Vector4f.new(laser_beam_color_array[1], laser_beam_color_array[2], laser_beam_color_array[3], laser_beam_color_array[4] or 1.0)
    beam_color_changed, new_beam_color = imgui.color_edit4("Beam##beam_picker", beam_color_array_4f, 4194304 | 32)
    if new_beam_color then
      laser_beam_color_array = {new_beam_color.x, new_beam_color.y, new_beam_color.z, new_beam_color.w}
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
      if post_shot.match_main_dot_beam then
        laser_dot_color_array = {
          laser_beam_color_array[1], laser_beam_color_array[2], laser_beam_color_array[3],
          laser_beam_color_array[4] or 1.0,
        }
        apply_dot_color(laser_dot_color_array)
      end
      apply_beam_color(laser_beam_color_array)
      focused_laser_colors.runtime_beam_sig = nil
      save_config()
  end
  
  imgui.same_line()
  local knife_color = {
    knife_dot_color_array and knife_dot_color_array[1] or 1.0,
    knife_dot_color_array and knife_dot_color_array[2] or 1.0,
    knife_dot_color_array and knife_dot_color_array[3] or 1.0
  }
  local knife_color_changed, new_knife_color
  local success_knife = pcall(function()
    knife_color_changed, new_knife_color = imgui.color_edit3("Knife##knife_picker", knife_color, 4194304 | 32)
  end)
  if not success_knife then
    local knife_color_array_4f = Vector4f.new(knife_dot_color_array[1], knife_dot_color_array[2], knife_dot_color_array[3], knife_dot_color_array[4] or 1.0)
    knife_color_changed, new_knife_color = imgui.color_edit4("Knife##knife_picker", knife_color_array_4f, 4194304 | 32)
    if new_knife_color then
      knife_dot_color_array = {new_knife_color.x, new_knife_color.y, new_knife_color.z, new_knife_color.w}
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

  imgui.spacing()
  local rfc_changed, rfc_new = imgui.checkbox("Separate dot/beam color when focused ##reticle_fit_colors", focused_laser_colors.enabled)
  if rfc_changed then
      focused_laser_colors.enabled = rfc_new
      focused_laser_colors.runtime_beam_sig = nil
      save_config()
  end
  if imgui.is_item_hovered() then
      imgui.set_tooltip("While IsReticleFitting is true (focused aim, use the colors below instead of the main Dot and Beam pickers.")
  end
  if focused_laser_colors.enabled then
      focused_laser_colors.dot = sanitize_color_array(focused_laser_colors.dot, {0.0, 1.0, 0.0, 1.0})
      focused_laser_colors.beam = sanitize_color_array(focused_laser_colors.beam, {0.0, 1.0, 0.0, 1.0})
      local rfm_changed, rfm_new = imgui.checkbox("Match focused dot & beam##match_focused_dot_beam", focused_laser_colors.match_focused_dot_beam)
      if rfm_changed then
          focused_laser_colors.match_focused_dot_beam = rfm_new
          if focused_laser_colors.match_focused_dot_beam then
            focused_laser_colors.beam = {
              focused_laser_colors.dot[1], focused_laser_colors.dot[2], focused_laser_colors.dot[3],
              focused_laser_colors.dot[4] or 1.0,
            }
          end
          focused_laser_colors.runtime_beam_sig = nil
          save_config()
      end
      if imgui.is_item_hovered() then
          imgui.set_tooltip("While using focused-aim colors, the beam tint follows the focused dot color.")
      end
      imgui.set_next_item_width(280)
      local sfg_changed, sfg_new = imgui.slider_float("Glow (focused)##reticle_fit_glow", focused_laser_colors.glow, 0.0, 100.0, "%.1f")
      if imgui.is_item_hovered() then
          imgui.set_tooltip("Laser dot glow (ColorPanel saturation) while focused (_IsReticleFitting).")
      end
      if sfg_changed then
          focused_laser_colors.glow = math.max(0.0, math.min(100.0, sfg_new))
          save_config()
      end
      local rfd = {
        focused_laser_colors.dot[1] or 0.0,
        focused_laser_colors.dot[2] or 1.0,
        focused_laser_colors.dot[3] or 0.0
      }
      local rfd_changed, rfd_new
      local rfd_ok = pcall(function()
        rfd_changed, rfd_new = imgui.color_edit3("Dot (focused)##rf_dot_picker", rfd, 4194304 | 32)
      end)
      if not rfd_ok then
        local rfd_4f = Vector4f.new(focused_laser_colors.dot[1], focused_laser_colors.dot[2], focused_laser_colors.dot[3], focused_laser_colors.dot[4] or 1.0)
        rfd_changed, rfd_new = imgui.color_edit4("Dot (focused)##rf_dot_picker", rfd_4f, 4194304 | 32)
        if rfd_new then
          focused_laser_colors.dot = {rfd_new.x, rfd_new.y, rfd_new.z, rfd_new.w}
        end
      else
        if rfd_new then
          focused_laser_colors.dot = rfd_new
        end
      end
      if imgui.is_item_hovered() then
          imgui.set_tooltip("Laser dot color while focused (_IsReticleFitting true)")
      end
      if rfd_changed then
          if focused_laser_colors.match_focused_dot_beam then
            focused_laser_colors.beam = {
              focused_laser_colors.dot[1], focused_laser_colors.dot[2], focused_laser_colors.dot[3],
              focused_laser_colors.dot[4] or 1.0,
            }
          end
          focused_laser_colors.runtime_beam_sig = nil
          save_config()
      end
      if not focused_laser_colors.match_focused_dot_beam then
          imgui.same_line()
          local rfb = {
            focused_laser_colors.beam[1] or 0.0,
            focused_laser_colors.beam[2] or 1.0,
            focused_laser_colors.beam[3] or 0.0
          }
          local rfb_changed, rfb_new
          local rfb_ok = pcall(function()
            rfb_changed, rfb_new = imgui.color_edit3("Beam (focused)##rf_beam_picker", rfb, 4194304 | 32)
          end)
          if not rfb_ok then
            local rfb_4f = Vector4f.new(focused_laser_colors.beam[1], focused_laser_colors.beam[2], focused_laser_colors.beam[3], focused_laser_colors.beam[4] or 1.0)
            rfb_changed, rfb_new = imgui.color_edit4("Beam (focused)##rf_beam_picker", rfb_4f, 4194304 | 32)
            if rfb_new then
              focused_laser_colors.beam = {rfb_new.x, rfb_new.y, rfb_new.z, rfb_new.w}
            end
          else
            if rfb_new then
              focused_laser_colors.beam = rfb_new
            end
          end
          if imgui.is_item_hovered() then
              imgui.set_tooltip("Laser beam color while focused (_IsReticleFitting true)")
          end
          if rfb_changed then
              focused_laser_colors.runtime_beam_sig = nil
              save_config()
          end
      end
  end
  
  imgui.end_rect(1)
  
  if show_default_crosshair_laser_off then
  imgui.same_line()
  
  -- Crosshair section (to the right of Color Presets)
  imgui.begin_group()
  imgui.begin_rect()
  imgui.text_colored("Crosshair:", 0xFFFFFFAA)
  local ml_changed, ml_new = imgui.checkbox("Match laser color##match_laser_crosshair", default_crosshair_match_laser)
  if ml_changed then
      default_crosshair_match_laser = ml_new
      save_config()
  end
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Use the laser dot color for the crosshair when laser is off")
  end
  if not default_crosshair_match_laser then
    local dc_color = {
      default_crosshair_color_array[1] or 1.0,
      default_crosshair_color_array[2] or 1.0,
      default_crosshair_color_array[3] or 1.0
    }
    local dc_changed, dc_new
    local dc_ok = pcall(function()
      dc_changed, dc_new = imgui.color_edit3("Crosshair Color##default_crosshair_picker", dc_color, 4194304 | 32)
    end)
    if not dc_ok then
      local dc_4f = Vector4f.new(default_crosshair_color_array[1], default_crosshair_color_array[2], default_crosshair_color_array[3], default_crosshair_color_array[4] or 1.0)
      dc_changed, dc_new = imgui.color_edit4("Crosshair Color##default_crosshair_picker", dc_4f, 4194304 | 32)
      if dc_new then
        default_crosshair_color_array = {dc_new.x, dc_new.y, dc_new.z, dc_new.w}
      end
    else
      if dc_new then
        default_crosshair_color_array = dc_new
      end
    end
    if imgui.is_item_hovered() then
        imgui.set_tooltip("Color of the crosshair when laser is toggled off")
    end
    if dc_changed then
        save_config()
    end
  end
  imgui.text_colored("Select crosshair type:", 0xFFFFFFAA)
  imgui.set_next_item_width(110)
  local dcvt_changed, dcvt_new = imgui.combo("##crosshair_viewtype", default_crosshair_view_type, CROSSHAIR_TYPE_COMBO_LABELS)
  if dcvt_changed then
      default_crosshair_view_type = dcvt_new
      save_config()
  end
  if imgui.is_item_hovered() then
    imgui.set_tooltip(
      "Crosshair Type\n3D Crosshair: CANNOT BE USED WITH ANY WEAPON THAT HAS LASER TRAIL DISABLED IN Per-Weapon Laser Enable/Disable. Reticle tracks the muzzle in world space.\nDefault: native flat crosshair (center screen, *Bullet still spawn from muzzle if using with Iron Sights)."
    )
  end
  imgui.same_line()
  local dco_changed, dco_new = imgui.checkbox("Overlay##crosshair_overlay", default_crosshair_overlay)
  if dco_changed then
      default_crosshair_overlay = dco_new
      save_config()
  end
  imgui.same_line()
  local dcd_changed, dcd_new = imgui.checkbox("Detonemap##crosshair_detonemap", default_crosshair_detonemap)
  if dcd_changed then
      default_crosshair_detonemap = dcd_new
      save_config()
  end
  imgui.same_line()
  local dcdt_changed, dcdt_new = imgui.checkbox("Depth Test##crosshair_depthtest", default_crosshair_depth_test)
  if dcdt_changed then
      default_crosshair_depth_test = dcdt_new
      save_config()
  end
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Always show  when unchecked")
  end
  imgui.text_colored("Glow only applies when crosshair type is 3D Crosshair and Overlay is unchecked.", 0xFF888888)
  imgui.set_next_item_width(200)
  local dcs_changed, dcs_new = imgui.slider_float("Glow##crosshair_sat", default_crosshair_saturation, 0.0, 100.0, "%.1f")
  if dcs_changed then
      default_crosshair_saturation = dcs_new
      default_crosshair_overlay = false
      save_config()
  end
  if imgui.is_item_hovered() then
      imgui.set_tooltip("Glow/saturation of the crosshair when laser is off. Only has an effect when crosshair type is 3D Crosshair (not Default) and Overlay is unchecked.")
  end
  if not crosshair_combo_shows_3d_crosshair() then
    local chs_changed, chs_new = imgui.checkbox("Hide crosshair after shot (pistols only)##crosshair_hide_after_shot", post_shot.crosshair_after.enabled)
    if chs_changed then
        post_shot.crosshair_after.enabled = chs_new
        if not chs_new then
          post_shot.crosshair_after.weapon_id = nil
          post_shot.crosshair_after.effect_until = 0.0
        end
        save_config()
    end
    if imgui.is_item_hovered() then
      imgui.set_tooltip(
        "Pistols only: SG-09 R, Punisher, Red9, Blacktail, Matilda, Minecart Handgun, Broken Butterfly, Killer7, Handcannon, Sentinel Nine, Blacktail AC, Punisher MC, Red9 SW, XM96E1.\n"
        .. "After each shot, hide the crosshair for the duration below."
      )
    end
    if post_shot.crosshair_after.enabled then
      imgui.set_next_item_width(200)
      local cht_changed, cht_new = imgui.drag_float("Duration (sec)##crosshair_hide_after_shot_timer", post_shot.crosshair_after.timer_sec, 0.01, 0.01, 3.0, "%.2f")
      if cht_changed then
        post_shot.crosshair_after.timer_sec = math.max(0.01, math.min(10.0, cht_new))
        save_config()
      end
    end
  end
  imgui.end_rect(1)
  imgui.end_group()
  end
  
  imgui.spacing()

  imgui.begin_rect()
  imgui.text_colored(" Laser Dot/Beam Presets:", 0xFFFFFFAA)
  if imgui.button("Default Preset##default_dot_beam_preset") then
    crosshair_saturation = LASER_DOT_GLOW_DEFAULT
    _G.laser_mat_params = _G.laser_mat_params or {}
    local function default_params_for_material(matName)
      if not matName or matName == "" then return end
      _G.laser_mat_params[matName] = {}
      copy_laser_beam_material_defaults_into(_G.laser_mat_params[matName])
    end
    if laser_trail_gameobject then
      local ok_mc, mesh_component = pcall(function()
        return laser_trail_gameobject:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
      end)
      if ok_mc and mesh_component and mesh_component.get_MaterialNum then
        for j = 0, mesh_component:get_MaterialNum() - 1 do
          default_params_for_material(mesh_component:getMaterialName(j))
        end
        apply_laser_trail_settings()
      else
        default_params_for_material("wp4000_00_Laserbeam")
      end
    else
      default_params_for_material("wp4000_00_Laserbeam")
    end
    save_config()
  end
  if imgui.is_item_hovered() then
    imgui.set_tooltip("Restores laser dot Glow and all beam material sliders to the mod defaults (same as a fresh install for dot glow + beam MDF). Saves to config.")
  end
  imgui.same_line()
  if imgui.button("Ultra Bright Preset##ultra_bright_preset") then
    crosshair_saturation = 50.0
    dot_scale = 1.25
    _G.laser_mat_params = _G.laser_mat_params or {}
    local function ultra_bright_params_for_material(matName)
      if not matName or matName == "" then return end
      if not _G.laser_mat_params[matName] then _G.laser_mat_params[matName] = {} end
      _G.laser_mat_params[matName].AlphaRate = 0.5
      _G.laser_mat_params[matName].SmokeContrast_Pow = 0.0
    end
    if laser_trail_gameobject then
      local ok_mc, mesh_component = pcall(function()
        return laser_trail_gameobject:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
      end)
      if ok_mc and mesh_component and mesh_component.get_MaterialNum then
        for j = 0, mesh_component:get_MaterialNum() - 1 do
          ultra_bright_params_for_material(mesh_component:getMaterialName(j))
        end
        apply_laser_trail_settings()
      else
        ultra_bright_params_for_material("wp4000_00_Laserbeam")
      end
    else
      ultra_bright_params_for_material("wp4000_00_Laserbeam")
    end
    save_config()
  end
  if imgui.is_item_hovered() then
    imgui.set_tooltip("Sets laser dot Glow to 50, Dot/Crosshair scale to 1.25, beam AlphaRate to 0.5, and SmokeContrast_Pow to 0.0 on each trail material (or wp4000_00_Laserbeam when trail is inactive). Saves to config.")
  end
  imgui.end_rect(1)
  imgui.spacing()
  
  -- Laser/Knife Dot Settings
  imgui.begin_rect()
  imgui.text_colored(" Laser/Knife Dot/Crosshhair Settings:", 0xFFFFFFAA)
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
  
  scale_changed, dot_scale = imgui.slider_float("Dot/Crosshair Scale", dot_scale, 0.1, 10.0, "%.2f")
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
      
      -- Set hardcoded defaults for laser beam material parameters
      if not _G.laser_mat_params_defaults["wp4000_00_Laserbeam"] then
        _G.laser_mat_params_defaults["wp4000_00_Laserbeam"] = {}
        copy_laser_beam_material_defaults_into(_G.laser_mat_params_defaults["wp4000_00_Laserbeam"])
      end
      
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
  local changed_x, new_x = imgui.drag_float("X Offset##laser_origin_x", offset.x, 0.0005, -1, 1, "%.4f")
  local changed_y, new_y = imgui.drag_float("Y Offset##laser_origin_y", offset.y, 0.0005, -1, 1, "%.4f")
  local changed_z, new_z = imgui.drag_float("Z Offset##laser_origin_z", offset.z, 0.0005, -1, 1, "%.4f")
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
      dot_scale = 1.0
      knife_dot_scale = 1.0
      crosshair_saturation = LASER_DOT_GLOW_DEFAULT
      static_center_dot = false
      update_spawn_flag()
      simple_static_mode = false
      disable_shoulder_corrector = false
      hide_dot_when_no_muzzle = false
      show_default_crosshair_laser_off = true
      default_crosshair_color_array = {1.0, 1.0, 1.0, 1.0}
      default_crosshair_match_laser = false
      default_crosshair_saturation =1.0
      default_crosshair_view_type = 1
      default_crosshair_overlay = true
      default_crosshair_detonemap = true
      default_crosshair_depth_test = false
      post_shot.crosshair_after.enabled = false
      post_shot.crosshair_after.timer_sec = 0.25
      post_shot.crosshair_after.effect_until = 0.0
      post_shot.crosshair_after.weapon_id = nil
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
    
    -- Set hardcoded defaults for laser beam material parameters
    if not _G.laser_mat_params_defaults then _G.laser_mat_params_defaults = {} end
    _G.laser_mat_params_defaults["wp4000_00_Laserbeam"] = {}
    copy_laser_beam_material_defaults_into(_G.laser_mat_params_defaults["wp4000_00_Laserbeam"])
    
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
      dot_scale = 1.0
      knife_dot_scale = 1.0
      disable_shoulder_corrector = false
      perfect_accuracy_only_when_laser_active = false
      perfect_focus_only_when_laser_active = false
      classic_laser_trail_effective_prev = nil
      _G.classic_re4_laser_perfect_accuracy_enabled = true
      _G.classic_re4_laser_point_range_enabled = true
      force_spread_update = true
      hide_dot_when_no_muzzle = false
      show_default_crosshair_laser_off = true
      default_crosshair_color_array = {1.0, 1.0, 1.0, 1.0}
      default_crosshair_match_laser = false
      default_crosshair_saturation =1.0
      default_crosshair_view_type = 1
      default_crosshair_overlay = true
      default_crosshair_detonemap = true
      default_crosshair_depth_test = false
      post_shot.crosshair_after.enabled = false
      post_shot.crosshair_after.timer_sec = 0.25
      post_shot.crosshair_after.effect_until = 0.0
      post_shot.crosshair_after.weapon_id = nil
      laser_beam_color_array = {1.0, 0.0, 0.0, 1.0}
      laser_dot_color_array = {1.0, 0.0, 0.0, 1.0}
      knife_dot_color_array = {1.0, 1.0, 1.0, 1.0}
      laser_color_array = {1.0, 0.0, 0.0, 1.0}
      focused_laser_colors.enabled = false
      focused_laser_colors.dot = {0.0, 1.0, 0.0, 1.0}
      focused_laser_colors.beam = {0.0, 1.0, 0.0, 1.0}
      focused_laser_colors.runtime_beam_sig = nil
      focused_laser_colors.match_focused_dot_beam = false
      focused_laser_colors.glow = LASER_DOT_GLOW_DEFAULT
      post_shot.match_main_dot_beam = false
      crosshair_saturation = LASER_DOT_GLOW_DEFAULT
      static_center_dot = false
      update_spawn_flag()
      static_lerp_speed = 50.0
      simple_static_mode = false
      enable_laser_trail = true
      laser_trail_scale = 1.5
      post_shot.hide_laser = false
      post_shot.timer_sec = 0.2
      post_shot.restrict_list = false
      post_shot.weapon_ids = {}
      post_shot.dim_enabled = false
      post_shot.dim_restrict_list = false
      post_shot.dim_weapon_ids = {}
      post_shot.dim_dot_scale = 0.95
      post_shot.dim_glow_saturation = 1.0
      post_shot.dim_intensity_dim = 1.0
      post_shot.firing_mode = nil
      post_shot.per_weapon = {}
      hide_dot_when_no_muzzle = false
      show_default_crosshair_laser_off = true
      default_crosshair_color_array = {1.0, 1.0, 1.0, 1.0}
      default_crosshair_match_laser = false
      default_crosshair_saturation =1.0
      default_crosshair_view_type = 1
      default_crosshair_overlay = true
      default_crosshair_detonemap = true
      default_crosshair_depth_test = false
      -- Reset laser origin offsets to defaults
      laser_origin_offsets = {}
      for weapon_id, offset in pairs(default_laser_origin_offsets) do
          laser_origin_offsets[weapon_id] = {x = offset.x, y = offset.y, z = offset.z}
      end
      
      -- Reset beam material parameters if laser trail exists (before clearing defaults)
      if is_laser_trail_valid() then
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
  --[[ Debug: 6304 Panel Visibility Tester (commented out)
  if current_weapon_id == 6304 then
    imgui.spacing()
    if imgui.tree_node("[DEBUG] 6304 Panel Inspector") then
      imgui.begin_rect()
      imgui.text_colored("Live panel visibility for Compound Bow (6304):", 0xFFFFFFAA)
      imgui.text_colored("Captures ALL gui elements from draw callback.", 0xFF88FFFF)
      local captured = _G._dbg_6304_captured_gos or {}
      imgui.text("Captured GUI objects: " .. tostring(#captured))
      for ci, entry in ipairs(captured) do
        pcall(function()
          local go = entry.go
          local go_name = entry.name or "?"
          local go_addr = tostring(go)
          imgui.spacing()
          imgui.text_colored(" [" .. ci .. "] " .. go_name .. " (" .. go_addr .. "):", 0xFF00FFAA)
          local beh = go:call("getComponent(System.Type)", T_RETICLE_GUI_BEHAVIOR)
          if beh then
            imgui.same_line()
            imgui.text_colored("has ReticleGuiBehavior", 0xFF00FF00)
            local all_panels = {"TYPE00Panel","TYPE01Panel","TYPE02Panel","TYPE04Panel","TYPE05Panel","TYPE06Panel","TYPE07Panel","TYPE08Panel","TYPE09Panel","TYPE10Panel","TYPE90Panel","CurrWeaponPanel","ColorPanel","TypePanel"}
            for _, pname in ipairs(all_panels) do
              local ok, panel = pcall(function() return beh:get_field(pname) end)
              if ok and panel then
                local ok2, vis = pcall(function() return panel:call("get_Visible") end)
                if ok2 then
                  local changed, new_vis = imgui.checkbox(pname .. "##" .. go_addr, vis)
                  if changed then
                    pcall(function() panel:call("set_Visible", new_vis) end)
                  end
                  imgui.same_line()
                  imgui.text_colored(tostring(panel), 0xFF888888)
                else
                  imgui.text(pname .. ": (get_Visible failed)")
                end
              else
                imgui.text_colored(pname .. ": nil", 0xFF666666)
              end
            end
          else
            imgui.same_line()
            imgui.text_colored("no ReticleGuiBehavior", 0xFFFF4444)
            local gui = nil
            pcall(function() gui = go:call("getComponent(System.Type)", sdk.typeof("via.gui.GUI")) end)
            if gui then
              local view = nil
              pcall(function() view = gui:call("get_View") end)
              if view then
                local overlay = nil
                local viewType = nil
                pcall(function() overlay = view:call("get_Overlay") end)
                pcall(function() viewType = view:call("get_ViewType") end)
                imgui.text("  Overlay=" .. tostring(overlay) .. " ViewType=" .. tostring(viewType))
                local ov_changed, ov_new = imgui.checkbox("Overlay##" .. go_addr, overlay == true)
                if ov_changed then pcall(function() view:call("set_Overlay", ov_new) end) end
              end
            end
            local tr = nil
            pcall(function() tr = go:call("get_Transform") end)
            if tr then
              local childCount = 0
              pcall(function() childCount = tr:call("get_ChildCount") end)
              imgui.text("  Children: " .. tostring(childCount))
            end
          end
        end)
      end
      if imgui.button("Clear Captured") then
        _G._dbg_6304_captured_gos = {}
      end
      imgui.end_rect(1)
      imgui.tree_pop()
    end
  end
  --]]

  imgui.end_rect(1)
  imgui.tree_pop()
  end
end)

load_config()