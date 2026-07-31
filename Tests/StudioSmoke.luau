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
	It branches on DevConfig.Mode, because the two builds share almost no
	runtime. Shared modules are checked either way; the world assertions check
	whichever world Bootstrap actually built.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("Shared")
local server = ServerScriptService:WaitForChild("Server")

local CargoManifest = require(shared:WaitForChild("CargoManifest"))
local DevConfig = require(shared:WaitForChild("DevConfig"))
local Failures = require(shared:WaitForChild("Failures"))
local LabConfig = require(shared:WaitForChild("LabConfig"))
local LiveOps = require(shared:WaitForChild("LiveOps"))
local MatchConfig = require(shared:WaitForChild("MatchConfig"))
local Net = require(shared:WaitForChild("Net"))
local RoleKits = require(shared:WaitForChild("RoleKits"))
local Roles = require(shared:WaitForChild("Roles"))
local RouteMath = require(shared:WaitForChild("RouteMath"))
local TuningSchema = require(shared:WaitForChild("TuningSchema"))

local EconomyService = require(server:WaitForChild("EconomyService"))
local RateLimiter = require(server:WaitForChild("RateLimiter"))

local StudioSmoke = {}

--------------------------------------------------------------------------------
-- Shared: always checked
--------------------------------------------------------------------------------

