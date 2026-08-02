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
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevConfig = require(Shared:WaitForChild("DevConfig"))
local LabConfig = require(Shared:WaitForChild("LabConfig"))
local LabRemotes = require(Shared:WaitForChild("LabRemotes"))
local LabTypes = require(Shared:WaitForChild("LabTypes"))
local Net = require(Shared:WaitForChild("Net"))
local RunCauses = require(Shared:WaitForChild("RunCauses"))
local DailyContract = require(Shared:WaitForChild("DailyContract"))
local LabRoute = require(Shared:WaitForChild("LabRoute"))
local RunVariants = require(Shared:WaitForChild("RunVariants"))

local CargoLoad = require(script.Parent.CargoLoad)
local AchievementService = require(script.Parent.AchievementService)
local DailyProgressionService = require(script.Parent.DailyProgressionService)
local CommerceService = require(script.Parent.CommerceService)
local LabAnalytics = require(script.Parent.LabAnalytics)
local LabProgressionService = require(script.Parent.LabProgressionService)
local LabTelemetry = require(script.Parent.LabTelemetry)
local PlayerDataService = require(script.Parent.PlayerDataService)
local PhysicsChassis = require(script.Parent.PhysicsChassis)
local PressureDirector = require(script.Parent.PressureDirector)
local RateLimiter = require(script.Parent.RateLimiter)
local StrapperStations = require(script.Parent.StrapperStations)
local WorldBuilder = require(script.Parent.WorldBuilder)
local LabRespawnPolicy = require(Shared:WaitForChild("LabRespawnPolicy"))
local LabRigPolicy = require(Shared:WaitForChild("LabRigPolicy"))

local SNAPSHOT_INTERVAL = 0.1
local DEBUG_INTERVAL = 0.2
-- Safety poll only outside Run; seating paths reclaim immediately.
local OWNERSHIP_INTERVAL = 2
local MOTION_INTERVAL = 0.05
local INPUT_SAMPLE_INTERVAL = 0.25

-- Chassis impulses run on Stepped with a fixed accumulator so hitchy wall-clock
-- dt cannot become one fat ApplyImpulse. Heartbeat keeps phase/UI clocks.
local FIXED_DT = 1 / 60
local MAX_SUBSTEPS = 4
-- Cap how much Stepped dt we absorb into the accumulator in one frame.
local MAX_STEP = 1 / 20
local DELIVERY_CHECK_INTERVAL = 0.2

-- Reused every Heartbeat so idle / brake drive paths allocate nothing.
local DRIVE_IDLE = { throttle = 0, steering = 0, braking = false }
local DRIVE_BRAKE = { throttle = 0, steering = 0, braking = true }

local LabSession = {}
LabSession.__index = LabSession

export type Config = {
	-- Every authored leg, in ladder order. The session stands the rig on one of
	-- them at a time and moves it when a crew climbs or falls.
	routes: { WorldBuilder.LabRouteInfo },
}

function LabSession.new(config: Config)
	assert(config and config.routes and #config.routes > 0, "LabSession requires at least one route")

	local self = setmetatable({
		routes = config.routes,
		route = config.routes[1],
		legIndex = 1,
		-- Set when a finished run changes the leg, so staging knows to move the
		-- rig before it rebuilds anything on it.
		pendingLeg = nil :: number?,

		phase = "Staging",
		phaseClock = 0,
		timeRemaining = LabConfig.RunTimeLimitSeconds,
		outcome = nil,
		outcomeCause = nil,
		crateSaved = nil,
		restartSeconds = 0,
		resultDuration = LabConfig.ResultDisplaySeconds,
		runIndex = 0,
		variantRng = Random.new(),
		runVariant = RunVariants.select(1),
		contractComplete = nil :: boolean?,
		rewardMultiplier = 1,

		-- The board, live only during a Result that has one. Votes are keyed by
		-- UserId so a player who leaves mid-vote takes their vote with them.
		contractOffer = nil :: RunVariants.ContractOffer?,
		contractVotes = {} :: { [number]: string },
		contractChoice = nil :: string?,
		objective = "Waiting for a crew.",

		roles = {},
		driveInputs = {},
		lastRewards = {},
		-- Record keys each player beat on the last finished run, by UserId.
		recordsBeaten = {},
		-- Daily bonus banked on the last finished run, by UserId.
		dailyEarned = {},

		-- Coalesced client flush targets 60 Hz on changed axes; burst covers edges.
		driveLimiter = RateLimiter.new(45, 60),
		actionLimiter = RateLimiter.new(8, 12),

		snapshotAccumulator = 0,
		debugAccumulator = 0,
		ownershipAccumulator = 0,
		motionAccumulator = 0,
		sampleAccumulator = 0,
		deliveryAccumulator = 0,
		physicsAccumulator = 0,
		lastDriveInput = nil :: { throttle: number, steering: number, braking: boolean }?,

		-- Set when the simulation step throws. See _bindHeartbeat for why this
		-- latches rather than retrying.
		stepFailed = false,
		lastPendingRecoverAt = 0,
		started = false,
		-- Coalesce overlapping Result timer + R into a single Staging entry.
		stagingBusy = false,

		-- Landmarks already warned about this run, keyed by name.
		announcedLandmarks = {},
		conditionTrend = "Stable",
		soloWorkingStrap = nil :: string?,
		swapGateIndex = 1,
		swapWarningGate = nil :: number?,
		swapHandoffUntil = 0,
		swapSignsVisible = nil :: boolean?,

		connections = {},
		characterDiedConnections = {} :: { [number]: RBXScriptConnection },
	}, LabSession)

	self.telemetry = LabTelemetry.new()
	self.analytics = LabAnalytics.new()
	-- Commerce binds its receipt callback at boot, before any session exists;
	-- the funnel events belong to whichever session is live.
	CommerceService.attachAnalytics(self.analytics)
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
	end, self.route.features)
end

function LabSession:_rigPreflightOk(): boolean
	if not self.chassisRig or not self.cargoLoad then
		return false
	end
	local chassis = self.chassisRig:getChassis()
	local crate = self.cargoLoad:getCrate()
	if not chassis or not chassis.Parent or not crate or not crate.Parent then
		return false
	end
	return self.chassisRig:hasCompleteWheelSet() and self.cargoLoad:hasCompleteLoad()
end

