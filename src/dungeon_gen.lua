--[[pod_format="raw",created="2025-11-07 21:17:13",modified="2025-11-07 21:48:06",revision=1]]
-- procedural dungeon generation

-- generation state
gen_rects={}
gen_nodes={}
gen_edges={}
gen_inventory={}
gen_objects={}
-- theme-specific floor id used during carving/eroding; initialized to stone_tile (1)
local gen_floor_id=1

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
  if not (rect[3]+gen_params.spacing<r[1] or rect[1]>r[3]+gen_params.spacing or
          rect[4]+gen_params.spacing<r[2] or rect[2]>r[4]+gen_params.spacing) then
   return true
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
			map.walls:set(x,y,fill_val)
  end
 end
end

-- helper: try place door with fallback positions
function try_place_door_with_fallback(x,y,dtype)
 local attempts={
  {x,y},
  {x-1,y},{x+1,y},{x,y-1},{x,y+1}
 }
 
 -- evaluate door placement probability once per logical placement
 local should_place_door=rnd(1)<gen_params.room_door_prob
 
 for attempt in all(attempts) do
  local ax,ay=attempt[1],attempt[2]
  if ax>=0 and ax<128 and ay>=0 and ay<128 then
			if is_wall(get_wall(ax,ay)) and should_place_door then
				map.walls:set(ax,ay,(dtype or 0))
    create_door(ax,ay,dtype)
    return true
   end
  end
 end
 return false
end

-- helper: generate random room
function random_room(base_node,is_special)
 local w,h
 if is_special then
  w,h=12,12
 else
  w=flr(rnd(gen_params.max_size-gen_params.min_size+1))+gen_params.min_size
  h=flr(rnd(gen_params.max_size-gen_params.min_size+1))+gen_params.min_size
 end
 
 local x,y
 if base_node then
  x=base_node.midx+flr(rnd(20)-10)
  y=base_node.midy+flr(rnd(20)-10)
 else
  x=flr(rnd(122))+3
  y=flr(rnd(122))+3
 end
 
 return {x,y,x+w-1,y+h-1},gen_params.room_door_prob
end

-- helper: add room to generation state
function add_room(rect,is_junction)
 add(gen_rects,rect)
 local node={
  rect=rect,
  midx=flr((rect[1]+rect[3])/2),
  midy=flr((rect[2]+rect[4])/2),
  edges={},
  is_junction=is_junction or false
 }
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
 max_attempts=max_attempts or 3
 for attempt=1,max_attempts do
  if bx>=0 and bx<128 and by>=0 and by<128 then
   if is_wall(get_wall(bx,by)) then
   map.walls:set(bx,by,(dtype or 0))
    create_door(bx,by,dtype)
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
			map.walls:set(bx,by,(dtype or 0))
   create_door(bx,by,dtype)
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
   map.walls:set(bx,by,0)
   set_floor(bx,by,gen_floor_id)
   printh("fallback: cleared blocking wall at ("..bx..","..by..")")
   return true
  end
 end
 return false
end

