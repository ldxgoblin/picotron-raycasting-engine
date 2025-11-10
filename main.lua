--[[pod_format="raw",created="2025-11-07 21:04:06",modified="2025-11-07 22:18:51",revision=5]]
-- nonboy raycast engine v1.0
-- main entry point

include"src/config.lua"
include"src/raycast.lua"
include"src/render.lua"
include"src/render_sprite.lua"
include"src/door_system.lua"
include"src/dungeon_gen.lua"

-- constants
player_collision_radius=0.15

function _init()
 window(screen_width,screen_height)
 
 -- pin masks to defaults for single colour-table fast path
 poke(0x5508,0x3f) poke(0x5509,0x3f) poke(0x550a,0x3f) poke(0x550b,0x00)
 
 -- tile 0 drawing state: verified not required; leave 0x5f36 at default (no explicit poke)
 -- sspr() usage verified: None in production code (only in sample files)
 -- Per Picotron guidelines: blit() is faster; HUD/minimap use direct drawing
 -- configuration guard: prevent fog popping beyond far-plane
 assert(far_plane>=fog_far+1,"config error: far_plane must be >= fog_far + 1")
 
 -- defensive defaults if config include failed to set them for any reason
 if not objgrid_size then objgrid_size=5 end
 if not objgrid_array_size then objgrid_array_size=26 end
 
 -- frame counter for ai timing
 frame_ct=0
 
 -- player state
 player={
  x=64,y=64,
  a=0,
  spd=player_move_speed,
  keys={},
  hp=100
 }
 
 -- interaction state
 interaction_active=false
 current_interact=nil
 
 -- combat state
 in_combat=false
 current_target=nil
 
 -- trap message timer
 trap_msg_timer=0
 
 -- camera
 cam={player.x,player.y}
 
 -- map abstraction with userdata layers
 map={}
 map.walls=userdata("i16",128,128)
 map.doors=userdata("i16",128,128)
 map.floors=userdata("i16",128,128)
 
 -- helper: get wall tile
-- Purpose: Retrieve wall tile ID at grid position
 -- Parameters: x, y (grid coordinates 0-127)
 -- Returns: tile ID (0=empty, >0=wall/door/exit)
 function get_wall(x,y)
 if x>=0 and x<128 and y>=0 and y<128 then
  return map.walls:get(x,y) or 0
 end
 return 0
 end
 
 -- helper: set wall tile
 function set_wall(x,y,val)
  if x>=0 and x<128 and y>=0 and y<128 then
		map.walls:set(x,y,val or 0)
  end
 end
 
 -- helper: get door tile
 function get_door(x,y)
  if x>=0 and x<128 and y>=0 and y<128 then
   return map.doors:get(x,y) or 0
  end
  return 0
 end
 
 -- helper: set door tile
 function set_door(x,y,val)
  if x>=0 and x<128 and y>=0 and y<128 then
   map.doors:set(x,y,val or 0)
  end
 end

 -- helper: get floor tile
 -- Purpose: Retrieve floor type ID at grid position
 -- Parameters: x, y (grid coordinates 0-127)
 -- Returns: floor type ID (0=use global default, 1-8=specific floor type from planetyps)
 -- Notes: Floor type IDs map to indices in the planetyps table defined in config.lua
 function get_floor(x,y)
  if x>=0 and x<128 and y>=0 and y<128 then
   return map.floors:get(x,y) or 0
  end
  return 0
 end

 -- helper: set floor tile
 -- Purpose: Store per-cell floor type IDs for varied floor textures
 -- Parameters: x, y (grid coordinates 0-127), val (floor type ID 0-8)
 -- Notes: 0=use global default floor type, 1-8=specific floor type from planetyps
 function set_floor(x,y,val)
  if x>=0 and x<128 and y>=0 and y<128 then
   -- normalize val to valid range 0-8
   if type(val)~="number" or val==nil then
    val=0
   elseif val<0 then
    val=0
   elseif val>8 then
    val=8
   end
   map.floors:set(x,y,val)
  end
 end
 
 doorgrid={}
 for i=0,127 do
  doorgrid[i]={}
  for j=0,127 do
   doorgrid[i][j]=nil
  end
 end
 
 -- initialize floor data
 for i=0,127 do
  for j=0,127 do
   set_floor(i,j,0)
  end
 end
  
 doors={}
 objects={}
 animated_objects={}
 