--[[
	Catch damage Staging missed (partial destroy during countdown, cheap reset
	that left gaps). Forces a full rebuild, then restores the current variant
	pose so enterRun can unfreeze a complete truck.
]]
function LabSession:_ensureRigIntact(): boolean
	if self:_rigPreflightOk() then
		return true
	end
	warn("[CargoLab] Rig incomplete at GO; forcing rebuild.")
	self:_destroyRig()
	self:_buildRig()
	local variant = self.runVariant
	local ok, err = xpcall(function()
		self.chassisRig:reset()
		if variant then
			self.cargoLoad:configure(variant.cargo)
		end
		self.cargoLoad:reset()
		self.chassisRig:setFrozen(true)
		self.cargoLoad:setFrozen(true)
		self.stations:reset()
		if variant then
			self.director:configure(variant.difficulty)
		end
		self.director:reset()
		self:_assignRoles()
		self:_applyDriverCosmetics()
	end, debug.traceback)
	if not ok then
		warn("[CargoLab] Rig rebuild at GO failed.\n" .. tostring(err))
		return false
	end
	return self:_rigPreflightOk()
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
--[[
	Stand the rig on a different leg.

	Both roads are already built and standing, so this is a rebuild at a new
	start rather than a world change: the rig is torn down and put back up at
	the new route's start line, and the pressure director is rebuilt with that
	route's features so difficulty lands on the new road's corners rather than
	the old one's.

	Returns whether anything moved, so staging can announce a change and stay
	quiet about a repeat.
]]
function LabSession:_setLeg(leg: number): boolean
	local clamped = math.clamp(math.floor(leg or 1), 1, #self.routes)
	local target = self.routes[clamped]
	if not target or target == self.route then
		self.legIndex = clamped
		return false
	end

	WorldBuilder.setRouteActive(self.route, false)
	self.legIndex = clamped
	self.route = target
	WorldBuilder.setRouteActive(target, true)

	self:_destroyRig()
	self:_buildRig()
	self.swapGateIndex = 1
	self.swapWarningGate = nil
	self.swapHandoffUntil = 0
	table.clear(self.announcedLandmarks)
	self.telemetry:log("leg_change", target.id)
	return true
end

function LabSession:currentLeg(): number
	return self.legIndex
end

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
	self.swapGateIndex = 1
	while self.route.swapGates[self.swapGateIndex] and self.route.swapGates[self.swapGateIndex] <= progress do
		self.swapGateIndex += 1
	end
	self.swapWarningGate = nil
	self.swapHandoffUntil = 0
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
		return if self.phase ~= "Run" then DRIVE_BRAKE else DRIVE_IDLE
	end
	if os.clock() < self.swapHandoffUntil then
		return DRIVE_BRAKE
	end
	local state = self.driveInputs[driver.UserId]
	local hasFreshInput = state ~= nil and os.clock() - state.at <= 1
	-- Thrown / respawn-blocked Drivers stay braked. A brief SeatWeld drop after
	-- claimOwnership must not discard fresh throttle (that felt like a dead truck
	-- after wreck→GO while the HUD still said ON THE ROAD).
	if self.stations and self.stations:isOffTruck(driver) then
		local slot = self.stations:getSlot(driver)
		local hardOff = slot and (slot.thrown or slot.respawnBlocked)
		if hardOff or not hasFreshInput then
			return DRIVE_BRAKE
		end
	end
	if not hasFreshInput then
		return DRIVE_IDLE
	end
	return state
end

-- --------------------------------------------------------------- snapshots

local CONDITION_SEVERITY = {
	Secure = 0,
	Shifted = 1,
	Leaning = 2,
	Sliding = 3,
	PartiallyDetached = 4,
	Hanging = 5,
	Dragging = 6,
	Lost = 7,
}

-- Player-facing approach copy. Start / Depot / CornerApproach are skipped:
-- the first is noise, the last is the result screen, and CornerApproach
-- duplicates BlindRight a few seconds earlier.
local LANDMARK_WARNING = {
	BlindRight = "Blind corner ahead. Slow down before you can see it.",
	Descent = "Long descent ahead. Keep the load centred.",
	Rough = "Rough road ahead. Watch the straps.",
	LeftBend = "Left bend ahead. Crew on the wrong side will feel it.",
	Bridge = "Narrow bridge ahead. No shoulders.",
	Climb = "Climb ahead. A dragging load will cost you here.",
	SBends = "S-bends ahead. An already-shifted load becomes a second crisis.",
	Switchback = "Switchback ahead. The second turn comes before the load settles.",
	Ice = "Ice ahead. Braking distance just changed.",
	FirstBridge = "First crossing ahead. Keep the truck centred.",
	IceTraverse = "Icy descent ahead. Slow down before gravity chooses for you.",
	SecondBridge = "Second crossing ahead. You will enter it carrying speed.",
	SnowChicane = "Deep-snow chicane ahead. The verge will drag you wide.",
	RoughShelf = "Rough shelf ahead. Get the straps ready.",
}

local LANDMARK_APPROACH = 0.045

--[[
	Everything in the snapshot that is the same for everybody. Built once per
	broadcast rather than once per player: snapshotStraps and stations:snapshot
	each allocate a fresh array, and at four players that was four identical
	copies of both, ten times a second.
]]
function LabSession:_buildSharedSnapshot()
	local chassisRig = self.chassisRig
	local cargoLoad = self.cargoLoad
	local driveState = self:_driveState()
	local roadSurface = "Air"
	if chassisRig then
		local surfaceCounts = {}
		for _, wheel in chassisRig:getWheels() do
			if wheel.grounded then
				local surface = wheel.surface or "Road"
				surfaceCounts[surface] = (surfaceCounts[surface] or 0) + 1
			end
		end
		local bestCount = 0
		for surface, count in surfaceCounts do
			if count > bestCount then
				roadSurface = surface
				bestCount = count
			end
		end
	end
	local today = DailyContract.dayFromUnix(os.time())
	local dailyObjective = DailyContract.forDay(today)
	local crewCount = self:_activeCrewCount()
	local solo = crewCount <= 1
	local runVariant = self.runVariant
	local showSwapSigns = not solo
	if self.swapSignsVisible ~= showSwapSigns then
		self.swapSignsVisible = showSwapSigns
		WorldBuilder.setSwapSignsVisible(self.route, showSwapSigns)
	end

	return {
		phase = self.phase,
		timeRemaining = math.max(0, math.floor(self.timeRemaining)),
		routeProgress = if chassisRig then chassisRig:getRouteProgress() else 0,
		speed = if chassisRig then math.floor(chassisRig:getSpeed()) else 0,
		roadSurface = roadSurface,
		braking = self.phase == "Run" and driveState.braking or false,

		condition = if cargoLoad then cargoLoad.condition else "Secure",
		conditionTrend = self.conditionTrend or "Stable",
		cargoReadout = if cargoLoad then cargoLoad.readout else 100,
		cargoOffset = if cargoLoad then math.floor(cargoLoad.offset * 10) / 10 else 0,
		cargoLeanDeg = if cargoLoad then math.floor(cargoLoad.leanDeg) else 0,

		chassisIntegrity = if chassisRig then math.floor(chassisRig:getIntegrity()) else 100,
		straps = if cargoLoad then cargoLoad:snapshotStraps() else {},
		crew = if self.stations then self.stations:snapshot() else {},
		crewCount = crewCount,
		crewCapacity = LabConfig.MaxCrew,
		legIndex = self.legIndex,
		legCount = #self.routes,
		legLabel = self.route.label,
		cargoLabel = runVariant.cargo.label,
		cargoDescription = runVariant.cargo.description,
		contractLabel = runVariant.contract.label,
		contractBrief = runVariant.contract.brief,
		difficultyLabel = runVariant.difficulty.label,
		contractComplete = self.contractComplete,
		rewardMultiplier = self.rewardMultiplier,
		-- myVote is per-player, so _applyPersonalFields fills it in.
		offer = self:_offerView(),

		objective = self.objective,
		outcome = self.outcome,
		outcomeCause = self.outcomeCause,
		crateSaved = self.crateSaved,
		-- Countdown copy and the large numeral must always describe the same
		-- second. The objective also uses ceil while a partial second remains.
		restartSeconds = math.max(0, math.ceil(self.restartSeconds)),
		simHalted = self.stepFailed == true,
		solo = solo,
		swapWarning = self.swapWarningGate ~= nil and not solo,
		swapActive = os.clock() < self.swapHandoffUntil,

		-- myRole, myStation and myMovingTo are per-player and may legitimately
		-- be absent, so _applyPersonalFields writes them just before each send.
		-- Control hints are derived client-side from role and last input device.
		myThrown = false,
		myOffTruck = false,
		spectating = false,
		queuePosition = nil,
		feedbackRequested = false,
		feedbackSubmitted = false,
		myContractVote = nil,
		records = nil,
		recordsBeaten = nil,
		dailyLabel = dailyObjective.label,
		dailyBrief = dailyObjective.brief,
		dailyBonus = dailyObjective.bonus,
		dailyClaimed = false,
		dailyEarned = 0,
		progressionReady = false,
		progressionSaving = false,
		credits = 0,
		rewardEarned = 0,
		equippedPaint = "Factory",
		unlockedPaints = { Factory = true },
		swapNextRole = nil,
		swapNextStation = nil,
	}
end

--[[
	The board as the client draws it. Nil unless a board is genuinely live, so
	the HUD never has to reason about whether a stale offer still applies.

	Only descriptive fields cross: the authoritative RunVariant stays here, and
	the client's vote is a choice between two names rather than a payload the
	server trusts.
]]
function LabSession:_offerView(): LabTypes.ContractOfferView?
	local offer = self.contractOffer
	if not offer or self.phase ~= "Result" then
		return nil
	end

	local leading, safeVotes, riskyVotes = RunVariants.tally(self.contractVotes, self:_activeCrewCount())
	local function card(variant, votes: number): LabTypes.ContractCard
		return {
			cargoLabel = variant.cargo.label,
			cargoDescription = variant.cargo.description,
			contractLabel = variant.contract.label,
			contractBrief = variant.contract.brief,
			difficultyLabel = variant.difficulty.label,
			rewardMultiplier = RunVariants.rewardMultiplier(variant, true),
			votes = votes,
		}
	end

	return {
		runNumber = offer.runNumber,
		safe = card(offer.safe, safeVotes),
		risky = card(offer.risky, riskyVotes),
		leading = leading,
		secondsRemaining = math.max(0, math.ceil(self.restartSeconds)),
	}
end

function LabSession:_applyPersonalFields(snapshot, player: Player)
	local role = self.roles[player.UserId]
	local slot = self.stations and self.stations:getSlot(player)

	snapshot.myRole = role
	snapshot.spectating = role == nil
	snapshot.feedbackRequested = self.phase == "Result" and role ~= nil and self.analytics:shouldAskForFeedback(player)
	snapshot.feedbackSubmitted = self.phase == "Result" and self.analytics:hasFeedback(player)
	-- Spectators see the board and the running tally, but do not get a vote on
	-- a run they are not going to be on.
	snapshot.myContractVote = if role ~= nil then self.contractVotes[player.UserId] else nil
	snapshot.records = AchievementService.records(player)
	snapshot.dailyClaimed = DailyProgressionService.isClaimed(player, DailyContract.dayFromUnix(os.time()))
	snapshot.dailyEarned = self.dailyEarned[player.UserId] or 0
	snapshot.recordsBeaten = if self.phase == "Result" then self.recordsBeaten[player.UserId] else nil
	local progression = LabProgressionService.snapshot(player)
	snapshot.progressionReady = progression.ready
	snapshot.progressionSaving = progression.saving
	snapshot.credits = progression.credits
	snapshot.rewardEarned = self.lastRewards[player.UserId] or 0
	snapshot.equippedPaint = progression.equippedPaint
	snapshot.unlockedPaints = progression.unlockedPaints
	snapshot.queuePosition = nil
	if snapshot.spectating then
		local position = 0
		for _, candidate in Players:GetPlayers() do
			if self.roles[candidate.UserId] == nil then
				position += 1
				if candidate == player then
					snapshot.queuePosition = position
					break
				end
			end
		end
	end
	snapshot.myStation = slot and slot.station or nil
	snapshot.myMovingTo = slot and slot.movingTo or nil
	snapshot.myThrown = (slot and slot.thrown) or false
	snapshot.myOffTruck = if self.stations then self.stations:isOffTruck(player) else false
	if snapshot.swapWarning and self.stations then
		local assignment = self.stations:previewRotationFor(player)
		snapshot.swapNextRole = assignment and assignment.role or nil
		snapshot.swapNextStation = assignment and assignment.station or nil
	else
		snapshot.swapNextRole = nil
		snapshot.swapNextStation = nil
	end
	return snapshot
end

function LabSession:_isSolo(): boolean
	return self:_activeCrewCount() <= 1
end

function LabSession:_applyDriverCosmetics()
	if self.chassisRig then
		local livery, finish, paintColor = LabProgressionService.cosmeticsFor(self:currentDriver())
		self.chassisRig:setCosmetics(livery, finish, paintColor)
	end
end

-- Spectators and players whose character has not attached to the truck are
-- not crew. Counting every Player disabled the solo Driver's strap controls
-- as soon as a fifth player joined to watch.
function LabSession:_activeCrewCount(): number
	local count = 0
	for userId, role in self.roles do
		if role and Players:GetPlayerByUserId(userId) then
			count += 1
		end
	end
	return count
end

function LabSession:_crewPlayers(): { Player }
	local crew = {}
	for _, player in Players:GetPlayers() do
		if self.roles[player.UserId] then
			table.insert(crew, player)
		end
	end
	return crew
end

function LabSession:_pickSoloWorkStrap(): string?
	local cargoLoad = self.cargoLoad
	if not cargoLoad then
		return nil
	end

	local bestId = nil
	local bestScore = math.huge
	for _, id in LabConfig.StrapOrder do
		local strap = cargoLoad:getStrap(id)
		if not strap then
			continue
		end
		-- Prefer a broken strap that can still be refit; otherwise the weakest.
		local score = if strap.broken and strap.reattachable then -1 elseif strap.broken then math.huge else strap.health
		if score < bestScore then
			bestScore = score
			bestId = id
		end
	end
	return bestId
end

function LabSession:_setSoloWorking(player: Player, working: boolean)
	if not working then
		if self.soloWorkingStrap then
			self.cargoLoad:clearWorker(self.soloWorkingStrap)
			self.soloWorkingStrap = nil
		end
		return
	end

	local id = self:_pickSoloWorkStrap()
	if not id then
		LabRemotes.fireClient(Net.Names.LabEvent, player, "No strap needs work.")
		return
	end
	if self.soloWorkingStrap and self.soloWorkingStrap ~= id then
		self.cargoLoad:clearWorker(self.soloWorkingStrap)
	end
	self.soloWorkingStrap = id
	self.telemetry:noteInput(player.Name)
	self.analytics:noteInput(player, "Driver")
	self.telemetry:noteAction(player.Name, "solo_work_" .. id)
end

function LabSession:_announceLandmarks(progress: number)
	local landmarks = self.route.landmarks
	if not landmarks then
		return
	end

	for _, landmark in landmarks do
		local warning = LANDMARK_WARNING[landmark.name]
		if not warning or self.announcedLandmarks[landmark.name] then
			continue
		end
		local distance = landmark.progress - progress
		if distance >= 0 and distance <= LANDMARK_APPROACH then
			self.announcedLandmarks[landmark.name] = true
			self.objective = warning
			self:toast(warning)
		end
	end
end

function LabSession:_swapLocked(): boolean
	return self.swapWarningGate ~= nil or os.clock() < self.swapHandoffUntil
end

function LabSession:_performCrewSwap(gateIndex: number)
	local assignments, newDriverId = self.stations:rotateCrew(LabConfig.SwapHandoffSeconds)
	if not assignments or not newDriverId then
		return false
	end

	table.clear(self.driveInputs)
	self.soloWorkingStrap = nil
	for userId, assignment in assignments do
		self.roles[userId] = assignment.role
		local player = Players:GetPlayerByUserId(userId)
		if player then
			self.telemetry:noteRole(player.Name, assignment.role)
			self.analytics:roleAssigned(player, assignment.role)
		end
	end

	self.swapWarningGate = nil
	self.swapHandoffUntil = os.clock() + LabConfig.SwapHandoffSeconds
	self.swapGateIndex = gateIndex + 1
	local newDriver = Players:GetPlayerByUserId(newDriverId)
	local driverName = if newDriver then newDriver.Name else "A new Driver"
	self.objective = "SWAP! " .. driverName .. " has the wheel."
	self.telemetry:noteCrewSwap(gateIndex, driverName)
	self.analytics:crewSwap(gateIndex, self:_crewPlayers())
	self:_broadcastSnapshot()
	return true
end

function LabSession:_stepSwapGates(progress: number)
	local now = os.clock()
	if self.swapHandoffUntil > 0 and now >= self.swapHandoffUntil then
		self.swapHandoffUntil = 0
		self.objective = "GO · get the load to the depot."
		self:_broadcastSnapshot()
	end

	local gates = self.route.swapGates or LabConfig.SwapGateProgress
	local gateIndex = self.swapGateIndex
	local gateProgress = gates[gateIndex]
	if not gateProgress then
		return
	end

	local crewCount = self:_activeCrewCount()
	if progress >= gateProgress then
		if crewCount >= 2 and self:_performCrewSwap(gateIndex) then
			return
		end
		-- Solo runs pass the physical sign without a fake handoff.
		self.swapWarningGate = nil
		self.swapGateIndex = gateIndex + 1
		return
	end

	local shouldWarn = crewCount >= 2 and progress >= gateProgress - LabConfig.SwapWarningProgress
	if shouldWarn and self.swapWarningGate ~= gateIndex then
		self.swapWarningGate = gateIndex
		self.objective = "Red SWAP gate ahead. Finish your current move."
		self.telemetry:log("crew_swap_warning", "gate_" .. tostring(gateIndex))
		self:toast("SWAP AHEAD · everyone rotates at the red signs.")
		self:_broadcastSnapshot()
	elseif not shouldWarn and self.swapWarningGate == gateIndex then
		self.swapWarningGate = nil
		self.objective = "GO · get the load to the depot."
		self:_broadcastSnapshot()
	end
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
		if wheel then
			compression[index] = math.floor((wheel.compression or 0) * 100) / 100
			grounded[index] = wheel.grounded == true
			surface[index] = wheel.surface or "Air"
		else
			compression[index] = 0
			grounded[index] = false
			surface[index] = "Air"
		end
		health[index] = math.floor((chassisRig.suspensionHealth[id] or 1) * 100) / 100
	end

	local tension, strapHealth = {}, {}
	for index, id in LabConfig.StrapOrder do
		local strap = cargoLoad:getStrap(id)
		if strap then
			tension[index] = math.floor(strap.tension * 100) / 100
			strapHealth[index] = math.floor(strap.health)
		else
			tension[index] = 0
			strapHealth[index] = 0
		end
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
	local newlyAssigned = {}

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
					self.telemetry:noteRole(player.Name, "Driver")
					self.analytics:roleAssigned(player, "Driver")
					self:toast(player.Name .. " has the wheel.")
					break
				end
				self.roles[player.UserId] = nil
			end
		end
	end

	local crewCount = self:_activeCrewCount()
	for _, player in players do
		if self.roles[player.UserId] then
			continue
		end
		if crewCount >= LabConfig.MaxCrew then
			continue
		end
		if not hasDriver then
			self.roles[player.UserId] = "Driver"
			hasDriver = true
		else
			self.roles[player.UserId] = "Strapper"
		end
		newlyAssigned[player.UserId] = true
		crewCount += 1
	end

	for _, player in players do
		local role = self.roles[player.UserId]
		if not role then
			continue
		end
		if self.stations:getSlot(player) then
			continue
		end
		if self.stations:attach(player, role) then
			self.telemetry:noteRole(player.Name, role)
			self.analytics:roleAssigned(player, role)
			if newlyAssigned[player.UserId] then
				LabRemotes.fireClient(Net.Names.LabEvent, player, "Crew seat ready. You are " .. role .. ".")
			end
		else
			-- Keep the role. A Sit that is one beat early was wiping crew to
			-- spectators who then could not press R.
			LabRemotes.fireClient(Net.Names.LabEvent, player, "Seat not ready yet - holding your crew spot.")
		end
	end
end

function LabSession:enterStaging()
	if self.stagingBusy then
		return
	end
	self.stagingBusy = true

	-- Before the board resolves or the rig resets, because both are built
	-- against whichever road the session is standing on.
	local pendingLeg = self.pendingLeg
	self.pendingLeg = nil
	self.legChanged = pendingLeg ~= nil and self:_setLeg(pendingLeg)

	local nextRunNumber = self.runIndex + 1
	--[[
		A wreck is not a trustworthy assembly to recycle. Its independently
		positioned wheel targets can cross FallenPartsDestroyHeight before Result
		freezes the chassis; reset() correctly skips missing parts, but those same
		parts are what supply suspension, grip and engine force. That produced a
		wheel-less second-run truck which said GO and could not move.

		Rebuild after a wreck, cargo loss, a latched simulation error, or any
		detected wheel/cargo damage. Clean deliveries keep the cheaper in-place
		reset. Predicate lives in LabRigPolicy for headless coverage.
	]]
	local rebuildRig = LabRigPolicy.shouldRebuildRig({
		outcome = self.outcome,
		stepFailed = self.stepFailed,
		hasChassis = self.chassisRig ~= nil,
		hasCargo = self.cargoLoad ~= nil,
		wrecked = self.chassisRig ~= nil and self.chassisRig:isWrecked(),
		wheelsOk = self.chassisRig ~= nil and self.chassisRig:hasCompleteWheelSet(),
		cargoOk = self.cargoLoad ~= nil and self.cargoLoad:hasCompleteLoad(),
	})
	-- A decided board wins. Without one — run one, or a restart that skipped
	-- the result screen — fall back to the server roll this replaced.
	self.runVariant = self:_resolveContractBoard()
		or RunVariants.select(
			nextRunNumber,
			self.variantRng:NextNumber(),
			self.variantRng:NextNumber(),
			self.variantRng:NextNumber()
		)
	local variant = self.runVariant
	self.stepFailed = false
	self.phase = "Staging"
	self.phaseClock = 0
	self.outcome = nil
	self.outcomeCause = nil
	self.crateSaved = nil
	self.restartSeconds = LabConfig.RestartDelaySeconds
	self.resultDuration = LabConfig.ResultDisplaySeconds
	self.timeRemaining = variant.contract.timeLimit
	self.objective = "Get ready."
	self.contractComplete = nil
	self.rewardMultiplier = variant.difficulty.rewardMultiplier
	self.conditionTrend = "Stable"
	self.soloWorkingStrap = nil
	self.swapGateIndex = 1
	self.swapWarningGate = nil
	self.swapHandoffUntil = 0
	self.deliveryAccumulator = 0
	table.clear(self.announcedLandmarks)
	table.clear(self.driveInputs)

	-- reset() keeps both assemblies frozen through the teleport/reseat so a
	-- wreck in the void cannot fling parts for a solver frame before freeze.
	local ok, err = xpcall(function()
		if rebuildRig then
			self:_destroyRig()
			self:_buildRig()
		end
		self.chassisRig:reset()
		self.cargoLoad:configure(variant.cargo)
		self.cargoLoad:reset()
		self.chassisRig:setFrozen(true)
		self.cargoLoad:setFrozen(true)
		self.stations:reset()
		self.director:configure(variant.difficulty)
		self.director:reset()
		self.telemetry:reset()
		self:_assignRoles()
		self:_applyDriverCosmetics()
	end, debug.traceback)
	if not ok then
		self.stepFailed = true
		warn("[CargoLab] enterStaging failed.\n" .. tostring(err))
		self:toast("Simulation error. Press R to restart.")
		self.stagingBusy = false
		return
	end

	-- Assign can attach a fresh slot without a successful Sit (character still
	-- assembling). One deferred recover catches that without delaying the phase.
	task.defer(function()
		if self.phase == "Staging" and self.stations and not self.stepFailed then
			self.stations:recoverAll()
			self:_recoverPendingCrew()
		end
	end)
	self.stagingBusy = false
end

--[[
	Seat anyone who still holds a role but has no living Occupant, once the
	truck is in a safe attach band. Covers Result→Staging respawns and Sit
	attempts that were one beat early. Throttled: must not fight throw recovery
	or claimOwnership Sit flicker every Heartbeat.
]]
function LabSession:_recoverPendingCrew()
	if not self.stations or not self.chassisRig or self.stepFailed then
		return
	end
	local now = os.clock()
	if now - (self.lastPendingRecoverAt or 0) < 0.75 then
		return
	end
	local chassis = self.chassisRig:getChassis()
	if not chassis then
		return
	end
	if
		not LabRespawnPolicy.shouldAttach(self.phase, self.chassisRig:isWrecked(), chassis.Position.Y, LabConfig.VoidY)
	then
		return
	end

	local neededRecover = false
	for _, player in Players:GetPlayers() do
		local role = self.roles[player.UserId]
		if not role then
			continue
		end
		local slot = self.stations:getSlot(player)
		if not slot then
			self.lastPendingRecoverAt = now
			if self.stations:attach(player, role) then
				self.telemetry:noteRole(player.Name, role)
				self.analytics:roleAssigned(player, role)
			end
		elseif slot.respawnBlocked then
			neededRecover = true
		end
	end
	if neededRecover then
		self.lastPendingRecoverAt = now
		self.stations:recoverAll()
	end
end

function LabSession:enterRun()
	-- Anything Staging missed (partial destroy during countdown) must not GO.
	if not self:_ensureRigIntact() then
		self.stepFailed = true
		self.phase = "Staging"
		self:toast("Truck not ready. Press R to reset.")
		return
	end

	-- Release both assemblies in the same scheduler turn. setFrozen clears
	-- velocities before unanchoring, preventing a one-frame launch at GO.
	self.cargoLoad:setFrozen(false)
	self.chassisRig:setFrozen(false)
	local chassisClaimed = self.chassisRig:claimOwnership()
	self.cargoLoad:claimOwnership()
	-- Ownership reclaim can drop SeatWelds; reseat before the first drive tick
	-- so the Driver is Occupant and isOffTruck cannot latch forced braking.
	if self.stations then
		if chassisClaimed then
			self.stations:markOwnershipSettle()
		end
		self.stations:recoverAll()
	end
	-- Sit can re-grant client ownership; claim again after recoverAll.
	chassisClaimed = self.chassisRig:claimOwnership()
	self.cargoLoad:claimOwnership()
	if chassisClaimed and self.stations then
		self.stations:markOwnershipSettle()
	end

	local chassis = self.chassisRig:getChassis()
	local crate = self.cargoLoad:getCrate()
	if (chassis and chassis.Anchored) or (crate and crate.Anchored) then
		self.cargoLoad:setFrozen(false)
		self.chassisRig:setFrozen(false)
		chassisClaimed = self.chassisRig:claimOwnership()
		self.cargoLoad:claimOwnership()
		if chassisClaimed and self.stations then
			self.stations:markOwnershipSettle()
		end
		chassis = self.chassisRig:getChassis()
		crate = self.cargoLoad:getCrate()
	end
	if (chassis and chassis.Anchored) or (crate and crate.Anchored) then
		self.stepFailed = true
		self.chassisRig:setFrozen(true)
		self.cargoLoad:setFrozen(true)
		self.phase = "Staging"
		self:toast("Truck stuck frozen. Press R to reset.")
		return
	end

	table.clear(self.driveInputs)
	self.phase = "Run"
	self.phaseClock = 0
	self.runIndex += 1
	local runIndex = self.runIndex
	local variant = self.runVariant
	self.objective = variant.contract.label .. " · " .. variant.contract.brief
	self.conditionTrend = "Stable"
	self.soloWorkingStrap = nil
	table.clear(self.announcedLandmarks)
	table.clear(self.lastRewards)
	self.analytics:runStarted(self.runIndex, self:_crewPlayers())

	--[[
		The scripted opener. One strap is compromised before the truck moves, so
		the first corner has something to find. Nothing about the outcome is
		scripted: brake early and it holds.
	]]
	local weakStrap = variant.openingWeakStrap
	local openingHealth = math.max(24, LabConfig.OpeningWeakHealth / variant.difficulty.pressureScale)
	self.cargoLoad:weakenStrap(weakStrap, LabConfig.StrapMaxHealth - openingHealth)
	self.telemetry:log("opening_weak_strap", weakStrap)
	self.telemetry:log("run_variant", variant.cargo.id .. "/" .. variant.contract.id .. "/" .. variant.difficulty.id)
	local opener = variant.cargo.label .. ". " .. weakStrap .. " strap went on tired."
	if self:_isSolo() then
		opener ..= " Hold E to work it without leaving the wheel."
	end
	--[[
		A new road is the more important thing on the screen, so it goes first
		and the cargo brief follows it. Climbing the ladder should feel like
		arriving somewhere rather than like the same run with different scenery.
	]]
	if self.legChanged then
		self:toast(string.format("LEG %d - %s. %s", self.legIndex, self.route.label, self.route.blurb))
		self.analytics:legReached(self:_crewPlayers(), self.legIndex, self.route.id)
		self.legChanged = false
	end
	self:toast(opener)

	-- Mirror deferred seat reclaim: Sit / contact can flip ownership a beat later.
	task.delay(0.1, function()
		if self.phase ~= "Run" or self.runIndex ~= runIndex then
			return
		end
		if self.chassisRig and self.chassisRig:claimOwnership() and self.stations then
			self.stations:markOwnershipSettle()
		end
		if self.cargoLoad then
			self.cargoLoad:claimOwnership()
		end
	end)
end

function LabSession:_finishRun(outcome: string, saved: boolean, crew: { Player }, endCause: string)
	local variant = self.runVariant
	local summary = self.telemetry:finish(outcome, saved, {
		routeProgress = if self.chassisRig then self.chassisRig:getRouteProgress() else 0,
		cargoReadout = if self.cargoLoad then self.cargoLoad.readout else 0,
		chassisIntegrity = if self.chassisRig then self.chassisRig:getIntegrity() else 0,
		variantKey = if variant
			then string.format("%s/%s/%s", variant.cargo.id, variant.contract.id, variant.difficulty.id)
			else "unknown",
		endCause = endCause,
	})
	self.analytics:runFinished(outcome, crew, summary)

	--[[
		Records last, because they need the summary and the payout that the
		reward loop above has already written. `recordsBeaten` is per player and
		is read straight back out on the result screen, while the run that beat
		it is still on the truck.
	]]
	table.clear(self.recordsBeaten)
	table.clear(self.dailyEarned)
	local riskyContract = self.contractChoice == RunVariants.Choice.Risky

	--[[
		The facts every per-player consumer asks about, gathered once. Both
		records and the daily read the same run, and letting them each reach into
		the summary separately is how the two quietly start disagreeing about
		what happened.
	]]
	local facts = {
		outcome = outcome,
		cargoReadout = if summary then summary.cargoReadout else 0,
		chassisIntegrity = if summary then summary.chassisIntegrity else 0,
		strapBreaks = if summary then summary.strapBreaks else 0,
		strapRefits = if summary then summary.strapRefits else 0,
		throws = if summary then summary.throws else 0,
		durationSeconds = if summary then summary.duration else 0,
		riskyContract = riskyContract,
	}

	local today = DailyContract.dayFromUnix(os.time())
	local objective = DailyContract.forDay(today)
	local dailyMet = DailyContract.isMet(objective, facts)

	for _, player in crew do
		local beaten = AchievementService.applyRun(player, {
			outcome = outcome,
			conditionPct = facts.cargoReadout,
			durationSeconds = facts.durationSeconds,
			payout = self.lastRewards[player.UserId] or 0,
			strapBreaks = facts.strapBreaks,
			riskyContract = riskyContract,
		})
		if #beaten > 0 then
			self.recordsBeaten[player.UserId] = beaten
		end

		if dailyMet and DailyProgressionService.claim(player, today, objective) then
			self.dailyEarned[player.UserId] = objective.bonus
			self.analytics:dailyCompleted(player, objective)
		end
	end
end

function LabSession:enterResult(result: string, saved: boolean)
	if self.phase == "Result" then
		return
	end
	self.phase = "Result"
	self.phaseClock = 0
	self.outcome = result
	self.crateSaved = saved
	local crew = self:_crewPlayers()
	local cargoReadout = if self.cargoLoad then self.cargoLoad.readout else 0
	local chassisIntegrity = if self.chassisRig then self.chassisRig:getIntegrity() else 0
	self.contractComplete = RunVariants.contractMet(self.runVariant, result, cargoReadout)
	self.rewardMultiplier = RunVariants.rewardMultiplier(self.runVariant, self.contractComplete)
	self.outcomeCause = nil
	if result == "TruckWrecked" and self.chassisRig then
		self.outcomeCause = self.chassisRig.lastCause
	end
	-- Freeze first, then yank a void wreck back to the start pad. Holding the
	-- assembly below FallenPartsDestroyHeight for the whole result beat is what
	-- stripped wheel targets and left the next run unable to drive.
	self.chassisRig:setFrozen(true)
	self.cargoLoad:setFrozen(true)
	if result == "TruckWrecked" or result == "CargoLost" then
		self.chassisRig:teleport(self.route.startCFrame)
		self.chassisRig:ensureWheelSet()
		if self.cargoLoad:hasCompleteLoad() then
			self.cargoLoad:reseat()
		end
		self.chassisRig:setFrozen(true)
		self.cargoLoad:setFrozen(true)
	end
	for _, player in crew do
		local reward =
			LabProgressionService.awardRun(player, result, cargoReadout, chassisIntegrity, self.rewardMultiplier)
		self.lastRewards[player.UserId] = reward or 0
		if reward then
			self.analytics:creditsEarned(player, reward)
		end
	end
	self:_finishRun(result, saved, crew, RunCauses.bucket(result, self.outcomeCause))
	self:_openContractBoard()

	--[[
		The longest applicable beat wins. A board and a first-time feedback ask
		can land on the same result screen, and squeezing either one is worse
		than holding the wreck on screen for a few more seconds.
	]]
	local duration = LabConfig.ResultDisplaySeconds
	if self.analytics:anyFeedbackNeeded(crew) then
		duration = math.max(duration, LabConfig.FeedbackResultDisplaySeconds)
	end
	if self.contractOffer then
		duration = math.max(duration, LabConfig.ContractVoteSeconds)
	end
	self.resultDuration = duration
	self.restartSeconds = duration

	--[[
		The ladder moves here, where the outcome is known, and is applied at
		staging, where the rig can be moved without interrupting a run. Arriving
		climbs a rung; losing the truck drops the crew to the first, which is
		what makes reaching the second leg something that happened rather than
		something that unlocked.
	]]
	self.pendingLeg = LabRoute.nextLeg(self.legIndex, result)

	self.objective = "Run over."
end

--[[
	Put two cards on the result screen for the run after this one.

	Run one is the fixed onboarding contract, so the board first appears once a
	player has driven the truck at least once and has something to base a
	decision on. Votes are cleared here rather than when they are resolved, so a
	vote can never carry from one board to the next.
]]
function LabSession:_openContractBoard()
	table.clear(self.contractVotes)
	self.contractOffer = nil
	self.contractChoice = nil

	if self.runIndex < 1 then
		return
	end

	self.contractOffer = RunVariants.offer(
		self.runIndex + 1,
		self.variantRng:NextNumber(),
		self.variantRng:NextNumber(),
		self.variantRng:NextNumber()
	)
	self.telemetry:log(
		"contract_offer",
		string.format(
			"%s/%s vs %s/%s",
			self.contractOffer.safe.cargo.id,
			self.contractOffer.safe.contract.id,
			self.contractOffer.risky.cargo.id,
			self.contractOffer.risky.contract.id
		)
	)
end

--[[
	Close the board and hand the winning card to staging.

	Called at the Result to Staging boundary, because staging is where the crate
	is resized and the opener toast is written: a decision that landed any later
	would be a decision about a truck that had already been built.
]]
function LabSession:_resolveContractBoard(): RunVariants.RunVariant?
	local offer = self.contractOffer
	if not offer then
		return nil
	end

	local crew = self:_crewPlayers()
	local choice, safeVotes, riskyVotes = RunVariants.tally(self.contractVotes, #crew)
	self.contractChoice = choice
	self.contractOffer = nil
	table.clear(self.contractVotes)

	self.telemetry:log("contract_choice", string.format("%s (%d safe, %d risky)", choice, safeVotes, riskyVotes))
	self.analytics:contractChosen(crew, choice, safeVotes, riskyVotes, offer)

	return RunVariants.variantFor(offer, choice)
end

function LabSession:_evaluateDelivery()
	local chassis = self.chassisRig:getChassis()
	if not chassis or not chassis.Parent then
		return
	end
	local pos = chassis.Position
	local target = self.route.deliveryPosition
	local dx = pos.X - target.X
	local dz = pos.Z - target.Z
	local radius = LabConfig.DeliveryAcceptRadius
	if dx * dx + dz * dz > radius * radius or self.chassisRig:getSpeed() > LabConfig.DeliveryMaxSpeed then
		return
	end

	local broken = 0
	for _, id in LabConfig.StrapOrder do
		local strap = self.cargoLoad:getStrap(id)
		if strap and strap.broken then
			broken += 1
		end
	end

	if self.cargoLoad.condition == "Lost" then
		self:enterResult("CargoLost", false)
	elseif
		broken > 0
		or self.cargoLoad.offset > LabConfig.SlidingOffset
		or self.cargoLoad.readout < LabConfig.DeliveryCleanReadout
	then
		self:enterResult("PartialLoss", true)
	else
		self:enterResult("Delivered", true)
	end
end

-- -------------------------------------------------------------------- step

--[[
	Drive/cargo/station integration runs before the physics solver so impulses
	land on the same frame. Fixed substeps keep push even under hitchy dt.
]]
function LabSession:_physicsStep(fixedDt: number)
	if not self.chassisRig or not self.cargoLoad or not self.stations then
		return
	end
	local input = self:_driveState()
	self.lastDriveInput = input
	self.chassisRig:step(fixedDt, input, self.cargoLoad:getMass())
	self.cargoLoad:step(fixedDt)
	self.stations:step(fixedDt)
end

function LabSession:step(dt: number)
	dt = math.min(dt, MAX_STEP)
	self.phaseClock += dt

	--[[
		Seats can still hand ownership if Auto flips back on. Seating / GO paths
		reclaim immediately. Mid-Run polls are disabled: a reclaim that breaks
		SeatWeld is a hitch, and Auto is pinned false after the first claim.
	]]
	if self.phase ~= "Run" then
		self.ownershipAccumulator += dt
		if self.ownershipAccumulator >= OWNERSHIP_INTERVAL then
			self.ownershipAccumulator = 0
			if self.chassisRig and self.chassisRig:claimOwnership() and self.stations then
				self.stations:markOwnershipSettle()
			end
			if self.cargoLoad then
				self.cargoLoad:claimOwnership()
			end
		end
	end

	local input = self.lastDriveInput or self:_driveState()

	if self.phase == "Run" then
		self:_recoverPendingCrew()
		self:_stepRun(dt, input)
	elseif self.phase == "Staging" then
		self.restartSeconds = math.max(0, LabConfig.RestartDelaySeconds - self.phaseClock)
		self:_recoverPendingCrew()
		if #Players:GetPlayers() > 0 and self.phaseClock >= LabConfig.RestartDelaySeconds then
			self:_assignRoles()
			self:_recoverPendingCrew()
			if self:currentDriver() then
				self:enterRun()
			else
				-- Hold GO rather than rolling an empty truck for a full contract.
				self.phaseClock = LabConfig.RestartDelaySeconds - 1
				self.objective = "Waiting for a driver seat..."
			end
		end
	elseif self.phase == "Result" then
		self.restartSeconds = math.max(0, self.resultDuration - self.phaseClock)
		if self.phaseClock >= self.resultDuration then
			self:enterStaging()
		end
	end

	if self.phase == "Run" or self.phase == "Staging" then
		self.motionAccumulator += dt
		if self.motionAccumulator >= MOTION_INTERVAL then
			self.motionAccumulator = 0
			local sample = self.chassisRig and self.chassisRig:getMotionSample()
			if sample then
				LabRemotes.fireAllClients(Net.Names.LabMotion, sample)
			end
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
	self:_announceLandmarks(progress)

	if self.soloWorkingStrap then
		local driver = self:currentDriver()
		self.cargoLoad:tighten(self.soloWorkingStrap, dt, if driver then driver.Name else "Driver")
	end

	for _, name in self.stations:consumeThrows() do
		self.telemetry:noteThrow(name)
		self:toast(name .. " was thrown off the truck!")
	end

	self:_stepSwapGates(progress)

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

	for _, id in self.cargoLoad:consumeStrapBreaks() do
		self.telemetry:noteStrapBreak(id)
		local tip = if self:_isSolo()
			then id .. " strap snapped. Hold E to refit it."
			else id .. " strap snapped. Get to " .. id .. " and hold E to refit it."
		self:toast(tip)
	end
	for _, id in self.cargoLoad:consumeStrapRefits() do
		self.telemetry:noteStrapRefit(id)
		self:toast(id .. " strap refitted. Nice save.")
	end

	local changed, previous, reportedCause = self.cargoLoad:consumeConditionChange()
	if changed then
		local before = CONDITION_SEVERITY[previous or "Secure"] or 0
		local after = CONDITION_SEVERITY[self.cargoLoad.condition] or 0
		self.conditionTrend = if after > before then "Worsening" elseif after < before then "Recovering" else "Stable"

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
		if after >= 3 then
			self.analytics:firstCrisis(self.runIndex, self:_crewPlayers())
		end

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
		self.deliveryAccumulator += dt
		if self.deliveryAccumulator >= DELIVERY_CHECK_INTERVAL then
			self.deliveryAccumulator = 0
			self:_evaluateDelivery()
		end
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
		if self.roles[player.UserId] ~= "Driver" or self.phase ~= "Run" then
			return
		end
		-- Rate-limit drops must not age the last accepted axes into DRIVE_IDLE.
		if not self.driveLimiter:allow(player) then
			local previous = self.driveInputs[player.UserId]
			if previous then
				previous.at = os.clock()
			end
			return
		end

		if math.abs(drive.throttle) > 0.05 or math.abs(drive.steering) > 0.05 or drive.braking then
			self.telemetry:noteInput(player.Name)
			self.analytics:noteInput(player, "Driver")
		end
		if drive.sentAt then
			-- GetServerTimeNow is synchronized across client and server. Small
			-- negative jitter is clamped; implausible/fabricated ages are ignored.
			local inputAge = Workspace:GetServerTimeNow() - drive.sentAt
			if inputAge >= -0.05 and inputAge <= 10 then
				self.telemetry:noteDriveInputAge(math.max(0, inputAge))
			end
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
		if self.roles[player.UserId] ~= "Strapper" then
			LabRemotes.fireClient(Net.Names.LabEvent, player, "Only crew on the bed can move stations.")
			return
		end
		-- Staging is parked, so traversing the bed is harmless and lets a
		-- strapper pick a corner before the opener fires.
		if self.phase ~= "Run" and self.phase ~= "Staging" then
			LabRemotes.fireClient(Net.Names.LabEvent, player, "Wait for the next run.")
			return
		end
		if self:_swapLocked() then
			LabRemotes.fireClient(Net.Names.LabEvent, player, "Crew rotation is locked in. Hold your position.")
			return
		end

		local ok, message = self.stations:requestMove(player, move.station)
		if ok then
			self.telemetry:noteStationMove(player.Name, move.station)
			self.analytics:noteInput(player, "Strapper")
			-- Do not make a successful button press wait for the next 10 Hz tick.
			-- The server is still authoritative; this is simply an early snapshot.
			self:_broadcastSnapshot()
		end
		LabRemotes.fireClient(Net.Names.LabEvent, player, message)
	end))

	self:_track(LabRemotes.bindServer(Net.Names.LabWork, function(player: Player, work)
		if not self.actionLimiter:allow(player) then
			return
		end

		local role = self.roles[player.UserId]
		if os.clock() < self.swapHandoffUntil then
			if role == "Strapper" then
				self.stations:setWorking(player, false)
			elseif role == "Driver" then
				self:_setSoloWorking(player, false)
			end
			if work.working then
				LabRemotes.fireClient(Net.Names.LabEvent, player, "Controls unlock after the SWAP handoff.")
			end
			return
		end
		-- Solo driver keeps the wheel and works the weakest / refittable strap
		-- in place. Without this the opening weak FR can never be saved alone.
		if role == "Driver" and self:_isSolo() then
			if self.phase ~= "Run" then
				if work.working then
					LabRemotes.fireClient(Net.Names.LabEvent, player, "Wait for the run to start.")
				end
				self:_setSoloWorking(player, false)
				return
			end
			self:_setSoloWorking(player, work.working)
			return
		end

		if role ~= "Strapper" then
			if work.working then
				LabRemotes.fireClient(Net.Names.LabEvent, player, "Only crew on the bed can work a strap.")
			end
			return
		end
		if self.phase ~= "Run" then
			if work.working then
				LabRemotes.fireClient(Net.Names.LabEvent, player, "Wait for the run to start.")
			end
			self.stations:setWorking(player, false)
			return
		end

		local ok, message = self.stations:setWorking(player, work.working)
		if not ok and message and work.working then
			LabRemotes.fireClient(Net.Names.LabEvent, player, message)
		end
		if work.working and ok then
			self.telemetry:noteInput(player.Name)
			self.analytics:noteInput(player, "Strapper")
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

		-- Anyone may clear a halted sim. Role-wipe after a bad Sit used to leave
		-- only spectators, who could not press R, soft-locking the playtest.
		if self.stepFailed then
			if self.phase == "Run" then
				self:_finishRun("Abandoned", false, self:_crewPlayers(), "SimulationError")
			end
			-- Keep stepFailed true through enterStaging so rebuildRig sees it.
			-- Clearing first left a destroyed crate/wheels on a cheap reset and
			-- immediately re-latched the same error.
			self:enterStaging()
			self:toast(player.Name .. " restarted after an error.")
			return
		end

		if not self.roles[player.UserId] then
			LabRemotes.fireClient(Net.Names.LabEvent, player, "Spectators cannot reset the crew's run.")
			return
		end

		if self.phase == "Staging" then
			-- Staging with a stranded avatar is the stuck state players hit after
			-- a bad Sit. Recover seats instead of refusing the input.
			if self.stations and self.stations:isOffTruck(player) then
				self.stations:recoverAll()
				LabRemotes.fireClient(Net.Names.LabEvent, player, "Back on the truck.")
			else
				LabRemotes.fireClient(Net.Names.LabEvent, player, "Already staging.")
			end
			return
		end
		if self.phase == "Run" then
			self.telemetry:noteManualReset()
			self:_finishRun("Abandoned", false, self:_crewPlayers(), "ManualReset")
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
		if self:_swapLocked() then
			LabRemotes.fireClient(Net.Names.LabEvent, player, "Crew rotation is already locked in.")
			return
		end

		local role = self.roles[player.UserId]
		if not role then
			LabRemotes.fireClient(Net.Names.LabEvent, player, "Crew full. Spectating until a seat opens.")
			return
		end
		if role == "Driver" then
			self.driveInputs[player.UserId] = nil
			self.stations:detach(player)
			self.roles[player.UserId] = "Strapper"
			if not self.stations:attach(player, "Strapper") then
				self.roles[player.UserId] = nil
			end
			self:toast(player.Name .. " stepped off the wheel.")
		elseif role == "Strapper" and not self:currentDriver() then
			self.stations:detach(player)
			self.roles[player.UserId] = "Driver"
			if self.stations:attach(player, "Driver") then
				self:toast(player.Name .. " took the wheel.")
			else
				self.roles[player.UserId] = nil
				LabRemotes.fireClient(Net.Names.LabEvent, player, "Could not reach the wheel - rejoining the crew.")
				self:_assignRoles()
			end
		else
			LabRemotes.fireClient(Net.Names.LabEvent, player, "Someone else already has the wheel.")
			return
		end

		self.telemetry:noteRole(player.Name, self.roles[player.UserId] or "Spectator")
		if self.roles[player.UserId] then
			self.analytics:roleAssigned(player, self.roles[player.UserId])
		end
		self:_applyDriverCosmetics()
		self:_broadcastSnapshot()
	end))

	self:_track(LabRemotes.bindServer(Net.Names.LabFeedback, function(player: Player, feedback)
		if not self.actionLimiter:allow(player) or self.phase ~= "Result" or not self.roles[player.UserId] then
			return
		end
		if self.analytics:submitFeedback(player, feedback.answer) then
			LabRemotes.fireClient(Net.Names.LabEvent, player, "Feedback saved. Thank you.")
			self:_broadcastSnapshot()
		end
	end))

	--[[
		A contract vote. Only crew vote, and only while a board is actually up:
		a vote arriving after the board resolved would otherwise sit in the
		table and be counted against the next run's offer.
	]]
	self:_track(LabRemotes.bindServer(Net.Names.LabContractVote, function(player: Player, vote)
		if not self.actionLimiter:allow(player) then
			return
		end
		if self.phase ~= "Result" or not self.contractOffer or not self.roles[player.UserId] then
			return
		end
		if self.contractVotes[player.UserId] == vote.choice then
			return
		end
		self.contractVotes[player.UserId] = vote.choice
		self:_broadcastSnapshot()
	end))

	-- The platform owns the invite picker and delivery. This records only that
	-- our contextual button successfully opened it, which is the part of the
	-- social funnel this experience controls.
	self:_track(LabRemotes.bindServer(Net.Names.LabInvite, function(player: Player)
		if not self.actionLimiter:allow(player) or not self.roles[player.UserId] then
			return
		end
		if self.phase ~= "Result" and self.phase ~= "Staging" then
			return
		end
		self.analytics:invitePrompted(player, self:_activeCrewCount(), self.phase)
	end))

	--[[
		A purchase intent. The validator has already rejected unknown and
		unconfigured keys, so this only has to rate limit and refuse spectators.
		The prompt itself is raised server-side by CommerceService.
	]]
	self:_track(LabRemotes.bindServer(Net.Names.LabPurchase, function(player: Player, request)
		if not self.actionLimiter:allow(player) or not self.roles[player.UserId] then
			return
		end
		CommerceService.prompt(player, request.key)
	end))

	self:_track(LabRemotes.bindServer(Net.Names.LabPaint, function(player: Player, request)
		if not self.actionLimiter:allow(player) or self.phase == "Run" or not self.roles[player.UserId] then
			return
		end
		local ok, message = LabProgressionService.selectPaint(player, request.paintId)
		LabRemotes.fireClient(Net.Names.LabEvent, player, message)
		if ok then
			if self:currentDriver() == player then
				self:_applyDriverCosmetics()
			end
			self:_broadcastSnapshot()
		end
	end))
