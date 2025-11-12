--[[pod_format="raw",created="2025-11-12 00:00:00",modified="2025-11-12 00:00:00",revision=1]]
-- r_view.lua
-- Camera basis and ray direction LUT computation

local r_view = {}
local assert_lib = include"lib/assert.lua"

local NORMALIZED_EPSILON = 0.000001

-- Cached state to detect changes
local last_ray_count = 0
local last_fov = 0

-- Camera basis vectors (cached per frame)
r_view.forward_x = 0
r_view.forward_y = 0
r_view.right_x = 0
r_view.right_y = 0

-- Projection distance (cached, recomputed when FOV changes)
r_view.sdist = 200

-- Update camera basis and ray direction LUTs
-- camera: {x, y, a} table with position and angle
-- r_state: renderer state with buffers
-- fov: field of view (half-angle in radians)
-- active_ray_count: current ray budget (can be < r_state.config.ray_count)
function r_view.update(camera, r_state, fov, active_ray_count)
  local cfg = r_state.config
  local ray_cnt = active_ray_count or cfg.ray_count
  local screen_center_x = cfg.screen_width / 2
  
  -- Recompute projection distance if FOV changed
  if fov ~= last_fov then
    r_view.sdist = screen_center_x / math.tan(fov)
    last_fov = fov
  end
  
  -- Update camera basis (cached sin/cos)
  local sa = sin(camera.a)
  local ca = cos(camera.a)
  
  r_view.forward_x = ca
  r_view.forward_y = sa
  r_view.right_x = -sa
  r_view.right_y = ca
  
  -- Rebuild ray direction LUTs only if ray count changed
  if ray_cnt ~= last_ray_count then
    local bufs = r_state.buffers
    
    for i = 0, ray_cnt - 1 do
      -- Compute screen span for this ray
      local x0 = math.floor(i * cfg.screen_width / ray_cnt)
      local x1 = math.max(x0, math.floor((i + 1) * cfg.screen_width / ray_cnt) - 1)
      local pixel_x = (x0 + x1) / 2 + 0.5
      
      bufs.ray_x0:set(i, x0)
      bufs.ray_x1:set(i, x1)
      bufs.ray_px_center:set(i, pixel_x)
    end
    
    last_ray_count = ray_cnt
    printh("[r_view] rebuilt LUTs for " .. ray_cnt .. " rays")
  end
  
  -- Compute ray directions in world space
  local bufs = r_state.buffers
  for i = 0, ray_cnt - 1 do
    local pixel_x = bufs.ray_px_center:get(i)
    local dx = pixel_x - screen_center_x
    local dy = r_view.sdist

    -- Transform camera-space direction to world-space
    -- ray_dir = right * dx + forward * dy
    local world_dx = r_view.right_x * dx + r_view.forward_x * dy
    local world_dy = r_view.right_y * dx + r_view.forward_y * dy

    -- Normalize ray direction to unit vector (critical for DDA math)
    local mag_sq = world_dx * world_dx + world_dy * world_dy
    if mag_sq > 0 then
      local inv_mag = 1 / math.sqrt(mag_sq)
      world_dx = world_dx * inv_mag
      world_dy = world_dy * inv_mag
    end

    -- Contract assertion: rays must be normalized unit vectors
    local final_mag_sq = world_dx * world_dx + world_dy * world_dy
    assert_lib.is_true(math.abs(final_mag_sq - 1) < NORMALIZED_EPSILON,
      string.format("r_view: ray %d not normalized (magnitude squared: %.6f)", i, final_mag_sq))

    bufs.ray_dir_x:set(i, world_dx)
    bufs.ray_dir_y:set(i, world_dy)
  end
  
  r_state.occupancy.rays_active = ray_cnt
end

-- Contract verification harness
-- Call after update() to verify ray normalization
function r_view.verify_contract(r_state)
  local bufs = r_state.buffers
  local ray_cnt = r_state.occupancy.rays_active

  printh("[r_view] verifying contract for " .. ray_cnt .. " rays...")

  -- Verify ray normalization
  local violations = 0
  for i = 0, math.min(ray_cnt - 1, 4) do  -- Check first 5 rays
    local dx = bufs.ray_dir_x:get(i)
    local dy = bufs.ray_dir_y:get(i)
    local mag_sq = dx * dx + dy * dy
    local mag_error = math.abs(mag_sq - 1)

    if mag_error >= NORMALIZED_EPSILON then
      printh(string.format("  ray %d: magnitude error %.6f (dx=%.3f, dy=%.3f)", i, mag_error, dx, dy))
      violations = violations + 1
    end
  end

  if violations == 0 then
    printh("[r_view] contract verification PASSED")
    return true
  else
    printh("[r_view] contract verification FAILED (" .. violations .. " violations)")
    return false
  end
end

return r_view

