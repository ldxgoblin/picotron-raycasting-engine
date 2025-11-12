--[[pod_format="raw",created="2025-11-12 00:00:00",modified="2025-11-12 00:00:00",revision=1]]
-- r_cast.lua
-- DDA raycaster writing hit data to userdata buffers

local r_cast = {}

-- Sign helper
local function sgn(n)
  if n < 0 then return -1 end
  if n > 0 then return 1 end
  return 0
end

-- DDA raycast with depth tracking
-- Returns: z, hit_x, hit_y, tile, tx
local function raycast_dda(x, y, dx, dy, fx, fy, far_plane, map_size, get_wall_fn, is_door_fn, doorgrid, test_door_mode, test_door_open)
  -- Clamp near-zero components
  if abs(dx) < 0.01 then dx = 0.01 end
  if abs(dy) < 0.01 then dy = 0.01 end
  
  -- Horizontal ray initialization
  local hx, hy, hdx, hdy = x, y, sgn(dx), dy / abs(dx)
  local hdz = hdx * fx + hdy * fy
  local hz = 0
  
  -- Step to grid boundary
  local fracx = hx % 1
  local hstep = (hdx > 0) and (1 - fracx) or fracx
  hx = hx + hdx * hstep
  hy = hy + hdy * hstep
  hz = hz + hdz * hstep
  
  -- Vertical ray initialization
  local vx, vy, vdx, vdy = x, y, dx / abs(dy), sgn(dy)
  local vdz = vdx * fx + vdy * fy
  local vz = 0
  
  -- Step to grid boundary
  local fracy = vy % 1
  local vstep = (vdy > 0) and (1 - fracy) or fracy
  vx = vx + vdx * vstep
  vy = vy + vdy * vstep
  vz = vz + vdz * vstep
  
  -- Compute iteration limit
  local horizontal_crossings = (hdx > 0) and (map_size - math.floor(hx)) or (math.floor(hx) + 1)
  local vertical_crossings = (vdy > 0) and (map_size - math.floor(vy)) or (math.floor(vy) + 1)
  local iteration_limit = min(256, horizontal_crossings + vertical_crossings + 10)
  
  -- Ray marching
  for iter = 1, iteration_limit do
    -- Far-plane check
    if min(hz, vz) > far_plane then
      return 999, hx, hy, 0, 0
    end
    
    if hz < vz then
      -- Horizontal crossing (vertical gridline)
      local gx = math.floor(hx) + ((hdx < 0) and -1 or 0)
      local gy = math.floor(hy)
      
      -- OOB check
      if (gx < 0 and hdx < 0) or (gx >= map_size and hdx > 0) or 
         (gy < 0 and hdy < 0) or (gy >= map_size and hdy > 0) then
        return 999, hx, hy, 0, 0
      end
      
      if gx >= 0 and gx < map_size and gy >= 0 and gy < map_size then
        local m = get_wall_fn(gx, gy)
        if m > 0 then
          -- Check if door
          if is_door_fn(m) and doorgrid[gx] and doorgrid[gx][gy] then
            local dz = ((hx + hdx / 2 - x) * fx + (hy + hdy / 2 - y) * fy)
            if dz <= vz then
              local open = test_door_mode and (test_door_open or 0) or doorgrid[gx][gy].open
              local dy_off = (hy + hdy / 2) % 1 - open
              if dy_off >= 0 then
                return dz, hx, hy, m, dy_off
              end
            end
          else
            -- Wall hit
            local z = ((hx - x) * fx + (hy - y) * fy)
            local frac = hy - math.floor(hy)
            local tx = (hdx > 0) and (1 - frac) or frac
            return z, hx, hy, m, tx
          end
        end
      end
      
      hx = hx + hdx
      hy = hy + hdy
      hz = hz + hdz
    else
      -- Vertical crossing (horizontal gridline)
      local gx = math.floor(vx)
      local gy = math.floor(vy) + ((vdy < 0) and -1 or 0)
      
      -- OOB check
      if (gx < 0 and vdx < 0) or (gx >= map_size and vdx > 0) or 
         (gy < 0 and vdy < 0) or (gy >= map_size and vdy > 0) then
        return 999, vx, vy, 0, 0
      end
      
      if gx >= 0 and gx < map_size and gy >= 0 and gy < map_size then
        local m = get_wall_fn(gx, gy)
        if m > 0 then
          -- Check if door
          if is_door_fn(m) and doorgrid[gx] and doorgrid[gx][gy] then
            local dz = ((vx + vdx / 2 - x) * fx + (vy + vdy / 2 - y) * fy)
            if dz <= hz then
              local open = test_door_mode and (test_door_open or 0) or doorgrid[gx][gy].open
              local dx_off = (vx + vdx / 2) % 1 - open
              if dx_off >= 0 then
                return dz, vx, vy, m, dx_off
              end
            end
          else
            -- Wall hit
            local z = ((vx - x) * fx + (vy - y) * fy)
            local frac = vx - math.floor(vx)
            local tx = (vdy < 0) and (1 - frac) or frac
            return z, vx, vy, m, tx
          end
        end
      end
      
      vx = vx + vdx
      vy = vy + vdy
      vz = vz + vdz
    end
  end
  
  -- Fallback
  return 999, hx, hy, 0, 0
end

-- Cast scene: populate ray hit buffers
-- camera: {x, y} position table
-- r_view: view module with forward/right vectors
-- r_state: renderer state with buffers
-- game_state: {get_wall, is_door, doorgrid, test_door_mode, test_door_open, far_plane, map_size}
function r_cast.cast_scene(camera, r_view, r_state, game_state)
  local bufs = r_state.buffers
  local ray_cnt = r_state.occupancy.rays_active
  local fx, fy = r_view.forward_x, r_view.forward_y
  
  for i = 0, ray_cnt - 1 do
    local dx = bufs.ray_dir_x:get(i)
    local dy = bufs.ray_dir_y:get(i)
    
    local z, hx, hy, tile, tx = raycast_dda(
      camera.x, camera.y, dx, dy, fx, fy,
      game_state.far_plane, game_state.map_size,
      game_state.get_wall, game_state.is_door,
      game_state.doorgrid, game_state.test_door_mode, game_state.test_door_open
    )
    
    bufs.ray_z:set(i, z)
    bufs.ray_hitx:set(i, hx)
    bufs.ray_hity:set(i, hy)
    bufs.ray_tile:set(i, tile)
    bufs.ray_tx:set(i, tx)
  end
end

return r_cast