-- z-buffer and frame-stamp as typed userdata for speed
-- zbuf: per-column depth values (one z per screen x); zstamp: frame-stamp to avoid per-frame clears
 zbuf=userdata("f64", screen_width)
 zstamp=userdata("i32", screen_width)
 for i=0,screen_width-1 do
  -- initialize stamps to 0; z values are considered invalid until stamped
  zstamp:set(i, 0)
 end
 
 -- dynamic budgets
 active_ray_count=ray_count
 row_stride_dynamic=row_stride
 
 -- Convert to userdata for 24x performance gain (Picotron optimization guideline)
 ray_z = userdata("f64", ray_count)
 ray_x0 = userdata("i16", ray_count)
 ray_x1 = userdata("i16", ray_count)
 ray_dx = userdata("f64", ray_count)
 ray_dy = userdata("f64", ray_count)
 
 -- Precomputed pixel centers for camera-space ray offsets (eliminates per-frame computation)
 ray_px_center = userdata("f64", ray_count)
 
 -- Initialize with defaults
 for i=0,ray_count-1 do
   ray_z:set(i, 999)
   ray_x0:set(i, 0)
   ray_x1:set(i, 0)
   ray_dx:set(i, 0)
   ray_dy:set(i, 0)
 end
 
 -- rbuf: use separate userdata arrays for tile and tx (avoid nested structures)
 rbuf_tile = userdata("i16", ray_count)
 rbuf_tx = userdata("f64", ray_count)
 for i=0,ray_count-1 do
   rbuf_tile:set(i, 0)
   rbuf_tx:set(i, 0)
 end
 
 -- fog state for hysteresis
 last_fog_z=0
 
 -- projection constant defined in config.lua
 
 -- floor and roof state
 floor={typ=planetyps[1],x=0,y=0}
 roof={typ=planetyps[3],x=0,y=0}
 
 -- generate dungeon
 start_pos,gen_stats=generate_dungeon()
 
 -- mode: 3d or 2d map
 view_mode="3d" -- or "2d" for minimap
 
 -- debug mode for ray casting
 debug_mode=false
show_diagnostics=false
enable_diagnostics_logging=false  -- Permanently disabled for production performance
-- Optional: re-enable a non-render CPU governor (samples CPU outside _draw())
enable_nonrender_governor=false
recent_cpu=0
 
 -- performance validation mode: disables CPU governor to stabilize measurements
 perf_validation=false
 
 -- diagnostic counters for performance tracking
 diag_dda_steps_total=0
 diag_dda_early_outs=0
 diag_fog_switches=0
 diag_wall_tline_submits=0
 diag_wall_samples=0
 diag_wall_pixels=0
 diag_floor_rows=0
 diag_floor_draw_calls=0
 diag_sprite_columns=0
 diag_frame_count=0
 
 -- test door mode
 test_door_mode=false

 -- create tinted error textures for different object types (checkerboard pattern)
 -- walls: magenta/pink (8/14), floor: blue/cyan (12/13), ceiling: green/dark green (11/3)
 -- sprites: yellow/orange (10/9), props: red/brown (8/4)
 error_textures = {
  wall = userdata("u8", 32, 32),
 door = userdata("u8", 32, 32),
  floor = userdata("u8", 32, 32),
  ceiling = userdata("u8", 32, 32),
  sprite = userdata("u8", 32, 32),
  default = userdata("u8", 32, 32)
 }
 
 -- generate tinted checkerboards for each type
 local tints = {
  wall = {8, 14},      -- magenta/pink
 door = {2, 6},       -- purple/blue (distinct from walls)
  floor = {12, 13},    -- blue/cyan
  ceiling = {11, 3},   -- green/dark green
  sprite = {10, 9},    -- yellow/orange
  default = {8, 14}    -- magenta/pink (fallback)
 }
 
 for type_name, colors in pairs(tints) do
  for y=0,31 do
   for x=0,31 do
    local color = ((flr(x/4) + flr(y/4)) % 2 == 0) and colors[1] or colors[2]
    error_textures[type_name]:set(x, y, color)
   end
  end
 end
 
 -- maintain backward compatibility with single error_texture
 error_texture = error_textures.default

 -- reserve sprite indexes for error textures (batching prefers sprite indexes)
 ERROR_IDX = { wall=8000, door=8001, floor=8002, ceiling=8003, sprite=8004, default=8005 }
 for name, ud in pairs(error_textures) do
  local idx = ERROR_IDX[name] or ERROR_IDX.default
  set_spr(idx, ud)
 end
 
 -- Preload texture cache for commonly-used sprites (0-200)
 -- Populate tex_cache directly using get_spr() to avoid warnings
 printh("preloading texture cache...")
 local preload_start = time()
 for i=0,200 do
  local src=get_spr and get_spr(i)
  if src and cache_tex then
   cache_tex(i, src, false)
  end
 end
 local preload_time = (time() - preload_start) * 1000
 printh("texture cache preloaded: "..preload_time.."ms")
 -- Trigger GC after preloading (Picotron guideline: stat(0) during pauses only)
 stat(0)
 
 -- logging helper: console + ring buffer for optional on-screen echo
 log_lines = {}
 function log(str)
  printh(str)
  add(log_lines, str)
  if #log_lines > 200 then deli(log_lines, 1) end
 end

 -- validate all configured sprites exist (comment out for production)
 validate_sprite_configuration()

 printh("picotron raycast engine v1.0")
