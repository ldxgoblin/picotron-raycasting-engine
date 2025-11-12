--[[pod_format="raw",created="2025-11-12 00:00:00",modified="2025-11-12 00:00:00",revision=1]]
-- r_diag.lua
-- Diagnostics overlay gated by debug_mode

local r_diag = {}

-- Draw diagnostics panel
-- r_state: renderer state with occupancy counters
-- frame_ms: frame time in milliseconds
-- cpu_sample: CPU usage from stat(1)
function r_diag.draw(r_state, frame_ms, cpu_sample)
  if not r_state.config.debug_mode then
    return
  end
  
  local cfg = r_state.config
  local occ = r_state.occupancy
  
  -- Format metrics
  frame_ms = frame_ms or 0
  cpu_sample = cpu_sample or 0
  local cpu_pct = math.floor(cpu_sample * 1000 + 0.5) / 10
  local frame_ms_fmt = math.floor(frame_ms * 10 + 0.5) / 10
  local rays_text = occ.rays_active .. "/" .. cfg.ray_count
  
  local lines = {
    {text = "r_diag: metrics", color = 11},
    {text = "frame_ms: " .. frame_ms_fmt, color = 11},
    {text = "cpu%: " .. cpu_pct, color = (cpu_pct > 90) and 8 or ((cpu_pct > 70) and 10 or 11)},
    {text = "rays: " .. rays_text, color = 7},
    {text = "floor rows: " .. occ.floor_rows, color = 7},
    {text = "wall spans: " .. occ.wall_spans, color = 7},
    {text = "sprite count: " .. occ.sprite_count, color = 7}
  }
  
  -- Compute panel dimensions
  local max_len = 0
  for entry in all(lines) do
    if #entry.text > max_len then
      max_len = #entry.text
    end
  end
  
  local panel_x = 4
  local panel_y = 80
  local panel_w = max_len * 4 + 6
  local panel_h = #lines * 8 + 6
  
  -- Save clip/palette state
  local prev_clip = peek(0x5f20, 4)
  
  -- Draw panel background and border
  clip()
  rectfill(panel_x - 2, panel_y - 2, panel_x + panel_w, panel_y + panel_h, 1)
  rect(panel_x - 3, panel_y - 3, panel_x + panel_w + 1, panel_y + panel_h + 1, 7)
  
  -- Draw text
  for i = 1, #lines do
    local entry = lines[i]
    print(entry.text, panel_x, panel_y + (i - 1) * 8, entry.color)
  end
  
  -- Restore clip state
  clip()
end

return r_diag