end

function LabSession:_onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 5)
	local root = character:WaitForChild("HumanoidRootPart", 5)
	if not humanoid or not root or not self.stations then
		return
	end
	local userId = player.UserId
	local previousDiedConnection = self.characterDiedConnections[userId]
	if previousDiedConnection then
		previousDiedConnection:Disconnect()
	end
	local diedConnection: RBXScriptConnection? = nil
	diedConnection = humanoid.Died:Connect(function()
		if self.characterDiedConnections[userId] == diedConnection then
			self.characterDiedConnections[userId] = nil
		end
		if player.Character ~= character or not self.stations then
			return
		end
		self.driveInputs[player.UserId] = nil
		self.stations:suspendRespawn(player)
		LabRemotes.fireClient(Net.Names.LabEvent, player, "Respawning safely - you will rejoin the crew shortly.")
		self:_broadcastSnapshot()
	end)
	self.characterDiedConnections[userId] = diedConnection
	-- Give the default character scripts one beat to finish assembling before
	-- we Sit; calling Sit on a half-built rig is a silent no-op.
	task.wait(0.35)
	if not self.started or not self.stations or player.Parent ~= Players or player.Character ~= character then
		return
	end
	if not self.roles[player.UserId] then
		if self:_activeCrewCount() >= LabConfig.MaxCrew then
			LabRemotes.fireClient(
				Net.Names.LabEvent,
				player,
				string.format("Crew full (%d/%d). Spectating until a seat opens.", LabConfig.MaxCrew, LabConfig.MaxCrew)
			)
			self:_broadcastSnapshot()
			return
		end
		local hasDriver = self:currentDriver() ~= nil
		self.roles[player.UserId] = if hasDriver then "Strapper" else "Driver"
	end

	local chassis = self.chassisRig and self.chassisRig:getChassis()
	local canAttach = chassis
		and LabRespawnPolicy.shouldAttach(self.phase, self.chassisRig:isWrecked(), chassis.Position.Y, LabConfig.VoidY)
	if not canAttach then
		self.stations:suspendRespawn(player)
		LabRemotes.fireClient(Net.Names.LabEvent, player, "Truck is resetting - joining on the next prep.")
		self:_broadcastSnapshot()
		return
	end
	if not self.stations:attach(player, self.roles[player.UserId]) then
		LabRemotes.fireClient(Net.Names.LabEvent, player, "Seat not ready yet - holding your crew spot.")
		self:_broadcastSnapshot()
		return
	end
	self.telemetry:noteRole(player.Name, self.roles[player.UserId])
	self.analytics:roleAssigned(player, self.roles[player.UserId])
	self:_broadcastSnapshot()
