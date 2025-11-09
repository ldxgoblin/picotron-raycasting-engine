# Picotron Raycast Engine

A high-performance 3D raycasting engine for Picotron featuring procedural dungeon generation, sprite rendering with z-buffer occlusion, animated doors, and spatial partitioning for efficient object management.

## Architecture Overview

### Core Systems
- **Raycasting Pipeline** (`raycast.lua`): DDA-based raycasting with 256-iteration limit, door animation support, and object hitscan
- **Rendering** (`render.lua`, `render_sprite.lua`): Wall/floor/ceiling rendering with incremental fog palette caching, sprite z-buffering with frustum culling
- **Floor System** (`main.lua`, `render.lua`, `dungeon_gen.lua`): Per-cell floor type data stored in `map.floors` userdata, accessed via `get_floor(x,y)` / `set_floor(x,y,val)`. The generator assigns a theme-specific floor ID early (before carving), corridors and rooms use that ID, and erosion writes floors when clearing walls. Floor rendering samples these per-cell types, and the minimap uses them to distinguish carved space from void.
- **Door System** (`door_system.lua`): Animated sliding doors with configurable speed, auto-close delay, and lock/key mechanics
- **Dungeon Generation** (`dungeon_gen.lua`): Procedural BSP-based room generation with corridor carving, theme-aware decoration spawning, progression gating, and content generation
- **Enemy AI** (`main.lua`): Rate-limited patrol and follow behaviors with Euclidean pathfinding and spatial partitioning sync
- **Theme System** (`config.lua`, `dungeon_gen.lua`): Context-aware environments with 5 themes (dungeon, outdoor, demon, house, dark) controlling textures, decorations, and atmosphere
- **Configuration** (`config.lua`): Centralized constants for screen dimensions, fog parameters, texture sets, object types, themes, and gameplay tuning

### Data Structures
- **Map Layers**: 128×128 userdata grids for walls, doors, and floors with Lua table fallback
- **Spatial Partitioning**: 27×27 objgrid (5-unit cells) for efficient object queries and AI movement updates
- **Animated Objects List**: Separate tracking for objects requiring per-frame animation updates (~96% reduction vs full grid iteration)
- **AI State**: Per-NPC patrol points, waypoint indices, and behavior types (patrol/follow) stored in object tables

## Usage

### Controls
- **Arrow Keys**: Turn left/right, move forward/backward
- **E / Z Button**: Interact with objects (chests, shrines, notes, exits)
- **X**: Toggle minimap (2D top-down debug view)
- **Tab**: Toggle debug overlay (raycast diagnostics, floor/ceiling types, theme)
- **V**: Toggle door test mode (when in 3D view)
- **C/D**: Cycle floor/ceiling types (debug) or adjust door test value

### Gameplay
- **Health**: Collect hearts (+20 HP, max 100), avoid traps (-10 HP)
- **Keys**: Unlock colored doors (auto-consumed on use)
- **NPCs**: Hostile enemies patrol rooms or follow player; non-hostile NPCs are passable
- **Floor Progression**: Use exit portals to advance difficulty (increases enemy count/types)

### Running
```lua
-- In Picotron console
load("picotron_raycast_engine/main.lua")
run()
```

## Asset Requirements

### Sprite Sheet (128×128 pixels)
- **Walls**: Tiles 1-24 (8×8 each, 7 texture sets: brick, cobblestone, wood, stone, grass, earth)
- **Floors/Ceilings**: Tiles 0-9 (stone, dirt, sky, night sky)
  - **Floor Textures**: Tiles 0-1 (8×8 each)
    - Tile 0: Stone tile floor (gray checkered pattern)
    - Tile 1: Dirt floor (brown speckled texture)
    - Additional floor types can be added by extending `planetyps` and updating texture indices
