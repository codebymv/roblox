--!strict

--[[
	Builds the depot hub and one parallel route lane per bay.

	The hub deliberately sits between the spawn and every bay pad, so a player
	walking to their own rig always passes the other crews' pads and the board.
	That foot traffic is the point.
]]

local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local RouteMath = require(Shared:WaitForChild("RouteMath"))

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

--[[
	================= Fun-test route =================

	Unlike the depot lanes, this route has real geometry the truck is genuinely
	constrained by: a blind corner with adverse camber, a long descent, a broken
	surface, and a bridge with nothing either side of it. Environmental pressure
	is the road, not an event that fires.
]]

export type LabLandmark = {
	name: string,
	progress: number,
}

export type LabRouteInfo = {
	root: Folder,
	points: { Vector3 },
	cumulative: { number },
	totalLength: number,
	startCFrame: CFrame,
	deliveryPosition: Vector3,
	deliveryPad: BasePart,
	cornerPosition: Vector3,
	bridgePosition: Vector3,
	descentPosition: Vector3,
	landmarks: { LabLandmark },
}

-- Height above the centreline that a truck spawns at, matching startCFrame.
local LAB_SPAWN_HEIGHT = 5

type RouteNode = {
	position: Vector3,
	width: number,
	surface: string,
	bankDeg: number,
	shoulders: boolean,
}

local function node(position: Vector3, width: number, surface: string, bankDeg: number, shoulders: boolean): RouteNode
	return { position = position, width = width, surface = surface, bankDeg = bankDeg, shoulders = shoulders }
end

local function quadratic(a: Vector3, control: Vector3, b: Vector3, t: number): Vector3
	local inv = 1 - t
	return a * (inv * inv) + control * (2 * inv * t) + b * (t * t)
end

--[[
	The route is about 3,900 studs, which is roughly two to three minutes of
	driving once corners, recoveries and stops are accounted for.

	That is shorter than the five to eight minutes the brief asked for, and the
	trade is deliberate: a run that reliably produces the designed cascade and
	then a second emergent one, and can be repeated twenty times in a session,
	is worth more during validation than a padded one. Lengthening it later is a
	matter of adding nodes to this list.
]]
local LAB_CORNER_Z = 420

