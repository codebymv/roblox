--!nonstrict

--[[
	The half of the test suite that does not need Roblox running.

		lune run Tests/Headless.luau        (from the repository root)

	A couple of seconds, on every push, with no Studio and no place file. The
	other half lives in Tests/StudioSmoke.luau; see Tests/README.md for which
	belongs where.

	WHAT CAN LIVE HERE

	Only modules with no engine dependency: no game:GetService, no Instance, no
	require of another module through the DataModel. Lune gives us the Roblox
	datatypes and nothing else, which is why LabConfig, MatchConfig, RouteMath,
	TokenBucket and TuningSchema are testable here and PhysicsChassis is not.

	That boundary is a feature rather than a limitation. When a piece of logic
	turns out to be worth testing, the work is to make it engine-free, and it
	usually should have been anyway: RouteMath and TokenBucket were both carved
	out of larger modules for exactly this reason.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

--[[
	The source modules read Vector3 and friends as bare globals, the way Studio
	presents them, while Lune keeps them behind its roblox library. Rather than
	assign into the global environment and hope requires inherit it, each module
	is compiled with an explicit environment that supplies exactly the datatypes
	it needs. injectGlobals keeps the ordinary Luau standard library available
	alongside them.

	The consequence is that a module which grows an engine dependency fails here
	with a nil global rather than passing silently, which is the boundary this
	file is trying to hold.
]]
local ENVIRONMENT = {
	Vector3 = roblox.Vector3,
	CFrame = roblox.CFrame,
	NumberRange = roblox.NumberRange,
}

-- The environment above belongs to the loaded modules; this file needs its own
-- handle on the constructors it uses to build test fixtures.
local Vector3 = roblox.Vector3

local function loadShared(name: string)
	local path = "src/Shared/" .. name .. ".lua"
	assert(fs.isFile(path), "Cannot find " .. path .. " -- run this from the repository root")
	local chunk = luau.load(fs.readFile(path), {
		debugName = name,
		environment = ENVIRONMENT,
		injectGlobals = true,
	})
	return chunk()
end

local LabConfig = loadShared("LabConfig")
local MatchConfig = loadShared("MatchConfig")
local BuildProfiles = loadShared("BuildProfiles")
local AudioIds = loadShared("AudioIds")
local PresentationMath = loadShared("PresentationMath")
local CrewRotation = loadShared("CrewRotation")
local LabProgression = loadShared("LabProgression")
local LabRespawnPolicy = loadShared("LabRespawnPolicy")
local RunVariants = loadShared("RunVariants")
local RouteMath = loadShared("RouteMath")
local TokenBucket = loadShared("TokenBucket")
local TuningSchema = loadShared("TuningSchema")

local failures = 0
local checks = 0

local function check(name: string, run: () -> ())
	checks += 1
	local ok, err = pcall(run)
	if ok then
		print("  ok    " .. name)
	else
		failures += 1
		print("  FAIL  " .. name .. "\n        " .. tostring(err))
	end
end

print("headless suite")

-- ---------------------------------------------------------- config invariants

check("release profile disables every developer-only surface", function()
	local release = BuildProfiles.get("Release")
	assert(#BuildProfiles.releaseSafetyIssues(release) == 0, "Release profile is not safe")
	assert(release.Telemetry, "Release playtests still need server telemetry")
end)

check("development profile keeps the Studio tuning workflow", function()
	local development = BuildProfiles.get("Development")
	assert(development.ShowDebugOverlay and development.LiveTuning, "Studio tooling should be available")
	assert(#BuildProfiles.releaseSafetyIssues(development) > 0, "Development must not masquerade as release")
end)

check("one server is exactly one four-player crew", function()
	assert(LabConfig.MaxCrew == 4, "Fun-test crew capacity must remain four")
	assert(LabConfig.MaxCrew <= 1 + #LabConfig.StationOrder, "Crew capacity exceeds physical truck stations")
end)

check("the core SFX manifest has 36 unique Roblox assets", function()
	local count = 0
	local ids = {}
	for name, id in AudioIds.Sfx do
		count += 1
		assert(typeof(name) == "string" and name ~= "", "SFX entry needs a name")
		assert(typeof(id) == "string" and string.match(id, "^rbxassetid://%d+$"), name .. " has an invalid asset ID")
		assert(not ids[id], "Duplicate SFX asset ID: " .. id)
		ids[id] = true
	end
	assert(count == 36, string.format("Expected 36 core SFX, got %d", count))
end)

check("first-session feedback has enough time to answer", function()
	assert(
		LabConfig.FeedbackResultDisplaySeconds > LabConfig.ResultDisplaySeconds,
		"Feedback result beat must outlast an ordinary restart"
	)
end)

check("successful cargo runs pay more than recoverable failures", function()
	local clean = LabProgression.rewardFor("Delivered", 100, 100)
	local partial = LabProgression.rewardFor("PartialLoss", 70, 70)
	local lost = LabProgression.rewardFor("CargoLost", 0, 80)
	assert(clean > partial, "Clean delivery should beat partial delivery")
	assert(partial > lost, "Partial delivery should beat cargo loss")
	assert(lost > 0, "A failed run should still grant a participation reward")
end)

check("cargo rewards clamp untrusted measurements", function()
	assert(
		LabProgression.rewardFor("Delivered", 1000, 1000) == LabProgression.rewardFor("Delivered", 100, 100),
		"Oversized measurements changed the payout"
	)
	assert(LabProgression.rewardFor("Unknown", 100, 100) == 0, "Unknown outcomes must not pay")
end)

check("the first run is a stable onboarding contract", function()
	local variant = RunVariants.select(1, 0.99, 0.99, 0)
	assert(variant.cargo.id == "GeneralFreight", "First run changed cargo")
	assert(variant.contract.id == "Standard", "First run changed contract")
	assert(variant.difficulty.id == "Normal", "First run changed difficulty")
	assert(variant.openingWeakStrap == "FR", "First run changed its taught weak strap")
end)

check("later runs combine cargo, contract, difficulty, and weak strap", function()
	local variant = RunVariants.select(2, 0.4, 0.8, 0.1)
	assert(variant.cargo.id == "TowerLoad", "Cargo roll did not select the tall load")
	assert(variant.contract.id == "Express", "Contract roll did not select express")
	assert(variant.difficulty.id == "Catastrophe", "Difficulty roll did not select Catastrophe")
	assert(variant.openingWeakStrap == "RL", "Weak strap did not rotate")
end)

check("fragile contracts require both arrival and cargo quality", function()
	local fragile = RunVariants.select(2, 0, 0.4, 0.9)
	assert(fragile.contract.id == "Fragile", "Fixture did not select fragile")
	assert(RunVariants.contractMet(fragile, "Delivered", 75), "Threshold delivery failed")
	assert(not RunVariants.contractMet(fragile, "Delivered", 74.9), "Damaged cargo passed fragile")
	assert(not RunVariants.contractMet(fragile, "CargoLost", 100), "Lost cargo passed fragile")
end)

check("contract and difficulty multipliers stack only when earned", function()
	local variant = RunVariants.select(2, 0, 0.4, 0.1)
	local missed = RunVariants.rewardMultiplier(variant, false)
	local completed = RunVariants.rewardMultiplier(variant, true)
	assert(missed == variant.difficulty.rewardMultiplier, "Missed contract still received its bonus")
	assert(completed > missed, "Completed contract did not increase its multiplier")
	assert(
		LabProgression.rewardFor("Delivered", 100, 100, completed) > LabProgression.rewardFor("Delivered", 100, 100),
		"Reward policy ignored the earned multiplier"
	)
end)

check("respawns never attach to a wreck or result-phase truck", function()
	assert(not LabRespawnPolicy.shouldAttach("Result", false, 0, -200), "Result truck accepted a respawn")
	assert(not LabRespawnPolicy.shouldAttach("Run", true, 0, -200), "Wrecked truck accepted a respawn")
	assert(not LabRespawnPolicy.shouldAttach("Run", false, -180, -200), "Descending void truck accepted a respawn")
	assert(LabRespawnPolicy.shouldAttach("Staging", false, 0, -200), "Safe staging truck rejected a respawn")
end)

check("cargo offset thresholds are strictly increasing", function()
	assert(LabConfig.ShiftedOffset < LabConfig.SlidingOffset, "Shifted must be under Sliding")
	assert(LabConfig.SlidingOffset < LabConfig.HangingOffset, "Sliding must be under Hanging")
	assert(LabConfig.HangingOffset < LabConfig.LostOffset, "Hanging must be under Lost")
end)

check("lean thresholds are increasing", function()
	assert(LabConfig.LeaningAngleDeg < LabConfig.HangingAngleDeg, "Leaning must be under Hanging")
end)

check("every strap has both anchors", function()
	for _, id in LabConfig.StrapOrder do
		assert(LabConfig.StrapRailLocal[id], "Strap has no rail anchor: " .. id)
		assert(LabConfig.StrapCrateLocal[id], "Strap has no crate anchor: " .. id)
	end
end)

check("every station maps to a strap", function()
	for _, id in LabConfig.StationOrder do
		assert(LabConfig.StationLocal[id], "Station has no local CFrame: " .. id)
		assert(LabConfig.StrapRailLocal[id], "Station does not map to a strap: " .. id)
	end
end)

check("surface lookup degrades safely", function()
	assert(LabConfig.surface("Shoulder").grip < LabConfig.surface("Road").grip, "Shoulder must have less grip")
	assert(
		LabConfig.surface("Nonsense").grip == LabConfig.surface("Road").grip,
		"An unknown surface must fall back to road"
	)
	assert(LabConfig.surface(nil).grip == LabConfig.surface("Road").grip, "A nil surface must fall back to road")
end)

check("the opening weak strap is a real strap", function()
	assert(
		table.find(LabConfig.StrapOrder, LabConfig.OpeningWeakStrap) ~= nil,
		"OpeningWeakStrap is not in StrapOrder: " .. tostring(LabConfig.OpeningWeakStrap)
	)
	assert(LabConfig.OpeningWeakHealth < LabConfig.StrapMaxHealth, "The opener must actually weaken the strap")
end)

check("SWAP gates are ordered and inside the route", function()
	local previous = 0
	for _, progress in LabConfig.SwapGateProgress do
		assert(progress > previous and progress < 1, "SWAP gates must be strictly ordered inside the route")
		previous = progress
	end
	assert(#LabConfig.SwapGateProgress >= 1, "At least one SWAP gate is required")
	assert(LabConfig.SwapWarningProgress > 0, "SWAP warning distance must be positive")
	assert(LabConfig.SwapHandoffSeconds > 0, "SWAP handoff must have a safety beat")
end)

-- ------------------------------------------------------------- route maths

--[[
	A hundred studs north, then a hundred studs east. The corner is the whole
	point: a progress metric that reads one world axis reports 0.5 for the
	entire second leg, which is the bug arc-length progress exists to avoid.
]]
local straightThenRight = {
	points = {
		Vector3.new(0, 0, 0),
		Vector3.new(0, 0, 100),
		Vector3.new(100, 0, 100),
	},
	cumulative = { 0, 100, 200 },
	totalLength = 200,
}

check("route progress starts at zero", function()
	assert(RouteMath.progress(straightThenRight, Vector3.new(0, 0, 0)) < 0.01, "Start should be zero progress")
end)

check("route progress reaches a half at the corner", function()
	local halfway = RouteMath.progress(straightThenRight, Vector3.new(0, 0, 100))
	assert(math.abs(halfway - 0.5) < 0.02, "Corner should be halfway, got " .. tostring(halfway))
end)

check("route progress follows the road round a corner", function()
	local past = RouteMath.progress(straightThenRight, Vector3.new(60, 0, 100))
	assert(past > 0.75, "Progress must follow the road, got " .. tostring(past))
end)

check("route progress ignores height", function()
	-- The truck is above the centreline at all times, and airborne over jumps.
	local ground = RouteMath.progress(straightThenRight, Vector3.new(0, 0, 50))
	local air = RouteMath.progress(straightThenRight, Vector3.new(0, 40, 50))
	assert(math.abs(ground - air) < 0.15, "A jump must not throw progress off")
end)

check("route progress is clamped to the route", function()
	local before = RouteMath.progress(straightThenRight, Vector3.new(0, 0, -500))
	local after = RouteMath.progress(straightThenRight, Vector3.new(900, 0, 100))
	assert(before >= 0 and before <= 1, "Progress before the start must clamp")
	assert(after == 1, "Progress past the end must clamp to one, got " .. tostring(after))
end)

check("cframeAt round-trips through progress", function()
	for _, fraction in { 0, 0.25, 0.5, 0.75, 1 } do
		local cf = RouteMath.cframeAt(straightThenRight, fraction, 5)
		local back = RouteMath.progress(straightThenRight, cf.Position)
		assert(math.abs(back - fraction) < 0.02, string.format("cframeAt(%.2f) measured back as %.3f", fraction, back))
	end
end)

check("cframeAt lifts by the requested height", function()
	local cf = RouteMath.cframeAt(straightThenRight, 0.25, 5)
	assert(math.abs(cf.Position.Y - 5) < 0.001, "Expected a 5 stud lift, got " .. tostring(cf.Position.Y))
end)

--[[
	Which way cframeAt faces is asserted in Tests/StudioSmoke.luau instead, not
	because it needs the engine but because Lune gets it wrong: asked to look
	towards +Z from the origin, Lune's CFrame.lookAt returns the identity
	rotation, where Roblox returns a 180 degree yaw. The two disagree about
	which axis lookAt aims, so an assertion here would be testing Lune rather
	than RouteMath. Position is unaffected, so the round-trip and clamping
	checks above are still honest.
]]

check("cframeAt clamps out-of-range progress", function()
	local under = RouteMath.cframeAt(straightThenRight, -3, 0)
	local over = RouteMath.cframeAt(straightThenRight, 42, 0)
	assert((under.Position - Vector3.new(0, 0, 0)).Magnitude < 0.01, "Negative progress should clamp to the start")
	assert((over.Position - Vector3.new(100, 0, 100)).Magnitude < 0.01, "Progress over one should clamp to the end")
end)

-- ------------------------------------------------------ presentation maths

check("presentation smoothing never overshoots", function()
	local value = PresentationMath.approach(0, 100, 12, 1 / 30)
	assert(value > 0 and value < 100, "Smoothing must move toward, not past, the target")
end)

check("presentation smoothing is frame-rate independent", function()
	local oneStep = PresentationMath.approach(0, 100, 10, 0.1)
	local twoSteps = PresentationMath.approach(0, 100, 10, 0.05)
	twoSteps = PresentationMath.approach(twoSteps, 100, 10, 0.05)
	assert(math.abs(oneStep - twoSteps) < 0.0001, "Two half-steps should equal one full step")
end)

check("presentation smoothing ignores invalid time", function()
	assert(PresentationMath.approach(20, 80, 10, 0) == 20, "Zero dt must not change the value")
	assert(PresentationMath.approach(20, 80, 0, 1) == 20, "Zero rate must not change the value")
end)

-- ---------------------------------------------------------- crew rotation

check("two-player SWAP exchanges Driver and Strapper", function()
	local plan, newDriver = CrewRotation.plan("driver", { { id = "strapper", station = "FR" } }, LabConfig.StationOrder)
	assert(newDriver == "strapper", "The Strapper should take the wheel")
	assert(plan.driver.role == "Strapper" and plan.driver.station == "FR", "Driver should take the vacated station")
	assert(plan.strapper.role == "Driver" and plan.strapper.station == nil, "Strapper should become Driver")
end)

check("four-player SWAP rotates every occupied slot", function()
	local plan, newDriver = CrewRotation.plan("driver", {
		{ id = "one", station = "FL" },
		{ id = "two", station = "FR" },
		{ id = "three", station = "RL" },
	}, LabConfig.StationOrder)
	assert(newDriver == "three", "Last occupied station should take the wheel")
	assert(plan.driver.station == "FL", "Driver should rotate into the first station")
	assert(plan.one.station == "FR" and plan.two.station == "RL", "Strappers should advance one station")
	assert(plan.three.role == "Driver", "Final Strapper should become Driver")
end)

check("three-player SWAP gives every player a new slot", function()
	local plan, newDriver = CrewRotation.plan("driver", {
		{ id = "front", station = "FL" },
		{ id = "rear", station = "RL" },
	}, LabConfig.StationOrder)
	assert(newDriver == "rear", "Rear Strapper should take the wheel")
	assert(plan.driver.station == "FL", "Driver should take the first occupied station")
	assert(plan.front.station == "RL", "Front Strapper should advance to the rear station")
	assert(plan.rear.role == "Driver", "Rear Strapper should become Driver")
end)

check("SWAP repairs missing or duplicate station assignments", function()
	local plan = CrewRotation.plan(1, {
		{ id = 2, station = "FL" },
		{ id = 3, station = "FL" },
		{ id = 4, station = nil },
	}, LabConfig.StationOrder)
	local occupied = {}
	for _, assignment in plan do
		if assignment.station then
			assert(not occupied[assignment.station], "Rotation produced a duplicate station")
			occupied[assignment.station] = true
		end
	end
	assert(occupied.FL and occupied.FR and occupied.RL, "Rotation should fill the first three unique stations")
end)

-- ------------------------------------------------------------ token bucket

check("a fresh bucket allows exactly its burst", function()
	local bucket = TokenBucket.new(1, 3)
	assert(bucket:allow(1, 0), "Burst token 1 should pass")
	assert(bucket:allow(1, 0), "Burst token 2 should pass")
	assert(bucket:allow(1, 0), "Burst token 3 should pass")
	assert(not bucket:allow(1, 0), "Bucket should be empty after the burst")
end)

check("tokens refill at the configured rate", function()
	local bucket = TokenBucket.new(2, 2)
	assert(bucket:allow(1, 0) and bucket:allow(1, 0), "Should start full")
	assert(not bucket:allow(1, 0), "Should be empty")
	assert(not bucket:allow(1, 0.4), "Four fifths of a token is not a token")
	assert(bucket:allow(1, 0.5), "One token should be back after half a second at 2/s")
end)

check("refill is capped at the burst size", function()
	local bucket = TokenBucket.new(5, 2)
	assert(bucket:allow(1, 0), "First call primes the bucket")
	-- An hour of idling must not bank an hour of requests.
	assert(bucket:allow(1, 3600), "Refilled token 1")
	assert(bucket:allow(1, 3600), "Refilled token 2")
	assert(not bucket:allow(1, 3600), "Refill must clamp at the burst size")
end)

check("buckets are independent per key", function()
	local bucket = TokenBucket.new(1, 1)
	assert(bucket:allow(1, 0), "Key 1 has a token")
	assert(not bucket:allow(1, 0), "Key 1 is spent")
	assert(bucket:allow(2, 0), "Key 2 must be unaffected by key 1")
end)

check("forget resets a single key", function()
	local bucket = TokenBucket.new(1, 1)
	assert(bucket:allow(7, 0), "Key 7 has a token")
	assert(not bucket:allow(7, 0), "Key 7 is spent")
	bucket:forget(7)
	assert(bucket:allow(7, 0), "A forgotten key starts fresh")
end)

-- ----------------------------------------------------------- tuning schema

--[[
	Checked structurally rather than with typeof, so the assertion says the same
	thing under Lune as it would in Studio.
]]
local function readsAsNumbers(value: any, fields: { string }): boolean
	for _, field in fields do
		local ok, component = pcall(function()
			return value[field]
		end)
		if not ok or type(component) ~= "number" then
			return false
		end
	end
	return true
end

local function looksLike(kind: string, value: any): boolean
	if kind == "number" then
		return type(value) == "number"
	elseif kind == "range" then
		return readsAsNumbers(value, { "Min", "Max" })
	elseif kind == "vector3" then
		return readsAsNumbers(value, { "X", "Y", "Z" })
	end
	return false
end

check("every schema path resolves to a real LabConfig value", function()
	for _, entry in TuningSchema.Entries do
		assert(
			TuningSchema.get(LabConfig, entry.path) ~= nil,
			"Schema exposes a value LabConfig does not have: " .. entry.path
		)
	end
end)

check("schema attribute names are unique and attribute-safe", function()
	local seen = {}
	for _, entry in TuningSchema.Entries do
		assert(not seen[entry.attribute], "Duplicate tuning attribute: " .. entry.attribute)
		seen[entry.attribute] = true
		-- Roblox rejects an attribute name containing anything else.
		assert(
			entry.attribute:match("^[%a_][%w_]*$") ~= nil,
			"Attribute names may only use alphanumerics and underscores: " .. entry.attribute
		)
	end
end)

check("declared kinds match the values they point at", function()
	for _, entry in TuningSchema.Entries do
		local value = TuningSchema.get(LabConfig, entry.path)
		assert(looksLike(entry.kind, value), string.format("%s is declared %s but is not one", entry.path, entry.kind))
	end
end)

check("defaults sit inside their own declared bounds", function()
	for _, entry in TuningSchema.Entries do
		if entry.kind == "number" then
			local value = TuningSchema.get(LabConfig, entry.path)
			local low = entry.min or -math.huge
			local high = entry.max or math.huge
			assert(
				value >= low and value <= high,
				string.format(
					"%s default %s is outside its own range [%s, %s], so the tuning UI would clamp it on load",
					entry.path,
					tostring(value),
					tostring(low),
					tostring(high)
				)
			)
		end
	end
end)

check("byAttribute finds what the schema declares", function()
	local first = TuningSchema.Entries[1]
	assert(TuningSchema.byAttribute(first.attribute) == first, "byAttribute should return the declaring entry")
	assert(TuningSchema.byAttribute("NoSuchAttribute") == nil, "byAttribute should return nil for a stranger")
end)

check("set writes through nested paths", function()
	local path = "Surfaces.Rough.grip"
	local original = TuningSchema.get(LabConfig, path)
	assert(original ~= nil, "Expected a nested surface value to exist")
	assert(TuningSchema.set(LabConfig, path, 0.42), "Nested set should succeed")
	assert(TuningSchema.get(LabConfig, path) == 0.42, "Nested set did not take")
	TuningSchema.set(LabConfig, path, original)
	assert(TuningSchema.get(LabConfig, path) == original, "Failed to restore")
end)

check("set refuses a path that does not exist", function()
	assert(not TuningSchema.set(LabConfig, "Nope.Nothing.Here", 1), "A bogus path must not report success")
	assert(TuningSchema.get(LabConfig, "Nope.Nothing.Here") == nil, "A bogus path must read as nil")
end)

-- --------------------------------------------------------------- leg ladder

check("legs get shorter and harder as the convoy pushes", function()
	assert(MatchConfig.legDuration(1) > MatchConfig.legDuration(4), "Legs should shorten")
	assert(MatchConfig.legDuration(50) == MatchConfig.LegMinDurationSeconds, "Duration should clamp at the floor")
	assert(MatchConfig.legPressure(5) > MatchConfig.legPressure(1), "Pressure should rise with leg number")
	assert(MatchConfig.legPressure(500) <= MatchConfig.LegMaxPressure, "Pressure should clamp at the ceiling")
end)

-- --------------------------------------------------------------------- done

print(string.format("\n%d checks, %d failed", checks, failures))
if failures > 0 then
	process.exit(1)
end