end

-- validate sprite configuration at startup (optional, can be disabled for performance)
function validate_sprite_configuration()
 -- check enemy sprites
 for enemy in all(enemy_types) do
  if not get_spr(enemy.sprite) then
   printh("WARNING: enemy sprite "..enemy.sprite.." ("..enemy.name..") not found in GFX files")
  end
 end
 
 -- check decoration sprites
 for dec in all(decoration_types) do
  if not get_spr(dec.sprite) then
   printh("WARNING: decoration sprite "..dec.sprite.." ("..dec.name..") not found in GFX files")
  end
 end
 
 -- check wall texture sprites
 for texset in all(texsets) do
  for variant in all(texset.variants) do
   if not get_spr(variant) then
    printh("WARNING: wall texture sprite "..variant.." not found in GFX files")
   end
  end
 end
 
 -- check floor/ceiling sprites
 for typ in all(planetyps) do
  if not get_spr(typ.tex) then
   printh("WARNING: floor/ceiling sprite "..typ.tex.." not found in GFX files")
  end
 end
end

function _update()
 -- increment frame counter
 frame_ct+=1
 
 -- optional: sample CPU outside render frame (every 30 frames) for non-render governor
 if enable_nonrender_governor and (frame_ct%30==0) then
  recent_cpu=stat(1) or 0
 end
 
 -- combat gating: skip normal updates when in combat
 if in_combat then
  update_combat()
  return
 end
 
 update_input()
 update_doors()
 
 -- update npc ai (rate limited, deterministic frame check)
 if frame_ct%ai_update_rate==0 then
  update_npc_ai()
 end
 
 cam={player.x,player.y}
 
 -- update floor/ceiling scrolling
 floor.x+=floor.typ.xvel or 0
 floor.y+=floor.typ.yvel or 0
 roof.x+=roof.typ.xvel or 0
 roof.y+=roof.typ.yvel or 0
 
 -- update object animations
 for ob in all(animated_objects) do
  if ob.typ and ob.typ.framect then
   ob.frame+=ob.typ.animspd
   if ob.animloop then
    ob.frame=ob.frame%ob.typ.framect
   else
    ob.frame=min(ob.frame,ob.typ.framect-1)
   end
  end
 end
 
 -- toggle view mode (debug only)
 if debug_mode and (keyp("x") or btnp(5)) then
  view_mode=view_mode=="3d" and "2d" or "3d"
 end
 
 -- debug mode toggle (moved from btnp(4) to avoid conflict)
 if keyp("tab") then
  debug_mode=not debug_mode
 end
 
 -- diagnostics overlay removed; merged into debug panel (Tab)
 
 -- toggle diagnostics logging (controller button 12)
 if btnp(12) then
  enable_diagnostics_logging=not enable_diagnostics_logging
  printh("Diagnostics logging: "..tostring(enable_diagnostics_logging))
 end
 
 -- decrement trap message timer
 if trap_msg_timer>0 then
  trap_msg_timer-=1
 end
 
 -- toggle test door mode (when not in 2d map view)
 if view_mode=="3d" and (keyp("v") or btnp(15)) then
  test_door_mode=not test_door_mode
 end
 
 -- cycle test door open value (0.0 to 1.0)
 if test_door_mode then
  if keyp("c") then
   test_door_open=(test_door_open or 0)+0.1
   if test_door_open>1 then test_door_open=0 end
  end
  if keyp("d") then
   test_door_open=(test_door_open or 0)-0.1
   if test_door_open<0 then test_door_open=1 end
  end
 end
 
 -- cycle floor type (for testing) when not in door test mode
 if not test_door_mode and keyp("c") then
  local current_idx=1
  for i=1,#planetyps do
   if planetyps[i].tex==floor.typ.tex then
    current_idx=i
    break
   end
  end
  floor.typ=planetyps[(current_idx % #planetyps)+1]
  floor.x,floor.y=0,0
  -- Test mode: clear cache when cycling floor types (can be disabled in production)
  if clear_texture_caches then clear_texture_caches() end
 end
 
 -- cycle roof type (for testing) when not in door test mode
 if not test_door_mode and keyp("d") then
  local current_idx=1
  for i=1,#planetyps do
   if planetyps[i].tex==roof.typ.tex then
    current_idx=i
    break
   end
  end
  roof.typ=planetyps[(current_idx % #planetyps)+1]
  roof.x,roof.y=0,0
  -- Test mode: clear cache when cycling roof types (can be disabled in production)
  if clear_texture_caches then clear_texture_caches() end
 end
 
 -- debug ray casting
  if debug_mode then
   local sa,ca=sin(player.a),cos(player.a)
   local z,hx,hy,tile,tx=raycast(player.x,player.y,ca,sa,sa,ca)
   printh("debug: z="..(flr(z*100)/100).." hx="..(flr(hx*100)/100).." hy="..(flr(hy*100)/100).." tile="..tile.." tx="..(flr(tx*100)/100))
   local ob,dist=hitscan(player.x,player.y,ca,sa)
   if ob then
    printh("debug: obj found at dist="..(flr(dist*100)/100).." kind="..(ob.kind or "unknown"))
   else
    printh("debug: no obj hit")
   end
  end
end

function _draw()
 clip(0,0,screen_width,screen_height)
 cls(0)
 
 local frame_start=time()
 
 diag_frame_count+=1
 
-- Ensure adaptive controls are initialized once
if not active_ray_count then active_ray_count=ray_count end
if not row_stride_dynamic then row_stride_dynamic=row_stride end

local function adjust_ray_budget(cpu_sample)
 local min_rays=max(48, flr(ray_count*0.25))
 if cpu_sample>0.90 then
  active_ray_count=max(min_rays, active_ray_count-16)
 elseif cpu_sample<0.70 then
  active_ray_count=min(ray_count, active_ray_count+8)
 end
end

-- Lightweight CPU sampler in _draw() (every 60 frames) for adaptive quality
if not perf_validation and (diag_frame_count % 60 == 0) then
 local cpu = stat(1) or 0
 if not enable_nonrender_governor then
  adjust_ray_budget(cpu)
 end
end

-- Optional non-render governor: uses CPU sampled in _update(), never calls stat(1) here
if enable_nonrender_governor then
 adjust_ray_budget(recent_cpu or 0)
end
 
 -- z-buffer helpers (use frame-stamp, defined once)
 if not zread then
  function zread(x)
   -- x is 0-based; return 999 unless stamped this frame
   local stamp=zstamp:get(x) or 0
   if stamp==diag_frame_count then
    local z=zbuf:get(x)
    return z or 999
   end
   return 999
  end
  function zwrite(x,z)
   zbuf:set(x,z)
   zstamp:set(x,diag_frame_count)
  end
 end
 
 -- cache sin/cos for entire frame to avoid recomputation
 sa_cached=sin(player.a)
 ca_cached=cos(player.a)
 
 if view_mode=="3d" then
  raycast_scene()
  local t_raycast=time()
  render_floor_ceiling()  -- Now includes wall rendering
  local t_floor_walls=time()
  render_sprites()
  local t_sprites=time()
  
  local ms_raycast=(t_raycast-frame_start)*1000
  local ms_floor_walls=(t_floor_walls-t_raycast)*1000
  local ms_sprites=(t_sprites-t_floor_walls)*1000
  local frame_ms=(t_sprites-frame_start)*1000
  
  -- hud
  print("pos:"..flr(player.x)..","..flr(player.y),2,2,7)
  print("ang:"..(flr(player.a*100)/100),2,10,7)
  print("fps:"..stat(7),2,18,7)
  print("hp:"..player.hp,2,26,7)
  local frame_ms_col=(frame_ms<32 and 11) or (frame_ms<40 and 10) or 8
  print("frame_ms:"..(flr(frame_ms*10)/10).."ms",2,42,frame_ms_col)
  if debug_mode then
   print("raycast:"..(flr(ms_raycast*10)/10).."ms",2,50,7)
   print("floor+walls:"..(flr(ms_floor_walls*10)/10).."ms",2,58,7)
   print("sprites:"..(flr(ms_sprites*10)/10).."ms",2,66,7)
   print("[x] toggle map",2,34,7)
  end
  
  -- interaction prompt
  if interaction_active and current_interact then
   print("[E]/Z: interact",screen_center_x-40,screen_height-20,11)
  end
  
  -- trap message
  if trap_msg_timer>0 then
   print("trap sprung!",screen_center_x-30,screen_center_y,8)
  end
  
 --[[ DEBUG PANEL REMOVED FOR PRODUCTION PERFORMANCE
 if debug_mode then
  -- removed
 end
 ]]
  
 --[[ PERIODIC LOGGING REMOVED FOR PRODUCTION PERFORMANCE
 if enable_diagnostics_logging and diag_frame_count%60==0 then
  -- removed
 end
 ]]
  
  -- minimap HUD overlay
  draw_minimap_hud()
 else
  draw_minimap()
 end
 
 -- combat overlay
 if in_combat then
  rectfill(0,screen_height-40,screen_width,screen_height,0)
  print("entering combat...",screen_center_x-40,screen_center_y,8)
  print("[enter] exit (temp)",screen_center_x-40,screen_center_y+10,7)
 end
 
 -- restore palette from fog remapping (single restore per frame)
 pal()
 -- reset fog state so first set_fog applies mapping next frame
 last_fog_level=-1
 prev_pal={}
end

-- draw 2d minimap for testing
-- Purpose: Render 2D top-down debug view of dungeon
-- Algorithm: Scale 128×128 map to 256×256 pixels (scale=2)
-- Displays: Walls, rooms, doors, objects, player position and facing
-- Notes: Toggled with X button, useful for debugging generation
function draw_minimap()
 local scale=2
 local ox,oy=10,10
 
 -- batch all tile drawing to reduce draw call count
 rbatch_reset()
 
 -- draw walls from map.walls userdata with floor data to distinguish corridors from void
 for x=0,127 do
  for y=0,127 do
   local wall=get_wall(x,y)
   local floor_val=get_floor(x,y)
   local color
   if wall>0 then
    -- wall tile
    color=5
   elseif floor_val>0 then
    -- carved corridor/room floor (floor type set during generation)
    color=6
   else
    -- uncarved void (wall=0, floor=0)
    color=1
   end
   rbatch_push(ox+x*scale,oy+y*scale,ox+x*scale+scale-1,oy+y*scale+scale-1,color)
  end
 end
 
 rbatch_submit()
 
 -- draw rooms
 for node in all(gen_nodes) do
  local r=node.rect
  rect(ox+r[1]*scale,oy+r[2]*scale,ox+r[3]*scale,oy+r[4]*scale,11)
 end
 
 -- batch door drawing
 rbatch_reset()
 for door in all(doors) do
  local c=door.dtype==door_locked and 8 or 12
  rbatch_push(ox+door.x*scale,oy+door.y*scale,ox+door.x*scale+scale-1,oy+door.y*scale+scale-1,c)
 end
 rbatch_submit()
 
 -- draw objects
 for ob in all(objects) do
  local c=7
  if ob.typ and ob.typ.kind=="hostile_npc" then c=8
  elseif ob.typ and ob.typ.kind=="direct_pickup" then
   if ob.typ.subtype=="heart" then c=14
   elseif ob.typ.subtype=="key" then c=9
   end
  elseif ob.typ and ob.typ.kind=="interactable" then
   if ob.typ.subtype=="exit" then c=12 end
  elseif ob.typ and ob.typ.kind=="decorative" then c=13
  end
  local x=ob.pos[1]
  local y=ob.pos[2]
  circfill(ox+x*scale,oy+y*scale,1,c)
 end
 
 -- draw player
 local px,py=ox+player.x*scale,oy+player.y*scale
 circfill(px,py,2,10)
 local sa,ca=sin(player.a),cos(player.a)
 line(px,py,px+ca*6,py+sa*6,10)
 
 -- stats
 print("2d map view",10,2,7)
 print("rooms: "..gen_stats.rooms,10,10,7)
 print("objects: "..gen_stats.objects,10,18,7)
 print("seed: "..gen_stats.seed,10,26,7)
 if debug_mode then
  print("[x] toggle 3d",10,34,7)
 end
end

-- draw hud minimap overlay
-- Purpose: Render scrolling viewport minimap in top-right corner during 3D view
-- Algorithm: Player-centered camera with clipped drawing of visible tiles only
-- Displays: Walls, floors, doors, objects, player (auto-scrolls as player moves)
-- Notes: Fixed 120×68px viewport at top-right, scale=2, only draws visible tile range
function draw_minimap_hud()
 local hud_w=ceil(screen_width*0.25)
 local hud_h=ceil(screen_height*0.25)
 local hud_x=screen_width-hud_w-8
 local hud_y=8
 local scale=2
 
 -- camera offset to center player in viewport
 local cam_x=player.x*scale-hud_w/2
 local cam_y=player.y*scale-hud_h/2
 
 -- calculate visible tile range
 local x_min=max(0,flr(cam_x/scale))
 local x_max=min(127,flr((cam_x+hud_w)/scale))
 local y_min=max(0,flr(cam_y/scale))
 local y_max=min(127,flr((cam_y+hud_h)/scale))
 
 -- set clip region
 clip(hud_x,hud_y,hud_w,hud_h)
 
 -- draw background
 rectfill(hud_x,hud_y,hud_x+hud_w-1,hud_y+hud_h-1,0)
 
 -- batch map tiles (only visible range)
 rbatch_reset()
 for x=x_min,x_max do
  for y=y_min,y_max do
   local sx=hud_x+(x*scale-cam_x)
   local sy=hud_y+(y*scale-cam_y)
   
   -- additional bounds check
   if sx>=hud_x and sx<hud_x+hud_w and sy>=hud_y and sy<hud_y+hud_h then
    local wall=get_wall(x,y)
    local floor_val=get_floor(x,y)
    local color
    
    if wall>0 then
     color=5
    elseif floor_val>0 then
     color=6
    else
     color=1
    end
    
    rbatch_push(sx,sy,sx+scale-1,sy+scale-1,color)
   end
  end
 end
 rbatch_submit()
 
 -- batch door drawing via spatial query over visible tiles
 rbatch_reset()
 for x=x_min,x_max do
  for y=y_min,y_max do
   local door=doorgrid[x] and doorgrid[x][y] or nil
   if door then
    local sx=hud_x+(x*scale-cam_x)
    local sy=hud_y+(y*scale-cam_y)
    if sx>=hud_x and sx<hud_x+hud_w and sy>=hud_y and sy<hud_y+hud_h then
     local c=door.dtype==door_locked and 8 or 12
     rbatch_push(sx,sy,sx+scale-1,sy+scale-1,c)
    end
   end
  end
 end
 rbatch_submit()
 
 -- draw objects via flat array iteration within viewport bounds
 for ob in all(objects) do
  if ob.pos then
   local sx=hud_x+(ob.pos[1]*scale-cam_x)
   local sy=hud_y+(ob.pos[2]*scale-cam_y)
   if sx>=hud_x and sx<hud_x+hud_w and sy>=hud_y and sy<hud_y+hud_h then
    local c=7
    if ob.typ and ob.typ.kind=="hostile_npc" then c=8
    elseif ob.typ and ob.typ.kind=="direct_pickup" then
     if ob.typ.subtype=="heart" then c=14
     elseif ob.typ.subtype=="key" then c=9
     end
    elseif ob.typ and ob.typ.kind=="interactable" then
     if ob.typ.subtype=="exit" then c=12 end
    elseif ob.typ and ob.typ.kind=="decorative" then c=13
    end
    circfill(sx,sy,1,c)
   end
  end
 end
 
 -- draw player (always centered by camera design)
 local px=hud_x+(player.x*scale-cam_x)
 local py=hud_y+(player.y*scale-cam_y)
 circfill(px,py,2,10)
 line(px,py,px+ca_cached*6,py+sa_cached*6,10)
 
 -- optional frame
 rect(hud_x,hud_y,hud_x+hud_w-1,hud_y+hud_h-1,7)
 
 -- reset clip
 clip()
end

-- unified collision check for walls, doors, and objects
-- Purpose: Unified collision detection for walls, doors, and objects
-- Parameters: px, py (world position), radius (collision radius), opendoors (auto-open doors), isplayer (enable key checking)
-- Returns: boolean (true if collision detected)
-- Algorithm: Grid-based wall check + spatial partitioning for objects
-- Side effects: Opens doors, prevents door closing when player inside
function iscol(px,py,radius,opendoors,isplayer)
 local col=false
 opendoors=opendoors or false
 isplayer=isplayer or false
 
 -- check grid cells around position
 for x=flr(px-radius),flr(px+radius) do
  for y=flr(py-radius),flr(py+radius) do
   -- bounds check
   if x<0 or x>=128 or y<0 or y>=128 then
    col=true
    break
   else
    local tile=get_wall(x,y)
    
    -- check if door tile
    if tile==door_normal or tile==door_locked or tile==door_stay_open then
     local door=doorgrid[x][y]
     if door then
      if door.open==1 then
       -- fully open: prevent closing
       door.opening=true
      else
       -- door partially open or closed: collision detected
       col=true
       -- handle unlocking/opening before exiting inner loop
       if opendoors then
        if door.keynum then
         -- check inventory for key
         if isplayer then
          for i,item in ipairs(player.keys) do
           if item.keynum==door.keynum then
            -- remove key
            deli(player.keys,i)
            door.keynum=nil
            door.opening=true
            -- keep col=true, don't clear immediately
            break
           end
          end
         end
        else
         -- unlocked
         door.opening=true
         -- keep col=true, don't clear immediately
        end
       end
       -- early exit from inner loop on collision (after opendoors handling)
       break
      end
     end
    -- check if exit portal
    elseif (tile==exit_start or tile==exit_end) and isplayer then
     -- placeholder for level completion
    -- check if wall
    elseif tile>0 then
     col=true
     break
    end
   end
  end
  if col then break end
 end
 
 -- check solid objects around position via flat array with early distance cull
 for ob in all(objects) do
  if ob.typ and ob.typ.solid and ob.pos then
   local ox=ob.pos[1]-px
   local oy=ob.pos[2]-py
   -- early axis-aligned cull
   if abs(ox)<(radius+(ob.typ.w or 0)) and abs(oy)<(radius+(ob.typ.w or 0)) then
    if max(abs(ox),abs(oy))<(ob.typ.w or 0) then
     col=true
     -- trigger interaction on solid contact if player
     if isplayer then
      check_interactions_at(px,py)
     end
     break
    end
   end
  end
 end
 
 return col
end

-- movement wrapper with sliding collision
-- Purpose: Movement with sliding collision (try diagonal, then X, then Y)
-- Parameters: pos (table with x,y), target_x, target_y, radius, opendoors, isplayer
-- Returns: boolean (true if any movement succeeded)
-- Algorithm: Three-phase collision check for smooth wall sliding
function trymoveto(pos,target_x,target_y,radius,opendoors,isplayer)
 radius=radius or player_collision_radius
 opendoors=opendoors or false
 isplayer=isplayer or false
 
 -- try direct movement
 if not radius or not iscol(target_x,target_y,radius,opendoors,isplayer) then
  pos.x,pos.y=target_x,target_y
  return true
 end
 
 -- try x-only movement
 if abs(pos.x-target_x)>0.01 and not iscol(target_x,pos.y,radius,opendoors,isplayer) then
  pos.x=target_x
  return true
 end
 
 -- try y-only movement
 if abs(pos.y-target_y)>0.01 and not iscol(pos.x,target_y,radius,opendoors,isplayer) then
  pos.y=target_y
  return true
 end
 
 return false
end

-- movement wrapper for pos[1]/pos[2] array positions
function trymoveto_pos(pos_array,target_x,target_y,radius,opendoors,isplayer)
 radius=radius or player_collision_radius
 opendoors=opendoors or false
 isplayer=isplayer or false
 
 -- try direct movement
 if not radius or not iscol(target_x,target_y,radius,opendoors,isplayer) then
  pos_array[1],pos_array[2]=target_x,target_y
  return true
 end
 
 -- try x-only movement
 if abs(pos_array[1]-target_x)>0.01 and not iscol(target_x,pos_array[2],radius,opendoors,isplayer) then
  pos_array[1]=target_x
  return true
 end
 
 -- try y-only movement
 if abs(pos_array[2]-target_y)>0.01 and not iscol(pos_array[1],target_y,radius,opendoors,isplayer) then
  pos_array[2]=target_y
  return true
 end
 
 return false
end

function update_input()
 local sa,ca=sin(player.a),cos(player.a)
 
 -- movement
 -- combine keys to avoid double-processing and fix direction:
 -- positive turn = left, negative turn = right
 local turn=(btn(0) and 1 or 0)-(btn(1) and 1 or 0)
 if turn~=0 then
  player.a+=turn*player_rotation_speed
 end
 if btn(2) then -- up
  local nx=player.x+ca*player.spd
  local ny=player.y+sa*player.spd
  trymoveto(player,nx,ny,player_collision_radius,true,true)
 end
 if btn(3) then -- down
  local nx=player.x-ca*player.spd
  local ny=player.y-sa*player.spd
  trymoveto(player,nx,ny,player_collision_radius,true,true)
 end
 
 -- check for interactions every frame
 check_interactions()
 
 -- interaction input: E key or Z button
 if keyp("e") or btnp(4) then
  handle_interact()
 end
end

 

-- check interactions around player position
-- Purpose: Scan nearby objects for proximity-based interactions
-- Algorithm: 3×3 objgrid cell scan around player
-- Side effects: Auto-collects pickups, triggers combat, sets interaction flags
-- Notes: Called every frame in _update()
function check_interactions()
 check_interactions_at(player.x,player.y)
end

-- check interactions at specific position (avoids recursion)
function check_interactions_at(px,py)
 -- scan all objects with distance culling
 local closest_interact=nil
 local closest_dist=999
 
 for ob in all(objects) do
  if ob.pos and ob.typ then
   local dx=ob.pos[1]-px
   local dy=ob.pos[2]-py
   local dist=abs(dx)+abs(dy)
   
   -- direct pickup: auto-collect
   if ob.typ.kind=="direct_pickup" and dist<interaction_range then
    collect_item(ob)
    del(objects,ob)
    if ob.autoanim then del(animated_objects,ob) end
   
   -- hostile npc: trigger combat
   elseif ob.typ.kind=="hostile_npc" and dist<combat_trigger_range then
    in_combat=true
    current_target=ob
   
   -- interactable: set flag for closest
   elseif ob.typ.kind=="interactable" and dist<interaction_range then
    -- trap: immediate effect
    if ob.typ.subtype=="trap" then
     player.hp=max(0,player.hp-10)
     trap_msg_timer=60
     del(objects,ob)
     if ob.autoanim then del(animated_objects,ob) end
    elseif dist<closest_dist then
     closest_interact=ob
     closest_dist=dist
    end
   end
  end
 end
 
 -- update interaction state
 if closest_interact then
  interaction_active=true
  current_interact=closest_interact
 else
  interaction_active=false
  current_interact=nil
 end
end

-- collect item (pickup)
-- Purpose: Handle pickup collection and inventory updates
-- Parameters: ob (object with typ.subtype)
-- Side effects: Adds to player.keys, increases player.hp
-- Notes: Called by check_interactions_at() for direct_pickup objects
function collect_item(ob)
 if ob.typ.subtype=="key" and ob.keynum then
  add(player.keys,{keynum=ob.keynum})
  printh("collected key "..ob.keynum)
 elseif ob.typ.subtype=="heart" then
  player.hp=min(100,player.hp+20)
  printh("collected heart")
 else
  printh("collected item")
 end
end

-- handle interaction when player presses E/Z
-- Purpose: Process player-initiated interactions (E key / Z button)
-- Algorithm: Switch on current_interact.typ.subtype
-- Side effects: Opens chests, activates shrines, reads notes, triggers floor transition
-- Notes: Only runs when interaction_active flag is true
function handle_interact()
 if not interaction_active or not current_interact then return end
 
 local subtype=current_interact.typ and current_interact.typ.subtype or "unknown"
 
 if subtype=="chest" then
  -- open chest (placeholder)
  player.hp=min(100,player.hp+10)
  printh("opened chest")
  del(objects,current_interact)
  if current_interact.autoanim then del(animated_objects,current_interact) end
  
 elseif subtype=="shrine" then
  -- activate shrine (placeholder)
  player.hp=100
  printh("activated shrine")
  
 elseif subtype=="note" then
  -- read note (placeholder)
  printh("read note")
  del(objects,current_interact)
  if current_interact.autoanim then del(animated_objects,current_interact) end
  
 elseif subtype=="exit" then
  -- trigger next floor
  printh("using exit portal")
  generate_new_floor()
  
 end
 
 -- clear interaction state after handling
 interaction_active=false
 current_interact=nil
end

-- generate new floor (regenerate dungeon)
function generate_new_floor()
 -- increment difficulty
 gen_params.difficulty=min(gen_params.max_difficulty,gen_params.difficulty+1)
 
 -- clear existing objects
 objects={}
 animated_objects={}
 doors={}
 -- also clear doorgrid to prevent stale references
 for i=0,127 do
  if doorgrid[i] then
   for j=0,127 do
    doorgrid[i][j]=nil
   end
  end
 end
 
 -- regenerate dungeon
 start_pos,gen_stats=generate_dungeon()
-- Trigger GC after dungeon generation (Picotron guideline: avoid mid-gameplay stutter)
stat(0)
 -- invalidate persistent render caches for new floor
-- Production: clear cache on level load to prevent stale texture references
if clear_texture_caches then clear_texture_caches() end
 
 printh("floor complete! difficulty: "..gen_params.difficulty)
 
 -- level load diagnostic summary
 printh("=== LEVEL LOAD DIAGNOSTICS ===")
 printh("Floor: "..(current_floor or "unknown"))
 printh("Difficulty: "..gen_params.difficulty)
 printh("Rooms: "..gen_stats.rooms)
 printh("Objects: "..gen_stats.objects)
 printh("Seed: "..gen_stats.seed)
end

-- update combat (placeholder)
function update_combat()
 -- temp exit: press Q or Enter
 if keyp("q") or keyp("enter") then
  in_combat=false
  current_target=nil
  printh("exited combat")
 end
end

-- update npc ai (basic patrol and follow)
function update_npc_ai()
 for ob in all(objects) do
  if ob.typ and ob.typ.kind=="hostile_npc" and ob.ai_type then
   local old_x,old_y=ob.pos[1],ob.pos[2]
   
   if ob.ai_type=="patrol" then
    -- patrol: cycle through patrol_points
    if ob.patrol_points and #ob.patrol_points>0 then
     -- initialize patrol_index if nil or 0
     if not ob.patrol_index or ob.patrol_index==0 then
      ob.patrol_index=1
     end
     
     local target=ob.patrol_points[ob.patrol_index]
     if target then
      local dx=target.x-ob.pos[1]
      local dy=target.y-ob.pos[2]
      local dist=sqrt(dx*dx+dy*dy)
      
      -- reached waypoint: advance to next
      if dist<0.1 then
       ob.patrol_index=(ob.patrol_index%#ob.patrol_points)+1
      else
       -- move toward current waypoint
       if dist>0 then
        local spd=ob.typ.patrol_speed or 0.03
        local nx=ob.pos[1]+dx/dist*spd
        local ny=ob.pos[2]+dy/dist*spd
        trymoveto_pos(ob.pos,nx,ny,ob.typ.w or 0.4,false,false)
       end
      end
     end
    end
    
   elseif ob.ai_type=="follow" then
    -- follow: move toward player if in range
    local dx=player.x-ob.pos[1]
    local dy=player.y-ob.pos[2]
    local dist=sqrt(dx*dx+dy*dy)
    local follow_range=ob.typ.follow_range or 20
    if dist<follow_range and dist>0.1 then
     local spd=ob.typ.follow_speed or 0.05
     local nx=ob.pos[1]+dx/dist*spd
     local ny=ob.pos[2]+dy/dist*spd
     trymoveto_pos(ob.pos,nx,ny,ob.typ.w or 0.4,false,false)
    end
   end
  end
 end
end