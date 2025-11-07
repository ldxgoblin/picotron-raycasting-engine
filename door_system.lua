-- door animation system

-- create a door
function create_door(x,y,dtype,key_id)
 local door={
  x=x,
  y=y,
  open=0, -- 0=closed, 1=fully open
  opening=false, -- animation state
  timer=0,
  dtype=dtype or door_normal,
  keynum=key_id, -- nil if unlocked, key id if locked
  stayopen=(dtype==door_stay_open) -- doors with door_stay_open dtype stay open
 }
 
 add(doors,door)
 doorgrid[x][y]=door
	-- mirror to doors layer userdata
	set_door(x,y,door.dtype)
	-- wall userdata already set by generation to door tile ID
 
 return door
end

-- update all doors
function update_doors()
 -- in test mode, force all doors to test_door_open value
 if test_door_mode then
  for door in all(doors) do
   door.open=test_door_open or 0
  end
  return
 end
 
 for door in all(doors) do
  if door.opening then
   -- play sound on start
   if door.open==0 then
    -- sfx(10) -- door open sound
   end
   -- animate opening
   door.open+=door_anim_speed
   if door.open>1 then
    door.open=1
    door.opening=false
    door.timer=door_close_delay
   end
  else
   -- not opening
   if door.timer>0 then
    door.timer-=1
   elseif not door.stayopen then
    -- close door
    door.open=max(door.open-door_anim_speed,0)
   end
  end
 end
end



-- remove a door
function remove_door(x,y)
 local door=doorgrid[x][y]
 if door then
  del(doors,door)
  doorgrid[x][y]=nil
		set_door(x,y,0)
		set_wall(x,y,0)
 end
end
