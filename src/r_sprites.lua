--[[pod_format="raw",created="2025-11-12 00:00:00",modified="2025-11-12 00:00:00",revision=1]]
-- r_sprites.lua
-- Depth-bucketed sprite renderer with impostor fallback

local r_sprites = {}

-- Note: Sprite buckets now use userdata buffers from r_state
-- Each bucket stores object indices (not object references) to avoid GC pressure
-- Buckets are stored as flat arrays: [bucket0_obj1, bucket0_obj2, ..., bucket1_obj1, ...]
-- bucket_counts tracks how many objects in each bucket

local function clear_buckets(r_state)
  -- Zero out bucket counts (userdata stays allocated)
  for i = 0, r_state.config.sprite_bucket_count - 1 do
    r_state.buffers.sprite_bucket_counts:set(i, 0)
  end
end

-- Draw single sprite with z-buffer occlusion
local function draw_sprite(ob, camera, r_view, r_state, r_batch, game_state)
  if not ob or not ob.typ or not ob.rel then
    return
  end
  
  local t = ob.typ
  local x = ob.rel[1]  -- camera-space x
  local z = ob.rel[2]  -- camera-space z (depth)
  local sdist = r_view.sdist
  local cfg = r_state.config
  local screen_center_x = cfg.screen_width / 2
  local screen_center_y = cfg.screen_height / 2
  local sprite_size = game_state.sprite_size or 32
  
  -- Fetch sprite index
  local base_sprite_index = ob.sprite_index or t.mx
  local sprite_index = base_sprite_index
  
  -- Handle animation
  if t.framect then
    local fr = math.floor(ob.frame or 0)
    if ob.animloop then
      fr = fr % t.framect
    else
      fr = math.min(fr, t.framect - 1)
    end
    sprite_index = base_sprite_index + fr
  end
  
  -- Validate sprite exists
  local src = game_state.get_spr(sprite_index)
  if not src then
    if sprite_index ~= base_sprite_index then
      sprite_index = base_sprite_index
    end
    src = game_state.get_spr(sprite_index)
  end
  
  if not src then
    src = game_state.error_textures.sprite or game_state.error_textures.default
  end
  
  -- Get vertical offset
  local y = ob.y or t.y
  if t.yoffs then
    local frame = ob.frame or 0
    local frame_idx = math.floor(frame % #t.yoffs) + 1
    if frame_idx > 0 and frame_idx <= #t.yoffs then
      y = y + t.yoffs[frame_idx]
    end
  end
  
  -- LOD: impostor rendering for distant sprites
  local sprite_lod_distance = game_state.fog_far * game_state.sprite_lod_ratio
  if z > sprite_lod_distance then
    -- Sample average color from sprite center
    local avg_color = 5
    if src and src.get then
      avg_color = src:get(16, 16) or 5
    end
    
    -- Project to screen space
    local f_lod = sdist / z
    local sx_lod = x * f_lod + screen_center_x
    local w_lod = t.w * f_lod
    
    -- Compute vertical span
    local y0_lod, y1_lod
    if t.flat then
      local z0 = z + t.w / 2
      local z1 = z - t.w / 2
      y0_lod = y * sdist / z0 + screen_center_y
      y1_lod = y * sdist / z1 + screen_center_y
    else
      local sy_lod = y * f_lod + screen_center_y
      local h_lod = t.h * f_lod
      y0_lod = sy_lod - h_lod / 2
      y1_lod = sy_lod + h_lod / 2
    end
    
    -- Clamp to screen bounds
    local x0 = math.max(0, math.ceil(sx_lod - w_lod / 2))
    local x1 = math.min(cfg.screen_width - 1, math.floor(sx_lod + w_lod / 2))
    y0_lod = math.max(0, math.ceil(y0_lod))
    y1_lod = math.min(cfg.screen_height - 1, math.floor(y1_lod))
    
    -- Draw impostor columns with z-test
    if y1_lod > y0_lod and x1 >= x0 then
      r_batch.rect_reset()
      for px = x0, x1 do
        local zb = r_state.zread(px)
        if z < zb then
          r_batch.rect_push(px, y0_lod, px, y1_lod, avg_color)
          r_state.zwrite(px, z)
        end
      end
      r_batch.rect_submit()
    end
    
    return
  end
  
  -- Full texture rendering
  local f = sdist / z
  local sx = x * f + screen_center_x
  local w = t.w * f
  
  -- Calculate y coordinates
  local y0, y1
  if t.flat then
    local z0 = z + t.w / 2
    local z1 = z - t.w / 2
    y0 = y * sdist / z0 + screen_center_y
    y1 = y * sdist / z1 + screen_center_y
  else
    local sy = y * f + screen_center_y
    local h = t.h * f
    y0 = sy - h / 2
    y1 = sy + h / 2
  end
  
  -- Map to UV space
  local sxd = sprite_size / w
  local syd = sprite_size / (y1 - y0 + 0.01)
  local u0 = 0
  local v0 = 0
  
  -- Clamp to screen bounds
  local lx = sx - w / 2
  local fy0 = y0
  local x0 = math.max(0, math.ceil(lx))
  local x1 = math.min(cfg.screen_width - 1, math.floor(sx + w / 2))
  
  if x0 > lx then
    u0 = u0 + (x0 - lx) * sxd
  end
  
  y0 = math.max(0, math.ceil(fy0))
  y1 = math.min(cfg.screen_height - 1, math.floor(y1))
  
  if y0 > fy0 then
    v0 = v0 + (y0 - fy0) * syd
  end
  
  -- Guard against degenerate span
  if y1 <= y0 or x1 < x0 then
    return
  end
  
  -- Draw sprite column-by-column with z-buffer
  local spr_idx = sprite_index
  r_batch.tline_reset()
  for px = x0, x1 do
    local zb = r_state.zread(px)
    if z < zb then
      local u = u0 + (px - x0) * sxd
      r_batch.tline_push(spr_idx, px, y0, px, y1, u, v0, u, v0 + sprite_size, 1, 1)
      r_state.zwrite(px, z)
    end
  end
  r_batch.tline_submit()
end

-- Render all sprites with depth bucketing
-- camera: {x, y} position
-- r_view: view module with forward/right vectors
-- r_state: renderer state
-- r_batch: batch module
-- game_state: {objects, far_plane, sprite_lod_ratio, fog_far, sprite_size, get_spr, error_textures}
function r_sprites.draw(camera, r_view, r_state, r_batch, game_state)
  local cfg = r_state.config
  local sa, ca = sin(camera.a), cos(camera.a)
  local bucket_size = game_state.far_plane / 8
  local bufs = r_state.buffers
  local bucket_count = cfg.sprite_bucket_count
  local bucket_capacity = cfg.sprite_bucket_capacity
  
  clear_buckets(r_state)
  
  -- Build object index list (for stable bucket storage)
  local obj_list = game_state.objects
  local obj_count = #obj_list
  
  -- Transform sprites to camera space and bucket by depth
  for obj_idx = 1, obj_count do
    local ob = obj_list[obj_idx]
    if ob and ob.pos and ob.typ then
      -- Transform to view space
      local rx = ob.pos[1] - camera.x
      local ry = ob.pos[2] - camera.y
      
      -- Simple distance culling
      if abs(rx) >= game_state.far_plane or abs(ry) >= game_state.far_plane then
        goto skip_sprite
      end
      
      -- Rotate to camera space
      local x_cam = -sa * rx + ca * ry
      local z_cam = ca * rx + sa * ry
      ob.rel = ob.rel or {}
      ob.rel[1] = x_cam
      ob.rel[2] = z_cam
      
      -- Far-plane culling
      if ob.rel[2] > game_state.far_plane then
        goto skip_sprite
      end
      
      -- Frustum culling
      local t = ob.typ
      local pass_frustum = false
      if ob.rel[2] > 0.1 then
        if t.flat then
          if ob.rel[2] >= t.w / 2 then
            pass_frustum = true
          end
        else
          if abs(ob.rel[1]) - (t.w / 2) < ob.rel[2] * (cfg.screen_width / 2 / r_view.sdist) then
            pass_frustum = true
          end
        end
      end
      
      if pass_frustum then
        local bucket_idx = math.min(bucket_count - 1, math.floor(ob.rel[2] / bucket_size))
        local count = bufs.sprite_bucket_counts:get(bucket_idx)
        
        -- Check capacity
        if count < bucket_capacity then
          local base = bucket_idx * bucket_capacity
          bufs.sprite_bucket_indices:set(base + count, obj_idx)
          bufs.sprite_bucket_depths:set(base + count, ob.rel[2])
          bufs.sprite_bucket_counts:set(bucket_idx, count + 1)
        end
      end
      
      ::skip_sprite::
    end
  end
  
  -- Draw sprites back-to-front
  palt(0, false)
  palt(14, true)
  
  for bucket_idx = bucket_count - 1, 0, -1 do
    local count = bufs.sprite_bucket_counts:get(bucket_idx)
    
    -- Sort bucket by z descending (far to near) using insertion sort
    if count > 4 then
      local base = bucket_idx * bucket_capacity
      for i = 1, count - 1 do
        local idx_i = bufs.sprite_bucket_indices:get(base + i)
        local z_i = bufs.sprite_bucket_depths:get(base + i)
        local j = i - 1
        while j >= 0 and bufs.sprite_bucket_depths:get(base + j) < z_i do
          bufs.sprite_bucket_indices:set(base + j + 1, bufs.sprite_bucket_indices:get(base + j))
          bufs.sprite_bucket_depths:set(base + j + 1, bufs.sprite_bucket_depths:get(base + j))
          j = j - 1
        end
        bufs.sprite_bucket_indices:set(base + j + 1, idx_i)
        bufs.sprite_bucket_depths:set(base + j + 1, z_i)
      end
    end
    
    -- Draw all sprites in bucket
    local base = bucket_idx * bucket_capacity
    for i = 0, count - 1 do
      local obj_idx = bufs.sprite_bucket_indices:get(base + i)
      local ob = obj_list[obj_idx]
      draw_sprite(ob, camera, r_view, r_state, r_batch, game_state)
    end
  end
  
  palt()
  r_state.occupancy.sprite_count = r_state.occupancy.sprite_count + #game_state.objects
end

return r_sprites

