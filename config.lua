-- engine configuration

-- screen constants
screen_width=320
screen_height=180
screen_center_x=160
screen_center_y=90
ray_count=320
sdist=200 -- default; computed dynamically in raycast_scene() based on fov
map_size=128
objgrid_size=5
objgrid_array_size=26
fov=0.5

-- fog configuration (optional enhancements)
fogdist=250 -- fog distance parameter for quadratic falloff (scaled from PICO-8's 100-150)
screenbright=1.0 -- screen brightness multiplier (1.0=normal, <1.0=darker for atmosphere)
use_quadratic_fog=false -- flag to enable/disable quadratic fog (default to simple linear fog)

-- ai and interaction constants
ai_update_rate=2 -- frames between AI updates
interaction_range=0.5 -- proximity for triggers
combat_trigger_range=0.3 -- distance to trigger combat

-- player movement constants
player_rotation_speed=0.02 -- radians per frame when turning
player_move_speed=0.1 -- units per frame when moving

-- door animation constants
door_anim_speed=0.06 -- door open/close speed per frame
door_close_delay=90 -- frames before door auto-closes

-- floor/ceiling types
planetyps={
 -- stone_tile
 {tex=0,scale=1,height=0.5,lit=true,xvel=0,yvel=0},
 -- dirt
 {tex=1,scale=1,height=0.5,lit=true,xvel=0,yvel=0},
 -- stone_ceiling
 {tex=2,scale=1,height=0.5,lit=false,xvel=0,yvel=0},
 -- sky
 {tex=8,scale=2,height=1,lit=false,xvel=0.01,yvel=0},
 -- night_sky
 {tex=9,scale=2,height=1,lit=false,xvel=0.005,yvel=0}
}

-- wall texture sets
texsets={
 -- none (for empty space)
 {base=0,variants={0}},
 -- brick
 {base=1,variants={1,2,3,4}},
 -- cobblestone
 {base=5,variants={5,6,7,8}},
 -- wood_plank
 {base=9,variants={9,10,11,12}},
 -- stone
 {base=13,variants={13,14,15,16}},
 -- grass (outdoor)
 {base=17,variants={17,18,19,20}},
 -- earth (outdoor)
 {base=21,variants={21,22,23,24}}
}

-- door types (tile IDs, must not overlap with floor 0)
door_normal=64
door_locked=65
door_stay_open=66

-- helper: check if tile is a door
function is_door(val)
 return val>=door_normal and val<=door_stay_open
end

-- exit types (tile IDs)
exit_start=67
exit_end=68

-- wall fill constant
wall_fill_tile=1

-- generation parameters
gen_params={
 min_rooms=5,
 max_rooms=15,
 min_size=4,
 max_size=12,
 spacing=2,
 corridor_texture=0,
 room_door_prob=0.3,
 erode_amount=50,
 difficulty=1,
 max_difficulty=9,
 max_enemies_per_room=8,
 max_decorations_per_room=12,
 npc_hostile_ratio=0.7,
 items_per_room=2,
 pickup_density=0.1
}

-- helper constants
max_spawn_attempts=50
max_room_attempts=100

-- door testing parameters
test_door_open=nil -- if set to a value 0.0-1.0, forces all doors to this open state for testing
test_door_x=nil -- if set, only affects door at this position
test_door_y=nil -- if set, only affects door at this position

-- object type definitions
obj_types={
 player={solid=true,w=0.4,mx=98,my=9,mw=8,mh=8,y=0.4,h=0.8,flat=false,lit=nil,framect=nil,animspd=nil,yoffs=nil,kind="player"},
 enemy={solid=true,w=0.4,mx=103,my=0,mw=16,mh=40,y=0.1,h=0.8,flat=false,lit=nil,framect=4,animspd=0.25,yoffs={0,-0.01,0,-0.01},kind="hostile_npc",ai_type="follow",follow_speed=0.05,follow_range=20,patrol_speed=0.03},
 item={solid=false,w=0.3,mx=80,my=0,mw=8,mh=8,y=0.4,h=0.2,flat=false,lit=nil,framect=nil,animspd=nil,yoffs=nil,kind="direct_pickup",subtype="generic"},
 key={solid=false,w=0.3,mx=98,my=10,mw=8,mh=8,y=0.4,h=0.2,flat=false,lit=nil,framect=nil,animspd=nil,yoffs=nil,kind="direct_pickup",subtype="key"},
 heart={solid=false,w=0.3,mx=88,my=0,mw=8,mh=8,y=0.4,h=0.2,flat=false,lit=nil,framect=2,animspd=0.1,yoffs={0,0.05},kind="direct_pickup",subtype="heart"},
 decoration={solid=false,w=0.3,mx=92,my=0,mw=8,mh=16,y=0.3,h=0.4,flat=false,lit=0,framect=4,animspd=0.25,yoffs=nil,kind="decorative"},
 hostile_npc={solid=true,w=0.4,mx=103,my=0,mw=16,mh=40,y=0.1,h=0.8,flat=false,lit=nil,framect=4,animspd=0.25,yoffs={0,-0.01,0,-0.01},kind="hostile_npc",ai_type="follow",follow_speed=0.05,follow_range=20,patrol_speed=0.03},
 non_hostile_npc={solid=false,w=0.4,mx=110,my=0,mw=16,mh=40,y=0.1,h=0.8,flat=false,lit=nil,framect=1,animspd=0,yoffs=nil,kind="non_hostile_npc"},
 direct_pickup={solid=false,w=0.2,mx=80,my=0,mw=8,mh=8,y=0.4,h=0.2,flat=false,lit=nil,framect=2,animspd=0.1,yoffs={0,0.05},kind="direct_pickup"},
 interactable_chest={solid=false,w=0.3,mx=85,my=0,mw=8,mh=8,y=0.3,h=0.3,flat=false,lit=nil,framect=1,animspd=0,yoffs=nil,kind="interactable",subtype="chest"},
 interactable_shrine={solid=false,w=0.4,mx=90,my=0,mw=8,mh=16,y=0.3,h=0.5,flat=false,lit=nil,framect=1,animspd=0,yoffs=nil,kind="interactable",subtype="shrine"},
 interactable_trap={solid=false,w=0.2,mx=95,my=0,mw=8,mh=8,y=0.4,h=0.1,flat=true,lit=nil,framect=1,animspd=0,yoffs=nil,kind="interactable",subtype="trap"},
 interactable_note={solid=false,w=0.3,mx=100,my=0,mw=8,mh=8,y=0.4,h=0.2,flat=true,lit=nil,framect=1,animspd=0,yoffs=nil,kind="interactable",subtype="note"},
 interactable_exit={solid=false,w=0.3,mx=100,my=0,mw=8,mh=8,y=0.4,h=0.2,flat=false,lit=nil,framect=1,animspd=0,yoffs=nil,kind="interactable",subtype="exit"}
}

-- enemy type definitions
enemy_types={
 {name="rat",difficulty=1,min_count=1,max_count=3,obj_type=obj_types.hostile_npc,sprite=1,hp=1},
 {name="bat",difficulty=2,min_count=1,max_count=4,obj_type=obj_types.hostile_npc,sprite=2,hp=1},
 {name="slime",difficulty=3,min_count=2,max_count=5,obj_type=obj_types.hostile_npc,sprite=3,hp=2},
 {name="skeleton",difficulty=4,min_count=1,max_count=3,obj_type=obj_types.hostile_npc,sprite=4,hp=3},
 {name="goblin",difficulty=5,min_count=2,max_count=4,obj_type=obj_types.hostile_npc,sprite=5,hp=3},
 {name="orc",difficulty=6,min_count=1,max_count=3,obj_type=obj_types.hostile_npc,sprite=6,hp=4},
 {name="troll",difficulty=7,min_count=1,max_count=2,obj_type=obj_types.hostile_npc,sprite=7,hp=5},
 {name="demon",difficulty=8,min_count=1,max_count=2,obj_type=obj_types.hostile_npc,sprite=8,hp=6},
 {name="dragon",difficulty=9,min_count=1,max_count=1,obj_type=obj_types.hostile_npc,sprite=9,hp=10}
}

-- decoration type definitions
decoration_types={
 {name="torch",difficulty=1,obj_type=obj_types.decoration,gen_tags={"lit","uni"},theme_tags={"dng","lit"},sprite=10},
 {name="barrel",difficulty=1,obj_type=obj_types.decoration,gen_tags={"uni"},theme_tags={"dng","house"},sprite=11},
 {name="crate",difficulty=1,obj_type=obj_types.decoration,gen_tags={"uni2"},theme_tags={"dng","house"},sprite=12},
 {name="pillar",difficulty=2,obj_type=obj_types.decoration,gen_tags={"big"},theme_tags={"dng","dem"},sprite=13},
 {name="statue",difficulty=3,obj_type=obj_types.decoration,gen_tags={"rare"},theme_tags={"dng","dem"},sprite=14},
 {name="chest",difficulty=2,obj_type=obj_types.decoration,gen_tags={"scatter"},theme_tags={"dng","house"},sprite=15},
 {name="tree",difficulty=1,obj_type=obj_types.decoration,gen_tags={"scatter"},theme_tags={"out"},sprite=16},
 {name="rock",difficulty=1,obj_type=obj_types.decoration,gen_tags={"uni"},theme_tags={"out"},sprite=17}
}

-- theme definitions
themes={
 dng={floor="stone_tile",roof="stone_ceiling",decor_prob=0.8},
 out={floor="dirt",roof="sky",decor_prob=0.5},
 dem={floor="stone_tile",roof="night_sky",decor_prob=0.9},
 house={floor="stone_tile",roof="stone_ceiling",decor_prob=0.7},
 dark={floor="stone_tile",roof="night_sky",decor_prob=0.6}
}

-- fog palettes (distance-based)
-- extended to support all 64 colors in Picotron
-- base colors 0-15 are remapped per fog level; colors 16-63 map to their fogged equivalents
pals={
 -- level 0: no fog
 {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63},
 -- level 1
 {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,5,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,5,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,5,48,49,50,51,52,53,54,5,56,57,58,59,60,61,62,5},
 -- level 2
 {0,1,2,3,4,5,6,7,8,9,10,11,12,13,5,5,16,17,18,19,20,21,22,23,24,25,26,27,28,29,5,5,32,33,34,35,36,37,38,39,40,41,42,43,44,45,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,61,5,5},
 -- level 3
 {0,1,2,3,4,5,6,7,8,9,10,11,12,5,5,5,16,17,18,19,20,21,22,23,24,25,26,27,28,5,5,5,32,33,34,35,36,37,38,39,40,41,42,43,44,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5},
 -- level 4
 {0,1,2,3,4,5,6,7,8,9,10,11,5,5,5,5,16,17,18,19,20,21,22,23,24,25,26,27,5,5,5,5,32,33,34,35,36,37,38,39,40,41,42,43,5,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5},
 -- level 5
 {0,1,2,3,4,5,6,7,8,9,10,5,5,5,5,5,16,17,18,19,20,21,22,23,24,25,26,5,5,5,5,5,32,33,34,35,36,37,38,39,40,41,42,5,5,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5},
 -- level 6
 {0,1,2,3,4,5,6,7,8,9,5,5,5,5,5,5,16,17,18,19,20,21,22,23,24,25,5,5,5,5,5,5,32,33,34,35,36,37,38,39,40,41,5,5,5,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5},
 -- level 7
 {0,1,2,3,4,5,6,7,8,5,5,5,5,5,5,5,16,17,18,19,20,21,22,23,24,5,5,5,5,5,5,5,32,33,34,35,36,37,38,39,40,5,5,5,5,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5},
 -- level 8
 {0,1,2,3,4,5,6,7,5,5,5,5,5,5,5,5,16,17,18,19,20,21,22,23,5,5,5,5,5,5,5,5,32,33,34,35,36,37,38,39,5,5,5,5,5,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5},
 -- level 9
 {0,1,2,3,4,5,6,5,5,5,5,5,5,5,5,5,16,17,18,19,20,21,5,5,5,5,5,5,5,5,5,5,32,33,34,35,36,37,5,5,5,5,5,5,5,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5},
 -- level 10
 {0,1,2,3,4,5,5,5,5,5,5,5,5,5,5,5,16,17,18,19,20,21,5,5,5,5,5,5,5,5,5,5,32,33,34,35,36,37,5,5,5,5,5,5,5,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5},
 -- level 11
 {0,1,2,3,4,5,5,5,5,5,5,5,5,5,5,5,16,17,18,19,20,21,5,5,5,5,5,5,5,5,5,5,32,33,34,35,36,37,5,5,5,5,5,5,5,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5},
 -- level 12
 {0,1,2,3,5,5,5,5,5,5,5,5,5,5,5,5,16,17,18,19,5,5,5,5,5,5,5,5,5,5,5,5,32,33,34,35,5,5,5,5,5,5,5,5,5,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5},
 -- level 13
 {0,1,2,5,5,5,5,5,5,5,5,5,5,5,5,5,16,17,18,5,5,5,5,5,5,5,5,5,5,5,5,5,32,33,34,5,5,5,5,5,5,5,5,5,5,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5},
 -- level 14
 {0,1,5,5,5,5,5,5,5,5,5,5,5,5,5,5,16,17,5,5,5,5,5,5,5,5,5,5,5,5,5,5,32,33,5,5,5,5,5,5,5,5,5,5,5,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5},
 -- level 15: maximum fog
 {0,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,16,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,32,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,48,49,50,51,52,53,54,5,56,57,58,59,60,5,5,5}
}
