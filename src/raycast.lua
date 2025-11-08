--[[pod_format="raw",created="2025-11-07 21:17:12",modified="2025-11-07 21:48:07",revision=1]]
-- raycasting core

-- sign helper
function sgn(n)
 if n<0 then return -1 end
 if n>0 then return 1 end
 return 0
end

-- vector length
function length(x,y)
 x/=16
 y/=16
 return sqrt(x*x+y*y)*16
end

-- vector normalization
function normalise(x,y)
 local l=length(x,y)
 if l<=0.0001 then return 0,1 end
 return x/l,y/l
end

-- dda raycast with z-depth tracking
-- fx,fy represent the forward/depth axis used for perpendicular distance:
--  - In main scene: fx,fy = camera forward = (cos(a), sin(a))
--  - In hitscan:    fx,fy = normalized ray direction
function raycast(x,y,dx,dy,fx,fy)
 -- clamp near-zero components before normalization
 if abs(dx)<0.01 then dx=0.01 end
 if abs(dy)<0.01 then dy=0.01 end
 
 -- normalize direction if forward axis not provided
 if not fx then
  fx,fy=normalise(dx,dy)
 end
 
 -- horizontal ray initialization
 local hx,hy,hdx,hdy=x,y,sgn(dx),dy/abs(dx)
 local hdz,hz=hdx*fx+hdy*fy,0
 
 -- initial step to grid boundary
 local fracx=hx%1
 local hstep
 if hdx>0 then
  hstep=1-fracx
 else
  hstep=fracx
 end
 hx+=hdx*hstep
 hy+=hdy*hstep
 hz+=hdz*hstep
 
 -- vertical ray initialization
 local vx,vy,vdx,vdy=x,y,dx/abs(dy),sgn(dy)
 local vdz,vz=vdx*fx+vdy*fy,0
 
 -- initial step to grid boundary
 local fracy=vy%1
 local vstep
 if vdy>0 then
  vstep=1-fracy
 else
  vstep=fracy
 end
 vx+=vdx*vstep
 vy+=vdy*vstep
 vz+=vdz*vstep
 
 -- ray marching
 for iter=1,256 do
  if hz<vz then
   -- horizontal closer
   -- crossing a vertical gridline (x changes): choose the cell we are entering
   local gx=flr(hx)+(hdx<0 and -1 or 0)
   local gy=flr(hy)
   if gx>=0 and gx<map_size and gy>=0 and gy<map_size then
    local m=get_wall(gx,gy)
    if m>0 then
     -- check if door
     if is_door(m) and doorgrid[gx][gy] then
     local dz=((hx+hdx/2-x)*fx+(hy+hdy/2-y)*fy)
      if dz<=vz then
       local open=test_door_mode and test_door_open or doorgrid[gx][gy].open
       local dy_off=(hy+hdy/2)%1-open
       if dy_off>=0 then
        return dz,hx,hy,m,dy_off
       end
      end
     else
      -- wall hit
     local z=((hx-x)*fx+(hy-y)*fy)
     -- texture coordinate from y-fraction; flip when rayDirX > 0
     local frac=hy-flr(hy)
     local tx=(hdx>0) and (1-frac) or frac
     return z,hx,hy,m,tx
     end
    end
   end
   hx+=hdx
   hy+=hdy
   hz+=hdz
  else
   -- vertical closer or equal
   -- crossing a horizontal gridline (y changes): choose the cell we are entering
   local gx=flr(vx)
   local gy=flr(vy)+(vdy<0 and -1 or 0)
   if gx>=0 and gx<map_size and gy>=0 and gy<map_size then
    local m=get_wall(gx,gy)
    if m>0 then
     -- check if door
     if is_door(m) and doorgrid[gx][gy] then
     local dz=((vx+vdx/2-x)*fx+(vy+vdy/2-y)*fy)
      if dz<=hz then
       local open=test_door_mode and test_door_open or doorgrid[gx][gy].open
       local dx_off=(vx+vdx/2)%1-open
       if dx_off>=0 then
        return dz,vx,vy,m,dx_off
       end
      end
     else
      -- wall hit
     local z=((vx-x)*fx+(vy-y)*fy)
     -- texture coordinate from x-fraction; flip when rayDirY < 0
     local frac=vx-flr(vx)
     local tx=(vdy<0) and (1-frac) or frac
     return z,vx,vy,m,tx
     end
    end
   end
   vx+=vdx
   vy+=vdy
   vz+=vdz
  end
 end
 
 -- fallback if iteration limit reached
 return 999,hx,hy,0,0
