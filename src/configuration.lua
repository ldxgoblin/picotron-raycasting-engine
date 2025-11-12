--[[pod_format="raw",created="2024-09-08 09:49:19",modified="2025-03-07 13:16:06",revision=6]]
--[[
	configuration.lua - configuration settings for the program
	(c) 2025 Andrew Vasilyev. All rights reserved.

	This program is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program. If not, see <https://www.gnu.org/licenses/>.
]]

local log = require("log", "log")

configuration = {
	-- If true, logging will be initialized and messages will be sent to the "logview" process
	log = {
		-- If true, logging will be enabled
		enabled = true,
		-- The logging level to use
		level = log.levels.DEBUG
	}
}
