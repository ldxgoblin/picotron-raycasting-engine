--[[pod_format="raw",created="2025-11-12 00:00:00",modified="2025-11-12 00:00:00",revision=1]]
-- r_floor.lua
-- Hybrid floor/ceiling renderer with near/mid/far row scheduling

local r_floor = {}

-- Preallocated buffers for per-cell floor runs (avoid per-frame allocations)
local RUN_CAP = 1024
local runs_x0 = userdata("i16", RUN_CAP)
local runs_x1 = userdata("i16", RUN_CAP)
local runs_id = userdata("i16", RUN_CAP)
local merged_x0 = userdata("i16", RUN_CAP)
local merged_x1 = userdata("i16", RUN_CAP)
local merged_id = userdata("i16", RUN_CAP)

-- Clamped blit helper
local function clamped_blit(src_row, dst_row, screen_center_y, screen_height, y1_limit, r_state)
  if dst_row > y1_limit then return end
  local dst_y = screen_center_y + dst_row
  if dst_y < 0 or dst_y >= screen_height then return end
  local src_y = screen_center_y + src_row
  if src_y < 0 or src_y >= screen_height then return end
  blit(get_draw_target(), get_draw_target(), 0, src_y, 0, dst_y, screen_width, 1)
  r_state.occupancy.floor_rows = r_state.occupancy.floor_rows + 1
end

-- Resolve sprite index with fallback
local function resolve_sprite_index(idx, kind, error_idx_table, get_spr_fn)
  if idx and get_spr_fn(idx) then
    return idx
  end
  if error_idx_table then
    if kind == "floor" then return error_idx_table.floor
    elseif kind == "ceiling" then return error_idx_table.ceiling
    else return error_idx_table.default end
  end
  return 0
end

