--[[pod_format="raw",created="2025-11-07 21:17:10",modified="2025-11-07 21:48:08",revision=1]]
-- sprite rendering pipeline

-- global sprite tline batch (12 cols: idx,x0,y0,x1,y1,u0,v0,u1,v1,w0,w1)
local SPR_TLINE_COLS=12
local spr_tline_capacity=screen_width*2
local spr_tline_args=userdata("f64", SPR_TLINE_COLS, spr_tline_capacity)
local spr_tline_count=0
local function sbatch_reset() spr_tline_count=0 end
local function sbatch_push(idx,x0,y0,x1,y1,u0,v0,u1,v1,w0,w1)
 if spr_tline_count>=spr_tline_capacity then
  tline3d(spr_tline_args, 0, spr_tline_count, SPR_TLINE_COLS)
  spr_tline_count=0
 end
 spr_tline_args:set(0, spr_tline_count, idx, x0, y0, x1, y1, u0, v0, u1, v1, w0 or 1, w1 or 1)
 spr_tline_count+=1
end
local function sbatch_submit()
 if spr_tline_count>0 then
  tline3d(spr_tline_args, 0, spr_tline_count, SPR_TLINE_COLS)
  spr_tline_count=0
 end
end

-- persistent depth buckets (0..15) reused each frame
sprite_buckets=sprite_buckets or {}
for i=0,7 do sprite_buckets[i]=sprite_buckets[i] or {} end
local function clear_buckets()
 for i=0,7 do
  local b=sprite_buckets[i]
  for j=#b,1,-1 do b[j]=nil end
 end
end

-- render sprites with z-buffer occlusion (flat array iteration with distance culling)
function render_sprites()
 -- use cached sin/cos from _draw() if available
 local sa,ca=sa_cached or sin(player.a),ca_cached or cos(player.a)
 
 -- frustum bounds check removed (distance-based culling in use)
 
 -- initialize depth buckets for sprite sorting
-- 8 total buckets: 0-7 for all sprites (upright and flat treated uniformly)
-- bucket size = far_plane / 8 (e.g., 25.0 / 8 = 3.125 units per bucket)
-- iterate all objects with distance culling (no spatial grid)
local bucket_size = far_plane / 8
 clear_buckets()
 
 -- iterate all objects with simple distance culling (no spatial grid)
 for ob in all(objects) do
  if ob and ob.pos and ob.typ then
   -- transform to view space
   local rx=ob.pos[1]-player.x
   local ry=ob.pos[2]-player.y
   
   -- simple distance culling using axis-aligned bound
   if abs(rx)>=far_plane or abs(ry)>=far_plane then
    goto skip_sprite
   end
   
   -- rotate to view-aligned coordinates (camera space)
   -- right = (-sin a, cos a), forward = (cos a, sin a)
   local x_cam = -sa*rx + ca*ry
   local z_cam =  ca*rx + sa*ry
   ob.rel[1]=x_cam
   ob.rel[2]=z_cam
   
   -- far-plane culling: skip sprites beyond far_plane
   if ob.rel[2]>far_plane then
    goto skip_sprite
   end
   
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
     if abs(ob.rel[1])-(t.w/2)<ob.rel[2]*(screen_center_x/sdist) then
      pass_frustum=true
     end
    end
   end
   
   if pass_frustum then
    -- compute bucket index based on depth
    -- bucket 0 = 0.0-6.25, bucket 1 = 6.25-12.5, ..., bucket 7 = 43.75-50.0+
    local bucket_idx = min(7, flr(ob.rel[2] / bucket_size))
    
    -- add to bucket
    add(sprite_buckets[bucket_idx], ob)
   end
   
   ::skip_sprite::
  end
 end
 
 -- draw sprites back-to-front using bucket iteration
-- bucket 7-0: farthest to nearest (bucket 7 = all sprites at far distance)
 palt(0,false)
 palt(14,true)
 
