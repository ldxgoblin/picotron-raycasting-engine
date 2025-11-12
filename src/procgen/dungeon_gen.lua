--[[pod_format="raw",created="2025-11-07 21:17:13",modified="2025-11-07 21:48:06",revision=1]]
-- procedural dungeon generation

-- generation state
gen_rects={}
gen_nodes={}
gen_edges={}
gen_inventory={}
gen_objects={}
gen_locked_edges={}

-- theme-specific floor id used during carving/eroding; initialized to stone_tile (1)
local gen_floor_id=1

-- observability + diagnostics configuration (defaults if config.lua did not define them)
local observability = rawget(_G,"gen_observability") or {
 enable_console=false,
 capture_history=true,
 history_limit=400,
 log_seed=true,
 log_room_attempts=true,
 log_corridors=true,
 log_progression=true,
 log_repairs=true
}

local gen_history={}
local protected_tiles={}
local dynamic_spacing=0
local base_spacing=0
local spacing_restore_timer=0
local spacing_relaxations=0
local active_theme_rules=nil
local adaptive_settings=rawget(_G,"gen_adaptive_settings") or {
 spacing_relax_threshold=4,
 spacing_relax_step=1,
 spacing_max_relax=4,
 spacing_restore_delay=2,
 spacing_restore_step=1,
 max_room_failures=20,
 offcenter_bias=0.65,
 bias_radius=12,
 junction_retry_limit=4,
 corridor_jog_chance=0.25
}

local room_failure_streak=0
local total_room_failures=0

local tick_spacing -- forward declaration
local gen_log -- forward declaration
local relax_spacing -- forward declaration

local function hist_push(entry)
 if not observability.capture_history then return end
 add(gen_history,entry)
 if #gen_history>(observability.history_limit or 400) then
  deli(gen_history,1)
 end
end

local function register_room_failure(reason)
 room_failure_streak+=1
 total_room_failures+=1
 tick_spacing(false)
 if observability.log_room_attempts then
  gen_log("room_fail",reason.." (streak="..room_failure_streak..")")
 end
 if room_failure_streak>=(adaptive_settings.spacing_relax_threshold or 4) then
  relax_spacing()
  room_failure_streak=0
 end
end

local function register_room_success()
 room_failure_streak=0
 tick_spacing(true)
end

gen_log=function(tag,msg)
 local line="["..tag.."] "..msg
 hist_push(line)
 if observability.enable_console then printh(line) end
end

local function clear_protected()
 protected_tiles={}
end

local function protect_tile(x,y)
 if not x or not y then return end
 protected_tiles[x]=protected_tiles[x] or {}
 protected_tiles[x][y]=true
end

local function is_tile_protected(x,y)
 return protected_tiles[x] and protected_tiles[x][y] or false
end

local function reset_adaptive_spacing()
 base_spacing=gen_params.spacing or 0
 dynamic_spacing=base_spacing
 spacing_restore_timer=0
 spacing_relaxations=0
 room_failure_streak=0
 total_room_failures=0
end

relax_spacing=function()
 if spacing_relaxations>=(adaptive_settings.spacing_max_relax or 4) then return end
 dynamic_spacing=max(0,dynamic_spacing-(adaptive_settings.spacing_relax_step or 1))
 spacing_relaxations+=1
 spacing_restore_timer=adaptive_settings.spacing_restore_delay or 2
 gen_log("spacing","relaxed spacing to "..dynamic_spacing)
end

tick_spacing=function(success)
 if success then
  if spacing_restore_timer>0 then
   spacing_restore_timer-=1
  elseif dynamic_spacing<base_spacing then
   dynamic_spacing=min(base_spacing,dynamic_spacing+(adaptive_settings.spacing_restore_step or 1))
   if dynamic_spacing==base_spacing then
    spacing_relaxations=0
   end
   gen_log("spacing","restored spacing to "..dynamic_spacing)
  end
 else
  if spacing_restore_timer>0 then
   spacing_restore_timer-=1
  end
 end
end

local function rect_area(rect)
 return (rect[3]-rect[1]+1)*(rect[4]-rect[2]+1)
end

local function classify_room_style(rect)
 local w=rect[3]-rect[1]+1
 local h=rect[4]-rect[2]+1
 local ratio=w/h
 if ratio>=1.8 then
  return "hall_horizontal"
 elseif ratio<=0.55 then
  return "hall_vertical"
 elseif w*h>=120 then
  return "grand"
 elseif w<=6 and h<=6 then
  return "compact"
 else
  return "square"
 end
end

local function choose_weighted(weights,default_key)
 if not weights then return default_key end
 local total=0
 for _,v in pairs(weights) do
  total+=v
 end
 if total<=0 then return default_key end
 local roll=rnd(total)
 local acc=0
 for key,v in pairs(weights) do
  acc+=v
  if roll<=acc then return key end
 end
 return default_key
end

local function get_edge_between(a,b)
 for e in all(gen_edges) do
  if (e.n1==a and e.n2==b) or (e.n1==b and e.n2==a) then
   return e
  end
 end
 return nil
end

local function locate_room_for_position(x,y)
 for node in all(gen_nodes) do
  local r=node.rect
  if x>=r[1] and x<=r[3] and y>=r[2] and y<=r[4] then
   return node
  end
 end
 return nil
end

local function relocate_key_to_room(keynum,target_node)
 if not target_node then return false end
 local sx,sy=find_spawn_point(target_node.rect)
 if not sx then
  sx=target_node.midx+0.5
  sy=target_node.midy+0.5
 end
 for ob in all(gen_objects) do
  if ob.typ==obj_types.key and ob.keynum==keynum then
   ob.pos={sx,sy}
   ob.room_index=target_node.index
   if observability.log_progression then
    gen_log("progression","relocated key#"..keynum.." to room "..target_node.index)
   end
   return true
  end
 end
 return false
end

