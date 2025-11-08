--[[pod_format="raw",created="2025-11-08 00:00:00",modified="2025-11-08 00:00:00",revision=2]]
-- Nonboy Mini Raycasting Engine - v0.2
-- raycasting, rendering, procedural generation, player movement, UI framework, minimap
-- single-color placeholders for all assets

--=======================
-- Utility Functions
--=======================
function sgn(x)
 return x<0 and -1 or (x>0 and 1 or 0)
end

function clamp(v,mn,mx)
 return min(max(v,mn),mx)
end

function lerp(a,b,f)
 return (1-f)*a+f*b
end

function tblcopy(t)
 local r={}
 for k,v in pairs(t) do r[k]=v end
 return r
end

--=======================
-- Constants & Configuration
--=======================
sdist=100 -- projection distance
max_ray_steps=256
objgridsize=5

-- Render configuration (data-driven)
screen_w,screen_h=480,270
cx,cy=screen_w/2,screen_h/2
num_rays=screen_w

-- Tile types
door_normal,door_locked,exit_tile=1,2,4

-- Placeholder colors (single, clearly distinguishable)
col_wall_base,col_wall_var=5,7
col_door_normal,col_door_locked=9,8
col_floor,col_ceiling=12,3
col_enemy,col_pickup,col_prop,col_projectile=8,10,13,11

--=======================
-- Global State
--=======================
framect,timer=0,0
player=nil
wallgrid,doorgrid,floorgrid={},{},{}
doors,collect,enem,part,proj={},{},{},{},{}
objgrid={}
zbuf,tbuf={},{}
minx,miny,maxx,maxy,maxz=0,0,0,0,0
sa,ca=0,1
floor,roof={typ={col=col_ceiling}},{typ={col=col_floor}}
fogdist=40
totalenem,levelenem=0,0
gamestate="playing" -- States: playing, paused, won, died
levelnum=1
epdata={} -- Episode data for persistence

-- UI state
g_x,g_y,g_left,g_right,g_tabs,g_focus,g_mousemode=1,1,1,screen_w,{},false,false
g_mx,g_my,g_mb,g_mbp,g_clk=cx,cy,false,false,false
autonl=true
itms,dolast,co,regions,rstack={},{},{},{},{}

--=======================
-- Data Tables
--=======================
otyps={
 player={w=0.3,h=1,y=0.5,solid=true},
 key={w=0.2,h=0.2,y=0.4},
 heart={w=0.2,h=0.2,y=0.25},
 skel={w=0.36,h=0.8,y=0.1,solid=true},
 wolf={w=0.45,h=0.5,y=0.25,solid=true},
 bat={w=0.7,h=0.233,y=-0.15,solid=true},
 torch={w=0.2,h=0.4,y=0.3,lit=0},
 column={w=0.2,h=1.1,y=0,solid=true},
 spark={w=0.3,h=0.3,y=0},
 firebl={w=0.2,h=0.2,y=0.1}
}

etyps={
 {name="bat",objtyp=otyps.bat,hp=1,cooldown=15,attframe=3,dmg=1,spd=0.05,ai="chase",attdist=0.4,attrng=0.4,pdist=5,crad=0.1},
 {name="wolf",objtyp=otyps.wolf,hp=2,cooldown=8,attframe=3,dmg=1,spd=0.08,ai="chase",attdist=0.4,attrng=0.4,pdist=8,crad=0.15},
 {name="skel",objtyp=otyps.skel,hp=5,cooldown=30,attframe=10,dmg=4,spd=0.03,ai="chase",attdist=0.5,attrng=0.8,pdist=7,crad=0.15,opendoors=true}
}

-- Combat is handled in a separate mode later; no projectiles in 3D view.

--=======================
-- Init
--=======================
function _init()
 -- Init grids
 for x=0,127 do
  wallgrid[x],doorgrid[x],floorgrid[x]={},{},{}
  for y=0,127 do
   wallgrid[x][y],doorgrid[x][y],floorgrid[x][y]=0,nil,0
  end
 end
 
 -- Init objgrid (27x27 for 128/5 spatial partitioning)
 for gx=0,27 do
  objgrid[gx+1]={}
  for gy=0,27 do objgrid[gx+1][gy+1]={} end
 end
 
 -- Init zbuf/tbuf
 for i=1,num_rays do
  zbuf[i]=999
  tbuf[i]=tbuf[i] or {tile=0,tx=0}
 end
 
 -- Player
 player={x=64,y=64,a=0,spd=0.08,keys={},hp=10}
 
 generate_dungeon()
 printh("engine init complete")
end

--=======================
-- Update
--=======================
function _update()
 framect+=1
 timer+=1/30
 
 update_player()
 update_doors()
 update_enemies()
 update_collectables()
 update_particles()
end

--=======================
-- Draw
--=======================
function _draw()
 cls(0)
 camera(0,0)
 clip(0,0,screen_w,screen_h)
 
 draw_3d_view()
 draw_hud()
 draw_minimap()
end

--=======================
-- HUD
--=======================
function draw_hud()
 print("hp:"..player.hp,2,2,7)
 print("fps:"..stat(7),2,10,7)
 print("enemies:"..levelenem.."/"..totalenem,2,18,7)
