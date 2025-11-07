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
 
 -- helper: get wall tile
 -- Purpose: Retrieve wall tile ID at grid position with fallback
 -- Parameters: x, y (grid coordinates 0-127)
 -- Returns: tile ID (0=empty, >0=wall/door/exit)
 -- Notes: Checks userdata first, falls back to wallgrid table for compatibility
 function get_wall(x,y)
  if x>=0 and x<128 and y>=0 and y<128 then
   local val=map.walls:get(x,y)
   if val and val>0 then return val end
   -- defensive fallback: check wallgrid if map.walls is nil or 0
   if wallgrid and wallgrid[x] and wallgrid[x][y]>0 then
    return wallgrid[x][y]
   end
   return 0
  end
  return 0
 end
 
 -- helper: set wall tile
 function set_wall(x,y,val)
  if x>=0 and x<128 and y>=0 and y<128 then
		map.walls:set(x,y,val or 0)
		-- keep Lua mirror in sync for systems still reading wallgrid (e.g., minimap)
		if wallgrid and wallgrid[x] then wallgrid[x][y]=val or 0 end
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
 
 -- compatibility layer: expose wallgrid as table for dungeon generator
 wallgrid={}
 doorgrid={}
 for i=0,127 do
  wallgrid[i]={}
  doorgrid[i]={}
  for j=0,127 do
   wallgrid[i][j]=0
   doorgrid[i][j]=nil
  end
 end
  
 doors={}
 objects={}
 animated_objects={}
 objgrid={}
 for gx=0,objgrid_array_size do
  objgrid[gx+1]={}
  for gy=0,objgrid_array_size do
   objgrid[gx+1][gy+1]={}
  end
 end
 zbuf={}
 tbuf={}
 for i=1,ray_count do
  zbuf[i]=999
  tbuf[i]={tile=0,tx=0}
 end
 
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
 
 -- test door mode
 test_door_mode=false

 printh("picotron raycast engine v1.0")
end

