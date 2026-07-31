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

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LabConfig = require(Shared:WaitForChild("LabConfig"))

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

local function weldTo(primary: BasePart, part: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = primary
	weld.Part1 = part
	weld.Parent = primary
end

function PhysicsChassis.new(route: WorldBuilder.LabRouteInfo)
	local self = setmetatable({
		route = route,
		steerAngle = 0,
		wheels = {},
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
	cab.Material = Enum.Material.Metal
	cab.Anchored = false
	cab.CanCollide = false
	cab.CustomPhysicalProperties = PhysicalProperties.new(LabConfig.CabDensity, 0.3, 0, 1, 1)
	cab.Parent = model
	weldTo(chassis, cab)

	local windshield = Instance.new("Part")
	windshield.Name = "Windshield"
	windshield.Size = Vector3.new(7, 2.2, 0.3)
	windshield.CFrame = cab.CFrame * CFrame.new(0, 0.7, -3.1)
	windshield.Color = Color3.fromRGB(95, 170, 205)
	windshield.Material = Enum.Material.Glass
	windshield.Transparency = 0.35
	windshield.Anchored = false
	windshield.CanCollide = false
	windshield.Massless = true
	windshield.Parent = model
	weldTo(chassis, windshield)

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
	end

	--[[
		Wheels are anchored visual props repositioned from the raycast result
		each frame. Making them real physics wheels would mean constraint tuning
		we explicitly decided not to pay for, and the suspension travel reads
		just as well this way.
	]]
	for _, id in WHEEL_ORDER do
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
		wheel.CFrame = chassis.CFrame * CFrame.new(offset)
		wheel.Parent = model

		self.wheels[id] = {
			id = id,
			offset = offset,
			part = wheel,
			steer = id == "FL" or id == "FR",
			drive = id == "RL" or id == "RR",
			grounded = false,
			compression = 0,
			normalForce = 0,
			surface = "Road",
			spin = 0,
		}
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true
	rayParams.FilterDescendantsInstances = { model }

	self.model = model
	self.chassis = chassis
	self.cab = cab
	self.anchors = anchors
	self.rayParams = rayParams

	self:claimOwnership()
end

--[[
	Sitting a player in a Seat hands that player network ownership of the whole
	assembly, which would silently disable every force this module applies. The
	truck therefore has to take ownership back after anyone sits down, and the
	run loop re-asserts it on a timer in case a seat change is missed.
]]
function PhysicsChassis:claimOwnership()
	local chassis = self.chassis
	if not chassis or not chassis.Parent or chassis.Anchored then
		return
	end
	pcall(function()
		if chassis:GetNetworkOwnershipAuto() or chassis:GetNetworkOwner() ~= nil then
			chassis:SetNetworkOwner(nil)
		end
	end)
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

function PhysicsChassis:applyExternalAccel(accel: Vector3)
	self.externalAccel = accel
end

function PhysicsChassis:damageSuspension(wheelId: string, amount: number)
	local current = self.suspensionHealth[wheelId] or 1
	self.suspensionHealth[wheelId] = math.clamp(current - amount, 0.15, 1)
end

function PhysicsChassis:degradeSteering(amount: number)
	self.steeringHealth = math.clamp(self.steeringHealth - amount, 0.3, 1)
end

function PhysicsChassis:repairSuspension(wheelId: string, amount: number)
	local current = self.suspensionHealth[wheelId] or 1
	self.suspensionHealth[wheelId] = math.clamp(current + amount, 0.15, 1)
end

function PhysicsChassis:applyImpactDamage(amount: number, cause: string)
	if amount <= 0 then
		return
	end
	self.integrity = math.clamp(self.integrity - amount, 0, LabConfig.MaxChassisIntegrity)
	self.lastImpact = os.clock()
	self.lastCause = cause
	if self.integrity <= LabConfig.MinChassisIntegrity then
		self.wrecked = true
	end
end

function PhysicsChassis:step(dt: number, input: DriveInput, extraMass: number)
	local chassis = self.chassis
	if not chassis or not chassis.Parent then
		return
	end

	local cf = chassis.CFrame
	local velocity = chassis.AssemblyLinearVelocity
	local mass = chassis.AssemblyMass + extraMass

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
	local blend = math.clamp(dt * 18, 0, 1)
	self.accelWorld = self.accelWorld:Lerp(rawAccel, blend)
	self.lateralAccel = self.accelWorld:Dot(cf.RightVector)
	self.longitudinalAccel = self.accelWorld:Dot(cf.LookVector)

	-- A hard hit shows up as a velocity change no drivetrain could produce.
	local budget = (LabConfig.EngineAccel + LabConfig.BrakeAccel + GRAVITY) * 1.5
	local unexplained = rawAccel.Magnitude - budget
	if unexplained > 55 and os.clock() - self.lastImpact > 0.35 then
		self:applyImpactDamage(unexplained * dt * LabConfig.ImpactDamageScale, "impact")
	end

	local forwardSpeed = velocity:Dot(cf.LookVector)
	local speedFactor = math.clamp(
		1 - math.abs(forwardSpeed) / LabConfig.SteerSpeedFalloff,
		LabConfig.MinSteerFactor,
		1
	)
	local maxSteer = math.rad(LabConfig.MaxSteerAngleDeg) * speedFactor * self.steeringHealth
	local targetSteer = math.clamp(input.steering, -1, 1) * maxSteer
	local steerStep = math.rad(LabConfig.SteerRateDegPerSec) * dt
	self.steerAngle += math.clamp(targetSteer - self.steerAngle, -steerStep, steerStep)
	self.turnSeverity = math.abs(self.steerAngle) / math.max(math.rad(LabConfig.MaxSteerAngleDeg), 0.001)

	local stiffness, damping = self:_springRate(extraMass)
	local maxSpringForce = mass * GRAVITY * LabConfig.SuspensionMaxForceScale
	local groundedCount = 0

	for _, id in WHEEL_ORDER do
		local wheel = self.wheels[id]
		local mountWorld = cf * wheel.offset
		local result = workspace:Raycast(
			mountWorld,
			Vector3.new(0, -LabConfig.SuspensionRestLength, 0),
			self.rayParams
		)

		if result then
			groundedCount += 1
			local distance = (result.Position - mountWorld).Magnitude
			local compression = math.clamp(
				(LabConfig.SuspensionRestLength - distance) / LabConfig.SuspensionRestLength,
				0,
				1
			)
			local health = self.suspensionHealth[id] or 1
			local normal = result.Normal
			local pointVelocity = chassis:GetVelocityAtPosition(mountWorld)
			local springVelocity = pointVelocity:Dot(normal)

			local force = math.clamp(
				stiffness * compression * health - damping * springVelocity,
				0,
				maxSpringForce
			)
			chassis:ApplyImpulseAtPosition(normal * force * dt, mountWorld)

			local surfaceName = result.Instance:GetAttribute("LabSurface")
			local surface = LabConfig.surface(if typeof(surfaceName) == "string" then surfaceName else nil)

			wheel.grounded = true
			wheel.compression = compression
			wheel.normalForce = force
			wheel.surface = if typeof(surfaceName) == "string" then surfaceName else "Road"

			-- Contact-patch axes, flattened onto the surface the wheel is on.
			local steerRotation = if wheel.steer then CFrame.Angles(0, self.steerAngle, 0) else CFrame.identity
			local wheelLook = (cf * steerRotation).LookVector
			local wheelForward = (wheelLook - normal * wheelLook:Dot(normal))
			if wheelForward.Magnitude < 0.01 then
				wheelForward = cf.LookVector
			end
			wheelForward = wheelForward.Unit
			local wheelRight = wheelForward:Cross(normal).Unit

			--[[
				Lateral grip, limited by this wheel's own normal load. This one
				line is why the truck behaves: lift a wheel on a corner and its
				grip budget collapses, so the truck starts to slide exactly when
				a real one would.
			]]
			local grip = if wheel.steer then LabConfig.GripFront else LabConfig.GripRear
			local lateralVelocity = pointVelocity:Dot(wheelRight)
			local desiredLateral = -lateralVelocity * grip * (mass / 4) * surface.grip
			local gripBudget = force * LabConfig.GripLimitPerWheel * surface.grip
			local lateralForce = math.clamp(desiredLateral, -gripBudget, gripBudget)
			chassis:ApplyImpulseAtPosition(wheelRight * lateralForce * dt, mountWorld)

			local longitudinal = 0
			if input.braking then
				local along = pointVelocity:Dot(wheelForward)
				longitudinal = -math.sign(along)
					* math.min(math.abs(along) / math.max(dt, 1 / 240), LabConfig.BrakeAccel)
					* (mass / 4)
				longitudinal = math.clamp(longitudinal, -gripBudget, gripBudget)
			elseif wheel.drive and math.abs(input.throttle) > 0.05 then
				local accelTarget = if input.throttle > 0 then LabConfig.EngineAccel else -LabConfig.ReverseAccel
				local limit = if input.throttle > 0
					then LabConfig.MaxForwardSpeed
					else -LabConfig.MaxReverseSpeed
				local overspeed = if input.throttle > 0
					then forwardSpeed > limit
					else forwardSpeed < limit
				if not overspeed then
					longitudinal = math.clamp(
						accelTarget * math.abs(input.throttle) * (mass / 2),
						-gripBudget,
						gripBudget
					)
				end
			else
				local along = pointVelocity:Dot(wheelForward)
				-- Deadzone, or a parked truck oscillates around zero forever.
				if math.abs(along) > LabConfig.SpeedDeadzone then
					longitudinal = -math.sign(along) * LabConfig.CoastDecel * (mass / 4)
				end
			end

			-- Rolling resistance from the surface the wheel is actually on.
			local along = pointVelocity:Dot(wheelForward)
			if surface.resistance > 0 and math.abs(along) > LabConfig.SpeedDeadzone then
				longitudinal -= math.sign(along) * surface.resistance * (mass / 4)
			end

			chassis:ApplyImpulseAtPosition(wheelForward * longitudinal * dt, mountWorld)
			self.brakeForce = if input.braking then math.abs(longitudinal) / math.max(mass, 1) else 0

			wheel.part.CFrame = CFrame.lookAt(
				result.Position + normal * LabConfig.WheelRadius,
				result.Position + normal * LabConfig.WheelRadius + wheelForward
			) * CFrame.Angles(0, math.rad(90), 0) * CFrame.Angles(0, 0, math.rad(90))
		else
			wheel.grounded = false
			wheel.compression = 0
			wheel.normalForce = 0
			wheel.surface = "Air"
			wheel.part.CFrame = cf * CFrame.new(wheel.offset - Vector3.new(0, LabConfig.SuspensionRestLength * 0.7, 0))
				* CFrame.Angles(0, 0, math.rad(90))
		end
	end

	if self.externalAccel.Magnitude > 0.01 then
		chassis:ApplyImpulseAtPosition(self.externalAccel * mass * dt, cf.Position)
	end

	-- Raycast vehicles accumulate a slow yaw drift with no real tyre contact
	-- patch to resist it. Damp only yaw so roll and pitch stay expressive.
	local angular = chassis.AssemblyAngularVelocity
	local damped = angular.Y * (1 - math.clamp(LabConfig.YawDamping * dt, 0, 1))
	if angular.Magnitude > LabConfig.MaxAngularSpeed then
		angular = angular.Unit * LabConfig.MaxAngularSpeed
		damped = math.clamp(damped, -LabConfig.MaxAngularSpeed, LabConfig.MaxAngularSpeed)
	end
	chassis.AssemblyAngularVelocity = Vector3.new(angular.X, damped, angular.Z)

	if groundedCount == 0 then
		self.brakeForce = 0
	end

	-- Rollover: not a threshold on a meter, just the truck being upside down
	-- for long enough that nobody is getting it back.
	if cf.UpVector:Dot(Vector3.yAxis) < 0.15 then
		self.invertedFor += dt
		if self.invertedFor > 1.6 and not self.wrecked then
			self.wrecked = true
			self.lastCause = "rolled"
		end
	else
		self.invertedFor = 0
	end

	if chassis.Position.Y < LabConfig.VoidY then
		self.wrecked = true
		self.lastCause = "fell"
	end
end

function PhysicsChassis:getSpeed(): number
	return self.chassis.AssemblyLinearVelocity.Magnitude
end

function PhysicsChassis:getForwardSpeed(): number
	return self.chassis.AssemblyLinearVelocity:Dot(self.chassis.CFrame.LookVector)
end

function PhysicsChassis:getRouteProgress(): number
	return WorldBuilder.labProgress(self.route, self.chassis.Position)
end

function PhysicsChassis:getRollDegrees(): number
	local cf = self.chassis.CFrame
	return math.deg(math.asin(math.clamp(cf.RightVector.Y, -1, 1)))
end

function PhysicsChassis:getPitchDegrees(): number
	local cf = self.chassis.CFrame
	return math.deg(math.asin(math.clamp(cf.LookVector.Y, -1, 1)))
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

function PhysicsChassis:reset()
	local chassis = self.chassis
	chassis.AssemblyLinearVelocity = Vector3.zero
	chassis.AssemblyAngularVelocity = Vector3.zero
	self.model:PivotTo(self.route.startCFrame)
	chassis.AssemblyLinearVelocity = Vector3.zero
	chassis.AssemblyAngularVelocity = Vector3.zero

	self.steerAngle = 0
	self.integrity = LabConfig.MaxChassisIntegrity
	self.wrecked = false
	self.invertedFor = 0
	self.lastVelocity = Vector3.zero
	self.lateralAccel = 0
	self.longitudinalAccel = 0
	self.turnSeverity = 0
	self.brakeForce = 0
	self.steeringHealth = 1
	self.externalAccel = Vector3.zero
	self.lastCause = ""
	for _, id in WHEEL_ORDER do
		self.suspensionHealth[id] = 1
	end
end

function PhysicsChassis:destroy()
	if self.model then
		self.model:Destroy()
		self.model = nil
	end
end

PhysicsChassis.WheelOrder = WHEEL_ORDER
PhysicsChassis.Heartbeat = RunService.Heartbeat

return PhysicsChassis
