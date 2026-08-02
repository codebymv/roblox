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
local RouteFeatures = require(Shared:WaitForChild("RouteFeatures"))

local PressureDirector = {}
PressureDirector.__index = PressureDirector

local WHEELS = { "FL", "FR", "RL", "RR" }

--[[
	Where a category lands hardest now comes from the route.

	These used to be literal fractions -- 0.06 to 0.19 for the first corner --
	measured off one specific road. Weakening a strap on a straight is nearly
	free and weakening one two seconds before a corner is the whole game, so
	getting the locations wrong does not break anything visibly; it just makes
	every failure feel arbitrary. A second route would have inherited the first
	route's map of itself.
]]
-- After the scripted corner setup, refuse a random event for at least this long
-- so it cannot stack on top of the blind right.
local CORNER_SETUP_MIN_GAP = 22
-- Late-run intervals shrink toward this fraction of the base range.
local INTERVAL_PROGRESS_SCALE = 0.35

-- Fallback for the opener when a route has no corner at all, which no real
-- route should, but a test fixture or a stripped route might.
local CORNER_SETUP_FALLBACK = 0.075

local function pick(rng: Random, range: NumberRange): number
	return rng:NextNumber(range.Min, range.Max)
end

local function nextInterval(rng: Random, progress: number, intervalScale: number): number
	local interval = pick(rng, LabConfig.PressureIntervalSeconds)
	return interval * (1 - INTERVAL_PROGRESS_SCALE * math.clamp(progress, 0, 1)) * intervalScale
end

function PressureDirector.new(chassisRig, cargoLoad, onEvent, features)
	local resolved = features or {}
	return setmetatable({
		chassisRig = chassisRig,
		cargoLoad = cargoLoad,
		onEvent = onEvent,
		features = resolved,
		-- Placed just short of the route's first corner, wherever that is.
		cornerSetupProgress = RouteFeatures.firstOf(resolved, RouteFeatures.Kind.Corner) or CORNER_SETUP_FALLBACK,
		rng = Random.new(),
		elapsed = 0,
		nextEventAt = LabConfig.PressureFirstEventSeconds,
		gustRemaining = 0,
		gustAccel = Vector3.zero,
		lastCategory = "",
		activeLabel = "none",
		firedCornerSetup = false,
		intervalScale = 1,
		pressureScale = 1,
	}, PressureDirector)
end

-- Terrain lookup. A route with no features of a kind simply never weights that
-- category, which is the correct behaviour for a road that has no bridge.
function PressureDirector:_inFeature(progress: number, kind): boolean
	return RouteFeatures.inKind(self.features, progress, kind)
end

function PressureDirector:configure(difficulty)
	self.intervalScale = math.clamp(difficulty and difficulty.intervalScale or 1, 0.5, 1.5)
	self.pressureScale = math.clamp(difficulty and difficulty.pressureScale or 1, 0.5, 1.5)
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
	local eventRoll = self.rng:NextNumber()
	if eventRoll < 0.18 then
		local chassis = self.chassisRig:getChassis()
		if not chassis or not chassis.Parent then
			return false
		end
		local side = if self.rng:NextNumber() > 0.5 then 1 else -1
		local raw = chassis.CFrame.RightVector * side + chassis.CFrame.LookVector * 0.25
		local direction = if raw.Magnitude > 1e-4 then raw.Unit else chassis.CFrame.RightVector * side
		local velocityChange = pick(self.rng, LabConfig.GustAccel) * 0.3 * self.pressureScale
		self.cargoLoad:applyJolt(direction * velocityChange)
		self:_announce("Cargo jolt", if side > 0 then "right" else "left")
		return true
	end

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
	if eventRoll < 0.36 and #candidates >= 2 then
		local firstIndex = self.rng:NextInteger(1, #candidates)
		local first = table.remove(candidates, firstIndex)
		local second = candidates[self.rng:NextInteger(1, #candidates)]
		local amount = pick(self.rng, LabConfig.StrapWeakenAmount) * 0.55 * self.pressureScale
		self.cargoLoad:weakenStrap(first, amount)
		self.cargoLoad:weakenStrap(second, amount)
		self:_announce("Ratchet cascade", first .. "+" .. second)
		return true
	end

	local chosen = candidates[self.rng:NextInteger(1, #candidates)]

	--[[
		Approaching a corner, prefer the rail the load is about to swing away
		from. Skip anything already badly worn: the point is to give the crew
		two straps worth watching, not to guarantee a break before the driver
		has had a chance to do anything about it.
	]]
	if self:_inFeature(progress, RouteFeatures.Kind.Corner) then
		for _, id in { "FR", "RR", "FL", "RL" } do
			local strap = self.cargoLoad:getStrap(id)
			if strap and not strap.broken and strap.health > LabConfig.StrapMaxHealth * 0.6 then
				chosen = id
				break
			end
		end
	end

	local amount = pick(self.rng, LabConfig.StrapWeakenAmount) * self.pressureScale
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
		if self:_inFeature(progress, RouteFeatures.Kind.Descent) then
			-- On the descent the front carries the load, so hurt the front.
			wheel = if self.rng:NextNumber() > 0.5 then "FL" else "FR"
		end
		self.chassisRig:damageSuspension(wheel, pick(self.rng, LabConfig.SuspensionDamageAmount) * self.pressureScale)
		self:_announce("Suspension " .. wheel .. " sagging", wheel)
	else
		self.chassisRig:degradeSteering(pick(self.rng, LabConfig.SteeringDegradeAmount) * self.pressureScale)
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
	if not chassis or not chassis.Parent then
		return false
	end
	local magnitude = pick(self.rng, LabConfig.GustAccel) * self.pressureScale
	if self:_inFeature(progress, RouteFeatures.Kind.Bridge) then
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
	if self:_inFeature(progress, RouteFeatures.Kind.Corner) then
		weights.Cargo = 6
	elseif self:_inFeature(progress, RouteFeatures.Kind.Descent) then
		weights.Mechanical = 5
	elseif self:_inFeature(progress, RouteFeatures.Kind.Bridge) then
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
	if not self.firedCornerSetup and progress >= self.cornerSetupProgress then
		self.firedCornerSetup = true
		self:_cargoPressure(progress)
		self.nextEventAt = self.elapsed
			+ math.max(nextInterval(self.rng, progress, self.intervalScale), CORNER_SETUP_MIN_GAP * self.intervalScale)
		return
	end

	if self.elapsed >= self.nextEventAt then
		self:_fire(progress)
		self.nextEventAt = self.elapsed + nextInterval(self.rng, progress, self.intervalScale)
	end
end

function PressureDirector:getActiveLabel(): string
	return self.activeLabel
end

function PressureDirector:reset()
	self.elapsed = 0
	self.nextEventAt = LabConfig.PressureFirstEventSeconds * self.intervalScale
	self.gustRemaining = 0
	self.gustAccel = Vector3.zero
	self.lastCategory = ""
	self.activeLabel = "none"
	self.firedCornerSetup = false
	self.chassisRig:applyExternalAccel(Vector3.zero)
end

return PressureDirector