function _update()
 -- increment frame counter
 frame_ct+=1
 
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
 
 -- toggle view mode
 if btnp(5) then -- x key
  view_mode=view_mode=="3d" and "2d" or "3d"
 end
 
 -- debug mode toggle (moved from btnp(4) to avoid conflict)
 if keyp("tab") then
  debug_mode=not debug_mode
 end
 
 -- decrement trap message timer
 if trap_msg_timer>0 then
  trap_msg_timer-=1
 end
 
 -- toggle test door mode (when not in 2d map view)
 if view_mode=="3d" and btnp(8) then -- v key for door test mode
  test_door_mode=not test_door_mode
 end
 
 -- cycle test door open value (0.0 to 1.0)
 if test_door_mode then
  if btnp(6) then -- c key: increase
   test_door_open=(test_door_open or 0)+0.1
   if test_door_open>1 then test_door_open=0 end
  end
  if btnp(7) then -- d key: decrease
   test_door_open=(test_door_open or 0)-0.1
   if test_door_open<0 then test_door_open=1 end
  end
 end
 
 -- cycle floor type (for testing) when not in door test mode
 if not test_door_mode and btnp(6) then -- c key
  local current_idx=1
  for i=1,#planetyps do
   if planetyps[i].tex==floor.typ.tex then
    current_idx=i
    break
   end
  end
  floor.typ=planetyps[(current_idx % #planetyps)+1]
  floor.x,floor.y=0,0
 end
 
 -- cycle roof type (for testing) when not in door test mode
 if not test_door_mode and btnp(7) then -- d key
  local current_idx=1
  for i=1,#planetyps do
   if planetyps[i].tex==roof.typ.tex then
    current_idx=i
    break
   end
  end
  roof.typ=planetyps[(current_idx % #planetyps)+1]
  roof.x,roof.y=0,0
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
 
 if view_mode=="3d" then
  raycast_scene()
  render_floor_ceiling()
  render_walls()
  render_sprites()
  
  -- hud
  print("pos:"..flr(player.x)..","..flr(player.y),2,2,7)
  print("ang:"..(flr(player.a*100)/100),2,10,7)
  print("fps:"..stat(7),2,18,7)
  print("hp:"..player.hp,2,26,7)
  print("[x] toggle map",2,34,7)
  
  -- interaction prompt
  if interaction_active and current_interact then
   print("[E]/Z: interact",screen_center_x-40,screen_height-20,11)
  end
  
  -- trap message
  if trap_msg_timer>0 then
   print("trap sprung!",screen_center_x-30,screen_center_y,8)
  end
  
  -- debug overlay
  if debug_mode then
   local sa,ca=sin(player.a),cos(player.a)
   local z,hx,hy,tile,tx=raycast(player.x,player.y,ca,sa,sa,ca)
   print("debug on [tab]",2,42,11)
   print("z="..(flr(z*100)/100),2,50,7)
   print("tile="..tile,2,58,7)
   print("tx="..(flr(tx*100)/100),2,66,7)
   print("floor: "..floor.typ.tex,2,74,7)
   print("roof: "..roof.typ.tex,2,82,7)
  end
 else
  draw_minimap()
 end
 
 -- combat overlay
 if in_combat then
  rectfill(0,screen_height-40,screen_width,screen_height,0)
  print("entering combat...",screen_center_x-40,screen_center_y,8)
  print("[esc] exit (temp)",screen_center_x-40,screen_center_y+10,7)
 end
end

-- draw 2d minimap for testing
-- Purpose: Render 2D top-down debug view of dungeon
-- Algorithm: Scale 128×128 map to 256×256 pixels (scale=2)
-- Displays: Walls, rooms, doors, objects, player position and facing
-- Notes: Toggled with X button, useful for debugging generation
function draw_minimap()
 local scale=2
 local ox,oy=10,10
 
 -- draw wallgrid
 for x=0,127 do
  for y=0,127 do
   if wallgrid[x][y]>0 then
    rectfill(ox+x*scale,oy+y*scale,ox+x*scale+scale-1,oy+y*scale+scale-1,5)
   else
    rectfill(ox+x*scale,oy+y*scale,ox+x*scale+scale-1,oy+y*scale+scale-1,1)
   end
  end
 end
 
 -- draw rooms
 for node in all(gen_nodes) do
  local r=node.rect
  rect(ox+r[1]*scale,oy+r[2]*scale,ox+r[3]*scale,oy+r[4]*scale,11)
 end
 
 -- draw doors
 for door in all(doors) do
  local c=door.dtype==door_locked and 8 or 12
  rectfill(ox+door.x*scale,oy+door.y*scale,ox+door.x*scale+scale-1,oy+door.y*scale+scale-1,c)
 end
 
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
 print("[x] toggle 3d",10,34,7)
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
      end
     end
    -- check if exit portal
    elseif (tile==exit_start or tile==exit_end) and isplayer then
     -- placeholder for level completion
    -- check if wall
    elseif tile>0 then
     col=true
    end
   end
  end
 end
 
 -- check solid objects around position using objgrid spatial query
 local gx_min=flr((px-radius)/objgrid_size)
 local gx_max=flr((px+radius)/objgrid_size)
 local gy_min=flr((py-radius)/objgrid_size)
 local gy_max=flr((py+radius)/objgrid_size)
 
 gx_min=max(0,gx_min)
 gx_max=min(objgrid_array_size,gx_max)
 gy_min=max(0,gy_min)
 gy_max=min(objgrid_array_size,gy_max)
 
 for gx=gx_min,gx_max do
  for gy=gy_min,gy_max do
   for ob in all(objgrid[gx+1][gy+1]) do
    if ob.typ and ob.typ.solid then
     local ox=ob.pos[1]-px
     local oy=ob.pos[2]-py
     if max(abs(ox),abs(oy))<ob.typ.w then
      col=true
      -- trigger interaction on solid contact if player
      if isplayer then
       check_interactions_at(px,py)
      end
      break
     end
    end
   end
   if col then break end
  end
  if col then break end
 end
 
 -- prevent doors from closing when player is inside
 if isplayer then
  for x=flr(px-radius),flr(px+radius) do
   for y=flr(py-radius),flr(py+radius) do
    if x>=0 and x<128 and y>=0 and y<128 then
     local tile=get_wall(x,y)
     if tile==door_normal or tile==door_locked or tile==door_stay_open then
      local door=doorgrid[x][y]
      if door and door.open>0 then
       door.opening=true
      end
     end
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
 if btn(0) then -- left
  player.a-=player_rotation_speed
 end
 if btn(1) then -- right
  player.a+=player_rotation_speed
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

-- add object to objgrid
-- Purpose: Add object to spatial partitioning grid
-- Parameters: ob (object with pos array)
-- Side effects: Adds to objgrid cell based on position, adds to animated_objects if autoanim=true
-- Notes: Used during dungeon generation and object spawning
function addobject(ob)
 if not ob.pos then return end
 local gx=flr(ob.pos[1]/objgrid_size)
 local gy=flr(ob.pos[2]/objgrid_size)
 if gx>=0 and gx<=objgrid_array_size and gy>=0 and gy<=objgrid_array_size then
  add(objgrid[gx+1][gy+1],ob)
  -- add to animated list if autoanim is true
  if ob.autoanim then
   add(animated_objects,ob)
  end
 end
end

-- remove object from objgrid
function removeobject(ob)
 if not ob.pos then return end
 local gx=flr(ob.pos[1]/objgrid_size)
 local gy=flr(ob.pos[2]/objgrid_size)
 if gx>=0 and gx<=objgrid_array_size and gy>=0 and gy<=objgrid_array_size then
  deli(objgrid[gx+1][gy+1],ob)
  -- also remove from animated list
  if ob.autoanim then
   deli(animated_objects,ob)
  end
 end
end

-- update object grid after position change
function update_object_grid(ob,old_x,old_y)
 if not ob.pos then return end
 local old_gx=flr(old_x/objgrid_size)
 local old_gy=flr(old_y/objgrid_size)
 local new_gx=flr(ob.pos[1]/objgrid_size)
 local new_gy=flr(ob.pos[2]/objgrid_size)
 if old_gx~=new_gx or old_gy~=new_gy then
  if old_gx>=0 and old_gx<=objgrid_array_size and old_gy>=0 and old_gy<=objgrid_array_size then
   deli(objgrid[old_gx+1][old_gy+1],ob)
  end
  if new_gx>=0 and new_gx<=objgrid_array_size and new_gy>=0 and new_gy<=objgrid_array_size then
   add(objgrid[new_gx+1][new_gy+1],ob)
  end
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
 local gx_center=flr(px/objgrid_size)
 local gy_center=flr(py/objgrid_size)
 
 -- scan 3x3 block around player
 local closest_interact=nil
 local closest_dist=999
 
 for gx=gx_center-1,gx_center+1 do
  for gy=gy_center-1,gy_center+1 do
   if gx>=0 and gx<=objgrid_array_size and gy>=0 and gy<=objgrid_array_size then
    for ob in all(objgrid[gx+1][gy+1]) do
     if ob.pos and ob.typ then
      local dx=ob.pos[1]-px
      local dy=ob.pos[2]-py
      local dist=abs(dx)+abs(dy)
      
      -- direct pickup: auto-collect
      if ob.typ.kind=="direct_pickup" and dist<interaction_range then
       collect_item(ob)
       removeobject(ob)
       deli(objects,ob)
      
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
        removeobject(ob)
        deli(objects,ob)
       elseif dist<closest_dist then
        closest_interact=ob
        closest_dist=dist
       end
      end
     end
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
  removeobject(current_interact)
  deli(objects,current_interact)
  
 elseif subtype=="shrine" then
  -- activate shrine (placeholder)
  player.hp=100
  printh("activated shrine")
  
 elseif subtype=="note" then
  -- read note (placeholder)
  printh("read note")
  removeobject(current_interact)
  deli(objects,current_interact)
  
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
 for gx=1,objgrid_array_size+1 do
  for gy=1,objgrid_array_size+1 do
   objgrid[gx][gy]={}
  end
 end
 objects={}
 animated_objects={}
 doors={}
 
 -- regenerate dungeon
 start_pos,gen_stats=generate_dungeon()
 
 printh("floor complete! difficulty: "..gen_params.difficulty)
end

-- update combat (placeholder)
function update_combat()
 -- temp exit: press escape or menu button
 if keyp("escape") or btnp(6) then
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
   
   -- update spatial grid after movement
   if old_x~=ob.pos[1] or old_y~=ob.pos[2] then
    update_object_grid(ob,old_x,old_y)
   end
  end
 end
end
