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
local LabConfig = require(Shared:WaitForChild("LabConfig"))
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

local function makePart(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
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

local function makeDecorPart(
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	parent: Instance
): Part
	local part = makePart(name, size, cframe, color, parent)
	part.Material = material
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	return part
end

local function makePine(parent: Instance, base: Vector3, scale: number)
	local trunkHeight = 5.5 * scale
	local trunk = makeDecorPart(
		"PineTrunk",
		Vector3.new(trunkHeight, 0.8 * scale, 0.8 * scale),
		CFrame.new(base + Vector3.new(0, trunkHeight * 0.5, 0)),
		Color3.fromRGB(82, 58, 38),
		Enum.Material.Wood,
		parent
	)
	trunk.Shape = Enum.PartType.Cylinder
	trunk.CFrame *= CFrame.Angles(0, 0, math.rad(90))

	for tier = 1, 3 do
		local radius = (4.2 - tier * 0.65) * scale
		local crown = makeDecorPart(
			"PineCrown",
			Vector3.new(radius * 1.7, radius, radius * 1.7),
			CFrame.new(base + Vector3.new(0, trunkHeight * 0.55 + tier * 1.6 * scale, 0)),
			if tier == 1 then Color3.fromRGB(43, 78, 51) else Color3.fromRGB(50, 92, 58),
			Enum.Material.Grass,
			parent
		)
		crown.Shape = Enum.PartType.Ball
	end
end

local function makeRockCluster(parent: Instance, base: Vector3, scale: number)
	for index = 1, 3 do
		local rock = makeDecorPart(
			"RoadsideRock",
			Vector3.new((2.5 + index) * scale, (1.5 + index * 0.35) * scale, (2 + index * 0.6) * scale),
			CFrame.new(base + Vector3.new((index - 2) * 2.2 * scale, 0.8 * scale, (index % 2) * 1.3 * scale))
				* CFrame.Angles(math.rad(index * 7), math.rad(index * 31), math.rad(index * 5)),
			Color3.fromRGB(88 + index * 4, 84 + index * 3, 78 + index * 2),
			Enum.Material.Slate,
			parent
		)
		rock.Shape = Enum.PartType.Ball
	end
end

local function makePostedSign(
	parent: Instance,
	cframe: CFrame,
	text: string,
	color: Color3,
	textSize: number,
	boardColor: Color3?
)
	local post = makePart(
		"SignPost",
		Vector3.new(0.35, 5.5, 0.35),
		cframe * CFrame.new(0, -2.75, 0),
		Color3.fromRGB(88, 92, 98),
		parent
	)
	post.Material = Enum.Material.Metal
	post.CanCollide = false
	post.CanTouch = false
	post.CanQuery = false

	local board = makePart(
		"SignBoard",
		Vector3.new(5.8, 3.4, 0.22),
		cframe * CFrame.new(0, 1.15, 0),
		boardColor or Color3.fromRGB(255, 185, 35),
		parent
	)
	board.CanCollide = false
	board.CanTouch = false
	board.CanQuery = false
	board.Material = Enum.Material.SmoothPlastic

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Sign"
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	gui.Parent = board

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextSize = textSize
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.35
	label.Text = text
	label.Parent = gui
end

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
		centerLine.Material = Enum.Material.SmoothPlastic
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
	delivery.Material = Enum.Material.Concrete

	makePostedSign(
		folder,
		CFrame.new(originX - 14, 5.5, 78) * CFrame.Angles(0, math.rad(25), 0),
		"SHARP\nTURN",
		Color3.fromRGB(30, 30, 30),
		22
	)

	local pad = makePart(
		"BayPad",
		Vector3.new(26, 0.4, 22),
		CFrame.new(originX, 0.5, HUB_Z),
		Color3.fromRGB(70, 78, 92),
		folder
	)
	pad.Material = Enum.Material.Metal
	makePostedSign(
		folder,
		CFrame.new(originX, 5.2, HUB_Z - 8) * CFrame.Angles(0, math.pi, 0),
		"BAY " .. tostring(index) .. "\nstep on to crew up",
		Color3.fromRGB(235, 235, 235),
		20,
		Color3.fromRGB(70, 78, 92)
	)

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
	swapGates: { number },
	swapSigns: Folder,
}