-- helper: create corridor between two nodes
function create_corridor(n1,n2)
 local ctype=get_corridor_type(n1.rect,n2.rect)
	local b1,b2
 
 if ctype=="horiz" then
  local x0,x1=min(n1.midx,n2.midx),max(n1.midx,n2.midx)
  local y=n1.midy
  local r1,r2=n1.rect,n2.rect
  
  -- identify boundary wall tiles before carving
  local bx1,bx2
  if r1[1]<=r2[1] then
   bx1=r1[3]+1
   bx2=r2[1]-1
  else
   bx1=r2[3]+1
   bx2=r1[1]-1
  end
  
  -- place doors on boundary walls (robust: retry and fallback to passage)
  local d1_ok=place_boundary_door_with_retry(bx1,y,door_normal,3)
  if not d1_ok then ensure_boundary_passage(bx1,y) end
  local d2_ok=place_boundary_door_with_retry(bx2,y,door_normal,3)
  if not d2_ok then ensure_boundary_passage(bx2,y) end
  
  -- carve corridor between doors (exclusive)
  local x_start=max(0,bx1+1)
  local x_end=min(127,bx2-1)
  local cy=y
  local cfloor_id=gen_floor_id
  for x=x_start,x_end do
				map.walls:set(x,cy,0)
				set_floor(x,cy,cfloor_id)
  end

		-- store boundary tiles
		b1={x=bx1,y=y}
		b2={x=bx2,y=y}
  
 elseif ctype=="vert" then
  local y0,y1=min(n1.midy,n2.midy),max(n1.midy,n2.midy)
  local x=n1.midx
  local r1,r2=n1.rect,n2.rect
  
  -- identify boundary wall tiles before carving
  local by1,by2
  if r1[2]<=r2[2] then
   by1=r1[4]+1
   by2=r2[2]-1
  else
   by1=r2[4]+1
   by2=r1[2]-1
  end
  
  -- place doors on boundary walls (robust: retry and fallback to passage)
  local d1_ok=place_boundary_door_with_retry(x,by1,door_normal,3)
  if not d1_ok then ensure_boundary_passage(x,by1) end
  local d2_ok=place_boundary_door_with_retry(x,by2,door_normal,3)
  if not d2_ok then ensure_boundary_passage(x,by2) end
  
  -- carve corridor between doors (exclusive)
  local y_start=max(0,by1+1)
  local y_end=min(127,by2-1)
  local cx=x
  local cfloor_id=gen_floor_id
  for y=y_start,y_end do
				map.walls:set(cx,y,0)
				set_floor(cx,y,cfloor_id)
  end

		-- store boundary tiles
		b1={x=x,y=by1}
		b2={x=x,y=by2}
  
 else -- l_shape
	local jx,jy=n1.midx,n2.midy
  local jw,jh=3,3
  local jrect={jx-1,jy-1,jx+jw-2,jy+jh-2}
  fill_rect(jrect,0)
  for x=max(0,jrect[1]),min(127,jrect[3]) do
   for y=max(0,jrect[2]),min(127,jrect[4]) do
    set_floor(x, y, gen_floor_id)
   end
  end
  -- tag as junction to skip perimeter wall texturing
  local jnode=add_room(jrect,true)
  
  -- connect n1 to junction (horizontal)
  local x0,x1=min(n1.midx,jx),max(n1.midx,jx)
  local r1=n1.rect
  local bx1_horiz,bx2_horiz
  if r1[1]<=jx then
   bx1_horiz=r1[3]+1
   -- place door on the wall just outside the junction (left side)
   bx2_horiz=jrect[1]-1
  else
   -- place door on the wall just outside the junction (right side)
   bx1_horiz=jrect[3]+1
   bx2_horiz=r1[1]-1
  end
  
  -- place doors on horizontal segment boundaries with retry and fallback
  if bx1_horiz>=0 and bx1_horiz<128 then
   local door1_ok=place_boundary_door_with_retry(bx1_horiz,n1.midy,door_normal,3)
   if not door1_ok then
    printh("warning: failed to place junction door at ("..bx1_horiz..","..n1.midy.."), clearing as passage")
    ensure_boundary_passage(bx1_horiz,n1.midy)
   end
  end
  
  if bx2_horiz>=0 and bx2_horiz<128 then
   local door2_ok=place_boundary_door_with_retry(bx2_horiz,n1.midy,door_normal,3)
   if not door2_ok then
    printh("warning: failed to place junction door at ("..bx2_horiz..","..n1.midy.."), clearing as passage")
    ensure_boundary_passage(bx2_horiz,n1.midy)
   end
  end
  
	-- carve horizontal segment
  local xh_start=max(0,bx1_horiz+1)
  local xh_end=min(127,bx2_horiz-1)
  local hy=n1.midy
  local hfloor_id=gen_floor_id
  for x=xh_start,xh_end do
				map.walls:set(x,hy,0)
				set_floor(x,hy,hfloor_id)
  end
  
  -- connect junction to n2 (vertical)
  local y0,y1=min(jy,n2.midy),max(jy,n2.midy)
  local r2=n2.rect
  local by1_vert,by2_vert
  if jy<=r2[2] then
   -- place door on the wall just outside the junction (bottom side)
   by1_vert=jrect[4]+1
   by2_vert=r2[2]-1
  else
   by1_vert=r2[4]+1
   -- place door on the wall just outside the junction (top side)
   by2_vert=jrect[2]-1
  end
  
  -- place doors on vertical segment boundaries with retry and fallback
  if by1_vert>=0 and by1_vert<128 then
   local door3_ok=place_boundary_door_with_retry(jx,by1_vert,door_normal,3)
   if not door3_ok then
    printh("warning: failed to place junction door at ("..jx..","..by1_vert.."), clearing as passage")
    ensure_boundary_passage(jx,by1_vert)
   end
  end
  
  if by2_vert>=0 and by2_vert<128 then
   local door4_ok=place_boundary_door_with_retry(jx,by2_vert,door_normal,3)
   if not door4_ok then
    printh("warning: failed to place junction door at ("..jx..","..by2_vert.."), clearing as passage")
    ensure_boundary_passage(jx,by2_vert)
   end
  end
  
	-- carve vertical segment
  local yv_start=max(0,by1_vert+1)
  local yv_end=min(127,by2_vert-1)
  local vx=jx
  local vfloor_id=gen_floor_id
  for y=yv_start,yv_end do
				map.walls:set(vx,y,0)
				set_floor(vx,y,vfloor_id)
  end
  
  -- validation: ensure all boundary passages are clear
  ensure_boundary_passage(bx1_horiz,n1.midy)
  ensure_boundary_passage(bx2_horiz,n1.midy)
  ensure_boundary_passage(jx,by1_vert)
  ensure_boundary_passage(jx,by2_vert)

		-- store boundary tiles near rooms
		local near_n1
		if r1[1]<=jx then
			near_n1={x=bx1_horiz,y=n1.midy}
		else
			near_n1={x=bx2_horiz,y=n1.midy}
		end
		local near_n2
		if jy<=r2[2] then
			near_n2={x=jx,y=by2_vert}
		else
			near_n2={x=jx,y=by1_vert}
		end
		b1=near_n1
		b2=near_n2
 end
 
 -- store boundary tiles for progression gating
	local edge={n1=n1,n2=n2,b1=b1,b2=b2}
 add(gen_edges,edge)
 add(n1.edges,n2)
 add(n2.edges,n1)
