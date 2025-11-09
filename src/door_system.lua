--[[pod_format="raw",created="2025-11-07 21:17:14",modified="2025-11-07 21:48:06",revision=1]]
-- door animation system
-- test mode state (to avoid permanent mutation)
test_mode_prev=false
test_mode_saved_state={}

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
 
 -- prevent duplicates at same grid cell
 local existing = doorgrid[x] and doorgrid[x][y] or nil
 if existing then
  printh("warning: duplicate door at ("..x..","..y..") - replacing")
  del(doors, existing)
 end
 add(doors,door)
 doorgrid[x][y]=door
	-- walls layer already set by generation to door tile ID (authoritative)
 
 return door
end

-- update all doors
function update_doors()
 -- handle test mode transitions to avoid permanent state mutation
 if test_door_mode and not test_mode_prev then
  -- entering test mode: save states
  test_mode_saved_state={}
  for door in all(doors) do
   test_mode_saved_state[door]={open=door.open,opening=door.opening,timer=door.timer}
  end
 elseif (not test_door_mode) and test_mode_prev then
  -- exiting test mode: restore states
  for door in all(doors) do
   local st=test_mode_saved_state[door]
   if st~=nil then
    door.open=st.open
    door.opening=st.opening
    door.timer=st.timer
   end
  end
  test_mode_saved_state={}
 end
 
 -- in test mode, temporarily override open values (restored on exit)
 if test_door_mode then
  for door in all(doors) do
   door.open=test_door_open or 0
  end
  -- keep early return to skip normal animation while testing
  test_mode_prev=true
  return
 end
 
 test_mode_prev=false
 
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
		set_wall(x,y,0)
 end
end
