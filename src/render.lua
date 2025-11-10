--[[pod_format="raw",created="2025-11-07 21:17:11",modified="2025-11-07 21:48:08",revision=1]]
-- rendering pipeline

-- track warned sprite indices to avoid per-frame spam
warned_sprites={}

-- lazy initialization flag for error texture
error_texture_initialized=false

-- persistent caches for textures and average colors across frames
tex_cache={}
avg_color_cache={}

-- clear caches when tiles/floor/ceiling change (e.g., on new floor)
function clear_texture_caches()
 tex_cache={}
 avg_color_cache={}
 warned_sprites={}
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

-- track last applied fog level to reduce palette changes
last_fog_level=-1
prev_pal={}

-- apply distance-based fog (with hysteresis caching for performance)
function compute_fog_level(z)
 if z<=0 then
  return -1
 end
 -- guard against degenerate config (prevent division by zero)
 if fog_far<=fog_near+0.000001 then
  return z>fog_far and 15 or 0
 end
 -- unified linear fog: 0 at fog_near, 15 at fog_far
 local t=(z-fog_near)/(fog_far-fog_near)
 -- clamp to [0,1]
 t=max(0,min(1,t))
 -- 16 levels (0..15)
 return flr(t*15)
end

-- apply distance-based fog (with hysteresis caching for performance)
function set_fog(z)
 if z<=0 then
  return  -- invalid depth, skip fog application
 end
 
 local level=compute_fog_level(z)
 
 -- hysteresis: only update if z changed significantly (reduces palette thrashing)
 if abs(z-last_fog_z)<fog_hysteresis and last_fog_level>=0 then
  return
 end
 last_fog_z=z
 
 -- only update palette if fog level changed (reduces palette ops from 320/frame to ~10-20)
 if level~=last_fog_level then
  if debug_mode then
   diag_fog_switches+=1
  end
  local p=pals[level+1]
  for i=0,63 do
   -- incremental update: only apply if value changed
    if p[i+1]~=prev_pal[i] then
     pal(i,p[i+1],1)
    prev_pal[i]=p[i+1]
   end
  end
  last_fog_level=level
 end
end

-- =========================
-- Batched tline3d utilities
-- =========================
-- Each row: sprite_index, x0,y0,x1,y1, u0,v0,u1,v1, w0,w1  (12 columns)
local TLINE_COLS=12
local tline_buf_capacity=screen_width*2
local tline_args=userdata("f64", TLINE_COLS, tline_buf_capacity)
local tline_count=0

local function batch_reset()
	tline_count=0
end

local function batch_push(idx,x0,y0,x1,y1,u0,v0,u1,v1,w0,w1)
	if tline_count>=tline_buf_capacity then
		tline3d(tline_args, 0, tline_count, TLINE_COLS)
		tline_count=0
	end
	tline_args:set(0, tline_count, idx, x0, y0, x1, y1, u0, v0, u1, v1, w0 or 1, w1 or 1)
	tline_count+=1
end

local function batch_submit()
	if tline_count>0 then
		tline3d(tline_args, 0, tline_count, TLINE_COLS)
		tline_count=0
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

