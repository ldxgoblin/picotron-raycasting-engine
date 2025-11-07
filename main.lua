-- picotron raycast engine v1.0
-- main entry point

include"config.lua"
include"raycast.lua"
include"render.lua"
include"render_sprite.lua"
include"door_system.lua"
include"dungeon_gen.lua"

function _init()
 window(480,270)
 
 -- player state
 player={
  x=64,y=64,
  a=0,
  spd=0.1,
  keys={}
 }
 
 -- camera
 cam={player.x,player.y}
 
 -- map abstraction with userdata layers
 map={}
 map.walls=userdata("i16",128,128)
 map.doors=userdata("i16",128,128)
 map.floors=userdata("i16",128,128)
 
 -- helper: get wall tile
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
 
 -- helper: set floor tile
 function set_floor(x,y,val)
  if x>=0 and x<128 and y>=0 and y<128 then
   map.floors:set(x,y,val or 0)
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
 update_input()
 update_doors()
 cam={player.x,player.y}
 
 -- update floor/ceiling scrolling
 floor.x+=floor.typ.xvel or 0
 floor.y+=floor.typ.yvel or 0
 roof.x+=roof.typ.xvel or 0
 roof.y+=roof.typ.yvel or 0
 
 -- update object animations
 for gx=1,objgrid_array_size+1 do
  for gy=1,objgrid_array_size+1 do
   for ob in all(objgrid[gx][gy]) do
    if ob.typ and ob.typ.framect then
     if ob.autoanim then
      ob.frame+=ob.typ.animspd
      if ob.animloop then
       ob.frame=ob.frame%ob.typ.framect
      else
       ob.frame=min(ob.frame,ob.typ.framect-1)
      end
     end
    end
   end
  end
 end
 
 -- toggle view mode
 if btnp(5) then -- x key
  view_mode=view_mode=="3d" and "2d" or "3d"
 end
 
 -- toggle debug mode
 if btnp(4) then -- z key
  debug_mode=not debug_mode
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
  printh("debug: z="..flr(z*100)/100.." hx="..flr(hx*100)/100.." hy="..flr(hy*100)/100.." tile="..tile.." tx="..flr(tx*100)/100)
  local ob,dist=hitscan(player.x,player.y,ca,sa)
  if ob then
   printh("debug: obj found at dist="..flr(dist*100)/100.." kind="..(ob.kind or "unknown"))
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
  print("ang:"..flr(player.a*100)/100,2,10,7)
  print("fps:"..stat(7),2,18,7)
  print("[x] toggle map",2,26,7)
  
  -- debug overlay
  if debug_mode then
   local sa,ca=sin(player.a),cos(player.a)
   local z,hx,hy,tile,tx=raycast(player.x,player.y,ca,sa,sa,ca)
   print("debug on [z]",2,34,11)
   print("z="..flr(z*100)/100,2,42,7)
   print("tile="..tile,2,50,7)
   print("tx="..flr(tx*100)/100,2,58,7)
   print("floor: "..floor.typ.tex,2,66,7)
   print("roof: "..roof.typ.tex,2,74,7)
  end
 else
  draw_minimap()
 end
end

-- draw 2d minimap for testing
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
  if ob.kind=="enemy" then c=8
  elseif ob.kind=="heart" then c=14
  elseif ob.kind=="key" then c=9
  elseif ob.kind=="exit" then c=12
  elseif ob.kind=="decoration" then c=13
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
    if not ob.typ or not ob.typ.solid then
     continue
    end
    
    local ox=ob.pos[1]-px
    local oy=ob.pos[2]-py
    if max(abs(ox),abs(oy))<ob.typ.w then
     col=true
     break
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
function trymoveto(pos,target_x,target_y,radius,opendoors,isplayer)
 radius=radius or 0.15
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

function update_input()
 local sa,ca=sin(player.a),cos(player.a)
 
 -- movement
 if btn(0) then -- left
  player.a-=0.02
 end
 if btn(1) then -- right
  player.a+=0.02
 end
 if btn(2) then -- up
  local nx=player.x+ca*player.spd
  local ny=player.y+sa*player.spd
  trymoveto(player,nx,ny,0.15,true,true)
 end
 if btn(3) then -- down
  local nx=player.x-ca*player.spd
  local ny=player.y-sa*player.spd
  trymoveto(player,nx,ny,0.15,true,true)
 end
end

-- add object to objgrid
function addobject(ob)
 if not ob.pos then return end
 local gx=flr(ob.pos[1]/objgrid_size)
 local gy=flr(ob.pos[2]/objgrid_size)
 if gx>=0 and gx<=objgrid_array_size and gy>=0 and gy<=objgrid_array_size then
  add(objgrid[gx+1][gy+1],ob)
 end
end

-- remove object from objgrid
function removeobject(ob)
 if not ob.pos then return end
 local gx=flr(ob.pos[1]/objgrid_size)
 local gy=flr(ob.pos[2]/objgrid_size)
 if gx>=0 and gx<=objgrid_array_size and gy>=0 and gy<=objgrid_array_size then
  deli(objgrid[gx+1][gy+1],ob)
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
