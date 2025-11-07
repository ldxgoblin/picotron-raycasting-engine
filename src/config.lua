--[[pod_format="raw",created="2025-11-07 21:17:14",modified="2025-11-07 21:48:05",revision=1]]
-- engine configuration

-- screen constants
screen_width=480
screen_height=270
screen_center_x=240
screen_center_y=135
ray_count=480
-- CRITICAL: screen_center_x must equal screen_width/2, screen_center_y must equal screen_height/2, ray_count must equal screen_width
sdist=200 -- default; computed dynamically in raycast_scene() based on fov
map_size=128
objgrid_size=5
objgrid_array_size=26
fov=0.5

-- sprite configuration
sprite_size=32

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

-- floor/ceiling types (tex indexes from gfx/1_surfaces.gfx, offset 32)
planetyps={
 -- stone_tile
 {tex=32,scale=1,height=0.5,lit=true,xvel=0,yvel=0},
 -- dirt
 {tex=33,scale=1,height=0.5,lit=true,xvel=0,yvel=0},
 -- stone_ceiling
 {tex=34,scale=1,height=0.5,lit=false,xvel=0,yvel=0},
 -- sky
 {tex=35,scale=2,height=1,lit=false,xvel=0.01,yvel=0},
 -- night_sky
 {tex=36,scale=2,height=1,lit=false,xvel=0.005,yvel=0}
}

-- wall texture sets (sprite indexes from gfx/0_walls.gfx)
texsets={
 -- none (removed to avoid collision with brick variant 0)
 -- brick
 {base=0,variants={0,1,2,3}},
 -- cobblestone
 {base=4,variants={4,5,6,7}},
 -- wood_plank
 {base=8,variants={8,9,10,11}},
 -- stone
 {base=12,variants={12,13,14,15}},
 -- grass (outdoor)
 {base=16,variants={16,17,18,19}},
 -- earth (outdoor)
 {base=20,variants={20,21,22,23}}
}

-- door types (sprite indexes from gfx/0_walls.gfx)
door_normal=24
door_locked=25
door_stay_open=26

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

-- object type definitions (mx=sprite index from gfx files, my deprecated, mw/mh use sprite_size)
-- NOTE: my=0 is deprecated and maintained for backward compatibility only; will be removed once rendering code migrates
obj_types={
 player={solid=true,w=0.4,mx=0,my=0,mw=sprite_size,mh=sprite_size,y=0.4,h=0.8,flat=false,lit=nil,framect=nil,animspd=nil,yoffs=nil,kind="player"},
 enemy={solid=true,w=0.4,mx=64,my=0,mw=sprite_size,mh=sprite_size,y=0.1,h=0.8,flat=false,lit=nil,framect=4,animspd=0.25,yoffs={0,-0.01,0,-0.01},kind="hostile_npc",ai_type="follow",follow_speed=0.05,follow_range=20,patrol_speed=0.03},
 item={solid=false,w=0.3,mx=128,my=0,mw=sprite_size,mh=sprite_size,y=0.4,h=0.2,flat=false,lit=nil,framect=nil,animspd=nil,yoffs=nil,kind="direct_pickup",subtype="generic"},
 key={solid=false,w=0.3,mx=129,my=0,mw=sprite_size,mh=sprite_size,y=0.4,h=0.2,flat=false,lit=nil,framect=nil,animspd=nil,yoffs=nil,kind="direct_pickup",subtype="key"},
 heart={solid=false,w=0.3,mx=130,my=0,mw=sprite_size,mh=sprite_size,y=0.4,h=0.2,flat=false,lit=nil,framect=2,animspd=0.1,yoffs={0,0.05},kind="direct_pickup",subtype="heart"},
 decoration={solid=false,w=0.3,mx=148,my=0,mw=sprite_size,mh=sprite_size,y=0.3,h=0.4,flat=false,lit=0,framect=4,animspd=0.25,yoffs=nil,kind="decorative"},
 hostile_npc={solid=true,w=0.4,mx=64,my=0,mw=sprite_size,mh=sprite_size,y=0.1,h=0.8,flat=false,lit=nil,framect=4,animspd=0.25,yoffs={0,-0.01,0,-0.01},kind="hostile_npc",ai_type="follow",follow_speed=0.05,follow_range=20,patrol_speed=0.03},
 non_hostile_npc={solid=false,w=0.4,mx=73,my=0,mw=sprite_size,mh=sprite_size,y=0.1,h=0.8,flat=false,lit=nil,framect=1,animspd=0,yoffs=nil,kind="non_hostile_npc"},
 direct_pickup={solid=false,w=0.2,mx=128,my=0,mw=sprite_size,mh=sprite_size,y=0.4,h=0.2,flat=false,lit=nil,framect=2,animspd=0.1,yoffs={0,0.05},kind="direct_pickup"},
 interactable_chest={solid=false,w=0.3,mx=131,my=0,mw=sprite_size,mh=sprite_size,y=0.3,h=0.3,flat=false,lit=nil,framect=1,animspd=0,yoffs=nil,kind="interactable",subtype="chest"},
 interactable_shrine={solid=false,w=0.4,mx=132,my=0,mw=sprite_size,mh=sprite_size,y=0.3,h=0.5,flat=false,lit=nil,framect=1,animspd=0,yoffs=nil,kind="interactable",subtype="shrine"},
 interactable_trap={solid=false,w=0.2,mx=133,my=0,mw=sprite_size,mh=sprite_size,y=0.4,h=0.1,flat=true,lit=nil,framect=1,animspd=0,yoffs=nil,kind="interactable",subtype="trap"},
 interactable_note={solid=false,w=0.3,mx=134,my=0,mw=sprite_size,mh=sprite_size,y=0.4,h=0.2,flat=true,lit=nil,framect=1,animspd=0,yoffs=nil,kind="interactable",subtype="note"},
 interactable_exit={solid=false,w=0.3,mx=135,my=0,mw=sprite_size,mh=sprite_size,y=0.4,h=0.2,flat=false,lit=nil,framect=1,animspd=0,yoffs=nil,kind="interactable",subtype="exit"}
}

