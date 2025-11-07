--[[pod_format="raw",created="2025-11-07 21:17:11",modified="2025-11-07 21:48:08",revision=1]]
-- rendering pipeline

-- track warned sprite indices to avoid per-frame spam
warned_sprites={}

-- lazy initialization flag for error texture
error_texture_initialized=false

-- initialize error texture on first access (defensive fallback)
function init_error_texture()
 if not error_texture_initialized and not error_texture then
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

-- get individual sprite userdata for tline3d by sprite index
function get_texture_source(sprite_index)
 -- default to sprite 0 for backward compatibility
 sprite_index=sprite_index or 0
 
 -- return sprite sheet userdata
 local src=get_spr(sprite_index)
 if not src then
  -- warn once per sprite index to avoid per-frame spam
  if not warned_sprites[sprite_index] then
   printh("warning: sprite "..sprite_index.." not found")
   warned_sprites[sprite_index]=true
  end
  -- ensure error texture is initialized (defensive fallback)
  init_error_texture()
  -- return error texture (magenta checkerboard) for missing sprites
  return error_texture,true
 end
 return src,false
end

-- track last applied fog level to reduce palette changes
last_fog_level=-1
prev_pal={}

-- apply distance-based fog (with caching for performance)
function set_fog(z)
 if z<=0 then
  pal()
  last_fog_level=-1
  prev_pal={}
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

-- render textured walls
function render_walls()
 palt(0,false)
 
 -- cache sprite sources by tile to avoid repeated get_spr() calls
 local tex_cache={}
 
 for x=0,ray_count-1 do
  local z=zbuf[x+1]
  local t=tbuf[x+1]
  
  if z<999 then
   -- calculate wall height
   local h=sdist/z
   local y0=screen_center_y-h/2
   local y1=screen_center_y+h/2
   
   -- extract texture coordinates from table
   local tile=t.tile
   local tx=t.tx
   
   -- fetch sprite for this specific wall/door tile (0-26 from gfx/0_walls.gfx)
   -- tile ranges: walls 0-23 (brick/cobblestone/wood/stone/grass/earth), doors 24-26
   -- use cached sprite source when available
   local cached=tex_cache[tile]
   local src,is_fallback
   if cached then
    src,is_fallback=cached.src,cached.is_fallback
   else
    src,is_fallback=get_texture_source(tile)
    tex_cache[tile]={src=src,is_fallback=is_fallback}
   end
   
   -- render wall with error texture if sprite missing (visible as magenta checkerboard)
   -- compute pixel UV in 32x32 sprite
   -- map fractional tx (0-1) to pixel u (0-31) in 32x32 sprite
   local u0=flr(tx*32)
   -- clamp u0 to [0,31] to avoid out-of-range sampling when tx is numerically 1.0
   u0=max(0,min(31,u0))
   local u1=u0
   local v0=0
   local v1=32
   
   -- sub-pixel adjustment with texture v adjustment
   local yadj=ceil(y0)-y0
   y0+=yadj
   -- adjust v0 to maintain texture continuity when top is clipped
   if y1>y0 then
    v0+=(yadj/(y1-y0))*32
    v1=v0+32
   end
   
   -- clamp
   y1=min(flr(y1),screen_height-1)
   
   -- apply fog
   set_fog(z)
   
   -- draw textured column (vertical sample u0==u1)
   -- renders wall texture variants and door tiles with correct 32x32 textures
   tline3d(src,x,y0,x,y1,u0,v0,u1,v1,1,1)
  end
 end
 
 -- restore transparency mask to defaults (color 0 transparent, others opaque)
 palt()
 -- restore palette from fog remapping
 pal()
end

-- render perspective floor/ceiling with individual 32x32 sprites
function render_floor_ceiling()
 local sa,ca=sin(player.a),cos(player.a)
 
 -- calculate horizon with safeguard against divide-by-zero
 local h
 if maxz<=0 then
  h=screen_height
 else
  h=sdist/maxz
 end
 
 -- fetch and render ceiling (sprites 34-36 from gfx/1_surfaces.gfx)
 local roof_typ=roof.typ
 local roof_src,roof_fallback=get_texture_source(roof_typ.tex)
 if roof_fallback then
  roof_src=error_texture
 end
 draw_rows(roof_src,-screen_center_y,-ceil(h/2),roof_typ.scale,roof_typ.height,cam[1]-roof.x,cam[2]-roof.y,roof_typ.lit,sa,ca,roof_typ.tex)
 
 -- fetch and render floor (sprites 32-33 from gfx/1_surfaces.gfx)
 local floor_typ=floor.typ
 local floor_src,floor_fallback=get_texture_source(floor_typ.tex)
 if floor_fallback then
  floor_src=error_texture
 end
 draw_rows(floor_src,ceil(h/2),screen_center_y-1,floor_typ.scale,floor_typ.height,cam[1]-floor.x,cam[2]-floor.y,floor_typ.lit,sa,ca,floor_typ.tex)
 
 pal()
end

-- draw horizontal scanlines with 32x32 sprite sampling
function draw_rows(src,y0,y1,tilesize,height,cx,cy,lit,sa,ca,tex)
 local size=sprite_size or 32
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
  
  -- apply fog
  set_fog(lit and 0 or z)
  
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

