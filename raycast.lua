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
function raycast(x,y,dx,dy,sa,ca)
 -- clamp near-zero components before normalization
 if abs(dx)<0.01 then dx=0.01 end
 if abs(dy)<0.01 then dy=0.01 end
 
 -- normalize direction if camera angles not provided
 if not sa then
  sa,ca=normalise(dx,dy)
 end
 
 -- horizontal ray initialization
 local hx,hy,hdx,hdy=x,y,sgn(dx),dy/abs(dx)
 local hdz,hz=hdx*sa+hdy*ca,0
 
 -- initial step to grid boundary
 local hstep=hx%1
 if hdx>0 then
  hstep=(1-hstep)
 else
  hx-=1
  hstep=(1-hstep)
 end
 hy+=hdy*hstep
 hz+=hdz*hstep
 
 -- vertical ray initialization
 local vx,vy,vdx,vdy=x,y,dx/abs(dy),sgn(dy)
 local vdz,vz=vdx*sa+vdy*ca,0
 
 -- initial step to grid boundary
 local vstep=vy%1
 if vdy>0 then
  vstep=(1-vstep)
 else
  vy-=1
  vstep=(1-vstep)
 end
 vx+=vdx*vstep
 vz+=vdz*vstep
 
 -- ray marching
 for iter=1,256 do
  if hz<vz then
   -- horizontal closer
   local gx,gy=flr(hx),flr(hy)
   if gx>=0 and gx<map_size and gy>=0 and gy<map_size then
    local m=get_wall(gx,gy)
    if m>0 then
     -- check if door
     if is_door(m) and doorgrid[gx][gy] then
      local dz=hz+hdz/2
      if dz<vz then
       local open=test_door_mode and test_door_open or doorgrid[gx][gy].open
       local dy_off=(hy+hdy/2)%1-open
       if dy_off>=0 then
        return dz,hx,hy,m,dy_off
       end
      end
     else
      -- wall hit
      return hz,hx,hy,m,(hy*hdx)%1
     end
    end
   end
   hx+=hdx
   hy+=hdy
   hz+=hdz
  else
   -- vertical closer or equal
   local gx,gy=flr(vx),flr(vy)
   if gx>=0 and gx<map_size and gy>=0 and gy<map_size then
    local m=get_wall(gx,gy)
    if m>0 then
     -- check if door
     if is_door(m) and doorgrid[gx][gy] then
      local dz=vz+vdz/2
      if dz<hz then
       local open=test_door_mode and test_door_open or doorgrid[gx][gy].open
       local dx_off=(vx+vdx/2)%1-open
       if dx_off>=0 then
        return dz,vx,vy,m,dx_off
       end
      end
     else
      -- wall hit
      return vz,vx,vy,m,(vx*-vdy)%1
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
 sdist=screen_center_x/tan(fov)
 
 local sa,ca=sin(player.a),cos(player.a)
 minx,maxx=999,-999
 miny,maxy=999,-999
 maxz=0
 
 for i=0,ray_count-1 do
  local dx=screen_center_x-i
  local dy=sdist
  
  -- rotate by camera angle
  local rdx=ca*dx+sa*dy
  local rdy=ca*dy-sa*dx
  
  local z,hx,hy,tile,tx=raycast(player.x,player.y,rdx,rdy,sa,ca)
  
  zbuf[i+1]=z
  tbuf[i+1]={tile=tile,tx=tx}
  
  -- track bounds for object culling
  minx=min(minx,hx)
  maxx=max(maxx,hx)
  miny=min(miny,hy)
  maxy=max(maxy,hy)
  maxz=max(maxz,z)
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
