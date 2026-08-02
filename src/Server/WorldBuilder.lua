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
local LabRoute = require(Shared:WaitForChild("LabRoute"))
local RouteFeatures = require(Shared:WaitForChild("RouteFeatures"))
local RouteSections = require(Shared:WaitForChild("RouteSections"))
local RouteMath = require(Shared:WaitForChild("RouteMath"))

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

-- Loaded raycast-suspension ride height above the road centreline. This is
-- ground top + desired spring length - local wheel-mount Y; five studs left
-- the truck free-falling for the first seconds of every prep.
local LAB_TRUCK_RIDE_HEIGHT = 3.2
local LAB_SIGN_HEIGHT = 5

type RouteNode = RouteSections.RouteNode

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

--[[
	One route, into a folder of its own under the shared CargoLab root.

	Every leg is built once at startup and then left standing. Rebuilding a road
	on every leg change would stall the server at the exact moment a crew is
	waiting to set off, and the routes are authored far enough apart in world
	space that having both is free -- the headless suite asserts they do not
	overlap.

	The shared root matters: four client modules find the truck by searching
	Workspace.CargoLab, so the roads may live in separate folders but the
	folders have to live in one place.
]]
local function buildLabRoute(parent: Folder, definition): LabRouteInfo
	local root = Instance.new("Folder")
	root.Name = "Route_" .. definition.id
	root.Parent = parent

	local nodes = LabRoute.nodes(definition.id)
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

	local points, cumulative, surfaces, total = RouteSections.measure(nodes)

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

	local cornerPosition = definition.cornerPosition
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
		id = definition.id,
		label = definition.label,
		blurb = definition.blurb,
		skin = definition.skin,
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
		--[[
			Corners, descents and bridges, read off the geometry above rather
			than written down beside it. PressureDirector weights its events by
			these, and a second route gets the right weighting for free because
			nobody has to remember to describe it.
		]]
		features = RouteFeatures.detect(points, cumulative, surfaces, total),
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
		{ name = "CornerApproach", at = LabRoute.CornerPosition - Vector3.new(0, 0, 130) },
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

--[[
	Build the world: one shared root, and every authored leg inside it.

	Returns the routes in leg order. The session holds them all and switches
	which one the rig is standing on, rather than tearing a road down and
	putting another up between runs.
]]
function WorldBuilder.buildLabWorld(): { LabRouteInfo }
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

	local routes: { LabRouteInfo } = {}
	for index, definition in LabRoute.Routes do
		local route = buildLabRoute(root, definition)
		-- Only the leg being driven offers a spawn. Two enabled SpawnLocations
		-- would drop a respawning player onto whichever road Roblox preferred.
		WorldBuilder.setRouteActive(route, index == 1)
		routes[index] = route
	end
	return routes
end

--[[
	Mark which leg is live. The inactive road stays standing and visible -- it
	is scenery on the horizon rather than something to hide -- but it stops
	accepting spawns.
]]
function WorldBuilder.setRouteActive(route: LabRouteInfo, active: boolean)
	local spawn = route.root:FindFirstChild("LabSpawn")
	if spawn and spawn:IsA("SpawnLocation") then
		spawn.Enabled = active
	end
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

return WorldBuilder