end

function LabSession:_onPlayerAdded(player: Player)
	self.analytics:playerJoined(player)
	task.spawn(function()
		local profile = PlayerDataService.waitFor(player, 12)
		if profile and self.started and player.Parent then
			player:SetAttribute("CargoCredits", profile.credits)
			if self.phase == "Staging" and self:currentDriver() == player then
				self:_applyDriverCosmetics()
			end
			self:_broadcastSnapshot()
		end
	end)
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
	self.analytics:playerLeaving(player, self.phase == "Run")
	local diedConnection = self.characterDiedConnections[player.UserId]
	if diedConnection then
		diedConnection:Disconnect()
		self.characterDiedConnections[player.UserId] = nil
	end
	self.stations:detach(player)
	self.roles[player.UserId] = nil
	self.driveInputs[player.UserId] = nil
	-- A vote belongs to somebody who is going to drive the run it decides.
	self.contractVotes[player.UserId] = nil

	-- PlayerRemoving can fire before GetPlayers stops returning the departing
	-- player. Defer promotion by one scheduler turn so _assignRoles cannot hand
	-- the wheel straight back to somebody who is already leaving.
	task.defer(function()
		if self.started then
			self:_assignRoles()
			self:_broadcastSnapshot()
		end
	end)
end

function LabSession:_haltSimulation(err: any, source: string)
	self.stepFailed = true
	-- Halt must freeze assemblies. Otherwise the truck keeps falling
	-- through the void with stepping no-op'd and parts get Destroy()'d
	-- before the player can press R.
	if self.chassisRig then
		pcall(function()
			self.chassisRig:setFrozen(true)
			self.chassisRig:teleport(self.route.startCFrame)
			self.chassisRig:ensureWheelSet()
		end)
	end
	if self.cargoLoad then
		pcall(function()
			if self.cargoLoad:hasCompleteLoad() then
				self.cargoLoad:reseat()
			end
			self.cargoLoad:setFrozen(true)
		end)
	end
	if self.phase == "Run" then
		self.telemetry:noteSimulationError(source)
	end
	warn("[CargoLab] step error, simulation halted. Press R to restart.\n" .. tostring(err))
	self:toast("Simulation error. Press R to restart.")
