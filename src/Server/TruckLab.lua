--!nonstrict

--[[
	The fun-test build's composition root.

	One crew, one truck, one route, one crate. Persistent run rewards and truck
	paint sit around the loop; bays, role kits and the leg ladder stay out. A run starts within a couple of seconds of
	joining and restarts within a couple of seconds of ending, because the only
	thing being measured is whether the thing in between is worth doing again.

	All of the actual behaviour lives in LabSession. This module exists to do
	the wiring that a session should not know about: build the world, stand a
	session up on it, and hand the developer commands a way to reach it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local DevConfig = require(Shared:WaitForChild("DevConfig"))
local LabConfig = require(Shared:WaitForChild("LabConfig"))

local DevCommands = require(script.Parent.DevCommands)
local LabSession = require(script.Parent.LabSession)
local TuningService = require(script.Parent.TuningService)
local WorldBuilder = require(script.Parent.WorldBuilder)

local TruckLab = {}

local session = nil
local studioSessionBridge = nil

local function exposeStudioSession()
	if not RunService:IsStudio() then
		return
	end

	if studioSessionBridge then
		studioSessionBridge:Destroy()
	end
	studioSessionBridge = Instance.new("BindableFunction")
	studioSessionBridge.Name = "GetLiveSessionForStudioSmoke"
	studioSessionBridge.OnInvoke = function(action, argumentA, argumentB)
		assert(session, "CargoLab session is not running")
		if action == "State" then
			local routes = {}
			for index, route in session.routes do
				routes[index] = {
					id = route.id,
					root = route.root,
					startCFrame = route.startCFrame,
					points = route.points,
					features = route.features,
				}
			end
			return {
				phase = session.phase,
				currentLeg = session:currentLeg(),
				routes = routes,
				route = {
					id = session.route.id,
					root = session.route.root,
					features = session.route.features,
				},
				runVariant = session.runVariant,
				cargoHome = session.cargoLoad and session.cargoLoad.home or Vector3.zero,
			}
		elseif action == "BuildSnapshot" then
			return session:buildSnapshotFor(argumentA)
		elseif action == "HasCompleteWheelSet" then
			return session.chassisRig and session.chassisRig:hasCompleteWheelSet() or false
		elseif action == "SetCosmetics" then
			assert(session.chassisRig, "CargoLab chassis is not running")
			session.chassisRig:setCosmetics(argumentA, argumentB, session.chassisRig.cosmeticPaintColor)
			return true
		elseif action == "RestoreDriverCosmetics" then
			session:_applyDriverCosmetics()
			return true
		end
		error("Unknown Studio smoke action: " .. tostring(action))
	end
	studioSessionBridge.Parent = script
end

function TruckLab.init()
	Net.ensureServer()
	TuningService.init()

	local routes = WorldBuilder.buildLabWorld()
	session = LabSession.new({ routes = routes })
	session:start()
	exposeStudioSession()

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

	print(
		string.format(
			"[CargoLab] Fun-test mode running (%s). One %d-player crew, one route, physics truck.",
			DevConfig.Profile,
			LabConfig.MaxCrew
		)
	)
end

-- The live session, for the smoke test and the developer commands.
function TruckLab.getSession()
	return session
end

function TruckLab.shutdown()
	if studioSessionBridge then
		studioSessionBridge:Destroy()
		studioSessionBridge = nil
	end
	if session then
		session:destroy()
		session = nil
	end
end

return TruckLab
