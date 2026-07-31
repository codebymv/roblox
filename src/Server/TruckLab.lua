--!nonstrict

--[[
	The fun-test build.

	One crew, one truck, one route, one crate. No credits, no shop, no bays, no
	persistence, no leg ladder. A run starts within a couple of seconds of
	joining and restarts within a couple of seconds of ending, because the only
	thing being measured is whether the thing in between is worth doing again.

	Roles: one Driver, up to three crew on the bed. Every crew member can move
	between all four strap stations, which means a crew has to actually divide
	the load between them out loud.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevConfig = require(Shared:WaitForChild("DevConfig"))
local LabConfig = require(Shared:WaitForChild("LabConfig"))
local Net = require(Shared:WaitForChild("Net"))

local CargoLoad = require(script.Parent.CargoLoad)
local LabTelemetry = require(script.Parent.LabTelemetry)
local PhysicsChassis = require(script.Parent.PhysicsChassis)
local PressureDirector = require(script.Parent.PressureDirector)
local RateLimiter = require(script.Parent.RateLimiter)
local StrapperStations = require(script.Parent.StrapperStations)
local WorldBuilder = require(script.Parent.WorldBuilder)

local TruckLab = {}

local route
local chassisRig
local cargoLoad
local stations
local director
local telemetry

local phase: string = "Staging"
local phaseClock = 0
local timeRemaining = LabConfig.RunTimeLimitSeconds
local outcome: string? = nil
local crateSaved: boolean? = nil
local restartSeconds = 0
local objective = "Waiting for a crew."

local roles: { [number]: string } = {}
local driveInputs: { [number]: { throttle: number, steering: number, braking: boolean, at: number } } = {}

local driveLimiter = RateLimiter.new(25, 40)
local actionLimiter = RateLimiter.new(8, 12)

local snapshotAccumulator = 0
local debugAccumulator = 0
local ownershipAccumulator = 0

local function currentDriver(): Player?
	for userId, role in roles do
		if role == "Driver" then
			return Players:GetPlayerByUserId(userId)
		end
	end
	return nil
end

local function toast(text: string)
	Net.get(Net.Names.LabEvent):FireAllClients(text)
end

local function driveState()
	local driver = currentDriver()
	if not driver or phase ~= "Run" then
		return { throttle = 0, steering = 0, braking = phase ~= "Run" }
	end
	local state = driveInputs[driver.UserId]
	if not state or os.clock() - state.at > 1 then
		return { throttle = 0, steering = 0, braking = false }
	end
	return state
end

local function hintFor(role: string?): string
	if role == "Driver" then
		return "W/S drive, A/D steer, Space brake. Slow down before you can see round the corner."
	elseif role == "Strapper" then
		return "1-4 to move to a corner. Hold E to work the strap you are standing at."
	end
	return "Waiting for a seat on the truck."
end

local function buildSnapshot(player: Player)
	local userId = player.UserId
	local role = roles[userId]
	local slot = stations and stations:getSlot(player)

	return {
		phase = phase,
		timeRemaining = math.max(0, math.floor(timeRemaining)),
		routeProgress = if chassisRig then chassisRig:getRouteProgress() else 0,
		speed = if chassisRig then math.floor(chassisRig:getSpeed()) else 0,

		condition = if cargoLoad then cargoLoad.condition else "Secure",
		cargoReadout = if cargoLoad then cargoLoad.readout else 100,
		cargoOffset = if cargoLoad then math.floor(cargoLoad.offset * 10) / 10 else 0,
		cargoLeanDeg = if cargoLoad then math.floor(cargoLoad.leanDeg) else 0,

		chassisIntegrity = if chassisRig then math.floor(chassisRig:getIntegrity()) else 100,
		straps = if cargoLoad then cargoLoad:snapshotStraps() else {},
		crew = if stations then stations:snapshot() else {},

		myRole = role,
		myStation = slot and slot.station or nil,
		myMovingTo = slot and slot.movingTo or nil,
		myThrown = (slot and slot.thrown) or false,

		objective = objective,
		hint = hintFor(role),
		outcome = outcome,
		crateSaved = crateSaved,
		restartSeconds = math.max(0, math.floor(restartSeconds)),
	}
end

local function broadcastSnapshot()
	local remote = Net.get(Net.Names.LabSnapshot)
	for _, player in Players:GetPlayers() do
		remote:FireClient(player, buildSnapshot(player))
	end
end

local function broadcastDebug()
	if not DevConfig.ShowDebugOverlay or not chassisRig then
		return
	end

	local compression, grounded, surface, health = {}, {}, {}, {}
	for index, id in PhysicsChassis.WheelOrder do
		local wheel = chassisRig:getWheels()[id]
		compression[index] = math.floor(wheel.compression * 100) / 100
		grounded[index] = wheel.grounded
		surface[index] = wheel.surface
		health[index] = math.floor((chassisRig.suspensionHealth[id] or 1) * 100) / 100
	end

	local tension, strapHealth = {}, {}
	for index, id in LabConfig.StrapOrder do
		local strap = cargoLoad:getStrap(id)
		tension[index] = math.floor(strap.tension * 100) / 100
		strapHealth[index] = math.floor(strap.health)
	end

	local offset = cargoLoad.localOffset or Vector3.zero

	Net.get(Net.Names.LabDebug):FireAllClients({
		loadLocalX = math.floor(offset.X * 100) / 100,
		loadLocalY = math.floor(offset.Y * 100) / 100,
		loadLocalZ = math.floor(offset.Z * 100) / 100,
		lateralAccel = math.floor(chassisRig.lateralAccel),
		longitudinalAccel = math.floor(chassisRig.longitudinalAccel),
		turnSeverity = math.floor(chassisRig.turnSeverity * 100) / 100,
		brakeForce = math.floor(chassisRig.brakeForce),
		rollDeg = math.floor(chassisRig:getRollDegrees()),
		pitchDeg = math.floor(chassisRig:getPitchDegrees()),
		wheelCompression = compression,
		wheelGrounded = grounded,
		wheelSurface = surface,
		suspensionHealth = health,
		steeringHealth = math.floor(chassisRig.steeringHealth * 100) / 100,
		strapTension = tension,
		strapHealth = strapHealth,
		activePressure = director and director:getActiveLabel() or "none",
		lastCause = cargoLoad.lastCause ~= "" and cargoLoad.lastCause or chassisRig.lastCause,
	})
end

-- ------------------------------------------------------------------ phases

local function assignRoles()
	local players = Players:GetPlayers()
	local hasDriver = currentDriver() ~= nil

	--[[
		If the driver left, somebody already on the bed takes the wheel. Without
		this the crew keeps its existing Strapper roles, nobody is assigned, and
		the truck silently never moves again.
	]]
	if not hasDriver then
		for _, player in players do
			if roles[player.UserId] == "Strapper" then
				stations:detach(player)
				roles[player.UserId] = "Driver"
				if stations:attach(player, "Driver") then
					hasDriver = true
					toast(player.Name .. " has the wheel.")
					break
				end
				roles[player.UserId] = nil
			end
		end
	end

	for _, player in players do
		if roles[player.UserId] then
			continue
		end
		if not hasDriver then
			roles[player.UserId] = "Driver"
			hasDriver = true
		else
			roles[player.UserId] = "Strapper"
		end
	end

	for _, player in players do
		local role = roles[player.UserId]
		if stations:attach(player, role) then
			telemetry:noteRole(player.Name, role)
		elseif role == "Strapper" then
			-- Bed is full; they watch this run out.
			roles[player.UserId] = nil
		end
	end
end

local function enterStaging()
	phase = "Staging"
	phaseClock = 0
	outcome = nil
	crateSaved = nil
	restartSeconds = LabConfig.RestartDelaySeconds
	timeRemaining = LabConfig.RunTimeLimitSeconds
	objective = "Loading up. Hold on."

	chassisRig:reset()
	cargoLoad:reset()
	stations:reset()
	director:reset()
	telemetry:reset()
	table.clear(driveInputs)

	assignRoles()
end

local function enterRun()
	phase = "Run"
	phaseClock = 0
	objective = "Get the load to the depot."

	--[[
		The scripted opener. One strap is compromised before the truck moves, so
		the first corner has something to find. Nothing about the outcome is
		scripted: brake early and it holds.
	]]
	cargoLoad:weakenStrap(
		LabConfig.OpeningWeakStrap,
		LabConfig.StrapMaxHealth - LabConfig.OpeningWeakHealth
	)
	telemetry:log("opening_weak_strap", LabConfig.OpeningWeakStrap)
	toast("Rolling. " .. LabConfig.OpeningWeakStrap .. " strap went on tired.")
end

local function enterResult(result: string, saved: boolean)
	if phase == "Result" then
		return
	end
	phase = "Result"
	phaseClock = 0
	outcome = result
	crateSaved = saved
	restartSeconds = LabConfig.ResultDisplaySeconds

	local headline = if result == "Delivered" then "Clean delivery."
		elseif result == "PartialLoss" then "Delivered, but the load took a beating."
		elseif result == "CargoLost" then "You lost the load."
		elseif result == "TruckWrecked" then "Truck is finished."
		else "Ran out of road time."
	objective = headline
	toast(headline .. " Restarting shortly, or press R.")

	telemetry:finish(result, saved)
end

local function evaluateDelivery()
	local chassis = chassisRig:getChassis()
	local flat = Vector3.new(chassis.Position.X, 0, chassis.Position.Z)
	local target = Vector3.new(route.deliveryPosition.X, 0, route.deliveryPosition.Z)
	if (flat - target).Magnitude > 20 or chassisRig:getSpeed() > 14 then
		return
	end

	local broken = 0
	for _, id in LabConfig.StrapOrder do
		if cargoLoad:getStrap(id).broken then
			broken += 1
		end
	end

	if cargoLoad.condition == "Lost" then
		enterResult("CargoLost", false)
	elseif broken > 0 or cargoLoad.offset > LabConfig.SlidingOffset or cargoLoad.readout < 62 then
		enterResult("PartialLoss", true)
	else
		enterResult("Delivered", true)
	end
end

-- ------------------------------------------------------------------- step

local function step(dt: number)
	dt = math.min(dt, 1 / 20)
	phaseClock += dt

	--[[
		Seats hand network ownership of the assembly to whoever sat down, which
		would silently disable every force the chassis applies. Ownership is
		reclaimed on each seating, and re-checked here in case a seat change
		slipped past that.
	]]
	ownershipAccumulator += dt
	if ownershipAccumulator >= 1 then
		ownershipAccumulator = 0
		chassisRig:claimOwnership()
		cargoLoad:claimOwnership()
	end

	local input = driveState()
	chassisRig:step(dt, input, cargoLoad:getMass())
	cargoLoad:step(dt)
	stations:step(dt)

	if phase == "Run" then
		timeRemaining -= dt

		local progress = chassisRig:getRouteProgress()
		director:step(dt, progress)

		if chassisRig:getSpeed() > 3 then
			telemetry:noteMovement()
		end

		local changed, previous, reportedCause = cargoLoad:consumeConditionChange()
		if changed then
			local cause = reportedCause
			if not cause then
				cause = string.format(
					"lat %.0f, turn %.2f, offset %.1f",
					chassisRig.lateralAccel,
					chassisRig.turnSeverity,
					cargoLoad.offset
				)
			end
			telemetry:noteCondition(previous, cargoLoad.condition, cause)

			-- The opener happens early and near the corner. Anything serious
			-- after that came out of accumulated state, which is the whole
			-- point of the exercise.
			local severity = cargoLoad.condition
			if severity ~= "Secure" and severity ~= "Shifted" then
				-- The blind corner finishes around 17% of the route, so
				-- anything serious past a quarter came out of accumulated
				-- state rather than the scripted opener.
				if progress < 0.25 then
					telemetry:noteDesignedCascade()
				else
					telemetry:noteEmergentCascade(cause)
				end
			end
		end

		if chassisRig:isWrecked() then
			enterResult("TruckWrecked", false)
		elseif cargoLoad.lost then
			enterResult("CargoLost", false)
		elseif timeRemaining <= 0 then
			enterResult("TimeExpired", cargoLoad.condition ~= "Lost")
		else
			evaluateDelivery()
		end
	elseif phase == "Staging" then
		restartSeconds = math.max(0, LabConfig.RestartDelaySeconds - phaseClock)
		if #Players:GetPlayers() > 0 and phaseClock >= LabConfig.RestartDelaySeconds then
			enterRun()
		end
	elseif phase == "Result" then
		restartSeconds = math.max(0, LabConfig.ResultDisplaySeconds - phaseClock)
		if phaseClock >= LabConfig.ResultDisplaySeconds then
			enterStaging()
		end
	end

	snapshotAccumulator += dt
	if snapshotAccumulator >= 0.1 then
		snapshotAccumulator = 0
		broadcastSnapshot()
	end

	debugAccumulator += dt
	if debugAccumulator >= 0.2 then
		debugAccumulator = 0
		broadcastDebug()
	end
end

-- ---------------------------------------------------------------- remotes

local function bindRemotes()
	Net.get(Net.Names.LabDrive).OnServerEvent:Connect(function(player: Player, payload: any)
		if not driveLimiter:allow(player) then
			return
		end
		if roles[player.UserId] ~= "Driver" or phase ~= "Run" then
			return
		end
		if typeof(payload) ~= "table" then
			return
		end

		local throttle, steering, braking = payload.throttle, payload.steering, payload.braking
		local function finite(value: any): boolean
			return typeof(value) == "number" and value == value and math.abs(value) < math.huge
		end
		if not finite(throttle) or not finite(steering) or typeof(braking) ~= "boolean" then
			return
		end

		if math.abs(throttle) > 0.05 or math.abs(steering) > 0.05 or braking then
			telemetry:noteInput(player.Name)
		end

		driveInputs[player.UserId] = {
			throttle = math.clamp(throttle, -1, 1),
			steering = math.clamp(steering, -1, 1),
			braking = braking,
			at = os.clock(),
		}
	end)

	Net.get(Net.Names.LabMoveTo).OnServerEvent:Connect(function(player: Player, target: any)
		if not actionLimiter:allow(player) then
			return
		end
		if typeof(target) ~= "string" or roles[player.UserId] ~= "Strapper" or phase ~= "Run" then
			return
		end

		local ok, message = stations:requestMove(player, target)
		if ok then
			telemetry:noteStationMove(player.Name, target)
		end
		Net.get(Net.Names.LabEvent):FireClient(player, message)
	end)

	Net.get(Net.Names.LabWork).OnServerEvent:Connect(function(player: Player, working: any)
		if not actionLimiter:allow(player) then
			return
		end
		if typeof(working) ~= "boolean" or roles[player.UserId] ~= "Strapper" then
			return
		end

		stations:setWorking(player, working and phase == "Run")
		if working then
			telemetry:noteInput(player.Name)
			local slot = stations:getSlot(player)
			if slot and slot.station then
				telemetry:noteAction(player.Name, "work_" .. slot.station)
			end
		end
	end)

	Net.get(Net.Names.LabRestart).OnServerEvent:Connect(function(player: Player)
		if not actionLimiter:allow(player) then
			return
		end
		if phase == "Staging" then
			return
		end
		if phase == "Run" then
			telemetry:finish("Abandoned", false)
		end
		enterStaging()
		toast(player.Name .. " reset the run.")
	end)

	--[[
		Role switching is deliberately blunt: hand the wheel over, or take it if
		nobody has it. A four-player test needs to be able to rotate the driver
		without anyone leaving.
	]]
	Net.get(Net.Names.LabSwitchRole).OnServerEvent:Connect(function(player: Player)
		if not actionLimiter:allow(player) then
			return
		end

		local role = roles[player.UserId]
		if role == "Driver" then
			stations:detach(player)
			roles[player.UserId] = "Strapper"
			if not stations:attach(player, "Strapper") then
				roles[player.UserId] = nil
			end
			toast(player.Name .. " stepped off the wheel.")
		elseif role == "Strapper" and not currentDriver() then
			stations:detach(player)
			roles[player.UserId] = "Driver"
			stations:attach(player, "Driver")
			toast(player.Name .. " took the wheel.")
		else
			Net.get(Net.Names.LabEvent):FireClient(player, "Someone else already has the wheel.")
			return
		end

		telemetry:noteRole(player.Name, roles[player.UserId] or "Spectator")
	end)
end

-- ---------------------------------------------------------------- players

local function onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then
		return
	end
	-- Seating happens a frame later or the character is not fully assembled.
	task.wait(0.35)
	if not roles[player.UserId] then
		local hasDriver = currentDriver() ~= nil
		roles[player.UserId] = if hasDriver then "Strapper" else "Driver"
	end
	if not stations:attach(player, roles[player.UserId]) then
		roles[player.UserId] = nil
		return
	end
	telemetry:noteRole(player.Name, roles[player.UserId])
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		onCharacter(player, character)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	stations:detach(player)
	roles[player.UserId] = nil
	driveInputs[player.UserId] = nil
end

function TruckLab.init()
	Net.ensureServer()

	route = WorldBuilder.buildLabRoute()
	telemetry = LabTelemetry.new()
	chassisRig = PhysicsChassis.new(route)
	cargoLoad = CargoLoad.new(chassisRig, route.root)
	stations = StrapperStations.new(chassisRig, cargoLoad)
	director = PressureDirector.new(chassisRig, cargoLoad, function(label: string, detail: string)
		telemetry:notePressure(label, chassisRig:getRouteProgress())
		toast(label)
	end)

	bindRemotes()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	enterStaging()

	RunService.Heartbeat:Connect(function(dt: number)
		local ok, err = pcall(step, dt)
		if not ok then
			warn("[CargoLab] step error: " .. tostring(err))
		end
	end)

	print("[CargoLab] Fun-test mode running. One crew, one route, physics truck.")
end

return TruckLab