- **Doors**: Tiles 64-66 (normal, locked, stay-open)
- **Exits**: Tiles 67-68 (start portal, end portal)
- **NPCs**: 16×40 pixel sprites (hostile/non-hostile)
- **Items**: 8×8 sprites (keys, hearts, generic pickups)
- **Decorations**: 8×16 sprites (torches, barrels, crates, pillars, statues, trees, rocks)

See `ASSETS.md` for detailed sprite coordinate specifications.

## Known Limitations

### Performance
- 240 rays per frame (480px width with 2× column upscaling)
- Fog palette updates: ~100-200 operations/frame (optimized from ~1000)
- Animation updates: ~10-30 objects/frame (optimized from 729 grid cells)
- AI updates: Rate-limited to every 2 frames (configurable via `ai_update_rate`)
- Decoration density: Capped at 12 per room (configurable via `max_decorations_per_room`)

### Technical Constraints
- 128×128 map size (hardcoded)
- 27×27 objgrid (5-unit cells, covers 135×135 world space)
- 256 ray march iteration limit (diagonal coverage of 128×128 map)
- Door animation: 0.06 units/frame open speed, 90-frame close delay
- AI pathfinding: Simple direct movement with collision sliding (no A* or nav meshes)
- Theme assignment: Random per floor (70% dungeon, 20% outdoor, 10% demon)
- Floor type system: Per-cell data sampled during rendering, currently supports 2 floor types (stone, dirt) and 3 ceiling types

### Rendering Quirks
- Pixel-centered ray offsets ensure even angular coverage with half-resolution rays and 2× upscaling
- Floor texture layer implemented: per-cell floor types sampled during rendering for visual variety
- Fog cache not reset on full palette clear (edge case when z≤0)
- Sprite z-buffer uses back-to-front sorting (insertion sort per frame)
- Non-hostile NPCs are non-solid (players can walk through them to prevent corridor blocking)

## Module API Guide

### `config.lua`
Global constants for tuning:
- `screen_width`, `screen_height`, `ray_count`, `fov`
- `player_move_speed`, `player_rotation_speed`, `player_collision_radius`
- `door_anim_speed`, `door_close_delay`
- `interaction_range`, `combat_trigger_range`, `ai_update_rate`
- `obj_types`, `enemy_types`, `decoration_types`, `texsets`, `planetyps`
- `themes`: 5 environment presets (dng, out, dem, house, dark) with floor/roof/decor_prob settings
- Extended `texsets`: 7 wall texture sets including grass and earth for outdoor themes

### `raycast.lua`
- `raycast(x, y, dx, dy, fx, fy)`: Cast a single ray. `dx,dy` are the world-space ray direction; `(fx,fy)` is the forward/depth axis used for perpendicular distance (camera forward uses `(cos(a),sin(a))`). Returns `z, hx, hy, tile, tx`.
- `raycast_scene()`: Cast all rays, populate `zbuf` and `tbuf`. Uses pixel-centered offsets so `ray_count` rays cover the full `screen_width`. Camera mapping is classic: `Right=(-sin(a),cos(a))`, `Forward=(cos(a),sin(a))`.
- `hitscan(x, y, dx, dy)`: Line-of-sight check for projectiles, returns `closest_obj, dist`

### `render.lua`
- `render_walls()`: Draw textured wall columns using `zbuf`/`tbuf`
- `render_floor_ceiling()`: Draw perspective floor/ceiling scanlines
- `set_fog(z)`: Apply distance-based palette mapping (incremental updates)
- `get_texture_source()`: Return sprite sheet userdata (fallback to empty 128×128 on missing)

### `render_sprite.lua`
- `render_sprites()`: Transform, cull, sort, and draw all visible objects
- `drawobjs(sobj, sa, ca, src)`: Draw sorted sprites with z-buffer occlusion

### `door_system.lua`
- `create_door(x, y, dtype, key_id)`: Spawn door in grid
- `update_doors()`: Animate all doors (opening/closing state machine)
- `remove_door(x, y)`: Delete door from grid

