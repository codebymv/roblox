--[[
	The half of the test suite that needs Roblox running.

		1. Press Play in Studio and wait for the world to build.
		2. Open the command bar and run:

			require(game.ServerStorage.Tests.StudioSmoke).run()

	Everything here depends on something only the engine provides: a DataModel,
	the physics solver, replication, or a module that reaches for a service at
	require time. Pure logic does not belong in this file -- it belongs in
	Tests/Headless.luau, which CI runs on every push in a couple of seconds.
	Tests/README.md has the full split.

	If you are about to add an assertion here, check first whether the thing it
	tests could be engine-free. Config invariants, arc-length maths and token
	bucket arithmetic all used to live in this file and all moved out.

	This is a module rather than a Script so that syncing it into the place does
	not run it on every Play; run is called explicitly, once the world exists.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("Shared")
local server = ServerScriptService:WaitForChild("Server")

local DevConfig = require(shared:WaitForChild("DevConfig"))
local LabConfig = require(shared:WaitForChild("LabConfig"))
local LabRemotes = require(shared:WaitForChild("LabRemotes"))
local Net = require(shared:WaitForChild("Net"))
local TruckPaints = require(shared:WaitForChild("TruckPaints"))
local RunVariants = require(shared:WaitForChild("RunVariants"))
local RouteMath = require(shared:WaitForChild("RouteMath"))
local TuningSchema = require(shared:WaitForChild("TuningSchema"))

local RateLimiter = require(server:WaitForChild("RateLimiter"))

local StudioSmoke = {}

--------------------------------------------------------------------------------
-- Shared: always checked
--------------------------------------------------------------------------------

local function checkShared()
	assert(Players.MaxPlayers == LabConfig.MaxCrew, "Place capacity must match the server-enforced crew capacity")
	if DevConfig.isRelease() then
		assert(#DevConfig.releaseSafetyIssues() == 0, "Published profile exposed developer tooling")
	end

	-- Networking ---------------------------------------------------------
	local remotes = Net.ensureServer()
	for _, name in pairs(Net.Names) do
		assert(remotes:FindFirstChild(name), "Missing remote: " .. name)
	end
	local feedback = LabRemotes.validate(Net.Names.LabFeedback, "Yes")
	assert(feedback and feedback.answer == "Yes", "Valid playtest feedback was rejected")
	assert(LabRemotes.validate(Net.Names.LabFeedback, "Definitely") == nil, "Unknown feedback must be rejected")
	local drive = LabRemotes.validate(Net.Names.LabDrive, {
		throttle = 1,
		steering = -0.5,
		braking = false,
		sentAt = Workspace:GetServerTimeNow(),
	})
	assert(drive and drive.sentAt, "Timestamped drive input was rejected")
	assert(
		LabRemotes.validate(Net.Names.LabDrive, { throttle = 0, steering = 0, braking = false }),
		"Drive input without a timestamp must remain compatible during rolling publishes"
	)
	assert(LabRemotes.validate(Net.Names.LabDrive, {
		throttle = 0,
		steering = 0,
		braking = false,
		sentAt = 0 / 0,
	}) == nil, "Non-finite drive timestamp must be rejected")
	local vote = LabRemotes.validate(Net.Names.LabContractVote, RunVariants.Choice.Risky)
	assert(vote and vote.choice == RunVariants.Choice.Risky, "A valid contract vote was rejected")
	assert(LabRemotes.validate(Net.Names.LabContractVote, "Safe") ~= nil, "The safe card cannot be voted for")
	assert(LabRemotes.validate(Net.Names.LabContractVote, "risky") == nil, "Choices must be case-sensitive")
	assert(LabRemotes.validate(Net.Names.LabContractVote, "Bank") == nil, "An unknown choice must be rejected")
	assert(LabRemotes.validate(Net.Names.LabContractVote, 1) == nil, "A non-string choice must be rejected")
	assert(LabRemotes.validate(Net.Names.LabInvite, true), "Invite prompt telemetry was rejected")

	local paint = LabRemotes.validate(Net.Names.LabPaint, "DepotGrey")
	assert(paint and paint.paintId == "DepotGrey", "Known paint was rejected")
	assert(LabRemotes.validate(Net.Names.LabPaint, "ExploitGold") == nil, "Unknown paint must be rejected")
	-- Every paint the catalogue offers has to survive the wire, since the
	-- garage builds its buttons straight from this list.
	for _, entry in TruckPaints.getAllPaints() do
		assert(LabRemotes.validate(Net.Names.LabPaint, entry.id), "Catalogue paint was rejected: " .. entry.id)
	end

	-- Route facing -------------------------------------------------------
	-- The rest of RouteMath is covered headlessly. This assertion is not,
	-- because Lune's CFrame.lookAt aims the opposite axis to Roblox's, so only
	-- the engine can answer whether a warp faces down the route or back up it.
	local route = {
		points = { Vector3.new(0, 0, 0), Vector3.new(0, 0, 100), Vector3.new(100, 0, 100) },
		cumulative = { 0, 100, 200 },
		totalLength = 200,
	}
	local early = RouteMath.cframeAt(route, 0.25, 0).LookVector
	local late = RouteMath.cframeAt(route, 0.75, 0).LookVector
	assert(early.Z > 0.9, "First leg should face +Z, got " .. tostring(early))
	assert(late.X > 0.9, "Second leg should face +X, got " .. tostring(late))

	-- Rate limiter -------------------------------------------------------
	-- The bucket arithmetic is covered headlessly. What needs the engine is
	-- the part that keys on a Player and the PlayerRemoving connection.
	local limiter = RateLimiter.new(1, 2)
	local one = { UserId = -998877 }
	local two = { UserId = -998878 }
	assert(limiter:allow(one) and limiter:allow(one), "Burst should pass")
	assert(not limiter:allow(one), "Bucket should be empty after the burst")
	assert(limiter:allow(two), "A different player must have their own bucket")
	limiter:destroy()
	assert(limiter:allow(one), "Destroy should clear the buckets")
	limiter:destroy()
end

--------------------------------------------------------------------------------
-- Fun-test world
--------------------------------------------------------------------------------

local function checkFunTest()
	-- The fun-test world is built by TruckLab during Bootstrap. Rebuilding it
	-- here would destroy the live one out from under the running simulation, so
	-- this section inspects what is already there.
	local lab = Workspace:WaitForChild("CargoLab", 10)
	assert(lab, "Lab world was not built")
	local TruckLab = require(server:WaitForChild("TruckLab"))
	local session = TruckLab.getSession()
	assert(session and session.runVariant, "Live session has no run variation card")
	assert(session.runVariant.cargo.label ~= "", "Run cargo has no player-facing label")
	assert(session.runVariant.contract.brief ~= "", "Run contract has no player-facing brief")
	local player = Players:GetPlayers()[1]
	if player and session.phase == "Staging" then
		local snapshot = session:buildSnapshotFor(player)
		if snapshot.restartSeconds > 0 then
			assert(
				string.find(snapshot.objective, tostring(snapshot.restartSeconds), 1, true),
				"Countdown numeral and prep sentence disagree"
			)
		end
	end

	local truck = lab:WaitForChild("LabTruck", 5)
	assert(truck, "Lab truck was not built")

	local chassis = truck:FindFirstChild("Chassis")
	assert(chassis and chassis:IsA("BasePart"), "Chassis missing")
	assert(chassis:FindFirstChild("BodyForce"), "Chassis body force missing")
	assert(chassis.Anchored == (session.phase ~= "Run"), "Truck must be parked outside Run and physical during Run")
	assert(chassis.CanCollide, "Chassis must collide with the road")
	for _, detailName in { "FrontBumper", "Grille", "RoofVisor", "ExhaustStackL", "ExhaustStackR", "RearBumper" } do
		local detail = truck:FindFirstChild(detailName)
		assert(detail and detail:IsA("BasePart"), "Missing truck silhouette detail " .. detailName)
		assert(detail.Massless and not detail.CanCollide, detailName .. " must remain visual-only")
	end

	for _, id in { "FL", "FR", "RL", "RR" } do
		local wheel = truck:FindFirstChild("Wheel" .. id)
		assert(wheel and wheel:IsA("BasePart"), "Missing wheel " .. id)
		assert(wheel.Anchored and not wheel.CanCollide, "Wheel " .. id .. " must remain a visual target")
		local hub = wheel:FindFirstChild("Hub")
		assert(hub and hub:IsA("BasePart"), "Missing wheel hub " .. id)
		assert(hub.Anchored and hub.Massless, "Wheel hub " .. id .. " must remain a visual target")
		if session.phase == "Staging" then
			local offset = LabConfig.WheelOffsets[id]
			local expectedDrop = LabConfig.SuspensionRestLength * (1 - LabConfig.SuspensionStaticCompression)
				- LabConfig.WheelRadius
			local localPosition = chassis.CFrame:PointToObjectSpace(wheel.Position)
			local expectedPosition = offset - Vector3.yAxis * expectedDrop
			assert(
				(localPosition - expectedPosition).Magnitude < 0.05,
				"Wheel " .. id .. " staging position would jump when suspension starts"
			)
			assert(wheel.CFrame.UpVector:Dot(chassis.CFrame.UpVector) > 0.99, "Wheel " .. id .. " has a flipped basis")
		end
		assert(chassis:FindFirstChild("Strap_" .. id), "Missing strap anchor " .. id)
		assert(chassis:FindFirstChild("Force_" .. id), "Missing wheel force attachment " .. id)
		assert(chassis:FindFirstChild("WheelForce_" .. id), "Missing wheel force actuator " .. id)
	end
	assert(session.chassisRig:hasCompleteWheelSet(), "Truck is missing wheel geometry or force authority")

	local crate = truck:FindFirstChild("Crate")
	assert(crate and crate:IsA("BasePart"), "Crate missing")
	assert(crate:FindFirstChild("Drag"), "Cargo drag actuator missing")
	assert(crate.Anchored == (session.phase ~= "Run"), "Cargo freeze state must match the truck")
	local cargo = session.runVariant.cargo
	local expectedSize = Vector3.new(
		LabConfig.CrateSize.X * cargo.scaleX,
		LabConfig.CrateSize.Y * cargo.scaleY,
		LabConfig.CrateSize.Z * cargo.scaleZ
	)
	assert((crate.Size - expectedSize).Magnitude < 0.05, "Crate geometry does not match the selected cargo")
	local cargoDetails = truck:FindFirstChild("CargoDetails")
	assert(cargoDetails and cargoDetails:IsA("Model"), "Selected cargo has no visual identity model")
	assert(cargoDetails:FindFirstChild("CargoPlacard"), "Selected cargo has no readable placard")

	-- Collision ribbon ----------------------------------------------------
	local roads = {}
	local bumps = {}
	for _, child in lab:GetChildren() do
		if child:IsA("BasePart") and child.Name == "Road" then
			table.insert(roads, child)
		elseif child:IsA("BasePart") and child.Name == "Bump" then
			table.insert(bumps, child)
		end
	end
	assert(#roads >= 70, "Route sampling regressed; curves will become visibly angular")
	assert(#bumps <= 40, "Rough road has too many physical contacts: " .. tostring(#bumps))
	for _, bump in bumps do
		assert(bump.Shape == Enum.PartType.Ball, "Rough-road contacts must use rounded geometry")
		assert(bump.Size.Y <= 0.65, "Rough-road bump is tall enough to launch the truck")
	end
	table.sort(roads, function(a, b)
		return (a:GetAttribute("RouteSegmentIndex") or 0) < (b:GetAttribute("RouteSegmentIndex") or 0)
	end)
	for index, road in roads do
		assert(road:GetAttribute("RouteSegmentIndex") == index, "Road segment indices are missing or unordered")
		if index > 1 then
			local previous = roads[index - 1]
			local directionDelta =
				math.deg(math.acos(math.clamp(previous.CFrame.LookVector:Dot(road.CFrame.LookVector), -1, 1)))
			local normalDelta =
				math.deg(math.acos(math.clamp(previous.CFrame.UpVector:Dot(road.CFrame.UpVector), -1, 1)))
			assert(
				directionDelta <= 9,
				string.format("Road heading/grade joint %d jumps %.2f degrees", index, directionDelta)
			)
			assert(
				normalDelta <= 9,
				string.format("Road surface-normal joint %d jumps %.2f degrees", index, normalDelta)
			)
		end
	end
	local staging = lab:FindFirstChild("StagingPad")
	assert(staging and staging:IsA("BasePart"), "Staging pad missing")
	local stagingTop = staging.Position.Y + staging.Size.Y * 0.5
	local firstRoadTop = roads[1].Position.Y + roads[1].Size.Y * 0.5
	assert(math.abs(stagingTop - firstRoadTop) < 0.01, "Staging pad and first road have a collision lip")

	local dressing = lab:FindFirstChild("RoadsideDressing")
	assert(dressing and dressing:IsA("Folder"), "Roadside dressing was not built")
	assert(dressing:FindFirstChild("ReceivingWarehouse"), "Depot receiving warehouse is missing")
	assert(dressing:FindFirstChild("EdgePost"), "Route has no reflective edge posts")
	for _, descendant in dressing:GetDescendants() do
		if descendant:IsA("BasePart") then
			assert(not descendant.CanCollide, "Visual dressing must not change truck collisions: " .. descendant.Name)
			assert(not descendant.CanQuery, "Visual dressing must not intercept gameplay queries: " .. descendant.Name)
		end
	end

	local ropes = 0
	for _, child in chassis:GetChildren() do
		if child:IsA("RopeConstraint") then
			ropes += 1
		end
	end
	assert(ropes == #LabConfig.StrapOrder, "Expected one rope per strap, found " .. tostring(ropes))

	local swapSigns = lab:FindFirstChild("SwapSigns")
	assert(swapSigns, "SWAP signs were not built")
	local signsVisible = swapSigns:GetAttribute("VisibleForCrew")
	assert(typeof(signsVisible) == "boolean", "SWAP signs must expose their crew visibility state")
	for index, progress in LabConfig.SwapGateProgress do
		local gate = swapSigns:FindFirstChild("SwapGate" .. tostring(index))
		assert(gate, "Missing SWAP gate " .. tostring(index))
		assert(gate:GetAttribute("Progress") == progress, "SWAP gate progress does not match LabConfig")
		local boards = 0
		for _, child in gate:GetChildren() do
			if child.Name == "SignBoard" then
				boards += 1
			end
		end
		assert(boards == 2, "Each SWAP gate should have two roadside boards")
	end
	for _, descendant in swapSigns:GetDescendants() do
		if descendant:IsA("BasePart") then
			assert(descendant.CanCollide == false, "SWAP signs must never block the truck")
			if not signsVisible then
				assert(descendant.Transparency == 1, "Solo SWAP sign geometry must be invisible")
				assert(descendant.CanQuery == false, "Solo SWAP signs must not intercept raycasts")
			end
		elseif descendant:IsA("SurfaceGui") and not signsVisible then
			assert(descendant.Enabled == false, "Solo SWAP sign text must be disabled")
		end
	end

	-- Let the solver settle, then confirm the suspension is actually holding the
	-- truck up rather than sinking it or launching it.
	local startY = chassis.Position.Y
	task.wait(2)
	local restY = chassis.Position.Y
	assert(restY > LabConfig.VoidY, "Truck fell out of the world")
	assert(math.abs(restY - startY) < 12, "Truck did not settle near its spawn height")
	assert(
		chassis.AssemblyLinearVelocity.Magnitude < 8,
		"Parked truck should be at rest, moving at " .. tostring(chassis.AssemblyLinearVelocity.Magnitude)
	)

	local ride = restY - (lab:FindFirstChild("StagingPad") and lab.StagingPad.Position.Y or 0)
	assert(ride > 1, "Truck sank into the ground; suspension is under-sprung (ride " .. tostring(ride) .. ")")

	-- The crate should still be on the bed and roughly where it started.
	local localOffset = chassis.CFrame:PointToObjectSpace(crate.Position) - session.cargoLoad.home
	assert(
		Vector3.new(localOffset.X, 0, localOffset.Z).Magnitude < LabConfig.SlidingOffset,
		"Crate drifted off the bed while parked"
	)

	-- Live tuning ----------------------------------------------------------
	-- The schema is checked headlessly; what needs the engine is whether every
	-- declared knob actually reached an attribute you can edit in Studio.
	if DevConfig.isDevToolingEnabled() then
		local tuning = ReplicatedStorage:WaitForChild("LabTuning", 5)
		assert(tuning, "Tuning folder was not published")
		for _, entry in TuningSchema.Entries do
			assert(tuning:GetAttribute(entry.attribute) ~= nil, "Tunable not mirrored: " .. entry.attribute)
		end
	end
end

function StudioSmoke.run()
	checkShared()
	checkFunTest()
	print("STUDIO_SMOKE_OK (" .. DevConfig.Profile .. ")")
	return true
end

return StudioSmoke
