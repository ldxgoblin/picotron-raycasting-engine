--[[pod_format="raw",created="2025-11-12 00:00:00",modified="2025-11-12 00:00:00",revision=1]]
-- r_view.lua
-- Camera basis and ray direction LUT computation

local r_view = {}

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
    
    bufs.ray_dir_x:set(i, world_dx)
    bufs.ray_dir_y:set(i, world_dy)
  end
  
  r_state.occupancy.rays_active = ray_cnt
end

return r_view

