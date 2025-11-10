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
   -- if debug_mode then
   --  diag_dda_steps_total+=dda_steps
   --  diag_dda_early_outs+=1
   -- end
   return 999,hx,hy,0,0
  end
  
  if hz<vz then
   -- horizontal closer
   -- crossing a vertical gridline (x changes): choose the cell we are entering
   local gx=flr(hx)+(hdx<0 and -1 or 0)
   local gy=flr(hy)
   
   -- irreversible OOB check for horizontal candidate
   if (gx<0 and hdx<0) or (gx>=map_size and hdx>0) or (gy<0 and hdy<0) or (gy>=map_size and hdy>0) then
    -- if debug_mode then
    --  diag_dda_steps_total+=dda_steps
    --  diag_dda_early_outs+=1
    -- end
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
     -- if debug_mode then
     --  diag_dda_steps_total+=dda_steps
     -- end
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
    -- if debug_mode then
    --  diag_dda_steps_total+=dda_steps
    --  diag_dda_early_outs+=1
    -- end
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
     -- if debug_mode then
     --  diag_dda_steps_total+=dda_steps
     -- end
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
-- if debug_mode then
--  diag_dda_steps_total+=dda_steps
--  diag_dda_early_outs+=1
-- end
 return 999,hx,hy,0,0
end

-- raycast entire scene
-- Note: ray arrays (ray_z, ray_x0, ray_x1, ray_dx, ray_dy, rbuf_tile, rbuf_tx)
-- use userdata for 24x performance gain per Picotron optimization guidelines
function raycast_scene()
 -- compute projection distance from FOV (fov is half-angle in radians)
 -- sdist = screen_center_x / tan(half_fov) ensures proper perspective mapping
 sdist=screen_center_x/math.tan(fov)
 
 -- classic forward basis: forward = (cos(a), sin(a))
 -- use cached cos/sin from _draw() if available
 local fwdx=(ca_cached or cos(player.a))
 local fwdy=(sa_cached or sin(player.a))
 maxz=0
 
  -- precompute per-ray screen spans (decouples ray_count from screen_width)
  -- only when active_ray_count changes
  local span_count = active_ray_count or ray_count
  if _last_span_count ~= span_count then
    for i=0,span_count-1 do
      ray_x0:set(i, flr(i*screen_width/span_count))
      ray_x1:set(i, max(ray_x0:get(i), flr((i+1)*screen_width/span_count)-1))
      -- precompute pixel center for camera-space offset (eliminates per-frame computation)
      local pixel_x=(ray_x0:get(i)+ray_x1:get(i))/2+0.5
      ray_px_center:set(i, pixel_x)
    end
    _last_span_count = span_count
  end
 
 for i=0,span_count-1 do
  -- use precomputed pixel center for camera-space offset
  local dx=ray_px_center:get(i)-screen_center_x
  local dy=sdist
  
  -- map camera-space to world-space and cache direction
  ray_dx:set(i, (-fwdy)*dx+fwdx*dy)
  ray_dy:set(i, ( fwdx)*dx+fwdy*dy)
  
  -- cast ray using cached direction
  local z,hx,hy,tile,tx=raycast(player.x,player.y,ray_dx:get(i),ray_dy:get(i),fwdx,fwdy)
  
  -- store hit data in dedicated per-ray arrays
  ray_z:set(i, z)
  rbuf_tile:set(i, tile)
  rbuf_tx:set(i, tx)
  
  maxz=max(maxz,z)
 end
 
 -- frustum AABB computation removed; sprite culling now uses distance checks
end

-- compute_frustum_aabb removed (distance-based culling is used instead)

-- hitscan for projectiles/line-of-sight
function hitscan(x,y,dx,dy)
 -- normalize and get wall depth
 local sa,ca=normalise(dx,dy)
 local d,hx,hy,tile,tx=raycast(x,y,dx,dy,sa,ca)
 
 local closest_obj=nil
 local closest_dist=d
 
 -- iterate all objects; check solid intersections before wall hit
 for ob in all(objects) do
  if ob and ob.pos and ob.typ and ob.typ.solid then
   local ox=ob.pos[1]-x
   local oy=ob.pos[2]-y
   local dn=ox*ca-oy*sa
   local dt=ox*sa+oy*ca
   if abs(dn)<= (ob.typ.w or 0)*0.5 and dt>0 and dt<d then
    if dt<closest_dist then
     closest_dist=dt
     closest_obj=ob
    end
   end
  end
 end
 
 return closest_obj,closest_dist
end
