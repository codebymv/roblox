--!nonstrict

--[[
	One crew, one bay, one convoy.

	A convoy is leg 1, 2, 3... Each delivered leg raises the multiplier and the
	pressure and shortens the clock, and the crew then votes to bank or push.
	A wipe forfeits the entire unbanked stack.

	This module is the sole writer of its own phase. Everything else asks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local CargoManifest = require(Shared:WaitForChild("CargoManifest"))
local LiveOps = require(Shared:WaitForChild("LiveOps"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Net = require(Shared:WaitForChild("Net"))
local RoleKits = require(Shared:WaitForChild("RoleKits"))
local Types = require(Shared:WaitForChild("Types"))

local CargoRig = require(script.Parent.CargoRig)
local EconomyService = require(script.Parent.EconomyService)
local FailureRunner = require(script.Parent.FailureRunner)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RoleService = require(script.Parent.RoleService)

type DriveState = {
	throttle: number,
	steering: number,
	braking: boolean,
	updatedAt: number,
}

local CrewMatch = {}
CrewMatch.__index = CrewMatch

local function cancelThread(thread: thread?)
	if thread and thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then
		task.cancel(thread)
	end
end

function CrewMatch.new(lane: any, onChanged: () -> ())
	local self = setmetatable({
		bayIndex = lane.index,
		lane = lane,
		rig = CargoRig.new(lane),
		roles = RoleService.new(),
		failureRunner = nil :: any,
		onChanged = onChanged,

		members = {} :: { Player },
		spectators = {} :: { Player },

		phase = "Idle" :: Types.CrewPhase,
		leg = 0,
		carriedValue = 0,
		legValue = 0,
		cargo = nil :: Types.CargoDef?,
		cargoStability = 100,
		convoyCascades = 0,
		timeRemaining = 0,
		timeSurvived = 0,
		lastFailureLabel = nil :: string?,
		failReason = nil :: Types.FailReason?,

		readyPlayers = {} :: { [number]: boolean },
		votes = {} :: { [number]: string },
		countdownSeconds = 0,
		decisionSeconds = 0,

		driveInputs = {} :: { [number]: DriveState },
		holdActions = {} :: { [number]: string },

		cornerStage = 0,
		randomFailuresStarted = false,
		deliveryHoldEntered = false,
		tutorialFired = false,

		runThread = nil :: thread?,
		countdownThread = nil :: thread?,
		decisionThread = nil :: thread?,
		stageThread = nil :: thread?,
		resolveThread = nil :: thread?,

		rng = Random.new(),
	}, CrewMatch)

	self.rig:reset()
	self:_updateCrewTag()
	return self
end

--------------------------------------------------------------------------------
-- Audience and replication
--------------------------------------------------------------------------------

function CrewMatch:_audience(): { Player }
	local list = table.clone(self.members)
	for _, spectator in self.spectators do
		table.insert(list, spectator)
	end
	return list
end

function CrewMatch:_toast(message: string)
	local remote = Net.get(Net.Names.Toast)
	for _, player in self:_audience() do
		remote:FireClient(player, message)
	end
end

function CrewMatch:_isMember(player: Player): boolean
	return table.find(self.members, player) ~= nil
end

function CrewMatch:isLiveRun(): boolean
	return self.phase == "Run" or self.phase == "DeliveryHold"
end

function CrewMatch:_countReady(): number
	local count = 0
	for _, player in self.members do
		if self.readyPlayers[player.UserId] then
			count += 1
		end
	end
	return count
end

function CrewMatch:_memberNames(): { string }
	local names: { string } = {}
	for _, player in self.members do
		table.insert(names, player.Name)
	end
	return names
end

function CrewMatch:_readyMap(): { [string]: boolean }
	local map: { [string]: boolean } = {}
	for _, player in self.members do
		map[player.Name] = self.readyPlayers[player.UserId] == true
	end
	return map
end

function CrewMatch:_objective(): string
	local phase = self.phase
	if phase == "Idle" then
		return "Bay open — step on the pad to crew up"
	elseif phase == "Staging" then
		return string.format(
			"Ready up (%d/%d) — departing automatically",
			self:_countReady(),
			#self.members
		)
	elseif phase == "Departing" then
		return "Rolling out in " .. tostring(self.countdownSeconds) .. "..."
	elseif phase == "Run" then
		if self.lastFailureLabel then
			return "Handle: " .. self.lastFailureLabel
		end
		return string.format("Leg %d — haul to the blue delivery zone", self.leg)
	elseif phase == "DeliveryHold" then
		return "DELIVERY HOLD — stop inside the glowing zone"
	elseif phase == "BankOrPush" then
		return string.format(
			"Leg %d delivered. Bank %d credits, or push for more?",
			self.leg,
			self.carriedValue
		)
	elseif phase == "Resolve" then
		if self.failReason == "Banked" then
			return string.format("Banked %d credits after %d legs", self.carriedValue, self.leg)
		end
		return "Convoy lost — " .. tostring(self.failReason or "CargoLost")
	end
	return "Cargo Catastrophe"
end

function CrewMatch:_activeFailureSnapshot(): Types.ActiveFailureSnapshot?
	local runner = self.failureRunner
	if not runner then
		return nil
	end
	local active = runner:getActive()
	if not active or active.resolved or active.cascaded then
		return nil
	end
	return {
		id = active.def.id,
		label = active.def.label,
		description = active.def.description,
		responsibleRole = active.def.responsibleRole,
		interaction = active.def.interaction,
		secondsRemaining = math.max(0, active.expiresAt - os.clock()),
	}
end

function CrewMatch:_tallyVotes(): (number, number)
	local push, bank = 0, 0
	for _, choice in self.votes do
		if choice == "Push" then
			push += 1
		elseif choice == "Bank" then
			bank += 1
		end
	end
	return push, bank
end

function CrewMatch:buildSnapshot(player: Player?): Types.CrewSnapshot
	local push, bank = self:_tallyVotes()
	local runnerCascades = if self.failureRunner then self.failureRunner.cascadeCount else 0
	return {
		bayIndex = self.bayIndex,
		phase = self.phase,
		leg = self.leg,
		timeRemaining = math.max(0, math.ceil(self.timeRemaining)),
		cargoStability = math.clamp(math.floor(self.cargoStability), 0, 100),
		truckIntegrity = math.clamp(
			math.floor(self.rig:getTruckIntegrity()),
			0,
			MatchConfig.MaxTruckIntegrity
		),
		cargoState = self.rig:getCargoState(),
		routeProgress = math.floor(self.rig:getRouteProgress() * 100),
		speed = math.floor(self.rig:getSpeed() * 2.2),
		objective = self:_objective(),
		lastFailureLabel = self.lastFailureLabel,
		activeFailure = self:_activeFailureSnapshot(),
		failReason = self.failReason,
		cascadeCount = self.convoyCascades + runnerCascades,
		timeSurvived = math.floor(self.timeSurvived),
		readyCount = self:_countReady(),
		readyRequired = math.max(#self.members, 1),
		countdownSeconds = self.countdownSeconds,
		readyPlayers = self:_readyMap(),
		roles = self.roles:getAssignmentMap(),
		members = self:_memberNames(),
		cargo = self.cargo,
		carriedValue = self.carriedValue,
		legValue = self.legValue,
		multiplier = EconomyService.multiplierForLeg(math.max(1, self.leg)),
		decisionSeconds = self.decisionSeconds,
		pushVotes = push,
		bankVotes = bank,
		myVote = if player then self.votes[player.UserId] else nil,
		spectating = if player then not self:_isMember(player) else false,
		safeSpeed = math.floor(self:getSafeSpeed() * 2.2),
	}
end

function CrewMatch:replicate()
	local remote = Net.get(Net.Names.CrewSnapshot)
	for _, player in self:_audience() do
		remote:FireClient(player, self:buildSnapshot(player))
	end
end

function CrewMatch:replicateTo(player: Player)
	Net.get(Net.Names.CrewSnapshot):FireClient(player, self:buildSnapshot(player))
end

function CrewMatch:_setPhase(nextPhase: Types.CrewPhase)
	self.phase = nextPhase
	self:replicate()
	self.onChanged()
end

--------------------------------------------------------------------------------
-- Membership
--------------------------------------------------------------------------------

function CrewMatch:isJoinable(): boolean
	if #self.members >= MatchConfig.CrewCapacity then
		return false
	end
	return self.phase == "Idle" or self.phase == "Staging" or self.phase == "Resolve"
end

function CrewMatch:getStatus(): Types.BayStatus
	return {
		index = self.bayIndex,
		phase = self.phase,
		leg = self.leg,
		memberCount = #self.members,
		capacity = MatchConfig.CrewCapacity,
		members = self:_memberNames(),
		carriedValue = self.carriedValue,
		cargoLabel = if self.cargo then self.cargo.label else nil,
		rarity = if self.cargo then self.cargo.rarity else nil,
	}
end

function CrewMatch:addMember(player: Player): boolean
	if self:_isMember(player) or not self:isJoinable() then
		return false
	end
	self:removeSpectator(player)
	table.insert(self.members, player)
	player:SetAttribute("CargoBay", self.bayIndex)
	self:_updateCrewTag()

	if self.phase == "Idle" then
		self:_setPhase("Staging")
		self:_beginStageTimer()
	else
		self:replicate()
		self.onChanged()
	end
	self:_toast(player.Name .. " joined bay " .. tostring(self.bayIndex) .. ".")
	return true
end

function CrewMatch:removeMember(player: Player)
	local index = table.find(self.members, player)
	if not index then
		return
	end
	table.remove(self.members, index)
	self.readyPlayers[player.UserId] = nil
	self.votes[player.UserId] = nil
	self.driveInputs[player.UserId] = nil
	self.holdActions[player.UserId] = nil
	if player.Parent then
		player:SetAttribute("CargoBay", nil)
		player:SetAttribute("CargoRole", nil)
	end

	local wasLive = self:isLiveRun() or self.phase == "BankOrPush"
	if wasLive then
		-- Leaving mid-convoy forfeits the unbanked stack and the streak. Otherwise
		-- bailing on a doomed leg would be the optimal way to protect a streak.
		EconomyService.registerWipe(player, self.leg)
	end

	if #self.members == 0 then
		self:_abandon()
		return
	end

	if wasLive and not self.roles:hasRole("Driver") then
		self.roles:assignForPlayers(self.members)
		self:_applyKitWindows()
		self:_toast("Driver left — roles reassigned mid-haul.")
	end

	self:_updateCrewTag()
	self:replicate()
	self.onChanged()
end

function CrewMatch:addSpectator(player: Player)
	if self:_isMember(player) or table.find(self.spectators, player) then
		return
	end
	table.insert(self.spectators, player)
	self:replicateTo(player)
end

function CrewMatch:removeSpectator(player: Player)
	local index = table.find(self.spectators, player)
	if index then
		table.remove(self.spectators, index)
	end
end

function CrewMatch:_updateCrewTag()
	if #self.members == 0 then
		self.rig:setCrewTag("BAY " .. tostring(self.bayIndex) .. " — OPEN")
		return
	end
	local best = 0
	for _, player in self.members do
		best = math.max(best, EconomyService.getStreak(player))
	end
	local names = table.concat(self:_memberNames(), ", ")
	local streakText = if best > 0 then string.format("  ·  %d convoy streak", best) else ""
	self.rig:setCrewTag(string.format("BAY %d  ·  %s%s", self.bayIndex, names, streakText))
end

--------------------------------------------------------------------------------
-- Staging and departure
--------------------------------------------------------------------------------

--[[
	Staging never blocks on a Ready click. The window is re-evaluated as people
	join, so a solo player rolls almost immediately while a forming crew gets time
	to fill up.
]]
function CrewMatch:_beginStageTimer()
	cancelThread(self.stageThread)
	self.stageThread = task.spawn(function()
		local elapsed = 0
		while self.phase == "Staging" and #self.members > 0 do
			task.wait(0.5)
			elapsed += 0.5
			local required = if #self.members <= 1
				then MatchConfig.SoloAutoDepartSeconds
				else MatchConfig.AutoDepartSeconds
			if elapsed >= required then
				self:_toast("Dispatch is not waiting. Rolling out.")
				self:_beginDeparture()
				return
			end
		end
	end)
end

function CrewMatch:setReady(player: Player, isReady: boolean)
	if self.phase ~= "Staging" or not self:_isMember(player) then
		return
	end
	self.readyPlayers[player.UserId] = isReady
	self:replicate()
	self.onChanged()

	if self:_countReady() >= #self.members then
		self:_beginDeparture()
	end
end

function CrewMatch:forceStart(player: Player)
	if self.phase ~= "Staging" or not self:_isMember(player) then
		return
	end
	for _, member in self.members do
		self.readyPlayers[member.UserId] = true
	end
	self:_beginDeparture()
end

function CrewMatch:_beginDeparture()
	if self.phase ~= "Staging" then
		return
	end
	cancelThread(self.stageThread)
	self.stageThread = nil
	cancelThread(self.countdownThread)

	self:_setPhase("Departing")
	self.countdownThread = task.spawn(function()
		for remaining = MatchConfig.DepartCountdownSeconds, 1, -1 do
			self.countdownSeconds = remaining
			self:replicate()
			task.wait(1)
			if self.phase ~= "Departing" then
				return
			end
		end
		self.countdownSeconds = 0
		if self.phase == "Departing" then
			self:_startConvoy()
		end
	end)
end

--------------------------------------------------------------------------------
-- Convoy and legs
--------------------------------------------------------------------------------

function CrewMatch:_applyKitWindows()
	local runner = self.failureRunner
	if not runner then
		return
	end
	local bonuses: { [Types.RoleId]: number } = {}
	for _, roleId in { "Driver", "Strapper", "Spotter", "Repair" } :: { Types.RoleId } do
		bonuses[roleId] = self.roles:effectFor(roleId).windowBonusSeconds or 0
	end
	runner:setRoleWindowBonuses(bonuses)
end

function CrewMatch:getSafeSpeed(): number
	local safe = MatchConfig.SafeCornerSpeed + (self.roles:effectFor("Driver").safeSpeedBonus or 0)
	if self.cargo and self.cargo.safeSpeedDelta then
		safe += self.cargo.safeSpeedDelta
	end
	return math.max(6, safe)
end

function CrewMatch:_applyPaint()
	local drivers = self.roles:getPlayersWithRole("Driver")
	local driver = drivers[1] or self.members[1]
	if not driver then
		return
	end
	local profile = PlayerDataService.get(driver)
	local paint = RoleKits.getPaint(if profile then profile.equippedPaint else "Factory")
	if paint then
		self.rig:setPaint(paint.color)
	end
end

function CrewMatch:_startConvoy()
	if #self.members == 0 then
		self:_abandon()
		return
	end

	self.roles:assignForPlayers(self.members)
	self.leg = 0
	self.carriedValue = 0
	self.convoyCascades = 0
	self.timeSurvived = 0
	self.failReason = nil
	table.clear(self.readyPlayers)
	table.clear(self.votes)
	self:_applyPaint()
	self:_toast("Roles assigned. Driver has WASD; everyone else watches the load.")
	self:_startLeg(1)
end

function CrewMatch:_stopRuntime()
	if self.failureRunner then
		self.convoyCascades += self.failureRunner.cascadeCount
		self.failureRunner:stop()
		self.failureRunner = nil
	end
	cancelThread(self.runThread)
	self.runThread = nil
	cancelThread(self.decisionThread)
	self.decisionThread = nil
	table.clear(self.driveInputs)
	table.clear(self.holdActions)
	self.rig:setDeliveryCue(false)
end

function CrewMatch:_startLeg(leg: number)
	self:_stopRuntime()

	self.leg = leg
	self.cargo = CargoManifest.roll(self.rng, leg)
	self.legValue = EconomyService.legValue(leg, self.cargo)
	self.cargoStability = 100
	self.lastFailureLabel = nil
	self.failReason = nil
	self.timeRemaining = MatchConfig.legDuration(leg)
	self.cornerStage = 0
	self.randomFailuresStarted = false
	self.deliveryHoldEntered = false
	self.tutorialFired = false
	table.clear(self.votes)

	self.rig:reset()
	self.rig:applyCargo(self.cargo)
	self:_configureFailureRunner()

	local reveal = Net.get(Net.Names.CargoReveal)
	for _, player in self:_audience() do
		reveal:FireClient(player, {
			leg = leg,
			cargo = self.cargo,
			legValue = self.legValue,
			carriedValue = self.carriedValue,
		})
	end

	self:_setPhase("Run")
	self.runThread = task.spawn(function()
		self:_runLeg()
	end)
end

function CrewMatch:_configureFailureRunner()
	local event = LiveOps.getActive()
	self.failureRunner = FailureRunner.new({
		onPrompt = function(def: Types.FailureDef, expiresAt: number)
			self.lastFailureLabel = def.label
			if self:_isCargoFailure(def.id) then
				self.rig:setCargoState("Tipping")
			elseif def.id ~= "BlindCorner" then
				self.rig:setFaultActive(true)
			end
			local prompt = Net.get(Net.Names.FailurePrompt)
			for _, player in self:_audience() do
				prompt:FireClient(player, {
					id = def.id,
					label = def.label,
					description = def.description,
					role = def.responsibleRole,
					interaction = def.interaction,
					windowSeconds = math.max(0, expiresAt - os.clock()),
					clipLine = def.clipLine,
				})
			end
			self:replicate()
		end,
		onResolved = function(def: Types.FailureDef)
			self.lastFailureLabel = def.label .. " (saved)"
			if self:_isCargoFailure(def.id) then
				self.rig:setCargoState("Stable")
			else
				self.rig:setFaultActive(false)
			end
			self.cargoStability = math.min(100, self.cargoStability + 5)
			if def.damagesTruck or def.responsibleRole == "Repair" then
				local bonus = self.roles:effectFor("Repair").integrityRestoreBonus or 0
				self.rig:repairTruck(MatchConfig.RepairIntegrityRestore + bonus)
			end
			if def.id == "BlindCorner" then
				self.cornerStage = 2
			end
			self:_rollLivestockPanic()
			self:replicate()
		end,
		onCascade = function(def: Types.FailureDef)
			self:_handleCascade(def)
		end,
		onToast = function(message: string)
			self:_toast(message)
		end,
	})

	local pressure = MatchConfig.legPressure(self.leg) + event.pressureBonus
	self.failureRunner:setPressure(pressure, MatchConfig.legWindowScale(self.leg))
	self:_applyKitWindows()
end

function CrewMatch:_isCargoFailure(id: Types.FailureId): boolean
	return id == "LooseStrap" or id == "CargoTilt" or id == "SharpTurn"
end

function CrewMatch:_damageTruck(amount: number): number
	local scale = if self.cargo and self.cargo.truckDamageScale then self.cargo.truckDamageScale else 1
	return self.rig:applyTruckDamage(amount * scale)
end

function CrewMatch:_rollLivestockPanic()
	local cargo = self.cargo
	if not cargo or not cargo.panicChance or not self:isLiveRun() then
		return
	end
	if self.rng:NextNumber() > cargo.panicChance then
		return
	end
	task.delay(1.2, function()
		if self:isLiveRun() and self.failureRunner then
			self:_toast("The livestock panicked!")
			self.failureRunner:fireById("CargoTilt")
		end
	end)
end

function CrewMatch:_handleCascade(def: Types.FailureDef)
	self.lastFailureLabel = def.label .. " (cascade)"
	local damage = def.cascadeSeverity * 20
	if def.id == "BlindCorner" then
		damage = 8
		self.cornerStage = 2
	elseif def.id == "SharpTurn" then
		damage = 15
	end
	self.cargoStability -= damage

	if def.damagesTruck then
		local integrity = self:_damageTruck(MatchConfig.TruckDamagePerCascade * def.cascadeSeverity)
		if integrity <= 0 then
			self:_wipe("TruckTotaled")
			return
		end
	end

	local canChainToStrap = def.id == "SharpTurn"
		and self.roles:hasRole("Strapper")
		and self.cargoStability > 0
	if self:_isCargoFailure(def.id) then
		self.rig:setCargoState(if self.cargoStability <= 0 then "Dumped" else "Tipping")
	else
		self.rig:setFaultActive(true)
	end
	self:replicate()

	if canChainToStrap then
		self:_toast("The turn tore a strap loose!")
		task.delay(0.8, function()
			if self:isLiveRun() and self.failureRunner then
				self.failureRunner:fireById("LooseStrap")
			end
		end)
		return
	end

	local runnerCascades = if self.failureRunner then self.failureRunner.cascadeCount else 0
	if self.cargoStability <= 0 or runnerCascades >= MatchConfig.CargoDumpFailThreshold then
		self:_wipe("CargoDumped")
	end
end

function CrewMatch:_getDriveState(): DriveState
	local drivers = self.roles:getPlayersWithRole("Driver")
	local driver = drivers[1]
	if not driver then
		return { throttle = 0, steering = 0, braking = true, updatedAt = os.clock() }
	end
	local state = self.driveInputs[driver.UserId]
	if not state or os.clock() - state.updatedAt > 1 then
		return { throttle = 0, steering = 0, braking = false, updatedAt = os.clock() }
	end
	return state
end

function CrewMatch:_updatePressure(progress: number)
	local runner = self.failureRunner
	if not runner then
		return
	end
	local event = LiveOps.getActive()
	if self.deliveryHoldEntered or progress >= MatchConfig.DeliveryHoldProgress then
		runner:setPressure(
			MatchConfig.legPressure(self.leg) + event.pressureBonus + MatchConfig.DeliveryHoldPressure - 1,
			MatchConfig.DeliveryHoldWindowScale * MatchConfig.legWindowScale(self.leg)
		)
	else
		runner:setPressure(
			MatchConfig.legPressure(self.leg) + event.pressureBonus + progress * 0.85,
			MatchConfig.legWindowScale(self.leg)
		)
	end
end

function CrewMatch:_enterDeliveryHold()
	if self.deliveryHoldEntered or not self:isLiveRun() then
		return
	end
	self.deliveryHoldEntered = true
	self.rig:setDeliveryCue(true)
	self:_updatePressure(1)
	self:_setPhase("DeliveryHold")
	self:_toast("DELIVERY HOLD — stop inside the glowing zone.")
end

function CrewMatch:_runLeg()
	local lastClock = os.clock()
	local replicateAccumulator = 0
	local deliveryHintShown = false

	while self:isLiveRun() and self.timeRemaining > 0 do
		task.wait(0.05)
		local now = os.clock()
		local dt = math.clamp(now - lastClock, 0, 0.1)
		lastClock = now
		self.timeRemaining -= dt
		self.timeSurvived += dt
		replicateAccumulator += dt

		local drive = self:_getDriveState()
		self.rig:step(dt, drive.throttle, drive.steering, drive.braking)

		local progress = self.rig:getRouteProgress()
		self:_updatePressure(progress)

		--[[
			Leg 1 opens with a guaranteed, generously timed save so a new player
			experiences the core interaction almost immediately. The beat has to be
			one this crew can actually answer: a solo Driver cannot fix a strap, so
			they get the corner brought forward instead of a scripted cascade.
		]]
		if not self.tutorialFired and self.leg == 1 and progress >= MatchConfig.TutorialStrapProgress then
			self.tutorialFired = true
			local runner = self.failureRunner
			if runner then
				if self.roles:hasRole("Strapper") then
					runner:fireById("LooseStrap", 12)
				elseif self.cornerStage == 0 then
					self:_toast("Bend coming up early on this leg — brake for it.")
					if runner:fireById("SharpTurn", 12) then
						self.cornerStage = 3
					end
				end
			end
		end

		if not self.deliveryHoldEntered and progress >= MatchConfig.DeliveryHoldProgress then
			self:_enterDeliveryHold()
		end

		if self.cornerStage == 0 and progress >= MatchConfig.SpotterWarningProgress then
			if self.roles:hasRole("Spotter") and self.failureRunner then
				if self.failureRunner:fireById("BlindCorner") then
					self.cornerStage = 1
				end
			else
				self.cornerStage = 2
				self:_toast("Warning: sharp right bend ahead.")
			end
		end

		if self.cornerStage == 2 and progress >= MatchConfig.SharpTurnProgress and self.failureRunner then
			if self.failureRunner:fireById("SharpTurn") then
				self.cornerStage = 3
			end
		end

		local active = if self.failureRunner then self.failureRunner:getActive() else nil
		if active
			and not active.resolved
			and not active.cascaded
			and active.def.id == "SharpTurn"
			and self.rig:getSpeed() <= self:getSafeSpeed()
		then
			self.failureRunner:tryResolve("Driver")
		end

		if not self.randomFailuresStarted
			and self.cornerStage >= 3
			and progress >= MatchConfig.RandomFailureStartProgress
			and self.failureRunner
		then
			self.randomFailuresStarted = true
			self.failureRunner:startRandom(self.roles:getActiveRoles())
		end

		if self.rig:isOffRoad() and self.rig:getSpeed() > 4 then
			self.cargoStability -= 7 * dt
			local integrity = self:_damageTruck(MatchConfig.OffRoadTruckDamagePerSecond * dt)
			if self.cargoStability <= 70 and self.rig:getCargoState() == "Stable" then
				self.rig:setCargoState("Tipping")
				self:_toast("Get back on the road — the load is sliding.")
			end
			if integrity <= 0 then
				self:_wipe("TruckTotaled")
				break
			end
			if self.cargoStability <= 0 then
				self:_wipe("CargoDumped")
				break
			end
		elseif self.rig:getCargoState() == "Tipping"
			and (not active or not self:_isCargoFailure(active.def.id))
		then
			local recovery = 3 + (self.roles:effectFor("Strapper").stabilityRecoveryBonus or 0)
			self.cargoStability = math.min(100, self.cargoStability + recovery * dt)
			if self.cargoStability >= 75 then
				self.rig:setCargoState("Stable")
			end
		end

		if not deliveryHintShown and progress >= 0.9 then
			deliveryHintShown = true
			self:_toast("Stop inside the blue delivery zone.")
		end

		if self.rig:isDelivered() then
			self:_deliverLeg()
			break
		end

		if replicateAccumulator >= 0.2 then
			replicateAccumulator = 0
			self:replicate()
		end
	end

	if self:isLiveRun() then
		self:_wipe("TimeExpired")
	end
end

--------------------------------------------------------------------------------
-- Resolution: bank, push, wipe
--------------------------------------------------------------------------------

function CrewMatch:_deliverLeg()
	if not self:isLiveRun() then
		return
	end
	self:_stopRuntime()

	self.carriedValue += self.legValue
	self.failReason = "Delivered"
	self.rig:setCargoState("Stable")

	for _, player in self.members do
		EconomyService.recordLeg(player, self.cargo)
	end

	self:_toast(string.format("Leg %d delivered. +%d on the stack.", self.leg, self.legValue))
	table.clear(self.votes)
	self.decisionSeconds = MatchConfig.DecisionSeconds
	self:_setPhase("BankOrPush")

	self.decisionThread = task.spawn(function()
		for remaining = MatchConfig.DecisionSeconds, 1, -1 do
			self.decisionSeconds = remaining
			self:replicate()
			task.wait(1)
			if self.phase ~= "BankOrPush" then
				return
			end
		end
		self.decisionSeconds = 0
		if self.phase == "BankOrPush" then
			-- Timing out banks. The safe outcome should never require a reaction.
			self:_toast("No call made — dispatch banked the load.")
			self:_bank()
		end
	end)
end

function CrewMatch:vote(player: Player, choice: string)
	if self.phase ~= "BankOrPush" or not self:_isMember(player) then
		return
	end
	if choice ~= "Bank" and choice ~= "Push" then
		return
	end
	self.votes[player.UserId] = choice
	self:_toast(player.Name .. " votes " .. string.upper(choice) .. ".")
	self:replicate()

	local push, bank = self:_tallyVotes()
	if push + bank < #self.members then
		return
	end
	-- Majority rules; a tie banks. Greed has to be agreed on.
	if push > bank then
		self:_push()
	else
		self:_bank()
	end
end

function CrewMatch:_push()
	if self.phase ~= "BankOrPush" then
		return
	end
	cancelThread(self.decisionThread)
	self.decisionThread = nil
	self.decisionSeconds = 0
	self:_toast(string.format("Pushing on to leg %d. Nothing is banked yet.", self.leg + 1))
	self:_startLeg(self.leg + 1)
end

function CrewMatch:_bank()
	if self.phase ~= "BankOrPush" then
		return
	end
	cancelThread(self.decisionThread)
	self.decisionThread = nil
	self.decisionSeconds = 0

	local payout = self.carriedValue
	for _, player in self.members do
		EconomyService.awardBank(player, payout, self.leg)
	end
	self.failReason = "Banked"
	self:_toast(string.format("Banked %d credits after %d legs.", payout, self.leg))
	self:_updateCrewTag()
	self:_enterResolve()
end

function CrewMatch:_wipe(reason: Types.FailReason)
	if not self:isLiveRun() then
		return
	end
	self:_stopRuntime()

	self.failReason = reason
	if reason == "TruckTotaled" then
		self.rig:setFaultActive(true)
	else
		self.rig:setCargoState("Dumped")
	end

	local lost = self.carriedValue
	self.carriedValue = 0
	for _, player in self.members do
		EconomyService.registerWipe(player, self.leg)
	end

	if lost > 0 then
		self:_toast(string.format("Convoy lost. %d unbanked credits gone.", lost))
	else
		self:_toast("Convoy lost — " .. reason .. ".")
	end
	self:_updateCrewTag()
	self:_enterResolve()
end

function CrewMatch:_enterResolve()
	self:_setPhase("Resolve")
	cancelThread(self.resolveThread)
	self.resolveThread = task.spawn(function()
		task.wait(MatchConfig.ResolveDisplaySeconds)
		if self.phase == "Resolve" then
			self:returnToStaging()
		end
	end)
end

function CrewMatch:requestNewConvoy(player: Player)
	if self.phase ~= "Resolve" or not self:_isMember(player) then
		return
	end
	self:returnToStaging()
	self.readyPlayers[player.UserId] = true
	self:replicate()
	if self:_countReady() >= #self.members then
		self:_beginDeparture()
	end
end

function CrewMatch:returnToStaging()
	self:_stopRuntime()
	cancelThread(self.resolveThread)
	self.resolveThread = nil
	self.roles:clear()
	table.clear(self.readyPlayers)
	table.clear(self.votes)

	self.leg = 0
	self.carriedValue = 0
	self.legValue = 0
	self.cargo = nil
	self.cargoStability = 100
	self.convoyCascades = 0
	self.timeRemaining = 0
	self.timeSurvived = 0
	self.lastFailureLabel = nil
	self.failReason = nil
	self.countdownSeconds = 0
	self.decisionSeconds = 0

	self.rig:reset()
	self.rig:applyCargo(nil)
	self:_updateCrewTag()

	if #self.members > 0 then
		self:_setPhase("Staging")
		self:_beginStageTimer()
	else
		self:_setPhase("Idle")
	end
end

function CrewMatch:_abandon()
	self:_stopRuntime()
	cancelThread(self.stageThread)
	self.stageThread = nil
	cancelThread(self.countdownThread)
	self.countdownThread = nil
	cancelThread(self.resolveThread)
	self.resolveThread = nil
	self.roles:clear()
	table.clear(self.readyPlayers)
	table.clear(self.votes)

	self.leg = 0
	self.carriedValue = 0
	self.legValue = 0
	self.cargo = nil
	self.failReason = nil
	self.timeRemaining = 0
	self.timeSurvived = 0
	self.countdownSeconds = 0
	self.decisionSeconds = 0
	self.rig:reset()
	self.rig:applyCargo(nil)
	self:_updateCrewTag()
	self:_setPhase("Idle")
end

--------------------------------------------------------------------------------
-- Player input
--------------------------------------------------------------------------------

function CrewMatch:handleDriveInput(player: Player, payload: any)
	if not self:isLiveRun() or self.roles:getRole(player) ~= "Driver" then
		return
	end
	if typeof(payload) ~= "table" then
		return
	end
	local throttle = payload.throttle
	local steering = payload.steering
	local braking = payload.braking
	local function finite(value: unknown): boolean
		return typeof(value) == "number" and value == value and math.abs(value) < math.huge
	end
	if not finite(throttle) or not finite(steering) or typeof(braking) ~= "boolean" then
		return
	end
	self.driveInputs[player.UserId] = {
		throttle = math.clamp(throttle, -1, 1),
		steering = math.clamp(steering, -1, 1),
		braking = braking,
		updatedAt = os.clock(),
	}
end

function CrewMatch:handleRoleAction(player: Player, action: string)
	local runner = self.failureRunner
	if not self:isLiveRun() or not runner then
		return
	end
	local roleId = self.roles:getRole(player)
	local active = runner:getActive()
	if not roleId
		or not active
		or active.resolved
		or active.cascaded
		or active.def.responsibleRole ~= roleId
	then
		return
	end

	if active.def.interaction == "Ping" and action == "Ping" then
		if runner:tryResolve(roleId) then
			self:_toast(player.Name .. " marked the hazard.")
		end
	elseif active.def.interaction == "Hold" and action == "BeginResolve" then
		local failureId = active.def.id
		self.holdActions[player.UserId] = failureId
		self:_toast(player.Name .. " is working on " .. active.def.label .. "...")
		task.delay(active.def.holdSeconds or 1.5, function()
			if not self:isLiveRun() or self.holdActions[player.UserId] ~= failureId then
				return
			end
			local currentRunner = self.failureRunner
			if not currentRunner then
				return
			end
			local current = currentRunner:getActive()
			if not current or current.def.id ~= failureId then
				return
			end
			self.holdActions[player.UserId] = nil
			if currentRunner:tryResolve(roleId) then
				self:_toast(player.Name .. " (" .. roleId .. ") saved it.")
			end
		end)
	elseif action == "EndResolve" then
		self.holdActions[player.UserId] = nil
	end
end

return CrewMatch
