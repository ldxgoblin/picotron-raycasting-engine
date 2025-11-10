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
local wall_y0 = {}   -- Top y-coordinate for each ray's wall
local wall_y1 = {}   -- Bottom y-coordinate for each ray's wall
local wall_valid = {} -- Boolean: true if ray hit a wall (z<999)
-- Cached per-ray wall draw data to minimize inner-loop work
local wall_tile = {}
local wall_tx = {}
local wall_u0 = {}
local wall_u1 = {}
local wall_spr_idx = {}
local wall_tdy0 = {}
local wall_tdy1 = {}
local wall_tiny = {}
local wall_z = {}

-- render perspective floor/ceiling and walls (flat shading, fog removed)
function render_floor_ceiling()
 palt(0,false)
 
 local fwdx=(ca_cached or cos(player.a))
 local fwdy=(sa_cached or sin(player.a))
 local tex_size=sprite_size or 32
 
 -- Precompute wall y-ranges for all rays (used during scanline iteration)
 local _rc = active_ray_count or ray_count
 for ray_idx=0,_rc-1 do
  local z=ray_z:get(ray_idx)
  if z<999 then
   -- Calculate wall height and y-range
   local h=sdist/z
   local y0 = screen_center_y-h/2
   local y1 = screen_center_y+h/2
   wall_y0[ray_idx]=y0
   wall_y1[ray_idx]=y1
   wall_z[ray_idx]=z
   -- screen-space tiny wall threshold (use LOD when very short)
   local tdy0=ceil(y0)
   local tdy1=min(flr(y1),screen_height-1)
   wall_tdy0[ray_idx]=tdy0
   wall_tdy1[ray_idx]=tdy1
   wall_tiny[ray_idx]=(tdy1 - tdy0) < (wall_tiny_screen_px or 4)
   -- cache texture info
   local tile=rbuf_tile:get(ray_idx)
   local tx=rbuf_tx:get(ray_idx)
   wall_tile[ray_idx]=tile
   wall_tx[ray_idx]=tx
  -- compute base u coordinate and possible interpolation with next ray
  local u0=tx*tex_size
  u0=max(0,min(tex_size-0.001,u0))
   local u1=u0
   if ray_idx<_rc-1 then
    local tile_next=rbuf_tile:get(ray_idx+1)
    if tile_next==tile then
     local tx_next=rbuf_tx:get(ray_idx+1)
    local u1_next=tx_next*tex_size
    u1_next=max(0,min(tex_size-0.001,u1_next))
     u1=u1_next
    end
   end
   wall_u0[ray_idx]=u0
   wall_u1[ray_idx]=u1
   -- resolve sprite once
   local spr_idx=resolve_sprite_index(tile, (is_door and is_door(tile)) and "door" or "wall")
   wall_spr_idx[ray_idx]=spr_idx
   wall_valid[ray_idx]=true
  else
   wall_valid[ray_idx]=false
  end
 end
 
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
 local any_rect=false
 for ray_idx=0,_rc-1 do
  if wall_valid[ray_idx] then
   -- read cached values
   local z=wall_z[ray_idx]
   local x0=ray_x0:get(ray_idx)
   local x1=ray_x1:get(ray_idx)
   if x0<=x1 then
    local tdy0=wall_tdy0[ray_idx]
    local tdy1=wall_tdy1[ray_idx]
    local tile=wall_tile[ray_idx]
    -- LOD or tiny: solid fill via rect batch
    if z>wall_lod_distance or wall_tiny[ray_idx] then
     local avg_color=avg_color_cache[tile]
     if not avg_color then
      local cached=tex_cache[tile]
      local src,is_fallback
      if cached then
       src,is_fallback=cached.src,cached.is_fallback
      else
       local obj_type=is_door and is_door(tile) and "door" or "wall"
       src,is_fallback=get_texture_source(tile,obj_type)
       cache_tex(tile, src, is_fallback)
      end
      avg_color=5
      if src and src.get then
       avg_color=src:get(16,16) or 5
      end
      cache_avg(tile, avg_color)
     end
     rbatch_push(x0, tdy0, x1, tdy1, avg_color)
     any_rect=true
     -- write zbuf for span
     for x=x0,x1 do
      if zwrite then zwrite(x,z) else zbuf:set(x,z) end
     end
    else
     -- textured vertical columns
     local u0=wall_u0[ray_idx]
     local u1=wall_u1[ray_idx]
     local spr_idx=wall_spr_idx[ray_idx]
     local y0=wall_y0[ray_idx]
     local y1=wall_y1[ray_idx]
     -- compute v0/v1 mapped across clipped span
     local full_h=y1-y0
     local v0=0
     local v1=tex_size
     if full_h>0 and tdy0<y1 then
      v0+=((tdy0-y0)/full_h)*tex_size
      v1=v0+tex_size
     end
     local span_w=max(1,(x1-x0))
     local delta_u=u1-u0
     if delta_u>tex_size*0.5 or delta_u < -tex_size*0.5 then
      delta_u=0
      u1=u0
     end
     local du=delta_u/span_w
     local u_interp=u0
     -- Hardcode flags=0 for consistent fast path (Picotron guideline: minimize tline3d overhead)
     local flags=0
     for x=x0,x1 do
      u_interp=max(0,min(tex_size-0.001,u_interp))
      batch_push(spr_idx, x, tdy0, x, tdy1, u_interp, v0, u_interp, v1, 1, 1, flags)
      if zwrite then zwrite(x, z) else zbuf:set(x,z) end
      u_interp+=du
     end
    end
   end
  end
 end
 if any_rect then
  -- apply dithering pattern and submit
  fillp(0x55aa55aa)
  rbatch_submit()
  fillp()
 end
 batch_submit()
 
 palt()
end

-- draw horizontal scanlines with 32x32 sprite sampling and optional wall rendering (flat shading)
function draw_rows(src,y0,y1,tilesize,height,cx,cy,lit,sa,ca,tex,render_walls)
 local size=sprite_size or 32
 
 for y=y0,y1 do
  -- calculate ray gradient using half-pixel offset (avoid horizon singularity)
  local y_offset
  if y>=0 then
   y_offset=y+0.5
  else
   y_offset=abs(y-0.5)
  end
  local g=y_offset/sdist
  if g<0.0001 then g=0.0001 end
  
  -- calculate z distance
  local z=(height or 0.5)/g
  
  -- calculate map coordinates
  local mx=(cx+z*sa)/tilesize
  local my=(cy+z*ca)/tilesize
  
  -- calculate texture deltas
  local s=sdist/z*tilesize
  local mdx=-ca/s
  local mdy=sa/s
  
  -- offset to left edge
  mx-=screen_center_x*mdx
  my-=screen_center_x*mdy
  
 -- diagnostics removed for production
  
  if per_cell_floors_enabled then
   -- per-cell floor type rendering using preallocated buffers (no per-frame table allocs)
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
   -- merge short runs into previous using preallocated buffers
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
   -- draw all merged runs with batching
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
   end
  else
   -- simplified rendering: draw full scanline with single texture
   local idx=resolve_sprite_index(tex,"floor")
   local u0=(mx)%1*size
   local v0=(my)%1*size
  u0=max(0,min(size-0.001,u0))
  v0=max(0,min(size-0.001,v0))
   local u1=u0+(screen_width-1)*mdx*size
   local v1=v0+(screen_width-1)*mdy*size
   batch_push(idx, 0, screen_center_y+y, screen_width-1, screen_center_y+y, u0, v0, u1, v1, 1, 1)
  end
 end
end

