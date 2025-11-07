# Asset Specification

Complete texture and sprite coordinate reference for the Picotron Raycast Engine.

## Sprite Sheet Layout

**Format**: 128×128 pixel userdata, 8×8 tile grid (16 tiles wide × 16 tiles tall)  
**Source**: `get_spr(0)` sprite sheet index 0  
**Tile Indexing**: `tile_id = (tile_x % 16) + (tile_y / 16) * 16`

## Wall Textures

### Tile Coordinates (8×8 pixels each)
Walls use single 8×8 tiles sampled vertically. Texture sets provide variants for visual variety.

| Tile ID | Grid Pos | Texture Set | Description |
|---------|----------|-------------|-------------|
| 0 | (0,0) | none | Empty/Floor (not rendered as wall) |
| 1 | (1,0) | brick | Brick variant 1 |
| 2 | (2,0) | brick | Brick variant 2 |
| 3 | (3,0) | brick | Brick variant 3 |
| 4 | (4,0) | brick | Brick variant 4 |
| 5 | (5,0) | cobblestone | Cobblestone variant 1 |
| 6 | (6,0) | cobblestone | Cobblestone variant 2 |
| 7 | (7,0) | cobblestone | Cobblestone variant 3 |
| 8 | (8,0) | cobblestone | Cobblestone variant 4 |
| 9 | (9,0) | wood_plank | Wood variant 1 |
| 10 | (10,0) | wood_plank | Wood variant 2 |
| 11 | (11,0) | wood_plank | Wood variant 3 |
| 12 | (12,0) | wood_plank | Wood variant 4 |
| 13 | (13,0) | stone | Stone variant 1 |
| 14 | (14,0) | stone | Stone variant 2 |
| 15 | (15,0) | stone | Stone variant 3 |
| 16 | (0,1) | stone | Stone variant 4 |

**Wall Fill Tile**: `wall_fill_tile = 1` (used as background fill during generation)

## Floor and Ceiling Textures

Floor/ceiling tiles use the same 8×8 format, sampled with perspective correction.

| Tile ID | Grid Pos | Type | Description | Scale | Height | Lit | Velocity |
|---------|----------|------|-------------|-------|--------|-----|----------|
| 0 | (0,0) | stone_tile | Stone floor | 1 | 0.5 | yes | (0,0) |
| 1 | (1,0) | dirt | Dirt floor | 1 | 0.5 | yes | (0,0) |
| 2 | (2,0) | stone_ceiling | Stone ceiling | 1 | 0.5 | no | (0,0) |
| 8 | (8,0) | sky | Sky ceiling | 2 | 1.0 | no | (0.01,0) |
| 9 | (9,0) | night_sky | Night sky ceiling | 2 | 1.0 | no | (0.005,0) |

**Velocity**: `(xvel, yvel)` - scrolling speed per frame for animated skies

## Door Tiles

Doors occupy single 8×8 tiles in the map but render as vertical slices that slide open.

| Tile ID | Grid Pos | Type | Description |
|---------|----------|------|-------------|
| 64 | (0,4) | door_normal | Standard door (auto-closes after 90 frames) |
| 65 | (1,4) | door_locked | Locked door (requires key) |
| 66 | (2,4) | door_stay_open | Door that stays open once triggered |

**Animation**: Slides horizontally (texture offset 0.0 → 1.0 over time)  
**Speed**: `door_anim_speed = 0.06` units/frame  
**Close Delay**: `door_close_delay = 90` frames

## Exit Portals

| Tile ID | Grid Pos | Type | Description |
|---------|----------|------|-------------|
| 67 | (3,4) | exit_start | Entry portal (downward stairs) |
| 68 | (4,4) | exit_end | Exit portal (upward stairs) |

## Object Sprites

### NPCs (16×40 pixels, upright)

| Object Type | Sprite Coords | Frames | Anim Speed | Y-Offset | Solid | Kind |
|-------------|---------------|--------|------------|----------|-------|------|
| hostile_npc | (103,0) | 4 | 0.25 | [0,-0.01,0,-0.01] | yes | hostile_npc |
| non_hostile_npc | (110,0) | 1 | 0 | nil | yes | non_hostile_npc |

**Memory Layout**: `mx=103, my=0, mw=16, mh=40` means sprite starts at pixel (103,0), size 16×40.  
**Frame Advancement**: Horizontal offset `+mw` per frame (frame 0: x=103, frame 1: x=119, etc.)

### Items (8×8 pixels, upright small objects)

| Object Type | Sprite Coords | Frames | Anim Speed | Y-Offset | Solid | Kind | Subtype |
|-------------|---------------|--------|------------|----------|-------|------|---------|
| key | (98,10) | 1 | 0 | nil | no | direct_pickup | key |
| heart | (88,0) | 2 | 0.1 | [0,0.05] | no | direct_pickup | heart |
| direct_pickup | (80,0) | 2 | 0.1 | [0,0.05] | no | direct_pickup | generic |

### Interactables (8×8 or 8×16 pixels)

| Object Type | Sprite Coords | Size | Frames | Flat | Kind | Subtype |
|-------------|---------------|------|--------|------|------|---------|
| chest | (85,0) | 8×8 | 1 | no | interactable | chest |
| shrine | (90,0) | 8×16 | 1 | no | interactable | shrine |
| trap | (95,0) | 8×8 | 1 | yes | interactable | trap |
| note | (100,0) | 8×8 | 1 | yes | interactable | note |
| exit | (100,0) | 8×8 | 1 | no | interactable | exit |