end

--=======================
-- Raycasting
--=======================
function raycast(px,py,dx,dy,sa,ca)
 -- DDA from reference
 if not sa then sa,ca=dx,dy end
 if abs(dx)<0.01 then dx=0.01 end
 if abs(dy)<0.01 then dy=0.01 end
 
 local hx,hy,hdx,hdy=px,py,sgn(dx),dy/abs(dx)
 local hdz,hz=hdx*sa+hdy*ca,0
 local hstep=hx%1
 if hdx>0 then hstep=1-hstep end
 hx,hy,hz=hx+hdx*hstep,hy+hdy*hstep,hz+hdz*hstep
 if hdx<0 then hx-=1 end
 
 local vx,vy,vdx,vdy=px,py,dx/abs(dy),sgn(dy)
 local vdz,vz=vdx*sa+vdy*ca,0
 local vstep=vy%1
 if vdy>0 then vstep=1-vstep end
 vx,vy,vz=vx+vdx*vstep,vy+vdy*vstep,vz+vdz*vstep
 if vdy<0 then vy-=1 end
 
 for i=1,max_ray_steps do
  if hz<vz then
   local m=get_wall(flr(hx),flr(hy))
   if m>0 then
    if m==door_normal or m==door_locked then
     local door=doorgrid[flr(hx)][flr(hy)]
     if door and type(door)=="table" and door.open then
      local dz=hz+hdz/2
      if dz<vz then
       local dy_offset=(hy+hdy/2)%1-door.open
       if dy_offset>=0 then return dz,hx,hy,m,dy_offset end
      end
     end
    else
     return hz,hx,hy,m,(hy*hdx)%1
    end
   end
   hx,hy,hz=hx+hdx,hy+hdy,hz+hdz
  else
   local m=get_wall(flr(vx),flr(vy))
   if m>0 then
    if m==door_normal or m==door_locked then
     local door=doorgrid[flr(vx)][flr(vy)]
     if door and type(door)=="table" and door.open then
      local dz=vz+vdz/2
      if dz<hz then
       local dx_offset=(vx+vdx/2)%1-door.open
       if dx_offset>=0 then return dz,vx,vy,m,dx_offset end
      end
     end
    else
     return vz,vx,vy,m,(vx*-vdy)%1
    end
   end
   vx,vy,vz=vx+vdx,vy+vdy,vz+vdz
  end
 end
 return 999,px,py,0,0
end

function raycastwalls()
 -- Cast rays and populate zbuf/tbuf (CRITICAL: must be called every frame before rendering)
 -- Coordinate system: angle 0 = facing +Y, forward = (sin(a), cos(a))
 sa,ca=sin(player.a),cos(player.a)
 minx,miny,maxx,maxy,maxz=999,999,-999,-999,0
 for i=0,num_rays-1 do
  -- Screen x offset from center, depth projection distance
  local dx,dy=cx-i,sdist
  -- Rotate ray direction to world space
  dx,dy=ca*dx+sa*dy,ca*dy-sa*dx
  local z,mx,my,tile,tx=raycast(player.x,player.y,dx,dy,sa,ca)
  -- Use perpendicular camera depth returned from raycast directly (no extra cos correction)
  if tile>0 and z>0 and z<999 then
   zbuf[i+1]=z
   maxz=max(maxz,z)
  else
   zbuf[i+1]=999
  end
  local t=tbuf[i+1]
  t.tile=tile
  t.tx=tx
  minx,maxx=min(minx,mx),max(maxx,mx)
  miny,maxy=min(miny,my),max(maxy,my)
 end
end

--=======================
-- Rendering
--=======================
function draw_3d_view()
 -- CRITICAL FIX: Call raycastwalls to populate zbuf/tbuf before rendering
 raycastwalls()
 
 -- Ceiling/floor with fog bands
 local h=sdist/max(maxz,0.1)
 local y0,y1=max(0,flr(cy-h/2)),min(screen_h-1,ceil(cy+h/2))
 
 -- Ceiling (solid color placeholder)
 if y0>0 then
  rectfill(0,0,screen_w-1,y0,col_ceiling)
 end
 
 -- Floor (solid color placeholder)
 if y1<screen_h-1 then
  rectfill(0,y1,screen_w-1,screen_h-1,col_floor)
 end
 
 -- Walls (per-column with fog)
 for x=0,num_rays-1 do
  local z,t=zbuf[x+1],tbuf[x+1]
  if z<999 and t.tile>0 then
   local h=sdist/max(z,0.1)
   local y0,y1=cy-h/2,cy+h/2
   y0,y1=max(0,flr(y0)),min(screen_h-1,ceil(y1))
   
   -- Determine wall color
   local col=col_wall_base
   if t.tile==door_normal then col=col_door_normal
   elseif t.tile==door_locked then col=col_door_locked
   elseif t.tile%2==0 then col=col_wall_var
   end
   
   -- Apply fog via palette darkening
   if z>fogdist*0.5 then
    col=1 -- dark gray at distance
   elseif z>fogdist*0.3 then
    col=5 -- medium gray
   end
   
   if y1>y0 then
    rectfill(x,y0,x,y1,col)
   end
  end
 end
 
 -- Sprites (objects)
 draw_sprites()
 
 -- Reset transparency state
 palt()