end

function LabSession:_bindStepped()
	self:_track(RunService.Stepped:Connect(function(_t: number, dt: number)
		if self.stepFailed then
			return
		end
		local ok, err = xpcall(function()
			self.physicsAccumulator += math.min(dt, MAX_STEP)
			local steps = 0
			while self.physicsAccumulator >= FIXED_DT and steps < MAX_SUBSTEPS do
				self.physicsAccumulator -= FIXED_DT
				self:_physicsStep(FIXED_DT)
				steps += 1
			end
			if steps >= MAX_SUBSTEPS then
				self.physicsAccumulator = 0
			end
		end, debug.traceback)
		if not ok then
			self:_haltSimulation(err, "stepped_physics")
		end
	end))
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
			self:_haltSimulation(err, "heartbeat_step")
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
	self:_bindStepped()
	self:_bindHeartbeat()
end

function LabSession:destroy()
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)
	for userId, connection in self.characterDiedConnections do
		connection:Disconnect()
		self.characterDiedConnections[userId] = nil
	end

	self.driveLimiter:destroy()
	self.actionLimiter:destroy()
	self.analytics:destroy()

	self:_destroyRig()

	table.clear(self.roles)
	table.clear(self.driveInputs)
	table.clear(self.lastRewards)
	self.started = false
end

return LabSession
