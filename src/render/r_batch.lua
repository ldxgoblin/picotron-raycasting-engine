--[[pod_format="raw",created="2025-11-12 00:00:00",modified="2025-11-12 00:00:00",revision=1]]
-- r_batch.lua
-- Central batching for tline3d and rectfill operations

local r_batch = {}

-- Batch configuration
local TLINE_COLS = 13  -- sprite_index, x0,y0,x1,y1, u0,v0,u1,v1, w0,w1, flags
local RECT_COLS = 5    -- x0,y0,x1,y1, color

-- Buffer capacities
local tline_capacity = 480 * 2  -- 2x screen width
local rect_capacity = 480 * 4   -- 4x screen width

-- Batch buffers
local tline_args = nil
local rect_args = nil
local tline_count = 0
local rect_count = 0

-- Current clip/palette state (for pass isolation)
local current_clip = nil
local current_palette = nil

-- Initialize batch buffers
function r_batch.init()
  tline_args = userdata("f64", TLINE_COLS, tline_capacity)
  rect_args = userdata("f64", RECT_COLS, rect_capacity)
  tline_count = 0
  rect_count = 0
  printh("[r_batch] initialized: tline=" .. tline_capacity .. ", rect=" .. rect_capacity)
end

-- Reset tline batch
function r_batch.tline_reset()
  tline_count = 0
end

-- Push a tline3d call to batch
function r_batch.tline_push(idx, x0, y0, x1, y1, u0, v0, u1, v1, w0, w1, flags)
  if tline_count >= tline_capacity then
    r_batch.tline_submit()
  end
  
  tline_args:set(0, tline_count, 
    idx, x0, y0, x1, y1, 
    u0, v0, u1, v1, 
    w0 or 1, w1 or 1, 
    flags or 0)
  tline_count = tline_count + 1
end

-- Submit tline batch
function r_batch.tline_submit()
  if tline_count > 0 then
    tline3d(tline_args, 0, tline_count, TLINE_COLS)
    tline_count = 0
  end
end

-- Reset rect batch
function r_batch.rect_reset()
  rect_count = 0
end

-- Push a rectfill call to batch
function r_batch.rect_push(x0, y0, x1, y1, c)
  if rect_count >= rect_capacity then
    r_batch.rect_submit()
  end
  
  rect_args:set(0, rect_count, x0, y0, x1, y1, c)
  rect_count = rect_count + 1
end

-- Submit rect batch
function r_batch.rect_submit()
  if rect_count > 0 then
    rectfill(rect_args, 0, rect_count, RECT_COLS)
    rect_count = 0
  end
end

-- Set clip region for current pass
function r_batch.set_clip(x, y, w, h)
  -- Flush any pending batches before changing state
  r_batch.tline_submit()
  r_batch.rect_submit()
  
  if x == nil then
    clip()
    current_clip = nil
  else
    clip(x, y, w, h)
    current_clip = {x, y, w, h}
  end
end

-- Set palette for current pass
function r_batch.set_palette(pal_table)
  -- Flush any pending batches before changing state
  r_batch.tline_submit()
  r_batch.rect_submit()
  
  if pal_table == nil then
    pal()
    current_palette = nil
  else
    pal(pal_table)
    current_palette = pal_table
  end
end

-- Restore default state (called at pass boundaries)
function r_batch.restore_defaults()
  r_batch.tline_submit()
  r_batch.rect_submit()
  clip()
  pal()
  palt()
  current_clip = nil
  current_palette = nil
end

return r_batch