end

function draw_sprites()
 local sobj=transform_objects()
 for ob in all(sobj) do
  local t,x,z=ob.typ,ob.rel[1],ob.rel[2]
  if t then
   local w,y=t.w or 0.5,ob.y or (t.y or 0.5)
   local f=sdist/max(z,0.1)
  local sx,sy,sw,sh=x*f+cx,y*f+cy,w*f,(t.h or 1)*f
  local x0,x1,y0,y1=max(0,flr(sx-sw/2)),min(screen_w-1,ceil(sx+sw/2)),max(0,flr(sy-sh/2)),min(screen_h-1,ceil(sy+sh/2))
   
   -- Determine sprite color
   local col=col_prop
   if ob.enem then col=col_enemy
   elseif ob.collectable then col=col_pickup
   elseif ob.proj then col=col_projectile
   end
   
   -- Z-buffer occlusion per column
   for sx=x0,x1 do
    if z<zbuf[sx+1] then
     rectfill(sx,y0,sx,y1,col)
    end
   end
  end
 end
end

function transform_objects()
 -- Transform world objects to camera space using inverse rotation
 local sa,ca=sin(player.a),cos(player.a)
 local sobj={}
 for gx=flr(minx/objgridsize),flr(maxx/objgridsize) do
  for gy=flr(miny/objgridsize),flr(maxy/objgridsize) do
   if gx>=0 and gx<=27 and gy>=0 and gy<=27 then
    for ob in all(objgrid[gx+1][gy+1]) do
     if ob.pos and ob.typ then
      -- Get object position relative to player
      local rx,ry=ob.pos[1]-player.x,ob.pos[2]-player.y
      -- Apply inverse rotation to transform to camera space
      -- rel[1] = screen X (left/right), rel[2] = depth (forward)
      ob.rel={ca*rx-sa*ry,sa*rx+ca*ry}
      local w=ob.typ.w or 0.5
      if ob.rel[2]>=w/2 and ob.rel[2]<maxz then
       ob.sortorder=ob.rel[2]
       add(sobj,ob)
      end
     end
    end
   end
  end
 end
 -- Insertion sort by distance
 for i=2,#sobj do
  local ob,j=sobj[i],i
  while j>1 and sobj[j-1].sortorder<ob.sortorder do
   sobj[j],j=sobj[j-1],j-1
  end
  sobj[j]=ob
 end
 return sobj
end

--=======================
-- Door System
--=======================
function update_doors()
 for door in all(doors) do
  if door.opening then
   door.open+=0.06
   if door.open>=1 then
    door.open,door.opening,door.timer=1,false,90
   end
  else
   if door.timer>0 then door.timer-=1
   elseif door.dtype~=3 then door.open=max(0,door.open-0.06)
   end
  end
 end
end

--=======================
-- Player
--=======================
function update_player()
 if player.hp<=0 then return end
 
 local sa,ca=sin(player.a),cos(player.a)
 
 -- Rotation (btn 0=left, 1=right)
 if btn(0) then player.a-=0.015 end
 if btn(1) then player.a+=0.015 end
 
 -- Movement (btn 2=up, 3=down)
 -- Forward movement: move in direction of (sin(a), cos(a))
 if btn(2) then
  local nx,ny=player.x+sa*player.spd,player.y+ca*player.spd
  trymoveto(player,nx,ny,0.15,true)
 end
 if btn(3) then
  local nx,ny=player.x-sa*player.spd,player.y-ca*player.spd
  trymoveto(player,nx,ny,0.15,true)
 end
end

--=======================
-- Collision
--=======================
function trymoveto(pl,nx,ny,radius,opendoors)
 local col,colobj=iscol(nx,ny,radius,opendoors,pl==player)
 if not col then
  pl.x,pl.y=nx,ny
  return true
 end
 if colobj and colobj.enem and pl==player then
  on_combat_trigger(colobj.enem)
 end
 local colx=select(1,iscol(nx,pl.y,radius,opendoors,pl==player))
 if abs(pl.x-nx)>0.01 and not colx then
  pl.x=nx
  return true
 end
 local coly=select(1,iscol(pl.x,ny,radius,opendoors,pl==player))
 if abs(pl.y-ny)>0.01 and not coly then
  pl.y=ny
  return true
 end
 return false
end

function iscol(px,py,radius,opendoors,isplayer)
 for x=flr(px-radius),flr(px+radius) do
  for y=flr(py-radius),flr(py+radius) do
   if x<0 or x>=128 or y<0 or y>=128 then return true end
   local tile=wallgrid[x][y]
   if tile>0 then
    if tile==door_normal or tile==door_locked then
     local door=doorgrid[x][y]
     if door and door.open<1 then
      if door.keynum and isplayer then
       -- consume matching key if player has it
       for i,k in ipairs(player.keys or {}) do
        if k==door.keynum then
         deli(player.keys,i)
         door.keynum=nil
         break
        end
       end
      end
      if not door.keynum and opendoors then door.opening=true end
      return true
     end
    else
     if tile==exit_tile and isplayer then
      gamestate="won"
      printh("level complete")
     end
     return true
    end
   end
  end
 end
 -- object collisions (solid objects)
 for gx=flr((px-radius)/objgridsize),flr((px+radius)/objgridsize) do
  for gy=flr((py-radius)/objgridsize),flr((py+radius)/objgridsize) do
   if gx>=0 and gx<=27 and gy>=0 and gy<=27 then
    for ob in all(objgrid[gx+1][gy+1]) do
     if ob.typ and ob.typ.solid then
      if max(abs(ob.pos[1]-px),abs(ob.pos[2]-py))<radius*2 then
       return true,ob
      end
     end
    end
   end
  end
 end
 return false