local function checkShared()
	-- Roles ------------------------------------------------------------------
	assert(#Roles.assign(1) == 1, "Solo should receive one role")
	assert(#Roles.assign(4) == 4, "Full party should receive four roles")

	local driverOnly = { Driver = true }
	for _ = 1, 20 do
		local picked = Failures.pickRandom(Random.new(), driverOnly, "SharpTurn")
		assert(picked and picked.responsibleRole == "Driver", "Role-filtered deck selected an absent role")
	end

	-- Networking ---------------------------------------------------------
	local remotes = Net.ensureServer()
	for _, name in pairs(Net.Names) do
		assert(remotes:FindFirstChild(name), "Missing remote: " .. name)
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

	local truck = lab:WaitForChild("LabTruck", 5)
	assert(truck, "Lab truck was not built")

	local chassis = truck:FindFirstChild("Chassis")
	assert(chassis and chassis:IsA("BasePart"), "Chassis missing")
	assert(not chassis.Anchored, "Chassis must be unanchored; the whole point is real physics")
	assert(chassis.CanCollide, "Chassis must collide with the road")

	for _, id in { "FL", "FR", "RL", "RR" } do
		assert(truck:FindFirstChild("Wheel" .. id), "Missing wheel " .. id)
		assert(chassis:FindFirstChild("Strap_" .. id), "Missing strap anchor " .. id)
	end

	local crate = lab:FindFirstChild("Crate")
	assert(crate and crate:IsA("BasePart"), "Crate missing")
	assert(not crate.Anchored, "Crate must be a real object")

	local ropes = 0
	for _, child in chassis:GetChildren() do
		if child:IsA("RopeConstraint") then
			ropes += 1
		end
	end
	assert(ropes == #LabConfig.StrapOrder, "Expected one rope per strap, found " .. tostring(ropes))

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
	local localOffset = chassis.CFrame:PointToObjectSpace(crate.Position) - LabConfig.CrateHome
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

--------------------------------------------------------------------------------
-- Depot world
--------------------------------------------------------------------------------

local function checkDepot()
	local CargoRig = require(server:WaitForChild("CargoRig"))
	local DepotService = require(server:WaitForChild("DepotService"))
	local FailureRunner = require(server:WaitForChild("FailureRunner"))

	-- Economy ------------------------------------------------------------
	-- The leg duration and pressure ladders are covered headlessly.
	assert(EconomyService.multiplierForLeg(1) == 1, "Leg 1 must be a 1x multiplier")
	assert(EconomyService.legValue(3, nil) > EconomyService.legValue(1, nil), "Deeper legs must be worth more")
	assert(type(EconomyService.equipPaint) == "function", "equipPaint must exist so equipping cannot spend credits")

	-- Manifest -------------------------------------------------------------
	local rng = Random.new(1234)
	for _ = 1, 400 do
		local def = CargoManifest.roll(rng, 1)
		assert(def and def.id, "Manifest roll returned nothing")
		assert((def.minLeg or 1) <= 1, "Leg 1 rolled cargo gated behind a deeper leg: " .. def.id)
	end
	local jackpotSeen = false
	for _ = 1, 400 do
		if CargoManifest.roll(rng, 6).rarity == "Prototype" then
			jackpotSeen = true
		end
	end
	assert(jackpotSeen, "Jackpot cargo never appeared on a deep leg")
	assert(CargoManifest.count() >= 8, "Manifest deck is suspiciously small")

	-- Role kits ------------------------------------------------------------
	for _, roleId in { "Driver", "Strapper", "Spotter", "Repair" } do
		local starterId = RoleKits.starterFor(roleId)
		assert(starterId, "Role has no starter kit: " .. roleId)
		assert(RoleKits.isStarterKit(starterId), "Starter kit not recognised: " .. starterId)
		local starter = RoleKits.getKit(starterId)
		assert(starter and starter.cost == 0, "Starter kits must be free")
		assert(#RoleKits.kitsForRole(roleId) >= 2, "Every role needs something to buy")
	end

	local event = LiveOps.getActive()
	assert(event and event.payoutMultiplier > 0, "LiveOps returned no active event")

	-- Rig ------------------------------------------------------------------
	local testFolder = Instance.new("Folder")
	testFolder.Name = "SmokeTestLane"
	testFolder.Parent = Workspace

	local zone = Instance.new("Part")
	zone.Anchored = true
	zone.CanCollide = false
	zone.Size = Vector3.new(30, 0.2, 24)
	zone.Position = Vector3.new(55, 0.6, 250)
	zone.Parent = testFolder

	local rig = CargoRig.new({
		index = 99,
		originX = 0,
		startPosition = Vector3.new(0, 3, 4),
		deliveryPosition = Vector3.new(55, 0, 250),
		deliveryZone = zone,
		bayPad = zone,
		folder = testFolder,
	})
	rig:reset()

	local initialProgress = rig:getRouteProgress()
	for _ = 1, 50 do
		rig:step(0.1, 1, 0, false)
	end
	assert(rig:getSpeed() > 0, "Rig did not accelerate")
	assert(rig:getRouteProgress() > initialProgress, "Rig did not advance")

	rig:applyCargo(CargoManifest.getById("FuelDrums"))
	rig:setCargoState("Tipping")
	assert(rig:getCargoState() == "Tipping", "Rig did not enter Tipping state")
	rig:setCargoState("Stable")

	local integrity = rig:applyTruckDamage(30)
	assert(integrity < MatchConfig.MaxTruckIntegrity, "Truck damage did not apply")
	assert(rig:repairTruck(30) > integrity, "Repair did not restore integrity")

	rig:destroy()
	testFolder:Destroy()

	-- Failure runner ---------------------------------------------------------
	local prompts, resolutions, cascades = 0, 0, 0
	local runner = FailureRunner.new({
		onPrompt = function()
			prompts += 1
		end,
		onResolved = function()
			resolutions += 1
		end,
		onCascade = function()
			cascades += 1
		end,
		onToast = function() end,
	})
	runner:setRoleWindowBonuses({ Driver = 2 })
	assert(runner:fireById("SharpTurn"), "Could not start forced Sharp Turn")
	assert(runner:tryResolve("Driver"), "Driver could not resolve Sharp Turn")
	assert(prompts == 1 and resolutions == 1 and cascades == 0, "Failure callback counts were incorrect")
	runner:stop()

	-- Depot ------------------------------------------------------------------
	assert(type(DepotService.getCrewFor) == "function", "DepotService did not load")
	local depot = Workspace:FindFirstChild("CargoPrototype")
	assert(depot, "Depot world was not built")
	for index = 1, MatchConfig.BayCount do
		local lane = depot:FindFirstChild("Lane" .. tostring(index))
		assert(lane, "Missing lane " .. tostring(index))
		assert(lane:FindFirstChild("CargoTruck"), "Lane " .. tostring(index) .. " has no rig")
	end
end

function StudioSmoke.run()
	checkShared()

	if DevConfig.isFunTest() then
		checkFunTest()
	else
		checkDepot()
	end

	print("STUDIO_SMOKE_OK (" .. DevConfig.Mode .. ")")
	return true
end

return StudioSmoke
