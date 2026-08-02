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
local GRAVITY_DOWN = Vector3.new(0, -GRAVITY, 0)

local CargoLoad = {}
CargoLoad.__index = CargoLoad

local HEALTHY = BrickColor.new("Cork")
local STRESSED = BrickColor.new("Gold")
local CRITICAL = BrickColor.new("Rust")

local MARKER_REFIT = Color3.fromRGB(255, 205, 90)
local MARKER_OUT_OF_REACH = Color3.fromRGB(220, 90, 90)
local CARGO_COLORS = {
	GeneralFreight = Color3.fromRGB(214, 132, 52),
	TowerLoad = Color3.fromRGB(185, 108, 55),
	CompactGenerator = Color3.fromRGB(78, 94, 108),
}

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
		pendingBreaks = {} :: { string },
		pendingRefits = {} :: { string },
		brackets = {},
		home = LabConfig.CrateHome,
		variantModel = nil,
		_dragRaySizeY = nil :: number?,
		_dragRayDir = Vector3.new(0, -(LabConfig.CrateSize.Y * 0.5 + 0.8), 0),
	}, CargoLoad)

	self:_build()
	return self
end

function CargoLoad:_build()
	local body = self.chassisRig:getChassis()

	local pallet = Instance.new("Part")
	pallet.Name = "Pallet"
	pallet.Size = Vector3.new(6.4, 0.35, 6.4)
	local palletCenterY = LabConfig.CrateHome.Y - LabConfig.CrateSize.Y * 0.5 - 0.18
	pallet.CFrame = body.CFrame * CFrame.new(LabConfig.CrateHome.X, palletCenterY, LabConfig.CrateHome.Z)
	pallet.Color = Color3.fromRGB(118, 82, 48)
	pallet.Material = Enum.Material.WoodPlanks
	pallet.Anchored = false
	pallet.CanCollide = true
	pallet.CustomPhysicalProperties = PhysicalProperties.new(0.9, 0.55, 0, 1, 1)
	-- Parent under the truck model so PivotTo on reset/warp moves the pallet with
	-- the chassis. Parenting under the route folder left it at the wreck pose
	-- until the weld solver yanked the assembly.
	pallet.Parent = self.chassisRig:getModel()

	local palletWeld = Instance.new("WeldConstraint")
	palletWeld.Part0 = body
	palletWeld.Part1 = pallet
	palletWeld.Parent = body
	self.palletWeld = palletWeld

	local crate = Instance.new("Part")
	crate.Name = "Crate"
	crate.Size = LabConfig.CrateSize
	crate.CFrame = body.CFrame * CFrame.new(LabConfig.CrateHome)
	crate.Color = Color3.fromRGB(214, 132, 52)
	crate.Material = Enum.Material.WoodPlanks
	crate.Anchored = false
	crate.CanCollide = true
	crate.CustomPhysicalProperties = PhysicalProperties.new(LabConfig.CrateDensity, 0.55, 0.05, 2, 1)
	-- Parent under the truck so PivotTo / void yank moves the crate with the
	-- model. Keep it unwelded — ropes alone connect it to the chassis assembly.
	local truck = self.chassisRig:getModel()
	crate.Parent = truck

	for _, id in LabConfig.StrapOrder do
		local corner = LabConfig.StrapCrateLocal[id]
		local bracket = Instance.new("Part")
		bracket.Name = "Bracket_" .. id
		bracket.Size = Vector3.new(0.38, 0.38, 0.38)
		bracket.Color = Color3.fromRGB(88, 94, 102)
		bracket.Material = Enum.Material.Metal
		bracket.Anchored = false
		bracket.CanCollide = false
		bracket.Massless = true
		bracket.CFrame = crate.CFrame * CFrame.new(corner)
		bracket.Parent = truck

		local bracketWeld = Instance.new("WeldConstraint")
		bracketWeld.Part0 = crate
		bracketWeld.Part1 = bracket
		bracketWeld.Parent = crate
		self.brackets[id] = { part = bracket, weld = bracketWeld }
	end

	local dragRayParams = RaycastParams.new()
	dragRayParams.FilterType = Enum.RaycastFilterType.Exclude
	dragRayParams.IgnoreWater = true
	dragRayParams.FilterDescendantsInstances = { self.chassisRig:getModel(), crate }

	-- Ground drag, held rather than pulsed. See the comment at the use site.
	local dragAttachment = Instance.new("Attachment")
	dragAttachment.Name = "DragForce"
	dragAttachment.Parent = crate

	local dragForce = Instance.new("VectorForce")
	dragForce.Name = "Drag"
	dragForce.Attachment0 = dragAttachment
	dragForce.RelativeTo = Enum.ActuatorRelativeTo.World
	dragForce.ApplyAtCenterOfMass = true
	dragForce.Force = Vector3.zero
	dragForce.Parent = crate

	self.crate = crate
	self.pallet = pallet
	self.dragForce = dragForce
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
			marker = nil,
			markerLabel = nil,
		}

		self:_makeMarker(id)
		self:_makeRope(id)
	end

	-- The suspension has to know about the crate so it does not raycast into it.
	self.chassisRig:setIgnoreList({ crate })
	self:claimOwnership()
