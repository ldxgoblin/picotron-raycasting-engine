--[[pod_format="raw",created="2025-11-12 00:00:00",modified="2025-11-12 00:00:00",revision=1]]
-- r_walls.lua
-- Span batcher for wall rendering with LOD

local r_walls = {}

-- Texture cache (sprite index -> {src, is_fallback})
local tex_cache = {}
local avg_color_cache = {}

-- Resolve sprite index with fallback to error textures
local function resolve_sprite_index(idx, kind, error_idx_table, get_spr_fn)
  if idx and get_spr_fn(idx) then
    return idx
  end
  if error_idx_table then
    if kind == "door" then return error_idx_table.door
    else return error_idx_table.wall end
  end
  return 0
end

-- Get texture source with caching
local function get_texture_source(sprite_index, obj_type, get_spr_fn, error_textures)
  sprite_index = sprite_index or 0
  obj_type = obj_type or "default"
  
  -- Check cache
  local cached = tex_cache[sprite_index]
  if cached then
    return cached.src, cached.is_fallback
  end
  
  -- Try to fetch sprite
  local src = get_spr_fn(sprite_index)
  if not src then
    -- Use error texture
    local err_tex = error_textures[obj_type] or error_textures.default
    tex_cache[sprite_index] = {src = err_tex, is_fallback = true}
    return err_tex, true
  end
  
  tex_cache[sprite_index] = {src = src, is_fallback = false}
  return src, false
end

-- Get average color with caching
local function get_avg_color(tile, get_spr_fn, error_textures, is_door_fn)
  local avg = avg_color_cache[tile]
  if avg then return avg end
  
  local obj_type = is_door_fn and is_door_fn(tile) and "door" or "wall"
  local src, is_fallback = get_texture_source(tile, obj_type, get_spr_fn, error_textures)
  
  avg = 5  -- default fog color
  if src and src.get then
    avg = src:get(16, 16) or 5
  end
  
  avg_color_cache[tile] = avg
  return avg
end