local function validate_and_repair_progression(start_node,locked_edges)
 if not locked_edges or #locked_edges==0 then return end
 local key_rooms={}
 for ob in all(gen_objects) do
  if ob.typ==obj_types.key and ob.keynum then
   if not ob.room_index then
    local node=locate_room_for_position(ob.pos[1],ob.pos[2])
    ob.room_index=node and node.index or nil
   end
   key_rooms[ob.keynum]=ob.room_index
  end
 end

 local acquired={}
 local visited={}
 local queue={start_node}
 visited[start_node]=true
 local function collect_keys(node)
  for ob in all(gen_objects) do
   if ob.typ==obj_types.key and ob.keynum and ob.room_index==node.index then
    acquired[ob.keynum]=true
   end
  end
 end
 collect_keys(start_node)
 local progressed=true
 while progressed do
  progressed=false
  for edge in all(gen_edges) do
   local a,b=edge.n1,edge.n2
   local a_vis=visited[a]
   local b_vis=visited[b]
   if a_vis and not b_vis then
    local can_traverse=true
    if edge.locked and edge.keynum and not acquired[edge.keynum] then
     can_traverse=false
    end
    if can_traverse then
     visited[b]=true
     collect_keys(b)
     progressed=true
    end
   elseif b_vis and not a_vis then
    local can_traverse=true
    if edge.locked and edge.keynum and not acquired[edge.keynum] then
     can_traverse=false
    end
    if can_traverse then
     visited[a]=true
     collect_keys(a)
     progressed=true
    end
   end
  end
 end

 local relocated=false
 for edge in all(locked_edges) do
  if edge.locked and edge.keynum then
   local n1_vis=visited[edge.n1]
   local n2_vis=visited[edge.n2]
   if not (n1_vis and n2_vis) then
    if relocate_key_to_room(edge.keynum,start_node) then
     relocated=true
     acquired[edge.keynum]=true
     visited[edge.n1]=true
     visited[edge.n2]=true
    end
   end
  end
 end
 if relocated then
  validate_and_repair_progression(start_node,locked_edges)
 end
end

local function ensure_theme_rules(theme)
 local rules=(themes[theme] and themes[theme].rules) or nil
 active_theme_rules=rules or {
  room_aspect_bias=0.35,
  room_extra_size=0,
  spacing_floor=0,
  corridor_width=1,
  corridor_jog_chance=adaptive_settings.corridor_jog_chance or 0.25
 }
end

-- helper: check if tile is a wall
function is_wall(val)
 return val>0 and val<door_normal
end

-- helper: check if tile is a door
function is_door(val)
 return val>=door_normal and val<=door_stay_open
end

-- helper: check if tile is an exit
function is_exit(val)
 return val>=exit_start and val<=exit_end
end

-- helper: boundary cell is reserved if it has a door/exit in either layer
function is_reserved_boundary(x,y)
 local w=get_wall(x,y)
 if is_door(w) or is_exit(w) then return true end
 -- defensive: should always be 0 if walls layer is authoritative
 if get_door(x,y)>0 then return true end
 if doorgrid[x] and doorgrid[x][y] then return true end
 return false
end

-- helper: check if rectangles overlap
function rect_overlaps(rect)
 -- reject out-of-bounds rectangles upfront (map is 0..127)
 if rect[1]<0 or rect[3]>=128 or rect[2]<0 or rect[4]>=128 then
  return true
 end
 for r in all(gen_rects) do
  local spacing=dynamic_spacing or 0
  if not (rect[3]+spacing<r[1] or rect[1]>r[3]+spacing or
          rect[4]+spacing<r[2] or rect[2]>r[4]+spacing) then
   return true
  end
 end
 return false
end

local function rect_conflicts(rect,ignore_nodes,spacing_override)
 if rect[1]<0 or rect[3]>=map_size or rect[2]<0 or rect[4]>=map_size then
  return true
 end
 local ignore={}
 if ignore_nodes then
  for n in all(ignore_nodes) do
   if n and n.index then
    ignore[n.index]=true
   end
  end
 end
 local spacing=(spacing_override~=nil) and spacing_override or (dynamic_spacing or 0)
 for idx=1,#gen_rects do
  if not ignore[idx] then
   local r=gen_rects[idx]
   if r and not (rect[3]+spacing<r[1] or rect[1]>r[3]+spacing or rect[4]+spacing<r[2] or rect[2]>r[4]+spacing) then
    return true
   end
  end
 end
 return false
end

-- helper: fill rectangle using set_wall
-- Note: Uses Lua loops with userdata:set() calls; potential optimization:
-- batch userdata operations or memset() if available per Picotron guidelines
function fill_rect(rect,val)
 local x0=max(0,rect[1])
 local x1=min(127,rect[3])
 local y0=max(0,rect[2])
 local y1=min(127,rect[4])
 local fill_val=(val or 0)
 for x=x0,x1 do
  for y=y0,y1 do
   set_wall(x,y,fill_val)
  end
 end
end

-- helper: try place door with fallback positions
function try_place_door_with_fallback(x,y,dtype)
 dtype=dtype or door_normal
 local attempts={{0,0},{-1,0},{1,0},{0,-1},{0,1},{-2,0},{2,0},{0,-2},{0,2}}
 local should_place=rnd(1)<gen_params.room_door_prob
 if not should_place then
  gen_log("door","skipped optional door at "..x..","..y)
  return false
 end
 for i=1,#attempts do
  local off=attempts[i]
  local ax,ay=x+off[1],y+off[2]
  if ax>=0 and ax<map_size and ay>=0 and ay<map_size then
   local existing=get_wall(ax,ay)
   if is_wall(existing) then
    set_wall(ax,ay,dtype)
    create_door(ax,ay,dtype)
    protect_tile(ax,ay)
    if observability.log_corridors then
     gen_log("door","placed door at "..ax..","..ay.." after "..i.." attempts")
    end
    return true
   end
  end
 end
 if observability.log_repairs then
  gen_log("door","failed to place door near "..x..","..y)
 end
 return false
end

-- helper: generate random room
function random_room(base_node,is_special)
 local min_size=gen_params.min_size or 4
 local max_size=gen_params.max_size or 12
 if active_theme_rules and active_theme_rules.room_extra_size then
  max_size+=active_theme_rules.room_extra_size
 end
 if max_size<min_size then max_size=min_size end
 local shape_weights=active_theme_rules and active_theme_rules.room_shape_weights
 local shape=choose_weighted(shape_weights,"square")
 local w,h
 if is_special then
  w,h=12,12
 else
  if shape=="hall_horizontal" then
   w=flr(rnd(max_size-min_size+1))+min_size
   h=max(min_size,flr(w*0.5))
  elseif shape=="hall_vertical" then
   h=flr(rnd(max_size-min_size+1))+min_size
   w=max(min_size,flr(h*0.5))
  elseif shape=="grand" then
   w=max_size
   h=max(min_size,max_size-2)
  else
   w=flr(rnd(max_size-min_size+1))+min_size
   h=flr(rnd(max_size-min_size+1))+min_size
  end
 end
 w=min(w, max_size)
 h=min(h, max_size)
 w=max(w,min_size)
 h=max(h,min_size)

 local function sample_offset(range)
  local bias=(active_theme_rules and active_theme_rules.center_bias) or adaptive_settings.offcenter_bias or 0.65
  local magnitude=flr(range*(rnd()^bias))
  if rnd(1)<0.5 then magnitude=-magnitude end
  return magnitude
 end

 local x,y
 if base_node then
  local radius=(active_theme_rules and active_theme_rules.bias_radius) or adaptive_settings.bias_radius or 12
  local dx=sample_offset(radius)
  local dy=sample_offset(radius)
  x=base_node.midx+dx-flr(w/2)
  y=base_node.midy+dy-flr(h/2)
 else
  local margin=4
  x=flr(rnd(map_size-w-margin*2))+margin
  y=flr(rnd(map_size-h-margin*2))+margin
 end

 x=max(1,min(map_size-w-2,x))
 y=max(1,min(map_size-h-2,y))

 return {x,y,x+w-1,y+h-1}
