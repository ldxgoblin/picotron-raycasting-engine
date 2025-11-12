--[[pod_format="raw",created="2025-11-12 00:00:00",modified="2025-11-12 00:00:00",revision=1]]
-- r_state.lua
-- Renderer state: owns all userdata buffers, config, and occupancy counters

local r_state = {}

-- Memory base address for renderer buffers (safe range per optimization guidelines)
local MEM_BASE = 0x080000

-- Configuration
r_state.config = {
  screen_width = 480,
  screen_height = 270,
  ray_count = 128,
  sprite_bucket_count = 8,
  sprite_bucket_capacity = 64,
  debug_mode = false
}

-- Buffer handles (will be populated by init)
r_state.buffers = {}

-- Occupancy counters (reset per frame)
r_state.occupancy = {
  rays_active = 0,
  wall_spans = 0,
  floor_rows = 0,
  sprite_count = 0
}

-- Frame counter for z-buffer stamping
r_state.frame_id = 0

-- Initialize all renderer buffers using memmap
function r_state.init(config)
  -- Merge user config
  if config then
    for k, v in pairs(config) do
      r_state.config[k] = v
    end
  end
  
  local cfg = r_state.config
  local ray_cnt = cfg.ray_count
  local sw = cfg.screen_width
  local sh = cfg.screen_height
  
  -- Ray direction and hit data buffers
  r_state.buffers.ray_dir_x = userdata("f64", ray_cnt)
  r_state.buffers.ray_dir_y = userdata("f64", ray_cnt)
  r_state.buffers.ray_z = userdata("f64", ray_cnt)
  r_state.buffers.ray_tx = userdata("f64", ray_cnt)
  r_state.buffers.ray_hitx = userdata("f64", ray_cnt)
  r_state.buffers.ray_hity = userdata("f64", ray_cnt)
  r_state.buffers.ray_tile = userdata("i16", ray_cnt)
  
  -- Screen span mapping (which pixels each ray covers)
  r_state.buffers.ray_x0 = userdata("i16", ray_cnt)
  r_state.buffers.ray_x1 = userdata("i16", ray_cnt)
  r_state.buffers.ray_px_center = userdata("f64", ray_cnt)
  
  -- Wall span buffers (worst case: one span per ray)
  r_state.buffers.wall_span_start = userdata("i16", ray_cnt)
  r_state.buffers.wall_span_end = userdata("i16", ray_cnt)
  r_state.buffers.wall_span_tile = userdata("i16", ray_cnt)
  r_state.buffers.wall_span_uv0 = userdata("f32", ray_cnt)
  r_state.buffers.wall_span_uv1 = userdata("f32", ray_cnt)
  r_state.buffers.wall_span_depth = userdata("f32", ray_cnt)
  
  -- Sprite buckets (depth-sorted bins)
  local bucket_size = cfg.sprite_bucket_count * cfg.sprite_bucket_capacity
  r_state.buffers.sprite_bucket_indices = userdata("i16", bucket_size)
  r_state.buffers.sprite_bucket_depths = userdata("f32", bucket_size)
  r_state.buffers.sprite_bucket_counts = userdata("i16", cfg.sprite_bucket_count)
  
  -- Z-buffer and frame stamp
  r_state.buffers.zbuf = userdata("f32", sw)
  r_state.buffers.zstamp = userdata("i32", sw)
  
  -- Initialize zstamp to 0
  for i = 0, sw - 1 do
    r_state.buffers.zstamp:set(i, 0)
  end
  
  -- Diagnostics snapshot buffer (only used when debug_mode enabled)
  r_state.buffers.stats_ud = userdata("f32", 32)
  
  printh("[r_state] initialized: " .. ray_cnt .. " rays, " .. sw .. "x" .. sh .. " screen")
end

-- Prepare frame: clear occupancy counters and stamp z-buffer
function r_state.prepare_frame()
  r_state.frame_id = r_state.frame_id + 1
  r_state.occupancy.rays_active = 0
  r_state.occupancy.wall_spans = 0
  r_state.occupancy.floor_rows = 0
  r_state.occupancy.sprite_count = 0
  
  -- Z-buffer is invalidated by frame stamp, no need to clear values
end

-- Z-buffer helpers using frame stamping
function r_state.zread(x)
  if x < 0 or x >= r_state.config.screen_width then return 999 end
  local stamp = r_state.buffers.zstamp:get(x) or 0
  if stamp == r_state.frame_id then
    return r_state.buffers.zbuf:get(x) or 999
  end
  return 999
end

function r_state.zwrite(x, z)
  if x < 0 or x >= r_state.config.screen_width then return end
  r_state.buffers.zbuf:set(x, z)
  r_state.buffers.zstamp:set(x, r_state.frame_id)
end

-- Dump buffer usage (debug mode only)
function r_state.dump_usage()
  if not r_state.config.debug_mode then return end
  
  printh("[r_state] buffer usage:")
  printh("  rays_active: " .. r_state.occupancy.rays_active .. " / " .. r_state.config.ray_count)
  printh("  wall_spans: " .. r_state.occupancy.wall_spans .. " / " .. r_state.config.ray_count)
  printh("  floor_rows: " .. r_state.occupancy.floor_rows)
  printh("  sprite_count: " .. r_state.occupancy.sprite_count)
end

-- Teardown: unmap all userdata (allows GC)
function r_state.teardown()
  -- Picotron doesn't require explicit unmap, but we clear references
  for k, v in pairs(r_state.buffers) do
    r_state.buffers[k] = nil
  end
  printh("[r_state] teardown complete")
end

return r_state

