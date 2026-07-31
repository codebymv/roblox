--!nonstrict

--[[
	One fun-test run, as an object.

	This was a set of fifteen mutable file-level locals in TruckLab. That works
	exactly once per server, which is why the smoke test could never construct a
	run, tear it down, and assert on what happened, and why the rebuild command
	had to reach into module state to swap the rig out.

	CrewMatch on the depot side is already a class per crew, so this is the
	pattern the project had and the fun-test build regressed away from.

	The session does not build the world. It is handed a route and owns
	everything downstream of it: the rig, the crew, the phase machine, the
	remotes and its own Heartbeat connection. destroy puts all of that back.

	Phases: Staging -> Run -> Result -> Staging.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevConfig = require(Shared:WaitForChild("DevConfig"))
local LabConfig = require(Shared:WaitForChild("LabConfig"))
local LabRemotes = require(Shared:WaitForChild("LabRemotes"))
local Net = require(Shared:WaitForChild("Net"))

local CargoLoad = require(script.Parent.CargoLoad)
local LabTelemetry = require(script.Parent.LabTelemetry)
local PhysicsChassis = require(script.Parent.PhysicsChassis)
local PressureDirector = require(script.Parent.PressureDirector)
local RateLimiter = require(script.Parent.RateLimiter)
local StrapperStations = require(script.Parent.StrapperStations)
local WorldBuilder = require(script.Parent.WorldBuilder)

local SNAPSHOT_INTERVAL = 0.1
local DEBUG_INTERVAL = 0.2
local OWNERSHIP_INTERVAL = 1
local INPUT_SAMPLE_INTERVAL = 0.25

-- Below twenty frames a second the solver is already in trouble; clamping
-- stops a hitch from being integrated as one enormous step.
local MAX_STEP = 1 / 20

local LabSession = {}
LabSession.__index = LabSession

export type Config = {
	route: WorldBuilder.LabRouteInfo,
}

function LabSession.new(config: Config)
	assert(config and config.route, "LabSession requires a route")

	local self = setmetatable({
		route = config.route,

		phase = "Staging",
		phaseClock = 0,
		timeRemaining = LabConfig.RunTimeLimitSeconds,
		outcome = nil,
		crateSaved = nil,
		restartSeconds = 0,
		objective = "Waiting for a crew.",

		roles = {},
		driveInputs = {},

		driveLimiter = RateLimiter.new(25, 40),
		actionLimiter = RateLimiter.new(8, 12),

		snapshotAccumulator = 0,
		debugAccumulator = 0,
		ownershipAccumulator = 0,
		sampleAccumulator = 0,

		-- Set when the simulation step throws. See _bindHeartbeat for why this
		-- latches rather than retrying.
		stepFailed = false,
		started = false,

		connections = {},
	}, LabSession)

	self.telemetry = LabTelemetry.new()
	self:_buildRig()

	return self
end

function LabSession:_track(connection: RBXScriptConnection)
	table.insert(self.connections, connection)
	return connection
end

-- --------------------------------------------------------------------- rig

function LabSession:_buildRig()
	self.chassisRig = PhysicsChassis.new(self.route)
	self.cargoLoad = CargoLoad.new(self.chassisRig, self.route.root)
	self.stations = StrapperStations.new(self.chassisRig, self.cargoLoad)
	self.director = PressureDirector.new(self.chassisRig, self.cargoLoad, function(label: string)
		self.telemetry:notePressure(label, self.chassisRig:getRouteProgress())
		self:toast(label)
	end)
end

function LabSession:_destroyRig()
	if self.stations then
		self.stations:destroy()
	end
	if self.cargoLoad then
		self.cargoLoad:destroy()
	end
	if self.chassisRig then
		self.chassisRig:destroy()
	end
	self.stations = nil
	self.cargoLoad = nil
	self.chassisRig = nil
	self.director = nil
end

--[[
	Rebuild the truck from the current LabConfig. Needed for the values that
	are read once while parts are being created -- sizes, densities, mount
	offsets -- which a live attribute edit cannot reach.
]]
function LabSession:rebuildRig(): string
	self:_destroyRig()
	self:_buildRig()
	self:enterStaging()
	return "Rig rebuilt from current LabConfig."
end

--[[
	Drop the truck onto the centreline at a fraction of the route. Strap wear,
	suspension damage and integrity all survive, because that accumulated state
	is usually the thing being tuned.
]]
function LabSession:warpTo(progress: number): string
	progress = math.clamp(progress, 0, 1)
	self.chassisRig:teleport(WorldBuilder.labCFrameAt(self.route, progress))
	self.cargoLoad:reseat()
	self.stations:reseatAll()
	table.clear(self.driveInputs)
	self.telemetry:log("dev_warp", string.format("%.2f", progress))
	return string.format("Warped to %d%% of the route.", math.floor(progress * 100 + 0.5))
end

function LabSession:getLandmarks()
	return self.route.landmarks
end

-- ----------------------------------------------------------------- players

function LabSession:currentDriver(): Player?
	for userId, role in self.roles do
		if role == "Driver" then
			return Players:GetPlayerByUserId(userId)
		end
	end
	return nil
end

function LabSession:toast(text: string)
	LabRemotes.fireAllClients(Net.Names.LabEvent, text)
end

function LabSession:_driveState()
	local driver = self:currentDriver()
	if not driver or self.phase ~= "Run" then
		return { throttle = 0, steering = 0, braking = self.phase ~= "Run" }
	end
	local state = self.driveInputs[driver.UserId]
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

-- --------------------------------------------------------------- snapshots

--[[
	Everything in the snapshot that is the same for everybody. Built once per
	broadcast rather than once per player: snapshotStraps and stations:snapshot
	each allocate a fresh array, and at four players that was four identical
	copies of both, ten times a second.
]]
function LabSession:_buildSharedSnapshot()
	local chassisRig = self.chassisRig
	local cargoLoad = self.cargoLoad

	return {
		phase = self.phase,
		timeRemaining = math.max(0, math.floor(self.timeRemaining)),
		routeProgress = if chassisRig then chassisRig:getRouteProgress() else 0,
		speed = if chassisRig then math.floor(chassisRig:getSpeed()) else 0,

		condition = if cargoLoad then cargoLoad.condition else "Secure",
		cargoReadout = if cargoLoad then cargoLoad.readout else 100,
		cargoOffset = if cargoLoad then math.floor(cargoLoad.offset * 10) / 10 else 0,
		cargoLeanDeg = if cargoLoad then math.floor(cargoLoad.leanDeg) else 0,

		chassisIntegrity = if chassisRig then math.floor(chassisRig:getIntegrity()) else 100,
		straps = if cargoLoad then cargoLoad:snapshotStraps() else {},
		crew = if self.stations then self.stations:snapshot() else {},

		objective = self.objective,
		outcome = self.outcome,
		crateSaved = self.crateSaved,
		restartSeconds = math.max(0, math.floor(self.restartSeconds)),

		-- myRole, myStation and myMovingTo are per-player and may legitimately
		-- be absent, so _applyPersonalFields writes them just before each send.
		myThrown = false,
		hint = "",
	}
end

function LabSession:_applyPersonalFields(snapshot, player: Player)
	local role = self.roles[player.UserId]
	local slot = self.stations and self.stations:getSlot(player)

	snapshot.myRole = role
	snapshot.myStation = slot and slot.station or nil
	snapshot.myMovingTo = slot and slot.movingTo or nil
	snapshot.myThrown = (slot and slot.thrown) or false
	snapshot.hint = hintFor(role)
	return snapshot
end

function LabSession:buildSnapshotFor(player: Player)
	return self:_applyPersonalFields(self:_buildSharedSnapshot(), player)
end

--[[
	The payload table is reused across players. FireClient serialises its
	arguments at call time, so overwriting the personal fields between calls is
	safe and saves one table plus two arrays per player per tick.
]]
function LabSession:_broadcastSnapshot()
	local snapshot = self:_buildSharedSnapshot()
	for _, player in Players:GetPlayers() do
		LabRemotes.fireClient(Net.Names.LabSnapshot, player, self:_applyPersonalFields(snapshot, player))
	end
end

function LabSession:_broadcastDebug()
	if not DevConfig.ShowDebugOverlay or not self.chassisRig then
		return
	end

	local chassisRig = self.chassisRig
	local cargoLoad = self.cargoLoad

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

	LabRemotes.fireAllClients(Net.Names.LabDebug, {
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
		activePressure = self.director and self.director:getActiveLabel() or "none",
		lastCause = cargoLoad.lastCause ~= "" and cargoLoad.lastCause or chassisRig.lastCause,
	})
end

-- ------------------------------------------------------------------ phases

function LabSession:_assignRoles()
	local players = Players:GetPlayers()
	local hasDriver = self:currentDriver() ~= nil

	--[[
		If the driver left, somebody already on the bed takes the wheel. Without
		this the crew keeps its existing Strapper roles, nobody is assigned, and
		the truck silently never moves again.
	]]
	if not hasDriver then
		for _, player in players do
			if self.roles[player.UserId] == "Strapper" then
				self.stations:detach(player)
				self.roles[player.UserId] = "Driver"
				if self.stations:attach(player, "Driver") then
					hasDriver = true
					self:toast(player.Name .. " has the wheel.")
					break
				end
				self.roles[player.UserId] = nil
			end
		end
	end

	for _, player in players do
		if self.roles[player.UserId] then
			continue
		end
		if not hasDriver then
			self.roles[player.UserId] = "Driver"
			hasDriver = true
		else
			self.roles[player.UserId] = "Strapper"
		end
	end

	for _, player in players do
		local role = self.roles[player.UserId]
		if self.stations:attach(player, role) then
			self.telemetry:noteRole(player.Name, role)
		elseif role == "Strapper" then
			-- Bed is full; they watch this run out.
			self.roles[player.UserId] = nil
		end
	end
end

function LabSession:enterStaging()
	self.phase = "Staging"
	self.phaseClock = 0
	self.outcome = nil
	self.crateSaved = nil
	self.restartSeconds = LabConfig.RestartDelaySeconds
	self.timeRemaining = LabConfig.RunTimeLimitSeconds
	self.objective = "Loading up. Hold on."

	self.chassisRig:reset()
	self.cargoLoad:reset()
	self.stations:reset()
	self.director:reset()
	self.telemetry:reset()
	table.clear(self.driveInputs)

	self:_assignRoles()
end

function LabSession:enterRun()
	self.phase = "Run"
	self.phaseClock = 0
	self.objective = "Get the load to the depot."

	--[[
		The scripted opener. One strap is compromised before the truck moves, so
		the first corner has something to find. Nothing about the outcome is
		scripted: brake early and it holds.
	]]
	self.cargoLoad:weakenStrap(LabConfig.OpeningWeakStrap, LabConfig.StrapMaxHealth - LabConfig.OpeningWeakHealth)
	self.telemetry:log("opening_weak_strap", LabConfig.OpeningWeakStrap)
	self:toast("Rolling. " .. LabConfig.OpeningWeakStrap .. " strap went on tired.")
end

function LabSession:enterResult(result: string, saved: boolean)
	if self.phase == "Result" then
		return
	end
	self.phase = "Result"
	self.phaseClock = 0
	self.outcome = result
	self.crateSaved = saved
	self.restartSeconds = LabConfig.ResultDisplaySeconds

	local headline = if result == "Delivered"
		then "Clean delivery."
		elseif result == "PartialLoss" then "Delivered, but the load took a beating."
		elseif result == "CargoLost" then "You lost the load."
		elseif result == "TruckWrecked" then "Truck is finished."
		else "Ran out of road time."
	self.objective = headline
	self:toast(headline .. " Restarting shortly, or press R.")

	self.telemetry:finish(result, saved)
end

function LabSession:_evaluateDelivery()
	local chassis = self.chassisRig:getChassis()
	local flat = Vector3.new(chassis.Position.X, 0, chassis.Position.Z)
	local target = Vector3.new(self.route.deliveryPosition.X, 0, self.route.deliveryPosition.Z)
	if (flat - target).Magnitude > 20 or self.chassisRig:getSpeed() > 14 then
		return
	end

	local broken = 0
	for _, id in LabConfig.StrapOrder do
		if self.cargoLoad:getStrap(id).broken then
			broken += 1
		end
	end

	if self.cargoLoad.condition == "Lost" then
		self:enterResult("CargoLost", false)
	elseif broken > 0 or self.cargoLoad.offset > LabConfig.SlidingOffset or self.cargoLoad.readout < 62 then
		self:enterResult("PartialLoss", true)
	else
		self:enterResult("Delivered", true)
	end
end

-- -------------------------------------------------------------------- step

function LabSession:step(dt: number)
	dt = math.min(dt, MAX_STEP)
	self.phaseClock += dt

	--[[
		Seats hand network ownership of the assembly to whoever sat down, which
		would silently disable every force the chassis applies. Ownership is
		reclaimed on each seating, and re-checked here in case a seat change
		slipped past that.
	]]
	self.ownershipAccumulator += dt
	if self.ownershipAccumulator >= OWNERSHIP_INTERVAL then
		self.ownershipAccumulator = 0
		self.chassisRig:claimOwnership()
		self.cargoLoad:claimOwnership()
	end

	local input = self:_driveState()
	self.chassisRig:step(dt, input, self.cargoLoad:getMass())
	self.cargoLoad:step(dt)
	self.stations:step(dt)

	if self.phase == "Run" then
		self:_stepRun(dt, input)
	elseif self.phase == "Staging" then
		self.restartSeconds = math.max(0, LabConfig.RestartDelaySeconds - self.phaseClock)
		if #Players:GetPlayers() > 0 and self.phaseClock >= LabConfig.RestartDelaySeconds then
			self:enterRun()
		end
	elseif self.phase == "Result" then
		self.restartSeconds = math.max(0, LabConfig.ResultDisplaySeconds - self.phaseClock)
		if self.phaseClock >= LabConfig.ResultDisplaySeconds then
			self:enterStaging()
		end
	end

	self.snapshotAccumulator += dt
	if self.snapshotAccumulator >= SNAPSHOT_INTERVAL then
		self.snapshotAccumulator = 0
		self:_broadcastSnapshot()
	end

	self.debugAccumulator += dt
	if self.debugAccumulator >= DEBUG_INTERVAL then
		self.debugAccumulator = 0
		self:_broadcastDebug()
	end
end

function LabSession:_stepRun(dt: number, input)
	self.timeRemaining -= dt

	local progress = self.chassisRig:getRouteProgress()
	self.director:step(dt, progress)

	if self.chassisRig:getSpeed() > 3 then
		self.telemetry:noteMovement()
	end

	self.sampleAccumulator += dt
	if self.sampleAccumulator >= INPUT_SAMPLE_INTERVAL then
		self.sampleAccumulator = 0
		self.telemetry:noteDriveSample(
			input.throttle,
			input.steering,
			input.braking,
			self.chassisRig:getSpeed(),
			progress
		)
	end

	local changed, previous, reportedCause = self.cargoLoad:consumeConditionChange()
	if changed then
		local cause = reportedCause
		if not cause then
			cause = string.format(
				"lat %.0f, turn %.2f, offset %.1f",
				self.chassisRig.lateralAccel,
				self.chassisRig.turnSeverity,
				self.cargoLoad.offset
			)
		end
		self.telemetry:noteCondition(previous, self.cargoLoad.condition, cause)

		local severity = self.cargoLoad.condition
		if severity ~= "Secure" and severity ~= "Shifted" then
			-- The blind corner finishes around 17% of the route, so anything
			-- serious past a quarter came out of accumulated state rather than
			-- the scripted opener.
			if progress < 0.25 then
				self.telemetry:noteDesignedCascade()
			else
				self.telemetry:noteEmergentCascade(cause)
			end
		end
	end

	if self.chassisRig:isWrecked() then
		self:enterResult("TruckWrecked", false)
	elseif self.cargoLoad.lost then
		self:enterResult("CargoLost", false)
	elseif self.timeRemaining <= 0 then
		self:enterResult("TimeExpired", self.cargoLoad.condition ~= "Lost")
	else
		self:_evaluateDelivery()
	end
end

-- ----------------------------------------------------------------- remotes

--[[
	Payload shape is checked by LabRemotes before any of these run, so each
	handler only has to decide the gameplay question: is this player allowed to
	do this, in this phase.
]]
function LabSession:_bindRemotes()
	self:_track(LabRemotes.bindServer(Net.Names.LabDrive, function(player: Player, drive)
		if not self.driveLimiter:allow(player) then
			return
		end
		if self.roles[player.UserId] ~= "Driver" or self.phase ~= "Run" then
			return
		end

		if math.abs(drive.throttle) > 0.05 or math.abs(drive.steering) > 0.05 or drive.braking then
			self.telemetry:noteInput(player.Name)
		end

		self.driveInputs[player.UserId] = {
			throttle = drive.throttle,
			steering = drive.steering,
			braking = drive.braking,
			at = os.clock(),
		}
	end))

	self:_track(LabRemotes.bindServer(Net.Names.LabMoveTo, function(player: Player, move)
		if not self.actionLimiter:allow(player) then
			return
		end
		if self.roles[player.UserId] ~= "Strapper" or self.phase ~= "Run" then
			return
		end

		local ok, message = self.stations:requestMove(player, move.station)
		if ok then
			self.telemetry:noteStationMove(player.Name, move.station)
		end
		LabRemotes.fireClient(Net.Names.LabEvent, player, message)
	end))

	self:_track(LabRemotes.bindServer(Net.Names.LabWork, function(player: Player, work)
		if not self.actionLimiter:allow(player) then
			return
		end
		if self.roles[player.UserId] ~= "Strapper" then
			return
		end

		self.stations:setWorking(player, work.working and self.phase == "Run")
		if work.working then
			self.telemetry:noteInput(player.Name)
			local slot = self.stations:getSlot(player)
			if slot and slot.station then
				self.telemetry:noteAction(player.Name, "work_" .. slot.station)
			end
		end
	end))

	self:_track(LabRemotes.bindServer(Net.Names.LabRestart, function(player: Player)
		if not self.actionLimiter:allow(player) then
			return
		end

		-- A restart is also the way back from a halted simulation, so the latch
		-- clears before the usual "already staging, nothing to do" guard.
		if self.stepFailed then
			self.stepFailed = false
			self:enterStaging()
			self:toast(player.Name .. " restarted after an error.")
			return
		end
		if self.phase == "Staging" then
			return
		end
		if self.phase == "Run" then
			self.telemetry:finish("Abandoned", false)
		end
		self:enterStaging()
		self:toast(player.Name .. " reset the run.")
	end))

	--[[
		Role switching is deliberately blunt: hand the wheel over, or take it if
		nobody has it. A four-player test needs to be able to rotate the driver
		without anyone leaving.
	]]
	self:_track(LabRemotes.bindServer(Net.Names.LabSwitchRole, function(player: Player)
		if not self.actionLimiter:allow(player) then
			return
		end

		local role = self.roles[player.UserId]
		if role == "Driver" then
			self.stations:detach(player)
			self.roles[player.UserId] = "Strapper"
			if not self.stations:attach(player, "Strapper") then
				self.roles[player.UserId] = nil
			end
			self:toast(player.Name .. " stepped off the wheel.")
		elseif role == "Strapper" and not self:currentDriver() then
			self.stations:detach(player)
			self.roles[player.UserId] = "Driver"
			self.stations:attach(player, "Driver")
			self:toast(player.Name .. " took the wheel.")
		else
			LabRemotes.fireClient(Net.Names.LabEvent, player, "Someone else already has the wheel.")
			return
		end

		self.telemetry:noteRole(player.Name, self.roles[player.UserId] or "Spectator")
	end))
end

function LabSession:_onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid or not self.stations then
		return
	end
	-- Seating happens a frame later or the character is not fully assembled.
	task.wait(0.35)
	if not self.stations then
		return
	end
	if not self.roles[player.UserId] then
		local hasDriver = self:currentDriver() ~= nil
		self.roles[player.UserId] = if hasDriver then "Strapper" else "Driver"
	end
	if not self.stations:attach(player, self.roles[player.UserId]) then
		self.roles[player.UserId] = nil
		return
	end
	self.telemetry:noteRole(player.Name, self.roles[player.UserId])
end

function LabSession:_onPlayerAdded(player: Player)
	self:_track(player.CharacterAdded:Connect(function(character: Model)
		self:_onCharacter(player, character)
	end))
	if player.Character then
		task.spawn(function()
			self:_onCharacter(player, player.Character)
		end)
	end
end

function LabSession:_onPlayerRemoving(player: Player)
	self.stations:detach(player)
	self.roles[player.UserId] = nil
	self.driveInputs[player.UserId] = nil
end

function LabSession:_bindHeartbeat()
	--[[
		A step error is almost always the same error every frame. Warning on
		each one buried the run telemetry under thousands of identical lines
		exactly when somebody was trying to read it, so the simulation latches
		off instead: one warning, with a traceback, and a frozen truck that is
		obvious to everyone in the room. Restarting clears the latch, so a
		transient fault does not cost the session.
	]]
	self:_track(RunService.Heartbeat:Connect(function(dt: number)
		if self.stepFailed then
			return
		end
		local ok, err = xpcall(function()
			self:step(dt)
		end, debug.traceback)
		if not ok then
			self.stepFailed = true
			warn("[CargoLab] step error, simulation halted. Press R to restart.\n" .. tostring(err))
			self:toast("Simulation error. Press R to restart.")
		end
	end))
end

-- --------------------------------------------------------------- lifecycle

function LabSession:start()
	if self.started then
		return
	end
	self.started = true

	self:_bindRemotes()

	self:_track(Players.PlayerAdded:Connect(function(player: Player)
		self:_onPlayerAdded(player)
	end))
	self:_track(Players.PlayerRemoving:Connect(function(player: Player)
		self:_onPlayerRemoving(player)
	end))
	for _, player in Players:GetPlayers() do
		self:_onPlayerAdded(player)
	end

	self:enterStaging()
	self:_bindHeartbeat()
end

function LabSession:destroy()
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)

	self.driveLimiter:destroy()
	self.actionLimiter:destroy()

	self:_destroyRig()

	table.clear(self.roles)
	table.clear(self.driveInputs)
	self.started = false
end

return LabSession
