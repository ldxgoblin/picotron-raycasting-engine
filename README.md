# Picotron Raycast Engine

A high-performance 3D raycasting engine for Picotron featuring procedural dungeon generation, sprite rendering with z-buffer occlusion, animated doors, and spatial partitioning for efficient object management.

## Architecture Overview

### Core Systems
- **Raycasting Pipeline** (`raycast.lua`): DDA-based raycasting with 256-iteration limit, door animation support, and object hitscan
- **Rendering** (`render.lua`, `render_sprite.lua`): Wall/floor/ceiling rendering with incremental fog palette caching, sprite z-buffering with frustum culling
- **Door System** (`door_system.lua`): Animated sliding doors with configurable speed, auto-close delay, and lock/key mechanics
- **Dungeon Generation** (`dungeon_gen.lua`): Procedural BSP-based room generation with corridor carving, progression gating, and content spawning
- **Configuration** (`config.lua`): Centralized constants for screen dimensions, fog parameters, texture sets, object types, and gameplay tuning

### Data Structures
- **Map Layers**: 128×128 userdata grids for walls, doors, and floors with Lua table fallback
- **Spatial Partitioning**: 27×27 objgrid (5-unit cells) for efficient object queries
- **Animated Objects List**: Separate tracking for objects requiring per-frame animation updates (~96% reduction vs full grid iteration)

## Usage

### Controls
- **Arrow Keys**: Turn left/right, move forward/backward
- **E / Z Button**: Interact with objects (chests, shrines, notes, exits)
- **X**: Toggle minimap (2D top-down debug view)
- **Tab**: Toggle debug overlay (raycast diagnostics, floor/ceiling types)
- **V**: Toggle door test mode (when in 3D view)
- **C/D**: Cycle floor/ceiling types (debug) or adjust door test value

### Running
```lua
-- In Picotron console
load("picotron_raycast_engine/main.lua")
run()
```

## Asset Requirements

### Sprite Sheet (128×128 pixels)
- **Walls**: Tiles 1-16 (8×8 each, organized in 16-tile-wide grid)
- **Floors/Ceilings**: Tiles 0-9 (stone, dirt, sky, night sky)
- **Doors**: Tiles 64-66 (normal, locked, stay-open)
- **Exits**: Tiles 67-68 (start portal, end portal)
- **NPCs**: 16×40 pixel sprites (hostile/non-hostile)
- **Items**: 8×8 sprites (keys, hearts, generic pickups)
- **Decorations**: 8×16 sprites (torches, barrels, pillars)

See `ASSETS.md` for detailed sprite coordinate specifications.

## Known Limitations

### Performance
- Maximum 320 rays per frame (480px width)
- Fog palette updates: ~100-200 operations/frame (optimized from ~1000)
- Animation updates: ~10-30 objects/frame (optimized from 729 grid cells)

### Technical Constraints
- 128×128 map size (hardcoded)
- 27×27 objgrid (5-unit cells, covers 135×135 world space)
- 256 ray march iteration limit (diagonal coverage of 128×128 map)
- Door animation: 0.06 units/frame open speed, 90-frame close delay

### Rendering Quirks
- Floor texture layer unused by renderer (writes persist but no visual impact)
- Fog cache not reset on full palette clear (edge case when z≤0)
- Sprite z-buffer uses back-to-front sorting (insertion sort per frame)

## Module API Guide

### `config.lua`
Global constants for tuning:
- `screen_width`, `screen_height`, `ray_count`, `fov`
- `player_move_speed`, `player_rotation_speed`, `player_collision_radius`
- `door_anim_speed`, `door_close_delay`
- `interaction_range`, `combat_trigger_range`
- `obj_types`, `enemy_types`, `decoration_types`, `texsets`, `planetyps`

### `raycast.lua`
- `raycast(x, y, dx, dy, sa, ca)`: Cast single ray, returns `z, hx, hy, tile, tx`
- `raycast_scene()`: Cast all rays, populate `zbuf` and `tbuf`
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
  - Corridor carving with L-shaped junctions
  - Wall texture application and erosion
  - Door placement at boundaries
  - Progression loop (locked doors + key items)
  - NPC, item, and decoration spawning
- `find_spawn_point(rect)`: Collision-free object placement

### `main.lua`
- `_init()`: Initialize player, map layers, objgrid, generate first dungeon
- `_update()`: Input, door animations, object updates, interactions
- `_draw()`: Raycast scene, render pipeline, HUD, minimap
- `iscol(px, py, radius, opendoors, isplayer)`: Unified collision (walls + doors + objects)
- `trymoveto(pos, target_x, target_y, radius, opendoors, isplayer)`: Sliding collision
- `addobject(ob)` / `removeobject(ob)`: Objgrid management
- `check_interactions()`: Proximity-based triggers (pickups, combat, interactables)
- `handle_interact()`: Player-initiated E/Z interactions
- `draw_minimap()`: 2D debug view (scale=2, shows walls/rooms/doors/objects/player)

## Development Notes

### Memory Layout
- **Map Layers**: 128×128×2 bytes = 32KB per layer (walls, doors, floors = 96KB total)
- **Objgrid**: 27×27 tables with dynamic object references (~5-10KB runtime)
- **Z-buffer**: 320×4 bytes = 1.3KB
- **Animated Objects**: Dynamic list (~1KB, scales with object count)

### Performance Bottlenecks
1. **Sprite Sorting**: Insertion sort on visible objects (~10-50/frame)
2. **Fog Palette**: 64 comparisons per fog level change (~10-20/frame)
3. **Raycasting**: 320 rays × 256 max iterations = 81,920 worst-case steps/frame

### Extension Points
- Add texture variance via coordinate-based hashing (see memory: `Coordinate-Based Wall Texture Variation Rule`)
- Implement combat system (stub exists: `in_combat`, `current_target`, `update_combat()`)
- Expand interaction types (current: chest, shrine, trap, note, exit)
- Procedural boss rooms (dungeon gen supports special room sizing)
