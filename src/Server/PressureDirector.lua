--!nonstrict

--[[
	Three categories of pressure, replacing the eight authored failures.

	The critical difference: this director never decides an outcome. It weakens
	a strap, sags a corner of the suspension, softens the steering, or pushes
	the truck sideways. What happens next is decided by the road, the driver,
	and where the crew is standing.

	It is also contextual. Weakening a strap is worth far more just before the
	blind corner than on a straight, so the director looks at route progress and
	spends its events where they will find something.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LabConfig = require(Shared:WaitForChild("LabConfig"))

local PressureDirector = {}
PressureDirector.__index = PressureDirector

local WHEELS = { "FL", "FR", "RL", "RR" }

--[[
	Stretches of route where a given category lands hardest, as fractions of the
	arc length built in WorldBuilder.buildLabNodes. Weakening a strap on a
	straight is nearly free; weakening one two seconds before a corner is the
	whole game.
]]
local CORNER_WINDOWS = { { 0.06, 0.19 }, { 0.51, 0.60 }, { 0.72, 0.88 } }
local DESCENT_WINDOW = { 0.22, 0.42 }
local BRIDGE_WINDOW = { 0.56, 0.70 }

-- Progress at which the scripted opener adds the second half of its setup,
-- placed just short of the blind right-hander.
local CORNER_SETUP_PROGRESS = 0.075

local function inWindow(progress: number, window): boolean
	return progress >= window[1] and progress <= window[2]
end

local function nearCorner(progress: number): boolean
	for _, window in CORNER_WINDOWS do
		if inWindow(progress, window) then
			return true
		end
	end
	return false
end

local function pick(rng: Random, range: NumberRange): number
	return rng:NextNumber(range.Min, range.Max)
end

function PressureDirector.new(chassisRig, cargoLoad, onEvent)
	return setmetatable({
		chassisRig = chassisRig,
		cargoLoad = cargoLoad,
		onEvent = onEvent,
		rng = Random.new(),
		elapsed = 0,
		nextEventAt = LabConfig.PressureFirstEventSeconds,
		gustRemaining = 0,
		gustAccel = Vector3.zero,
		lastCategory = "",
		activeLabel = "none",
		firedCornerSetup = false,
	}, PressureDirector)
end

function PressureDirector:_announce(label: string, detail: string)
	self.activeLabel = label
	if self.onEvent then
		self.onEvent(label, detail)
	end
end

--[[
	Cargo instability: take health out of one strap. Prefers the strap on the
	outside of the corner that is coming, so the crew has to notice and cross.
]]
function PressureDirector:_cargoPressure(progress: number)
	local candidates = {}
	for _, id in LabConfig.StrapOrder do
		local strap = self.cargoLoad:getStrap(id)
		if strap and not strap.broken then
			table.insert(candidates, id)
		end
	end
	if #candidates == 0 then
		return false
	end

	local chosen = candidates[self.rng:NextInteger(1, #candidates)]

	--[[
		Approaching a corner, prefer the rail the load is about to swing away
		from. Skip anything already badly worn: the point is to give the crew
		two straps worth watching, not to guarantee a break before the driver
		has had a chance to do anything about it.
	]]
	if nearCorner(progress) then
		for _, id in { "FR", "RR", "FL", "RL" } do
			local strap = self.cargoLoad:getStrap(id)
			if strap and not strap.broken and strap.health > LabConfig.StrapMaxHealth * 0.6 then
				chosen = id
				break
			end
		end
	end

	local amount = pick(self.rng, LabConfig.StrapWeakenAmount)
	self.cargoLoad:weakenStrap(chosen, amount)
	self:_announce("Strap " .. chosen .. " slipping", chosen)
	return true
end

--[[
	Mechanical degradation: a sagging corner or vague steering. Both change how
	the truck behaves rather than subtracting from anything.
]]
function PressureDirector:_mechanicalPressure(progress: number)
	if self.rng:NextNumber() < 0.62 then
		local wheel = WHEELS[self.rng:NextInteger(1, #WHEELS)]
		if inWindow(progress, DESCENT_WINDOW) then
			-- On the descent the front carries the load, so hurt the front.
			wheel = if self.rng:NextNumber() > 0.5 then "FL" else "FR"
		end
		self.chassisRig:damageSuspension(wheel, pick(self.rng, LabConfig.SuspensionDamageAmount))
		self:_announce("Suspension " .. wheel .. " sagging", wheel)
	else
		self.chassisRig:degradeSteering(pick(self.rng, LabConfig.SteeringDegradeAmount))
		self:_announce("Steering going vague", "steering")
	end
	return true
end

--[[
	Environmental pressure: a real sideways force for a couple of seconds. On
	the bridge this is the whole event; anywhere else it is a nudge.
]]
function PressureDirector:_environmentalPressure(progress: number)
	local chassis = self.chassisRig:getChassis()
	local magnitude = pick(self.rng, LabConfig.GustAccel)
	if inWindow(progress, BRIDGE_WINDOW) then
		magnitude *= 1.35
	end
	local direction = if self.rng:NextNumber() > 0.5 then 1 else -1
	self.gustAccel = chassis.CFrame.RightVector * magnitude * direction
	self.gustRemaining = pick(self.rng, LabConfig.GustSeconds)
	self:_announce("Crosswind", if direction > 0 then "right" else "left")
	return true
end

function PressureDirector:_fire(progress: number)
	-- Weight the categories by where the truck is, then avoid repeating.
	local weights = { Cargo = 3, Mechanical = 2, Environmental = 2 }
	if nearCorner(progress) then
		weights.Cargo = 6
	elseif inWindow(progress, DESCENT_WINDOW) then
		weights.Mechanical = 5
	elseif inWindow(progress, BRIDGE_WINDOW) then
		weights.Environmental = 6
	end
	weights[self.lastCategory] = math.max(1, (weights[self.lastCategory] or 2) - 2)

	local total = weights.Cargo + weights.Mechanical + weights.Environmental
	local roll = self.rng:NextNumber() * total

	local category
	if roll < weights.Cargo then
		category = "Cargo"
	elseif roll < weights.Cargo + weights.Mechanical then
		category = "Mechanical"
	else
		category = "Environmental"
	end

	local fired
	if category == "Cargo" then
		fired = self:_cargoPressure(progress)
	elseif category == "Mechanical" then
		fired = self:_mechanicalPressure(progress)
	else
		fired = self:_environmentalPressure(progress)
	end

	if fired then
		self.lastCategory = category
	end
end

function PressureDirector:step(dt: number, progress: number)
	self.elapsed += dt

	if self.gustRemaining > 0 then
		self.gustRemaining -= dt
		self.chassisRig:applyExternalAccel(self.gustAccel)
		if self.gustRemaining <= 0 then
			self.chassisRig:applyExternalAccel(Vector3.zero)
			self.activeLabel = "none"
		end
	end

	--[[
		The designed opener. One strap is already compromised at the start of
		the run; this adds the second half of the setup just before the blind
		corner, so the corner has something to find. The outcome is still open:
		brake early and it holds, carry speed and it does not.
	]]
	if not self.firedCornerSetup and progress >= CORNER_SETUP_PROGRESS then
		self.firedCornerSetup = true
		self:_cargoPressure(progress)
		self.nextEventAt = self.elapsed + pick(self.rng, LabConfig.PressureIntervalSeconds)
		return
	end

	if self.elapsed >= self.nextEventAt then
		self:_fire(progress)
		self.nextEventAt = self.elapsed + pick(self.rng, LabConfig.PressureIntervalSeconds)
	end
end

function PressureDirector:getActiveLabel(): string
	return self.activeLabel
end

function PressureDirector:reset()
	self.elapsed = 0
	self.nextEventAt = LabConfig.PressureFirstEventSeconds
	self.gustRemaining = 0
	self.gustAccel = Vector3.zero
	self.lastCategory = ""
	self.activeLabel = "none"
	self.firedCornerSetup = false
	self.chassisRig:applyExternalAccel(Vector3.zero)
end

return PressureDirector