end

-- raycast entire scene
function raycast_scene()
 -- compute projection distance from FOV (fov is half-angle in radians)
 -- sdist = screen_center_x / tan(half_fov) ensures proper perspective mapping
 sdist=screen_center_x/math.tan(fov)
 
 -- classic forward basis: forward = (cos(a), sin(a))
 -- use cached cos/sin from _draw() if available
 local fwdx=(ca_cached or cos(player.a))
 local fwdy=(sa_cached or sin(player.a))
 minx,maxx=999,-999
 miny,maxy=999,-999
 maxz=0
 
 for i=0,ray_count-1 do
  -- map ray index to pixel center, then to screen-centered offset
  -- scale automatically adapts if screen_width != ray_count*2
  local pixel_x=(i+0.5)*(screen_width/ray_count)
  local dx=pixel_x-screen_center_x
  local dy=sdist
  
  -- map camera-space (dx along right, dy forward) to world:
  -- right = (-fwdy, fwdx); forward = (fwdx, fwdy)
  local rdx=(-fwdy)*dx+fwdx*dy
  local rdy=( fwdx)*dx+fwdy*dy
  
  -- pass forward components to DDA as (fx, fy) = (cos, sin)
  local z,hx,hy,tile,tx=raycast(player.x,player.y,rdx,rdy,fwdx,fwdy)
  
  zbuf[i*2+1]=z
  tbuf[i*2+1].tile=tile
  tbuf[i*2+1].tx=tx
  
  -- track bounds for object culling
  minx=min(minx,hx)
  maxx=max(maxx,hx)
  miny=min(miny,hy)
  maxy=max(maxy,hy)
  maxz=max(maxz,z)
 end
 
 -- validate and clamp culling bounds to map range
 if minx>maxx or miny>maxy then
  -- degenerate bounds (no valid hits), set to player position
  minx,maxx=player.x,player.x
  miny,maxy=player.y,player.y
 else
  -- clamp to map boundaries [0, map_size-1]
  minx=max(0,minx)
  maxx=min(map_size-1,maxx)
  miny=max(0,miny)
  maxy=min(map_size-1,maxy)
  
  -- add margin for sprite culling (expand by objgrid_size)
  minx=max(0,minx-objgrid_size)
  maxx=min(map_size-1,maxx+objgrid_size)
  miny=max(0,miny-objgrid_size)
  maxy=min(map_size-1,maxy+objgrid_size)
 end
end

-- hitscan for projectiles/line-of-sight
function hitscan(x,y,dx,dy)
 -- normalize and get wall depth
 local sa,ca=normalise(dx,dy)
 local d,hx,hy,tile,tx=raycast(x,y,dx,dy,sa,ca)
 
 -- determine aabb
 local x0,y0=min(x,hx),min(y,hy)
 local x1,y1=max(x,hx),max(y,hy)
 
 local closest_obj=nil
 local closest_dist=d
 
 -- iterate relevant objgrid cells
 for gx=flr(x0/objgrid_size),flr(x1/objgrid_size) do
  for gy=flr(y0/objgrid_size),flr(y1/objgrid_size) do
   if gx>=0 and gx<=objgrid_array_size and gy>=0 and gy<=objgrid_array_size then
    for ob in all(objgrid[gx+1][gy+1]) do
     -- check if solid object
     if ob.typ and ob.typ.solid then
      -- compute normal and tangential distances
      local ox=ob.pos[1]-x
      local oy=ob.pos[2]-y
      local dn=(ox)*ca-(oy)*sa
      local dt=(ox)*sa+(oy)*ca
      
      -- check if within normal bounds
      if abs(dn)<=ob.typ.w*0.5 then
       -- check if not behind or beyond wall
       if dt>0 and dt<d then
        -- track closest object
        if dt<closest_dist then
         closest_dist=dt
         closest_obj=ob
        end
       end
      end
     end
    end
   end
  end
 end
 
 return closest_obj,closest_dist
end