**Flat**: Ground-aligned sprites (traps, notes) use different perspective calculation

### Decorations (8×16 pixels, upright)

| Decoration | Sprite Coords | Frames | Anim Speed | Lit | Gen Tags |
|------------|---------------|--------|------------|-----|----------|
| torch | (92,0) | 4 | 0.25 | yes | ["lit","uni"] |
| barrel | (92,0) | 4 | 0.25 | no | ["uni"] |
| crate | (92,0) | 4 | 0.25 | no | ["uni2"] |
| pillar | (92,0) | 4 | 0.25 | no | ["big"] |
| statue | (92,0) | 4 | 0.25 | no | ["rare"] |
| chest_deco | (92,0) | 4 | 0.25 | no | ["scatter"] |

**Note**: All decorations currently share sprite coords (92,0). Update with unique coordinates for visual variety.

## Memory Banks and Userdata

### Map Layers (128×128 i16 userdata)
- **map.walls**: Wall tile IDs (0-255)
- **map.doors**: Door type IDs (64-66) at door positions
- **map.floors**: Floor tile IDs (unused by renderer, placeholder for future extension)

### Compatibility Tables (Lua tables mirroring userdata)
- **wallgrid[x][y]**: Lua fallback for wall queries (kept in sync with map.walls)
- **doorgrid[x][y]**: Door object references for animation state

### Rendering Buffers
- **zbuf[1..320]**: Z-depth per ray (number, units in world space)
- **tbuf[1..320]**: Tile info per ray `{tile=id, tx=fractional_offset}`

## Texture Sampling

### Wall Column Rendering
```lua
-- Given tile ID and fractional offset tx (0.0-1.0):
local tile_x = tile % 16
local tile_y = flr(tile / 16)
local u0 = tile_x * 8 + flr(tx * 8)  -- pixel column in sprite sheet
local v0 = tile_y * 8                 -- top of 8-pixel tile
local v1 = v0 + 8                     -- bottom of tile
-- tline3d samples vertical column from (u0,v0) to (u0,v1)
```

### Floor/Ceiling Scanline Rendering
```lua
-- Given tile ID and fractional map position (mx, my):
local tile_x = tex % 16
local tile_y = flr(tex / 16)
local base_u = tile_x * 8
local base_v = tile_y * 8
local u0 = base_u + (mx % 1) * 8      -- start pixel
local v0 = base_v + (my % 1) * 8
-- tline3d samples horizontal span with deltas mdx, mdy
```

## Performance Characteristics

### Sprite Rendering
- **Frustum Culling**: Upright sprites check `abs(rel[1]) - w < rel[2] * (160/200)`
- **Flat Sprites**: Ground-aligned require `rel[2] >= w/2` to prevent z-division issues
- **Z-Buffer Check**: Per-column test `z < zbuf[px+1]` before drawing
- **Sort Cost**: Insertion sort on ~10-50 visible objects per frame

### Texture Bottlenecks
- **Wall Columns**: 320 rays × 8-pixel-wide samples = 2,560 tline3d calls/frame
- **Floor/Ceiling**: ~90 scanlines × 2 planes = 180 tline3d calls/frame (width varies by perspective)
- **Sprites**: Variable (depends on visible object count and screen coverage)

## Expected Resolutions

### Environment
- **Walls**: 8×8 source tiles, stretched to screen height (varies by distance)
- **Floors/Ceilings**: 8×8 tiles, perspective-mapped across scanlines
- **Typical Wall Height**: ~50-150 pixels at mid-range distances (h = sdist/z, sdist≈200)

### NPCs
- **Hostile/Non-Hostile**: 16×40 source, scales with distance (typical 20-80 pixels tall)

### Props and Items
- **Small Items** (keys, hearts): 8×8 source, ~5-20 pixels on screen
- **Medium Props** (chests, shrines): 8-16 pixels tall, ~10-40 pixels on screen
- **Decorations**: 8×16 source, ~15-50 pixels tall depending on placement

### Doors
- **Rendered Height**: Same as wall (full vertical column)
- **Texture Offset**: Horizontal slide during animation (0.0 = closed, 1.0 = fully open)

## Source Locations

All assets reside in **sprite sheet 0** (`get_spr(0)`), accessible via `get_texture_source()`.

**Fallback**: If sprite sheet 0 is missing, renderer returns empty 128×128 u8 userdata to prevent crashes.

## Asset Creation Guidelines

1. **Sprite Sheet**: Create 128×128 pixel image, import to Picotron sprite editor slot 0
2. **Tile Alignment**: Ensure 8×8 tiles align to grid (pixel-perfect at multiples of 8)
3. **Color Palette**: Use Picotron's 64-color palette; fog system remaps colors 0-63
4. **Transparency**: Color 14 is treated as transparent for sprites (`palt(14, true)`)
5. **Animation**: Place frames horizontally (e.g., 4-frame animation uses 4 adjacent 8×8 tiles)
6. **Flat vs Upright**: Flat sprites (traps, notes) render on ground plane; upright sprites billboard to camera
