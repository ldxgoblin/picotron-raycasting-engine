-- rendering pipeline

-- get sprite sheet for tline3d
function get_texture_source()
 -- return sprite sheet userdata (index 0)
 return get_spr(0)
end

-- track last applied fog level to reduce palette changes
last_fog_level=-1

-- apply distance-based fog (with caching for performance)
function set_fog(z)
 if z<=0 then
  pal()
  last_fog_level=-1
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
   pal(i,p[i+1])
  end
  last_fog_level=level
 end
end

-- render textured walls
function render_walls()
 palt(0,false)
 local src=get_texture_source()
 
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
   
   -- compute pixel UV in spritesheet (8x8 tiles)
   -- current approach: tile x,y position in 16-tile-wide sheet
   -- functionally equivalent to reference's ((t\8)+t%1)*4 encoding
   -- but more maintainable for Picotron's tile-based system
   local tile_x=tile%16
   local tile_y=flr(tile/16)
   -- pixel u is tile_x*8 + fractional offset tx*8 (clamped 0-7)
   local u0=tile_x*8+flr(tx*8)
   local v0=tile_y*8
   local u1=u0
   local v1=v0+8
   
   -- sub-pixel adjustment with texture v adjustment
   local yadj=ceil(y0)-y0
   y0+=yadj
   -- adjust v0 to maintain texture continuity when top is clipped
   if y1>y0 then
    v0+=(yadj/(y1-y0))*8
    v1=v0+8
   end
   
   -- clamp
   y1=min(flr(y1),screen_height-1)
   
   -- apply fog
   set_fog(z)
   
   -- draw textured column (vertical sample u0==u1)
   tline3d(src,x,y0,x,y1,u0,v0,u1,v1,1,1)
  end
 end
 
 pal()
end

-- render perspective floor/ceiling
function render_floor_ceiling()
 local sa,ca=sin(player.a),cos(player.a)
 local src=get_texture_source()
 
 -- calculate horizon with safeguard against divide-by-zero
 local h
 if maxz<=0 then
  h=screen_height
 else
  h=sdist/maxz
 end
 
 -- render ceiling
 local roof_typ=roof.typ
 draw_rows(src,-screen_center_y,-ceil(h/2),roof_typ.scale,roof_typ.height,cam[1]-roof.x,cam[2]-roof.y,roof_typ.lit,sa,ca,roof_typ.tex)
 
 -- render floor
 local floor_typ=floor.typ
 draw_rows(src,ceil(h/2),screen_center_y-1,floor_typ.scale,floor_typ.height,cam[1]-floor.x,cam[2]-floor.y,floor_typ.lit,sa,ca,floor_typ.tex)
 
 pal()
end

-- draw horizontal scanlines
function draw_rows(src,y0,y1,tilesize,height,cx,cy,lit,sa,ca,tex)
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
  
  -- texture coordinates (pixel UVs in 8x8 tile)
  local tile_x=tex%16
  local tile_y=flr(tex/16)
  local base_u=tile_x*8
  local base_v=tile_y*8
  
  -- map fractional position to pixel offset within tile
  local u0=base_u+(mx%1)*8
  local v0=base_v+(my%1)*8
  -- calculate end UVs based on texture delta across scanline
  local u1=u0+screen_width*mdx*8
  local v1=v0+screen_width*mdy*8
  
  -- draw scanline
  tline3d(src,0,screen_center_y+y,screen_width-1,screen_center_y+y,u0,v0,u1,v1,1,1)
 end
end