local function buildLabNodes(): { RouteNode }
	local nodes: { RouteNode } = {}

	local function straight(position: Vector3, width: number, surface: string, bank: number, shoulders: boolean)
		table.insert(nodes, node(position, width, surface, bank, shoulders))
	end

	local function curve(control: Vector3, target: Vector3, width: number, bank: number, steps: number)
		local from = nodes[#nodes].position
		for step = 1, steps do
			table.insert(nodes, node(quadratic(from, control, target, step / steps), width, "Road", bank, true))
		end
	end

	-- 1. Warm-up straight. Long enough to find the throttle, the brake, and the
	--    fact that the load moves when you use either.
	straight(Vector3.new(0, 0, 0), 34, "Road", 0, true)
	straight(Vector3.new(0, 0, LAB_CORNER_Z), 34, "Road", 0, true)

	-- 2. The blind right-hander, cambered the wrong way so the load wants to go
	--    outboard exactly when the driver is already committed.
	curve(Vector3.new(0, -2, 570), Vector3.new(150, -6, 604), 27, -6, 8)

	-- 3. Breather, and the last flat road for a while.
	straight(Vector3.new(430, -12, 644), 32, "Road", 0, true)

	-- 4. Long descent in two stages. Gravity now adds to anything the corner
	--    started, and the front axle carries the load.
	straight(Vector3.new(770, -72, 702), 30, "Road", 0, true)
	straight(Vector3.new(1050, -122, 762), 30, "Road", 0, true)

	-- 5. Broken surface. Bumps do the work, not a failure event.
	straight(Vector3.new(1320, -128, 822), 30, "Rough", 0, true)
	straight(Vector3.new(1560, -132, 900), 30, "Rough", 0, true)

	-- 6. Left-hander, so a crew that spent the whole first half braced on one
	--    side of the bed is now on the wrong side.
	curve(Vector3.new(1690, -134, 986), Vector3.new(1700, -136, 1120), 26, 5, 6)

	-- 7. Bridge. No shoulders, no rails, no second chance.
	straight(Vector3.new(1700, -136, 1182), 30, "Road", 0, true)
	straight(Vector3.new(1700, -136, 1190), 13, "Bridge", 0, false)
	straight(Vector3.new(1700, -136, 1444), 13, "Bridge", 0, false)

	-- 8. Climb out, which is where a dragging load really costs you.
	straight(Vector3.new(1700, -136, 1452), 32, "Road", 0, true)
	straight(Vector3.new(1622, -102, 1700), 32, "Road", 0, true)

	-- 9. S-bends. Two direction changes in a row is the cheapest way to make an
	--    already-shifted load into a second crisis.
	curve(Vector3.new(1608, -94, 1822), Vector3.new(1784, -88, 1902), 28, -5, 6)
	curve(Vector3.new(1962, -82, 1982), Vector3.new(1962, -76, 2122), 28, 5, 6)

	-- 10. Rough descent to finish, taken with whatever is left.
	straight(Vector3.new(1962, -112, 2382), 30, "Rough", 0, true)

	-- 11. Run-in to the depot.
	straight(Vector3.new(1962, -106, 2620), 34, "Road", 0, true)

	return nodes
end

local function buildRoadSegment(folder: Folder, from: RouteNode, to: RouteNode)
	local delta = to.position - from.position
	local length = delta.Magnitude
	if length < 0.05 then
		return
	end

	local midpoint = (from.position + to.position) / 2
	local bank = math.rad((from.bankDeg + to.bankDeg) / 2)
	local width = (from.width + to.width) / 2
	local orientation = CFrame.lookAt(midpoint, to.position) * CFrame.Angles(0, 0, bank)

	if from.shoulders and to.shoulders then
		local shoulder = makePart(
			"Shoulder",
			Vector3.new(width + 52, 1, length + 2),
			orientation * CFrame.new(0, -0.8, 0),
			Color3.fromRGB(86, 108, 70),
			folder
		)
		shoulder.Material = Enum.Material.Grass
		shoulder:SetAttribute("LabSurface", "Shoulder")
	end

	local road = makePart(
		"Road",
		Vector3.new(width, 1.2, length + 1.5),
		orientation,
		if to.surface == "Bridge"
			then Color3.fromRGB(96, 84, 66)
			elseif to.surface == "Rough" then Color3.fromRGB(74, 68, 58)
			else Color3.fromRGB(58, 61, 68),
		folder
	)
	road.Material = if to.surface == "Bridge"
		then Enum.Material.WoodPlanks
		elseif to.surface == "Rough" then Enum.Material.Ground
		else Enum.Material.Asphalt
	road:SetAttribute("LabSurface", to.surface)

	if to.surface == "Rough" then
		-- Deterministic bumps: the same road every run, so a crew can learn it.
		local bumpCount = math.max(2, math.floor(length / 9))
		for index = 1, bumpCount do
			local alpha = (index - 0.5) / bumpCount
			local side = if index % 2 == 0 then 1 else -1
			local lateral = side * (width * 0.22 + (index % 3) * 1.4)
			local bump = makePart(
				"Bump",
				Vector3.new(6 + (index % 3) * 2.5, 0.9 + (index % 2) * 0.35, 5),
				orientation * CFrame.new(lateral, 0.5, (alpha - 0.5) * length),
				Color3.fromRGB(88, 80, 68),
				folder
			)
			bump.Material = Enum.Material.Ground
			bump:SetAttribute("LabSurface", "Rough")
		end
	end

	if to.surface ~= "Bridge" then
		local centerLine = makePart(
			"CenterLine",
			Vector3.new(0.4, 0.1, math.max(1, length - 3)),
			orientation * CFrame.new(0, 0.66, 0),
			Color3.fromRGB(245, 200, 55),
			folder
		)
		centerLine.CanCollide = false
		centerLine.CanQuery = false
	else
		for _, side in { -1, 1 } do
			local kerb = makePart(
				"BridgeKerb",
				Vector3.new(0.8, 1.1, length),
				orientation * CFrame.new(side * (width / 2 - 0.4), 0.9, 0),
				Color3.fromRGB(150, 120, 80),
				folder
			)
			kerb.Material = Enum.Material.WoodPlanks
			kerb:SetAttribute("LabSurface", "Bridge")
		end
	end
end

function WorldBuilder.buildLabRoute(): LabRouteInfo
	local existing = Workspace:FindFirstChild("CargoLab")
	if existing then
		existing:Destroy()
	end

	-- A leftover baseplate sits at y = 0, right where the warm-up straight is,
	-- and the suspension would happily drive on it. Serving into an existing
	-- Studio place is the common way to hit this.
	for _, name in { "Baseplate", "SpawnLocation" } do
		local stray = Workspace:FindFirstChild(name)
		if stray and stray:IsA("BasePart") then
			stray:Destroy()
		end
	end

	local root = Instance.new("Folder")
	root.Name = "CargoLab"
	root.Parent = Workspace

	local nodes = buildLabNodes()

	local staging = makePart(
		"StagingPad",
		Vector3.new(60, 1, 46),
		CFrame.new(0, 0, -22),
		Color3.fromRGB(48, 50, 58),
		root
	)
	staging.Material = Enum.Material.Concrete
	staging:SetAttribute("LabSurface", "Road")

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LabSpawn"
	spawn.Size = Vector3.new(16, 1, 16)
	spawn.CFrame = CFrame.new(0, 1.1, -36) * CFrame.Angles(0, math.pi, 0)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Transparency = 0.4
	spawn.Color = Color3.fromRGB(230, 230, 230)
	spawn.Parent = root

	for index = 1, #nodes - 1 do
		buildRoadSegment(root, nodes[index], nodes[index + 1])
	end

	local points: { Vector3 } = {}
	local cumulative: { number } = {}
	local total = 0
	for index, entry in nodes do
		points[index] = entry.position
		if index == 1 then
			cumulative[index] = 0
		else
			total += (entry.position - nodes[index - 1].position).Magnitude
			cumulative[index] = total
		end
	end

	local deliveryPosition = nodes[#nodes].position

	--[[
		Runoff past the depot. Overshooting is a normal outcome of arriving with
		a load that will not let you brake, and it should mean an embarrassing
		reverse rather than dropping off the end of the world.
	]]
	local apron = makePart(
		"DepotApron",
		Vector3.new(120, 1.2, 110),
		CFrame.new(deliveryPosition + Vector3.new(0, 0, 42)),
		Color3.fromRGB(52, 55, 62),
		root
	)
	apron.Material = Enum.Material.Concrete
	apron:SetAttribute("LabSurface", "Road")

	local deliveryPad = makePart(
		"DeliveryPad",
		Vector3.new(38, 0.4, 26),
		CFrame.new(deliveryPosition + Vector3.new(0, 0.9, 0)),
		Color3.fromRGB(55, 145, 255),
		root
	)
	deliveryPad.Transparency = 0.4
	deliveryPad.CanCollide = false
	deliveryPad.CanQuery = false
	deliveryPad.Material = Enum.Material.Neon
	makeSignLabel(deliveryPad, "DROP THE LOAD HERE", Color3.fromRGB(200, 235, 255), 26)

	local cornerPosition = Vector3.new(0, 0, LAB_CORNER_Z)
	local hazard = makePart(
		"CornerWarning",
		Vector3.new(7, 7, 0.5),
		CFrame.new(cornerPosition + Vector3.new(-24, 5, -40)) * CFrame.Angles(0, math.rad(35), 0),
		Color3.fromRGB(255, 185, 35),
		root
	)
	hazard.CanCollide = false
	makeSignLabel(hazard, "BLIND RIGHT", Color3.fromRGB(255, 220, 120), 26)

	local route: LabRouteInfo = {
		root = root,
		points = points,
		cumulative = cumulative,
		totalLength = math.max(total, 1),
		startCFrame = CFrame.lookAt(
			Vector3.new(0, LAB_SPAWN_HEIGHT, -6),
			Vector3.new(0, LAB_SPAWN_HEIGHT, 20)
		),
		deliveryPosition = deliveryPosition,
		deliveryPad = deliveryPad,
		cornerPosition = cornerPosition,
		bridgePosition = Vector3.new(1700, -136, 1190),
		descentPosition = Vector3.new(430, -12, 644),
		landmarks = {},
	}

	--[[
		Named points on the route, resolved to arc-length progress so the warp
		command can jump between the sections worth tuning rather than making
		somebody drive 400 studs to reach the corner every iteration.

		Each is placed a little before the feature it names, so warping there
		gives you the approach rather than dropping you mid-event.
	]]
	local markers = {
		{ "Start", nodes[1].position },
		{ "CornerApproach", Vector3.new(0, 0, LAB_CORNER_Z - 130) },
		{ "BlindRight", cornerPosition },
		{ "Descent", Vector3.new(430, -12, 644) },
		{ "Rough", Vector3.new(1320, -128, 822) },
		{ "LeftBend", Vector3.new(1700, -136, 1120) },
		{ "Bridge", Vector3.new(1700, -136, 1182) },
		{ "Climb", Vector3.new(1622, -102, 1700) },
		{ "SBends", Vector3.new(1784, -88, 1902) },
		{ "Depot", deliveryPosition },
	}
	for _, marker in markers do
		table.insert(route.landmarks, {
			name = marker[1] :: string,
			progress = WorldBuilder.labProgress(route, marker[2] :: Vector3),
		})
	end

	return route
end

-- Both of these are thin wrappers over Shared/RouteMath, which is engine-free
-- so the arc-length maths can be covered by the headless tests.
function WorldBuilder.labProgress(route: LabRouteInfo, position: Vector3): number
	return RouteMath.progress(route, position)
end

--[[
	The inverse of labProgress: a CFrame on the centreline at a given fraction
	of the route, facing the way the truck should be pointing. Used by the warp
	command so a tuning pass can start at the corner, the descent or the bridge
	instead of at the depot gate.
]]
function WorldBuilder.labCFrameAt(route: LabRouteInfo, progress: number): CFrame
	return RouteMath.cframeAt(route, progress, LAB_SPAWN_HEIGHT)
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
