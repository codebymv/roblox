--!nonstrict

--[[
	A real, unanchored, collidable truck.

	This replaces the anchored PivotTo rig for the fun-test build. The model is a
	raycast vehicle: four suspension rays apply spring and damper force at the
	corners, and cornering comes from traction-limited lateral grip at each
	contact patch rather than from a yaw hack. That matters, because it means an
	unloaded inside wheel actually loses grip, a shifted load actually changes
	how the truck behaves, and the truck can genuinely roll over.

	Network ownership is pinned to the server. Server-applied impulses and client
	physics ownership cannot coexist: the client would overwrite our forces and
	every other player would see a different truck. The driver pays one round
	trip of input latency, which is the accepted trade.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LabConfig = require(Shared:WaitForChild("LabConfig"))
local RunCauses = require(Shared:WaitForChild("RunCauses"))

local WorldBuilder = require(script.Parent.WorldBuilder)

local GRAVITY = workspace.Gravity

local PhysicsChassis = {}
PhysicsChassis.__index = PhysicsChassis

export type DriveInput = {
	throttle: number,
	steering: number,
	braking: boolean,
}

local WHEEL_ORDER = { "FL", "FR", "RL", "RR" }

-- Suspension ray direction; rebuilt only when LiveTuning changes rest length.
local suspensionRayDir = Vector3.new(0, -LabConfig.SuspensionRestLength, 0)
local suspensionRayRest = LabConfig.SuspensionRestLength

local function weldTo(primary: BasePart, part: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = primary
	weld.Part1 = part
	weld.Parent = primary
end

--[[
	Roblox cylinders spin around local X. Build a wheel frame with X = axle
	(lateral), Y = ground normal, Z = roll direction, then apply tread spin.
]]
local function safeUnit(vector: Vector3, fallback: Vector3): Vector3
	if vector.Magnitude < 1e-4 then
		return fallback
	end
	return vector.Unit
end

-- math.clamp errors when max < min. Computed grip/spring budgets can go
-- negative after a wreck/reset mass blip or a hostile LiveTuning edit.
local function safeClamp(value: number, minValue: number, maxValue: number): number
	if maxValue < minValue then
		return minValue
	end
	return math.clamp(value, minValue, maxValue)
end

local function clampSymmetric(value: number, budget: number): number
	local limit = math.max(0, budget)
	return math.clamp(value, -limit, limit)
end

function PhysicsChassis:_wheelCFrame(center: Vector3, axle: Vector3, forward: Vector3, spin: number): CFrame
	local xAxis = safeUnit(axle, Vector3.xAxis)
	local lookAxis = safeUnit(forward - xAxis * forward:Dot(xAxis), Vector3.zAxis)
	local yAxis = safeUnit(xAxis:Cross(lookAxis), Vector3.yAxis)
	-- CFrame.fromMatrix's third axis is BackVector, not LookVector. Passing the
	-- forward vector here produced a reflected basis that could flip visually.
	local cf = CFrame.fromMatrix(center, xAxis, yAxis, -lookAxis)
	if spin ~= 0 then
		cf *= CFrame.Angles(spin, 0, 0)
	end
	return cf
end

function PhysicsChassis:_mountWheelVisual(
	chassisCF: CFrame,
	offset: Vector3,
	steer: boolean,
	spin: number,
	suspensionTravel: number?
): CFrame
	local steerRotation = if steer then CFrame.Angles(0, self.steerAngle, 0) else CFrame.identity
	local mountCF = chassisCF * CFrame.new(offset) * steerRotation
	-- Distance from the mount to the wheel centre. The old expression always
	-- subtracted one full wheel radius and then subtracted airborne travel a
	-- second time, placing parked wheels about a stud too low and making them
	-- jump on the first live suspension ray.
	local staticDistance = LabConfig.SuspensionRestLength * (1 - LabConfig.SuspensionStaticCompression)
		- LabConfig.WheelRadius
	local travel = suspensionTravel or staticDistance
	local center = mountCF.Position - mountCF.UpVector * math.max(0, travel)
	return self:_wheelCFrame(center, mountCF.RightVector, mountCF.LookVector, spin)
end

function PhysicsChassis.new(route: WorldBuilder.LabRouteInfo)
	local self = setmetatable({
		route = route,
		steerAngle = 0,
		wheels = {},
		bodyPaintParts = {},
		suspensionHealth = { FL = 1, FR = 1, RL = 1, RR = 1 },
		steeringHealth = 1,
		integrity = LabConfig.MaxChassisIntegrity,
		lastVelocity = Vector3.zero,
		lateralAccel = 0,
		longitudinalAccel = 0,
		accelWorld = Vector3.zero,
		turnSeverity = 0,
		brakeForce = 0,
		invertedFor = 0,
		wrecked = false,
		lastImpact = 0,
		externalAccel = Vector3.zero,
		lastCause = "",
	}, PhysicsChassis)

	self:_build()
	return self
end

function PhysicsChassis:_build()
	local model = Instance.new("Model")
	model.Name = "LabTruck"
	model.Parent = self.route.root

	local function addDetail(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size
		part.Color = color
		part.Material = material
		part.Anchored = false
		part.CanCollide = false
		part.Massless = true
		part.Parent = model
		return part
	end

	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = LabConfig.ChassisSize
	chassis.CFrame = self.route.startCFrame
	chassis.Color = Color3.fromRGB(63, 70, 78)
	chassis.Material = Enum.Material.Metal
	chassis.Anchored = false
	chassis.CanCollide = true
	-- Friction is handled by the grip model, so the collision box itself should
	-- be slippery or it fights the tyres on every scrape.
	chassis.CustomPhysicalProperties = PhysicalProperties.new(LabConfig.ChassisDensity, 0.08, 0, 1, 1)
	chassis.Parent = model
	model.PrimaryPart = chassis

	local cab = Instance.new("Part")
	cab.Name = "Cab"
	cab.Size = LabConfig.CabSize
	cab.CFrame = chassis.CFrame * CFrame.new(LabConfig.CabOffset)
	cab.Color = Color3.fromRGB(170, 66, 48)
	cab.Material = Enum.Material.SmoothPlastic
	cab.Anchored = false
	cab.CanCollide = false
	cab.CustomPhysicalProperties = PhysicalProperties.new(LabConfig.CabDensity, 0.3, 0, 1, 1)
	cab.Parent = model
	weldTo(chassis, cab)
	table.insert(self.bodyPaintParts, cab)

	local windshield = Instance.new("Part")
	windshield.Name = "Windshield"
	windshield.Size = LabConfig.WindshieldSize
	windshield.CFrame = cab.CFrame
		* CFrame.new(LabConfig.WindshieldOffset)
		* CFrame.Angles(-math.rad(LabConfig.WindshieldRakeDeg), 0, 0)
	windshield.Color = Color3.fromRGB(95, 170, 205)
	windshield.Material = Enum.Material.Glass
	windshield.Transparency = 0.35
	windshield.Anchored = false
	windshield.CanCollide = false
	windshield.Massless = true
	windshield.Parent = model
	weldTo(chassis, windshield)

	local bedDeck = Instance.new("Part")
	bedDeck.Name = "BedDeck"
	bedDeck.Size = LabConfig.BedDeckSize
	bedDeck.CFrame = chassis.CFrame * CFrame.new(LabConfig.BedDeckOffset)
	bedDeck.Color = Color3.fromRGB(42, 46, 52)
	bedDeck.Material = Enum.Material.DiamondPlate
	bedDeck.Anchored = false
	bedDeck.CanCollide = false
	bedDeck.Massless = true
	bedDeck.Parent = model
	weldTo(chassis, bedDeck)

	local bumper = addDetail("Bumper", LabConfig.BumperSize, Color3.fromRGB(38, 42, 48), Enum.Material.Metal)
	bumper.CFrame = chassis.CFrame * CFrame.new(LabConfig.BumperOffset)
	weldTo(chassis, bumper)

	-- A readable front face matters at every crew handoff: players thrown onto
	-- the road should immediately know which way the truck is pointing.
	local frontBumper =
		addDetail("FrontBumper", Vector3.new(8.9, 0.55, 0.48), Color3.fromRGB(46, 50, 56), Enum.Material.Metal)
	frontBumper.CFrame = cab.CFrame * CFrame.new(0, -2.18, -3.12)
	weldTo(chassis, frontBumper)

	local grille = addDetail("Grille", Vector3.new(4.8, 1.5, 0.18), Color3.fromRGB(30, 34, 39), Enum.Material.Metal)
	grille.CFrame = cab.CFrame * CFrame.new(0, -1.05, -3.16)
	weldTo(chassis, grille)
	for barIndex = -2, 2 do
		local grilleBar =
			addDetail("GrilleBar", Vector3.new(0.12, 1.32, 0.12), Color3.fromRGB(132, 138, 145), Enum.Material.Metal)
		grilleBar.CFrame = cab.CFrame * CFrame.new(barIndex * 0.78, -1.05, -3.28)
		weldTo(chassis, grilleBar)
	end

	local roofVisor =
		addDetail("RoofVisor", Vector3.new(8.3, 0.18, 1.05), Color3.fromRGB(42, 46, 52), Enum.Material.Metal)
	roofVisor.CFrame = cab.CFrame * CFrame.new(0, 2.56, -2.45) * CFrame.Angles(math.rad(-10), 0, 0)
	weldTo(chassis, roofVisor)

	for lampIndex = -1, 1 do
		local marker =
			addDetail("RoofMarker", Vector3.new(0.34, 0.22, 0.28), Color3.fromRGB(255, 174, 48), Enum.Material.Neon)
		marker.CFrame = cab.CFrame * CFrame.new(lampIndex * 1.5, 2.62, -1.55)
		weldTo(chassis, marker)
	end

	for _, side in { -1, 1 } do
		local headlight = Instance.new("Part")
		headlight.Name = if side == -1 then "HeadlightL" else "HeadlightR"
		headlight.Size = Vector3.new(0.55, 0.75, 0.35)
		headlight.CFrame = cab.CFrame
			* CFrame.new(LabConfig.HeadlightOffset.X * side, LabConfig.HeadlightOffset.Y, LabConfig.HeadlightOffset.Z)
		headlight.Color = Color3.fromRGB(255, 244, 200)
		headlight.Material = Enum.Material.Neon
		headlight.Anchored = false
		headlight.CanCollide = false
		headlight.Massless = true
		headlight.Parent = model
		weldTo(chassis, headlight)

		local taillight = Instance.new("Part")
		taillight.Name = if side == -1 then "TaillightL" else "TaillightR"
		taillight.Size = Vector3.new(0.5, 0.65, 0.25)
		taillight.CFrame = chassis.CFrame
			* CFrame.new(LabConfig.TaillightOffset.X * side, LabConfig.TaillightOffset.Y, LabConfig.TaillightOffset.Z)
		taillight.Color = Color3.fromRGB(220, 45, 40)
		taillight.Material = Enum.Material.Neon
		taillight.Anchored = false
		taillight.CanCollide = false
		taillight.Massless = true
		taillight.Parent = model
		weldTo(chassis, taillight)

		local mirrorArm = addDetail(
			if side == -1 then "MirrorArmL" else "MirrorArmR",
			Vector3.new(0.18, 0.18, 0.85),
			Color3.fromRGB(48, 52, 58),
			Enum.Material.Metal
		)
		mirrorArm.CFrame = cab.CFrame
			* CFrame.new(LabConfig.MirrorArmOffset.X * side, LabConfig.MirrorArmOffset.Y, LabConfig.MirrorArmOffset.Z)
		weldTo(chassis, mirrorArm)

		local mirrorGlass = addDetail(
			if side == -1 then "MirrorL" else "MirrorR",
			Vector3.new(0.08, 0.55, 0.75),
			Color3.fromRGB(130, 145, 158),
			Enum.Material.Glass
		)
		mirrorGlass.CFrame = cab.CFrame
			* CFrame.new(
				LabConfig.MirrorArmOffset.X * side,
				LabConfig.MirrorArmOffset.Y + 0.05,
				LabConfig.MirrorArmOffset.Z
			)
			* CFrame.new(side * 0.45, 0, 0.35)
		mirrorGlass.Transparency = 0.25
		weldTo(chassis, mirrorGlass)

		local door = addDetail(
			if side == -1 then "DoorL" else "DoorR",
			Vector3.new(0.14, 2.75, 2.9),
			Color3.fromRGB(170, 66, 48),
			Enum.Material.SmoothPlastic
		)
		door.CFrame = cab.CFrame * CFrame.new(side * 4.23, -0.15, 0.2)
		weldTo(chassis, door)
		table.insert(self.bodyPaintParts, door)

		local handle = addDetail(
			if side == -1 then "DoorHandleL" else "DoorHandleR",
			Vector3.new(0.12, 0.14, 0.7),
			Color3.fromRGB(38, 42, 48),
			Enum.Material.Metal
		)
		handle.CFrame = cab.CFrame * CFrame.new(side * 4.32, 0.45, -0.3)
		weldTo(chassis, handle)

		local stack = addDetail(
			if side == -1 then "ExhaustStackL" else "ExhaustStackR",
			Vector3.new(3.7, 0.34, 0.34),
			Color3.fromRGB(88, 92, 98),
			Enum.Material.Metal
		)
		stack.Shape = Enum.PartType.Cylinder
		stack.CFrame = chassis.CFrame * CFrame.new(side * 3.35, 4.65, -1.35) * CFrame.Angles(0, 0, math.rad(90))
		weldTo(chassis, stack)
	end

	local rearBumper =
		addDetail("RearBumper", Vector3.new(8.8, 0.62, 0.5), Color3.fromRGB(42, 46, 52), Enum.Material.Metal)
	rearBumper.CFrame = chassis.CFrame * CFrame.new(0, 0.15, 8.1)
	weldTo(chassis, rearBumper)

	for _, x in { -2.4, 2.4 } do
		local mudFlap =
			addDetail("RearMudFlap", Vector3.new(1.75, 1.55, 0.16), Color3.fromRGB(24, 25, 28), Enum.Material.Rubber)
		mudFlap.CFrame = chassis.CFrame * CFrame.new(x, -0.75, 7.65)
		weldTo(chassis, mudFlap)
	end

	for _, id in WHEEL_ORDER do
		local offset = LabConfig.WheelOffsets[id]
		local side = if offset.X < 0 then -1 else 1
		local fender = addDetail(
			"Fender" .. id,
			Vector3.new(0.32, 1.65, 2.35),
			Color3.fromRGB(170, 66, 48),
			Enum.Material.SmoothPlastic
		)
		fender.CFrame = chassis.CFrame * CFrame.new(offset + Vector3.new(side * 0.22, 1.05, 0))
		weldTo(chassis, fender)
		table.insert(self.bodyPaintParts, fender)
	end

	-- Side rails double as the strap anchor line and the running boards the
	-- crew stands on.
	for _, side in { -1, 1 } do
		local rail = Instance.new("Part")
		rail.Name = "Rail"
		rail.Size = Vector3.new(0.6, 1.1, 11)
		rail.CFrame = chassis.CFrame * CFrame.new(side * 4.35, LabConfig.RailHeight, 3)
		rail.Color = Color3.fromRGB(40, 44, 50)
		rail.Material = Enum.Material.Metal
		rail.Anchored = false
		rail.CanCollide = false
		rail.Massless = true
		rail.Parent = model
		weldTo(chassis, rail)

		local board = Instance.new("Part")
		board.Name = "RunningBoard"
		board.Size = Vector3.new(2.6, 0.4, 11)
		board.CFrame = chassis.CFrame * CFrame.new(side * 5.9, 1.2, 3)
		board.Color = Color3.fromRGB(52, 56, 62)
		board.Material = Enum.Material.DiamondPlate
		board.Anchored = false
		board.CanCollide = false
		board.Massless = true
		board.Parent = model
		weldTo(chassis, board)
	end

	-- Strap anchor attachments, referenced by CargoLoad.
	local anchors = {}
	for _, id in LabConfig.StrapOrder do
		local attachment = Instance.new("Attachment")
		attachment.Name = "Strap_" .. id
		attachment.Position = LabConfig.StrapRailLocal[id]
		attachment.Parent = chassis
		anchors[id] = attachment

		local ratchet =
			addDetail("Ratchet_" .. id, LabConfig.StrapRatchetSize, Color3.fromRGB(200, 175, 60), Enum.Material.Metal)
		ratchet.CFrame = chassis.CFrame * CFrame.new(LabConfig.StrapRailLocal[id]) * CFrame.Angles(0, math.rad(90), 0)
		weldTo(chassis, ratchet)
	end

	--[[
		Wheels are anchored authoritative suspension targets repositioned from the
		raycast result each frame. Clients render locally smoothed copies so these
		server updates never fight chassis interpolation. Making them real physics
		wheels would add constraint tuning without improving the handling model.
	]]
	-- _createWheel reads these fields, so publish the freshly built assembly
	-- before asking the wheel factory to attach its targets.
	self.model = model
	self.chassis = chassis
	self.cab = cab
	self.anchors = anchors
	for _, id in WHEEL_ORDER do
		self:_createWheel(id)
	end

	-- Crosswind and other whole-body pushes. At the centre of mass, because a
	-- gust that also produced yaw torque would be a second, hidden steering
	-- input rather than the environmental pressure it is meant to be.
	local bodyAttachment = Instance.new("Attachment")
	bodyAttachment.Name = "Force_Body"
	bodyAttachment.Parent = chassis

	local bodyForce = Instance.new("VectorForce")
	bodyForce.Name = "BodyForce"
	bodyForce.Attachment0 = bodyAttachment
	bodyForce.RelativeTo = Enum.ActuatorRelativeTo.World
	bodyForce.ApplyAtCenterOfMass = true
	bodyForce.Force = Vector3.zero
	bodyForce.Parent = chassis
	self.bodyForce = bodyForce

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true
	rayParams.FilterDescendantsInstances = { model }

	self.rayParams = rayParams

	self:claimOwnership()
end

function PhysicsChassis:_createWheel(id: string)
	local model = self.model
	local chassis = self.chassis
	if not model or not chassis then
		return
	end

	local existing = self.wheels[id]
	if existing then
		-- Force actuators live on the chassis rather than under the disposable
		-- wheel target. Destroy them explicitly or a repaired wheel leaves an
		-- invisible copy of its last force pushing forever.
		if existing.vectorForce and existing.vectorForce.Parent then
			existing.vectorForce:Destroy()
		end
		if existing.forceAttachment and existing.forceAttachment.Parent then
			existing.forceAttachment:Destroy()
		end
		if existing.part and existing.part.Parent then
			existing.part:Destroy()
		end
		self.wheels[id] = nil
	end
	local stale = model:FindFirstChild("Wheel" .. id)
	if stale then
		stale:Destroy()
	end

	local offset = LabConfig.WheelOffsets[id]
	local wheel = Instance.new("Part")
	wheel.Name = "Wheel" .. id
	wheel.Shape = Enum.PartType.Cylinder
	wheel.Size = Vector3.new(LabConfig.WheelWidth, LabConfig.WheelRadius * 2, LabConfig.WheelRadius * 2)
	wheel.Color = Color3.fromRGB(22, 22, 24)
	wheel.Material = Enum.Material.Rubber
	wheel.Anchored = true
	wheel.CanCollide = false
	wheel.CanQuery = false
	-- Client WheelPresentation draws the visible tyre; keep the server target
	-- invisible so a halted step never shows orphaned rubber floating mid-air.
	wheel.Transparency = 1
	wheel.CFrame = self:_mountWheelVisual(chassis.CFrame, offset, id == "FL" or id == "FR", 0)
	wheel.Parent = model

	local hub = Instance.new("Part")
	hub.Name = "Hub"
	hub.Shape = Enum.PartType.Cylinder
	hub.Size = Vector3.new(LabConfig.WheelWidth + 0.08, LabConfig.HubRadius * 2, LabConfig.HubRadius * 2)
	hub.Color = Color3.fromRGB(175, 180, 186)
	hub.Material = Enum.Material.Metal
	hub.Anchored = true
	hub.CanCollide = false
	hub.CanQuery = false
	hub.Massless = true
	hub.Transparency = 1
	hub.CFrame = wheel.CFrame
	hub.Parent = wheel

	--[[
		Suspension, grip and drive are applied through a persistent VectorForce
		rather than an impulse per step.

		Roblox's solver runs at 240Hz. ApplyImpulseAtPosition delivers the whole
		frame's momentum change in a single substep and leaves the other three
		with no suspension force at all -- a spring that only exists a quarter of
		the time, which is what chugging is. A VectorForce is integrated by every
		substep.

		The two are momentum-identical: an impulse of F*dt equals a force of F
		held for dt. Every grip and spring number in LabConfig carries over
		unchanged; only the distribution inside the frame moves.
	]]
	local forceAttachment = Instance.new("Attachment")
	forceAttachment.Name = "Force_" .. id
	forceAttachment.Position = offset
	forceAttachment.Parent = chassis

	local vectorForce = Instance.new("VectorForce")
	vectorForce.Name = "WheelForce_" .. id
	vectorForce.Attachment0 = forceAttachment
	-- World-relative: the contact normal and the flattened contact-patch axes
	-- these forces are built from are world vectors already.
	vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	-- Applied at the wheel mount, not the centre of mass, so it still produces
	-- the roll and pitch torque that makes weight transfer real.
	vectorForce.ApplyAtCenterOfMass = false
	vectorForce.Force = Vector3.zero
	vectorForce.Parent = chassis

	self.wheels[id] = {
		id = id,
		offset = offset,
		part = wheel,
		hub = hub,
		forceAttachment = forceAttachment,
		vectorForce = vectorForce,
		steer = id == "FL" or id == "FR",
		drive = id == "RL" or id == "RR",
		grounded = false,
		compression = 0,
		normalForce = 0,
		surface = "Road",
		spin = 0,
	}
	self.suspensionHealth[id] = self.suspensionHealth[id] or 1
end

-- Recreate any suspension targets Roblox stripped after a void fall.
function PhysicsChassis:ensureWheelSet(): boolean
	local repaired = false
	for _, id in WHEEL_ORDER do
		local wheel = self.wheels[id]
		if not wheel or not wheel.part or not wheel.part.Parent or not wheel.hub or not wheel.hub.Parent then
			self:_createWheel(id)
			repaired = true
		end
	end
	if repaired then
		self:_snapWheelVisuals()
	end
	return repaired
end

--[[
	Sitting a player in a Seat hands that player network ownership of the whole
	assembly, which would silently disable every force this module applies. The
	truck therefore has to take ownership back after anyone sits down, and the
	run loop re-asserts it on a timer in case a seat change is missed.
]]
--[[
	Returns true when ownership actually changed. Callers use that to start the
	SeatWeld settle grace so soft reseat does not immediately fight the reclaim.
]]
function PhysicsChassis:claimOwnership(): boolean
	local chassis = self.chassis
	-- Anchored parts still accept SetNetworkOwner on the server; Staging ticks
	-- used to no-op while frozen and left client ownership stuck after GO.
	if not chassis or not chassis.Parent then
		return false
	end
	local mutated = false
	pcall(function()
		local auto = chassis:GetNetworkOwnershipAuto()
		local owner = chassis:GetNetworkOwner()
		if auto or owner ~= nil then
			-- Pin server ownership so Sit cannot keep flipping Auto back mid-run.
			chassis:SetNetworkOwner(nil)
			mutated = true
		end
	end)
	return mutated
end

function PhysicsChassis:setIgnoreList(instances: { Instance })
	local list = { self.model }
	for _, instance in instances do
		table.insert(list, instance)
	end
	self.rayParams.FilterDescendantsInstances = list
end

function PhysicsChassis:getAnchor(id: string): Attachment
	return self.anchors[id]
end

function PhysicsChassis:getChassis(): BasePart
	return self.chassis
end

function PhysicsChassis:getModel(): Model
	return self.model
end

--[[
	Suspension stiffness is derived from the mass actually riding on it, so a
	heavier load automatically gets a stiffer, lower-riding truck.

	Stiffness is expressed per unit of *fractional* compression, because that is
	what the step loop measures. Solving it so that force equals the static
	wheel load exactly at SuspensionStaticCompression is what puts the truck at
	its intended ride height instead of sitting on the bump stops.
]]
function PhysicsChassis:_springRate(extraMass: number): (number, number)
	local mass = self.chassis.AssemblyMass + extraMass
	local perWheel = mass / 4
	local stiffness = (perWheel * GRAVITY) / math.max(LabConfig.SuspensionStaticCompression, 0.05)

	-- Damping is applied against real velocity, so convert the fractional rate
	-- into a per-stud rate before solving for the damping coefficient.
	local perStud = stiffness / LabConfig.SuspensionRestLength
	local damping = 2 * LabConfig.SuspensionDampingRatio * math.sqrt(math.max(perStud * perWheel, 0.001))
	return stiffness, damping
end

--[[
	Zero every persistent force.

	An impulse that is not applied simply does not happen. A VectorForce that is
	not updated keeps pushing, so anything that stops or relocates the truck has
	to clear them or the next unfrozen frame starts with whatever the truck was
	doing when it was parked.
]]
function PhysicsChassis:_clearForces()
	for _, id in WHEEL_ORDER do
		local wheel = self.wheels[id]
		if wheel and wheel.vectorForce and wheel.vectorForce.Parent then
			wheel.vectorForce.Force = Vector3.zero
		end
	end
	if self.bodyForce and self.bodyForce.Parent then
		self.bodyForce.Force = Vector3.zero
	end
end

function PhysicsChassis:applyExternalAccel(accel: Vector3)
	self.externalAccel = accel
end

function PhysicsChassis:damageSuspension(wheelId: string, amount: number)
	local current = self.suspensionHealth[wheelId] or 1
	self.suspensionHealth[wheelId] = safeClamp(current - amount, 0.15, 1)
end

function PhysicsChassis:degradeSteering(amount: number)
	-- Floor raised so "vague steering" means sluggish, not hair-trigger snap.
	self.steeringHealth = safeClamp(self.steeringHealth - amount, 0.45, 1)
end

function PhysicsChassis:repairSuspension(wheelId: string, amount: number)
	local current = self.suspensionHealth[wheelId] or 1
	self.suspensionHealth[wheelId] = safeClamp(current + amount, 0.15, 1)
end

-- `cause` is a RunCauses identifier, not a sentence. It reaches both the
-- analytics bucket and the player-facing wreck explanation, so a prose string
-- passed here would silently drop out of one and mislabel the other.
function PhysicsChassis:applyImpactDamage(amount: number, cause: RunCauses.WreckCause)
	if amount <= 0 then
		return
	end
	local maxIntegrity = math.max(0, LabConfig.MaxChassisIntegrity)
	self.integrity = safeClamp(self.integrity - amount, 0, maxIntegrity)
	self.lastImpact = os.clock()
	self.lastCause = cause
	if self.integrity <= LabConfig.MinChassisIntegrity then
		self.wrecked = true
	end
end

function PhysicsChassis:step(dt: number, input: DriveInput, extraMass: number)
	local chassis = self.chassis
	if not chassis or not chassis.Parent or chassis.Anchored then
		self:_clearForces()
		return
	end

	local cf = chassis.CFrame
	local velocity = chassis.AssemblyLinearVelocity
	-- AssemblyMass can blip around freezes/reseats; never feed clamp a negative budget.
	local mass = math.max(1, chassis.AssemblyMass + math.max(0, extraMass or 0))

	--[[
		Measured acceleration. Everything downstream (strap tension, the debug
		overlay, throw checks) reads this rather than guessing from inputs.

		A raw per-frame velocity difference is extremely noisy in Roblox, since
		every contact impulse lands on a single frame. The smoothed value is
		what the game reads; the raw one is kept only for impact detection,
		where the spike is the signal.
	]]
	local rawAccel = (velocity - self.lastVelocity) / math.max(dt, 1 / 240)
	self.lastVelocity = velocity
	local blend = safeClamp(dt * 18, 0, 1)
	self.accelWorld = self.accelWorld:Lerp(rawAccel, blend)
	self.lateralAccel = self.accelWorld:Dot(cf.RightVector)
	self.longitudinalAccel = self.accelWorld:Dot(cf.LookVector)

	-- A hard hit shows up as a velocity change no drivetrain could produce.
	-- Braking on grass/shoulder legitimately spikes decel; widen the budget so
	-- a road-edge bump does not one-shot the chassis integrity meter.
	local budget = (LabConfig.EngineAccel + LabConfig.BrakeAccel + GRAVITY) * 1.5
	if input.braking then
		budget += LabConfig.BrakeAccel * 2
	end
	budget += LabConfig.Surfaces.Shoulder.resistance * 3

	local unexplained = rawAccel.Magnitude - budget
	if unexplained > LabConfig.ImpactThreshold and os.clock() - self.lastImpact > 0.35 then
		local damage = math.min(unexplained * dt * LabConfig.ImpactDamageScale, LabConfig.ImpactDamageCap)
		self:applyImpactDamage(damage, RunCauses.Wreck.Impact)
	end

	local forwardSpeed = velocity:Dot(cf.LookVector)
	local minSteerFactor = safeClamp(LabConfig.MinSteerFactor, 0, 1)
	local speedFactor =
		safeClamp(1 - math.abs(forwardSpeed) / math.max(LabConfig.SteerSpeedFalloff, 1), minSteerFactor, 1)
	local maxSteer = math.rad(LabConfig.MaxSteerAngleDeg) * speedFactor * math.max(0, self.steeringHealth)

	-- Pitch from the look vector: positive when the nose points downhill.
	-- A small deadzone ignores flat-road noise so the soft cap never fights
	-- the throttle on the warm-up straight.
	local downhillGrade = math.max(0, -cf.LookVector.Y)
	if downhillGrade < 0.04 then
		downhillGrade = 0
	end

	--[[
		Negated, and it has to be.

		The client sends steering as right minus left, so pressing D is +1. A
		rotation about Y is counter-clockwise seen from above, so a positive
		angle points the front wheels left: CFrame.Angles(0, math.rad(90), 0)
		leaves LookVector at (-1, 0, 0), which is -X, and +X is the truck's
		right. Feeding the input straight in steered the truck the wrong way.
	]]
	local targetSteer = -safeClamp(input.steering, -1, 1) * maxSteer
	-- Degraded steering slows how fast the wheels turn, not just how far they
	-- can turn. Without this, a worn truck still snaps to max angle in one
	-- frame and spins from a tap of A/D.
	local steerRateScale = 0.4 + 0.6 * math.max(0, self.steeringHealth)
	local steerStep = math.max(0, math.rad(LabConfig.SteerRateDegPerSec) * dt * steerRateScale)
	if steerStep > 0 then
		self.steerAngle += clampSymmetric(targetSteer - self.steerAngle, steerStep)
	else
		self.steerAngle = targetSteer
	end
	self.turnSeverity = math.abs(self.steerAngle) / math.max(math.rad(LabConfig.MaxSteerAngleDeg), 0.001)

	local stiffness, damping = self:_springRate(extraMass)
	-- This is a per-wheel force. Capping against the whole truck mass made the
	-- limiter four times looser than its name and comment promised, so a sharp
	-- slab edge could turn damping force into a launch impulse.
	local maxSpringForce = math.max(0, (mass / 4) * GRAVITY * LabConfig.SuspensionMaxForceScale)
	local groundedCount = 0
	local restLength = LabConfig.SuspensionRestLength
	if restLength ~= suspensionRayRest then
		suspensionRayRest = restLength
		suspensionRayDir = Vector3.new(0, -restLength, 0)
	end

	for _, id in WHEEL_ORDER do
		local wheel = self.wheels[id]
		if not wheel or not wheel.part or not wheel.part.Parent then
			continue
		end
		local mountWorld = cf * wheel.offset
		local result = workspace:Raycast(mountWorld, suspensionRayDir, self.rayParams)

		if result then
			groundedCount += 1
			local distance = (result.Position - mountWorld).Magnitude
			local rest = math.max(LabConfig.SuspensionRestLength, 0.01)
			local compression = safeClamp((rest - distance) / rest, 0, 1)
			local health = self.suspensionHealth[id] or 1
			local normal = result.Normal
			local pointVelocity = chassis:GetVelocityAtPosition(mountWorld)
			local springVelocity = pointVelocity:Dot(normal)

			local force = safeClamp(stiffness * compression * health - damping * springVelocity, 0, maxSpringForce)
			-- Accumulated rather than applied. Suspension, lateral grip and
			-- drive all act at the same contact patch, so they become one
			-- VectorForce at the end of this branch.
			local wheelForce = normal * force

			local surfaceName = result.Instance:GetAttribute("LabSurface")
			local surface = LabConfig.surface(if typeof(surfaceName) == "string" then surfaceName else nil)

			wheel.grounded = true
			wheel.compression = compression
			wheel.normalForce = force
			wheel.surface = if typeof(surfaceName) == "string" then surfaceName else "Road"

			-- Contact-patch axes, flattened onto the surface the wheel is on.
			local steerRotation = if wheel.steer then CFrame.Angles(0, self.steerAngle, 0) else CFrame.identity
			local wheelLook = (cf * steerRotation).LookVector
			local wheelForward = safeUnit(wheelLook - normal * wheelLook:Dot(normal), cf.LookVector)
			local wheelRight = safeUnit(wheelForward:Cross(normal), cf.RightVector)

			--[[
				Lateral grip, limited by this wheel's own normal load. This one
				line is why the truck behaves: lift a wheel on a corner and its
				grip budget collapses, so the truck starts to slide exactly when
				a real one would.
			]]
			local grip = if wheel.steer then LabConfig.GripFront else LabConfig.GripRear
			local lateralVelocity = pointVelocity:Dot(wheelRight)
			local surfaceGrip = math.max(0, surface.grip)
			local desiredLateral = -lateralVelocity * grip * (mass / 4) * surfaceGrip
			local gripBudget = math.max(0, force * LabConfig.GripLimitPerWheel * surfaceGrip)
			local lateralForce = clampSymmetric(desiredLateral, gripBudget)
			wheelForce += wheelRight * lateralForce

			local longitudinal = 0
			local along = pointVelocity:Dot(wheelForward)
			if input.braking then
				longitudinal = -math.sign(along)
					* math.min(math.abs(along) / math.max(dt, 1 / 240), LabConfig.BrakeAccel)
					* (mass / 4)
				longitudinal = clampSymmetric(longitudinal, gripBudget)
			elseif wheel.drive and math.abs(input.throttle) > 0.05 then
				local accelTarget = if input.throttle > 0 then LabConfig.EngineAccel else -LabConfig.ReverseAccel
				local limit = if input.throttle > 0 then LabConfig.MaxForwardSpeed else -LabConfig.MaxReverseSpeed
				local overspeed = if input.throttle > 0 then forwardSpeed > limit else forwardSpeed < limit
				if not overspeed then
					longitudinal = clampSymmetric(accelTarget * math.abs(input.throttle) * (mass / 2), gripBudget)
				end
			else
				-- Deadzone, or a parked truck oscillates around zero forever.
				if math.abs(along) > LabConfig.SpeedDeadzone then
					longitudinal = -math.sign(along) * LabConfig.CoastDecel * (mass / 4)
				end
			end

			--[[
				Downhill soft cap. Space still wins above; this runs under
				throttle and coast so gravity cannot freely push past the
				steering sweet spot. Strength scales with how far over the
				cap you are and how steep the grade is.
			]]
			if not input.braking and wheel.drive and downhillGrade > 0 and forwardSpeed > LabConfig.DownhillSoftCap then
				local over = (forwardSpeed - LabConfig.DownhillSoftCap) / math.max(LabConfig.DownhillSoftCap, 1)
				local strength = LabConfig.DownhillBrakeAccel * safeClamp(over, 0, 1.5) * (0.5 + downhillGrade)
				longitudinal -= strength * (mass / 2)
				longitudinal = clampSymmetric(longitudinal, gripBudget)
			end

			-- Rolling resistance from the surface the wheel is actually on.
			if surface.resistance > 0 and math.abs(along) > LabConfig.SpeedDeadzone then
				longitudinal -= math.sign(along) * surface.resistance * (mass / 4)
			end

			wheelForce += wheelForward * longitudinal
			wheel.vectorForce.Force = wheelForce
			self.brakeForce = if input.braking then math.abs(longitudinal) / math.max(mass, 1) else 0

			wheel.spin += (along / LabConfig.WheelRadius) * dt

			local center = result.Position + normal * LabConfig.WheelRadius
			local wheelCF = self:_wheelCFrame(center, wheelRight, wheelForward, wheel.spin)
			wheel.part.CFrame = wheelCF
			if wheel.hub and wheel.hub.Parent then
				wheel.hub.CFrame = wheelCF
			end
		else
			wheel.grounded = false
			wheel.compression = 0
			wheel.normalForce = 0
			wheel.surface = "Air"
			-- An airborne wheel pushes on nothing. A persistent force has to be
			-- cleared explicitly, where an impulse simply was not applied.
			wheel.vectorForce.Force = Vector3.zero
			local wheelCF = self:_mountWheelVisual(
				cf,
				wheel.offset,
				wheel.steer,
				wheel.spin,
				LabConfig.SuspensionRestLength - LabConfig.WheelRadius
			)
			wheel.part.CFrame = wheelCF
			if wheel.hub and wheel.hub.Parent then
				wheel.hub.CFrame = wheelCF
			end
		end
	end

	if self.bodyForce then
		self.bodyForce.Force = if self.externalAccel.Magnitude > 0.01 then self.externalAccel * mass else Vector3.zero
	end

	-- Raycast vehicles accumulate a slow yaw drift with no real tyre contact
	-- patch to resist it. Damp only yaw so roll and pitch stay expressive.
	local angular = chassis.AssemblyAngularVelocity
	local damped = angular.Y * (1 - safeClamp(LabConfig.YawDamping * dt, 0, 1))
	local maxSpin = math.max(0, LabConfig.MaxAngularSpeed)
	if angular.Magnitude > maxSpin and maxSpin > 0 then
		angular = angular.Unit * maxSpin
		damped = clampSymmetric(damped, maxSpin)
	end
	chassis.AssemblyAngularVelocity = Vector3.new(angular.X, damped, angular.Z)

	if groundedCount == 0 then
		self.brakeForce = 0
	end

	-- Rollover: not a threshold on a meter, just the truck being upside down
	-- for long enough that nobody is getting it back.
	if cf.UpVector:Dot(Vector3.yAxis) < LabConfig.RolloverUpDot then
		self.invertedFor += dt
		if self.invertedFor > LabConfig.RolloverSeconds and not self.wrecked then
			self.wrecked = true
			self.lastCause = RunCauses.Wreck.Rolled
		end
	else
		self.invertedFor = 0
	end

	if chassis.Position.Y < LabConfig.VoidY then
		self.wrecked = true
		self.lastCause = RunCauses.Wreck.Fell
		-- Freeze and yank back immediately. Leaving the assembly in the void for
		-- the Result beat lets Roblox destroy unanchored body parts (and any
		-- wheel targets that followed them) before Staging can rebuild — that is
		-- the wheel-less second-run truck.
		self:setFrozen(true)
		self:teleport(self.route.startCFrame)
		self:ensureWheelSet()
	end
end

function PhysicsChassis:getSpeed(): number
	local chassis = self.chassis
	if not chassis or not chassis.Parent then
		return 0
	end
	return chassis.AssemblyLinearVelocity.Magnitude
end

--[[
	Authoritative motion for client camera / wheel presentation. Numbers only so
	LabMotion can stay on an UnreliableRemoteEvent at ~20 Hz.
]]
function PhysicsChassis:getMotionSample(): { [string]: number }?
	local chassis = self.chassis
	if not chassis or not chassis.Parent then
		return nil
	end
	local pos = chassis.Position
	local vel = chassis.AssemblyLinearVelocity
	local look = chassis.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	local yaw = 0
	if flat.Magnitude > 0.01 then
		flat = flat.Unit
		yaw = math.atan2(flat.X, flat.Z)
	end
	local fl = self.wheels.FL
	local fr = self.wheels.FR
	local rl = self.wheels.RL
	local rr = self.wheels.RR
	return {
		t = Workspace:GetServerTimeNow(),
		px = pos.X,
		py = pos.Y,
		pz = pos.Z,
		vx = vel.X,
		vy = vel.Y,
		vz = vel.Z,
		yaw = yaw,
		steer = self.steerAngle,
		speed = vel.Magnitude,
		cFL = if fl then fl.compression else 0,
		cFR = if fr then fr.compression else 0,
		cRL = if rl then rl.compression else 0,
		cRR = if rr then rr.compression else 0,
	}
end

function PhysicsChassis:getForwardSpeed(): number
	local chassis = self.chassis
	if not chassis or not chassis.Parent then
		return 0
	end
	return chassis.AssemblyLinearVelocity:Dot(chassis.CFrame.LookVector)
end

function PhysicsChassis:getRouteProgress(): number
	local chassis = self.chassis
	if not chassis or not chassis.Parent then
		return 0
	end
	return WorldBuilder.labProgress(self.route, chassis.Position)
end

function PhysicsChassis:getRollDegrees(): number
	local chassis = self.chassis
	if not chassis or not chassis.Parent then
		return 0
	end
	local cf = chassis.CFrame
	return math.deg(math.asin(safeClamp(cf.RightVector.Y, -1, 1)))
end

function PhysicsChassis:getPitchDegrees(): number
	local chassis = self.chassis
	if not chassis or not chassis.Parent then
		return 0
	end
	local cf = chassis.CFrame
	return math.deg(math.asin(safeClamp(cf.LookVector.Y, -1, 1)))
end

function PhysicsChassis:isWrecked(): boolean
	return self.wrecked
end

function PhysicsChassis:getIntegrity(): number
	return self.integrity
end

function PhysicsChassis:getWheels()
	return self.wheels
end

-- The raycast targets are also the authority for suspension, grip and drive
-- force. Roblox may remove them if a wreck carries them below the destruction
-- height before Result freezes the chassis. A truck with even one missing
-- target is not safe to reuse for another run.
function PhysicsChassis:hasCompleteWheelSet(): boolean
	for _, id in WHEEL_ORDER do
		local wheel = self.wheels[id]
		if
			not wheel
			or not wheel.part
			or not wheel.part.Parent
			or not wheel.hub
			or not wheel.hub.Parent
			or not wheel.forceAttachment
			or not wheel.forceAttachment.Parent
			or not wheel.vectorForce
			or not wheel.vectorForce.Parent
		then
			return false
		end
	end
	return true
end

function PhysicsChassis:_snapWheelVisuals()
	local chassis = self.chassis
	if not chassis or not chassis.Parent then
		return
	end
	local cf = chassis.CFrame
	for _, id in WHEEL_ORDER do
		local wheel = self.wheels[id]
		if wheel and wheel.part and wheel.part.Parent then
			local wheelCF = self:_mountWheelVisual(cf, wheel.offset, wheel.steer, wheel.spin)
			wheel.part.CFrame = wheelCF
			if wheel.hub and wheel.hub.Parent then
				wheel.hub.CFrame = wheelCF
			end
		end
	end
end

function PhysicsChassis:setFrozen(frozen: boolean)
	local chassis = self.chassis
	if not chassis or not chassis.Parent then
		return
	end
	chassis.AssemblyLinearVelocity = Vector3.zero
	chassis.AssemblyAngularVelocity = Vector3.zero
	self:_clearForces()
	chassis.Anchored = frozen
	if frozen then
		-- Clear measured accel so StrapperStations cannot throw crew during Result
		-- using the last cornering spike from the wreck frame.
		self.accelWorld = Vector3.zero
		self.lateralAccel = 0
		self.longitudinalAccel = 0
		self.brakeForce = 0
		self:_snapWheelVisuals()
	end
end

function PhysicsChassis:setPaintColor(color: Color3)
	for _, part in self.bodyPaintParts do
		if part and part.Parent then
			part.Color = color
		end
	end
end

--[[
	Put the truck somewhere, upright and stationary, without touching damage or
	wear. Zeroing velocity on both sides of the pivot is deliberate: the solver
	will otherwise carry the pre-teleport velocity through the move and fling
	the assembly.
]]
function PhysicsChassis:teleport(cframe: CFrame)
	local chassis = self.chassis
	chassis.AssemblyLinearVelocity = Vector3.zero
	chassis.AssemblyAngularVelocity = Vector3.zero
	self.model:PivotTo(cframe)
	chassis.AssemblyLinearVelocity = Vector3.zero
	chassis.AssemblyAngularVelocity = Vector3.zero

	-- Otherwise the next frame measures the teleport itself as an enormous
	-- acceleration and books it as an impact.
	self.lastVelocity = Vector3.zero
	self.accelWorld = Vector3.zero
	self.lateralAccel = 0
	self.longitudinalAccel = 0
	self.invertedFor = 0
	self.lastImpact = os.clock()
end

function PhysicsChassis:reset()
	-- Stay frozen across the teleport. Unfreezing a wreck mid-void for even one
	-- solver step is what flings hubs, seats, and the load across the sky.
	self:setFrozen(true)
	self:ensureWheelSet()
	self:teleport(self.route.startCFrame)

	self:_clearForces()
	self.steerAngle = 0
	self.integrity = LabConfig.MaxChassisIntegrity
	self.wrecked = false
	self.invertedFor = 0
	self.lastVelocity = Vector3.zero
	self.accelWorld = Vector3.zero
	self.lateralAccel = 0
	self.longitudinalAccel = 0
	self.turnSeverity = 0
	self.brakeForce = 0
	self.steeringHealth = 1
	self.externalAccel = Vector3.zero
	self.lastCause = ""
	for _, id in WHEEL_ORDER do
		self.suspensionHealth[id] = 1
		local wheel = self.wheels[id]
		if wheel then
			wheel.spin = 0
			wheel.grounded = false
			wheel.compression = 0
			wheel.normalForce = 0
			wheel.surface = "Road"
		end
	end
	self:_snapWheelVisuals()
end

function PhysicsChassis:destroy()
	if self.model then
		self.model:Destroy()
		self.model = nil
	end
	table.clear(self.bodyPaintParts)
end

PhysicsChassis.WheelOrder = WHEEL_ORDER
PhysicsChassis.Heartbeat = RunService.Heartbeat

return PhysicsChassis
