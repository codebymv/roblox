--!strict

--[[
	Builds the depot hub and one parallel route lane per bay.

	The hub deliberately sits between the spawn and every bay pad, so a player
	walking to their own rig always passes the other crews' pads and the board.
	That foot traffic is the point.
]]

local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MatchConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchConfig"))

export type LaneInfo = {
	index: number,
	originX: number,
	startPosition: Vector3,
	deliveryPosition: Vector3,
	deliveryZone: BasePart,
	bayPad: BasePart,
	folder: Folder,
}

export type WorldInfo = {
	root: Folder,
	lanes: { LaneInfo },
	boardLabel: TextLabel,
	eventLabel: TextLabel,
}

-- Route shape relative to a lane origin.
local ROUTE_POINTS = {
	Vector2.new(0, 0),
	Vector2.new(0, 88),
	Vector2.new(18, 125),
	Vector2.new(55, 168),
	Vector2.new(55, 260),
}
local DELIVERY_OFFSET = Vector3.new(55, 0, 250)
local START_OFFSET = Vector3.new(0, 3, 4)
local HUB_Z = -46

local WorldBuilder = {}

local function makePart(
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	parent: Instance
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Anchored = true
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

WorldBuilder.makePart = makePart

local function makeSignLabel(part: BasePart, text: string, color: Color3, size: number)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Sign"
	billboard.Size = UDim2.fromOffset(260, 60)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 320
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextSize = size
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.Text = text
	label.Parent = billboard
end

local function buildLaneRoad(folder: Folder, originX: number)
	for index = 1, #ROUTE_POINTS - 1 do
		local a = ROUTE_POINTS[index]
		local b = ROUTE_POINTS[index + 1]
		local from = Vector3.new(originX + a.X, 0, a.Y)
		local to = Vector3.new(originX + b.X, 0, b.Y)
		local midpoint = (from + to) / 2
		local length = (to - from).Magnitude

		local road = makePart(
			"Road" .. tostring(index),
			Vector3.new(34, 1, length + 2),
			CFrame.lookAt(midpoint, to),
			Color3.fromRGB(58, 61, 68),
			folder
		)
		road.Material = Enum.Material.Asphalt

		local centerLine = makePart(
			"CenterLine" .. tostring(index),
			Vector3.new(0.35, 0.08, length - 2),
			CFrame.lookAt(midpoint + Vector3.new(0, 0.55, 0), to + Vector3.new(0, 0.55, 0)),
			Color3.fromRGB(245, 200, 55),
			folder
		)
		centerLine.CanCollide = false
		centerLine.Material = Enum.Material.Neon
	end
end

local function buildLane(root: Folder, index: number): LaneInfo
	local originX = (index - 1) * MatchConfig.LaneSpacingStuds

	local folder = Instance.new("Folder")
	folder.Name = "Lane" .. tostring(index)
	folder.Parent = root

	buildLaneRoad(folder, originX)

	local startMarker = makePart(
		"StartLine",
		Vector3.new(28, 0.2, 12),
		CFrame.new(originX, 0.62, 5),
		Color3.fromRGB(65, 205, 110),
		folder
	)
	startMarker.Transparency = 0.35
	startMarker.CanCollide = false

	local deliveryPosition = Vector3.new(originX, 0, 0) + DELIVERY_OFFSET
	local delivery = makePart(
		"DeliveryZone",
		Vector3.new(30, 0.2, 24),
		CFrame.new(deliveryPosition + Vector3.new(0, 0.62, 0)),
		Color3.fromRGB(55, 145, 255),
		folder
	)
	delivery.Transparency = 0.55
	delivery.CanCollide = false
	delivery.Material = Enum.Material.Neon

	local hazardSign = makePart(
		"SharpTurnWarning",
		Vector3.new(6, 6, 0.5),
		CFrame.new(originX - 14, 4, 78) * CFrame.Angles(0, math.rad(25), 0),
		Color3.fromRGB(255, 185, 35),
		folder
	)
	hazardSign.CanCollide = false

	local pad = makePart(
		"BayPad",
		Vector3.new(26, 0.4, 22),
		CFrame.new(originX, 0.5, HUB_Z),
		Color3.fromRGB(70, 78, 92),
		folder
	)
	pad.Material = Enum.Material.Metal
	makeSignLabel(pad, "BAY " .. tostring(index) .. "\nstep on to crew up", Color3.fromRGB(235, 235, 235), 22)

	return {
		index = index,
		originX = originX,
		startPosition = Vector3.new(originX, 0, 0) + START_OFFSET,
		deliveryPosition = deliveryPosition,
		deliveryZone = delivery,
		bayPad = pad,
		folder = folder,
	}
end

local function buildHub(root: Folder, spanX: number): (TextLabel, TextLabel)
	local hub = Instance.new("Folder")
	hub.Name = "Depot"
	hub.Parent = root

	local plaza = makePart(
		"Plaza",
		Vector3.new(spanX + 120, 1, 96),
		CFrame.new(spanX / 2, 0.1, HUB_Z - 26),
		Color3.fromRGB(48, 50, 58),
		hub
	)
	plaza.Material = Enum.Material.Concrete

	-- Rotated so players spawn already facing the bays, with the board overhead
	-- on the way there.
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "DepotSpawn"
	spawn.Size = Vector3.new(20, 1, 20)
	spawn.CFrame = CFrame.new(spanX / 2, 1.1, HUB_Z - 66) * CFrame.Angles(0, math.pi, 0)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Transparency = 0.4
	spawn.Color = Color3.fromRGB(230, 230, 230)
	spawn.Parent = hub

	local board = makePart(
		"DepotBoard",
		Vector3.new(52, 17, 1),
		CFrame.new(spanX / 2, 14, HUB_Z - 44),
		Color3.fromRGB(22, 24, 30),
		hub
	)
	board.CanCollide = false

	local surface = Instance.new("SurfaceGui")
	surface.Name = "BoardGui"
	-- Front is the -Z face, which is the side the spawn looks at.
	surface.Face = Enum.NormalId.Front
	surface.CanvasSize = Vector2.new(1040, 340)
	surface.LightInfluence = 0
	surface.Parent = board

	local boardLabel = Instance.new("TextLabel")
	boardLabel.Name = "Standings"
	boardLabel.Size = UDim2.new(1, -30, 1, -110)
	boardLabel.Position = UDim2.fromOffset(15, 96)
	boardLabel.BackgroundTransparency = 1
	boardLabel.Font = Enum.Font.GothamMedium
	boardLabel.TextSize = 30
	boardLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
	boardLabel.TextXAlignment = Enum.TextXAlignment.Left
	boardLabel.TextYAlignment = Enum.TextYAlignment.Top
	boardLabel.Text = "Standings loading..."
	boardLabel.Parent = surface

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -30, 0, 48)
	title.Position = UDim2.fromOffset(15, 14)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 40
	title.TextColor3 = Color3.fromRGB(255, 190, 55)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "DEPOT STANDINGS"
	title.Parent = surface

	local eventLabel = Instance.new("TextLabel")
	eventLabel.Name = "Event"
	eventLabel.Size = UDim2.new(1, -30, 0, 34)
	eventLabel.Position = UDim2.fromOffset(15, 58)
	eventLabel.BackgroundTransparency = 1
	eventLabel.Font = Enum.Font.GothamBold
	eventLabel.TextSize = 28
	eventLabel.TextColor3 = Color3.fromRGB(120, 205, 255)
	eventLabel.TextXAlignment = Enum.TextXAlignment.Left
	eventLabel.Text = ""
	eventLabel.Parent = surface

	local shopPad = makePart(
		"ShopPad",
		Vector3.new(22, 0.4, 18),
		CFrame.new(spanX / 2 - 62, 0.5, HUB_Z - 34),
		Color3.fromRGB(90, 70, 40),
		hub
	)
	shopPad.Material = Enum.Material.WoodPlanks
	makeSignLabel(shopPad, "OUTFITTER\nrole kits and paint", Color3.fromRGB(255, 205, 120), 22)

	return boardLabel, eventLabel
