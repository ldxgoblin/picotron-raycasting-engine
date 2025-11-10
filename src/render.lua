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
    pal(i,p[i+1])
    prev_pal[i]=p[i+1]
   end
  end
  last_fog_level=level
 end
end

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
    
    -- draw columns across the span with interpolated u
    for x=x0,x1 do
     local u_interp=u0+(u1-u0)*(x-x0)/(x1-x0+0.01)
     u_interp=max(0,min(31,u_interp))
     tline3d(src,x,draw_y0,x,draw_y1,u_interp,v0,u_interp,v1,1,1)
     -- write zbuf per pixel
     zbuf[x+1]=z
    end
    
    -- count wall columns for diagnostics
    if debug_mode then
     diag_wall_columns+=(x1-x0+1)
    end
   end
  else
   -- miss: still write zbuf for the span to maintain occlusion
   for x=x0,x1 do
    zbuf[x+1]=999
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
   -- per-cell floor type rendering: sample floor types along scanline and build runs
   local runs={}
   local sample_interval=4
   local current_run=nil
   
   for x=0,screen_width-1,sample_interval do
    -- compute world coordinates at this x
    local wx=mx+x*mdx
    local wy=my+x*mdy
    local gx=flr(wx)
    local gy=flr(wy)
    
    -- read floor type from map (0=use global default)
    local floor_id=get_floor(gx,gy)
    
    -- start new run or extend current run
    if not current_run then
     current_run={x0=x,x1=x,floor_id=floor_id}
    elseif current_run.floor_id==floor_id then
     current_run.x1=x
    else
     -- close current run and start new one
     current_run.x1=x-1
     add(runs,current_run)
     current_run={x0=x,x1=x,floor_id=floor_id}
    end
   end
   
   -- close final run
   if current_run then
    current_run.x1=screen_width-1
    add(runs,current_run)
   end
   
   -- merge short runs (width < 4 pixels) into adjacent runs to reduce draw calls
   local merged_runs={}
   for i=1,#runs do
    local run=runs[i]
    local width=run.x1-run.x0+1
    if width<4 and #merged_runs>0 then
     -- merge into previous run
     merged_runs[#merged_runs].x1=run.x1
    else
     add(merged_runs,run)
    end
   end
   
   -- draw each run with appropriate texture
   for run in all(merged_runs) do
    local run_src=src
    local run_fallback=false
    
    -- select texture from planetyps if floor_id is valid
    if run.floor_id>0 and run.floor_id<=#planetyps then
     local floor_type=planetyps[run.floor_id]
     run_src,run_fallback=get_texture_source(floor_type.tex,"floor")
     if run_fallback then
      run_src=get_error_texture("floor")
     end
    end
    
    -- compute UVs for this run segment
    local u0=(mx+run.x0*mdx)%1*size
    local v0=(my+run.x0*mdy)%1*size
    u0=max(0,min(31,u0))
    v0=max(0,min(31,v0))
    local u1=u0+(run.x1-run.x0)*mdx*size
    local v1=v0+(run.x1-run.x0)*mdy*size
    
    -- draw run scanline
    tline3d(run_src,run.x0,screen_center_y+y,run.x1,screen_center_y+y,u0,v0,u1,v1,1,1)
    
    -- count draw calls for diagnostics (per run)
    if debug_mode then
     diag_floor_draw_calls+=1
    end
   end
  else
   -- simplified rendering: draw full scanline with single texture
   local u0=(mx)%1*size
   local v0=(my)%1*size
   u0=max(0,min(31,u0))
   v0=max(0,min(31,v0))
   local u1=u0+(screen_width-1)*mdx*size
   local v1=v0+(screen_width-1)*mdy*size
   
   -- draw full scanline
   tline3d(src,0,screen_center_y+y,screen_width-1,screen_center_y+y,u0,v0,u1,v1,1,1)
   
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