end

function get_wall(x,y)
 if x>=0 and x<128 and y>=0 and y<128 then return wallgrid[x][y] or 0 end
 -- Out-of-bounds returns normal wall (not door ID) to prevent crash when rays point outside map
 return col_wall_base
end

--=======================
-- Objects
--=======================
function spawnobject(typ,x,y,h)
 local ob={pos={x,y},y=h,typ=typ,rel={0,0},frame=0}
 addobject(ob)
 return ob
end

function addobject(ob)
 local gx,gy=flr(ob.pos[1]/objgridsize),flr(ob.pos[2]/objgridsize)
 if gx>=0 and gx<=27 and gy>=0 and gy<=27 then
  add(objgrid[gx+1][gy+1],ob)
 end
end

function removeobject(ob)
 local gx,gy=flr(ob.pos[1]/objgridsize),flr(ob.pos[2]/objgridsize)
 if gx>=0 and gx<=27 and gy>=0 and gy<=27 then
  del(objgrid[gx+1][gy+1],ob)
 end
end

--=======================
-- Enemies
--=======================
function spawnenemy(etyp,x,y)
 local ob=spawnobject(etyp.objtyp,x,y)
 ob.enem={etyp=etyp,obj=ob,hp=etyp.hp,state="ina",wp={x,y}}
 add(enem,ob.enem)
 totalenem+=1
 return ob.enem
end

function update_enemies()
 local px,py=player.x,player.y
 for e in all(enem) do
  local t,x,y=e.etyp,e.obj.pos[1],e.obj.pos[2]
  if e.state=="ina" and max(abs(x-px),abs(y-py))<=t.pdist then
   e.state="adv"
  elseif e.state=="adv" then
   local dx,dy=px-x,py-y
   local d=sqrt(dx*dx+dy*dy)
   if d>=t.spd then
    local nx,ny=x+dx/d*t.spd,y+dy/d*t.spd
    removeobject(e.obj)
    if not iscol(nx,ny,t.crad,t.opendoors,false) then
     e.obj.pos[1],e.obj.pos[2]=nx,ny
    end
    addobject(e.obj)
   end
  end
 end
end

function hurtenemy(e,dmg)
 e.hp-=dmg
 if e.hp<=0 then
  removeobject(e.obj)
  del(enem,e)
  levelenem+=1
 end
end

function hurtplayer(dmg)
 player.hp=max(0,player.hp-dmg)
 if player.hp==0 then printh("player died") end
end

--=======================
-- Combat hook (to be implemented by higher-level game mode)
function on_combat_trigger(enemy)
 printh("combat trigger: "..(enemy.etyp and enemy.etyp.name or "enemy"))
end

--=======================
-- Particles (stub)
--=======================
function update_particles()
 -- Placeholder for particle system
end

--=======================
-- Dungeon Generator (Full BSP System)
--=======================

-- Generation state
genrects,gennodes,geninv,genkeynum={},{},{},0
genparams={}

themes={
 dungeon={
  minrooms=5,maxrooms=10,
  minsize=3,maxsize=8,
  spacing=2,
  walltex=col_wall_base,
  cortex=col_wall_var,
  roomdoortypes={0,0.5,1},
  corridoortype=col_wall_base,
  fogdist=40
 }
}

