 local function clamped_blit(src_row,dst_row)
  if dst_row>y1 then return end
  local dst_y=screen_center_y+dst_row
  if dst_y<0 or dst_y>=screen_height then return end
  local src_y=screen_center_y+src_row
  if src_y<0 or src_y>=screen_height then return end
  blit(get_draw_target(),get_draw_target(),0,src_y,0,dst_y,screen_width,1)
  diag_floor_rows+=1
  diag_floor_batches+=1
 end
--[[pod_format="raw",created="2025-11-07 21:17:11",modified="2025-11-07 21:48:08",revision=1]]
-- rendering pipeline

-- track warned sprite indices to avoid per-frame spam
warned_sprites={}

-- lazy initialization flag for error texture
error_texture_initialized=false

-- persistent caches for textures and average colors across frames
tex_cache={}
avg_color_cache={}
-- Cache size limits to prevent unbounded growth (Picotron optimization guideline)
local CACHE_CAPACITY = 256  -- Max entries per cache (covers all game sprites + buffer)
local tex_cache_index = 0   -- Circular buffer write index for tex_cache
local avg_cache_index = 0   -- Circular buffer write index for avg_color_cache
local tex_cache_keys = {}   -- Array of tile IDs in insertion order (max 256)
local avg_cache_keys = {}   -- Array of tile IDs in insertion order (max 256)

-- bounded cache insert helpers
function cache_tex(tile, src, is_fallback)
 if not tile or not src then return end
 if #tex_cache_keys < CACHE_CAPACITY then
  tex_cache[tile]={src=src,is_fallback=is_fallback}
  add(tex_cache_keys, tile)
 else
  local evict_idx = (tex_cache_index % CACHE_CAPACITY) + 1
  local evict_tile = tex_cache_keys[evict_idx]
  tex_cache[evict_tile] = nil
  tex_cache[tile]={src=src,is_fallback=is_fallback}
  tex_cache_keys[evict_idx] = tile
  tex_cache_index += 1
 end
end

function cache_avg(tile, color)
 if tile==nil or color==nil then return end
 if #avg_cache_keys < CACHE_CAPACITY then
  avg_color_cache[tile]=color
  add(avg_cache_keys, tile)
 else
  local evict_idx = (avg_cache_index % CACHE_CAPACITY) + 1
  local evict_tile = avg_cache_keys[evict_idx]
  avg_color_cache[evict_tile] = nil
  avg_color_cache[tile]=color
  avg_cache_keys[evict_idx] = tile
  avg_cache_index += 1
 end
end