### `dungeon_gen.lua`
- `generate_dungeon()`: Full procedural generation pipeline
  - Room placement with BSP spatial partitioning
  - Theme assignment occurs before carving so a theme floor ID is available consistently
  - Theme-aware wall texture application via `theme_wall_texture(theme)`
  - Corridor carving with L-shaped junctions; straight corridors use door retry with fallback to passage to guarantee connectivity
  - Map erosion for organic feel; eroded clears write theme-consistent floor types
  - Door placement at boundaries (normal/locked progression gating)
  - Floor/ceiling type selection based on theme
  - Gameplay generation (NPCs, items, decorations)
- `generate_decorations()`: Theme-filtered decoration spawning
  - Supports gen_tags: `uni`, `uni2`, `scatter`, `big`, `rare`, `lit`
  - Respects theme_tags matching current theme
  - Per-room density cap via `max_decorations_per_room`
- `theme_wall_texture(theme)`: Maps themes to texture sets (outdoor→grass/earth, dungeon→brick/cobble, etc.)
- `find_spawn_point(rect)`: Collision-free object placement

### `main.lua`
- `_init()`: Initialize player, map layers, objgrid, frame counter, generate first dungeon
- `_update()`: Input, door animations, rate-limited AI updates, object animations, interactions
- `_draw()`: Raycast scene, render pipeline, HUD, minimap
- `set_floor(x, y, ftype)`: Set floor type at grid position in `map.floors` (ftype indexes into `planetyps`)
- `get_floor(x, y)`: Get floor type index from `map.floors`
- `update_npc_ai()`: Enemy AI update loop
  - **Patrol**: Cycles through waypoints, advances only when reached (dist < 0.1)
  - **Follow**: Moves toward player within follow_range using Euclidean distance
  - Updates spatial partitioning after movement via `update_object_grid()`
- `iscol(px, py, radius, opendoors, isplayer)`: Unified collision (walls + doors + objects)
- `trymoveto(pos, target_x, target_y, radius, opendoors, isplayer)`: Sliding collision for player (x/y fields)
- `trymoveto_pos(pos_array, target_x, target_y, radius, opendoors, isplayer)`: Sliding collision for NPCs (pos[1]/pos[2] arrays)
- `addobject(ob)` / `removeobject(ob)`: Objgrid management
- `update_object_grid(ob, old_x, old_y)`: Sync spatial partitioning after position change
- `check_interactions()`: Proximity-based triggers (pickups, combat, interactables)
- `handle_interact()`: Player-initiated E/Z interactions
- `draw_minimap()`: 2D debug view (scale=2, shows walls/rooms/doors/objects/player)

## Development Notes

### Memory Layout
- **Map Layers**: 128×128×2 bytes = 32KB per layer (walls, doors, floors = 96KB total)
- **Objgrid**: 27×27 tables with dynamic object references (~5-10KB runtime)
 - **Z-buffer**: 480 entries (matches `screen_width`; used for sprite occlusion)
- **Animated Objects**: Dynamic list (~1KB, scales with object count)

### Performance Bottlenecks
1. **Sprite Sorting**: Insertion sort on visible objects (~10-50/frame)
2. **Fog Palette**: 64 comparisons per fog level change (~10-20/frame)
3. **Raycasting**: 240 rays × 256 max iterations = 61,440 worst-case steps/frame
4. **AI Pathfinding**: Rate-limited to every 2 frames; uses Euclidean distance for follow behavior
5. **Decoration Generation**: Theme filtering + per-room density cap reduces excessive spawning

### Extension Points
- Add texture variance via coordinate-based hashing for per-wall variation within texture sets
- Implement combat system (stub exists: `in_combat`, `current_target`, `update_combat()`)
- Expand interaction types (current: chest, shrine, trap, note, exit)
- Procedural boss rooms (dungeon gen supports special room sizing)
- Additional themes (crypt, lava, ice) with unique decoration sets
- Advanced AI behaviors (flee, wander, guard) beyond patrol/follow
- Dynamic lighting based on decoration.lit property (currently unused by renderer)