-- Draw wall spans with LOD and batching
-- camera: {x, y} position
-- r_view: view module with forward vectors and sdist
-- r_state: renderer state with buffers
-- r_batch: batch module
-- game_state: {wall_lod_distance, wall_tiny_screen_px, sprite_size, is_door, get_spr, error_textures, ERROR_IDX}
function r_walls.draw_spans(camera, r_view, r_state, r_batch, game_state)
  local bufs = r_state.buffers
  local ray_cnt = r_state.occupancy.rays_active
  local cfg = r_state.config
  local screen_center_y = cfg.screen_height / 2
  local fwdx, fwdy = r_view.forward_x, r_view.forward_y
  local sdist = r_view.sdist
  local tex_size = game_state.sprite_size or 32
  
  r_batch.rect_reset()
  r_batch.tline_reset()
  
  -- Span merging state
  local span_start = nil
  local span_tile = nil
  local span_spr = nil
  local span_avg = nil
  local span_tx0, span_tx1 = nil, nil
  local span_hitx0, span_hity0 = nil, nil
  local span_hitx1, span_hity1 = nil, nil
  
  local function flush_span(span_end)
    if not span_start then return end
    
    local x0 = bufs.ray_x0:get(span_start)
    local x1 = bufs.ray_x1:get(span_end)
    if x0 > x1 then span_start = nil return end
    
    local span_width = x1 - x0
    
    -- Handle single-column span
    if span_width <= 0 then
      local rel_x = span_hitx0 - camera.x
      local rel_y = span_hity0 - camera.y
      local z = rel_x * fwdx + rel_y * fwdy
      if z <= 0.0001 then z = 0.0001 end
      
      local h = sdist / z
      local y0 = screen_center_y - h / 2
      local y1 = screen_center_y + h / 2
      local tdy0 = math.ceil(y0)
      local tdy1 = math.min(math.floor(y1), cfg.screen_height - 1)
      
      if tdy0 <= tdy1 then
        local wall_height = tdy1 - tdy0
        if z > game_state.wall_lod_distance or wall_height < game_state.wall_tiny_screen_px then
          r_batch.rect_push(x0, tdy0, x1, tdy1, span_avg)
        else
          local u0 = span_tx0 * tex_size
          local v0 = 0
          local full_h = y1 - y0
          if full_h > 0 and tdy0 < y1 then
            v0 = ((tdy0 - y0) / full_h) * tex_size
          end
          local w0 = 1 / z
          r_batch.tline_push(span_spr, x0, tdy0, x1, tdy1, u0, v0, u0, v0 + tex_size, w0, w0, 0)
        end
        r_state.zwrite(x0, z)
      end
      
      span_start = nil
      return
    end
    
    -- Multi-column span
    local rel_x0 = span_hitx0 - camera.x
    local rel_y0 = span_hity0 - camera.y
    local z0 = rel_x0 * fwdx + rel_y0 * fwdy
    if z0 <= 0.0001 then z0 = 0.0001 end
    
    local rel_x1 = span_hitx1 - camera.x
    local rel_y1 = span_hity1 - camera.y
    local z1 = rel_x1 * fwdx + rel_y1 * fwdy
    if z1 <= 0.0001 then z1 = 0.0001 end
    
    local h0 = sdist / z0
    local base_y0 = screen_center_y - h0 / 2
    local base_y1 = screen_center_y + h0 / 2
    local tdy0 = math.ceil(base_y0)
    local tdy1 = math.min(math.floor(base_y1), cfg.screen_height - 1)
    
    if tdy0 > tdy1 then
      span_start = nil
      return
    end
    
    local h1 = sdist / z1
    local y1_top = screen_center_y - h1 / 2
    local y1_bot = screen_center_y + h1 / 2
    tdy0 = math.min(tdy0, math.ceil(y1_top))
    tdy1 = math.max(tdy1, math.min(math.floor(y1_bot), cfg.screen_height - 1))
    tdy0 = math.max(tdy0, 0)
    tdy1 = math.min(tdy1, cfg.screen_height - 1)
    
    if tdy0 > tdy1 then
      span_start = nil
      return
    end
    
    local column_count = x1 - x0 + 1
    
    -- LOD check
    if z0 > game_state.wall_lod_distance and z1 > game_state.wall_lod_distance then
      r_batch.rect_push(x0, tdy0, x1, tdy1, span_avg)
    else
      local u0 = span_tx0 * tex_size
      local u1 = span_tx1 * tex_size
      local v0 = ((tdy0 - base_y0) / (base_y1 - base_y0)) * tex_size
      if base_y1 - base_y0 <= 0 then v0 = 0 end
      v0 = math.max(0, math.min(tex_size, v0))
      local v1 = v0 + tex_size
      r_batch.tline_push(span_spr, x0, tdy0, x1, tdy1, u0, v0, u1, v1, 1 / z0, 1 / z1, 0)
    end
    
    -- Update z-buffer for all columns in span
    for col = x0, x1 do
      local t = (span_width > 0) and ((col - x0) / span_width) or 0
      local world_x = span_hitx0 + (span_hitx1 - span_hitx0) * t
      local world_y = span_hity0 + (span_hity1 - span_hity0) * t
      local rel_x = world_x - camera.x
      local rel_y = world_y - camera.y
      local z = rel_x * fwdx + rel_y * fwdy
      if z <= 0.0001 then z = 0.0001 end
      r_state.zwrite(col, z)
    end
    
    r_state.occupancy.wall_spans = r_state.occupancy.wall_spans + 1
    span_start = nil
  end
  
  -- Iterate rays and merge into spans
  for ray_idx = 0, ray_cnt - 1 do
    local tile = bufs.ray_tile:get(ray_idx)
    
    if tile and tile > 0 then
      if span_start and tile == span_tile then
        -- Continue span
        span_tx1 = bufs.ray_tx:get(ray_idx)
        span_hitx1 = bufs.ray_hitx:get(ray_idx)
        span_hity1 = bufs.ray_hity:get(ray_idx)
      else
        -- Flush previous span
        if span_start then flush_span(ray_idx - 1) end
        
        -- Start new span
        span_start = ray_idx
        span_tile = tile
        span_spr = resolve_sprite_index(tile, (game_state.is_door and game_state.is_door(tile)) and "door" or "wall", game_state.ERROR_IDX, game_state.get_spr)
        span_avg = get_avg_color(tile, game_state.get_spr, game_state.error_textures, game_state.is_door)
        span_tx0 = bufs.ray_tx:get(ray_idx)
        span_tx1 = span_tx0
        span_hitx0 = bufs.ray_hitx:get(ray_idx)
        span_hity0 = bufs.ray_hity:get(ray_idx)
        span_hitx1 = span_hitx0
        span_hity1 = span_hity0
      end
    else
      -- Empty tile: flush span
      if span_start then flush_span(ray_idx - 1) end
    end
  end
  
  -- Flush final span
  if span_start then flush_span(ray_cnt - 1) end
  
  r_batch.tline_submit()
  r_batch.rect_submit()
end

-- Clear texture caches (call on level load)
function r_walls.clear_caches()
  tex_cache = {}
  avg_color_cache = {}
end

return r_walls

