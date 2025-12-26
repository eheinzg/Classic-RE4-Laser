-- Inline Statics so this module is self-contained and doesn't require utility/Statics. I referenced this from Praydog's utility scripts
local Statics = {}

function Statics.generate(typename, double_ended)
  local double_ended = double_ended or false

  local t = sdk.find_type_definition(typename)
  if not t then return {} end

  local fields = t:get_fields()
  local enum = {}

  for i, field in ipairs(fields) do
    if field:is_static() then
      local name = field:get_name()
      local raw_value = field:get_data(nil)

      -- Uncomment for debugging
      -- log.info(name .. " = " .. tostring(raw_value))

      enum[name] = raw_value

      if double_ended then
        enum[raw_value] = name
      end
    end
  end

  return enum
end

function Statics.generate_global(typename)
  -- Split typename on '.' to build nested global tables
  local parts = {}

  for part in typename:gmatch("[^%.]+") do
    table.insert(parts, part)
  end

  local global = _G
  for i, part in ipairs(parts) do
    if not global[part] then
      global[part] = {}
    end

    global = global[part]
  end

  if global ~= _G then
    local static_class = Statics.generate(typename)

    for k, v in pairs(static_class) do
      global[k] = v
      global[v] = k
    end
  end

  return global
end

local statics = Statics

local CastRays = {}

local CollisionLayer = statics.generate(sdk.game_namespace("CollisionUtil.Layer"))
local CollisionFilter = statics.generate(sdk.game_namespace("CollisionUtil.Filter"))

local cast_ray_async_method = sdk.find_type_definition("via.physics.System"):get_method("castRayAsync(via.physics.CastRayQuery, via.physics.CastRayResult)")

local function cast_ray_async(ray_result, start_pos, end_pos, layer, filter_info)
  if layer == nil then
    layer = CollisionLayer.Bullet
  end

  local via_physics_system = sdk.get_native_singleton("via.physics.System")
  local ray_query = sdk.create_instance("via.physics.CastRayQuery")
  local ray_result = ray_result or sdk.create_instance("via.physics.CastRayResult")

  ray_query:call("setRay(via.vec3, via.vec3)", start_pos, end_pos)
  ray_query:call("clearOptions")
  ray_query:call("enableAllHits")
  ray_query:call("enableNearSort")

  if filter_info == nil then
    filter_info = ray_query:call("get_FilterInfo")
    filter_info:call("set_Group", 0)
    filter_info:call("set_MaskBits", 0xFFFFFFFF & ~1) -- everything except the player.
    filter_info:call("set_Layer", layer)
  end

  ray_query:call("set_FilterInfo", filter_info)
  cast_ray_async_method:call(via_physics_system, ray_query, ray_result)

  return ray_result
end

CastRays.cast_ray_async = cast_ray_async
CastRays.CollisionLayer = CollisionLayer
CastRays.CollisionFilter = CollisionFilter

return CastRays
