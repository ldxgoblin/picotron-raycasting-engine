--[[pod_format="raw",created="2025-11-07 21:17:11",modified="2025-11-07 21:48:08",revision=1]]
-- rendering pipeline

-- track warned sprite indices to avoid per-frame spam
warned_sprites={}

-- lazy initialization flag for error texture
error_texture_initialized=false

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
function set_fog(z)
 if z<=0 then
  pal()
  last_fog_level=-1
  prev_pal={}
  -- preserve last_fog_z for hysteresis across sections
  return
 end
 
 local level
 if use_quadratic_fog then
  -- quadratic falloff with brightness adjustment
  local i=min(z,100)^2/fogdist
  i=min(1-(1-i)*screenbright,0.9999)
  level=flr(i*#pals)
 else
  -- simple linear distance fallback
  level=flr(min(z/8,15))
 end
 
 -- hysteresis: only update if z changed significantly (reduces palette thrashing)
 if abs(z-last_fog_z)<fog_hysteresis and last_fog_level>=0 then
  return
 end
 last_fog_z=z
 
 -- only update palette if fog level changed (reduces palette ops from 320/frame to ~10-20)
 if level~=last_fog_level then
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

-- render textured walls (with 2x upscaling and LOD)
function render_walls()
 palt(0,false)
 
 -- cache sprite sources by tile to avoid repeated get_spr() calls
 local tex_cache={}
 -- cache LOD average colors per tile to avoid per-frame src:get() sampling
 local avg_color_cache={}
 
 for ray_idx=0,ray_count-1 do
  -- read from every other zbuf/tbuf entry (populated by raycast)
  local z=zbuf[ray_idx*2+1]
  local t=tbuf[ray_idx*2+1]
  
  -- define x positions for this ray pair BEFORE the z check (needed by both branches)
  local x0=ray_idx*2
  local x1=ray_idx*2+1
  
  if z<999 then
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
      src,is_fallback=get_texture_source(tile,"wall")
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
    
    -- draw solid color columns (much faster than tline3d)
    local draw_y0=ceil(y0)
    local draw_y1=min(flr(y1),screen_height-1)
    rectfill(x0,draw_y0,x0,draw_y1,avg_color)
    rectfill(x1,draw_y0,x1,draw_y1,avg_color)
   else
    -- normal rendering with tline3d (draw vertical columns per ray)
    -- fetch sprite for this specific wall/door tile
    local cached=tex_cache[tile]
    local src,is_fallback
    if cached then
     src,is_fallback=cached.src,cached.is_fallback
    else
     src,is_fallback=get_texture_source(tile,"wall")
     tex_cache[tile]={src=src,is_fallback=is_fallback}
    end
    
    -- compute pixel UV in 32x32 sprite for x0 column
    local u0=flr(tx*32)
    u0=max(0,min(31,u0))
    
    -- compute u for x1 column with a light interpolation to next ray
    local u0_x1=u0
    if ray_idx<ray_count-1 then
     local t_next=tbuf[(ray_idx+1)*2+1]
     if t_next.tile==tile then
      local tx_next=t_next.tx
      local u0_next=flr(tx_next*32)
      u0_next=max(0,min(31,u0_next))
      u0_x1=flr(u0*0.5+u0_next*0.5)
      u0_x1=max(0,min(31,u0_x1))
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
    
    -- apply fog
    set_fog(z)
    
    -- draw the two upscaled vertical columns
    tline3d(src,x0,draw_y0,x0,draw_y1,u0,v0,u0,v1,1,1)
    tline3d(src,x1,draw_y0,x1,draw_y1,u0_x1,v0,u0_x1,v1,1,1)
   end
   
   -- populate zbuf for both columns (sprite occlusion needs pixel-accurate depth)
   zbuf[x0+1]=z
   zbuf[x1+1]=z
  else
   -- nothing to draw for this ray
  end
 end
 
 -- restore transparency mask to defaults (color 0 transparent, others opaque)
 palt()
 -- restore palette from fog remapping
 pal()
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
 
 pal()
end

-- draw horizontal scanlines with 32x32 sprite sampling (optimized fog calls)
function draw_rows(src,y0,y1,tilesize,height,cx,cy,lit,sa,ca,tex)
 local size=sprite_size or 32
 
 -- set fog once for lit surfaces instead of per scanline
 if lit then
  set_fog(0)
 end
 
 for y=y0,y1 do
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
  
  -- apply fog only for non-lit surfaces (per scanline)
  if not lit then
   set_fog(z)
  end
  
  -- texture coordinates (pixel UVs in 32x32 sprite)
  -- map fractional position (mx%1, my%1) to pixel offset (0-31) in 32x32 sprite
  local u0=(mx%1)*size
  local v0=(my%1)*size
  -- clamp starting UVs to [0,31] to guard against floating-point edge cases
  u0=max(0,min(31,u0))
  v0=max(0,min(31,v0))
  -- calculate end UVs based on texture delta across scanline (32px sprite width)
  local u1=u0+screen_width*mdx*size
  local v1=v0+screen_width*mdy*size
  
  -- draw scanline
  tline3d(src,0,screen_center_y+y,screen_width-1,screen_center_y+y,u0,v0,u1,v1,1,1)
 end
end

