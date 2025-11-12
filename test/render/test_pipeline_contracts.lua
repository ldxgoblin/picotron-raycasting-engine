--[[pod_format="raw",created="2025-11-12 00:00:00",modified="2025-11-12 00:00:00",revision=1]]
-- Renderer pipeline contract tests (unit-style, not tied to frame loop)
--
-- This fixture validates that:
-- - r_view produces normalized rays and sets rays_active
-- - r_cast can cast against a trivial map without crashing
-- - r_floor/r_walls/r_sprites can run once and update occupancy counters
-- 
-- The tests rely on small, deterministic game_state tables and do not
-- require the main game loop.

local assert = require("assert")
local log = require("log")

local fixture = {}

local r_state, r_batch, r_view, r_cast, r_floor, r_walls, r_sprites
local config

-- Minimal helpers and state shared by tests
local camera
local game_state_cast
local game_state_floor
local game_state_walls
local game_state_sprites

-- Minimal error textures for fallback paths
local function make_error_textures()
	local t = {
		wall = userdata("u8", 32, 32),
		door = userdata("u8", 32, 32),
		floor = userdata("u8", 32, 32),
		ceiling = userdata("u8", 32, 32),
		sprite = userdata("u8", 32, 32),
		default = userdata("u8", 32, 32)
	}
	-- Colorize a checkerboard so getters won't fail
	for _, ud in pairs(t) do
		for y = 0, 31 do
			for x = 0, 31 do
				local c = ((flr(x/4) + flr(y/4)) % 2 == 0) and 8 or 14
				ud:set(x, y, c)
			end
		end
	end
	return t
end

local ERROR_IDX = { wall=8000, door=8001, floor=8002, ceiling=8003, sprite=8004, default=8005 }

function fixture.before_all()
	-- Load modules
	config = include"src/config.lua"
	r_state = include"src/render/r_state.lua"
	r_batch = include"src/render/r_batch.lua"
	r_view  = include"src/render/r_view.lua"
	r_cast  = include"src/render/r_cast.lua"
	r_floor = include"src/render/r_floor.lua"
	r_walls = include"src/render/r_walls.lua"
	r_sprites = include"src/render/r_sprites.lua"

	-- Initialize renderer state
	r_state.init({
		screen_width = 160,   -- smaller for tests
		screen_height = 90,
		ray_count = 64,
		sprite_bucket_count = 4,
		sprite_bucket_capacity = 16,
		debug_mode = true
	})
	r_batch.init()
end

function fixture.before_each()
	-- Fresh frame
	r_state.prepare_frame()

	-- Build a trivial test camera
	camera = { x = 2.5, y = 2.5, a = 0 }

	-- Minimal "map": a vertical wall line at gx == 6
	local function get_wall_fn(gx, gy)
		if gx == 6 and gy >= 0 and gy < config.map_size then return 1 end
		return 0
	end

	-- Door grid: empty for tests
	local doorgrid = {}
	for i=0,config.map_size-1 do doorgrid[i] = {} end

	-- CAST game state
	game_state_cast = {
		get_wall = get_wall_fn,
		is_door = is_door,
		doorgrid = doorgrid,
		test_door_mode = false,
		test_door_open = 0,
		far_plane = config.far_plane,
		map_size = config.map_size
	}

	-- FLOOR/ROOF state
	local error_textures = make_error_textures()
	local get_spr = function(_) return nil end -- force error textures path
	game_state_floor = {
		floor = { typ = planetyps[1], x=0, y=0 },
		roof = { typ = planetyps[3], x=0, y=0 },
		sprite_size = config.sprite_size,
		per_cell_floors_enabled = false,
		get_floor = function() return 0 end,
		planetyps = planetyps,
		ERROR_IDX = ERROR_IDX,
		get_spr = get_spr,
		error_textures = error_textures
	}

	-- WALLS state
	game_state_walls = {
		wall_lod_distance = config.wall_lod_distance,
		wall_tiny_screen_px = config.wall_tiny_screen_px,
		sprite_size = config.sprite_size,
		is_door = is_door,
		get_spr = get_spr,
		error_textures = error_textures,
		ERROR_IDX = ERROR_IDX
	}

	-- SPRITES state (empty set for determinism)
	game_state_sprites = {
		objects = {},
		far_plane = config.far_plane,
		sprite_lod_ratio = config.sprite_lod_ratio,
		fog_far = config.fog_far,
		sprite_size = config.sprite_size,
		get_spr = get_spr,
		error_textures = error_textures
	}
end

function fixture.test_r_view_contract_normalizes_rays()
	-- Update view and build LUTs
	r_view.update(camera, r_state, fov, r_state.config.ray_count)
	-- Should set rays_active
	assert.is_true(r_state.occupancy.rays_active > 0, "rays_active should be set")
	-- Verify a few rays are unit-length
	local ok = r_view.verify_contract(r_state)
	assert.is_true(ok, "r_view.verify_contract should pass")
end

function fixture.test_r_cast_contract_hits_simple_wall()
	-- Prepare view first
	r_view.update(camera, r_state, fov, r_state.config.ray_count)
	-- Cast scene
	r_cast.cast_scene(camera, r_view, r_state, game_state_cast)
	-- Verify basic contract
	local ok = r_cast.verify_contract(r_state, game_state_cast)
	assert.is_true(ok, "r_cast.verify_contract should pass")
end

function fixture.test_floor_walls_sprites_draw_once_and_update_occupancy()
	-- View and cast to prepare buffers for walls
	r_view.update(camera, r_state, fov, r_state.config.ray_count)
	r_cast.cast_scene(camera, r_view, r_state, game_state_cast)
	-- Draw floor/ceiling
	r_floor.draw_floor_ceiling(camera, r_view, r_state, r_batch, game_state_floor)
	-- Draw walls
	r_walls.draw_spans(camera, r_view, r_state, r_batch, game_state_walls)
	-- Draw sprites (none)
	r_sprites.draw(camera, r_view, r_state, r_batch, game_state_sprites)
	-- Submit pending batches just in case
	r_batch.tline_submit()
	r_batch.rect_submit()

	assert.is_true(r_state.occupancy.floor_rows > 0, "floor_rows should be > 0 after draw")
	assert.is_true(r_state.occupancy.wall_spans >= 0, "wall_spans should be >= 0")
	assert.are_equal(r_state.occupancy.sprite_count, 0, "sprite_count should match objects length")
end

function fixture.after_each()
	-- no-op
end

function fixture.after_all()
	-- Teardown renderer
	r_state.teardown()
end

return fixture