for bucket_idx=7,0,-1 do
  -- sort non-empty bucket by z descending (far to near) for correct sprite-sprite occlusion
  local bucket = sprite_buckets[bucket_idx]
 if #bucket > 4 then
   -- insertion sort by ob.rel[2] descending
   for i=2,#bucket do
    local ob = bucket[i]
    local z = ob.rel[2]
    local j = i - 1
    while j >= 1 and bucket[j].rel[2] < z do
     bucket[j+1] = bucket[j]
     j = j - 1
    end
    bucket[j+1] = ob
   end
  end
  
  for ob in all(bucket) do
   drawobj_single(ob, sa, ca)
  end
 end
 
 palt()
 clip()
end

-- draw single sprite object with z-buffer occlusion (color 0=opaque, color 14=transparent)
function drawobj_single(ob, sa, ca)
 if not ob or not ob.typ or not ob.rel then
  return
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
  
  -- LOD: impostor rendering for distant sprites
  local sprite_lod_distance=fog_far*sprite_lod_ratio
  if z>sprite_lod_distance then
   -- sample average color from sprite center (defaults to fog color 5)
   local avg_color=5
   if src and src.get then
    avg_color=src:get(16,16) or 5
   end
   
   -- apply fog uniformly
  -- fog disabled
   
   -- project to screen space
   local f_lod=sdist/z
   local sx_lod=x*f_lod+screen_center_x
   local w_lod=t.w*f_lod
   
   -- compute vertical span
   local y0_lod,y1_lod
   if t.flat then
    local z0=z+t.w/2
    local z1=z-t.w/2
    y0_lod=y*sdist/z0+screen_center_y
    y1_lod=y*sdist/z1+screen_center_y
   else
    local sy_lod=y*f_lod+screen_center_y
    local h_lod=t.h*f_lod
    y0_lod=sy_lod-h_lod/2
    y1_lod=sy_lod+h_lod/2
   end
   
   -- clamp to screen bounds
   local x0=max(0,ceil(sx_lod-w_lod/2))
   local x1=min(screen_width-1,flr(sx_lod+w_lod/2))
   y0_lod=max(0,ceil(y0_lod))
   y1_lod=min(screen_height-1,flr(y1_lod))
   
  -- draw solid impostor columns with z-test (batched rectfill)
   if y1_lod>y0_lod and x1>=x0 then
   rbatch_reset()
   for px=x0,x1 do
    local zb=(zread and zread(px)) or (zbuf.get and zbuf:get(px)) or 999
    if z<zb then
      rbatch_push(px,y0_lod,px,y1_lod,avg_color)
      if zwrite then
       zwrite(px, z)
      elseif zbuf.set then
       zbuf:set(px, z)
      end
    end
   end
   rbatch_submit()
   diag_sprite_impostor_columns+=max(0,x1-x0+1)
   end
   
   return
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
   return
  end
  
  -- set fog and palette
  if ob.pal then
   pal(ob.pal)
  else
   -- fog disabled
  end
  
  -- draw sprite column-by-column with z-buffer (no diagonal batching)
  local function resolve_sprite_index(idx, kind)
   if idx and get_spr(idx) then
    return idx
   end
   if ERROR_IDX then
    if kind=="sprite" then return ERROR_IDX.sprite else return ERROR_IDX.default end
   end
   return 0
  end
  local spr_idx=resolve_sprite_index(sprite_index,"sprite")
  sbatch_reset()
  for px=x0,x1 do
  local zb=(zread and zread(px)) or (zbuf.get and zbuf:get(px)) or 999
   if z<zb then
    local u=u0+(px-x0)*sxd
    sbatch_push(spr_idx, px, y0, px, y1, u, v0, u, v0+size, 1, 1)
    -- diagnostics removed for production
    if zwrite then
     zwrite(px, z)
    elseif zbuf.set then
     zbuf:set(px, z)
    end
   diag_sprite_columns+=1
   end
  end
  sbatch_submit()
  
  -- if a custom palette was applied, restore fog mapping for subsequent draws
  if ob.pal then
   -- fog state removed
  end
end