-- clear caches when tiles/floor/ceiling change (e.g., on new floor)
function clear_texture_caches()
 -- Log cache statistics before clearing (useful for tuning CACHE_CAPACITY)
 if enable_diagnostics_logging then
  printh("tex_cache size: "..#tex_cache_keys.." / "..CACHE_CAPACITY)
  printh("avg_color_cache size: "..#avg_cache_keys.." / "..CACHE_CAPACITY)
 end
 tex_cache={}
 avg_color_cache={}
 warned_sprites={}
 
 -- Reset circular buffer tracking
 tex_cache_keys={}
 avg_cache_keys={}
 tex_cache_index=0
 avg_cache_index=0
end

-- initialize error texture on first access (defensive fallback)
function init_error_texture()
 if not error_texture_initialized and not error_texture then
  -- create default error texture if none exists
  error_texture = userdata("u8", 32, 32)
  for y=0,31 do
   for x=0,31 do
    local color = ((flr(x/4) + flr(y/4)) % 2 == 0) and 8 or 14
    error_texture:set(x, y, color)
   end
  end
  error_texture_initialized=true
 end
end

-- get appropriate error texture for object type
function get_error_texture(obj_type)
 if error_textures then
  return error_textures[obj_type] or error_textures.default
 end
 init_error_texture()
 return error_texture
end

-- get individual sprite userdata for tline3d by sprite index
function get_texture_source(sprite_index, obj_type)
 -- default to sprite 0 for backward compatibility
 sprite_index=sprite_index or 0
 obj_type=obj_type or "default"
 
 -- return sprite sheet userdata
 local src=get_spr(sprite_index)
 if not src then
  -- warn once per sprite index to avoid per-frame spam
  if not warned_sprites[sprite_index] then
   printh("warning: sprite "..sprite_index.." not found, using "..obj_type.." error texture")
   warned_sprites[sprite_index]=true
  end
  -- return appropriate error texture for object type
  return get_error_texture(obj_type),true
 end
 return src,false
end



-- =========================
-- Batched tline3d utilities
-- =========================
-- Each row: sprite_index, x0,y0,x1,y1, u0,v0,u1,v1, w0,w1, flags  (13 columns)
local TLINE_COLS=13
local tline_buf_capacity=screen_width*2
local tline_args=userdata("f64", TLINE_COLS, tline_buf_capacity)
local tline_count=0

local function batch_reset()
	tline_count=0
end

local function batch_push(idx,x0,y0,x1,y1,u0,v0,u1,v1,w0,w1,flags)
	if tline_count>=tline_buf_capacity then
		tline3d(tline_args, 0, tline_count, TLINE_COLS)
		tline_count=0
	end
	tline_args:set(0, tline_count, idx, x0, y0, x1, y1, u0, v0, u1, v1, w0 or 1, w1 or 1, flags or 0)
	tline_count+=1
end

local function batch_submit()
	if tline_count>0 then
		tline3d(tline_args, 0, tline_count, TLINE_COLS)
		tline_count=0
	end
end

-- =========================
-- Batched rectfill utility
-- =========================
-- Each row: x0,y0,x1,y1,c (5 columns)
local RECT_COLS=5
local rect_buf_capacity=screen_width*4
local rect_args=userdata("f64", RECT_COLS, rect_buf_capacity)
local rect_count=0
function rbatch_reset() rect_count=0 end
function rbatch_push(x0,y0,x1,y1,c)
	if rect_count>=rect_buf_capacity then
		rectfill(rect_args, 0, rect_count, RECT_COLS)
		rect_count=0
	end
	rect_args:set(0, rect_count, x0, y0, x1, y1, c)
	rect_count+=1
end
function rbatch_submit()
	if rect_count>0 then
		rectfill(rect_args, 0, rect_count, RECT_COLS)
		rect_count=0
	end
end

local function resolve_sprite_index(idx, kind)
	if idx and get_spr(idx) then
		return idx
	end
	if ERROR_IDX then
		if kind=="floor" then return ERROR_IDX.floor
		elseif kind=="ceiling" then return ERROR_IDX.ceiling
		elseif kind=="sprite" then return ERROR_IDX.sprite
		elseif kind=="door" then return ERROR_IDX.door
		else return ERROR_IDX.wall end
	end
	return 0
end

-- preallocated buffers for per-cell floor runs (avoid per-frame table allocations)
local RUN_CAP=1024
local runs_x0=userdata("i16", RUN_CAP)
local runs_x1=userdata("i16", RUN_CAP)
local runs_id=userdata("i16", RUN_CAP)
local merged_x0=userdata("i16", RUN_CAP)
local merged_x1=userdata("i16", RUN_CAP)
local merged_id=userdata("i16", RUN_CAP)

-- Precomputed wall y-ranges for merged rendering (avoid per-scanline recalculation)
-- render perspective floor/ceiling and walls (flat shading, fog removed)
function render_floor_ceiling()
 palt(0,false)
 
 local fwdx=(ca_cached or cos(player.a))
 local fwdy=(sa_cached or sin(player.a))
 local tex_size=sprite_size or 32
 local _rc = active_ray_count or ray_count
 
 -- Draw ceiling and floor first so walls overlay them
 batch_reset()
 local roof_typ=roof.typ
 local roof_src,roof_fallback=get_texture_source(roof_typ.tex,"ceiling")
 if roof_fallback then roof_src=get_error_texture("ceiling") end
 draw_rows(roof_src,-screen_center_y,-1,roof_typ.scale,roof_typ.height,cam[1]-roof.x,cam[2]-roof.y,roof_typ.lit,fwdy,fwdx,roof_typ.tex,false)
 
 local floor_typ=floor.typ
 local floor_src,floor_fallback=get_texture_source(floor_typ.tex,"floor")
 if floor_fallback then floor_src=get_error_texture("floor") end
 draw_rows(floor_src,0,screen_center_y-1,floor_typ.scale,floor_typ.height,cam[1]-floor.x,cam[2]-floor.y,floor_typ.lit,fwdy,fwdx,floor_typ.tex,false)
 batch_submit()

 -- Render walls per-ray in a single vertical pass (drawn after floors)
 rbatch_reset()
 batch_reset()
 local span_start=nil
 local span_tile=nil
 local span_spr=nil
 local span_avg=nil
 local span_tx0=nil
 local span_tx1=nil
 local span_hitx0=nil
 local span_hity0=nil
 local span_hitx1=nil
 local span_hity1=nil
 local function flush_span(span_end)
  if not span_start then return end
  local x0=ray_x0:get(span_start)
  local x1=ray_x1:get(span_end)
  if x0>x1 then span_start=nil return end
  local spr_idx=span_spr
  local avg_color=span_avg
  local hx0=span_hitx0
  local hy0=span_hity0
  local hx1=span_hitx1
  local hy1=span_hity1
  local tx0=span_tx0
  local tx1=span_tx1
  local span_width=x1-x0
  local base_z=nil
  local base_tdy0=nil
  local base_tdy1=nil
  local first_wall=false
  if span_width<=0 then
   span_width=0
   local rel_x=hx0-player.x
   local rel_y=hy0-player.y
   base_z=rel_x*fwdx+rel_y*fwdy
   if base_z<=0.0001 then base_z=0.0001 end
   local h=sdist/base_z
   local y0=screen_center_y-h/2
   local y1=screen_center_y+h/2
   base_tdy0=ceil(y0)
   base_tdy1=min(flr(y1),screen_height-1)
   if base_tdy0<=base_tdy1 then
    local wall_height=base_tdy1-base_tdy0
    if base_z>wall_lod_distance or wall_height<wall_tiny_screen_px then
     rbatch_push(x0, base_tdy0, x1, base_tdy1, avg_color)
     diag_wall_lod_columns+=x1-x0+1
    else
     local u0=tx0*tex_size
     local v0=0
     local full_h=y1-y0
     if full_h>0 and base_tdy0<y1 then
      v0=((base_tdy0-y0)/full_h)*tex_size
     end
     local w0=1/base_z
     batch_push(spr_idx,x0,base_tdy0,x1,base_tdy1,u0,v0,u0,v0+tex_size,w0,w0,0)
     diag_wall_columns+=x1-x0+1
    end
    if zwrite then zwrite(x0,base_z) else zbuf:set(x0,base_z) end
   end
   span_start=nil
   return
  end
  local rel_x0=hx0-player.x
  local rel_y0=hy0-player.y
  local z0=rel_x0*fwdx+rel_y0*fwdy
  if z0<=0.0001 then z0=0.0001 end
  local h0=sdist/z0
  local base_y0=screen_center_y-h0/2
  local base_y1=screen_center_y+h0/2
  local tdy0=ceil(base_y0)
  local tdy1=min(flr(base_y1),screen_height-1)
  if tdy0>tdy1 then
   span_start=nil
   return
  end
  local rel_x1=hx1-player.x
  local rel_y1=hy1-player.y
  local z1=rel_x1*fwdx+rel_y1*fwdy
  if z1<=0.0001 then z1=0.0001 end
  local h1=sdist/z1
  local y1_top=screen_center_y-h1/2
  local y1_bot=screen_center_y+h1/2
  local tdy1_alt=ceil(y1_top)
  local tdy1_bot=min(flr(y1_bot),screen_height-1)
  tdy0=min(tdy0,tdy1_alt)
  tdy1=max(tdy1,tdy1_bot)
  tdy0=max(tdy0,0)
  tdy1=min(tdy1,screen_height-1)
  if tdy0>tdy1 then
   span_start=nil
   return
  end
  local wall_height=tdy1-tdy0
  local column_count=x1-x0+1
  if z0>wall_lod_distance and z1>wall_lod_distance then
   rbatch_push(x0, tdy0, x1, tdy1, avg_color)
   diag_wall_lod_columns+=column_count
  else
   local u0=tx0*tex_size
   local u1=tx1*tex_size
   local v0=((tdy0-base_y0)/(base_y1-base_y0))*tex_size
   if base_y1-base_y0<=0 then v0=0 end
   if v0<0 then v0=0 elseif v0>tex_size then v0=tex_size end
   local v1=v0+tex_size
   batch_push(spr_idx, x0, tdy0, x1, tdy1, u0, v0, u1, v1, 1/z0, 1/z1, 0)
   diag_wall_columns+=column_count
  end
  for col=x0,x1 do
   local t=(span_width>0) and ((col-x0)/span_width) or 0
   local world_x=hx0+(hx1-hx0)*t
   local world_y=hy0+(hy1-hy0)*t
   local rel_x=world_x-player.x
   local rel_y=world_y-player.y
   local z=rel_x*fwdx+rel_y*fwdy
   if z<=0.0001 then z=0.0001 end
   if zwrite then zwrite(col,z) else zbuf:set(col,z) end
  end
  span_start=nil
 end
 for ray_idx=0,_rc-1 do
  local tile=rbuf_tile:get(ray_idx)
  if tile and tile>0 then
   if span_start and tile==span_tile then
    span_tx1=rbuf_tx:get(ray_idx)
    span_hitx1=ray_hitx:get(ray_idx)
    span_hity1=ray_hity:get(ray_idx)
   else
    if span_start then flush_span(ray_idx-1) end
    span_start=ray_idx
    span_tile=tile
    span_spr=resolve_sprite_index(tile,(is_door and is_door(tile)) and "door" or "wall")
    local avg=avg_color_cache[tile]
    if not avg then
     local cached=tex_cache[tile]
     local src,is_fallback
     if cached then
      src,is_fallback=cached.src,cached.is_fallback
     else
      local obj_type=is_door and is_door(tile) and "door" or "wall"
      src,is_fallback=get_texture_source(tile,obj_type)
      cache_tex(tile, src, is_fallback)
     end
     avg=5
     if src and src.get then
      avg=src:get(16,16) or 5
     end
     cache_avg(tile, avg)
    end
    span_avg=avg
    span_tx0=rbuf_tx:get(ray_idx)
    span_tx1=span_tx0
    span_hitx0=ray_hitx:get(ray_idx)
    span_hity0=ray_hity:get(ray_idx)
    span_hitx1=span_hitx0
    span_hity1=span_hity0
   end
  else
   if span_start then flush_span(ray_idx-1) end
  end
 end
 if span_start then flush_span(_rc-1) end
 batch_submit()
 
 palt()
end

-- draw horizontal scanlines with 32x32 sprite sampling and optional wall rendering (flat shading)
function draw_rows(src,y0,y1,tilesize,height,cx,cy,lit,sa,ca,tex,render_walls)
 local size=sprite_size or 32
 local function draw_single_row(row)
  diag_floor_rows+=1
  local y=row
  local y_offset=y>=0 and (y+0.5) or abs(y-0.5)
  local g=y_offset/sdist
  if g<0.0001 then g=0.0001 end
  local z=(height or 0.5)/g
  local mx=(cx+z*sa)/tilesize
  local my=(cy+z*ca)/tilesize
  local s=sdist/z*tilesize
  local mdx=-ca/s
  local mdy=sa/s
  mx-=screen_center_x*mdx
  my-=screen_center_x*mdy
  if per_cell_floors_enabled then
   local sample_interval=12
   local rcount=0
   local cur_id=-1
   local cur_x0=0
   for x=0,screen_width-1,sample_interval do
    local wx=mx+x*mdx
    local wy=my+x*mdy
    local gx=flr(wx)
    local gy=flr(wy)
    local fid=get_floor(gx,gy)
    if cur_id<0 then
     cur_id=fid
     cur_x0=x
    elseif fid~=cur_id then
     if rcount<RUN_CAP then
      runs_x0:set(rcount, cur_x0)
      runs_x1:set(rcount, x-1)
      runs_id:set(rcount, cur_id)
      rcount+=1
     end
     cur_id=fid
     cur_x0=x
    end
   end
   if rcount<RUN_CAP then
    runs_x0:set(rcount, cur_x0)
    runs_x1:set(rcount, screen_width-1)
    runs_id:set(rcount, cur_id)
    rcount+=1
   end
   local mcount=0
   for i=0,rcount-1 do
    local x0i=runs_x0:get(i)
    local x1i=runs_x1:get(i)
    local fidi=runs_id:get(i)
    local width=x1i-x0i+1
    if width<4 and mcount>0 then
     local prev_x1=merged_x1:get(mcount-1)
     if x1i>prev_x1 then merged_x1:set(mcount-1, x1i) end
    else
     if mcount<RUN_CAP then
      merged_x0:set(mcount, x0i)
      merged_x1:set(mcount, x1i)
      merged_id:set(mcount, fidi)
      mcount+=1
     end
    end
   end
   for i=0,mcount-1 do
    local rx0=merged_x0:get(i)
    local rx1=merged_x1:get(i)
    local fid=merged_id:get(i)
    local run_tex=tex
    if fid>0 and fid<=#planetyps then
     run_tex=planetyps[fid].tex
    end
    local idx=resolve_sprite_index(run_tex,"floor")
    local u0=(mx+rx0*mdx)%1*size
    local v0=(my+rx0*mdy)%1*size
    u0=max(0,min(size-0.001,u0))
    v0=max(0,min(size-0.001,v0))
    local u1=u0+(rx1-rx0)*mdx*size
    local v1=v0+(rx1-rx0)*mdy*size
    batch_push(idx, rx0, screen_center_y+y, rx1, screen_center_y+y, u0, v0, u1, v1, 1, 1)
    diag_floor_batches+=1
   end
  else
   local idx=resolve_sprite_index(tex,"floor")
   local u0=(mx)%1*size
   local v0=(my)%1*size
   u0=max(0,min(size-0.001,u0))
   v0=max(0,min(size-0.001,v0))
   local u1=u0+(screen_width-1)*mdx*size
   local v1=v0+(screen_width-1)*mdy*size
   batch_push(idx, 0, screen_center_y+y, screen_width-1, screen_center_y+y, u0, v0, u1, v1, 1, 1)
   diag_floor_batches+=1
  end
 end
 local function duplicate_rows(src_row, count)
  if count<=0 then return end
  local y0=screen_center_y+src_row+1
  local y1=y0+count-1
  if y0>screen_center_y+y1 then return end
  y1=min(y1,screen_center_y+y1)
  if y0>screen_height-1 then return end
 end
 local function blit_rows(src_row,rep_count)
  if rep_count<=0 then return end
  for k=1,rep_count do
   local row=src_row+k
  if row>y1 then break end
   diag_floor_rows+=1
   diag_floor_batches+=1
   blit(get_draw_target(),get_draw_target(),0,screen_center_y+src_row,0,screen_center_y+row,screen_width,1)
  end
 end
 local near_end = min(y1, -16)
 local mid_end = min(y1, 32)
 for y=y0, near_end do
  draw_single_row(y)
 end
 local y=near_end+1
 while y<=mid_end do
  draw_single_row(y)
 clamped_blit(y,y+1)
  y+=2
 end
 while y<=y1 do
  draw_single_row(y)
 clamped_blit(y,y+1)
 clamped_blit(y,y+2)
 clamped_blit(y,y+3)
  y+=4
 end
end

