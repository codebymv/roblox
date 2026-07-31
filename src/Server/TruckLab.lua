--!nonstrict

--[[
	The fun-test build's composition root.

	One crew, one truck, one route, one crate. No credits, no shop, no bays, no
	persistence, no leg ladder. A run starts within a couple of seconds of
	joining and restarts within a couple of seconds of ending, because the only
	thing being measured is whether the thing in between is worth doing again.

	All of the actual behaviour lives in LabSession. This module exists to do
	the wiring that a session should not know about: build the world, stand a
	session up on it, and hand the developer commands a way to reach it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))

local DevCommands = require(script.Parent.DevCommands)
local LabSession = require(script.Parent.LabSession)
local TuningService = require(script.Parent.TuningService)
local WorldBuilder = require(script.Parent.WorldBuilder)

local TruckLab = {}

local session = nil

function TruckLab.init()
	Net.ensureServer()
	TuningService.init()

	local route = WorldBuilder.buildLabRoute()
	session = LabSession.new({ route = route })
	session:start()

	DevCommands.init({
		warp = function(progress: number): string
			return session:warpTo(progress)
		end,
		rebuild = function(): string
			TuningService.consumeBuildDirty()
			return session:rebuildRig()
		end,
		landmarks = function()
			return session:getLandmarks()
		end,
	})

	print("[CargoLab] Fun-test mode running. One crew, one route, physics truck.")
end

-- The live session, for the smoke test and the developer commands.
function TruckLab.getSession()
	return session
end

function TruckLab.shutdown()
	if session then
		session:destroy()
		session = nil
	end
end

return TruckLab