-- render textured walls (span-based with per-pixel zbuf and LOD)
function render_walls()
 palt(0,false)
 
 -- cache sprite sources by tile to avoid repeated get_spr() calls
 -- cache LOD average colors per tile to avoid per-frame src:get() sampling
 
 for ray_idx=0,ray_count-1 do
  -- read hit data from dedicated per-ray arrays
  local z=ray_z[ray_idx]
  local t=rbuf[ray_idx]
  
  -- get screen span for this ray
  local x0=ray_x0[ray_idx]
  local x1=ray_x1[ray_idx]
  
  -- skip zero-width or degenerate spans
  if x0>x1 then
   -- degenerate span, skip
  elseif z<999 then
   -- calculate wall height
   local h=sdist/z
   local y0=screen_center_y-h/2
   local y1=screen_center_y+h/2
   
   -- extract texture coordinates from table
   local tile=t.tile
   local tx=t.tx
   
   -- LOD: use simplified rendering for distant walls
   if z>wall_lod_distance then
    -- check cached average color first
    local avg_color=avg_color_cache[tile]
    if not avg_color then
     -- sample average color from texture center for solid fill
     local cached=tex_cache[tile]
     local src,is_fallback
     if cached then
      src,is_fallback=cached.src,cached.is_fallback
     else
      -- choose object type for fallback texture
      local obj_type=is_door and is_door(tile) and "door" or "wall"
      src,is_fallback=get_texture_source(tile,obj_type)
      tex_cache[tile]={src=src,is_fallback=is_fallback}
     end
     
     -- sample center pixel color from texture (u=16, v=16 in 32x32 sprite)
     avg_color=5 -- default fog color if sampling fails
     if src and src.get then
      avg_color=src:get(16,16) or 5
     end
     
     -- cache for subsequent LOD draws
     avg_color_cache[tile]=avg_color
    end
    
    -- apply fog
    set_fog(z)
    
    -- draw solid color across span
    local draw_y0=ceil(y0)
    local draw_y1=min(flr(y1),screen_height-1)
    rectfill(x0,draw_y0,x1,draw_y1,avg_color)
    
    -- count wall columns for diagnostics
    if debug_mode then
     diag_wall_columns+=(x1-x0+1)
    end
    
    -- write zbuf for entire span
    for x=x0,x1 do
     zbuf[x+1]=z
    end
   else
    -- normal rendering with tline3d
    -- fetch sprite for this specific wall/door tile
    local cached=tex_cache[tile]
    local src,is_fallback
    if cached then
     src,is_fallback=cached.src,cached.is_fallback
    else
     -- choose object type for fallback texture
     local obj_type=is_door and is_door(tile) and "door" or "wall"
     src,is_fallback=get_texture_source(tile,obj_type)
     tex_cache[tile]={src=src,is_fallback=is_fallback}
    end
    
    -- compute base u coordinate
    local u0=flr(tx*32)
    u0=max(0,min(31,u0))
    
    -- interpolate u with next ray if same tile
    local u1=u0
    if ray_idx<ray_count-1 then
     local t_next=rbuf[ray_idx+1]
     if t_next.tile==tile then
      local tx_next=t_next.tx
      local u1_next=flr(tx_next*32)
      u1_next=max(0,min(31,u1_next))
      u1=u1_next
     end
    end
    
    -- vertical span clamps
    local draw_y0=ceil(y0)
    local draw_y1=min(flr(y1),screen_height-1)
    
    -- adjust v0 for clipped top to maintain texture continuity
    local v0=0
    local v1=32
    local full_h=y1-y0
    if full_h>0 and draw_y0<y1 then
     v0+=((draw_y0-y0)/full_h)*32
     v1=v0+32
    end
    
    -- apply fog once per ray
    set_fog(z)
    
    -- draw columns across the span with interpolated u (batched)
    batch_reset()
    local spr_idx=resolve_sprite_index(tile, (is_door and is_door(tile)) and "door" or "wall")
    for x=x0,x1 do
     local u_interp=u0+(u1-u0)*(x-x0)/(x1-x0+0.01)
     u_interp=max(0,min(31,u_interp))
     batch_push(spr_idx, x, draw_y0, x, draw_y1, u_interp, v0, u_interp, v1, 1, 1)
     -- write zbuf per pixel
     zbuf[x+1]=z
    end
    batch_submit()
    
    -- count wall columns for diagnostics
    if debug_mode then
     diag_wall_columns+=(x1-x0+1)
    end
   end
  end
 end
 
 -- restore transparency mask to defaults (color 0 transparent, others opaque)
 palt()
end

