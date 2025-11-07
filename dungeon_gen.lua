-- procedural dungeon generation

-- generation state
gen_rects={}
gen_nodes={}
gen_edges={}
gen_inventory={}
gen_objects={}

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

-- helper: check if rectangles overlap
function rect_overlaps(rect)
 for r in all(gen_rects) do
  if not (rect[3]+gen_params.spacing<r[1] or rect[1]>r[3]+gen_params.spacing or
          rect[4]+gen_params.spacing<r[2] or rect[2]>r[4]+gen_params.spacing) then
   return true
  end
 end
 return false
end

-- helper: fill rectangle using set_wall
function fill_rect(rect,val)
 for x=max(0,rect[1]),min(127,rect[3]) do
  for y=max(0,rect[2]),min(127,rect[4]) do
			set_wall(x,y,val)
  end
 end
end

-- helper: try place door with fallback positions
function try_place_door_with_fallback(x,y,dtype)
 local attempts={
  {x,y},
  {x-1,y},{x+1,y},{x,y-1},{x,y+1}
 }
 
 for attempt in all(attempts) do
  local ax,ay=attempt[1],attempt[2]
  if ax>=0 and ax<128 and ay>=0 and ay<128 then
			if is_wall(get_wall(ax,ay)) and rnd(1)<gen_params.room_door_prob then
				set_wall(ax,ay,dtype)
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
function add_room(rect)
 add(gen_rects,rect)
 local node={
  rect=rect,
  midx=flr((rect[1]+rect[3])/2),
  midy=flr((rect[2]+rect[4])/2),
  edges={}
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

-- helper: place door at exact boundary wall tile
function place_boundary_door(bx,by,dtype)
 -- bx,by = boundary wall tile (between corridor and room)
 if bx>=0 and bx<128 and by>=0 and by<128 then
		if is_wall(get_wall(bx,by)) then
			set_wall(bx,by,dtype)
   create_door(bx,by,dtype)
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
  
  -- place doors on boundary walls
  place_boundary_door(bx1,y,door_normal)
  place_boundary_door(bx2,y,door_normal)
  
  -- carve corridor between doors (exclusive)
  for x=bx1+1,bx2-1 do
   if x>=0 and x<128 and y>=0 and y<128 then
				set_wall(x,y,0)
				set_floor(x,y,1)
   end
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
  
  -- place doors on boundary walls
  place_boundary_door(x,by1,door_normal)
  place_boundary_door(x,by2,door_normal)
  
  -- carve corridor between doors (exclusive)
  for y=by1+1,by2-1 do
   if x>=0 and x<128 and y>=0 and y<128 then
				set_wall(x,y,0)
				set_floor(x,y,1)
   end
  end

		-- store boundary tiles
		b1={x=x,y=by1}
		b2={x=x,y=by2}
  
 else -- l_shape
	local jx,jy=n1.midx,n2.midy
  local jw,jh=3,3
  local jrect={jx-1,jy-1,jx+jw-2,jy+jh-2}
  fill_rect(jrect,0)
  local jnode=add_room(jrect)
  
  -- connect n1 to junction (horizontal)
  local x0,x1=min(n1.midx,jx),max(n1.midx,jx)
  local r1=n1.rect
  local bx1_horiz,bx2_horiz
  if r1[1]<=jx then
   bx1_horiz=r1[3]+1
   bx2_horiz=jrect[1]-1
  else
   bx1_horiz=jrect[3]+1
   bx2_horiz=r1[1]-1
  end
  
  -- place doors on horizontal segment boundaries
  place_boundary_door(bx1_horiz,n1.midy,door_normal)
  place_boundary_door(bx2_horiz,n1.midy,door_normal)
  
	-- carve horizontal segment
  for x=bx1_horiz+1,bx2_horiz-1 do
   if x>=0 and x<128 and n1.midy>=0 and n1.midy<128 then
				set_wall(x,n1.midy,0)
				set_floor(x,n1.midy,1)
   end
  end
  
  -- connect junction to n2 (vertical)
  local y0,y1=min(jy,n2.midy),max(jy,n2.midy)
  local r2=n2.rect
  local by1_vert,by2_vert
  if jy<=r2[2] then
   by1_vert=jrect[4]+1
   by2_vert=r2[2]-1
  else
   by1_vert=r2[4]+1
   by2_vert=jrect[2]-1
  end
  
  -- place doors on vertical segment boundaries
  place_boundary_door(jx,by1_vert,door_normal)
  place_boundary_door(jx,by2_vert,door_normal)
  
	-- carve vertical segment
  for y=by1_vert+1,by2_vert-1 do
   if jx>=0 and jx<128 and y>=0 and y<128 then
				set_wall(jx,y,0)
				set_floor(jx,y,1)
   end
  end

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
 create_corridor(base,node)
 return true
end

-- helper: apply wall textures to room perimeter
function apply_room_walls(rect,tex)
 -- ensure tex is never 0
 if tex==0 then tex=1 end
 
 for x=rect[1],rect[3] do
  if rect[2]-1>=0 and rect[2]-1<128 and x>=0 and x<128 then
   -- skip if door or exit tile
		if not (is_door(get_wall(x,rect[2]-1)) or is_exit(get_wall(x,rect[2]-1))) then
			set_wall(x,rect[2]-1,tex)
   end
  end
  if rect[4]+1>=0 and rect[4]+1<128 and x>=0 and x<128 then
   -- skip if door or exit tile
		if not (is_door(get_wall(x,rect[4]+1)) or is_exit(get_wall(x,rect[4]+1))) then
			set_wall(x,rect[4]+1,tex)
   end
  end
 end
 for y=rect[2],rect[4] do
  if rect[1]-1>=0 and rect[1]-1<128 and y>=0 and y<128 then
   -- skip if door or exit tile
		if not (is_door(get_wall(rect[1]-1,y)) or is_exit(get_wall(rect[1]-1,y))) then
			set_wall(rect[1]-1,y,tex)
   end
  end
  if rect[3]+1>=0 and rect[3]+1<128 and y>=0 and y<128 then
   -- skip if door or exit tile
		if not (is_door(get_wall(rect[3]+1,y)) or is_exit(get_wall(rect[3]+1,y))) then
			set_wall(rect[3]+1,y,tex)
   end
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
  local idx=rnd(1)<0.5 and 6 or 7 -- grass or earth
  return texsets[idx]
 elseif theme=="dem" then
  -- demon: stone or cobblestone
  local idx=rnd(1)<0.5 and 3 or 5
  return texsets[idx]
 elseif theme=="house" then
  -- house: wood plank
  return texsets[4]
 else
  -- default dungeon: brick or cobblestone
  local idx=rnd(1)<0.5 and 2 or 3
  return texsets[idx]
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
  
  if x>=0 and x<128 and y>=0 and y<128 and wallgrid[x][y]==0 then
   local valid=true
   for obj in all(gen_objects) do
    local dx,dy=abs(obj.x-x),abs(obj.y-y)
    if dx<1 and dy<1 then
     valid=false
     break
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
				set_wall(x,y,0)
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
  set_wall(pos[1],pos[2],exit_tile)
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
 
 -- attempt to create progression gates
 for gate_idx=1,#gen_edges do
  if key_counter>3 then break end
  
  -- try to lock an edge
  local edge=gen_edges[flr(rnd(#gen_edges))+1]
  local n1,n2=edge.n1,edge.n2
  
  -- check if this edge would gate content
  local test_locked={edge}
  local test_accessible=find_accessible_rooms(start_node,test_locked)
  local full_accessible=find_accessible_rooms(start_node,locked_edges)
  
		-- if locking this edge hides new rooms, add it as a gate
		if #test_accessible<#full_accessible then
			-- choose the actual corridor boundary door tile
			local candidates={edge.b1,edge.b2}
			local chosen=nil
			for c in all(candidates) do
				if c and c.x and c.y then
					chosen=c
					break
				end
			end
			if chosen then
				local x,y=chosen.x,chosen.y
				local door=doorgrid[x] and doorgrid[x][y] or nil
				if door then
					-- convert existing door to locked
					set_wall(x,y,door_locked)
					set_door(x,y,door_locked)
					door.dtype=door_locked
					door.keynum=key_counter
				else
					-- fallback: create a new locked door here
					set_wall(x,y,door_locked)
					create_door(x,y,door_locked,key_counter)
				end
				add(locked_edges,edge)
				-- add key to inventory
				add(gen_inventory,{type="key",keynum=key_counter})
				key_counter+=1
			end
		end
 end
 
 -- place inventory items in accessible rooms
 while #gen_inventory>0 do
  local accessible=find_accessible_rooms(start_node,locked_edges)
  
  if #accessible>0 then
   local room=accessible[flr(rnd(#accessible))+1]
   local item=gen_inventory[1]
   deli(gen_inventory,1)
   
   local x,y=find_spawn_point(room.rect)
   if x then
   if item.type=="key" then
     local ob={pos={x,y},typ=obj_types.key,rel={0,0},frame=0,animloop=true,autoanim=true,keynum=item.keynum}
     add(gen_objects,ob)
    else
     local ob={pos={x,y},typ=obj_types[item.type],rel={0,0},frame=0,animloop=true,autoanim=true}
     add(gen_objects,ob)
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
     -- hostile npc with patrol or follow behavior
     local ai_type=rnd(1)<0.5 and "patrol" or "follow"
     local ob={
      pos={x,y},
      typ=obj_types.hostile_npc,
      rel={0,0},
      frame=0,
      animloop=true,
      autoanim=true,
      ai_type=ai_type,
      patrol_index=0,
      patrol_points={}
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
     -- non-hostile npc
     local ob={
      pos={x,y},
      typ=obj_types.non_hostile_npc,
      rel={0,0},
      frame=0,
      animloop=true,
      autoanim=false
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
         local ob={pos={x,y},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,decoration_type=dec}
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
         local ob={pos={x,y},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,decoration_type=dec}
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
        local ob={pos={x,y},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,decoration_type=dec}
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
       local ob={pos={cx,cy},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,decoration_type=dec}
       add(gen_objects,ob)
       room_decor_count+=1
      else
       -- random corner
       local corners={{rect[1]+1.5,rect[2]+1.5},{rect[3]-0.5,rect[2]+1.5},{rect[1]+1.5,rect[4]-0.5},{rect[3]-0.5,rect[4]-0.5}}
       local corner=corners[flr(rnd(#corners))+1]
       local ob={pos={corner[1],corner[2]},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,decoration_type=dec}
       add(gen_objects,ob)
       room_decor_count+=1
      end
      
     elseif tag=="rare" and rnd(1)<0.05*decor_prob then
      if room_decor_count>=max_decor then break end
      -- rare: single spawn
      local x,y=find_spawn_point(rect)
      if x then
       local ob={pos={x,y},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,decoration_type=dec}
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
       local ob={pos={pos[1],pos[2]},typ=dec.obj_type,rel={0,0},frame=0,animloop=true,autoanim=true,decoration_type=dec}
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
 
 -- generate first room
 local first_rect=random_room(nil,false)
 local first_node=add_room(first_rect)
 fill_rect(first_rect,0)
 
 -- generate additional rooms
 local room_count=flr(rnd(gen_params.max_rooms-gen_params.min_rooms+1))+gen_params.min_rooms
 for i=2,room_count do
  for attempt=1,max_room_attempts do
   if try_generate_room() then
    break
   end
  end
 end
 
 -- assign global theme before gameplay generation
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
 
 -- apply wall textures based on theme
 for node in all(gen_nodes) do
  local texset=theme_wall_texture(selected_theme)
  local tex=texset.variants[flr(rnd(#texset.variants))+1]
  apply_room_walls(node.rect,tex)
 end
 
 -- generate gameplay content (now aware of theme)
 generate_gameplay()
 
 -- populate objgrid from gen_objects
 for ob in all(gen_objects) do
  addobject(ob)
 end
 
 -- export to global objects list
 objects=gen_objects
 
 -- set player start
 player.x=first_node.midx+0.5
 player.y=first_node.midy+0.5
 
 printh("generated dungeon: "..#gen_nodes.." rooms, "..#gen_objects.." objects, seed "..seed)
 
 return {x=player.x,y=player.y},{rooms=#gen_nodes,objects=#gen_objects,seed=seed}
end
