--!nonstrict

--[[
	One truck, one lane, one crew. Previously this was a module-level singleton;
	the depot needs several of these running at once, so it is now a class.

	The rig stays anchored and server-driven (network ownership of a physics truck
	is not a fight worth having in a prototype). Every part is non-collidable so a
	rig can never snag a player or another crew's rig.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local CargoManifest = require(Shared:WaitForChild("CargoManifest"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Types = require(Shared:WaitForChild("Types"))

local WorldBuilder = require(script.Parent.WorldBuilder)

local CargoRig = {}
CargoRig.__index = CargoRig

export type CargoState = "Stable" | "Tipping" | "Dumped"

local STABLE_STRAP = Color3.fromRGB(65, 150, 235)
local LOOSE_STRAP = Color3.fromRGB(240, 65, 50)

local function makePart(
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	parent: Instance
): Part
	local part = WorldBuilder.makePart(name, size, cframe, color, parent)
	part.CanCollide = false
	part.CanQuery = false
	return part
end

function CargoRig.new(lane: WorldBuilder.LaneInfo)
	local self = setmetatable({
		lane = lane,
		position = lane.startPosition,
		heading = 0,
		speed = 0,
		routeProgress = 0,
		offRoad = false,
		cargoState = "Stable" :: CargoState,
		truckIntegrity = MatchConfig.MaxTruckIntegrity,
		paintColor = Color3.fromRGB(170, 66, 48),
		cargo = nil :: Types.CargoDef?,
	}, CargoRig)

	self:_build()
	return self
end

function CargoRig:_build()
	local model = Instance.new("Model")
	model.Name = "CargoTruck"
	model.Parent = self.lane.folder

	local base = CFrame.new(self.lane.startPosition)

	local body = makePart("Body", Vector3.new(9, 3, 16), base, Color3.fromRGB(63, 70, 78), model)
	local cab = makePart(
		"Cab",
		Vector3.new(8.5, 5.5, 6),
		body.CFrame * CFrame.new(0, 3.6, 4.5),
		self.paintColor,
		model
	)
	local windshield = makePart(
		"Windshield",
		Vector3.new(7, 2.3, 0.3),
		cab.CFrame * CFrame.new(0, 0.6, 3.15),
		Color3.fromRGB(95, 170, 205),
		model
	)
	windshield.Material = Enum.Material.Glass
	windshield.Transparency = 0.25

	makePart(
		"Bed",
		Vector3.new(8.5, 0.8, 9),
		body.CFrame * CFrame.new(0, 2.1, -3),
		Color3.fromRGB(28, 30, 34),
		model
	)

	local crate = makePart(
		"Cargo",
		Vector3.new(6, 6, 6),
		body.CFrame * CFrame.new(0, 5.5, -3),
		Color3.fromRGB(238, 119, 36),
		model
	)
	crate.Material = Enum.Material.WoodPlanks

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "ManifestTag"
	billboard.Size = UDim2.fromOffset(240, 44)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4.5, 0)
	billboard.MaxDistance = 400
	billboard.Parent = crate

	local tag = Instance.new("TextLabel")
	tag.Name = "Text"
	tag.Size = UDim2.fromScale(1, 1)
	tag.BackgroundTransparency = 1
	tag.Font = Enum.Font.GothamBold
	tag.TextSize = 20
	tag.TextStrokeTransparency = 0.4
	tag.TextColor3 = Color3.fromRGB(235, 235, 235)
	tag.Text = ""
	tag.Parent = billboard

	local strap = makePart("CargoStrap", Vector3.new(0.45, 6.5, 6.4), crate.CFrame, STABLE_STRAP, model)
	strap.Material = Enum.Material.Neon

	local light = makePart(
		"FaultLight",
		Vector3.new(1, 1, 1),
		cab.CFrame * CFrame.new(0, 2.8, -2.5),
		Color3.fromRGB(65, 220, 100),
		model
	)
	light.Shape = Enum.PartType.Ball
	light.Material = Enum.Material.Neon

	for _, x in { -4.8, 4.8 } do
		for _, z in { -4.5, 4.5 } do
			local wheel = makePart(
				"Wheel",
				Vector3.new(2.2, 2.2, 1.2),
				body.CFrame * CFrame.new(x, -1.1, z) * CFrame.Angles(0, 0, math.rad(90)),
				Color3.fromRGB(20, 20, 20),
				model
			)
			wheel.Shape = Enum.PartType.Cylinder
		end
	end

	local streakSign = Instance.new("BillboardGui")
	streakSign.Name = "CrewTag"
	streakSign.Size = UDim2.fromOffset(300, 52)
	streakSign.StudsOffsetWorldSpace = Vector3.new(0, 11, 0)
	streakSign.MaxDistance = 500
	streakSign.Parent = body

	local streakLabel = Instance.new("TextLabel")
	streakLabel.Name = "Text"
	streakLabel.Size = UDim2.fromScale(1, 1)
	streakLabel.BackgroundTransparency = 1
	streakLabel.Font = Enum.Font.GothamBlack
	streakLabel.TextSize = 22
	streakLabel.TextStrokeTransparency = 0.35
	streakLabel.TextColor3 = Color3.fromRGB(255, 205, 90)
	streakLabel.Text = "BAY " .. tostring(self.lane.index)
	streakLabel.Parent = streakSign

	model.PrimaryPart = body

	self.model = model
	self.body = body
	self.cab = cab
	self.crate = crate
	self.strap = strap
	self.faultLight = light
	self.manifestTag = tag
	self.crewTag = streakLabel
end

function CargoRig:setPaint(color: Color3)
	self.paintColor = color
	if self.cab then
		self.cab.Color = color
	end
end

function CargoRig:setCrewTag(text: string)
	if self.crewTag then
		self.crewTag.Text = text
	end
end

function CargoRig:applyCargo(def: Types.CargoDef?)
	self.cargo = def
	if not self.crate or not self.manifestTag then
		return
	end
	if def then
		self.crate.Color = CargoManifest.crateColor(def.id)
		self.manifestTag.Text = string.upper(def.label)
		self.manifestTag.TextColor3 = CargoManifest.rarityColor(def.rarity)
	else
		self.crate.Color = Color3.fromRGB(238, 119, 36)
		self.manifestTag.Text = ""
	end
end

function CargoRig:reset()
	self.position = self.lane.startPosition
	self.heading = 0
	self.speed = 0
	self.routeProgress = 0
	self.offRoad = false
	self.truckIntegrity = MatchConfig.MaxTruckIntegrity

	-- A dumped crate is loose in the lane folder; bring it home before restaging.
	local crate = self.crate
	if crate and crate.Parent ~= self.model then
		crate.Anchored = true
		crate.AssemblyLinearVelocity = Vector3.zero
		crate.AssemblyAngularVelocity = Vector3.zero
		crate.Parent = self.model
	end

	self:setFaultActive(false)
	self:setDeliveryCue(false)
	self:setCargoState("Stable")
	self:_pivot()
end

function CargoRig:_pivot()
	if self.model and self.model.PrimaryPart then
		self.model:PivotTo(CFrame.new(self.position) * CFrame.Angles(0, self.heading, 0))
	end
end

function CargoRig:setCargoState(state: CargoState)
	self.cargoState = state
	local crate = self.crate
	local model = self.model
	local body = model and model.PrimaryPart
	if not crate or not model or not body then
		return
	end

	if state == "Dumped" then
		if crate.Parent == model then
			local worldCFrame = crate.CFrame
			crate.Parent = self.lane.folder
			crate.CFrame = worldCFrame
			crate.CanCollide = true
			crate.Anchored = false
			crate.AssemblyLinearVelocity = body.CFrame.RightVector * 34 + Vector3.new(0, 12, 0)
			crate.AssemblyAngularVelocity = Vector3.new(2, 0, 4)
		end
		if self.strap then
			self.strap.Color = Color3.fromRGB(235, 60, 55)
			self.strap.Transparency = 0.45
		end
		return
	end

	if crate.Parent ~= model then
		crate.Parent = model
	end
	crate.Anchored = true
	crate.CanCollide = false
	crate.CFrame = body.CFrame
		* CFrame.new(0, 5.5, -3)
		* CFrame.Angles(0, 0, if state == "Tipping" then math.rad(23) else 0)

	local strap = self.strap
	if strap then
		strap.Color = if state == "Stable" then STABLE_STRAP else LOOSE_STRAP
		strap.Transparency = if state == "Stable" then 0 else 0.1
		strap.CFrame = crate.CFrame
			* CFrame.new(if state == "Tipping" then 1.7 else 0, 0, 0)
			* CFrame.Angles(0, 0, if state == "Tipping" then math.rad(-12) else 0)
	end
end

function CargoRig:setFaultActive(isActive: boolean)
	if self.faultLight then
		self.faultLight.Color = if isActive
			then Color3.fromRGB(255, 60, 45)
			else Color3.fromRGB(65, 220, 100)
	end
end

function CargoRig:setDeliveryCue(isActive: boolean)
	local zone = self.lane.deliveryZone
	if isActive then
		zone.Transparency = 0.1
		zone.Color = Color3.fromRGB(80, 200, 255)
		zone.Size = Vector3.new(34, 0.35, 28)
	else
		zone.Transparency = 0.55
		zone.Color = Color3.fromRGB(55, 145, 255)
		zone.Size = Vector3.new(30, 0.2, 24)
	end
end

function CargoRig:applyTruckDamage(amount: number): number
	self.truckIntegrity = math.clamp(
		self.truckIntegrity - math.max(0, amount),
		0,
		MatchConfig.MaxTruckIntegrity
	)
	self:setFaultActive(
		self.truckIntegrity < MatchConfig.MaxTruckIntegrity - MatchConfig.RepairDamageThreshold
	)
	return self.truckIntegrity
end

function CargoRig:repairTruck(amount: number): number
	self.truckIntegrity = math.clamp(
		self.truckIntegrity + math.max(0, amount),
		0,
		MatchConfig.MaxTruckIntegrity
	)
	if self.truckIntegrity >= MatchConfig.MaxTruckIntegrity - MatchConfig.RepairDamageThreshold then
		self:setFaultActive(false)
	end
	return self.truckIntegrity
end

local function moveToward(value: number, target: number, amount: number): number
	if value < target then
		return math.min(value + amount, target)
	end
	return math.max(value - amount, target)
end

function CargoRig:step(dt: number, throttle: number, steering: number, braking: boolean)
	local model = self.model
	if not model or not model.PrimaryPart then
		return
	end

	local safeDt = math.clamp(dt, 0, 0.1)
	local clampedThrottle = math.clamp(throttle, -1, 1)
	local clampedSteering = math.clamp(steering, -1, 1)

	if braking then
		self.speed = moveToward(self.speed, 0, 38 * safeDt)
	elseif math.abs(clampedThrottle) > 0.05 then
		self.speed += clampedThrottle * 17 * safeDt
	else
		self.speed = moveToward(self.speed, 0, 4.5 * safeDt)
	end
	self.speed = math.clamp(self.speed, -8, MatchConfig.MaxTruckSpeed)

	local speedRatio = math.clamp(math.abs(self.speed) / MatchConfig.MaxTruckSpeed, 0, 1)
	if math.abs(self.speed) > 0.25 then
		local directionSign = if self.speed >= 0 then 1 else -1
		self.heading += clampedSteering
			* math.rad(66)
			* safeDt
			* (0.25 + speedRatio * 0.75)
			* directionSign
	end

	local forward = Vector3.new(math.sin(self.heading), 0, math.cos(self.heading))
	-- World velocity runs slower than the HUD speed so the short graybox route
	-- still leaves room for callouts and recovery.
	self.position += forward * self.speed * safeDt * 0.22
	self.routeProgress = math.clamp(self.position.Z / MatchConfig.RouteLengthStuds, 0, 1)

	local centerX = WorldBuilder.getRouteCenterX(self.position.Z, self.lane.originX)
	self.offRoad = math.abs(self.position.X - centerX) > 18
	if self.offRoad then
		self.speed = moveToward(self.speed, 0, 8 * safeDt)
	end

	self:_pivot()
end

function CargoRig:getSpeed(): number
	return math.abs(self.speed)
end

function CargoRig:getRouteProgress(): number
	return self.routeProgress
end

function CargoRig:getCargoState(): CargoState
	return self.cargoState
end

function CargoRig:getTruckIntegrity(): number
	return self.truckIntegrity
end

function CargoRig:isOffRoad(): boolean
	return self.offRoad
end

function CargoRig:isDelivered(): boolean
	local flat = Vector3.new(self.position.X, 0, self.position.Z)
	local target = Vector3.new(self.lane.deliveryPosition.X, 0, self.lane.deliveryPosition.Z)
	return (flat - target).Magnitude <= 18 and math.abs(self.speed) <= 12
end

function CargoRig:getBody(): BasePart?
	return self.body
end

function CargoRig:destroy()
	if self.model then
		self.model:Destroy()
		self.model = nil
	end
end

return CargoRig
