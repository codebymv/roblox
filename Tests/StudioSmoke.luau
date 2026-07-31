-- Engine-level smoke test.
-- Run with Roblox Studio's `--task RunScript` against the built local place.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("Shared")
local server = ServerScriptService:WaitForChild("Server")

local CargoManifest = require(shared:WaitForChild("CargoManifest"))
local Failures = require(shared:WaitForChild("Failures"))
local LiveOps = require(shared:WaitForChild("LiveOps"))
local MatchConfig = require(shared:WaitForChild("MatchConfig"))
local Net = require(shared:WaitForChild("Net"))
local RoleKits = require(shared:WaitForChild("RoleKits"))
local Roles = require(shared:WaitForChild("Roles"))

local CargoRig = require(server:WaitForChild("CargoRig"))
local DepotService = require(server:WaitForChild("DepotService"))
local EconomyService = require(server:WaitForChild("EconomyService"))
local FailureRunner = require(server:WaitForChild("FailureRunner"))

-- Roles ------------------------------------------------------------------
assert(#Roles.assign(1) == 1, "Solo should receive one role")
assert(#Roles.assign(4) == 4, "Full party should receive four roles")

local driverOnly = { Driver = true }
for _ = 1, 20 do
	local picked = Failures.pickRandom(Random.new(), driverOnly, "SharpTurn")
	assert(picked and picked.responsibleRole == "Driver", "Role-filtered deck selected an absent role")
end

-- Networking -------------------------------------------------------------
local remotes = Net.ensureServer()
for _, name in pairs(Net.Names) do
	assert(remotes:FindFirstChild(name), "Missing remote: " .. name)
end

-- Leg ladder curves ------------------------------------------------------
assert(
	MatchConfig.legDuration(1) > MatchConfig.legDuration(4),
	"Legs should get shorter as the convoy pushes"
)
assert(
	MatchConfig.legDuration(50) == MatchConfig.LegMinDurationSeconds,
	"Leg duration should clamp at the floor"
)
assert(
	MatchConfig.legPressure(5) > MatchConfig.legPressure(1),
	"Pressure should rise with leg number"
)
assert(
	MatchConfig.legPressure(500) <= MatchConfig.LegMaxPressure,
	"Pressure should clamp at the ceiling"
)
assert(
	EconomyService.multiplierForLeg(1) == 1,
	"Leg 1 must be a 1x multiplier"
)
assert(
	EconomyService.legValue(3, nil) > EconomyService.legValue(1, nil),
	"Deeper legs must be worth more"
)

-- Manifest ---------------------------------------------------------------
local rng = Random.new(1234)
for _ = 1, 400 do
	local def = CargoManifest.roll(rng, 1)
	assert(def and def.id, "Manifest roll returned nothing")
	assert((def.minLeg or 1) <= 1, "Leg 1 rolled cargo gated behind a deeper leg: " .. def.id)
end
local jackpotSeen = false
for _ = 1, 400 do
	local def = CargoManifest.roll(rng, 6)
	if def.rarity == "Prototype" then
		jackpotSeen = true
	end
end
assert(jackpotSeen, "Jackpot cargo never appeared on a deep leg")
assert(CargoManifest.count() >= 8, "Manifest deck is suspiciously small")

-- Role kits --------------------------------------------------------------
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

-- Rig --------------------------------------------------------------------
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
local prompts = 0
local resolutions = 0
local cascades = 0
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

print("STUDIO_SMOKE_OK")