-- Draw single row with optional per-cell floor sampling
local function draw_single_row(row, src, tex, tilesize, height, cx, cy, sa, ca, sdist, screen_center_y, screen_width, sprite_size, r_batch, r_state, per_cell_floors, get_floor_fn, planetyps, error_idx_table, get_spr_fn)
  local y = row
  local y_offset = (y >= 0) and (y + 0.5) or abs(y - 0.5)
  local g = y_offset / sdist
  if g < 0.0001 then g = 0.0001 end
  local z = (height or 0.5) / g
  local mx = (cx + z * sa) / tilesize
  local my = (cy + z * ca) / tilesize
  local s = sdist / z * tilesize
  local mdx = -ca / s
  local mdy = sa / s
  mx = mx - screen_center_x * mdx
  my = my - screen_center_x * mdy
  
  if per_cell_floors then
    -- Per-cell floor sampling
    local sample_interval = 12
    local rcount = 0
    local cur_id = -1
    local cur_x0 = 0
    
    for x = 0, screen_width - 1, sample_interval do
      local wx = mx + x * mdx
      local wy = my + x * mdy
      local gx = math.floor(wx)
      local gy = math.floor(wy)
      local fid = get_floor_fn(gx, gy)
      
      if cur_id < 0 then
        cur_id = fid
        cur_x0 = x
      elseif fid ~= cur_id then
        if rcount < RUN_CAP then
          runs_x0:set(rcount, cur_x0)
          runs_x1:set(rcount, x - 1)
          runs_id:set(rcount, cur_id)
          rcount = rcount + 1
        end
        cur_id = fid
        cur_x0 = x
      end
    end
    
    if rcount < RUN_CAP then
      runs_x0:set(rcount, cur_x0)
      runs_x1:set(rcount, screen_width - 1)
      runs_id:set(rcount, cur_id)
      rcount = rcount + 1
    end
    
    -- Merge tiny runs
    local mcount = 0
    for i = 0, rcount - 1 do
      local x0i = runs_x0:get(i)
      local x1i = runs_x1:get(i)
      local fidi = runs_id:get(i)
      local width = x1i - x0i + 1
      if width < 4 and mcount > 0 then
        local prev_x1 = merged_x1:get(mcount - 1)
        if x1i > prev_x1 then merged_x1:set(mcount - 1, x1i) end
      else
        if mcount < RUN_CAP then
          merged_x0:set(mcount, x0i)
          merged_x1:set(mcount, x1i)
          merged_id:set(mcount, fidi)
          mcount = mcount + 1
        end
      end
    end
    
    -- Draw merged runs
    for i = 0, mcount - 1 do
      local rx0 = merged_x0:get(i)
      local rx1 = merged_x1:get(i)
      local fid = merged_id:get(i)
      local run_tex = tex
      if fid > 0 and fid <= #planetyps then
        run_tex = planetyps[fid].tex
      end
      local idx = resolve_sprite_index(run_tex, "floor", error_idx_table, get_spr_fn)
      local u0 = ((mx + rx0 * mdx) % 1) * sprite_size
      local v0 = ((my + rx0 * mdy) % 1) * sprite_size
      u0 = math.max(0, math.min(sprite_size - 0.001, u0))
      v0 = math.max(0, math.min(sprite_size - 0.001, v0))
      local u1 = u0 + (rx1 - rx0) * mdx * sprite_size
      local v1 = v0 + (rx1 - rx0) * mdy * sprite_size
      r_batch.tline_push(idx, rx0, screen_center_y + y, rx1, screen_center_y + y, u0, v0, u1, v1, 1, 1)
    end
  else
    -- Single texture for entire row
    local idx = resolve_sprite_index(tex, "floor", error_idx_table, get_spr_fn)
    local u0 = (mx % 1) * sprite_size
    local v0 = (my % 1) * sprite_size
    u0 = math.max(0, math.min(sprite_size - 0.001, u0))
    v0 = math.max(0, math.min(sprite_size - 0.001, v0))
    local u1 = u0 + (screen_width - 1) * mdx * sprite_size
    local v1 = v0 + (screen_width - 1) * mdy * sprite_size
    r_batch.tline_push(idx, 0, screen_center_y + y, screen_width - 1, screen_center_y + y, u0, v0, u1, v1, 1, 1)
  end
  
  r_state.occupancy.floor_rows = r_state.occupancy.floor_rows + 1
end

