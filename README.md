                                                                 
░█▀█░█▀█░█▀█░█▀▄░█▀█░█░█
░█░█░█░█░█░█░█▀▄░█░█░░█░
░▀░▀░▀▀▀░▀░▀░▀▀░░▀▀▀░░▀░   

ダンジョンクロウラ
Picotron Engine

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Core Systems](#core-systems)
4. [Configuration](#configuration)
5. [Performance Characteristics](#performance-characteristics)
6. [File Structure](#file-structure)
7. [Technical Details](#technical-details)
8. [Development & Debugging](#development--debugging)

---

## Overview

The NONBOY ダンジョンクロウラ Engine aims to be a complete 3D game engine built on raycasting principles, optimized for Lexaloffle Picotron. Featuring:

- **Decoupled ray_count architecture** - Independent ray count from screen resolution for flexible performance tuning
- **Unified fog system** - Single linear fog model with 16 levels and hysteresis optimization
- **Advanced LOD** - Fog-driven level-of-detail for walls and sprites
- **Per-pixel depth buffer** - Accurate sprite occlusion at all ray counts
- **Frustum-based culling** - Geometric sprite culling independent of wall hits
- **Depth-bucket sorting** - O(n) sprite sorting with 16 depth buckets
- **Per-cell floor rendering** - Multi-texture floors with run detection and merging
- **Comprehensive diagnostics** - Real-time performance monitoring and logging
- **Batched rendering** - Batch tline3d calls for floors, walls, and sprites to minimize Lua call overhead
- **Allocation-free floor runs** - Preallocated userdata buffers for per-cell floor segmentation (no per-frame tables)
- **Optimized fog/z-buffer** - Display palette fog updates and single-pass z-buffer clear reduce per-frame cost

**Target Performance**: 50-60 FPS on typical scenes (128 rays, stride=2, LOD enabled)

---

## Architecture

### High-Level Data Flow

```mermaid
flowchart TD
  I[Initialization (_init)] --> U[Update Loop (_update)]
  U -->|Input| M[Movement & Collision]
  U -->|Doors| D[Door Updates]
  U -->|AI| A[AI (rate-limited)]
  U --> R[Render Loop (_draw)]
  R --> P[Precompute\n• Cache sin/cos • Compute spans • Clear zbuf]
  R --> RC[Raycast Phase (raycast_scene)\n• Cast rays • Fill ray_z/rbuf • Frustum AABB]
  R --> F[Floor/Ceiling\n• Stride rows • Per-cell floor runs • Unified fog]
  R --> W[Walls\n• Span-based • Per-pixel zbuf • LOD beyond 14.0 • U-interp]
  R --> S[Sprites\n• Frustum+objgrid cull • 16 depth buckets • Z-test • LOD]
  R --> H[HUD & Diagnostics\n• Stats • Prompts • Minimap • Single pal() restore]
  classDef box fill:#111,stroke:#666,color:#ddd;
  class I,U,R,P,RC,F,W,S,H,M,D,A box;
```

### Key Architectural Principles

1. **Single Source of Truth**: All configuration in `src/config.lua`
2. **Data-Driven**: No hardcoded constants; all systems read from config
3. **Lockstep Execution**: Clear input/output contracts between systems
4. **Performance Budgets**: Bounded worst-case work via DDA guards, LOD, stride
5. **Diagnostic-First**: Comprehensive instrumentation for data-driven optimization

---

## Core Systems

### 1. Raycasting System (`src/raycast.lua`)

**Purpose**: Cast rays into the world to determine visible geometry and depths.

The raycaster uses a guarded DDA with dual stepping and strict early-outs to bound work per ray. Per-ray screen spans are decoupled from resolution, and a geometric frustum AABB is computed independently of wall hits so sprite culling remains robust in open areas.

**Key Functions**:
- `raycast(x, y, dx, dy, fx, fy)` - DDA raycasting with door support
- `raycast_scene()` - Cast all rays, compute spans, build frustum AABB
- `compute_frustum_aabb()` - Geometric frustum for sprite culling
- `hitscan(x, y, dx, dy)` - Line-of-sight for projectiles/AI

**DDA Guards**:
1. **Far-plane check**: Early-out when `z > far_plane` (25.0 units)
2. **Irreversible OOB**: Detect rays moving away from map bounds
3. **Iteration cap**: Geometric limit based on remaining grid crossings
— What: Prevents unbounded DDA steps and off-map traversal.  
— How: Compare `min(hz, vz)` to `far_plane`, test step direction vs bounds, cap by crossings.  
— Why: Stabilizes frame time in worst-case layouts.

**Per-Ray Span Computation**:
```lua
ray_x0[i] = flr(i * screen_width / ray_count)
ray_x1[i] = max(ray_x0[i], flr((i+1) * screen_width / ray_count) - 1)
```
This decouples `ray_count` (128) from `screen_width` (480), allowing arbitrary ray counts.
— What: Assigns each ray a contiguous pixel span.  
— How: Proportional slicing ensures no gaps even when counts differ.  
— Why: Tunable performance independent of resolution.

**Frustum AABB**:
- Computes 4 frustum corners at `far_plane` distance
- Transforms to world space using camera basis
- Provides independent sprite culling bounds (not wall-hit-dependent)
— What: Geometry-only visibility bounds for sprites.  
— How: Build far-plane wedge; transform via camera basis.  
— Why: Keeps sprite culling valid when wall hits are sparse.

**Outputs**:
- `ray_z[0..127]` - Per-ray depths (999 = miss)
- `rbuf[0..127]` - Per-ray hit data (tile, tx)
- `ray_x0/x1[0..127]` - Per-ray screen spans
- `frustum_minx/maxx/miny/maxy` - Sprite culling AABB

---

### 2. Rendering System (`src/render.lua`)

**Purpose**: Transform raycast data into 3D visuals with fog, LOD, and per-pixel depth.

The renderer minimizes overdraw and state churn via hysteresis-driven fog, span-based wall writes to a per-pixel z-buffer, stride rendering for floors/ceilings, and solid-color impostors for distant geometry using cached average texture colors.

#### Batched Draw Submission

- Floors: Per-scanline tline3d calls are batched into a single submission using an f64 userdata buffer. Per-cell floor runs (when enabled) are also batched into one submit per scanline.
- Walls: Per-column wall draws in the “expensive path” are pushed into one batched tline3d submit per ray span.
- Sprites: Per-column sprite draws are batched into a single submit per sprite when visible columns are present.
— What: Collapse many draw calls into a single batched call per scanline/span/object.  
— Why: Dramatically reduces Lua call overhead while preserving visuals.

#### Allocation-Free Floor Runs

- Per-cell floor run segmentation uses preallocated userdata("i16") buffers for x0/x1/floor_id and merged runs to avoid per-frame table allocation and GC churn.
— What: Run detection without Lua table churn.  
— Why: Stabilizes frame time independent of scene density.

#### Unified Fog Manager

**Single Linear Formula**:
```lua
fog_level = flr(clamp((z - fog_near) / (fog_far - fog_near), 0, 1) * 15)
```
- 16 fog levels (0-15) mapping to `pals` array
- `fog_near=5.0`, `fog_far=20.0` from config
- Hysteresis: Only update when `z` changes by `fog_hysteresis` (0.5)
— What: Distance-based palette remap.  
— How: Compute level 0..15; apply only changed entries to reduce `pal()` calls.  
— Why: Avoids palette thrashing while keeping fog smooth.

**Incremental Palette Updates**:
```lua
for i=0,63 do
  if p[i+1] ~= prev_pal[i] then
    pal(i, p[i+1])  -- Only update changed colors
  end
end
```
Reduces palette operations from ~320/frame to ~10-20/frame.

**Single Frame-End Restore**:
- No mid-section `pal()` resets
- Single `pal()` call at end of `_draw()`
— What: One restore per frame.  
— How: Defer global `pal()` reset to `_draw()` end.  
— Why: Keeps sections isolated and cheaper.

#### Wall Rendering

**Span-Based Architecture**:
```lua
for ray_idx=0, ray_count-1 do
  local z = ray_z[ray_idx]
  local x0 = ray_x0[ray_idx]
  local x1 = ray_x1[ray_idx]
  
  for x=x0, x1 do
    local u_interp = u0 + (u1-u0) * (x-x0) / (x1-x0+0.01)
    tline3d(src, x, y0, x, y1, u_interp, v0, u_interp, v1, 1, 1)
    zbuf[x+1] = z  -- Per-pixel depth write
  end
end
```

**U-Interpolation**:
- Only interpolates when consecutive rays hit the same tile
- Prevents texture seams at tile boundaries
- Smooth texture transitions across spans
— What: Seam-free column continuity.  
— How: Interpolate only across same-tile rays; clamp UVs when clipped.  
— Why: Avoids shimmering and seams with minimal math.

**LOD System**:
- **Threshold**: `wall_lod_distance = fog_far * 0.7 = 14.0` units
- **Beyond LOD**: Draw solid average color (sampled from texture center)
- **Benefit**: Significant reduction in `tline3d` calls for distant walls
— What: Solid impostors for distant walls.  
— How: Cache `avg_color` per tile (center sample); fill span and write z.  
— Why: Fog hides detail; fill-rate win.

#### Floor/Ceiling Rendering

**Stride Rendering**:
```lua
for y=y0, y1, row_stride do  -- row_stride=2
  -- Draw scanline
  tline3d(src, 0, screen_center_y+y, screen_width-1, screen_center_y+y, ...)
  
  -- Duplicate into skipped rows
  for dy=1, row_stride-1 do
    rectfill(0, screen_center_y+y+dy, screen_width-1, screen_center_y+y+dy, cached_fill_color)
  end
end
```
- **Performance**: 50% fewer `tline3d` calls (135 vs 270)
- **Quality**: Duplication maintains visual density
— What: Draw fewer scanlines; duplicate into gaps.  
— How: Controlled by `row_stride`; uses cached fill color.  
— Why: Big savings with modest quality cost.

**Per-Cell Floor Types**:
1. **Sample** `map.floors` every 4 pixels along scanline
2. **Detect runs** sharing same floor type ID
3. **Merge runs** < 4 pixels to limit draw calls
4. **Render** each run with corresponding texture from `planetyps`
— What: Mixed materials per scanline.  
— How: Build/merge runs; draw each with its texture.  
— Why: Variety without exploding draw calls.

**Fog Application**:
- Compute fog level per scanline
- Only call `set_fog(z)` when level changes
- Uniform application (no `lit` exemptions)
— What: Coalesced fog updates.  
— How: Track last level and skip redundant `pal()`.  
— Why: Keeps floor section cheap.

---

### 3. Sprite System (`src/render_sprite.lua`)

**Purpose**: Render 3D objects (enemies, items, decorations) with correct occlusion.

Sprites are culled by a geometric frustum intersected with an object grid, sorted into 16 depth buckets to keep per-frame sorts local, and rendered back-to-front. Far sprites use solid impostors; near sprites draw per-column with z-tests against the wall z-buffer.

#### Frustum+Objgrid Culling

**Objgrid Query**:
```lua
for gx=flr(frustum_minx/objgrid_size), flr(frustum_maxx/objgrid_size) do
  for gy=flr(frustum_miny/objgrid_size), flr(frustum_maxy/objgrid_size) do
    for ob in all(objgrid[gx+1][gy+1]) do
      -- Transform to camera space
      -- Cull behind/outside/beyond far-plane
      -- Add to depth buckets
    end
  end
end
```

**Culling Checks**:
1. **Behind camera**: `z_cam <= 0`
2. **Outside frustum wedge**: `abs(x_cam) > z_cam * tan(fov)`
3. **Beyond far-plane**: `z_cam > far_plane` (25.0)
4. **Beyond wall depth**: `z_cam >= maxz` (secondary, wall-based)
— What: Early reject non-visible sprites.  
— How: Camera-space tests, far-plane cap, and max wall depth gate.  
— Why: Keeps sprite cost proportional to visibility.

#### Depth-Bucket Sorting

**16 Buckets**:
- Buckets 0-7: Upright sprites (0.0-25.0 units, 3.125 per bucket)
- Buckets 8-15: Flat sprites (offset by 8 for separate layering)

**Bucket Assignment**:
```lua
local bucket_size = far_plane / 8  -- 3.125 units
local bucket_idx = min(7, flr(z_cam / bucket_size))
if ob.typ.flat then
  bucket_idx = bucket_idx + 8  -- Flat sprites use a separate bucket range
end
add(sprite_buckets[bucket_idx], ob)
```

**Back-to-Front Iteration**:
```lua
for bucket_idx=15, 0, -1 do  -- Painter's algorithm
  for ob in all(sprite_buckets[bucket_idx]) do
    drawobj_single(ob, sa, ca)
  end
end
```

**Intra-Bucket Sorting**:
- Insertion sort within each bucket (small n)
- Handles sprite-sprite occlusion within same depth range
— What: Painter’s order with local sort.  
— How: Bucket by depth; insertion sort per bucket.  
— Why: Avoid O(n²) global sorts while preserving ordering.

#### Sprite LOD

**Threshold**: `sprite_lod_distance = fog_far * 0.8 = 16.0` units

**Impostor Rendering**:
```lua
if z > sprite_lod_distance then
  local avg_color = src:get(16, 16) or 5  -- Sample center pixel
  set_fog(z)
  for px=x0, x1 do
    if z < zbuf[px+1] then
      rectfill(px, y0, px, y1, avg_color)
    end
  end
end
```

**Per-Column Z-Test**:
```lua
for px=x0, x1 do
  if z < zbuf[px+1] then
    tline3d(src, px, y0, px, y1, u, v0, u, v1, 1, 1)
  end
end
```
Ensures correct occlusion with walls and other sprites.
— What: Far impostors; near per-column z-tested draws.  
— How: Center-color fill vs 32×32 UV sampling.  
— Why: Matches fog-driven perceptual detail, minimizes cost.

---

### 4. Dungeon Generation (`src/dungeon_gen.lua`)

**Purpose**: Procedurally generate dungeons with rooms, corridors, doors, and objects.

The generator builds a graph of rooms connected by corridors with boundary doors, applies theme-appropriate textures, places start/end exits on room perimeters, and populates objects. A progression loop locks certain corridor doors and guarantees matching key placement in currently accessible rooms to prevent dead-ends.

**Generation Pipeline**:
1. **Seed & Theme** - Initialize RNG, select theme (dungeon/outdoor/demonic)
2. **Fill Walls** - Start with solid map
3. **Carve Rooms** - Place 5-15 rooms (4x4 to 12x12)
4. **Carve Corridors** - Connect rooms with L-shaped corridors
5. **Place Doors** - Add doors at room entrances (30% probability)
6. **Place Exits** - Stairs to next floor
7. **Spawn Objects** - Enemies, items, decorations based on difficulty
8. **Erosion** - Smooth walls, add variety
9. **Border Ring** - Enforce 1-tile wall ring
10. **Door Tiles** - Re-assert door consistency

**Border Ring Enforcement**:
```lua
function enforce_border_ring()
  for x=0, map_size-1 do
    local tile = get_wall(x, 0)
    if not is_door(tile) and not is_exit(tile) then
      set_wall(x, 0, wall_fill_tile)  -- Preserve doors/exits
    end
    -- Repeat for bottom, left, right edges
  end
end
```
— What: Seals the outermost ring.  
— How: Writes `wall_fill_tile` on edges unless a door/exit occupies that cell.  
— Why: Prevents OOB traversal and keeps DDA rays bounded.

**Door Tile Re-Assertion**:
```lua
function enforce_door_tiles()
  for door in all(doors) do
    if not is_door(get_wall(door.x, door.y)) then
      set_wall(door.x, door.y, door.dtype or door_normal)
    end
  end
end
```
— What: Restores wall tiles for logically present doors.  
— How: Cross-checks `doors/doorgrid` against `map.walls` and fixes mismatches.  
— Why: Keeps rendering/collision authoritative after later passes.

**Difficulty Scaling**:
- Increases with floor number (1-9)
- More enemies, tougher enemy types
- More decorations, complex layouts
— What: Scales challenge by floor.  
— How: Filters `enemy_types` by `difficulty` and adjusts densities.  
— Why: Ensures progression across floors.

**Spatial Grids**:
- `objgrid[26][26]` - 5x5 unit cells for fast object queries
- `doorgrid[128][128]` - Door state tracking
— What: Separate grids for objects and doors.  
— How: `objgrid` accelerates culling/collision; `doorgrid` centralizes door states.  
— Why: Keeps queries and updates local.

#### Exit Placement
— What: Start (`exit_start`) and end (`exit_end`) exits placed on room perimeters and mirrored as interactable exit objects.  
— How: `generate_exit(rect, exit_type)` samples perimeter cells adjacent to walls, writes exit tile into `map.walls`, and adds an `interactable_exit` object at the same grid (centered at +0.5). Called for the first and last rooms during `generate_gameplay()`.  
— Why: Ensures exits are visible, reachable, and consistent between tiles and objects.

#### Progression Loop (Locked Doors and Keys)
— What: Locks selected corridor boundary doors and spawns matching keys in rooms that remain accessible without those keys.  
— How: `generate_progression_loop(start_node)` computes accessible rooms, shuffles edges, tentatively locks one boundary door per chosen edge (`door_locked` with `keynum`), recomputes accessibility, and enqueues a matching key into `gen_inventory`. Keys are then placed only in currently accessible rooms, with retries and fallback to the start room if needed. Boundary door placement uses retries and, if all fail, `ensure_boundary_passage` clears a blocking wall to preserve connectivity.  
— Why: Guarantees forward progress and prevents soft-locks while introducing lightweight gating.

---

### 5. Door System (`src/door_system.lua`)

**Purpose**: Animated doors with collision, state management, and auto-close.

Doors are represented in both logical (`doors`, `doorgrid`) and tile (`map.walls`) layers. Animation is deterministic, supports a test mode that avoids permanent state mutation, and integrates with collision and raycasting.

**Door States**:
- `open` - 0.0 (closed) to 1.0 (fully open)
- `opening` - Boolean flag
- `closing` - Boolean flag
- `close_timer` - Frames until auto-close (90 frames default)
— What: Minimal per-door FSM.  
— How: Opens to 1.0, starts timer, closes when timer elapses (unless `stayopen`).  
— Why: Predictable behavior compatible with collision and visuals.

**Door Types**:
- `door_normal` (24) - Standard door
- `door_locked` (25) - Requires key
- `door_stay_open` (26) - Never closes
— What: Encodes semantics and progression.  
— How: `door_locked` holds `keynum`; `door_stay_open` bypasses auto-close.  
— Why: Supports gating and UX expectations.

**Animation**:
```lua
function update_doors()
  for door in all(doors) do
    if door.opening then
      door.open = min(1.0, door.open + door_anim_speed)
    elseif door.closing then
      door.open = max(0.0, door.open - door_anim_speed)
    end
  end
end
```
— What: Constant-speed open/close.  
— How: Applies `door_anim_speed` per frame; uses `door_close_delay` timer.  
— Why: Simple, stable, low-cost.

**Collision Integration**:
- Raycast checks door open state
- Partial opening allows partial passage
- Collision system respects door geometry
— What: Unified movement respects doors; rays treat partially open doors as occluders.  
— How: `iscol()` consults `doorgrid`, can auto-open doors if player has a key.  
— Why: Keeps physics and visuals consistent.

---

### 6. AI System (main.lua)

**Purpose**: NPC behavior with patrol and follow modes.

AI updates are rate-limited. Patrol cycles waypoints; follow steers toward the player within a range. Movement uses unified sliding collision and updates the spatial grid on cell transitions.

**AI Types**:
1. **Follow** - Chase player when in range
2. **Patrol** - Waypoint-based movement
— What: Two lightweight behaviors.  
— How: Follow uses direct steering in-range; patrol follows precomputed waypoints.  
— Why: Keeps behavior expressive but cheap.

**Update Loop**:
```lua
function update_npc_ai()
  for ob in all(objects) do
    if ob.kind == "hostile_npc" then
      if distance_to_player < follow_range then
        -- Follow player
        move_towards(player.x, player.y, follow_speed)
      else
        -- Patrol waypoints
        move_towards(waypoint.x, waypoint.y, patrol_speed)
      end
    end
  end
end
```
— What: Rate-limited updates across object grid.  
— How: Deterministic frame check (`ai_update_rate`) with per-object logic.  
— Why: Avoids per-frame spikes when populations increase.

**Collision-Aware Movement**:
- Uses `trymoveto()` with sliding collision
- Updates `objgrid` after movement
- Respects walls, doors, and solid objects
— What: Shared movement core.  
— How: Try diagonal then axes; unify `iscol()` checks and update `objgrid`.  
— Why: Smooth movement without tunneling; keeps culling in sync.

---

## Configuration

All configuration is centralized in `src/config.lua`.

### Screen & View

```lua
screen_width = 480
screen_height = 270
screen_center_x = 240
screen_center_y = 135
ray_count = 128          -- Independent of screen_width
fov = 0.5                -- Half-angle in radians (~28.6°)
far_plane = 25.0         -- Maximum raycast distance
```

### Fog System

```lua
fog_near = 5.0           -- Fog starts at 5 units
fog_far = 20.0           -- Fog maximum at 20 units
fog_hysteresis = 0.5     -- Minimum z change to update fog
```

### LOD System

```lua
wall_lod_ratio = 0.7     -- Wall LOD at fog_far * 0.7 = 14.0
sprite_lod_ratio = 0.8   -- Sprite LOD at fog_far * 0.8 = 16.0
wall_lod_distance = fog_far * wall_lod_ratio  -- Computed
```

### Rendering

```lua
row_stride = 2           -- Floor/ceiling stride (1=full, 2=half)
```

### Map & Spatial

```lua
map_size = 128           -- 128x128 grid
objgrid_size = 5         -- 5x5 unit cells
objgrid_array_size = 26  -- 26x26 grid (128/5 rounded up)
```

### Player Movement

```lua
player_rotation_speed = 0.008  -- Radians per frame
player_move_speed = 0.04       -- Units per frame
```

### Door System

```lua
door_anim_speed = 0.06   -- Open/close speed per frame
door_close_delay = 90    -- Frames before auto-close
```

### AI

```lua
ai_update_rate = 2       -- Frames between AI updates
interaction_range = 0.5  -- Proximity for triggers
combat_trigger_range = 0.3  -- Distance to trigger combat
```

### Generation

```lua
gen_params = {
  min_rooms = 5,
  max_rooms = 15,
  min_size = 4,
  max_size = 12,
  spacing = 2,
  room_door_prob = 0.3,
  erode_amount = 50,
  difficulty = 1,
  max_difficulty = 9,
  max_enemies_per_room = 8,
  max_decorations_per_room = 12,
  npc_hostile_ratio = 0.7,
  items_per_room = 2,
  pickup_density = 0.1
}
```

---

## Performance Characteristics

### Typical Scene (128 rays, stride=2, LOD enabled)

**Target**: 50–60 FPS in typical scenes (128 rays, stride=2, fog-driven LOD).

Use the built-in diagnostics (G overlay, F logging) to tune:
- DDA steps/ray and early-outs (raycasting cost)
- Wall columns vs LOD solid fills (wall cost)
- Floor rows rendered (stride impact)
- Sprite columns drawn (culling/buckets/LOD impact)
- Fog switches (palette work)

### Performance Tuning Knobs

1. **ray_count** (64/128/256)
   - Lower = faster raycasting, blockier walls
   - Higher = slower raycasting, smoother walls

2. **row_stride** (1/2/4)
   - Higher = faster floors, more visible scanlines
   - Lower = slower floors, smoother floors

3. **wall_lod_ratio** (0.5-0.9)
   - Lower = more LOD, faster but less detail
   - Higher = less LOD, slower but more detail

4. **sprite_lod_ratio** (0.6-0.9)
   - Lower = more impostors, faster but less detail
   - Higher = fewer impostors, slower but more detail

5. **Floor run sampling/merging**
   - Increase sampling interval (code) or raise merge threshold to reduce draw calls

---

## File Structure

```
raycast_engine_v2/
├── main.lua                    # Entry point, game loop, collision, AI
├── src/
│   ├── config.lua              # Configuration (single source of truth)
│   ├── raycast.lua             # DDA raycasting, frustum AABB
│   ├── render.lua              # Wall/floor rendering, fog manager
│   ├── render_sprite.lua       # Sprite rendering, depth buckets
│   ├── door_system.lua         # Door animation and state
│   └── dungeon_gen.lua         # Procedural generation
├── README.md                   # This file
└── nbadv.p64                   # Picotron cartridge
```

---

## Technical Details

### Coordinate Systems

**World Space**:
- Origin: (0, 0) at top-left of map
- X-axis: Right
- Y-axis: Down
- Units: 1.0 = 1 grid cell

**Camera Space**:
- Origin: Player position
- Z-axis: Forward (camera direction)
- X-axis: Right (perpendicular to forward)
- Y-axis: Up (screen vertical)

**Screen Space**:
- Origin: (0, 0) at top-left of screen
- X-axis: Right (0-479)
- Y-axis: Down (0-269)
- Center: (240, 135)

### DDA Algorithm

**Digital Differential Analyzer** - Grid traversal for raycasting.

**Initialization**:
```lua
-- Horizontal ray (crosses vertical gridlines)
hx, hy = x, y
hdx, hdy = sgn(dx), dy / abs(dx)
hdz = hdx * fx + hdy * fy  -- Depth increment

-- Vertical ray (crosses horizontal gridlines)
vx, vy = x, y
vdx, vdy = dx / abs(dy), sgn(dy)
vdz = vdx * fx + vdy * fy  -- Depth increment
```

**Marching**:
```lua
for iter=1, iteration_limit do
  if hz < vz then
    -- Horizontal closer, check grid cell
    gx = flr(hx) + (hdx<0 and -1 or 0)
    gy = flr(hy)
    if get_wall(gx, gy) > 0 then
      return hz, hx, hy, tile, tx
    end
    hx += hdx
    hy += hdy
    hz += hdz
  else
    -- Vertical closer, check grid cell
    -- ... similar logic ...
  end
end
```

**Guards**:
1. **Far-plane**: `if min(hz, vz) > far_plane then return miss`
2. **Irreversible OOB**: `if (gx<0 and hdx<0) or (gx>=map_size and hdx>0) then return miss`
3. **Iteration cap**: `iteration_limit = min(256, horizontal_crossings + vertical_crossings + 10)`

### Fog Palette System

**16 Fog Levels** (0-15):
- Level 0: No fog (original colors)
- Level 15: Maximum fog (most colors → color 5)

**Palette Remapping**:
```lua
pals = {
  [1] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,...},  -- Level 0
  [2] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,5,...},   -- Level 1
  ...
  [16] = {0,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,...}        -- Level 15
}
```

**Application**:
```lua
function set_fog(z)
  local level = compute_fog_level(z)
  if level ~= last_fog_level then
    local p = pals[level+1]
    for i=0,63 do
      if p[i+1] ~= prev_pal[i] then
        pal(i, p[i+1])  -- Incremental update
      end
    end
  end
end
```

### Depth Buffer

**Per-Pixel zbuf**:
```lua
zbuf[1..480]  -- 1-based indexing (Lua convention)
```

**Wall Writes**:
```lua
for x=x0, x1 do
  tline3d(src, x, y0, x, y1, u, v0, u, v1, 1, 1)
  zbuf[x+1] = z  -- Write depth per pixel
end
```

**Sprite Z-Test**:
```lua
for px=x0, x1 do
  if z < zbuf[px+1] then  -- Per-pixel occlusion test
    tline3d(src, px, y0, px, y1, u, v0, u, v1, 1, 1)
  end
end
```

### Spatial Grids

**objgrid** - 26×26 grid of object lists:
```lua
objgrid[gx+1][gy+1] = {ob1, ob2, ...}  -- 1-based indexing
```
- Cell size: 5×5 world units
- Fast spatial queries for rendering and collision

**doorgrid** - 128×128 grid of door states:
```lua
doorgrid[x][y] = {open=0.5, opening=true, close_timer=90}
```
- Tracks door animation state
- Synchronized with `map.walls` layer

---

## Development & Debugging

### User Interface

- **HUD**: Position, angle, FPS, HP. Interaction prompt appears when an interactable is in range. Combat overlay displays during encounters.  
- **Debug & Diagnostics Panel (Tab)**: Consolidated on-screen counters (DDA steps, early-outs, fog switches, wall columns, floor rows, floor draw calls, sprite columns, FPS, frame) in a high-contrast panel with margins.  
- **Diagnostics Logging (Button 12)**: Periodic `printh` summary every 60 frames (includes CPU%).  
- **Minimap**:  
  - Full 2D minimap: press X (debug mode) to toggle between `3d` and `2d` views.  
  - HUD minimap: auto-scrolling clipped viewport in 3D view (walls/floors/doors/objects/player).  
- **Door Test Mode**: Press V to toggle. While active, C/D adjust forced open amount. When not in test mode, C cycles floor type; D cycles roof type.

### Diagnostic System

**Toggle Keys / Buttons**:
- **Tab**: Toggle consolidated debug & diagnostics panel
- **Button 12**: Toggle periodic printh logging

**On-Screen Display** (Consolidated Panel):
```
=== DIAGNOSTICS ===
DDA steps/ray: 8.3
Early-outs: 12
Fog switches: 7
Wall columns: 480
Floor rows: 135
Sprite columns: 156
FPS: 58
Frame: 3600
```

**Periodic Logging** (every 60 frames, when enabled):
```
=== FRAME 3600 DIAGNOSTICS ===
Avg DDA steps/ray: 8.3
Early-outs: 12
Fog switches: 7
Wall columns: 480
Floor rows: 135
Sprite columns: 156
FPS: 58
CPU: 42%
```

**Level Load Summary**:
```
=== LEVEL LOAD DIAGNOSTICS ===
Floor: 3
Difficulty: 3
Rooms: 12
Objects: 47
Seed: 12345
```

### Debug Modes

**Test Door Mode** (config.lua):
```lua
test_door_open = 0.5  -- Force all doors to 50% open
test_door_x = 10      -- Only affect door at (10, y)
test_door_y = 15      -- Only affect door at (x, 15)
```

**Minimap**:
- **X**: Toggle full 2D minimap (when debug_mode enabled)
- Shows walls, floors, doors, objects, player

**Debug Raycast Output**:
- Prints ray hit data when `debug_mode=true`
- Shows tile IDs, depths, texture coordinates

### Performance Profiling

**Identify Bottlenecks**:
1. Enable diagnostics (G)
2. Monitor counters across different scenes:
   - Corridors: High wall columns, low sprite columns
   - Rooms: Low wall columns, high sprite columns
   - Open areas: High early-outs, low wall columns

**Tune Configuration**:
1. If FPS < 50:
   - Reduce `ray_count` (128 → 64)
   - Increase `row_stride` (2 → 4)
   - Lower `wall_lod_ratio` (0.7 → 0.5)
   - Disable `per_cell_floors_enabled`

2. If FPS > 60:
   - Increase `ray_count` (128 → 256)
   - Decrease `row_stride` (2 → 1)
   - Raise `wall_lod_ratio` (0.7 → 0.9)

**Watch for Regressions**:
- Fog switches > 20/frame: Increase `fog_hysteresis`
- DDA steps/ray > 15: Check for missing early-outs
- Wall columns > 600: Check LOD threshold
- Sprite columns > 300: Check frustum culling

### Common Issues

**Blank Columns**:
- Cause: `ray_count` not dividing `screen_width` evenly
- Fix: Span computation handles this automatically

**Sprite Popping**:
- Cause: `far_plane < fog_far`
- Fix: Ensure `far_plane >= fog_far + 2.0`

**Texture Seams**:
- Cause: U-interpolation across different tiles
- Fix: Only interpolate when consecutive rays hit same tile

**Degenerate Bounds**:
- Cause: No wall hits in open scenes
- Fix: Frustum AABB provides independent sprite culling

**Palette Thrashing**:
- Cause: Frequent fog level changes
- Fix: Increase `fog_hysteresis` or reduce fog levels

---

## Asset Specifications

- **Wall textures**: 32×32 sprites referenced by `texsets` (e.g., `gfx/0_walls.gfx` indices).  
  - Opaque; rendered via `tline3d` or solid-color LOD beyond `wall_lod_distance` (`fog_far * wall_lod_ratio`).  
  - Configure sets and variants in `src/config.lua: texsets`.

- **Ceiling textures**: 32×32 sprites referenced by `planetyps` (typically indices 34–36).  
  - Optional scrolling via `xvel/yvel`; fog applied per scanline.  
  - Configure in `src/config.lua: planetyps`.

- **Floor textures**: 32×32 sprites referenced by `planetyps` (typically indices 32–33).  
  - Supports per-cell floor typing via `map.floors` if `per_cell_floors_enabled=true`.  
  - Configure in `src/config.lua: planetyps`.

- **Door textures**: 32×32 sprites (`door_normal`, `door_locked`, `door_stay_open`).  
  - Behavior determined by type; locked doors may carry `keynum`.  
  - Configure IDs in `src/config.lua` and create at generation with `create_door`.

- **Spawnable objects (items, decorations)**: 32×32 sprites.  
  - Definitions in `obj_types` and `decoration_types`; animated objects use sequential indices with `framect/animspd`.  
  - Place via generator (`generate_items`, `generate_decorations`).

- **NPCs/enemies**: 32×32 sprites.  
  - Entries in `enemy_types` (sprite indices 64–72 by default). Animation uses sequential indices when `framect>1`.

### Formats, Palettes, and Transparency
- Assets are resolved by sprite index via `get_spr()`. Author them in Picotron GFX banks.  
- Transparency: color 14 is treated transparent for sprites (`palt(14,true)` during sprite rendering). Walls/floors/ceilings render opaque.  
- Distance fog uses 64-color palette remaps (`pals` with 16 fog levels).

### Configuration Touchpoints (`src/config.lua`)
- `sprite_size` (default 32): global sprite sampling size.  
- `texsets`, `planetyps`: wall/floor/ceiling texture indices and properties.  
- `enemy_types`, `decoration_types`, `obj_types`: sprite indices and behavior for spawned content.  
- `pals`, `fog_near`, `fog_far`, `fog_hysteresis`: fog behavior and palette tables.  
- `wall_lod_ratio`, `sprite_lod_ratio`, `row_stride`, `per_cell_floors_enabled`: performance/quality controls.

---

## Credits & License

**Engine**: Picotron Raycast Engine  
**Platform**: Picotron (Lexaloffle Games)  
**Language**: Lua 5.4  
**Architecture**: Raycasting with modern optimizations  

**Key Innovations**:
- Decoupled ray_count architecture
- Unified fog system with hysteresis
- Frustum-based sprite culling
- Depth-bucket sorting
- Per-cell floor rendering
- Comprehensive diagnostics

**References**:
- Lode's Computer Graphics Tutorial (raycasting fundamentals)
- Wolfenstein 3D (original raycasting game)
- Doom (depth-bucket sorting inspiration)

---

## Appendix: Performance Budget Breakdown

### Frame Budget (60 FPS = 16.67ms)

| System | Budget | Actual | Notes |
|--------|--------|--------|-------|
| Raycasting | 6ms | 4-5ms | DDA guards prevent spikes |
| Floors | 4ms | 3-4ms | Stride=2 halves cost |
| Walls | 5ms | 4-5ms | LOD reduces distant walls |
| Sprites | 3ms | 2-3ms | Frustum culling, depth buckets |
| HUD | 1ms | 1ms | Minimal overhead |
| **Total** | **19ms** | **14-18ms** | **~2-3ms margin** |

### Optimization Impact

| Optimization | Effect |
|--------------|--------|
| DDA guards | Bounds worst-case traversal; reduces step spikes |
| Fog hysteresis | Dramatically lowers palette ops/frame |
| Floor stride | Halves scanline `tline3d` work at stride=2 |
| Wall LOD | Reduces distant wall `tline3d` work |
| Sprite LOD | Reduces distant sprite draw cost |
| Depth buckets | Avoids O(n²) sorts at higher sprite counts |

---