function generate_dungeon()
 -- Clear
 for x=0,127 do
  for y=0,127 do
   wallgrid[x][y],floorgrid[x][y]=0,0
  end
 end
 
 -- Generation parameters
 genparams=tblcopy(themes.dungeon)
 fogdist=genparams.fogdist or fogdist
 
 genrects,gennodes,geninv,genkeynum={},{},{},0
 
 -- Boundary
 for x=0,127 do
  wallgrid[x][0],wallgrid[x][127]=col_wall_base,col_wall_base
 end
 for y=0,127 do
  wallgrid[0][y],wallgrid[127][y]=col_wall_base,col_wall_base
 end
 
 -- Fill with corridor texture
 for x=1,126 do
  for y=1,126 do
   wallgrid[x][y]=genparams.cortex
  end
 end
 
 -- Generate rooms
 local firstroom=addroom(randomroom(nil))
 genparams.startroom=firstroom
 
 local roomct=rndrng(genparams.minrooms,genparams.maxrooms)
 for i=1,roomct-1 do
  for j=1,100 do
   if trygenerateroom() then break end
  end
 end
 
 -- Place walls around rooms
 for node in all(gennodes) do
  if node.w>1 then
   rectwalls(node.r,genparams.walltex)
  end
 end
 
 -- Gameplay phase: exit, erosion, locked door + key, health
 finalize_dungeon_gameplay()
 
 -- Spawn enemies
 for i=1,5 do
  local room=gennodes[flr(rnd(#gennodes))+1]
  if room and room~=genparams.startroom then
   local x,y=findspawnpt(room)
   if x then
    spawnenemy(etyps[flr(rnd(#etyps))+1],x,y)
   end
  end
 end
 
 -- Place player in start room
 if genparams.startroom then
  local x,y=findspawnpt(genparams.startroom)
  if x then
   player.x,player.y=x,y
  end
 end
end

function rndrng(a,b)
 return a+flr(rnd(b-a))
end

function randomroom(node)
 local doorgen=rnd(genparams.roomdoortypes)
 local w,h=rndrng(genparams.minsize,genparams.maxsize),rndrng(genparams.minsize,genparams.maxsize)
 local x0,y0
 
 if node then
  local xspacing=genparams.spacing+w/2+node.w/2
  local yspacing=genparams.spacing+h/2+node.h/2
  x0=flr(node.midx+rndrng(-xspacing,xspacing)-w/2)
  y0=flr(node.midy+rndrng(-yspacing,yspacing)-h/2)
 else
  x0,y0=flr(rnd(124-w))+3,flr(rnd(124-h))+3
 end
 
 return {x0,y0,x0+w,y0+h,true,true},doorgen
end

function trygenerateroom()
 -- Choose base room
 local node=gennodes[flr(rnd(#gennodes))+1]
 if not node then return false end
 local nr=node.r
 
 -- Attempt to place room nearby
 local r,doorgen=randomroom(node)
 
 -- Bounds check
 if r[1]<3 or r[2]<3 or r[3]>126 or r[4]>126 then return false end
 if rectoverlaps(r) then return false end
 
 -- Generate corridor
 local door1,door2
 local c={}
 
 if rectsoverlaph(nr,r) then
  local cr={max(nr[1],r[1]),min(nr[4],r[4]),min(nr[3],r[3]),max(nr[2],r[2]),true,false}
  local x=rndrng(cr[1],cr[3])
  cr[1],cr[3]=x,x+1
  add(c,cr)
  door1,door2={x,cr[2]},{x,cr[4]-1}
 elseif rectsoverlapv(nr,r) then
  local cr={min(nr[3],r[3]),max(nr[2],r[2]),max(nr[1],r[1]),min(nr[4],r[4]),false,true}
  local y=rndrng(cr[2],cr[4])
  cr[2],cr[4]=y,y+1
  add(c,cr)
  door1,door2={cr[1],y},{cr[3]-1,y}
 else
  -- L-shaped corridor
  local a,b=nr,r
  local x,y=rndrng(a[1],a[3]),rndrng(b[2],b[4])
  local x0,y0,x1,y1
  
  if b[1]<a[1] then
   x0,x1,door2=b[3],x,{b[3],y}
  else
   x0,x1,door2=x,b[1],{b[1]-1,y}
  end
  
  if b[2]<a[2] then
   y0,y1,door1=y,a[2],{x,a[2]-1}
  else
   y0,y1,door1=a[4],y,{x,a[4]}
  end
  
  add(c,{x0,y,x1,y+1,false,true})
  add(c,{x,y0,x+1,y1,true,false})
 end
 
 -- Check corridor overlaps
 for cr in all(c) do
  if anyrectoverlaps({cr},nr) then return false end
 end
 
 -- Create room
 local newnode=addroom(r,doorgen)
 
 -- Create corridors
 for cr in all(c) do
  fillrect(cr,0)
  add(genrects,cr)
 end
 
 -- Create doors and door slots for edges
 local doorslot1,doorslot2
 if door1 then
  doorslot1={pos=door1}
  if rnd(1)<doorgen then
   doorslot1.door=makedoor(door1[1],door1[2],door_normal)
  else
   wallgrid[door1[1]][door1[2]]=0
   doorgrid[door1[1]][door1[2]]=true
  end
 end
 if door2 and (not door1 or door1[1]~=door2[1] or door1[2]~=door2[2]) then
  doorslot2={pos=door2}
  if rnd(1)<doorgen then
   doorslot2.door=makedoor(door2[1],door2[2],door_normal)
  else
   wallgrid[door2[1]][door2[2]]=0
   doorgrid[door2[1]][door2[2]]=true
  end
 else
  doorslot2=doorslot1
 end
 
 -- Edge graph like reference
 if rectsoverlaph(nr,r)==false and rectsoverlapv(nr,r)==false then
  -- L junction: create junction node and split into two edges
  local jx=flr((nr[1]+nr[3]+r[1]+r[3])/4)
  local jy=flr((nr[2]+nr[4]+r[2]+r[4])/4)
  local jnode=addroom({jx,jy,jx+1,jy+1,true,true},0)
  jnode.isjunction=true
  local e1={nodes={node,jnode},doorslots={doorslot1}}
  local e2={nodes={jnode,newnode},doorslots={doorslot2}}
  add(node.edges,e1) add(jnode.edges,e1)
  add(jnode.edges,e2) add(newnode.edges,e2)
 else
  local e={nodes={node,newnode},doorslots={doorslot1,doorslot2}}
  add(node.edges,e) add(newnode.edges,e)
 end
 
 return newnode.w>1
end

function addroom(r,doorgen)
 fillrect(r,0)
 add(genrects,r)
 
 local node={
  idx=#gennodes+1,
  r=r,
  w=r[3]-r[1],
  h=r[4]-r[2],
  edges={},
  midx=(r[1]+r[3])/2,
  midy=(r[2]+r[4])/2,
  doorgen=doorgen or 0
 }
 add(gennodes,node)
 return node
end

function fillrect(r,v)
 for y=r[2],r[4]-1 do
  for x=r[1],r[3]-1 do
   wallgrid[x][y]=v
   floorgrid[x][y]=v==0 and 1 or 0
  end
 end
end

function rectwalls(r,v)
 for x=r[1]-1,r[3] do
  setwall(x,r[2]-1,v)
  setwall(x,r[4],v)
 end
 for y=r[2]-1,r[4] do
  setwall(r[1]-1,y,v)
  setwall(r[3],y,v)
 end
end

function setwall(x,y,v)
 if x>=0 and x<128 and y>=0 and y<128 then
  local m=wallgrid[x][y]
  if m>4 or m==0 then wallgrid[x][y]=v end
 end
end

function rectoverlaps(r,ignore)
 if rectoverlapsinternal({r[1]-1,r[2],r[3]+1,r[4]},ignore) then return true end
 if rectoverlapsinternal({r[1],r[2]-1,r[3],r[4]+1},ignore) then return true end
 return rectoverlapsinternal(r,ignore)
end

function rectoverlapsinternal(r,ignore)
 for gr in all(genrects) do
  if gr~=ignore and rectsoverlap(r,gr) then return true end
 end
 return false
end

function rectsoverlap(a,b)
 return rectsoverlaph(a,b) and rectsoverlapv(a,b)
end

function rectsoverlaph(a,b)
 return a[3]>b[1] and b[3]>a[1]
end

function rectsoverlapv(a,b)
 return a[4]>b[2] and b[4]>a[2]
end

function anyrectoverlaps(rarray,ignore)
 for r in all(rarray) do
  if rectoverlaps(r,ignore) then return true end
 end
 return false
end

function makedoor(x,y,t)
 local door={x=x,y=y,open=0,opening=false,dtype=t,timer=0}
 add(doors,door)
 wallgrid[x][y]=t
 doorgrid[x][y]=door
 return door
end

function getwallpt(r)
 if rnd(2)>=1 then
  return rndrng(r[1],r[3]),rnd({r[2]-1,r[4]})
 else
  return rnd({r[1]-1,r[3]}),rndrng(r[2],r[4])
 end
end

function isclearwallpt(px,py,r)
 local m=wallgrid[px][py]
 if m<5 and m>0 then return false end
 for x=px-1,px+1 do
  for y=py-1,py+1 do
   local m=wallgrid[x][y]
   if m>0 and m<5 then return false end
   if m==0 and not isinrect(r,x,y) then return false end
  end
 end
 return true
end

--=======================
-- Gameplay Phase (keys/locks/exit/erosion/items)
--=======================
function finalize_dungeon_gameplay()
 -- ensure startroom exists
 if not genparams.startroom and #gennodes>0 then
  genparams.startroom=gennodes[1]
 end
 
 -- choose exit room distinct from start
 local exitroom
 if #gennodes>1 then
  repeat
   exitroom=gennodes[flr(rnd(#gennodes))+1]
  until exitroom~=genparams.startroom
 else
  exitroom=gennodes[1]
 end
 -- place exit on wall and mark on doorgrid for visibility
 local ex,ey=getwallpt(exitroom.r)
 if isclearwallpt(ex,ey,exitroom.r) then
  wallgrid[ex][ey]=exit_tile
  doorgrid[ex][ey]=true
 end
 
 -- erosion similar to reference, avoid doors and update floorgrid
 local function getwalltyp(x,y)
  if doorgrid[x] and doorgrid[x][y] then return "D" end
  local m=wallgrid[x][y]
  return m==0 and "E" or "W"
 end
 for i=1,200 do
  local x,y=flr(rnd(126))+1,flr(rnd(126))+1
  if not (doorgrid[x] and doorgrid[x][y]) then
   local mid=getwalltyp(x,y)
   local ct=0
   local prev=nil
   for ox=-1,1 do
    for oy=-1,1 do
     local nx,ny=x+ox,y+oy
     if not (ox==0 and oy==0) and nx>=1 and nx<=126 and ny>=1 and ny<=126 then
      local t=getwalltyp(nx,ny)
      if t=="D" then goto continue_neighbor end
      if t~=prev then ct+=1 prev=t end
     end
     ::continue_neighbor::
    end
   end
   if ct<=2 and mid~="D" then
    if mid=="E" then
     wallgrid[x][y]=genparams.cortex
     floorgrid[x][y]=0
    else
     wallgrid[x][y]=0
     floorgrid[x][y]=1
    end
   end
  end
 end
 
 -- compute accessible rooms and lock an edge (BFS-based)
 local genaccess=findaccessiblerooms(genparams.startroom)
 trylockdoor()
 
 -- spawn health pickups
 local hct=flr(#gennodes*0.4)
 for i=1,hct do
  local room=gennodes[flr(rnd(#gennodes))+1]
  local hx,hy=findspawnpt(room)
  if hx then
   local ob=spawnobject(otyps.heart,hx,hy)
   ob.collectable=true
   ob.hp=2
   add(collect,ob)
  end
 end
end

function findaccessiblerooms(startnode)
 local access,queue={},{}
 add(queue,startnode)
 while #queue>0 do
  local n=deli(queue,1)
  if not access[n] then
   access[n]=true
   for e in all(n.edges) do
    if not e.isblocked then
     local o=e.nodes[1]
     if o==n then o=e.nodes[2] end
     if not access[o] then add(queue,o) end
    end
   end
  end
 end
 return access
end

function trylockdoor(node)
 -- choose random node if not provided
 node=node or gennodes[flr(rnd(#gennodes))+1]
 if node.isjunction then return false end
 -- choose an unblocked edge
 local candidates={}
 for e in all(node.edges) do
  if not e.isblocked then add(candidates,e) end
 end
 if #candidates==0 then return false end
 local edge=candidates[flr(rnd(#candidates))+1]
 -- test blocking and evaluate access sets
 edge.isblocked=true
 local a1=findaccessiblerooms(edge.nodes[1])
 local a2=findaccessiblerooms(edge.nodes[2])
 edge.isblocked=false
 if not (a1[genparams.startroom] or a2[genparams.startroom]) then return false end
 -- choose a door slot to lock
 local slot
 if edge.doorslots and #edge.doorslots>0 then
  slot=edge.doorslots[flr(rnd(#edge.doorslots))+1]
 end
 if not slot then return false end
 local pos=slot.pos
 -- ensure a door exists
 local door=slot.door
 if not door then door=makedoor(pos[1],pos[2],door_normal) slot.door=door end
 -- lock it and drop key
 genkeynum+=1
 door.keynum=genkeynum
 wallgrid[pos[1]][pos[2]]=door_locked
 edge.isblocked=true
 -- drop key in any accessible room not startroom
 local room
 for i=1,50 do
  room=gennodes[flr(rnd(#gennodes))+1]
  if room and not room.isjunction and room~=genparams.startroom then break end
 end
 local kx,ky=findspawnpt(room)
 if kx then
  local ob=spawnobject(otyps.key,kx,ky)
  ob.collectable=true
  ob.keynum=genkeynum
  add(collect,ob)
 end
 return true
end

function isinrect(r,x,y)
 return x>=r[1] and x<r[3] and y>=r[2] and y<r[4]
end

function findspawnpt(room,c)
 c=c or 0
 local r=room.r
 for i=1,50 do
  local x,y=rndrng(r[1],r[3])+0.5,rndrng(r[2],r[4])+0.5
  if isclearspawnpt(x,y,c) then return x,y end
 end
end

function isclearspawnpt(x,y,c)
 c=c or 0
 for cx=x-c,x+c do
  for cy=y-c,y+c do
   if iscol(cx,cy,0.4,false,false) then return false end
  end
 end
 return true
end

--=======================
-- Minimap (stub)
--=======================
function draw_minimap()
 local mx,my,mw,mh=screen_w-120,10,110,110
 clip(mx,my,mw,mh)
 rectfill(mx,my,mx+mw-1,my+mh-1,0)
 local scale=1
 for x=max(0,flr(player.x-55)),min(127,flr(player.x+55)) do
  for y=max(0,flr(player.y-55)),min(127,flr(player.y+55)) do
   local sx,sy=mx+(x-player.x+55)*scale,my+(y-player.y+55)*scale
   local m=wallgrid[x][y]
   if m==door_normal then
    pset(sx,sy,col_door_normal)
   elseif m==door_locked then
    pset(sx,sy,col_door_locked)
   elseif m==exit_tile then
    pset(sx,sy,11)
   elseif m>0 then
    pset(sx,sy,5)
   elseif floorgrid[x][y]>0 then
    pset(sx,sy,6)
   end
  end
 end
 circfill(mx+mw/2,my+mh/2,2,10)
 -- Direction indicator aligned with movement: forward = (sin(a), cos(a))
 local sa,ca=sin(player.a),cos(player.a)
 line(mx+mw/2,my+mh/2,mx+mw/2+sa*6,my+mh/2+ca*6,10)
 rect(mx,my,mx+mw-1,my+mh-1,7)
 clip()
end

--=======================
-- Persistence (File-based for Picotron)
--=======================
function save_game_state()
 -- Save player and level state to file
 local data={
  levelnum=levelnum,
  hp=player.hp,
  staffi=player.staffi,
  totalenem=totalenem,
  levelenem=levelenem,
  timer=timer
 }
 
 -- In full implementation, use Picotron file I/O
 -- store("savedata.pod", data)
 -- For now, use printh for debugging
 printh("save: level="..levelnum.." hp="..player.hp)
end

function load_game_state()
 -- Load player and level state from file
 -- In full implementation: local data = fetch("savedata.pod")
 -- For now, return default
 return {levelnum=1,hp=10,staffi=1,totalenem=0,levelenem=0,timer=0}
end

--=======================
-- Collectables Update
--=======================
function update_collectables()
 if not collect then return end
 local px,py=player.x,player.y
 for ob in all(collect) do
  local dx,dy=ob.pos[1]-px,ob.pos[2]-py
  if dx*dx+dy*dy<0.5 then
   if ob.keynum then
    player.keys=player.keys or {}
    add(player.keys,ob.keynum)
    removeobject(ob)
    del(collect,ob)
   elseif ob.hp then
    player.hp=min(10,player.hp+ob.hp)
    removeobject(ob)
    del(collect,ob)
   end
  end
 end
end

--=======================
-- Immediate-Mode UI Framework (Full Port)
--=======================

-- Core UI Functions
function g_beg()
 -- Deactivate items
 for itm in all(itms) do
  itm.active=false
 end
 
 -- Reset state
 g_x,g_y,g_left,g_right,autonl=1,1,1,screen_w,true
 
 -- Reset regions
 local nextregions=regions
 regions,rstack={},{{0,g_left,g_right}}
 
 -- Tab stops and focus
 g_tabs,g_focus={},false
 
 -- Read mouse (Picotron input)
 local mx,my=stat(32),stat(33)
 g_mbp=g_mb
 g_mb=stat(34)~=0
 g_clk=(stat(34)==1 and not g_mbp) or btnp(5)
 
 if mx~=g_mx or my~=g_my then
  g_mx,g_my,g_mousemode=mx,my,true
 end
end

function g_end()
 -- Run coroutines
 for c in all(co) do
  if costatus(c)=="dead" then
   del(co,c)
  else
   coresume(c)
  end
 end
 
 -- Do scheduled tasks
 for fn in all(dolast) do fn() end
 dolast={}
 
 -- Remove inactive items
 for itm in all(itms) do
  if not itm.active then del(itms,itm) end
 end
 
 -- Keyboard navigation for tabs
 if not g_focus and #g_tabs>0 then
  local xd,yd=0,0
  if btnp(0) then xd-=1 end
  if btnp(1) then xd+=1 end
  if btnp(2) then yd-=1 end
  if btnp(3) then yd+=1 end
  
  if xd~=0 or yd~=0 then
   local n,nx,ny=32000,g_mx,g_my
   for t in all(g_tabs) do
    local dx,dy=t.x-g_mx,t.y-g_my
    local d=dx*dx+dy*dy
    if (xd~=0 and dx~=0 and sgn(dx)==sgn(xd) and abs(dy)<=abs(dx) and d<n) or
       (yd~=0 and dy~=0 and sgn(dy)==sgn(yd) and abs(dx)<=abs(dy) and d<n) then
     n,nx,ny=d,t.x,t.y
    end
   end
   g_mx,g_my,g_mousemode=nx,ny,false
  end
 end
end

function g_newline(h)
 g_x=g_left
 g_y+=(h or 10)
end

function g_makespc(w,h)
 if g_x+w>g_right and g_x>g_left then g_newline(h) end
end

function g_advance(w,h)
 if autonl then g_newline(h)
 else g_x+=w
 end
end

function g_gethover(w,h)
 return g_mx>=g_x and g_my>=g_y and g_mx<g_x+w and g_my<g_y+(h or 10)-1
end

function g_tabstop(w,h)
 if g_gethover(w,h) then
  add(g_tabs,{x=g_x+w-4,y=g_y+(h or 10)-4})
 end
end

function g_getitm(typ,props)
 for itm in all(itms) do
  if itm.x==g_x and itm.y==g_y and itm.typ==typ then
   itm.active=true
   return itm
  end
 end
 local itm={typ=typ,x=g_x,y=g_y,active=true}
 if props then
  for k,v in pairs(props) do itm[k]=v end
 end
 add(itms,itm)
 return itm
end

function g_btn(text,w)
 w=w or 10
 g_makespc(w,10)
 local itm=g_getitm("btn")
 local hover=g_gethover(w,10)
 g_tabstop(w,10)
 
 local clicked=false
 if hover and g_clk then
  itm.down=true
 elseif itm.down and not g_mb then
  itm.down=false
  clicked=hover
 end
 
 -- Draw
 local col=7
 if hover then col=10 end
 if hover and itm.down then col=7 end
 local textw=#text*4
 print(text,g_x+(w-textw)/2,g_y+2,col)
 
 g_advance(w,10)
 return clicked
end

function g_label(text,w,centered,col)
 w=w or 63
 col=col or 13
 g_makespc(w)
 local lx=g_x
 if centered then lx+=(w-#text*4)/2 end
 print(text,lx,g_y+2,col)
 g_advance(w)
end

function g_co(fn)
 add(co,cocreate(fn))
end

function g_msgbox(text,buttons,callbackfn)
 g_co(function()
  local result
  while not result do
   g_beg()
   
   -- Modal region (simplified, no map bg)
   rectfill(24,50,104,88,6)
   rect(24,50,104,88,5)
   
   g_x,g_y,g_left,g_right=26,52,26,102
   
   -- Text
   for t in all(text) do
    g_label(t,90)
    g_newline()
   end
   
   -- Buttons
   for b in all(buttons) do
    if g_btn(b,32) then result=b end
   end
   
   g_end()
   yield()
  end
  if callbackfn then callbackfn(result) end
 end)
end
