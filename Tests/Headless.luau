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

check("cframeAt faces along the route", function()
	-- A quarter of the way in the route runs +Z; three quarters in it runs +X.
	local early = RouteMath.cframeAt(straightThenRight, 0.25, 0).LookVector
	local late = RouteMath.cframeAt(straightThenRight, 0.75, 0).LookVector
	assert(early.Z > 0.9, "First leg should face +Z, got " .. tostring(early))
	assert(late.X > 0.9, "Second leg should face +X, got " .. tostring(late))
end)

check("cframeAt clamps out-of-range progress", function()
	local under = RouteMath.cframeAt(straightThenRight, -3, 0)
	local over = RouteMath.cframeAt(straightThenRight, 42, 0)
	assert((under.Position - Vector3.new(0, 0, 0)).Magnitude < 0.01, "Negative progress should clamp to the start")
	assert((over.Position - Vector3.new(100, 0, 100)).Magnitude < 0.01, "Progress over one should clamp to the end")
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
