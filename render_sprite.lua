-- sprite rendering pipeline

-- render sprites with z-buffer occlusion
function render_sprites()
 palt(0,false)
 palt(14,true)
 local src=get_texture_source()
 
 local sa,ca=sin(player.a),cos(player.a)
 local vvolg=screen_center_x/sdist
 
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
         insert(sobj,i,ob)
         inserted=true
         break
        end
       end
       if not inserted then
        add(sobj,ob)
       end
      end
     end
    end
   end
  end
 end
 
 -- draw sprites back-to-front
 drawobjs(sobj,sa,ca,src)
 
 clip()
 pal()
end

-- draw objects from sorted list
function drawobjs(sobj,sa,ca,src)
 for ob in all(sobj) do
  if not ob or not ob.typ or not ob.rel then
   goto skip_obj
  end
  
  local t=ob.typ
  local x=ob.rel[1]
  local z=ob.rel[2]
  
  -- get vertical offset (can be animated)
  local y=ob.y or t.y
  if t.yoffs then
   local frame_idx=flr(ob.frame%#t.yoffs)+1
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
   -- upright sprite
   local sy=y*f+screen_center_y
   local h=t.h*f
   y0=sy-h/2
   y1=sy+h/2
  end
  
  -- calculate sprite sheet coordinates
  local sx_sheet=t.mx
  local sy_sheet=t.my
  local sxd=t.mw/w
  local syd=t.mh/(y1-y0+0.01)
  
  -- handle animation
  if t.framect then
   local fr=flr(ob.frame)
   if ob.animloop then
    fr=fr%t.framect
   else
    fr=min(fr,t.framect-1)
   end
   sx_sheet+=fr*t.mw
  end
  
  -- compute floating left/top edges for sub-pixel adjustment
  local lx=sx-w/2
  local fy0=y0
  
  -- clamp to screen bounds
  local x0=max(0,ceil(lx))
  local x1=min(ray_count-1,flr(sx+w/2))
  -- adjust sx_sheet for x clipping
  if x0>lx then
   sx_sheet+=(x0-lx)*sxd
  end
  
  y0=max(0,ceil(fy0))
  y1=min(screen_height-1,flr(y1))
  -- adjust sy_sheet for y clipping
  if y0>fy0 then
   sy_sheet+=(y0-fy0)*syd
  end
  
  -- set fog and palette
  if ob.pal then
   pal(ob.pal)
  else
   set_fog(z*(t.lit or 1))
  end
  
  -- draw sprite column by column with z-buffer
  for px=x0,x1 do
   if z<zbuf[px+1] then
    -- not occluded, draw column
    local u_offset=sx_sheet+(px-x0)*sxd
    tline3d(src,px,y0,px,y1,u_offset,sy_sheet,u_offset,sy_sheet+t.mh,1,1)
   end
  end
  
  ::skip_obj::
 end
end