-- enemy type definitions (sprite indexes from gfx/2_characters.gfx, offset 64)
enemy_types={
 {name="rat",difficulty=1,min_count=1,max_count=3,obj_type=obj_types.hostile_npc,sprite=64,hp=1},
 {name="bat",difficulty=2,min_count=1,max_count=4,obj_type=obj_types.hostile_npc,sprite=65,hp=1},
 {name="slime",difficulty=3,min_count=2,max_count=5,obj_type=obj_types.hostile_npc,sprite=66,hp=2},
 {name="skeleton",difficulty=4,min_count=1,max_count=3,obj_type=obj_types.hostile_npc,sprite=67,hp=3},
 {name="goblin",difficulty=5,min_count=2,max_count=4,obj_type=obj_types.hostile_npc,sprite=68,hp=3},
 {name="orc",difficulty=6,min_count=1,max_count=3,obj_type=obj_types.hostile_npc,sprite=69,hp=4},
 {name="troll",difficulty=7,min_count=1,max_count=2,obj_type=obj_types.hostile_npc,sprite=70,hp=5},
 {name="demon",difficulty=8,min_count=1,max_count=2,obj_type=obj_types.hostile_npc,sprite=71,hp=6},
 {name="dragon",difficulty=9,min_count=1,max_count=1,obj_type=obj_types.hostile_npc,sprite=72,hp=10}
}

-- decoration type definitions (sprite indexes from gfx/3_props.gfx, offset 148)
decoration_types={
 {name="torch",difficulty=1,obj_type=obj_types.decoration,gen_tags={"lit","uni"},theme_tags={"dng","lit"},sprite=148},
 {name="barrel",difficulty=1,obj_type=obj_types.decoration,gen_tags={"uni"},theme_tags={"dng","house"},sprite=149},
 {name="crate",difficulty=1,obj_type=obj_types.decoration,gen_tags={"uni2"},theme_tags={"dng","house"},sprite=150},
 {name="pillar",difficulty=2,obj_type=obj_types.decoration,gen_tags={"big"},theme_tags={"dng","dem"},sprite=151},
 {name="statue",difficulty=3,obj_type=obj_types.decoration,gen_tags={"rare"},theme_tags={"dng","dem"},sprite=152},
 {name="chest",difficulty=2,obj_type=obj_types.decoration,gen_tags={"scatter"},theme_tags={"dng","house"},sprite=153},
 {name="tree",difficulty=1,obj_type=obj_types.decoration,gen_tags={"scatter"},theme_tags={"out"},sprite=154},
 {name="rock",difficulty=1,obj_type=obj_types.decoration,gen_tags={"uni"},theme_tags={"out"},sprite=155}
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