-- Loaded raycast-suspension ride height above the road centreline. This is
-- ground top + desired spring length - local wheel-mount Y; five studs left
-- the truck free-falling for the first seconds of every prep.
local LAB_TRUCK_RIDE_HEIGHT = 3.2
local LAB_SIGN_HEIGHT = 5

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
		local startWidth = nodes[#nodes].width
		for step = 1, steps do
			local alpha = step / steps
			local smooth = alpha * alpha * (3 - 2 * alpha)
			local curveWidth = startWidth + (width - startWidth) * smooth
			-- Camber eases in and out instead of changing the collision normal by
			-- three degrees at each end of every authored curve.
			local curveBank = bank * math.sin(math.pi * alpha)
			table.insert(nodes, node(quadratic(from, control, target, alpha), curveWidth, "Road", curveBank, true))
		end
	end

	-- Ease a mostly-forward lane change and its grade together. Linear X here
	-- made the bridge exit turn almost eighteen degrees at a single collision
	-- seam even though the following points looked visually gradual.
	local function easedTurn(target: Vector3, width: number, surface: string, steps: number)
		local fromNode = nodes[#nodes]
		local from = fromNode.position
		for step = 1, steps do
			local alpha = step / steps
			local smooth = alpha * alpha * (3 - 2 * alpha)
			local position = Vector3.new(
				from.X + (target.X - from.X) * smooth,
				from.Y + (target.Y - from.Y) * smooth,
				from.Z + (target.Z - from.Z) * alpha
			)
			local turnWidth = fromNode.width + (width - fromNode.width) * smooth
			table.insert(nodes, node(position, turnWidth, surface, 0, true))
		end
	end

	-- Road width ramps down over the run. Early sections are deliberately wide
	-- so a crew learns throttle and load shift with room to recover; the
	-- current tight widths are the late-run target, not the opening lane.
	--
	--   ~0-17%   44 → 36   warm-up and blind corner
	--   ~17-40%  38 → 32   breather and staged descent
	--   ~40-60%  32 → 28   rough and left bend
	--   ~60%+    13 bridge, 26-28 S-bends, endgame (unchanged intent)

	-- 1. Warm-up straight. Long enough to find the throttle, the brake, and the
	--    fact that the load moves when you use either.
	straight(Vector3.new(0, 0, 0), 44, "Road", 0, true)
	straight(Vector3.new(0, 0, LAB_CORNER_Z), 44, "Road", 0, true)

	-- 2. The blind right-hander, cambered the wrong way so the load wants to go
	--    outboard exactly when the driver is already committed.
	curve(Vector3.new(0, -2, 570), Vector3.new(150, -6, 604), 36, -6, 16)

	-- 3. Breather, and the last flat road for a while.
	straight(Vector3.new(430, -12, 644), 38, "Road", 0, true)

	-- 4. Long descent in three stages. Same horizontal span as before, but the
	--    lane narrows as speed and stakes build toward the rough section.
	straight(Vector3.new(637, -38, 683), 38, "Road", 0, true)
	straight(Vector3.new(843, -77, 723), 34, "Road", 0, true)
	straight(Vector3.new(950, -96, 744), 34, "Road", 0, true)
	straight(Vector3.new(1050, -110, 762), 32, "Road", 0, true)
	straight(Vector3.new(1160, -121, 786), 32, "Rough", 0, true)

	-- 5. Broken surface. Bumps do the work, not a failure event.
	straight(Vector3.new(1320, -128, 822), 32, "Rough", 0, true)
	straight(Vector3.new(1560, -132, 900), 30, "Rough", 0, true)

	-- 6. Left-hander, so a crew that spent the whole first half braced on one
	--    side of the bed is now on the wrong side.
	curve(Vector3.new(1700, -134, 948), Vector3.new(1700, -136, 1120), 28, 5, 12)

	-- 7. Bridge. No shoulders, no rails, no second chance.
	straight(Vector3.new(1700, -136, 1150), 28, "Road", 0, true)
	straight(Vector3.new(1700, -136, 1164), 24, "Road", 0, true)
	straight(Vector3.new(1700, -136, 1176), 19, "Road", 0, true)
	straight(Vector3.new(1700, -136, 1190), 13, "Bridge", 0, false)
	straight(Vector3.new(1700, -136, 1444), 13, "Bridge", 0, false)

	-- 8. Climb out, which is where a dragging load really costs you.
	straight(Vector3.new(1700, -136, 1458), 18, "Road", 0, false)
	straight(Vector3.new(1700, -136, 1472), 24, "Road", 0, true)
	straight(Vector3.new(1700, -136, 1490), 30, "Road", 0, true)
	easedTurn(Vector3.new(1622, -102, 1700), 30, "Road", 10)

	-- 9. S-bends. Two direction changes in a row is the cheapest way to make an
	--    already-shifted load into a second crisis.
	curve(Vector3.new(1600, -94, 1822), Vector3.new(1784, -88, 1902), 28, -5, 12)
	curve(Vector3.new(1962, -82, 1982), Vector3.new(1962, -76, 2122), 26, 5, 12)

	-- 10. Rough descent to finish, taken with whatever is left.
	straight(Vector3.new(1962, -79.7, 2174), 26, "Rough", 0, true)
	straight(Vector3.new(1962, -88.7, 2226), 27, "Rough", 0, true)
	straight(Vector3.new(1962, -99.3, 2278), 27, "Rough", 0, true)
	straight(Vector3.new(1962, -108.3, 2330), 28, "Rough", 0, true)
	straight(Vector3.new(1962, -112, 2382), 28, "Rough", 0, true)

	-- 11. Run-in to the depot.
	straight(Vector3.new(1962, -111.1, 2441.5), 28, "Road", 0, true)
	straight(Vector3.new(1962, -109, 2501), 29, "Road", 0, true)
	straight(Vector3.new(1962, -106.9, 2560.5), 30, "Road", 0, true)
	straight(Vector3.new(1962, -106, 2620), 30, "Road", 0, true)

	return nodes
end

local function buildRoadSegment(folder: Folder, dressing: Folder, from: RouteNode, to: RouteNode, segmentIndex: number)
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
			Vector3.new(width + 10, 1, length + 2),
			orientation * CFrame.new(0, -0.15, 0),
			Color3.fromRGB(86, 108, 70),
			folder
		)
		shoulder.Material = Enum.Material.Grass
		shoulder:SetAttribute("LabSurface", "Shoulder")
		shoulder:SetAttribute("RouteSegmentIndex", segmentIndex)
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
	road:SetAttribute("RouteSegmentIndex", segmentIndex)

	if to.surface == "Rough" then
		-- Deterministic bumps: the same road every run, so a crew can learn it.
		local bumpCount = math.max(1, math.floor(length / 22))
		for index = 1, bumpCount do
			local alpha = (index - 0.5) / bumpCount
			local side = if index % 2 == 0 then 1 else -1
			local lateral = side * (width * 0.22 + (index % 3) * 1.4)
			local bump = makePart(
				"Bump",
				Vector3.new(7 + (index % 3) * 2, 0.45 + (index % 2) * 0.18, 8),
				orientation * CFrame.new(lateral, 0.5, (alpha - 0.5) * length),
				Color3.fromRGB(88, 80, 68),
				folder
			)
			bump.Material = Enum.Material.Ground
			bump.Shape = Enum.PartType.Ball
			bump:SetAttribute("LabSurface", "Rough")
			bump:SetAttribute("RouteSegmentIndex", segmentIndex)
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
		centerLine.Material = Enum.Material.SmoothPlastic

		-- Reflective edge posts give the Driver speed and curvature cues before
		-- the road itself fills the camera. They never participate in raycasts.
		local postCount = math.floor(length / 82)
		for postIndex = 1, postCount do
			local alpha = postIndex / (postCount + 1)
			for _, side in { -1, 1 } do
				local postCF = orientation * CFrame.new(side * (width * 0.5 + 3.2), 1.45, (alpha - 0.5) * length)
				local post = makeDecorPart(
					"EdgePost",
					Vector3.new(0.24, 2.2, 0.24),
					postCF,
					Color3.fromRGB(224, 224, 216),
					Enum.Material.Concrete,
					dressing
				)
				local reflector = makeDecorPart(
					"Reflector",
					Vector3.new(0.34, 0.38, 0.12),
					post.CFrame * CFrame.new(0, 0.55, -0.16),
					Color3.fromRGB(255, 196, 52),
					Enum.Material.Neon,
					dressing
				)
				reflector.CastShadow = false
			end
		end
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

			local rail = makePart(
				"BridgeRail",
				Vector3.new(0.22, 2.35, length),
				orientation * CFrame.new(side * (width / 2 - 0.12), 1.55, 0),
				Color3.fromRGB(118, 124, 132),
				folder
			)
			rail.Material = Enum.Material.Metal
			rail.CanCollide = false
			rail:SetAttribute("LabSurface", "Bridge")

			local postCount = math.max(2, math.floor(length / 11))
			for postIndex = 1, postCount do
				local alpha = (postIndex - 0.5) / postCount
				local post = makePart(
					"BridgePost",
					Vector3.new(0.28, 2.6, 0.28),
					orientation * CFrame.new(side * (width / 2 - 0.12), 1.35, (alpha - 0.5) * length),
					Color3.fromRGB(96, 100, 108),
					folder
				)
				post.Material = Enum.Material.Metal
				post.CanCollide = false
				post:SetAttribute("LabSurface", "Bridge")
			end
		end
	end
end

local function flatRouteAxes(route: LabRouteInfo, progress: number): (CFrame, Vector3, Vector3)
	-- Dressing wants the road centreline, not the truck chassis ride height.
	local centre = RouteMath.cframeAt(route, progress, 0)
	local look = centre.LookVector
	local forward = Vector3.new(look.X, 0, look.Z)
	forward = if forward.Magnitude > 0.01 then forward.Unit else Vector3.new(0, 0, 1)
	local right = Vector3.new(-forward.Z, 0, forward.X)
	return centre, forward, right
end

local function makeFloodlight(parent: Instance, position: Vector3)
	local pole = makeDecorPart(
		"FloodlightPole",
		Vector3.new(0.42, 11, 0.42),
		CFrame.new(position + Vector3.new(0, 5.5, 0)),
		Color3.fromRGB(78, 82, 88),
		Enum.Material.Metal,
		parent
	)
	local lamp = makeDecorPart(
		"Floodlight",
		Vector3.new(2.8, 0.55, 0.45),
		pole.CFrame * CFrame.new(0, 5.1, 0),
		Color3.fromRGB(255, 238, 185),
		Enum.Material.Neon,
		parent
	)
	lamp.CastShadow = false
end

local function buildRouteDressing(dressing: Folder, route: LabRouteInfo)
	local treeSpecs = {
		{ 0.035, -1, 24, 1.15 },
		{ 0.075, 1, 24, 0.9 },
		{ 0.16, -1, 22, 1.3 },
		{ 0.23, 1, 21, 1.05 },
		{ 0.34, -1, 19, 0.95 },
		{ 0.46, 1, 18, 1.2 },
		{ 0.53, -1, 17, 0.85 },
		{ 0.72, 1, 17, 1.15 },
		{ 0.82, -1, 17, 1.0 },
		{ 0.91, 1, 18, 1.25 },
	}
	for _, spec in treeSpecs do
		local centre, _, right = flatRouteAxes(route, spec[1])
		makePine(dressing, centre.Position + right * spec[2] * spec[3] + Vector3.new(0, 0.6, 0), spec[4])
	end

	for _, spec in { { 0.12, 1, 22 }, { 0.42, -1, 18 }, { 0.86, 1, 17 } } do
		local centre, _, right = flatRouteAxes(route, spec[1])
		makeRockCluster(dressing, centre.Position + right * spec[2] * spec[3] + Vector3.new(0, 0.5, 0), 1)
	end

	for _, warning in
		{
			{ progress = 0.37, side = -1, text = "ROUGH\nROAD" },
			{ progress = 0.55, side = 1, text = "BRIDGE\nAHEAD" },
			{ progress = 0.82, side = -1, text = "S-BENDS" },
		}
	do
		local centre, forward, right = flatRouteAxes(route, warning.progress)
		local position = centre.Position + right * warning.side * 18 + Vector3.new(0, 5.5, 0)
		makePostedSign(
			dressing,
			CFrame.lookAt(position, position - forward),
			warning.text,
			Color3.fromRGB(38, 40, 44),
			21,
			Color3.fromRGB(246, 190, 48)
		)
	end

	-- Staging yard props frame the truck without adding collision around spawn.
	makeFloodlight(dressing, Vector3.new(-24, 0.6, -30))
	makeFloodlight(dressing, Vector3.new(24, 0.6, -30))
	for _, side in { -1, 1 } do
		for index = 1, 3 do
			makeDecorPart(
				"YardBarrier",
				Vector3.new(3.8, 1.2, 1.2),
				CFrame.new(side * 25, 1.2, -8 + index * 4),
				if index % 2 == 0 then Color3.fromRGB(235, 235, 225) else Color3.fromRGB(220, 105, 45),
				Enum.Material.Concrete,
				dressing
			)
		end
	end

	-- A simple receiving warehouse turns the finish into a place, not a blue
	-- rectangle floating at the end of the road.
	local _, forward, right = flatRouteAxes(route, 1)
	local buildingPosition = route.deliveryPosition + right * 45 + forward * 20
	local buildingCenter = buildingPosition + Vector3.new(0, 10, 0)
	local buildingCF = CFrame.lookAt(buildingCenter, buildingCenter + forward)
	local warehouse = Instance.new("Model")
	warehouse.Name = "ReceivingWarehouse"
	warehouse.Parent = dressing
	makeDecorPart(
		"Warehouse",
		Vector3.new(48, 20, 58),
		buildingCF,
		Color3.fromRGB(104, 110, 116),
		Enum.Material.Metal,
		warehouse
	)
	makeDecorPart(
		"WarehouseRoof",
		Vector3.new(52, 1.1, 62),
		buildingCF * CFrame.new(0, 10.3, 0),
		Color3.fromRGB(54, 59, 66),
		Enum.Material.Metal,
		warehouse
	)
	local dockPosition = route.deliveryPosition + right * 24 + forward * 3 + Vector3.new(0, 5, 0)
	local dockCF = CFrame.lookAt(dockPosition, dockPosition - right)
	makeDecorPart(
		"LoadingDoor",
		Vector3.new(12, 9, 0.4),
		dockCF,
		Color3.fromRGB(38, 43, 50),
		Enum.Material.DiamondPlate,
		warehouse
	)
	makeDecorPart(
		"DockCanopy",
		Vector3.new(15, 0.6, 8),
		dockCF * CFrame.new(0, 5.1, -3.5),
		Color3.fromRGB(62, 68, 75),
		Enum.Material.Metal,
		warehouse
	)
	makeFloodlight(warehouse, route.deliveryPosition - right * 28 + forward * 20)
	makeFloodlight(warehouse, route.deliveryPosition + right * 28 + forward * 20)
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
	local dressing = Instance.new("Folder")
	dressing.Name = "RoadsideDressing"
	dressing.Parent = root

	local staging =
		makePart("StagingPad", Vector3.new(60, 1.2, 46), CFrame.new(0, 0, -22), Color3.fromRGB(48, 50, 58), root)
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
		buildRoadSegment(root, dressing, nodes[index], nodes[index + 1], index)
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
		Color3.fromRGB(62, 108, 168),
		root
	)
	deliveryPad.Transparency = 0.12
	deliveryPad.CanCollide = false
	deliveryPad.CanQuery = false
	deliveryPad.Material = Enum.Material.Concrete
	makePostedSign(
		root,
		CFrame.new(deliveryPosition + Vector3.new(-22, 5.5, -6)) * CFrame.Angles(0, math.rad(55), 0),
		"DROP THE\nLOAD HERE",
		Color3.fromRGB(200, 235, 255),
		24,
		Color3.fromRGB(62, 108, 168)
	)

	local cornerPosition = Vector3.new(0, 0, LAB_CORNER_Z)
	makePostedSign(
		root,
		CFrame.new(cornerPosition + Vector3.new(-24, 5.5, -40)) * CFrame.Angles(0, math.rad(35), 0),
		"BLIND\nRIGHT",
		Color3.fromRGB(255, 220, 120),
		24
	)
	local swapSigns = Instance.new("Folder")
	swapSigns.Name = "SwapSigns"
	swapSigns.Parent = root

	local route: LabRouteInfo = {
		root = root,
		points = points,
		cumulative = cumulative,
		totalLength = math.max(total, 1),
		startCFrame = CFrame.lookAt(
			Vector3.new(0, LAB_TRUCK_RIDE_HEIGHT, -6),
			Vector3.new(0, LAB_TRUCK_RIDE_HEIGHT, 20)
		),
		deliveryPosition = deliveryPosition,
		deliveryPad = deliveryPad,
		cornerPosition = cornerPosition,
		bridgePosition = Vector3.new(1700, -136, 1190),
		descentPosition = Vector3.new(430, -12, 644),
		landmarks = {},
		swapGates = {},
		swapSigns = swapSigns,
	}
	buildRouteDressing(dressing, route)

	-- Red signs make the forced handoff legible before the HUD says anything.
	-- Each pair faces back up the route so the Driver and bed crew see the same
	-- landmark, regardless of which side of the truck they occupy.
	for index, progress in LabConfig.SwapGateProgress do
		route.swapGates[index] = progress
		local gate = Instance.new("Folder")
		gate.Name = "SwapGate" .. tostring(index)
		gate:SetAttribute("Progress", progress)
		gate.Parent = swapSigns

		local centre = RouteMath.cframeAt(route, progress, 0)
		local forward = centre.LookVector
		local flatForward = Vector3.new(forward.X, 0, forward.Z)
		flatForward = if flatForward.Magnitude > 0.01 then flatForward.Unit else Vector3.new(0, 0, 1)
		local right = Vector3.new(-flatForward.Z, 0, flatForward.X)
		for _, side in { -1, 1 } do
			local position = centre.Position + right * side * 23 + Vector3.new(0, LAB_SIGN_HEIGHT, 0)
			makePostedSign(
				gate,
				CFrame.lookAt(position, position - flatForward),
				"SWAP\nROTATE CREW",
				Color3.fromRGB(255, 245, 245),
				24,
				Color3.fromRGB(190, 38, 42)
			)
		end
	end

	--[[
		Named points on the route, resolved to arc-length progress so the warp
		command can jump between the sections worth tuning rather than making
		somebody drive 400 studs to reach the corner every iteration.

		Each is placed a little before the feature it names, so warping there
		gives you the approach rather than dropping you mid-event.
	]]
	local markers: { { name: string, at: Vector3 } } = {
		{ name = "Start", at = nodes[1].position },
		{ name = "CornerApproach", at = Vector3.new(0, 0, LAB_CORNER_Z - 130) },
		{ name = "BlindRight", at = cornerPosition },
		{ name = "Descent", at = Vector3.new(430, -12, 644) },
		{ name = "Rough", at = Vector3.new(1320, -128, 822) },
		{ name = "LeftBend", at = Vector3.new(1700, -136, 1120) },
		{ name = "Bridge", at = Vector3.new(1700, -136, 1182) },
		{ name = "Climb", at = Vector3.new(1622, -102, 1700) },
		{ name = "SBends", at = Vector3.new(1784, -88, 1902) },
		{ name = "Depot", at = deliveryPosition },
	}
	for _, marker in markers do
		table.insert(route.landmarks, {
			name = marker.name,
			progress = WorldBuilder.labProgress(route, marker.at),
		})
	end
	for index, progress in route.swapGates do
		table.insert(route.landmarks, {
			name = "Swap" .. tostring(index) .. "Approach",
			progress = math.max(0, progress - LabConfig.SwapWarningProgress - 0.01),
		})
	end
	table.sort(route.landmarks, function(a, b)
		return a.progress < b.progress
	end)
	WorldBuilder.setSwapSignsVisible(route, false)

	return route