end

function WorldBuilder.build(): WorldInfo
	local existing = Workspace:FindFirstChild("CargoPrototype")
	if existing then
		existing:Destroy()
	end

	local root = Instance.new("Folder")
	root.Name = "CargoPrototype"
	root.Parent = Workspace

	local spanX = (MatchConfig.BayCount - 1) * MatchConfig.LaneSpacingStuds

	local ground = makePart(
		"Ground",
		Vector3.new(spanX + 320, 1, 480),
		CFrame.new(spanX / 2 + 20, -1, 90),
		Color3.fromRGB(80, 104, 67),
		root
	)
	ground.Material = Enum.Material.Grass

	local boardLabel, eventLabel = buildHub(root, spanX)

	local lanes: { LaneInfo } = {}
	for index = 1, MatchConfig.BayCount do
		lanes[index] = buildLane(root, index)
	end

	return {
		root = root,
		lanes = lanes,
		boardLabel = boardLabel,
		eventLabel = eventLabel,
	}
end

-- Lateral centre of the drivable road at a given Z, for one lane.
function WorldBuilder.getRouteCenterX(z: number, originX: number): number
	if z <= 88 then
		return originX
	elseif z >= 168 then
		return originX + 55
	end
	local alpha = math.clamp((z - 88) / 80, 0, 1)
	local smooth = alpha * alpha * (3 - 2 * alpha)
	return originX + smooth * 55
end

return WorldBuilder
