--!nonstrict

--[[
	The load is a real object.

	A crate with real mass sits on the bed and is held by four RopeConstraints
	running from the side rails up to its top corners. Ropes resist extension
	only, which is exactly what a strap does, and they fail one at a time.

	Nothing here writes a stability number. Strap tension is computed from the
	chassis's measured acceleration and the actual rope geometry; the crate's
	condition is read back out of where the crate physically is. If the load
	ends up hanging off the left side of the truck, it is because it slid there.

	Roblox does not expose the force inside a RopeConstraint, so tension is an
	estimate: the pseudo-force the load exerts, expressed in crate-weights, and
	projected onto each taut rope. It is an estimate of a real quantity rather
	than an authored value.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LabConfig = require(Shared:WaitForChild("LabConfig"))
local LabTypes = require(Shared:WaitForChild("LabTypes"))

local GRAVITY = workspace.Gravity

local CargoLoad = {}
CargoLoad.__index = CargoLoad

local HEALTHY = BrickColor.new("Bright blue")
local STRESSED = BrickColor.new("Bright yellow")
local CRITICAL = BrickColor.new("Neon orange")

function CargoLoad.new(chassis, parent: Instance)
	local self = setmetatable({
		chassisRig = chassis,
		parent = parent,
		straps = {},
		condition = "Secure" :: LabTypes.CargoCondition,
		readout = 100,
		offset = 0,
		leanDeg = 0,
		dragging = false,
		lost = false,
		lastCause = "",
		shockCooldown = {},
	}, CargoLoad)

	self:_build()
	return self
end

function CargoLoad:_build()
	local body = self.chassisRig:getChassis()

	local crate = Instance.new("Part")
	crate.Name = "Crate"
	crate.Size = LabConfig.CrateSize
	crate.CFrame = body.CFrame * CFrame.new(LabConfig.CrateHome)
	crate.Color = Color3.fromRGB(214, 132, 52)
	crate.Material = Enum.Material.WoodPlanks
	crate.Anchored = false
	crate.CanCollide = true
	crate.CustomPhysicalProperties = PhysicalProperties.new(LabConfig.CrateDensity, 0.55, 0.05, 2, 1)
	crate.Parent = self.parent

	local dragRayParams = RaycastParams.new()
	dragRayParams.FilterType = Enum.RaycastFilterType.Exclude
	dragRayParams.IgnoreWater = true
	dragRayParams.FilterDescendantsInstances = { self.chassisRig:getModel(), crate }

	self.crate = crate
	self.dragRayParams = dragRayParams
	self.crateMass = crate.AssemblyMass

	for _, id in LabConfig.StrapOrder do
		local crateAttachment = Instance.new("Attachment")
		crateAttachment.Name = "Crate_" .. id
		crateAttachment.Position = LabConfig.StrapCrateLocal[id]
		crateAttachment.Parent = crate

		local railAttachment = self.chassisRig:getAnchor(id)
		local restLength = (railAttachment.WorldPosition - crateAttachment.WorldPosition).Magnitude

		self.straps[id] = {
			id = id,
			health = LabConfig.StrapMaxHealth,
			tension = 0,
			broken = false,
			restLength = restLength,
			stretch = 0,
			rope = nil,
			railAttachment = railAttachment,
			crateAttachment = crateAttachment,
			reattachable = false,
			workedBy = nil,
			reattachProgress = 0,
		}

		self:_makeRope(id)
	end

	-- The suspension has to know about the crate so it does not raycast into it.
	self.chassisRig:setIgnoreList({ crate })
	self:claimOwnership()
end

--[[
	The crate is its own assembly, connected to the truck only by ropes, so it
	can have its ownership handed to whichever client last brushed against it.
	Keeping it on the server is what stops the load being in a different place
	for every player.
]]
function CargoLoad:claimOwnership()
	local crate = self.crate
	if not crate or not crate.Parent or crate.Anchored then
		return
	end
	pcall(function()
		if crate:GetNetworkOwnershipAuto() or crate:GetNetworkOwner() ~= nil then
			crate:SetNetworkOwner(nil)
		end
	end)
end

function CargoLoad:_makeRope(id: string)
	local strap = self.straps[id]
	if strap.rope then
		strap.rope:Destroy()
	end

	local rope = Instance.new("RopeConstraint")
	rope.Name = "Strap_" .. id
	rope.Attachment0 = strap.railAttachment
	rope.Attachment1 = strap.crateAttachment
	rope.Length = strap.restLength + strap.stretch
	rope.Restitution = 0
	rope.Visible = true
	rope.Thickness = 0.22
	rope.Color = HEALTHY
	rope.Parent = self.chassisRig:getChassis()

	strap.rope = rope
	strap.broken = false
end

function CargoLoad:_breakStrap(id: string, cause: string)
	local strap = self.straps[id]
	if strap.broken then
		return
	end
	strap.broken = true
	strap.health = 0
	strap.tension = 0
	strap.reattachProgress = 0
	if strap.rope then
		strap.rope:Destroy()
		strap.rope = nil
	end
	self.lastCause = string.format("%s strap failed (%s)", id, cause)
end

function CargoLoad:getCrate(): BasePart
	return self.crate
end

function CargoLoad:getMass(): number
	return self.crateMass
end

function CargoLoad:getStrap(id: string)
	return self.straps[id]
end

--[[
	Pre-weaken a strap. Used by the scripted opener and by the pressure
	director. It changes what the load can survive; it does not decide anything.
]]
function CargoLoad:weakenStrap(id: string, amount: number)
	local strap = self.straps[id]
	if not strap or strap.broken then
		return
	end
	strap.health = math.max(0, strap.health - amount)
	if strap.health <= 0 then
		self:_breakStrap(id, "wear")
	end
end

function CargoLoad:tighten(id: string, dt: number, workerName: string?): boolean
	local strap = self.straps[id]
	if not strap then
		return false
	end
	strap.workedBy = workerName

	if strap.broken then
		if not strap.reattachable then
			strap.reattachProgress = 0
			return false
		end
		strap.reattachProgress += dt
		if strap.reattachProgress >= LabConfig.StrapReattachSeconds then
			local gap = (strap.railAttachment.WorldPosition - strap.crateAttachment.WorldPosition).Magnitude
			strap.stretch = math.clamp(gap - strap.restLength, 0, LabConfig.StrapMaxStretch)
			strap.health = LabConfig.StrapMaxHealth * 0.45
			strap.reattachProgress = 0
			self:_makeRope(id)
			self.lastCause = string.format("%s strap refitted", id)
			return true
		end
		return false
	end

	strap.health = math.min(LabConfig.StrapMaxHealth, strap.health + LabConfig.StrapTightenPerSecond * dt)
	-- Tightening also takes the accumulated slack back out, which is how a
	-- crew walks a crept load back toward the middle of the bed.
	strap.stretch = math.max(0, strap.stretch - dt * 0.9)
	if strap.rope then
		strap.rope.Length = strap.restLength + strap.stretch
	end
	return true
end

function CargoLoad:clearWorker(id: string)
	local strap = self.straps[id]
	if strap then
		strap.workedBy = nil
		strap.reattachProgress = 0
	end
end

function CargoLoad:step(dt: number)
	local crate = self.crate
	local body = self.chassisRig:getChassis()
	if not crate or not crate.Parent or not body then
		return
	end

	local bodyCF = body.CFrame
	local weight = math.max(self.crateMass * GRAVITY, 1)

	--[[
		The force the straps must resist: the load's inertial reaction to
		whatever the truck just did, plus its weight. Expressed in crate-weights
		so the thresholds in LabConfig stay readable.
	]]
	local pseudoWorld = (-self.chassisRig.accelWorld + Vector3.new(0, -GRAVITY, 0)) * self.crateMass
	local demand = pseudoWorld / weight

	for _, id in LabConfig.StrapOrder do
		local strap = self.straps[id]

		if strap.broken then
			local gap = (strap.railAttachment.WorldPosition - strap.crateAttachment.WorldPosition).Magnitude
			strap.reattachable = gap <= LabConfig.StrapReattachMaxGap
			strap.tension = 0
			continue
		end

		local railWorld = strap.railAttachment.WorldPosition
		local crateWorld = strap.crateAttachment.WorldPosition
		local delta = crateWorld - railWorld
		local distance = delta.Magnitude
		local length = math.max(strap.rope and strap.rope.Length or strap.restLength, 0.05)
		local tautness = distance / length

		local tension = 0
		if tautness > 0.94 and distance > 0.01 then
			-- Only the component pulling the crate away from this anchor counts.
			tension = math.max(0, demand:Dot(delta.Unit)) * math.clamp(tautness, 0, 1.25)
		end
		strap.tension = tension

		local over = tension - LabConfig.StrapTensionThreshold
		if over > 0 then
			strap.health -= over * LabConfig.StrapWearRate * dt

			-- A sharp spike stretches the strap permanently, so the load creeps
			-- out of position across a run instead of failing all at once.
			local cooldown = self.shockCooldown[id] or 0
			if tension > LabConfig.StrapTensionThreshold * 2.4 and os.clock() > cooldown then
				strap.stretch = math.min(LabConfig.StrapMaxStretch, strap.stretch + LabConfig.StrapStretchPerShock)
				self.shockCooldown[id] = os.clock() + 0.5
			end

			if strap.health <= 0 then
				self:_breakStrap(id, "tension")
				continue
			end
		elseif tension < LabConfig.StrapTensionThreshold * 0.5 then
			-- Slow passive recovery, capped well below full so the crew is
			-- still the only way to get a strap properly secure again.
			strap.health = math.min(
				LabConfig.StrapMaxHealth * 0.7,
				strap.health + LabConfig.StrapRecoverRate * dt
			)
		end

		if strap.rope then
			strap.rope.Length = strap.restLength + strap.stretch
			local ratio = strap.health / LabConfig.StrapMaxHealth
			strap.rope.Color = if ratio > 0.6 then HEALTHY elseif ratio > 0.28 then STRESSED else CRITICAL
			strap.rope.Thickness = 0.18 + math.clamp(strap.tension, 0, 2) * 0.09
		end
	end

	self:_updateCondition(dt, bodyCF)
end

function CargoLoad:_updateCondition(dt: number, bodyCF: CFrame)
	local crate = self.crate

	local localPosition = bodyCF:PointToObjectSpace(crate.Position)
	local delta = localPosition - LabConfig.CrateHome
	self.localOffset = delta
	self.offset = Vector3.new(delta.X, 0, delta.Z).Magnitude

	local alignment = math.clamp(crate.CFrame.UpVector:Dot(bodyCF.UpVector), -1, 1)
	self.leanDeg = math.deg(math.acos(alignment))

	local brokenCount = 0
	local healthSum = 0
	for _, id in LabConfig.StrapOrder do
		local strap = self.straps[id]
		healthSum += strap.health
		if strap.broken then
			brokenCount += 1
		end
	end

	-- Is the load physically scraping the ground?
	local down = Vector3.new(0, -(LabConfig.CrateSize.Y * 0.5 + 0.8), 0)
	local hit = workspace:Raycast(crate.Position, down, self.dragRayParams)
	local horizontalSpeed = Vector3.new(
		crate.AssemblyLinearVelocity.X,
		0,
		crate.AssemblyLinearVelocity.Z
	).Magnitude
	self.dragging = hit ~= nil and self.offset > LabConfig.ShiftedOffset and horizontalSpeed > 3

	if self.dragging then
		-- Real drag on the crate. The straps then pull the truck around, which
		-- is why a dragging load is a handling problem and not a status effect.
		local resist = -crate.AssemblyLinearVelocity * LabConfig.DragForcePerStud * dt
		crate:ApplyImpulseAtPosition(Vector3.new(resist.X, 0, resist.Z), crate.Position)
	end

	local separation = (crate.Position - bodyCF.Position).Magnitude
	self.lost = (brokenCount >= #LabConfig.StrapOrder and self.offset > LabConfig.LostOffset)
		or separation > 34

	local condition: LabTypes.CargoCondition
	if self.lost then
		condition = "Lost"
	elseif self.dragging then
		condition = "Dragging"
	elseif self.offset > LabConfig.HangingOffset or self.leanDeg > LabConfig.HangingAngleDeg then
		condition = "Hanging"
	elseif brokenCount >= 1 then
		condition = "PartiallyDetached"
	elseif self.offset > LabConfig.SlidingOffset then
		condition = "Sliding"
	elseif self.leanDeg > LabConfig.LeaningAngleDeg then
		condition = "Leaning"
	elseif self.offset > LabConfig.ShiftedOffset then
		condition = "Shifted"
	else
		condition = "Secure"
	end

	if condition ~= self.condition then
		self.previousCondition = self.condition
		self.condition = condition
		self.conditionChangedAt = os.clock()
		self.conditionDirty = true
	end

	--[[
		The HUD number. Purely a readout of the three things a player can
		already see: how good the straps are, how far the load has moved, and
		how far over it is leaning.
	]]
	local strapScore = healthSum / (#LabConfig.StrapOrder * LabConfig.StrapMaxHealth)
	local offsetScore = 1 - math.clamp(self.offset / LabConfig.LostOffset, 0, 1)
	local leanScore = 1 - math.clamp(self.leanDeg / LabConfig.HangingAngleDeg, 0, 1)
	self.readout = math.floor(100 * (0.45 * strapScore + 0.35 * offsetScore + 0.2 * leanScore))
end

--[[
	Returns whether the condition changed, what it changed from, and the most
	recent physical cause. The cause is cleared on read so the next transition
	is never mislabelled with a stale reason.
]]
function CargoLoad:consumeConditionChange(): (boolean, string?, string?)
	if not self.conditionDirty then
		return false, nil, nil
	end
	self.conditionDirty = false
	local cause = self.lastCause
	self.lastCause = ""
	return true, self.previousCondition, if cause ~= "" then cause else nil
end

function CargoLoad:snapshotStraps(): { LabTypes.StrapSnapshot }
	local list = {}
	for index, id in LabConfig.StrapOrder do
		local strap = self.straps[id]
		list[index] = {
			id = id,
			health = math.floor(strap.health),
			tension = math.floor(strap.tension * 100) / 100,
			broken = strap.broken,
			stretch = math.floor(strap.stretch * 100) / 100,
			reattachable = strap.reattachable,
			workedBy = strap.workedBy,
		}
	end
	return list
end

function CargoLoad:reset()
	local body = self.chassisRig:getChassis()
	local crate = self.crate

	crate.AssemblyLinearVelocity = Vector3.zero
	crate.AssemblyAngularVelocity = Vector3.zero
	crate.CFrame = body.CFrame * CFrame.new(LabConfig.CrateHome)
	crate.AssemblyLinearVelocity = Vector3.zero
	crate.AssemblyAngularVelocity = Vector3.zero

	for _, id in LabConfig.StrapOrder do
		local strap = self.straps[id]
		strap.health = LabConfig.StrapMaxHealth
		strap.tension = 0
		strap.stretch = 0
		strap.reattachable = false
		strap.workedBy = nil
		strap.reattachProgress = 0
		self:_makeRope(id)
	end

	self.condition = "Secure"
	self.previousCondition = nil
	self.conditionDirty = false
	self.readout = 100
	self.offset = 0
	self.leanDeg = 0
	self.dragging = false
	self.lost = false
	self.lastCause = ""
	self.shockCooldown = {}
end

function CargoLoad:destroy()
	if self.crate then
		self.crate:Destroy()
		self.crate = nil
	end
end

return CargoLoad
