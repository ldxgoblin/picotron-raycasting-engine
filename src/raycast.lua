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
 
 -- compute iteration limit from remaining grid crossings to map edges
 -- compute remaining crossings to nearest boundary per axis based on current positions
 local horizontal_crossings
 if hdx>0 then
  horizontal_crossings=map_size-flr(hx)
 else
  horizontal_crossings=flr(hx)+1
 end
 
 local vertical_crossings
 if vdy>0 then
  vertical_crossings=map_size-flr(vy)
 else
  vertical_crossings=flr(vy)+1
 end
 
 local iteration_limit=min(256,horizontal_crossings+vertical_crossings+10)
 
 -- track DDA steps for diagnostics
 local dda_steps=0
 
 -- ray marching
 for iter=1,iteration_limit do
  -- increment step counter
  dda_steps+=1
  
  -- far-plane check: early-out if both candidates exceed far_plane
  if min(hz, vz) > far_plane then
   if debug_mode then
    diag_dda_steps_total+=dda_steps
    diag_dda_early_outs+=1
   end
   return 999,hx,hy,0,0
  end
  
  if hz<vz then
   -- horizontal closer
   -- crossing a vertical gridline (x changes): choose the cell we are entering
   local gx=flr(hx)+(hdx<0 and -1 or 0)
   local gy=flr(hy)
   
   -- irreversible OOB check for horizontal candidate
   if (gx<0 and hdx<0) or (gx>=map_size and hdx>0) or (gy<0 and hdy<0) or (gy>=map_size and hdy>0) then
    if debug_mode then
     diag_dda_steps_total+=dda_steps
     diag_dda_early_outs+=1
    end
    return 999,hx,hy,0,0
   end
   
   if gx>=0 and gx<map_size and gy>=0 and gy<map_size then
    local m=get_wall(gx,gy)
    if m>0 then
     -- check if door
     if is_door(m) and doorgrid[gx][gy] then
     local dz=((hx+hdx/2-x)*fx+(hy+hdy/2-y)*fy)
      if dz<=vz then
       local open = test_door_mode and (test_door_open or 0) or doorgrid[gx][gy].open
       local dy_off=(hy+hdy/2)%1-open
       if dy_off>=0 then
        return dz,hx,hy,m,dy_off
       end
      end
     else
      -- wall hit
     if debug_mode then
      diag_dda_steps_total+=dda_steps
     end
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
   
   -- irreversible OOB check for vertical candidate
   if (gx<0 and vdx<0) or (gx>=map_size and vdx>0) or (gy<0 and vdy<0) or (gy>=map_size and vdy>0) then
    if debug_mode then
     diag_dda_steps_total+=dda_steps
     diag_dda_early_outs+=1
    end
    return 999,vx,vy,0,0
   end
   
   if gx>=0 and gx<map_size and gy>=0 and gy<map_size then
    local m=get_wall(gx,gy)
    if m>0 then
     -- check if door
     if is_door(m) and doorgrid[gx][gy] then
     local dz=((vx+vdx/2-x)*fx+(vy+vdy/2-y)*fy)
      if dz<=hz then
       local open = test_door_mode and (test_door_open or 0) or doorgrid[gx][gy].open
       local dx_off=(vx+vdx/2)%1-open
       if dx_off>=0 then
        return dz,vx,vy,m,dx_off
       end
      end
     else
      -- wall hit
     if debug_mode then
      diag_dda_steps_total+=dda_steps
     end
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
 if debug_mode then
  diag_dda_steps_total+=dda_steps
  diag_dda_early_outs+=1
 end
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
 
 -- precompute per-ray screen spans (decouples ray_count from screen_width)
 for i=0,ray_count-1 do
  ray_x0[i]=flr(i*screen_width/ray_count)
  ray_x1[i]=max(ray_x0[i], flr((i+1)*screen_width/ray_count)-1)
 end
 
 for i=0,ray_count-1 do
  -- compute pixel center for this ray's span
  local pixel_x=(ray_x0[i]+ray_x1[i])/2+0.5
  local dx=pixel_x-screen_center_x
  local dy=sdist
  
  -- map camera-space to world-space and cache direction
  ray_dx[i]=(-fwdy)*dx+fwdx*dy
  ray_dy[i]=( fwdx)*dx+fwdy*dy
  
  -- cast ray using cached direction
  local z,hx,hy,tile,tx=raycast(player.x,player.y,ray_dx[i],ray_dy[i],fwdx,fwdy)
  
  -- store hit data in dedicated per-ray arrays
  ray_z[i]=z
  rbuf[i].tile=tile
  rbuf[i].tx=tx
  
  -- track bounds for object culling (only update on valid hits)
  if z<999 then
   minx=min(minx,hx)
   maxx=max(maxx,hx)
   miny=min(miny,hy)
   maxy=max(maxy,hy)
  end
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
 
 -- compute frustum AABB for sprite culling (independent of wall hits)
 compute_frustum_aabb()
end

-- compute camera-space frustum AABB for sprite culling (independent of wall hits)
-- returns world-space bounding box covering the view frustum out to far_plane
function compute_frustum_aabb()
  -- use cached camera basis
  local fwdx = ca_cached or cos(player.a)
  local fwdy = sa_cached or sin(player.a)
  local rightx = -fwdy  -- right vector perpendicular to forward
  local righty = fwdx
  
  -- compute horizontal extent at far_plane using FOV
  -- half_width = far_plane * tan(fov) = far_plane * (screen_center_x / sdist)
  local half_width = far_plane * (screen_center_x / sdist)
  
  -- compute four frustum corners in camera space:
  -- near-left, near-right, far-left, far-right
  -- (we use a small near distance to avoid player position issues)
  local near_dist = 0.1
  local near_half = near_dist * (screen_center_x / sdist)
  
  -- transform corners to world space and track min/max
  local wx_min = 999
  local wx_max = -999
  local wy_min = 999
  local wy_max = -999
  
  -- near-left corner
  local cx = -near_half
  local cz = near_dist
  local wx = player.x + fwdx * cz + rightx * cx
  local wy = player.y + fwdy * cz + righty * cx
  wx_min = min(wx_min, wx)
  wx_max = max(wx_max, wx)
  wy_min = min(wy_min, wy)
  wy_max = max(wy_max, wy)
  
  -- near-right corner
  cx = near_half
  wx = player.x + fwdx * cz + rightx * cx
  wy = player.y + fwdy * cz + righty * cx
  wx_min = min(wx_min, wx)
  wx_max = max(wx_max, wx)
  wy_min = min(wy_min, wy)
  wy_max = max(wy_max, wy)
  
  -- far-left corner
  cx = -half_width
  cz = far_plane
  wx = player.x + fwdx * cz + rightx * cx
  wy = player.y + fwdy * cz + righty * cx
  wx_min = min(wx_min, wx)
  wx_max = max(wx_max, wx)
  wy_min = min(wy_min, wy)
  wy_max = max(wy_max, wy)
  
  -- far-right corner
  cx = half_width
  wx = player.x + fwdx * cz + rightx * cx
  wy = player.y + fwdy * cz + righty * cx
  wx_min = min(wx_min, wx)
  wx_max = max(wx_max, wx)
  wy_min = min(wy_min, wy)
  wy_max = max(wy_max, wy)
  
  -- clamp to map boundaries and add small margin for sprite width
  local margin = objgrid_size
  frustum_minx = max(0, wx_min - margin)
  frustum_maxx = min(map_size - 1, wx_max + margin)
  frustum_miny = max(0, wy_min - margin)
  frustum_maxy = min(map_size - 1, wy_max + margin)
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