end

function CargoLoad:_addVariantDetail(
	name: string,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = self.crate.CFrame * offset
	part.Color = color
	part.Material = material
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.Parent = self.variantModel

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = self.crate
	weld.Part1 = part
	weld.Parent = part
	return part
end

-- Distinct dressing makes the cargo roll readable from the chase camera.
-- These pieces are visual-only and are recreated while staging.
function CargoLoad:_buildVariantDetails(variant)
	if self.variantModel then
		self.variantModel:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "CargoDetails"
	model.Parent = self.chassisRig:getModel()
	self.variantModel = model

	local size = self.crate.Size
	local frontZ = -size.Z * 0.5 - 0.07
	local rearZ = size.Z * 0.5 + 0.07
	if variant.id == "GeneralFreight" then
		for index, yScale in { -0.3, 0, 0.3 } do
			for _, z in { frontZ, rearZ } do
				self:_addVariantDetail(
					"TimberSlat" .. tostring(index),
					Vector3.new(size.X * 0.9, 0.18, 0.14),
					CFrame.new(0, size.Y * yScale, z),
					Color3.fromRGB(112, 72, 38),
					Enum.Material.Wood
				)
			end
		end
	elseif variant.id == "TowerLoad" then
		for _, x in { -1, 1 } do
			for _, z in { -1, 1 } do
				self:_addVariantDetail(
					"CornerBrace",
					Vector3.new(0.18, size.Y * 0.92, 0.18),
					CFrame.new(x * (size.X * 0.5 + 0.06), 0, z * (size.Z * 0.5 + 0.06)),
					Color3.fromRGB(245, 180, 48),
					Enum.Material.Metal
				)
			end
		end
		self:_addVariantDetail(
			"TopCap",
			Vector3.new(size.X + 0.25, 0.2, size.Z + 0.25),
			CFrame.new(0, size.Y * 0.5 + 0.08, 0),
			Color3.fromRGB(245, 180, 48),
			Enum.Material.Metal
		)
	else
		self:_addVariantDetail(
			"GeneratorTop",
			Vector3.new(size.X * 0.82, 0.24, size.Z * 0.78),
			CFrame.new(0, size.Y * 0.5 + 0.1, 0),
			Color3.fromRGB(38, 44, 50),
			Enum.Material.Metal
		)
		for _, side in { -1, 1 } do
			local x = side * (size.X * 0.5 + 0.07)
			for row = -1, 1 do
				self:_addVariantDetail(
					"Vent",
					Vector3.new(0.14, 0.16, size.Z * 0.54),
					CFrame.new(x, row * 0.38, 0),
					Color3.fromRGB(24, 28, 32),
					Enum.Material.Metal
				)
			end
		end
	end

	local plate = self:_addVariantDetail(
		"CargoPlacard",
		Vector3.new(math.min(size.X * 0.76, 4.8), math.min(size.Y * 0.22, 1.25), 0.12),
		CFrame.new(0, 0, rearZ + 0.03),
		Color3.fromRGB(32, 36, 42),
		Enum.Material.Metal
	)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "CargoLabel"
	gui.Face = Enum.NormalId.Back
	gui.LightInfluence = 0
	gui.PixelsPerStud = 32
	gui.Parent = plate
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(245, 220, 125)
	label.Text = variant.label
	label.Parent = gui
end

-- Apply a run's cargo geometry while the truck is parked. Strap attachments
-- follow the resized load, so the tall and compact variants change real
-- leverage rather than merely changing the label above the HUD.
function CargoLoad:configure(variant)
	local crate = self.crate
	local body = self.chassisRig:getChassis()
	if not crate or not body or not variant then
		return
	end

	local wasAnchored = crate.Anchored
	crate.Anchored = true
	local size = Vector3.new(
		LabConfig.CrateSize.X * variant.scaleX,
		LabConfig.CrateSize.Y * variant.scaleY,
		LabConfig.CrateSize.Z * variant.scaleZ
	)
	local bedHeight = LabConfig.CrateHome.Y - LabConfig.CrateSize.Y * 0.5
	self.home = Vector3.new(LabConfig.CrateHome.X, bedHeight + size.Y * 0.5, LabConfig.CrateHome.Z)
	crate.Size = size
	crate.CFrame = body.CFrame * CFrame.new(self.home)
	crate.Color = CARGO_COLORS[variant.id] or CARGO_COLORS.GeneralFreight
	crate.CustomPhysicalProperties = PhysicalProperties.new(variant.density, 0.55, 0.05, 2, 1)

	for _, id in LabConfig.StrapOrder do
		local base = LabConfig.StrapCrateLocal[id]
		local corner = Vector3.new(base.X * variant.scaleX, base.Y * variant.scaleY, base.Z * variant.scaleZ)
		local strap = self.straps[id]
		strap.crateAttachment.Position = corner

		local bracket = self.brackets[id]
		if bracket then
			bracket.weld:Destroy()
			bracket.part.CFrame = crate.CFrame * CFrame.new(corner)
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = crate
			weld.Part1 = bracket.part
			weld.Parent = crate
			bracket.weld = weld
		end
	end
	self:_buildVariantDetails(variant)

	crate.Anchored = wasAnchored
	self.crateMass = crate.AssemblyMass
end

--[[
	The crate is its own assembly, connected to the truck only by ropes, so it
	can have its ownership handed to whichever client last brushed against it.
	Keeping it on the server is what stops the load being in a different place
	for every player.
]]
function CargoLoad:claimOwnership(): boolean
	local crate = self.crate
	-- Same as chassis: reclaim even while Anchored so Staging ownership ticks work.
	if not crate or not crate.Parent then
		return false
	end
	local mutated = false
	pcall(function()
		local auto = crate:GetNetworkOwnershipAuto()
		local owner = crate:GetNetworkOwner()
		if auto or owner ~= nil then
			crate:SetNetworkOwner(nil)
			mutated = true
		end
	end)
	return mutated
end

--[[
	A broken strap has no rope left to colour, so the only presence it keeps in
	the world is this billboard. Disabled while the strap is intact; enabled and
	recoloured from step once it snaps.
]]
function CargoLoad:_makeMarker(id: string)
	local strap = self.straps[id]

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "StrapMarker_" .. id
	billboard.Adornee = strap.railAttachment
	billboard.Size = UDim2.fromOffset(110, 28)
	billboard.StudsOffset = Vector3.new(0, 1.6, 0)
	billboard.AlwaysOnTop = true
	billboard.Enabled = false
	billboard.Parent = self.parent

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = MARKER_REFIT
	label.TextStrokeTransparency = 0.4
	label.Text = ""
	label.Parent = billboard

	strap.marker = billboard
	strap.markerLabel = label
end

function CargoLoad:_updateMarker(strap)
	local marker = strap.marker
	local label = strap.markerLabel
	if not marker or not label then
		return
	end

	local enabled = strap.broken
	if marker.Enabled ~= enabled then
		marker.Enabled = enabled
	end
	if not enabled then
		return
	end

	local text = if strap.reattachable then strap.id .. " REFIT" else strap.id .. " OUT OF REACH"
	local color = if strap.reattachable then MARKER_REFIT else MARKER_OUT_OF_REACH
	if label.Text ~= text then
		label.Text = text
	end
	if label.TextColor3 ~= color then
		label.TextColor3 = color
	end
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
	rope.Thickness = LabConfig.StrapRopeThickness
	rope.Color = HEALTHY
	rope.Parent = self.chassisRig:getChassis()

	strap.rope = rope
	strap.broken = false
	self:_updateMarker(strap)
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
	table.insert(self.pendingBreaks, id)
	self:_updateMarker(strap)
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

-- A short, physical velocity change used by the pressure director. Outcomes
-- still come from the crate, ropes, road, and driver response.
function CargoLoad:applyJolt(velocityChange: Vector3)
	local crate = self.crate
	if crate and crate.Parent and not crate.Anchored then
		crate:ApplyImpulse(velocityChange * self.crateMass)
		self.lastCause = "cargo jolt"
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
			local maxStretch = math.max(0, LabConfig.StrapMaxStretch)
			strap.stretch = math.clamp(gap - strap.restLength, 0, maxStretch)
			strap.health = LabConfig.StrapMaxHealth * 0.45
			strap.reattachProgress = 0
			self:_makeRope(id)
			self.lastCause = string.format("%s strap refitted", id)
			table.insert(self.pendingRefits, id)
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
	if not crate or not crate.Parent or not body or not body.Parent or crate.Anchored or body.Anchored then
		return
	end

	local bodyCF = body.CFrame
	local weight = math.max(self.crateMass * GRAVITY, 1)

	--[[
		The force the straps must resist: the load's inertial reaction to
		whatever the truck just did, plus its weight. Expressed in crate-weights
		so the thresholds in LabConfig stay readable.
	]]
	local pseudoWorld = (-self.chassisRig.accelWorld + GRAVITY_DOWN) * self.crateMass
	local demand = pseudoWorld / weight

	for _, id in LabConfig.StrapOrder do
		local strap = self.straps[id]
		if not strap then
			continue
		end

		if strap.broken then
			if strap.railAttachment and strap.crateAttachment then
				local gap = (strap.railAttachment.WorldPosition - strap.crateAttachment.WorldPosition).Magnitude
				strap.reattachable = gap <= LabConfig.StrapReattachMaxGap
			else
				strap.reattachable = false
			end
			strap.tension = 0
			self:_updateMarker(strap)
			continue
		end

		if not strap.railAttachment or not strap.crateAttachment then
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
				local maxStretch = math.max(0, LabConfig.StrapMaxStretch)
				strap.stretch = math.min(maxStretch, strap.stretch + LabConfig.StrapStretchPerShock)
				self.shockCooldown[id] = os.clock() + 0.5
			end

			if strap.health <= 0 then
				self:_breakStrap(id, "tension")
				continue
			end
		elseif tension < LabConfig.StrapTensionThreshold * 0.5 then
			-- Slow passive recovery, capped well below full so the crew is
			-- still the only way to get a strap properly secure again.
			strap.health = math.min(LabConfig.StrapMaxHealth * 0.7, strap.health + LabConfig.StrapRecoverRate * dt)
		end

		if strap.rope then
			strap.rope.Length = strap.restLength + strap.stretch
			local ratio = strap.health / LabConfig.StrapMaxHealth
			strap.rope.Color = if ratio > 0.6 then HEALTHY elseif ratio > 0.28 then STRESSED else CRITICAL
			strap.rope.Thickness = LabConfig.StrapRopeThickness + math.clamp(strap.tension, 0, 2) * 0.08
		end
	end

	self:_updateCondition(bodyCF)
end

function CargoLoad:_updateCondition(bodyCF: CFrame)
	local crate = self.crate

	local localPosition = bodyCF:PointToObjectSpace(crate.Position)
	local delta = localPosition - self.home
	self.localOffset = delta
	self.offset = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)

	local alignment = math.clamp(crate.CFrame.UpVector:Dot(bodyCF.UpVector), -1, 1)
	self.leanDeg = math.deg(math.acos(alignment))

	local brokenCount = 0
	local healthSum = 0
	for _, id in LabConfig.StrapOrder do
		local strap = self.straps[id]
		if not strap then
			continue
		end
		healthSum += strap.health
		if strap.broken then
			brokenCount += 1
		end
	end

	-- Is the load physically scraping the ground?
	local crateSizeY = crate.Size.Y
	if crateSizeY ~= self._dragRaySizeY then
		self._dragRaySizeY = crateSizeY
		self._dragRayDir = Vector3.new(0, -(crateSizeY * 0.5 + 0.8), 0)
	end
	local hit = workspace:Raycast(crate.Position, self._dragRayDir, self.dragRayParams)
	local vel = crate.AssemblyLinearVelocity
	local horizontalSpeed = math.sqrt(vel.X * vel.X + vel.Z * vel.Z)
	self.dragging = hit ~= nil and self.offset > LabConfig.ShiftedOffset and horizontalSpeed > 3

	--[[
		Real drag on the crate. The straps then pull the truck around, which is
		why a dragging load is a handling problem and not a status effect.

		A VectorForce rather than a per-step impulse, for the same reason the
		chassis uses one: the solver runs at 240Hz and an impulse only exists in
		the first substep. Drag that stutters makes the truck it is hauling
		sideways stutter with it.
	]]
	if self.dragForce and self.dragForce.Parent then
		if self.dragging then
			local resist = -crate.AssemblyLinearVelocity * LabConfig.DragForcePerStud
			self.dragForce.Force = Vector3.new(resist.X, 0, resist.Z)
		else
			self.dragForce.Force = Vector3.zero
		end
	end

	local separation = (crate.Position - bodyCF.Position).Magnitude
	self.lost = (brokenCount >= #LabConfig.StrapOrder and self.offset > LabConfig.LostOffset)
		or separation > LabConfig.LostSeparationStuds

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

--[[
	Drain the ids that snapped since the last call. Networking stays out of
	this module; LabSession toasts a refit instruction for each one.
]]
function CargoLoad:consumeStrapBreaks(): { string }
	local breaks = self.pendingBreaks
	if #breaks == 0 then
		return breaks
	end
	self.pendingBreaks = {}
	return breaks
end

-- Drain successful refits separately from breaks. Keeping these as edge
-- events prevents the 20 Hz simulation from counting the same repaired strap
-- on every frame after it becomes healthy again.
function CargoLoad:consumeStrapRefits(): { string }
	local refits = self.pendingRefits
	if #refits == 0 then
		return refits
	end
	self.pendingRefits = {}
	return refits
end

function CargoLoad:snapshotStraps(): { LabTypes.StrapSnapshot }
	local list = {}
	for index, id in LabConfig.StrapOrder do
		local strap = self.straps[id]
		if strap then
			list[index] = {
				id = id,
				health = math.floor(strap.health),
				tension = math.floor(strap.tension * 100) / 100,
				broken = strap.broken,
				stretch = math.floor(strap.stretch * 100) / 100,
				reattachable = strap.reattachable,
				workedBy = strap.workedBy,
			}
		else
			list[index] = {
				id = id,
				health = 0,
				tension = 0,
				broken = true,
				stretch = 0,
				reattachable = false,
				workedBy = nil,
			}
		end
	end
	return list
end

--[[
	Put the crate back on the bed and stop it moving, leaving strap health,
	wear and breakage exactly as they were. This is what a warp needs: the
	truck has jumped, so the load has to come with it, but the accumulated
	damage is the state being tuned and must survive.
]]
function CargoLoad:reseat()
	local body = self.chassisRig:getChassis()
	local crate = self.crate
	if not crate or not body then
		return
	end

	crate.AssemblyLinearVelocity = Vector3.zero
	crate.AssemblyAngularVelocity = Vector3.zero
	crate.CFrame = body.CFrame * CFrame.new(self.home)
	crate.AssemblyLinearVelocity = Vector3.zero
	crate.AssemblyAngularVelocity = Vector3.zero

	local pallet = self.pallet
	if pallet and pallet.Parent then
		local palletCenterY = self.home.Y - crate.Size.Y * 0.5 - 0.18
		pallet.AssemblyLinearVelocity = Vector3.zero
		pallet.AssemblyAngularVelocity = Vector3.zero
		pallet.CFrame = body.CFrame * CFrame.new(self.home.X, palletCenterY, self.home.Z)
		pallet.AssemblyLinearVelocity = Vector3.zero
		pallet.AssemblyAngularVelocity = Vector3.zero
	end
end

function CargoLoad:setFrozen(frozen: boolean)
	local crate = self.crate
	if not crate or not crate.Parent then
		return
	end
	crate.AssemblyLinearVelocity = Vector3.zero
	crate.AssemblyAngularVelocity = Vector3.zero
	-- A held force survives being parked, unlike the impulse this replaced.
	if self.dragForce and self.dragForce.Parent then
		self.dragForce.Force = Vector3.zero
	end
	self.dragging = false
	crate.Anchored = frozen

	local pallet = self.pallet
	if pallet and pallet.Parent then
		pallet.AssemblyLinearVelocity = Vector3.zero
		pallet.AssemblyAngularVelocity = Vector3.zero
	end
end

-- Same class of failure as missing wheels: a void fall can Destroy() the crate
-- while Staging still tries to reset straps against a nil Parent.
function CargoLoad:hasCompleteLoad(): boolean
	if not self.crate or not self.crate.Parent then
		return false
	end
	if not self.dragForce or not self.dragForce.Parent then
		return false
	end
	if not self.pallet or not self.pallet.Parent then
		return false
	end
	for _, id in LabConfig.StrapOrder do
		local strap = self.straps[id]
		if
			not strap
			or not strap.railAttachment
			or not strap.railAttachment.Parent
			or not strap.crateAttachment
			or not strap.crateAttachment.Parent
		then
			return false
		end
	end
	return true
end

function CargoLoad:reset()
	-- Reseat while frozen so the crate cannot free-fall between place and freeze.
	if not self:hasCompleteLoad() then
		error("CargoLoad:reset requires an intact crate/pallet/straps; rebuild the rig")
	end
	self:setFrozen(true)
	self:reseat()

	for _, id in LabConfig.StrapOrder do
		local strap = self.straps[id]
		strap.restLength = (strap.railAttachment.WorldPosition - strap.crateAttachment.WorldPosition).Magnitude
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
	table.clear(self.pendingBreaks)
	table.clear(self.pendingRefits)
end

function CargoLoad:destroy()
	if self.variantModel then
		self.variantModel:Destroy()
		self.variantModel = nil
	end
	for _, id in LabConfig.StrapOrder do
		local strap = self.straps[id]
		if strap and strap.marker then
			strap.marker:Destroy()
			strap.marker = nil
			strap.markerLabel = nil
		end
		local bracket = self.brackets[id]
		if bracket and bracket.part then
			bracket.part:Destroy()
		end
	end
	table.clear(self.brackets)
	if self.pallet then
		self.pallet:Destroy()
		self.pallet = nil
	end
	if self.crate then
		self.crate:Destroy()
		self.crate = nil
	end
end

return CargoLoad
