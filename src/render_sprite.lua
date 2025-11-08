--[[pod_format="raw",created="2025-11-07 21:17:10",modified="2025-11-07 21:48:08",revision=1]]
-- sprite rendering pipeline

-- render sprites with z-buffer occlusion (optimized culling)
function render_sprites()
 -- use cached sin/cos from _draw() if available
 local sa,ca=sa_cached or sin(player.a),ca_cached or cos(player.a)
 local vvolg=screen_center_x/sdist
 
 -- early exit if bounds are degenerate
 if minx>maxx or miny>maxy then
  return
 end
 
 -- transform and cull objects
 local sobj={}
 
 for gx=flr(minx/objgrid_size),flr(maxx/objgrid_size) do
  for gy=flr(miny/objgrid_size),flr(maxy/objgrid_size) do
   if gx>=0 and gx<=objgrid_array_size and gy>=0 and gy<=objgrid_array_size then
    for ob in all(objgrid[gx+1][gy+1]) do
     if ob and ob.pos and ob.typ then
      -- transform to view space
      local rx=ob.pos[1]-player.x
      local ry=ob.pos[2]-player.y
      
      -- rotate to view-aligned coordinates
      ob.rel[1]=-ca*rx-sa*ry
      ob.rel[2]=ca*ry-sa*rx
      
      -- depth culling: skip sprites beyond max wall depth
      if ob.rel[2]>=maxz then
       goto skip_sprite
      end
      
      -- cull behind camera and outside frustum
      local t=ob.typ
      local pass_frustum=false
      if ob.rel[2]>0.1 then
       if t.flat then
        -- flat sprites: require minimum distance to prevent z-division issues
        if ob.rel[2]>=t.w/2 then
         pass_frustum=true
        end
       else
        -- upright sprites: horizontal frustum culling
        if abs(ob.rel[1])-t.w<ob.rel[2]*(screen_center_x/sdist) then
         pass_frustum=true
        end
       end
      end
      
      if pass_frustum then
       -- compute sort order (depth)
       ob.sortorder=ob.rel[2]
       
       -- flat sprites sort differently (on ground plane)
       if ob.typ.flat then
        ob.sortorder+=1000
       end
       
       -- insertion sort into sobj (back-to-front)
       local inserted=false
       for i=1,#sobj do
        if ob.sortorder>sobj[i].sortorder then
         -- manual array insertion
         for j=#sobj,i,-1 do
          sobj[j+1]=sobj[j]
         end
         sobj[i]=ob
         inserted=true
         break
        end
       end
       if not inserted then
        add(sobj,ob)
       end
      end
      
      ::skip_sprite::
     end
    end
   end
  end
 end
 
 -- draw sprites back-to-front
 drawobjs(sobj,sa,ca)
 
 clip()
 pal()
end

-- draw objects from sorted list with individual 32x32 sprites (color 0=opaque, color 14=transparent)
function drawobjs(sobj,sa,ca)
 palt(0,false)
 palt(14,true)
 
 for ob in all(sobj) do
  if not ob or not ob.typ or not ob.rel then
   goto skip_obj
  end
  
  local t=ob.typ
  local x=ob.rel[1]
  local z=ob.rel[2]
  
  -- fetch sprite for this object
  local base_sprite_index = ob.sprite_index or t.mx
  local sprite_index = base_sprite_index
  
  -- handle animation with sequential sprite indexes
  if t.framect then
   local fr=flr(ob.frame or 0)
   if ob.animloop then
    fr=fr%t.framect
   else
    fr=min(fr,t.framect-1)
   end
   sprite_index = base_sprite_index + fr
  end
  
  -- validate sprite exists; if animation overflow, reset to base
  local test_src = get_spr(sprite_index)
  if not test_src then
   if sprite_index ~= base_sprite_index then
    -- animation frame overflow detected
    if not warned_sprites[base_sprite_index] then
     printh("warning: animation frame overflow for sprite "..base_sprite_index..", clamping to base")
     warned_sprites[base_sprite_index]=true
    end
    sprite_index = base_sprite_index
   end
  end
  
  local src,is_fallback = get_texture_source(sprite_index,"sprite")
  if is_fallback then
   src = get_error_texture("sprite")
  end
  
  -- get vertical offset (can be animated)
  local y=ob.y or t.y
  if t.yoffs then
   local frame = ob.frame or 0
   local frame_idx=flr(frame%#t.yoffs)+1
   if frame_idx>0 and frame_idx<=#t.yoffs then
    y+=t.yoffs[frame_idx]
   end
  end
  
  -- calculate scale factor (perspective)
  local f=sdist/z
  
  -- project to screen space
  local sx=x*f+screen_center_x
  local w=t.w*f
  
  -- calculate y coordinates (different for flat vs upright)
  local y0,y1
  if t.flat then
   -- floor-aligned sprite
   local z0=z+t.w/2
   local z1=z-t.w/2
   y0=y*sdist/z0+screen_center_y
   y1=y*sdist/z1+screen_center_y
  else
   -- upright sprite (use world-space height t.h, not pixel size sprite_size)
   local sy=y*f+screen_center_y
   local h=t.h*f
   y0=sy-h/2
   y1=sy+h/2
  end
  
  -- map screen dimensions to 32x32 sprite UV space
  local size=sprite_size or 32
  local sxd=size/w
  local syd=size/(y1-y0+0.01)
  
  -- UV coordinates start at (0,0) for top-left of 32x32 sprite
  local u0 = 0
  local v0 = 0
  
  -- compute floating left/top edges for sub-pixel adjustment
  local lx=sx-w/2
  local fy0=y0
  
  -- clamp to screen bounds (0 to screen_width-1 for X, 0 to screen_height-1 for Y)
  local x0=max(0,ceil(lx))
  local x1=min(screen_width-1,flr(sx+w/2))
  -- adjust u0 for x clipping
  if x0>lx then
   u0+=(x0-lx)*sxd
  end
  
  y0=max(0,ceil(fy0))
  y1=min(screen_height-1,flr(y1))
  -- adjust v0 for y clipping
  if y0>fy0 then
   v0+=(y0-fy0)*syd
  end
  
  -- guard against degenerate vertical or horizontal span
  if y1<=y0 or x1<x0 then
   goto skip_obj
  end
  
  -- set fog and palette
  if ob.pal then
   pal(ob.pal)
  else
   set_fog(z*(t.lit or 1))
  end
  
  -- draw sprite column by column with z-buffer (batched runs)
  local run_start=-1
  local run_u0=-1
  
  for px=x0,x1 do
   if z<zbuf[px+1] then
    -- not occluded, add to run
    local u_offset=u0+(px-x0)*sxd
    if run_start<0 then
     -- start new run
     run_start=px
     run_u0=u_offset
    end
   else
    -- occluded, flush run if any
    if run_start>=0 then
     local run_u1=u0+(px-1-x0)*sxd
     tline3d(src,run_start,y0,px-1,y1,run_u0,v0,run_u1,v0+size,1,1)
     run_start=-1
    end
   end
  end
  
  -- flush final run
  if run_start>=0 then
   local run_u1=u0+(x1-x0)*sxd
   tline3d(src,run_start,y0,x1,y1,run_u0,v0,run_u1,v0+size,1,1)
  end
  
  ::skip_obj::
 end
 
 -- restore transparency mask to defaults
 palt()
end
