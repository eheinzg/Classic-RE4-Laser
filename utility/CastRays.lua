local statics = require("utility/Statics")

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