-- render perspective floor/ceiling with individual 32x32 sprites
function render_floor_ceiling()
 -- classic forward: forward = (cos(a), sin(a))
 -- use cached cos/sin from _draw() if available
 local fwdx=(ca_cached or cos(player.a))
 local fwdy=(sa_cached or sin(player.a))
 
 -- calculate horizon with safeguard against divide-by-zero
 local h
 if maxz<=0 then
  h=screen_height
 else
  h=sdist/maxz
 end
 
 -- fetch and render ceiling (sprites 34-36 from gfx/1_surfaces.gfx)
 local roof_typ=roof.typ
 local roof_src,roof_fallback=get_texture_source(roof_typ.tex,"ceiling")
 if roof_fallback then
  roof_src=get_error_texture("ceiling")
 end
 draw_rows(roof_src,-screen_center_y,-ceil(h/2),roof_typ.scale,roof_typ.height,cam[1]-roof.x,cam[2]-roof.y,roof_typ.lit,fwdx,fwdy,roof_typ.tex)
 
 -- fetch and render floor (sprites 32-33 from gfx/1_surfaces.gfx)
 local floor_typ=floor.typ
 local floor_src,floor_fallback=get_texture_source(floor_typ.tex,"floor")
 if floor_fallback then
  floor_src=get_error_texture("floor")
 end
 draw_rows(floor_src,ceil(h/2),screen_center_y-1,floor_typ.scale,floor_typ.height,cam[1]-floor.x,cam[2]-floor.y,floor_typ.lit,fwdx,fwdy,floor_typ.tex)
end

-- draw horizontal scanlines with 32x32 sprite sampling (optimized fog calls)
function draw_rows(src,y0,y1,tilesize,height,cx,cy,lit,sa,ca,tex)
 local size=sprite_size or 32
 
 -- normalize row_stride to prevent invalid config (guard against 0 or negative)
 local stride=max(1, row_stride or 1)
 
 -- track last applied fog level for this section to reduce calls
 local last_scanline_level=-2
 
 -- cache texture average color for duplication (avoid per-row src:get calls)
 local cached_fill_color=nil
 if stride > 1 and tex then
  cached_fill_color=avg_color_cache[tex]
  if not cached_fill_color then
   -- compute once and cache
   cached_fill_color=5  -- default fog color
   if src and src.get then
    cached_fill_color=src:get(16, 16) or 5
   end
   avg_color_cache[tex]=cached_fill_color
  end
 end
 
 for y=y0,y1,stride do
  -- calculate ray gradient
  local g=abs(y)/sdist
  
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
  
  -- apply fog uniformly (per scanline)
  -- compute expected fog level and only update when it changes
  local level=compute_fog_level(z)
  if level~=last_scanline_level then
   set_fog(z)
   last_scanline_level=level
  end
  
  -- count scanline for diagnostics (once per y iteration, consistent across modes)
  if debug_mode then
   diag_floor_rows+=1
  end
  
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
   batch_reset()
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
    u0=max(0,min(31,u0))
    v0=max(0,min(31,v0))
    local u1=u0+(rx1-rx0)*mdx*size
    local v1=v0+(rx1-rx0)*mdy*size
    batch_push(idx, rx0, screen_center_y+y, rx1, screen_center_y+y, u0, v0, u1, v1, 1, 1)
    if debug_mode then
     diag_floor_draw_calls+=1
    end
   end
   batch_submit()
  else
   -- simplified rendering: draw full scanline with single texture
   batch_reset()
   local idx=resolve_sprite_index(tex,"floor")
   local u0=(mx)%1*size
   local v0=(my)%1*size
   u0=max(0,min(31,u0))
   v0=max(0,min(31,v0))
   local u1=u0+(screen_width-1)*mdx*size
   local v1=v0+(screen_width-1)*mdy*size
   batch_push(idx, 0, screen_center_y+y, screen_width-1, screen_center_y+y, u0, v0, u1, v1, 1, 1)
   batch_submit()
   
   -- count draw calls for diagnostics (single draw call per scanline)
   if debug_mode then
    diag_floor_draw_calls+=1
   end
  end
  
  -- duplicate into skipped rows with solid fill for performance
  if stride > 1 and cached_fill_color then
   for dy=1,stride-1 do
    local next_y = y + dy
    if next_y <= y1 then
     rectfill(0, screen_center_y+next_y, screen_width-1, screen_center_y+next_y, cached_fill_color)
    end
   end
  end
 end
end