end

-- helper: try to generate and connect a room
function try_generate_room()
 local base=gen_nodes[flr(rnd(#gen_nodes))+1]
 local rect=random_room(base,false)
 
 if rect[1]<3 or rect[3]>126 or rect[2]<3 or rect[4]>126 then
  return false
 end
 
 if rect_overlaps(rect) then
  return false
 end
 
 local node=add_room(rect)
 fill_rect(rect,0)
 for x=max(0,rect[1]),min(127,rect[3]) do
  for y=max(0,rect[2]),min(127,rect[4]) do
   set_floor(x, y, gen_floor_id)
  end
 end
 create_corridor(base,node)
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
			map.walls:set(x,rect[2]-1,tex)
   end
  end
  if rect[4]+1>=0 and rect[4]+1<128 and x>=0 and x<128 then
   -- skip reserved cells (doors/exits in any layer)
		if not is_reserved_boundary(x,rect[4]+1) then
			map.walls:set(x,rect[4]+1,tex)
   end
  end
 end
 for y=rect[2],rect[4] do
  if rect[1]-1>=0 and rect[1]-1<128 and y>=0 and y<128 then
   -- skip reserved cells (doors/exits in any layer)
		if not is_reserved_boundary(rect[1]-1,y) then
			map.walls:set(rect[1]-1,y,tex)
   end
  end
  if rect[3]+1>=0 and rect[3]+1<128 and y>=0 and y<128 then
   -- skip reserved cells (doors/exits in any layer)
		if not is_reserved_boundary(rect[3]+1,y) then
			map.walls:set(rect[3]+1,y,tex)
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
      printh("warning: restored door tile at ("..x..","..y..")")
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
   map.walls:set(x,0,wall_fill_tile)
  end
  
  -- bottom edge
  local bottom_tile=get_wall(x,map_size-1)
  if not is_door(bottom_tile) and not is_exit(bottom_tile) then
   map.walls:set(x,map_size-1,wall_fill_tile)
  end
 end
 
 -- left and right edges (x=0 and x=map_size-1)
 for y=0,map_size-1 do
  -- left edge
  local left_tile=get_wall(0,y)
  if not is_door(left_tile) and not is_exit(left_tile) then
   map.walls:set(0,y,wall_fill_tile)
  end
  
  -- right edge
  local right_tile=get_wall(map_size-1,y)
  if not is_door(right_tile) and not is_exit(right_tile) then
   map.walls:set(map_size-1,y,wall_fill_tile)
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
 for i=1,amount do
  local x,y=flr(rnd(128)),flr(rnd(128))
		if is_wall(get_wall(x,y)) then
   local neighbors=0
   for dx=-1,1 do
    for dy=-1,1 do
     local nx,ny=x+dx,y+dy
					if nx>=0 and nx<128 and ny>=0 and ny<128 and get_wall(nx,ny)==0 then
      neighbors+=1
     end
    end
   end
   if neighbors>=3 then
				map.walls:set(x,y,0)
    -- ensure eroded clears become traversable floor with theme-specific type
    set_floor(x,y,gen_floor_id)
   end
  end
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
  map.walls:set(pos[1],pos[2],(exit_tile or 0))
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
			-- choose the actual corridor boundary door tile
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
					-- convert existing door to locked
					map.walls:set(x,y,door_locked)
					door.dtype=door_locked
					door.keynum=key_counter
				else
					-- fallback: create a new locked door here
					map.walls:set(x,y,door_locked)
					create_door(x,y,door_locked,key_counter)
				end
				add(locked_edges,edge)
     -- update cached accessibility after modifying locked edges
     full_accessible=find_accessible_rooms(start_node,locked_edges)
				-- add key to inventory
				add(gen_inventory,{type="key",keynum=key_counter})
				key_counter+=1
   else
    printh("warning: no valid boundary door tile for gate; skipping")
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
     local ob={pos={x,y},typ=obj_types.key,rel={0,0},frame=0,animloop=true,autoanim=true,keynum=item.keynum}
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
       local ob={pos={kx,ky},typ=obj_types.key,rel={0,0},frame=0,animloop=true,autoanim=true,keynum=item.keynum}
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
      local ob={pos={sx,sy},typ=obj_types.key,rel={0,0},frame=0,animloop=true,autoanim=true,keynum=item.keynum}
      add(gen_objects,ob)
     end
    else
     failed_placements+=1
     if failed_placements>10 then
      printh("warning: failed to place items after multiple attempts; stopping")
      break
     end
    end
   end
  else
   break
  end
 end
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
function generate_dungeon()
 local seed=flr(rnd(10000))
 srand(seed)
 
 -- initialize state
 gen_rects={}
 gen_nodes={}
 gen_edges={}
 gen_inventory={}
 gen_objects={}
 
 -- fill with walls (non-zero tile)
 fill_rect({0,0,127,127},wall_fill_tile)
 
 -- assign global theme before carving (ensures theme floor id is available)
 local theme_roll=rnd(1)
 local selected_theme="dng"
 if theme_roll<0.7 then
  selected_theme="dng"
 elseif theme_roll<0.9 then
  selected_theme="out"
 else
  selected_theme="dem"
 end
 gen_params.theme=selected_theme
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
 for x=max(0,first_rect[1]),min(127,first_rect[3]) do
  for y=max(0,first_rect[2]),min(127,first_rect[4]) do
   set_floor(x, y, gen_floor_id)
  end
 end
 
 -- generate additional rooms
 local room_count=flr(rnd(gen_params.max_rooms-gen_params.min_rooms+1))+gen_params.min_rooms
 for i=2,room_count do
  for attempt=1,max_room_attempts do
   if try_generate_room() then
    break
   end
  end
 end
 
 -- theme already chosen and floors configured above
 -- apply wall textures based on theme
 for node in all(gen_nodes) do
  -- skip junction rooms to avoid texturing their perimeters
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
 printh("Border ring enforced, doors preserved")
 
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
 
 printh("generated dungeon: "..#gen_nodes.." rooms, "..#gen_objects.." objects, seed "..seed)
 
 return {x=player.x,y=player.y},{rooms=#gen_nodes,objects=#gen_objects,seed=seed}
end