-- Draw floor and ceiling with hybrid duplication schedule
-- camera: {x, y} position
-- r_view: view module with forward/right vectors and sdist
-- r_state: renderer state
-- r_batch: batch module
-- game_state: {floor, roof, sprite_size, per_cell_floors_enabled, get_floor, planetyps, error_textures, ERROR_IDX, get_spr}
function r_floor.draw_floor_ceiling(camera, r_view, r_state, r_batch, game_state)
  local cfg = r_state.config
  local screen_center_y = cfg.screen_height / 2
  local screen_width = cfg.screen_width
  local screen_height = cfg.screen_height
  local fwdy = r_view.forward_y
  local fwdx = r_view.forward_x
  local sdist = r_view.sdist
  local sprite_size = game_state.sprite_size or 32
  
  palt(0, false)
  
  r_batch.tline_reset()
  
  -- Draw ceiling
  local roof_typ = game_state.roof.typ
  local roof_src = game_state.get_spr(roof_typ.tex)
  local y0_ceil = -screen_center_y
  local y1_ceil = -1
  
  -- Near ceiling rows (every row)
  local near_end = math.min(y1_ceil, -16)
  for y = y0_ceil, near_end do
    draw_single_row(y, roof_src, roof_typ.tex, roof_typ.scale, roof_typ.height, 
      camera.x - game_state.roof.x, camera.y - game_state.roof.y, 
      fwdy, fwdx, sdist, screen_center_y, screen_width, sprite_size, 
      r_batch, r_state, false, nil, nil, game_state.ERROR_IDX, game_state.get_spr)
  end
  
  -- Mid ceiling rows (2x duplication)
  local mid_end = math.min(y1_ceil, 32)
  local y = near_end + 1
  while y <= mid_end do
    draw_single_row(y, roof_src, roof_typ.tex, roof_typ.scale, roof_typ.height,
      camera.x - game_state.roof.x, camera.y - game_state.roof.y,
      fwdy, fwdx, sdist, screen_center_y, screen_width, sprite_size,
      r_batch, r_state, false, nil, nil, game_state.ERROR_IDX, game_state.get_spr)
    clamped_blit(y, y + 1, screen_center_y, screen_height, y1_ceil, r_state)
    y = y + 2
  end
  
  -- Far ceiling rows (4x duplication)
  while y <= y1_ceil do
    draw_single_row(y, roof_src, roof_typ.tex, roof_typ.scale, roof_typ.height,
      camera.x - game_state.roof.x, camera.y - game_state.roof.y,
      fwdy, fwdx, sdist, screen_center_y, screen_width, sprite_size,
      r_batch, r_state, false, nil, nil, game_state.ERROR_IDX, game_state.get_spr)
    clamped_blit(y, y + 1, screen_center_y, screen_height, y1_ceil, r_state)
    clamped_blit(y, y + 2, screen_center_y, screen_height, y1_ceil, r_state)
    clamped_blit(y, y + 3, screen_center_y, screen_height, y1_ceil, r_state)
    y = y + 4
  end
  
  -- Draw floor
  local floor_typ = game_state.floor.typ
  local floor_src = game_state.get_spr(floor_typ.tex)
  local y0_floor = 0
  local y1_floor = screen_center_y - 1
  
  -- Near floor rows (every row) - POSITIVE threshold for floor space
  near_end = math.min(y1_floor, 16)
  for y = y0_floor, near_end do
    draw_single_row(y, floor_src, floor_typ.tex, floor_typ.scale, floor_typ.height,
      camera.x - game_state.floor.x, camera.y - game_state.floor.y,
      fwdy, fwdx, sdist, screen_center_y, screen_width, sprite_size,
      r_batch, r_state, game_state.per_cell_floors_enabled, game_state.get_floor, game_state.planetyps, game_state.ERROR_IDX, game_state.get_spr)
  end
  
  -- Mid floor rows (2x duplication) - POSITIVE threshold
  mid_end = math.min(y1_floor, 48)
  y = near_end + 1
  while y <= mid_end do
    draw_single_row(y, floor_src, floor_typ.tex, floor_typ.scale, floor_typ.height,
      camera.x - game_state.floor.x, camera.y - game_state.floor.y,
      fwdy, fwdx, sdist, screen_center_y, screen_width, sprite_size,
      r_batch, r_state, game_state.per_cell_floors_enabled, game_state.get_floor, game_state.planetyps, game_state.ERROR_IDX, game_state.get_spr)
    clamped_blit(y, y + 1, screen_center_y, screen_height, y1_floor, r_state)
    y = y + 2
  end
  
  -- Far floor rows (4x duplication)
  while y <= y1_floor do
    draw_single_row(y, floor_src, floor_typ.tex, floor_typ.scale, floor_typ.height,
      camera.x - game_state.floor.x, camera.y - game_state.floor.y,
      fwdy, fwdx, sdist, screen_center_y, screen_width, sprite_size,
      r_batch, r_state, game_state.per_cell_floors_enabled, game_state.get_floor, game_state.planetyps, game_state.ERROR_IDX, game_state.get_spr)
    clamped_blit(y, y + 1, screen_center_y, screen_height, y1_floor, r_state)
    clamped_blit(y, y + 2, screen_center_y, screen_height, y1_floor, r_state)
    clamped_blit(y, y + 3, screen_center_y, screen_height, y1_floor, r_state)
    y = y + 4
  end
  
  r_batch.tline_submit()
  palt()
end

return r_floor