end

-- SWAP is a multiplayer mechanic. Keep its physical landmark in the route so
-- it can appear immediately when a second crew member joins, but make every
-- visual and query surface disappear for solo play.
function WorldBuilder.setSwapSignsVisible(route: LabRouteInfo, visible: boolean)
	local swapSigns = route and route.swapSigns
	if not swapSigns or not swapSigns.Parent then
		return
	end
	if swapSigns:GetAttribute("VisibleForCrew") == visible then
		return
	end

	swapSigns:SetAttribute("VisibleForCrew", visible)
	for _, descendant in swapSigns:GetDescendants() do
		if descendant:IsA("BasePart") then
			local originalTransparency = descendant:GetAttribute("SwapSignTransparency") :: number?
			local restoredTransparency: number
			if originalTransparency == nil then
				restoredTransparency = descendant.Transparency
				descendant:SetAttribute("SwapSignTransparency", restoredTransparency)
				descendant:SetAttribute("SwapSignCanQuery", descendant.CanQuery)
				descendant:SetAttribute("SwapSignCanTouch", descendant.CanTouch)
			else
				restoredTransparency = originalTransparency
			end
			descendant.Transparency = if visible then restoredTransparency else 1
			descendant.CanQuery = if visible then descendant:GetAttribute("SwapSignCanQuery") == true else false
			descendant.CanTouch = if visible then descendant:GetAttribute("SwapSignCanTouch") == true else false
		elseif descendant:IsA("SurfaceGui") then
			descendant.Enabled = visible
		end
	end
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
	return RouteMath.cframeAt(route, progress, LAB_TRUCK_RIDE_HEIGHT)
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