end

-- helper: add room to generation state
function add_room(rect,is_junction)
 local index=#gen_nodes+1
 gen_rects[index]=rect
 local style=classify_room_style(rect)
 local node={
  rect=rect,
  midx=flr((rect[1]+rect[3])/2),
  midy=flr((rect[2]+rect[4])/2),
  edges={},
  is_junction=is_junction or false,
  style=style,
  area=rect_area(rect),
  theme=gen_params.theme,
  metadata={},
  index=index
 }
 if observability.log_room_attempts then
  gen_log("room","added room "..(#gen_nodes+1).." style="..style.." rect=("..rect[1]..","..rect[2]..")-("..rect[3]..","..rect[4]..")")
 end
 add(gen_nodes,node)
 return node
end

-- helper: determine corridor type between two rooms
function get_corridor_type(r1,r2)
 local ox=not (r1[3]<r2[1] or r1[1]>r2[3])
 local oy=not (r1[4]<r2[2] or r1[2]>r2[4])
 if ox and not oy then return "vert" end
 if oy and not ox then return "horiz" end
 return "l_shape"
end

-- helper: place door at exact boundary wall tile with retry
function place_boundary_door_with_retry(bx,by,dtype,max_attempts)
 dtype=dtype or door_normal
 local offsets={{0,0},{-1,0},{1,0},{0,-1},{0,1},{-2,0},{2,0},{0,-2},{0,2}}
 local attempts=max_attempts or #offsets
 for i=1,attempts do
  local off=offsets[i] or offsets[#offsets]
  local ax,ay=bx+off[1],by+off[2]
  if ax>=0 and ax<map_size and ay>=0 and ay<map_size then
   local tile=get_wall(ax,ay)
   if is_wall(tile) then
    set_wall(ax,ay,dtype)
    create_door(ax,ay,dtype)
    protect_tile(ax,ay)
    if observability.log_corridors then
     gen_log("door","boundary door placed at "..ax..","..ay.." (from "..bx..","..by..")")
    end
    return true
   end
  end
 end
 return false
end

-- helper: place door at exact boundary wall tile
function place_boundary_door(bx,by,dtype)
 -- bx,by = boundary wall tile (between corridor and room)
 if bx>=0 and bx<128 and by>=0 and by<128 then
  if is_wall(get_wall(bx,by)) then
   set_wall(bx,by,dtype or door_normal)
   create_door(bx,by,dtype)
   protect_tile(bx,by)
   return true
  end
 end
 return false
end

-- helper: ensure boundary passage (fallback for failed door placement)
function ensure_boundary_passage(bx,by)
 if bx>=0 and bx<128 and by>=0 and by<128 then
  local tile=get_wall(bx,by)
  -- if wall is still blocking and not a door, clear it
  if tile>0 and not is_door(tile) and not is_exit(tile) then
   set_wall(bx,by,0)
   set_floor(bx,by,gen_floor_id)
   protect_tile(bx,by)
   if observability.log_repairs then
    gen_log("door","fallback cleared wall at ("..bx..","..by..")")
   end
   return true
  end
 end
 return false
end

local function verify_boundary_door(bx,by,dtype)
 if not bx or not by then return end
 dtype=dtype or door_normal
 if bx<0 or bx>=map_size or by<0 or by>=map_size then return end
 local tile=get_wall(bx,by)
 if is_door(tile) then
  protect_tile(bx,by)
  return
 end
 if tile==0 then
  set_wall(bx,by,dtype)
  create_door(bx,by,dtype)
  protect_tile(bx,by)
  if observability.log_repairs then
   gen_log("door","repaired missing door at "..bx..","..by)
  end
 else
  local ok=place_boundary_door_with_retry(bx,by,dtype,6)
  if not ok then
   ensure_boundary_passage(bx,by)
  end
 end
end

local function carve_horizontal_span(y,x_start,x_end,floor_id)
 if not floor_id then floor_id=gen_floor_id end
 if y<0 or y>=map_size then return end
 local a=min(x_start,x_end)
 local b=max(x_start,x_end)
 a=max(0,a)
 b=min(map_size-1,b)
 for x=a,b do
  set_wall(x,y,0)
  set_floor(x,y,floor_id)
 end
end

local function carve_vertical_span(x,y_start,y_end,floor_id)
 if not floor_id then floor_id=gen_floor_id end
 if x<0 or x>=map_size then return end
 local a=min(y_start,y_end)
 local b=max(y_start,y_end)
 a=max(0,a)
 b=min(map_size-1,b)
 for y=a,b do
  set_wall(x,y,0)
  set_floor(x,y,floor_id)
 end
end

local function create_horizontal_corridor(n1,n2,edge)
 local left,right=n1,n2
 if n1.midx>n2.midx then left,right=n2,n1 end
 local r_left,r_right=left.rect,right.rect
 local y_start=max(r_left[2],r_right[2])
 local y_end=min(r_left[4],r_right[4])
 local y
 if y_start<=y_end then
  y=flr((y_start+y_end)/2)
 else
  y=flr((n1.midy+n2.midy)/2)
 end
 local jog_offset=0
 local jog_chance=(active_theme_rules and active_theme_rules.corridor_jog_chance) or adaptive_settings.corridor_jog_chance or 0.25
 if rnd(1)<jog_chance then
  local offset=(rnd(1)<0.5) and -1 or 1
  local candidate=y+offset
  if candidate>1 and candidate<map_size-2 then
   y=candidate
   jog_offset=offset
  end
 end
 local bx_left=r_left[3]+1
 local bx_right=r_right[1]-1
 local success=true
 if not place_boundary_door_with_retry(bx_left,y,door_normal,5) then
  success=false
  ensure_boundary_passage(bx_left,y)
 end
 if not place_boundary_door_with_retry(bx_right,y,door_normal,5) then
  success=false
  ensure_boundary_passage(bx_right,y)
 end
 carve_horizontal_span(y,bx_left+1,bx_right-1,gen_floor_id)
 verify_boundary_door(bx_left,y,door_normal)
 verify_boundary_door(bx_right,y,door_normal)
 edge.b1={x=bx_left,y=y}
 edge.b2={x=bx_right,y=y}
 edge.shape=jog_offset~=0 and "jog" or "straight"
 edge.metadata.corridor_y=y
 edge.metadata.jog_offset=jog_offset
 return success
end

local function create_vertical_corridor(n1,n2,edge)
 local top,bottom=n1,n2
 if n1.midy>n2.midy then top,bottom=n2,n1 end
 local r_top,r_bottom=top.rect,bottom.rect
 local x_start=max(r_top[1],r_bottom[1])
 local x_end=min(r_top[3],r_bottom[3])
 local x
 if x_start<=x_end then
  x=flr((x_start+x_end)/2)
 else
  x=flr((n1.midx+n2.midx)/2)
 end
 local jog_offset=0
 local jog_chance=(active_theme_rules and active_theme_rules.corridor_jog_chance) or adaptive_settings.corridor_jog_chance or 0.25
 if rnd(1)<jog_chance then
  local offset=(rnd(1)<0.5) and -1 or 1
  local candidate=x+offset
  if candidate>1 and candidate<map_size-2 then
   x=candidate
   jog_offset=offset
  end
 end
 local by_top=r_top[4]+1
 local by_bottom=r_bottom[2]-1
 local success=true
 if not place_boundary_door_with_retry(x,by_top,door_normal,5) then
  success=false
  ensure_boundary_passage(x,by_top)
 end
 if not place_boundary_door_with_retry(x,by_bottom,door_normal,5) then
  success=false
  ensure_boundary_passage(x,by_bottom)
 end
 carve_vertical_span(x,by_top+1,by_bottom-1,gen_floor_id)
 verify_boundary_door(x,by_top,door_normal)
 verify_boundary_door(x,by_bottom,door_normal)
 edge.b1={x=x,y=by_top}
 edge.b2={x=x,y=by_bottom}
 edge.shape=jog_offset~=0 and "jog" or "straight"
 edge.metadata.corridor_x=x
 edge.metadata.jog_offset=jog_offset
 return success
end

local function create_l_shaped_corridor(n1,n2,edge)
local orient_horizontal_first=rnd(1)<0.5
local anchor_x=orient_horizontal_first and n2.midx or n1.midx
local anchor_y=orient_horizontal_first and n1.midy or n2.midy
local jrect
local offsets={{0,0},{1,0},{-1,0},{0,1},{0,-1},{2,0},{-2,0},{0,2},{0,-2}}
local attempt_limit=adaptive_settings.junction_retry_limit or 4
for i=1,#offsets do
 local off=offsets[i]
 local cx=max(1,min(map_size-2,anchor_x+off[1]))
 local cy=max(1,min(map_size-2,anchor_y+off[2]))
 local candidate={cx-1,cy-1,cx+1,cy+1}
 if not rect_conflicts(candidate,{n1,n2},0) then
  jrect=candidate
  anchor_x=cx
  anchor_y=cy
  break
 end
 if i>=attempt_limit then break end
end
 local success=true
 if not jrect then
  -- fallback: carve direct manhattan path without junction
  orient_horizontal_first=true
  anchor_x=n2.midx
  anchor_y=n1.midy
  jrect=nil
  success=false
  if observability.log_corridors then
   gen_log("corridor","fallback L-shape without junction between rooms")
  end
 else
  fill_rect(jrect,0)
  for x=jrect[1],jrect[3] do
   for y=jrect[2],jrect[4] do
    set_floor(x,y,gen_floor_id)
   end
  end
  local jnode=add_room(jrect,true)
  edge.metadata.junction_node=jnode
 end

 local function connect_horizontal(from_node, target_x, y)
  local rect=from_node.rect
  local side=target_x>from_node.midx and 1 or -1
  local boundary_from=(side==1) and rect[3]+1 or rect[1]-1
  local boundary_to=side==1 and target_x-1 or target_x+1
  local door_pos=boundary_from
  if not place_boundary_door_with_retry(door_pos, y, door_normal,5) then
   success=false
   ensure_boundary_passage(door_pos,y)
  end
  carve_horizontal_span(y, boundary_from+side, boundary_to, gen_floor_id)
  verify_boundary_door(door_pos,y,door_normal)
  return {x=door_pos,y=y}
 end

 local function connect_vertical(from_node, x, target_y)
  local rect=from_node.rect
  local side=target_y>from_node.midy and 1 or -1
  local boundary_from=(side==1) and rect[4]+1 or rect[2]-1
  local boundary_to=side==1 and target_y-1 or target_y+1
  local door_pos=boundary_from
  if not place_boundary_door_with_retry(x,door_pos,door_normal,5) then
   success=false
   ensure_boundary_passage(x,door_pos)
  end
  carve_vertical_span(x, boundary_from+side, boundary_to, gen_floor_id)
  verify_boundary_door(x,door_pos,door_normal)
  return {x=x,y=door_pos}
 end

 local b1,b2
 if orient_horizontal_first then
  local horizontal_y=n1.midy
  b1=connect_horizontal(n1, anchor_x, horizontal_y)
  local vertical_x=jrect and anchor_x or b1.x+(anchor_x>b1.x and 1 or -1)
  b2=connect_vertical(n2, vertical_x, anchor_y)
 else
  local vertical_x=n1.midx
  b1=connect_vertical(n1, vertical_x, anchor_y)
  local horizontal_y=jrect and anchor_y or b1.y+(anchor_y>b1.y and 1 or -1)
  b2=connect_horizontal(n2, anchor_x, horizontal_y)
 end

 edge.b1=b1
 edge.b2=b2
 edge.shape="l_shape"
 edge.metadata.anchor={x=anchor_x,y=anchor_y}
 edge.metadata.orientation=orient_horizontal_first and "hv" or "vh"
 return success
end

function create_corridor(n1,n2)
 local edge={n1=n1,n2=n2,metadata={}}
 local ctype=get_corridor_type(n1.rect,n2.rect)
 local success=true
 if ctype=="horiz" then
  success=create_horizontal_corridor(n1,n2,edge)
 elseif ctype=="vert" then
  success=create_vertical_corridor(n1,n2,edge)
 else
  success=create_l_shaped_corridor(n1,n2,edge)
 end
 edge.success=success
 add(gen_edges,edge)
 add(n1.edges,n2)
 add(n2.edges,n1)
 if observability.log_corridors then
  local status=success and "ok" or "fallback"
  gen_log("corridor","linked nodes "..n1.index.." <-> "..n2.index.." ("..ctype..","..status..")")
 end
 return success
end

-- helper: try to generate and connect a room
function try_generate_room()
 if #gen_nodes==0 then return false end
 local base=gen_nodes[flr(rnd(#gen_nodes))+1]
 if not base then return false end
 local rect=random_room(base,false)
 
 if rect[1]<2 or rect[3]>map_size-3 or rect[2]<2 or rect[4]>map_size-3 then
  register_room_failure("bounds")
  return false
 end
 
 if rect_overlaps(rect) then
  register_room_failure("overlap")
  return false
 end
 
 local node=add_room(rect)
 fill_rect(rect,0)
 for x=max(0,rect[1]),min(map_size-1,rect[3]) do
  for y=max(0,rect[2]),min(map_size-1,rect[4]) do
   set_floor(x, y, gen_floor_id)
  end
 end
 local corridor_ok=create_corridor(base,node)
 if not corridor_ok and observability.log_corridors then
  gen_log("corridor","degenerate corridor between nodes "..base.index.." and "..node.index)
 end
 register_room_success()
 return true
end

-- helper: apply wall textures to room perimeter
function apply_room_walls(rect,tex)
 -- ensure tex is never 0
 if tex==0 then tex=1 end
 
 for x=rect[1],rect[3] do
  if rect[2]-1>=0 and rect[2]-1<128 and x>=0 and x<128 then
   -- skip reserved cells (doors/exits in any layer)
		if not is_reserved_boundary(x,rect[2]-1) then
     set_wall(x,rect[2]-1,tex)
   end
  end
  if rect[4]+1>=0 and rect[4]+1<128 and x>=0 and x<128 then
   -- skip reserved cells (doors/exits in any layer)
		if not is_reserved_boundary(x,rect[4]+1) then
     set_wall(x,rect[4]+1,tex)
   end
  end
 end
 for y=rect[2],rect[4] do
  if rect[1]-1>=0 and rect[1]-1<128 and y>=0 and y<128 then
   -- skip reserved cells (doors/exits in any layer)
		if not is_reserved_boundary(rect[1]-1,y) then
     set_wall(rect[1]-1,y,tex)
   end
  end
  if rect[3]+1>=0 and rect[3]+1<128 and y>=0 and y<128 then
   -- skip reserved cells (doors/exits in any layer)
		if not is_reserved_boundary(rect[3]+1,y) then
     set_wall(rect[3]+1,y,tex)
   end
  end
 end
end

-- repair step: ensure door tiles exist on walls layer for all logical doors
function enforce_door_tiles()
 for door in all(doors) do
  if not is_door(get_wall(door.x,door.y)) then
   set_wall(door.x,door.y,door.dtype or door_normal)
  end
 end
 
 -- also check doorgrid consistency
 for x=0,map_size-1 do
  if doorgrid[x] then
   for y=0,map_size-1 do
    if doorgrid[x][y] then
     local tile=get_wall(x,y)
     if not is_door(tile) then
      -- restore door tile from doorgrid or use default
      local correct_tile=doorgrid[x][y].tile or door_normal
      set_wall(x,y,correct_tile)
      if observability.log_repairs then
       gen_log("door","restored door tile at ("..x..","..y..")")
      end
     end
    end
   end
  end
 end
end

-- border ring enforcement: set outermost ring to walls while preserving doors/exits
function enforce_border_ring()
 -- top and bottom edges (y=0 and y=map_size-1)
 for x=0,map_size-1 do
  -- top edge
  local top_tile=get_wall(x,0)
  if not is_door(top_tile) and not is_exit(top_tile) then
  set_wall(x,0,wall_fill_tile)
  end
  
  -- bottom edge
  local bottom_tile=get_wall(x,map_size-1)
  if not is_door(bottom_tile) and not is_exit(bottom_tile) then
  set_wall(x,map_size-1,wall_fill_tile)
  end
 end
 
 -- left and right edges (x=0 and x=map_size-1)
 for y=0,map_size-1 do
  -- left edge
  local left_tile=get_wall(0,y)
  if not is_door(left_tile) and not is_exit(left_tile) then
  set_wall(0,y,wall_fill_tile)
  end
  
  -- right edge
  local right_tile=get_wall(map_size-1,y)
  if not is_door(right_tile) and not is_exit(right_tile) then
  set_wall(map_size-1,y,wall_fill_tile)
  end
 end
end

-- helper: random wall texture (never returns 0)
function random_wall_texture()
 local set=texsets[flr(rnd(#texsets-1))+2] -- skip texsets[1] which is floor
 return set.variants[flr(rnd(#set.variants))+1]
end

-- helper: get theme-appropriate wall texture set
function theme_wall_texture(theme)
 if theme=="out" then
  -- outdoor: grass or earth variants
  -- indices in texsets: 5=grass, 6=earth
  local idx=rnd(1)<0.5 and 5 or 6
  return texsets[idx] or texsets[1]
 elseif theme=="dem" then
  -- demon: stone or cobblestone
  -- indices: 4=stone, 2=cobblestone
  local idx=rnd(1)<0.5 and 4 or 2
  return texsets[idx] or texsets[1]
 elseif theme=="house" then
  -- house: wood plank
  -- index: 3=wood_plank
  return texsets[3] or texsets[1]
 else
  -- default dungeon: brick or cobblestone
  -- indices: 1=brick, 2=cobblestone
  local idx=rnd(1)<0.5 and 1 or 2
  return texsets[idx] or texsets[1]
 end
end

-- helper: find accessible rooms from start via edges
function find_accessible_rooms(start_node,locked_edges)
 local accessible={}
 local queue={start_node}
 local visited={}
 visited[start_node]=true
 
 while #queue>0 do
  local node=queue[1]
  deli(queue,1)
  add(accessible,node)
  
  for edge_node in all(node.edges) do
   if not visited[edge_node] then
    local is_locked=false
    if locked_edges then
     for le in all(locked_edges) do
					if (le.n1==node and le.n2==edge_node) or (le.n1==edge_node and le.n2==node) then
       is_locked=true
       break
      end
     end
    end
    
    if not is_locked then
     visited[edge_node]=true
     add(queue,edge_node)
    end
   end
  end
 end
 
 return accessible
end

-- helper: find spawn point in room
function find_spawn_point(rect)
 for attempt=1,max_spawn_attempts do
  local x=rect[1]+1+flr(rnd(rect[3]-rect[1]-1))
  local y=rect[2]+1+flr(rnd(rect[4]-rect[2]-1))
  
  if x>=0 and x<128 and y>=0 and y<128 and get_wall(x,y)==0 then
   local valid=true
   for obj in all(gen_objects) do
    local ox=obj.pos and obj.pos[1] or obj.x
    local oy=obj.pos and obj.pos[2] or obj.y
    if ox and oy then
     local dx,dy=abs(ox-x),abs(oy-y)
     if dx<1 and dy<1 then
      valid=false
      break
     end
    end
   end
   
   if valid then
    return x+0.5,y+0.5
   end
  end
 end
 return nil,nil
end

-- helper: erode map for organic feel (generalized for all wall types)
function erode_map(amount)
 local intensity=(active_theme_rules and active_theme_rules.erosion_intensity) or 1
 local target=flr(amount*intensity)
 local removed=0
 for i=1,target do
  local x,y=flr(rnd(map_size)),flr(rnd(map_size))
  if is_tile_protected(x,y) then goto continue end
  if is_wall(get_wall(x,y)) then
   local neighbors=0
   local near_protected=false
   for dx=-1,1 do
    for dy=-1,1 do
     local nx,ny=x+dx,y+dy
     if nx>=0 and nx<map_size and ny>=0 and ny<map_size then
      if is_tile_protected(nx,ny) then
       near_protected=true
      end
      if get_wall(nx,ny)==0 then
       neighbors+=1
      end
     end
    end
   end
   if not near_protected and neighbors>=3 then
    set_wall(x,y,0)
    set_floor(x,y,gen_floor_id)
    removed+=1
   end
  end
 ::continue::
 end
 if observability.log_corridors and removed>target*0.7 then
  gen_log("erosion","high erosion count "..removed.."/"..target)
 end
end

-- helper: generate exit portal on wall
function generate_exit(rect,exit_type)
 local walls={}
 for x=rect[1],rect[3] do
		if rect[2]-1>=0 and is_wall(get_wall(x,rect[2]-1)) then
   add(walls,{x,rect[2]})
  end
		if rect[4]+1<128 and is_wall(get_wall(x,rect[4]+1)) then
   add(walls,{x,rect[4]})
  end
 end
 for y=rect[2],rect[4] do
		if rect[1]-1>=0 and is_wall(get_wall(rect[1]-1,y)) then
   add(walls,{rect[1],y})
  end
		if rect[3]+1<128 and is_wall(get_wall(rect[3]+1,y)) then
   add(walls,{rect[3],y})
  end
 end
 
 if #walls>0 then
  local pos=walls[flr(rnd(#walls))+1]
  -- write exit tile to map
  local exit_tile=exit_type==3 and exit_start or exit_end
  set_wall(pos[1],pos[2],exit_tile or 0)
  -- also add interactable exit object
  local ob={
   pos={pos[1]+0.5,pos[2]+0.5},
   typ=obj_types.interactable_exit,
   rel={0,0},
   frame=0,
   animloop=true,
   autoanim=false,
   exit_type=exit_type
  }
  add(gen_objects,ob)
 end
end

-- gameplay generation: enemies, items, decorations, npcs
function generate_gameplay()
 -- guard against empty gen_nodes to avoid nil dereference
 if not gen_nodes or #gen_nodes==0 then
  gen_log("error","generate_gameplay() called with no rooms")
  printh("error: generate_gameplay() called with no rooms")
  return
 end
 local start_node=gen_nodes[1]
 local exit_node=gen_nodes[#gen_nodes]
 
 -- place start/exit portals
 generate_exit(start_node.rect,3)
 generate_exit(exit_node.rect,4)
 
 -- erode map
 erode_map(gen_params.erode_amount)
 
 -- populate inventory with health items
 for i=1,3 do
  add(gen_inventory,{type="heart"})
 end
 
 -- generate progression loop (simplified - no locking yet)
 generate_progression_loop(start_node)
 
 -- generate npcs (includes hostile and non-hostile)
 generate_npcs()
 
 -- generate items
 generate_items()
 
 -- generate decorations
 generate_decorations()
end

-- generate progression: items and locked doors
function generate_progression_loop(start_node)
 local locked_edges={}
 local key_counter=1
 
 -- cache accessible rooms for current locked_edges; recompute only after a successful lock
 local full_accessible=find_accessible_rooms(start_node,locked_edges)
 
 -- prepare shuffled edge order to avoid duplicate selection and ensure coverage
 local edges_shuffled={}
 for e in all(gen_edges) do add(edges_shuffled,e) end
 -- fisher-yates shuffle
 for i=#edges_shuffled,2,-1 do
  local j=flr(rnd(i))+1
  edges_shuffled[i],edges_shuffled[j]=edges_shuffled[j],edges_shuffled[i]
 end
 
 -- attempt to create progression gates
 for gate_idx=1,#edges_shuffled do
  if key_counter>3 then break end
  
  -- try to lock an edge
  local edge=edges_shuffled[gate_idx]
  local n1,n2=edge.n1,edge.n2
  
  -- check if this edge would gate content
  local combined_locked={}
  for le in all(locked_edges) do add(combined_locked,le) end
  add(combined_locked,edge)
  local test_accessible=find_accessible_rooms(start_node,combined_locked)
  
  -- if locking this edge hides new rooms, add it as a gate
  if #test_accessible<#full_accessible then
   local candidates={edge.b1,edge.b2}
   local chosen=nil
   for c in all(candidates) do
    if c and c.x and c.y then
     local wt=get_wall(c.x,c.y)
     if is_door(wt) then
      chosen=c
      break
     end
    end
   end
   if chosen then
    local x,y=chosen.x,chosen.y
    local door=doorgrid[x] and doorgrid[x][y] or nil
    if door then
     set_wall(x,y,door_locked)
     door.dtype=door_locked
     door.keynum=key_counter
     door.locked=true
    else
     set_wall(x,y,door_locked)
     create_door(x,y,door_locked,key_counter)
    end
    protect_tile(x,y)
    edge.locked=true
    edge.keynum=key_counter
    edge.lock_tile={x=x,y=y}
    add(locked_edges,edge)
    full_accessible=find_accessible_rooms(start_node,locked_edges)
    add(gen_inventory,{type="key",keynum=key_counter})
    if observability.log_progression then
     gen_log("progression","locked edge "..n1.index.." <-> "..n2.index.." key#"..key_counter)
    end
    key_counter+=1
   else
    if observability.log_progression then
     gen_log("progression","edge "..n1.index.." <-> "..n2.index.." missing door; skipped")
    end
   end
  end
 end
 
 -- place inventory items in accessible rooms
 local failed_placements=0
 -- compute accessible rooms once (does not change during item placement)
 local accessible=find_accessible_rooms(start_node,locked_edges)
 while #gen_inventory>0 do
  
  if #accessible>0 then
   local room=accessible[flr(rnd(#accessible))+1]
   local item=gen_inventory[1]
   deli(gen_inventory,1)
   
   local x,y=find_spawn_point(room.rect)
   if x then
    failed_placements=0
    if item.type=="key" then
     local ob={pos={x,y},typ=obj_types.key,rel={0,0},frame=0,animloop=true,autoanim=true,keynum=item.keynum,room_index=room.index}
     add(gen_objects,ob)
    else
     local ob={pos={x,y},typ=obj_types[item.type],rel={0,0},frame=0,animloop=true,autoanim=true}
     add(gen_objects,ob)
    end
   else
    -- handle failed placement
    if item.type=="key" then
     -- retry a limited number of times across different rooms
     local attempts=0
     local placed=false
     while attempts<15 and not placed do
      local rr=accessible[flr(rnd(#accessible))+1]
      local kx,ky=find_spawn_point(rr.rect)
      if kx then
       local ob={pos={kx,ky},typ=obj_types.key,rel={0,0},frame=0,animloop=true,autoanim=true,keynum=item.keynum,room_index=rr.index}
       add(gen_objects,ob)
       placed=true
       break
      end
      attempts+=1
     end
     if not placed then
      -- fallback: force place in start room (center if needed)
      local sx,sy=find_spawn_point(start_node.rect)
      if not sx then
       sx=start_node.midx+0.5
       sy=start_node.midy+0.5
      end
      local ob={pos={sx,sy},typ=obj_types.key,rel={0,0},frame=0,animloop=true,autoanim=true,keynum=item.keynum,room_index=start_node.index}
      add(gen_objects,ob)
     end
    else
     failed_placements+=1
     if failed_placements>10 then
      gen_log("items","failed to place items after multiple attempts; stopping")
      break
     end
    end
   end
  else
   break
  end
 end

validate_and_repair_progression(start_node,locked_edges)
gen_locked_edges=locked_edges
end

-- generate npcs (hostile and non-hostile) in rooms
function generate_npcs()
 for node in all(gen_nodes) do
  local rect=node.rect
  local num_npcs=flr(rnd(3))+1
  
  for i=1,num_npcs do
   local x,y=find_spawn_point(rect)
   if x then
    -- 70% hostile, 30% non-hostile
    if rnd(1)<gen_params.npc_hostile_ratio then
     -- select enemy type based on current difficulty level
     local available_enemies = {}
     for enemy in all(enemy_types) do
      if enemy.difficulty <= gen_params.difficulty then
       add(available_enemies, enemy)
      end
     end
     -- fallback to rat if no enemies available
     if #available_enemies == 0 then
      available_enemies = {enemy_types[1]}
     end
     local enemy_type = available_enemies[flr(rnd(#available_enemies))+1]
     
     -- hostile npc with patrol or follow behavior
     local ai_type=rnd(1)<0.5 and "patrol" or "follow"
     -- sprite_index from enemy_types configuration (64-72 range)
     local ob={
      pos={x,y},
      typ=obj_types.hostile_npc,
      rel={0,0},
      frame=0,
      animloop=true,
      autoanim=true,
      ai_type=ai_type,
      patrol_index=0,
      patrol_points={},
      sprite_index=enemy_type.sprite
     }
     -- generate patrol points if patrol mode
     if ai_type=="patrol" then
      for j=1,4 do
       local px,py=find_spawn_point(rect)
       if px then
        add(ob.patrol_points,{x=px,y=py})
       end
      end
      if #ob.patrol_points==0 then
       add(ob.patrol_points,{x=x,y=y})
      end
     end
     add(gen_objects,ob)
    else
     -- non-hostile NPCs use sprite 73
     local ob={
      pos={x,y},
      typ=obj_types.non_hostile_npc,
      rel={0,0},
      frame=0,
      animloop=true,
      autoanim=false,
      sprite_index=obj_types.non_hostile_npc.mx
     }
     add(gen_objects,ob)
    end
   end
  end
 end
end

-- generate items (pickups and interactables) in rooms
function generate_items()
 for node in all(gen_nodes) do
  local rect=node.rect
  local num_items=flr(rnd(gen_params.items_per_room))+1
  
  for i=1,num_items do
   local x,y=find_spawn_point(rect)
   if x then
    -- choose item type: 60% pickup, 40% interactable
    if rnd(1)<0.6 then
     -- direct pickup (heart or generic item)
     local pickup_type=rnd(1)<0.5 and "heart" or "direct_pickup"
     local obj_type=pickup_type=="heart" and obj_types.heart or obj_types.direct_pickup
     local ob={
      pos={x,y},
      typ=obj_type,
      rel={0,0},
      frame=0,
      animloop=true,
      autoanim=true
     }
     add(gen_objects,ob)
    else
     -- interactable (chest, shrine, trap, note)
     local subtypes={"chest","shrine","trap","note"}
     local subtype=subtypes[flr(rnd(#subtypes))+1]
     local obj_type
     if subtype=="chest" then
      obj_type=obj_types.interactable_chest
     elseif subtype=="shrine" then
      obj_type=obj_types.interactable_shrine
     elseif subtype=="trap" then
      obj_type=obj_types.interactable_trap
     else
      obj_type=obj_types.interactable_note
     end
     local ob={
      pos={x,y},
      typ=obj_type,
      rel={0,0},
      frame=0,
      animloop=true,
      autoanim=false,
      subtype=subtype
     }
     add(gen_objects,ob)
    end
   end
  end
 end
end

-- generate decorations in rooms
function generate_decorations()
 local current_theme=gen_params.theme or "dng"
 local theme_config=themes[current_theme] or themes.dng
 local decor_prob=theme_config.decor_prob or 0.8
 
 for node in all(gen_nodes) do
  local rect=node.rect
  local w,h=rect[3]-rect[1]+1,rect[4]-rect[2]+1
  local room_decor_count=0
  local max_decor=gen_params.max_decorations_per_room or 12
  
  -- uniform grid pattern
  for dec in all(decoration_types) do
   if room_decor_count>=max_decor then break end
   
   -- filter by theme: check if any theme_tags match current_theme
   local theme_match=false
   if dec.theme_tags then
    for tag in all(dec.theme_tags) do
     if tag==current_theme then
      theme_match=true
      break
     end
    end
   else
    theme_match=true -- no theme_tags means always match
   end
   
   if theme_match and dec.gen_tags then
    for tag in all(dec.gen_tags) do
     if room_decor_count>=max_decor then break end
     
     if tag=="uni" and rnd(1)<0.3*decor_prob then
      for dx=2,w-2,3 do
       for dy=2,h-2,3 do
        if room_decor_count>=max_decor then break end
        if rnd(1)<0.5 then
         local x,y=rect[1]+dx+0.5,rect[2]+dy+0.5
         -- sprite_index from decoration_types configuration (148-155 range)
         local ob={pos={x,y},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,sprite_index=dec.sprite}
         add(gen_objects,ob)
         room_decor_count+=1
        end
       end
       if room_decor_count>=max_decor then break end
      end
      
     elseif tag=="uni2" and rnd(1)<0.4*decor_prob then
      -- denser uniform grid
      for dx=1,w-1,2 do
       for dy=1,h-1,2 do
        if room_decor_count>=max_decor then break end
        if rnd(1)<0.6 then
         local x,y=rect[1]+dx+0.5,rect[2]+dy+0.5
         local ob={pos={x,y},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,sprite_index=dec.sprite}
         add(gen_objects,ob)
         room_decor_count+=1
        end
       end
       if room_decor_count>=max_decor then break end
      end
      
     elseif tag=="scatter" and rnd(1)<0.2*decor_prob then
      local count=flr(rnd(3))+1
      for i=1,count do
       if room_decor_count>=max_decor then break end
       local x,y=find_spawn_point(rect)
       if x then
        local ob={pos={x,y},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,sprite_index=dec.sprite}
        add(gen_objects,ob)
        room_decor_count+=1
       end
      end
      
     elseif tag=="big" and rnd(1)<0.15*decor_prob then
      if room_decor_count>=max_decor then break end
      -- large object: place at room center or corner
      local cx,cy=flr((rect[1]+rect[3])/2)+0.5,flr((rect[2]+rect[4])/2)+0.5
      if rnd(1)<0.5 then
       -- center
       local ob={pos={cx,cy},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,sprite_index=dec.sprite}
       add(gen_objects,ob)
       room_decor_count+=1
      else
       -- random corner
       local corners={{rect[1]+1.5,rect[2]+1.5},{rect[3]-0.5,rect[2]+1.5},{rect[1]+1.5,rect[4]-0.5},{rect[3]-0.5,rect[4]-0.5}}
       local corner=corners[flr(rnd(#corners))+1]
       local ob={pos={corner[1],corner[2]},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,sprite_index=dec.sprite}
       add(gen_objects,ob)
       room_decor_count+=1
      end
      
     elseif tag=="rare" and rnd(1)<0.05*decor_prob then
      if room_decor_count>=max_decor then break end
      -- rare: single spawn
      local x,y=find_spawn_point(rect)
      if x then
       local ob={pos={x,y},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,sprite_index=dec.sprite}
       add(gen_objects,ob)
       room_decor_count+=1
      end
      
     elseif tag=="lit" and rnd(1)<0.25*decor_prob then
      if room_decor_count>=max_decor then break end
      -- lit: bias toward walls or doorways
      local walls={}
      -- collect wall-adjacent floor tiles
      for x=rect[1]+1,rect[3]-1 do
       if get_wall(x,rect[2])>0 then add(walls,{x+0.5,rect[2]+1.5}) end
       if get_wall(x,rect[4])>0 then add(walls,{x+0.5,rect[4]-0.5}) end
      end
      for y=rect[2]+1,rect[4]-1 do
       if get_wall(rect[1],y)>0 then add(walls,{rect[1]+1.5,y+0.5}) end
       if get_wall(rect[3],y)>0 then add(walls,{rect[3]-0.5,y+0.5}) end
      end
      if #walls>0 then
       local pos=walls[flr(rnd(#walls))+1]
       local ob={pos={pos[1],pos[2]},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,sprite_index=dec.sprite}
       add(gen_objects,ob)
       room_decor_count+=1
      end
     end
    end
   end
  end
 end
end

-- generate a complete dungeon
function generate_dungeon(opts)
 opts=opts or {}
 local seed=opts.seed or flr(rnd(1000000))
 srand(seed)
 gen_history={}
 clear_protected()
 reset_adaptive_spacing()
 if gen_params.spacing==nil then gen_params.spacing=0 end
 if observability.log_seed then
  gen_log("seed","generation seed "..seed)
 end
 
 -- initialize state
 gen_rects={}
 gen_nodes={}
 gen_edges={}
 gen_inventory={}
 gen_objects={}
 doors={}
 animated_objects={}
 -- clear doorgrid
 for x=0,map_size-1 do
  if doorgrid[x] then
   for y=0,map_size-1 do
    doorgrid[x][y]=nil
   end
  end
 end
 
 -- fill with walls (non-zero tile)
 fill_rect({0,0,map_size-1,map_size-1},wall_fill_tile)
 
 -- assign global theme before carving (ensures theme floor id is available)
 local selected_theme=opts.theme or "dng"
 if not opts.theme then
  local theme_roll=rnd(1)
  if theme_roll<0.7 then
   selected_theme="dng"
  elseif theme_roll<0.9 then
   selected_theme="out"
  else
   selected_theme="dem"
  end
 end
 gen_params.theme=selected_theme
 ensure_theme_rules(selected_theme)
 local theme_config=themes[selected_theme] or themes.dng
 
 -- set floor and ceiling types based on theme
 local floor_idx=1
 local roof_idx=3
 if theme_config.floor=="stone_tile" then floor_idx=1
 elseif theme_config.floor=="dirt" then floor_idx=2
 end
 if theme_config.roof=="stone_ceiling" then roof_idx=3
 elseif theme_config.roof=="sky" then roof_idx=4
 elseif theme_config.roof=="night_sky" then roof_idx=5
 end
 floor.typ=planetyps[floor_idx]
 roof.typ=planetyps[roof_idx]
 floor.x,floor.y=0,0
 roof.x,roof.y=0,0
 -- theme-specific floor id used by generator when carving/eroding
 gen_floor_id=floor_idx
 
 -- generate first room
 local first_rect=random_room(nil,false)
 local first_node=add_room(first_rect)
 fill_rect(first_rect,0)
 for x=max(0,first_rect[1]),min(map_size-1,first_rect[3]) do
  for y=max(0,first_rect[2]),min(map_size-1,first_rect[4]) do
   set_floor(x, y, gen_floor_id)
  end
 end
 register_room_success()
 
 -- generate additional rooms
 local target_rooms=flr(rnd(gen_params.max_rooms-gen_params.min_rooms+1))+gen_params.min_rooms
 for i=2,target_rooms do
  local placed=false
  for attempt=1,max_room_attempts do
   if try_generate_room() then
    placed=true
    break
   end
  end
  if not placed and observability.log_room_attempts then
   gen_log("room","failed to place room "..i.." after "..max_room_attempts.." attempts")
  end
 end
 
 -- apply wall textures based on theme
 for node in all(gen_nodes) do
  if not node.is_junction then
   local texset=theme_wall_texture(selected_theme)
   local tex=texset.variants[flr(rnd(#texset.variants))+1]
   apply_room_walls(node.rect,tex)
  end
 end
 
 -- ensure any doors placed earlier remain doors on the walls layer
 enforce_door_tiles()
 
 -- generate gameplay content (now aware of theme)
 generate_gameplay()
 -- gameplay may lock doors; re-assert tiles
 enforce_door_tiles()
 
 -- enforce border ring while preserving doors/exits
 enforce_border_ring()
 -- re-assert door tiles after border enforcement
 enforce_door_tiles()
 if observability.enable_console then
  gen_log("summary","border ring enforced")
 end
 
 -- export objects to global arrays (flat iteration, no spatial grid)
 objects=gen_objects
 
 -- populate animated_objects list for frame updates
 animated_objects={}
 for ob in all(objects) do
  if ob.autoanim then
   add(animated_objects, ob)
  end
 end
 
 -- set player start
 player.x=first_node.midx+0.5
 player.y=first_node.midy+0.5
 
 if observability.enable_console then
  gen_log("summary","rooms="..#gen_nodes.." objects="..#gen_objects)
 end
 
 return {x=player.x,y=player.y},{rooms=#gen_nodes,objects=#gen_objects,seed=seed,history=gen_history}
end

