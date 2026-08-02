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
	-- VfxSpec describes particle colour. NumberSequence and ColorSequence are
	-- deliberately absent: those are built in LabVfx from the scalars here, so
	-- the spec stays loadable without the engine.
	Color3 = roblox.Color3,
}

-- The environment above belongs to the loaded modules; this file needs its own
-- handle on the constructors it uses to build test fixtures.
local Vector3 = roblox.Vector3

--[[
	Shared modules may require their siblings.

	The boundary this file holds is that nothing here may reach the DataModel.
	A Shared module requiring another Shared module does not: it is a plain
	dependency between two engine-free files, and forbidding it was pushing
	composition out of the tested half of the codebase. LabRoute describing the
	road in terms of RouteSections' step kinds is exactly the shape that should
	be encouraged.

	So `script.Parent.Name` resolves to a marker and `require` turns markers
	back into loaded modules, cached, which is enough to emulate sibling
	requires without emulating a DataModel. Anything reaching further -- a
	service, an Instance, a module outside Shared -- still fails with a nil
	global, which is the boundary that matters.
]]
local loaded: { [string]: any } = {}
local loading: { [string]: boolean } = {}

local siblings = setmetatable({}, {
	__index = function(_, key: string)
		return { __sharedModule = key }
	end,
})

local function loadShared(name: string)
	if loaded[name] ~= nil then
		return loaded[name]
	end
	assert(not loading[name], "Circular require between Shared modules at: " .. name)
	loading[name] = true

	local path = "src/Shared/" .. name .. ".lua"
	assert(fs.isFile(path), "Cannot find " .. path .. " -- run this from the repository root")

	local environment = table.clone(ENVIRONMENT)
	environment.script = { Parent = siblings }
	environment.require = function(target: any)
		assert(
			typeof(target) == "table" and target.__sharedModule,
			"Headless modules may only require siblings in src/Shared"
		)
		return loadShared(target.__sharedModule)
	end

	local chunk = luau.load(fs.readFile(path), {
		debugName = name,
		environment = environment,
		injectGlobals = true,
	})
	local result = chunk()
	loading[name] = false
	loaded[name] = result
	return result
end

local LabConfig = loadShared("LabConfig")
local BuildProfiles = loadShared("BuildProfiles")
local AudioIds = loadShared("AudioIds")
local Achievements = loadShared("Achievements")
local AudioMix = loadShared("AudioMix")
local Commerce = loadShared("Commerce")
local DailyContract = loadShared("DailyContract")
local ImpactTiers = loadShared("ImpactTiers")
local VfxSpec = loadShared("VfxSpec")
local PresentationMath = loadShared("PresentationMath")
local CameraFeedback = loadShared("CameraFeedback")
local CrewRotation = loadShared("CrewRotation")
local LabProgression = loadShared("LabProgression")
local LabRespawnPolicy = loadShared("LabRespawnPolicy")
local LabRigPolicy = loadShared("LabRigPolicy")
local RunVariants = loadShared("RunVariants")
local LabRoute = loadShared("LabRoute")
local RouteFeatures = loadShared("RouteFeatures")
local RouteSections = loadShared("RouteSections")
local RouteMath = loadShared("RouteMath")
local RunCauses = loadShared("RunCauses")
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

--[[
	A seated driver has to fit inside the cab.

	Roblox seats a character with its HumanoidRootPart at the weld offset; the
	top of an R15 head sits roughly three studs above that, and hats and tall
	hair go higher again. The old cab cleared it by almost nothing, so anything
	on the character's head came through the roof.
]]
check("a seated driver fits inside the cab, hair included", function()
	local cabCentreY = LabConfig.CabOffset.Y
	local cabTopY = cabCentreY + LabConfig.CabSize.Y * 0.5
	local seatY = LabConfig.DriverSeatOffset.Y

	-- Head top, plus room for an accessory. Deliberately generous: the failure
	-- this guards against is only ever visible to other players.
	local headroomNeeded = 3.6
	assert(
		seatY + headroomNeeded < cabTopY,
		string.format("A seated driver reaches %.2f but the cab roof is at %.2f", seatY + headroomNeeded, cabTopY)
	)

	-- Grown about its centre on purpose. If the centre ever moves, the cab's
	-- contribution to the centre of mass moves with it and the handling tuning
	-- silently stops describing this truck.
	-- Compared with a tolerance because Vector3 stores 32-bit components, so a
	-- literal written as 3.8 does not read back equal to the double 3.8.
	assert(math.abs(cabCentreY - 3.8) < 1e-4, "The cab centre moved; grip and rollover tuning assumed it stays put")

	-- The extra depth is meant to hide inside the chassis rather than show as a
	-- skirt below the body.
	local cabBottomY = cabCentreY - LabConfig.CabSize.Y * 0.5
	local chassisTopY = LabConfig.ChassisSize.Y * 0.5
	assert(cabBottomY < chassisTopY, "The cab base now hangs below the chassis instead of inside it")
end)

check("the windshield stays on the cab's front face", function()
	local halfDepth = LabConfig.CabSize.Z * 0.5
	assert(
		math.abs(LabConfig.WindshieldOffset.Z) >= halfDepth,
		"The windshield sank into the cab instead of sitting on its face"
	)
	local top = LabConfig.WindshieldOffset.Y + LabConfig.WindshieldSize.Y * 0.5
	assert(top < LabConfig.CabSize.Y * 0.5, "The windshield pokes through the cab roof")
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

check("every mixed key names a sound that exists", function()
	for _, table_ in { AudioMix.EventVolume, AudioMix.LoopVolume, AudioMix.DuckWeight } do
		for key in table_ do
			assert(AudioIds.Sfx[key], "Mix references a sound that is not in AudioIds: " .. key)
		end
	end
	for key in AudioMix.LoopVolume do
		assert(string.find(key, "Loop$"), "Bed level applied to a one-shot: " .. key)
	end
end)

--[[
	The three-tier impact sets were previously played at a single volume, so the
	severity the code had carefully computed was inaudible. Ordering is the
	whole point of having tiers.
]]
check("impact severity is audible, not just computed", function()
	for _, prefix in { "CargoImpact", "TruckCollision" } do
		local light = AudioMix.eventVolume(prefix .. "Light")
		local medium = AudioMix.eventVolume(prefix .. "Medium")
		local heavy = AudioMix.eventVolume(prefix .. "Heavy")
		assert(light < medium, prefix .. " medium is not louder than light")
		assert(medium < heavy, prefix .. " heavy is not louder than medium")
	end
end)

--[[
	The invariant the whole split exists to hold: the loudest thing in the bed,
	and the loudest the music ever gets, both stay under the quietest event that
	is important enough to duck. Unducked is the hard case; ducking only widens
	the gap.
]]
check("events clear the bed and the music before any ducking", function()
	local quietestDuckingEvent = math.huge
	for key, weight in AudioMix.DuckWeight do
		if weight > 0 then
			quietestDuckingEvent = math.min(quietestDuckingEvent, AudioMix.eventVolume(key))
		end
	end
	assert(quietestDuckingEvent < math.huge, "No event ducks the mix")

	local loudestLoop = 0
	for _, volume in AudioMix.LoopVolume do
		loudestLoop = math.max(loudestLoop, volume)
	end
	local loudestMusic = 0
	for _, volume in AudioMix.MusicPhaseVolume do
		loudestMusic = math.max(loudestMusic, volume)
	end

	local event = AudioMix.busVolume("SfxEvents", 0) * quietestDuckingEvent
	assert(event > AudioMix.busVolume("SfxBed", 0) * loudestLoop, "The bed can bury an event that matters")
	assert(event > AudioMix.busVolume("Music", 0) * loudestMusic, "The music can bury an event that matters")
end)

check("ducking only ever lowers a bus", function()
	for name in AudioMix.Bus do
		local open = AudioMix.busVolume(name, 0)
		local ducked = AudioMix.busVolume(name, 1)
		assert(ducked <= open, name .. " gets louder when ducked")
		assert(ducked >= 0, name .. " ducks past silence")
	end
	assert(AudioMix.DuckDepth.Music > AudioMix.DuckDepth.SfxBed, "Music should give up more room than the bed")
	assert(AudioMix.DuckDepth.SfxEvents == 0, "Events must not duck themselves")
end)

--[[
	Compressor settings that pump rather than make room. A release shorter than
	the attack is the classic one: the layer underneath snaps back before the
	transient has finished, which is audible as the mix breathing.
]]
check("sidechain compressors make room instead of pumping", function()
	local compressed = 0
	for name, settings in AudioMix.Compressor do
		compressed += 1
		assert(AudioMix.Bus[name], "Compressor configured for a bus that does not exist: " .. name)
		assert(name ~= AudioMix.SideChainBus, name .. " is sidechained to itself")
		assert(settings.ratio > 1, name .. " has a ratio that does not compress")
		assert(settings.thresholdDb < 0, name .. " has a threshold at or above unity")
		assert(settings.attackSeconds > 0, name .. " has an instantaneous attack")
		assert(
			settings.releaseSeconds > settings.attackSeconds,
			name .. " releases faster than it attacks, which pumps"
		)
	end
	assert(compressed > 0, "Nothing is sidechained, so nothing cuts through")
	assert(AudioMix.Bus[AudioMix.SideChainBus], "The sidechain source is not a real bus")
	assert(
		AudioMix.Compressor[AudioMix.SideChainBus] == nil,
		"The event bus compresses itself and would squash its own transients"
	)

	-- Music is the layer with least to say during a crisis, so it gives way
	-- hardest under both mechanisms.
	assert(
		AudioMix.Compressor.Music.ratio > AudioMix.Compressor.SfxBed.ratio,
		"The bed gives way harder than the music"
	)
	assert(
		AudioMix.Compressor.Music.thresholdDb < AudioMix.Compressor.SfxBed.thresholdDb,
		"Music starts compressing later than the bed"
	)
end)

check("music steps back for the run it is scoring", function()
	assert(
		AudioMix.musicPhaseVolume("Run") < AudioMix.musicPhaseVolume("Staging"),
		"Music is not quieter during the run than during staging"
	)
	assert(AudioMix.musicPhaseVolume("Nonsense") == AudioMix.MusicPhaseVolume.Staging, "Unknown phase lost its default")
end)

-- ------------------------------------------------------------- impact tiers

check("damage tiers are ordered and have a dead zone", function()
	assert(ImpactTiers.cargo(0) == nil, "A run bleeding fractions of a point fired an impact")
	assert(ImpactTiers.cargo(ImpactTiers.Minimum - 0.01) == nil, "The dead zone does not hold")
	assert(ImpactTiers.cargo(ImpactTiers.Minimum) == "Light", "The smallest real hit is not Light")
	assert(ImpactTiers.cargo(ImpactTiers.CargoMedium) == "Medium", "The medium threshold is not inclusive")
	assert(ImpactTiers.cargo(ImpactTiers.CargoHeavy) == "Heavy", "The heavy threshold is not inclusive")
	assert(ImpactTiers.chassis(ImpactTiers.ChassisMedium) == "Medium", "Chassis medium is not inclusive")
	assert(ImpactTiers.chassis(ImpactTiers.ChassisHeavy) == "Heavy", "Chassis heavy is not inclusive")
	assert(ImpactTiers.CargoMedium < ImpactTiers.CargoHeavy, "Cargo thresholds are not increasing")
	assert(ImpactTiers.ChassisMedium < ImpactTiers.ChassisHeavy, "Chassis thresholds are not increasing")
end)

--[[
	The whole reason the thresholds moved into a shared module: a heavy hit must
	not sound heavy and look light. Every tier needs both halves, and both must
	climb together.
]]
check("every damage tier has a sound and a particle burst", function()
	for _, tier in ImpactTiers.Order do
		assert(AudioMix.EventVolume["CargoImpact" .. tier], "No cargo impact sound for tier " .. tier)
		assert(AudioMix.EventVolume["TruckCollision" .. tier], "No truck collision sound for tier " .. tier)
		assert(VfxSpec.CargoImpact[tier], "No cargo impact particles for tier " .. tier)
		assert(VfxSpec.TruckCollision[tier], "No truck collision particles for tier " .. tier)
	end

	for index = 2, #ImpactTiers.Order do
		local quieter, louder = ImpactTiers.Order[index - 1], ImpactTiers.Order[index]
		assert(
			VfxSpec.CargoImpact[quieter].count < VfxSpec.CargoImpact[louder].count,
			louder .. " cargo impact throws no more debris than " .. quieter
		)
		assert(
			VfxSpec.TruckCollision[quieter].count < VfxSpec.TruckCollision[louder].count,
			louder .. " collision throws no more debris than " .. quieter
		)
		assert(
			AudioMix.eventVolume("CargoImpact" .. quieter) < AudioMix.eventVolume("CargoImpact" .. louder),
			"Cargo impact audio and particles disagree about severity"
		)
	end
end)

check("every surface a wheel can touch has a spray", function()
	for name in LabConfig.Surfaces do
		assert(VfxSpec.WheelSpray[name], "No wheel spray defined for surface " .. name)
	end
	-- Asphalt is the quiet default; leaving it should be visible before the
	-- handling tells you.
	assert(
		VfxSpec.WheelSpray.Road.rate < VfxSpec.WheelSpray.Shoulder.rate,
		"Leaving the road looks the same as staying"
	)
	assert(VfxSpec.WheelSpray.Road.rate < VfxSpec.WheelSpray.Grass.rate, "Grass does not spray more than asphalt")
	assert(VfxSpec.wheelSpray("Nonsense") == VfxSpec.WheelSpray.Road, "An unknown surface lost its fallback")
	assert(VfxSpec.wheelSpray(nil) == VfxSpec.WheelSpray.Road, "A missing surface lost its fallback")
end)

check("particle specs are physically sane", function()
	local function validate(name: string, spec)
		assert(spec.lifetime.Min > 0, name .. " has particles that never live")
		assert(spec.speed.Min >= 0, name .. " emits at negative speed")
		assert(spec.sizeStart > 0 and spec.sizeEnd > 0, name .. " has a zero-sized particle")
		assert(spec.transparencyStart >= 0 and spec.transparencyStart < 1, name .. " starts invisible")
		assert(spec.spreadDegrees >= 0 and spec.spreadDegrees <= 180, name .. " has an impossible spread")
	end

	for _, name in { "StrapSnap", "StrapRefit", "Rollover", "TyreSmoke", "CargoScrape", "StrapStress" } do
		validate(name, VfxSpec[name])
	end
	for _, group in { "CargoImpact", "TruckCollision", "WheelSpray" } do
		for tier, spec in VfxSpec[group] do
			validate(group .. "." .. tier, spec)
		end
	end

	-- A snapping strap is the clip moment; it should out-throw a refit.
	assert(VfxSpec.StrapSnap.count > VfxSpec.StrapRefit.count, "Refitting a strap is more dramatic than breaking one")
	assert(
		VfxSpec.StrapStressFloor > 0 and VfxSpec.StrapStressFloor < 1,
		"Stress shimmer would show constantly or never"
	)
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

--[[
	The analytics breakdown used to be a substring search over a sentence, so
	rewording a cause emptied a dashboard category with nothing failing. These
	checks are what makes that a test failure instead.
]]
check("every declared wreck cause buckets to something specific", function()
	local seen: { [string]: boolean } = {}
	for _, cause in RunCauses.WreckOrder do
		assert(RunCauses.isWreckCause(cause), cause .. " is not recognised as a wreck cause")
		local bucket = RunCauses.bucket("TruckWrecked", cause)
		assert(
			bucket ~= RunCauses.UnknownWreckBucket,
			cause .. " falls through to the catch-all bucket instead of its own"
		)
		assert(not seen[bucket], "Two wreck causes share the bucket " .. bucket)
		seen[bucket] = true
	end

	for _, named in RunCauses.Wreck do
		local found = false
		for _, cause in RunCauses.WreckOrder do
			found = found or cause == named
		end
		assert(found, "RunCauses.Wreck." .. named .. " is missing from WreckOrder")
	end
end)

-- A wreck the player cannot learn from is a readability failure, and the
-- playtest protocol treats those as no-go signals.
check("every wreck cause tells the player what went wrong", function()
	for _, cause in RunCauses.WreckOrder do
		local text = RunCauses.WreckExplanation[cause]
		assert(typeof(text) == "string" and text ~= "", cause .. " has no explanation for the result screen")
		assert(RunCauses.explain(cause) == text, cause .. " does not resolve to its own explanation")
	end
	for cause in RunCauses.WreckExplanation do
		assert(RunCauses.isWreckCause(cause), "Explanation written for a cause nothing can produce: " .. cause)
	end
end)

-- The result screen is the only place a wreck is ever explained, so the
-- fallback path has to say something rather than render an empty panel.
check("an unrecognised wreck still explains itself", function()
	local fallback = RunCauses.UnknownWreckExplanation
	assert(typeof(fallback) == "string" and fallback ~= "", "The fallback explanation is empty")
	assert(RunCauses.explain(nil) == fallback, "A missing cause produced no explanation")
	assert(RunCauses.explain("reworded by someone") == fallback, "An unknown cause produced no explanation")
	assert(RunCauses.explain("") == fallback, "An empty cause produced no explanation")
	for _, cause in RunCauses.WreckOrder do
		assert(RunCauses.explain(cause) ~= fallback, cause .. " fell through to the generic explanation")
	end
end)

check("outcomes that are not wrecks never consult the cause", function()
	-- A delivered run still carries whatever the load last did. Reading it here
	-- is how the old substring version could mislabel a clean delivery.
	for _, outcome in { "Delivered", "PartialLoss", "CargoLost", "TimeExpired" } do
		local withCause = RunCauses.bucket(outcome, RunCauses.Wreck.Rolled)
		local withoutCause = RunCauses.bucket(outcome, nil)
		assert(withCause == withoutCause, outcome .. " changed bucket because of an unrelated cause")
		assert(withCause ~= "Rollover", outcome .. " was bucketed as a wreck")
	end
	assert(RunCauses.bucket("Delivered", nil) == "Delivery", "Delivered lost its bucket")
	assert(RunCauses.bucket("Abandoned", nil) == "Abandoned", "Unknown outcomes should pass through")
end)

check("a wreck with no usable cause is still countable", function()
	assert(RunCauses.bucket("TruckWrecked", nil) == RunCauses.UnknownWreckBucket, "Missing cause lost its bucket")
	assert(
		RunCauses.bucket("TruckWrecked", "reworded by someone") == RunCauses.UnknownWreckBucket,
		"An unrecognised cause must land in the catch-all, not vanish"
	)
	assert(not RunCauses.isWreckCause(nil), "nil is not a wreck cause")
	assert(not RunCauses.isWreckCause("collision"), "Only declared causes count")
end)

-- -------------------------------------------------------- records and badges

--[[
	Faster is better and zero means never delivered. A plain math.min would make
	the unset sentinel an unbeatable record forever, which is the bug this
	module exists in its own file to prevent.
]]
check("a first delivery sets the time record without claiming to beat one", function()
	local records = Achievements.defaultRecords()
	local beaten = Achievements.applyRun(records, "Delivered", 88, 140, 135)

	assert(records.bestTimeSeconds == 140, "The first delivery did not set a time")
	assert(records.deliveries == 1, "The first delivery was not counted")
	assert(records.deliveryStreak == 1, "The first delivery did not start a streak")
	for _, key in beaten do
		assert(key ~= "bestTimeSeconds", "The first delivery claimed to beat a time that did not exist")
		assert(key ~= "bestDeliveryStreak", "A streak of one was announced as a record")
	end
end)

check("a faster delivery beats the record and a slower one does not", function()
	local records = Achievements.defaultRecords()
	Achievements.applyRun(records, "Delivered", 50, 140, 100)

	local beaten = Achievements.applyRun(records, "Delivered", 50, 120, 100)
	assert(records.bestTimeSeconds == 120, "A faster delivery did not take the record")
	assert(table.find(beaten, "bestTimeSeconds"), "Beating the time was not reported")

	beaten = Achievements.applyRun(records, "Delivered", 50, 200, 100)
	assert(records.bestTimeSeconds == 120, "A slower delivery overwrote the record")
	assert(not table.find(beaten, "bestTimeSeconds"), "A slower delivery was reported as a record")
end)

check("a run that never arrived records nothing and breaks the streak", function()
	local records = Achievements.defaultRecords()
	Achievements.applyRun(records, "Delivered", 90, 150, 130)
	Achievements.applyRun(records, "Delivered", 90, 150, 130)
	assert(records.deliveryStreak == 2, "Two deliveries did not build a streak")

	local beaten = Achievements.applyRun(records, "TruckWrecked", 0, 40, 15)
	assert(#beaten == 0, "A wreck claimed a record")
	assert(records.deliveryStreak == 0, "A wreck did not break the streak")
	assert(records.bestDeliveryStreak == 2, "A wreck erased the best streak")
	assert(records.deliveries == 2, "A wreck counted as a delivery")
	assert(records.bestTimeSeconds == 150, "A wreck overwrote the time record")
end)

check("condition and payout records only move upward", function()
	local records = Achievements.defaultRecords()
	Achievements.applyRun(records, "Delivered", 70, 100, 200)
	Achievements.applyRun(records, "Delivered", 40, 100, 90)
	assert(records.bestConditionPct == 70, "A worse condition took the record")
	assert(records.bestPayout == 200, "A smaller payout took the record")

	local beaten = Achievements.applyRun(records, "Delivered", 100, 100, 400)
	assert(table.find(beaten, "bestConditionPct"), "A better condition was not reported")
	assert(table.find(beaten, "bestPayout"), "A bigger payout was not reported")
	-- Out-of-range measurements are clamped rather than trusted.
	Achievements.applyRun(records, "Delivered", 500, 100, 10)
	assert(records.bestConditionPct == 100, "Condition was not clamped to 100")
end)

check("badges are earned by what happened, and fail closed until configured", function()
	local earned = Achievements.earnedBy("Delivered", 100, 2, true)
	assert(table.find(earned, "FirstDelivery"), "A delivery earned no first-delivery badge")
	assert(table.find(earned, "SpotlessDelivery"), "A perfect delivery earned no badge")
	assert(table.find(earned, "SavedIt"), "Delivering after a break earned no badge")
	assert(table.find(earned, "TookTheRisk"), "Completing the risky card earned no badge")

	assert(#Achievements.earnedBy("TruckWrecked", 100, 0, true) == 0, "A wreck earned a badge")
	assert(
		not table.find(Achievements.earnedBy("Delivered", 99, 0, false), "SpotlessDelivery"),
		"99% counted as spotless"
	)

	for _, key in earned do
		assert(Achievements.badge(key), "Earned a badge key that is not in the list: " .. key)
	end
	for _, badge in Achievements.Badges do
		assert(badge.label ~= "" and badge.description ~= "", badge.key .. " is missing its copy")
	end
	assert(#Achievements.awardable() == 0, "A badge is configured; update this check when ids are real")
end)

check("every record the result screen can announce has words", function()
	local records = Achievements.defaultRecords()
	for key in records do
		assert(Achievements.RecordLabel[key], "Record " .. key .. " has no label for the result screen")
	end
end)

-- ---------------------------------------------------------------- the road

--[[
	The road the game is actually played on, checked without Studio.

	Until the plan became data this was impossible: the geometry lived inside an
	engine module, so the only level in the game was the least testable thing in
	the repository. The route's own shape decides where every corner, descent
	and bridge is, and therefore where difficulty lands.
]]
check("route one builds and measures the road it always did", function()
	local nodes = LabRoute.nodes()
	assert(#nodes > 40, "The route collapsed to " .. #nodes .. " nodes")

	local points, cumulative, surfaces, total = RouteSections.measure(nodes)
	assert(#points == #nodes, "Measurement lost nodes")
	assert(#surfaces == #nodes, "Measurement lost surfaces")

	-- Roughly 3,900 studs, which is what the route was authored and tuned to.
	-- A wide band, because this guards against a section going missing rather
	-- than against a deliberate reshaping.
	assert(total > 3400 and total < 4400, string.format("Route length moved to %d studs", total))

	-- Arc length only ever increases, and the last node is the far end.
	for index = 2, #cumulative do
		assert(cumulative[index] > cumulative[index - 1], "Arc length went backwards at node " .. index)
	end
	assert(math.abs(cumulative[#cumulative] - total) < 1e-6, "The last node is not at the end of the route")
end)

check("the road still has the features difficulty is placed against", function()
	local nodes = LabRoute.nodes()
	local points, cumulative, surfaces, total = RouteSections.measure(nodes)
	local features = RouteFeatures.detect(points, cumulative, surfaces, total)

	assert(
		RouteFeatures.countOf(features, "Corner") >= 3,
		"Three corners were authored; detection found " .. RouteFeatures.countOf(features, "Corner")
	)
	assert(RouteFeatures.countOf(features, "Descent") >= 1, "The long descent was not detected")
	assert(RouteFeatures.countOf(features, "Bridge") >= 1, "The bridge was not detected")

	--[[
		The blind right-hander opened at 0.06 when the director's windows were
		written by hand. If detection stops finding it there, the scripted opener
		fires somewhere else on the road and the first crisis stops being the one
		the route was built around.
	]]
	local firstCorner = RouteFeatures.firstOf(features, "Corner")
	assert(firstCorner and firstCorner < 0.2, "The first corner moved away from the start of the route")

	local descent = RouteFeatures.firstOf(features, "Descent")
	local bridge = RouteFeatures.firstOf(features, "Bridge")
	assert(descent and bridge and descent < bridge, "The descent no longer comes before the bridge")
end)

check("the road narrows as it goes, and the bridge is its tightest point", function()
	local nodes = LabRoute.nodes()
	local opening = nodes[1].width
	local narrowest = math.huge
	local narrowestSurface = ""
	for _, entry in nodes do
		assert(entry.width > 0, "A node has no width")
		if entry.width < narrowest then
			narrowest = entry.width
			narrowestSurface = entry.surface
		end
	end

	assert(opening > narrowest, "The road does not narrow at all")
	-- The bridge is meant to be the moment with no room. If something else gets
	-- tighter, the hardest place on the road moved without anyone deciding to.
	assert(narrowestSurface == "Bridge", "The tightest part of the road is " .. narrowestSurface .. ", not the bridge")
end)

check("only the bridge goes without shoulders", function()
	for _, entry in LabRoute.nodes() do
		if not entry.shoulders then
			assert(
				entry.surface == "Bridge" or entry.width <= 24,
				"A wide road section lost its shoulders: " .. entry.surface
			)
		end
	end
end)

check("a route plan must start somewhere", function()
	assert(#RouteSections.build({}) == 0, "An empty plan produced nodes")
	local ok = pcall(function()
		return RouteSections.build({
			{ kind = RouteSections.Kind.Curve, at = Vector3.new(0, 0, 10), width = 20 },
		})
	end)
	assert(not ok, "A plan opening with a curve was accepted, but a curve has nothing to curve from")

	local unknown = pcall(function()
		return RouteSections.build({ { kind = "Loop", at = Vector3.new(0, 0, 0), width = 20 } })
	end)
	assert(not unknown, "An unknown step kind was silently ignored")
end)

-- ------------------------------------------------------------ route features

--[[
	Build a synthetic route from segments so the detector can be pointed at
	geometry with a known answer. Each segment adds evenly spaced points along a
	heading, optionally descending, optionally surfaced.
]]
local function synthRoute(segments)
	local points = { Vector3.new(0, 0, 0) }
	local surfaces = { "Road" }
	local cumulative = { 0 }
	local total = 0

	for _, segment in segments do
		local steps = segment.steps or 8
		for _ = 1, steps do
			local last = points[#points]
			local nextPoint = last + segment.step
			total += (nextPoint - last).Magnitude
			table.insert(points, nextPoint)
			table.insert(surfaces, segment.surface or "Road")
			table.insert(cumulative, total)
		end
	end
	return points, cumulative, surfaces, math.max(total, 1)
end

check("a straight flat road has no features at all", function()
	local points, cumulative, surfaces, total = synthRoute({
		{ step = Vector3.new(0, 0, 40), steps = 30 },
	})
	local features = RouteFeatures.detect(points, cumulative, surfaces, total)
	assert(#features == 0, "A straight road reported " .. #features .. " features")
end)

check("a corner is found, and found before it arrives", function()
	-- Straight, then a sustained right turn, then straight again.
	local points, cumulative, surfaces, total = synthRoute({
		{ step = Vector3.new(0, 0, 40), steps = 20 },
		{ step = Vector3.new(14, 0, 38), steps = 10 },
		{ step = Vector3.new(40, 0, 0), steps = 20 },
	})
	local features = RouteFeatures.detect(points, cumulative, surfaces, total)
	assert(RouteFeatures.countOf(features, "Corner") >= 1, "The corner was not detected")

	local first = RouteFeatures.firstOf(features, "Corner")
	assert(first, "The corner has no start")
	-- The window opens during the approach straight, not inside the turn. This
	-- is the whole point: pressure applied inside a corner is not a decision.
	local turnStartProgress = cumulative[21] / total
	assert(first < turnStartProgress, "The corner window opens after the corner starts")
end)

check("a descent is found and a climb is not", function()
	local down = {
		synthRoute({
			{ step = Vector3.new(0, 0, 40), steps = 10 },
			{ step = Vector3.new(0, -6, 40), steps = 12 },
			{ step = Vector3.new(0, 0, 40), steps = 10 },
		}),
	}
	local features = RouteFeatures.detect(down[1], down[2], down[3], down[4])
	assert(RouteFeatures.countOf(features, "Descent") >= 1, "The descent was not detected")

	local up = {
		synthRoute({
			{ step = Vector3.new(0, 0, 40), steps = 10 },
			{ step = Vector3.new(0, 6, 40), steps = 12 },
			{ step = Vector3.new(0, 0, 40), steps = 10 },
		}),
	}
	local climbing = RouteFeatures.detect(up[1], up[2], up[3], up[4])
	assert(RouteFeatures.countOf(climbing, "Descent") == 0, "A climb was reported as a descent")
end)

check("a bridge is found from its surface, not its shape", function()
	local points, cumulative, surfaces, total = synthRoute({
		{ step = Vector3.new(0, 0, 40), steps = 10 },
		{ step = Vector3.new(0, 0, 40), steps = 8, surface = "Bridge" },
		{ step = Vector3.new(0, 0, 40), steps = 10 },
	})
	local features = RouteFeatures.detect(points, cumulative, surfaces, total)
	assert(RouteFeatures.countOf(features, "Bridge") == 1, "The bridge was not detected exactly once")
	-- Flat and straight, so it must not also read as a corner or a descent.
	assert(RouteFeatures.countOf(features, "Corner") == 0, "A flat bridge reported a corner")
	assert(RouteFeatures.countOf(features, "Descent") == 0, "A flat bridge reported a descent")
end)

check("a route with no bridge simply never weights bridges", function()
	local points, cumulative, surfaces, total = synthRoute({
		{ step = Vector3.new(0, 0, 40), steps = 20 },
	})
	local features = RouteFeatures.detect(points, cumulative, surfaces, total)
	assert(not RouteFeatures.inKind(features, 0.5, "Bridge"), "A road with no bridge matched a bridge")
	assert(RouteFeatures.firstOf(features, "Bridge") == nil, "A road with no bridge reported one")
end)

check("feature detection survives a degenerate route", function()
	assert(#RouteFeatures.detect({}, {}, {}, 0) == 0, "An empty route produced features")
	assert(
		#RouteFeatures.detect({ Vector3.new(0, 0, 0), Vector3.new(0, 0, 1) }, { 0, 1 }, {}, 1) == 0,
		"A two-point route produced features"
	)
	-- Repeated points have no heading. They must not divide by zero or read as
	-- an infinitely tight corner.
	local repeated = { Vector3.new(0, 0, 0), Vector3.new(0, 0, 0), Vector3.new(0, 0, 0), Vector3.new(0, 0, 0) }
	assert(#RouteFeatures.detect(repeated, { 0, 0, 0, 0 }, {}, 1) == 0, "Stacked points produced a feature")
end)

check("every feature window is ordered and inside the route", function()
	local points, cumulative, surfaces, total = synthRoute({
		{ step = Vector3.new(0, 0, 40), steps = 10 },
		{ step = Vector3.new(14, -6, 38), steps = 12, surface = "Bridge" },
		{ step = Vector3.new(40, 0, 0), steps = 10 },
	})
	local features = RouteFeatures.detect(points, cumulative, surfaces, total)
	assert(#features > 0, "The fixture produced no features to check")

	local previousStart = -1
	for _, feature in features do
		assert(feature.from >= 0 and feature.to <= 1, feature.kind .. " window escapes the route")
		assert(feature.to > feature.from, feature.kind .. " window is empty or inverted")
		assert(feature.from >= previousStart, "Features are not sorted by where they start")
		previousStart = feature.from
	end
end)

-- ------------------------------------------------------------- daily contract

local function dailyFacts(overrides)
	local facts = {
		outcome = "Delivered",
		cargoReadout = 100,
		chassisIntegrity = 100,
		strapBreaks = 0,
		strapRefits = 0,
		throws = 0,
		durationSeconds = 140,
		riskyContract = false,
	}
	for key, value in overrides or {} do
		facts[key] = value
	end
	return facts
end

--[[
	The trap this exists to catch: a daily that can be completed by not
	finishing. An objective phrased around what did not happen -- no strap
	broke, no dent taken -- is trivially satisfied by a truck that never left
	the depot, which would pay players for wrecking on purpose.
]]
check("no daily can be completed without arriving", function()
	for _, outcome in { "TruckWrecked", "CargoLost", "TimeExpired", "Abandoned" } do
		for _, objective in DailyContract.Objectives do
			local facts = dailyFacts({ outcome = outcome, riskyContract = true, strapBreaks = 1 })
			assert(
				not DailyContract.isMet(objective, facts),
				objective.id .. " was completed by a run that ended in " .. outcome
			)
		end
	end
end)

check("the daily changes every day and repeats predictably", function()
	local seen = {}
	for day = 0, #DailyContract.Objectives - 1 do
		local objective = DailyContract.forDay(day)
		assert(objective, "Day " .. day .. " has no objective")
		assert(not seen[objective.id], "The rotation repeats inside one cycle")
		seen[objective.id] = true
		assert(DailyContract.forDay(day) == DailyContract.forDay(day), "The same day gave two different objectives")
		assert(DailyContract.forDay(day + 1) ~= objective, "Two days in a row share an objective")
	end

	-- Every objective is reachable, and the cycle closes.
	assert(DailyContract.forDay(#DailyContract.Objectives) == DailyContract.forDay(0), "The rotation does not cycle")
	-- A clock before the epoch, or a broken one, still resolves to something.
	assert(DailyContract.forDay(-5) ~= nil, "A negative day has no objective")
	assert(DailyContract.dayFromUnix(-100) == 0, "A negative timestamp escaped the clamp")
end)

check("each daily is met by its own run and not by the others", function()
	local matches = {
		Spotless = dailyFacts({ cargoReadout = 92, chassisIntegrity = 40, durationSeconds = 200 }),
		Unbroken = dailyFacts({ cargoReadout = 40, chassisIntegrity = 40, durationSeconds = 200 }),
		Express = dailyFacts({ cargoReadout = 40, chassisIntegrity = 40, durationSeconds = 120 }),
		Straightener = dailyFacts({ cargoReadout = 40, chassisIntegrity = 40, strapBreaks = 2, durationSeconds = 200 }),
		Nerve = dailyFacts({ cargoReadout = 40, chassisIntegrity = 40, riskyContract = true, durationSeconds = 200 }),
		Panelbeater = dailyFacts({ cargoReadout = 40, chassisIntegrity = 95, durationSeconds = 200 }),
	}

	for _, objective in DailyContract.Objectives do
		local facts = matches[objective.id]
		assert(facts, "No fixture for daily " .. objective.id)
		assert(DailyContract.isMet(objective, facts), objective.id .. " rejected the run built to satisfy it")
	end

	-- Unbroken and Straightener are deliberate opposites; nothing should satisfy
	-- both, or the rotation contains a day that is two days.
	local unbroken = DailyContract.byId("Unbroken")
	local straightener = DailyContract.byId("Straightener")
	for _, facts in matches do
		assert(
			not (DailyContract.isMet(unbroken, facts) and DailyContract.isMet(straightener, facts)),
			"One run satisfied both the break and the no-break objective"
		)
	end
end)

check("a daily is claimable once per day and expires by itself", function()
	assert(not DailyContract.isClaimed(nil, 100), "A profile that never claimed reported a claim")
	assert(not DailyContract.isClaimed(0, 100), "A stale claim day counted as today")
	assert(DailyContract.isClaimed(100, 100), "Today's claim was not recognised")
	-- The expiry is the whole reason this is a day number rather than a flag.
	assert(not DailyContract.isClaimed(100, 101), "Yesterday's claim blocked today's bonus")
end)

check("every daily is worth taking a detour for", function()
	local ids = {}
	for _, objective in DailyContract.Objectives do
		assert(not ids[objective.id], "Duplicate daily id: " .. objective.id)
		ids[objective.id] = true
		assert(objective.label ~= "" and objective.brief ~= "", objective.id .. " is missing its copy")
		-- A clean delivery pays about 135. A bonus under that would make the
		-- daily worth less than simply running again, which is not a reason to
		-- come back.
		local cleanRun = LabProgression.rewardFor("Delivered", 100, 100)
		assert(objective.bonus > cleanRun, objective.id .. " pays less than just doing another run")
	end
end)

-- ------------------------------------------------------------------ commerce

--[[
	The line the design draws: paint changes a colour, and nothing sold may
	change how the truck behaves. This is the check that fails if a grant kind
	for grip, strap strength or timing windows ever appears.
]]
check("nothing on sale grants an advantage", function()
	for _, product in Commerce.Catalog do
		assert(
			Commerce.CosmeticGrants[product.grant.kind],
			product.key .. " sells a grant kind that is not cosmetic: " .. tostring(product.grant.kind)
		)
	end
	assert(not Commerce.CosmeticGrants.Grip, "Grip became sellable")
	assert(not Commerce.CosmeticGrants.StrapStrength, "Strap strength became sellable")
end)

--[[
	Shipping the pipeline ahead of the catalogue only works if an unconfigured
	product is inert. A placeholder id of zero must never be offered, matched or
	prompted, and with every id currently zero, id lookup must not collapse them
	all onto whichever entry happens to be first.
]]
check("an unconfigured product is completely inert", function()
	for _, product in Commerce.Catalog do
		if not Commerce.isConfigured(product) then
			assert(Commerce.byAssetId(product.assetId, product.kind) == nil, product.key .. " matched on a zero id")
		end
	end
	assert(Commerce.byAssetId(0, "Product") == nil, "A zero asset id resolved to a product")
	assert(Commerce.byAssetId(nil, "Product") == nil, "A missing asset id resolved to a product")
	assert(Commerce.byAssetId(-5, "Pass") == nil, "A negative asset id resolved to a product")

	for _, product in Commerce.purchasable() do
		assert(Commerce.isConfigured(product), "purchasable() offered an unconfigured product")
	end
end)

check("the catalogue is internally consistent", function()
	local keys = {}
	for _, product in Commerce.Catalog do
		assert(product.key ~= "", "A product has no key")
		assert(not keys[product.key], "Duplicate product key: " .. product.key)
		keys[product.key] = true
		assert(product.kind == "Product" or product.kind == "Pass", product.key .. " has an unknown kind")
		assert(product.label ~= "" and product.description ~= "", product.key .. " is missing storefront copy")
		assert(Commerce.byKey(product.key) == product, product.key .. " is not findable by its own key")
		if product.grant.kind == "Credits" then
			assert((product.grant.amount or 0) > 0, product.key .. " grants no credits")
		end
	end
	assert(Commerce.byKey(nil) == nil, "A missing key resolved to a product")
	assert(Commerce.byKey("NotAProduct") == nil, "An unknown key resolved to a product")
end)

--[[
	ProcessReceipt fires more than once for the same sale, and on a different
	server if the first never confirmed. Recognising a repeat is the whole
	defence against granting twice for one payment.
]]
check("a repeated receipt is recognised, not granted twice", function()
	local history = {}
	assert(Commerce.appendReceipt(history, "purchase-1"), "A new receipt was treated as a repeat")
	assert(not Commerce.appendReceipt(history, "purchase-1"), "A repeated receipt was treated as new")
	assert(#history == 1, "A repeated receipt was recorded twice")
	assert(Commerce.hasReceipt(history, "purchase-1"), "A granted receipt was forgotten")
	assert(not Commerce.hasReceipt(history, "purchase-2"), "An ungranted receipt was reported as granted")

	assert(Commerce.appendReceipt(history, "purchase-2"), "A second distinct receipt was rejected")
	assert(#history == 2, "A distinct receipt was not recorded")
end)

--[[
	The history lives inside a DataStore value with a size limit, so it cannot
	grow without end. Dropping the oldest is safe: Roblox stops retrying a
	receipt long before the same player buys another sixty-four things.
]]
check("receipt history is bounded and drops the oldest first", function()
	local history = {}
	for index = 1, Commerce.MaxReceiptHistory + 10 do
		Commerce.appendReceipt(history, "purchase-" .. tostring(index))
	end
	assert(#history == Commerce.MaxReceiptHistory, "Receipt history grew past its bound")
	assert(not Commerce.hasReceipt(history, "purchase-1"), "The oldest receipt was not the one dropped")
	assert(
		Commerce.hasReceipt(history, "purchase-" .. tostring(Commerce.MaxReceiptHistory + 10)),
		"The newest receipt was dropped"
	)
end)

-- ------------------------------------------------------------ contract board

check("the board always offers a real decision", function()
	for run = 2, 9 do
		local offer = RunVariants.offer(run, (run % 3) / 3, ((run + 1) % 3) / 3, (run % 2) / 2)
		assert(offer.runNumber == run, "Offer forgot which run it is for")
		assert(offer.safe.contract.id == "Standard", "The safe card asks for something extra")
		assert(offer.safe.difficulty.id == "Normal", "The safe card is not the calm one")
		assert(offer.risky.difficulty.id == "Catastrophe", "The risky card is not under pressure")
		assert(offer.risky.contract.id ~= "Standard", "The risky card asks for nothing extra")
		assert(
			offer.safe.openingWeakStrap == offer.risky.openingWeakStrap,
			"The weak strap is part of the run, not part of the choice"
		)
	end
end)

--[[
	The gamble has to be worth taking. Failing the risky contract still pays its
	difficulty bonus, so the risky card is never worse on arrival; the cost is
	the chance of not arriving. If that stopped being true the board would be a
	menu with one correct answer.
]]
check("the risky card pays more whether or not its contract lands", function()
	local offer = RunVariants.offer(2, 0, 0, 0)
	local safeMet = RunVariants.rewardMultiplier(offer.safe, true)
	local riskyMet = RunVariants.rewardMultiplier(offer.risky, true)
	local riskyMissed = RunVariants.rewardMultiplier(offer.risky, false)

	assert(riskyMet > safeMet, "Completing the risky contract pays no better than the safe one")
	assert(riskyMissed > safeMet, "Missing the risky contract pays worse than never taking it")
	assert(riskyMet > riskyMissed, "The risky contract's own bonus does not reward completing it")
end)

check("a vote that does not resolve takes the safe card", function()
	local Choice = RunVariants.Choice
	local decided, safe, risky = RunVariants.tally({}, 4)
	assert(decided == Choice.Safe and safe == 0 and risky == 0, "An empty board did not default to safe")

	decided = RunVariants.tally({ [1] = Choice.Risky, [2] = Choice.Safe }, 2)
	assert(decided == Choice.Safe, "A tie did not default to safe")

	decided = RunVariants.tally({ [1] = Choice.Risky, [2] = Choice.Risky, [3] = Choice.Safe }, 3)
	assert(decided == Choice.Risky, "A majority for risky was not honoured")

	decided, safe, risky = RunVariants.tally({ [1] = Choice.Risky, [2] = "Nonsense" }, 1)
	assert(decided == Choice.Risky and safe == 0 and risky == 1, "An unparsable vote was counted")
end)

check("abstentions cannot force the crew into the risky card", function()
	local Choice = RunVariants.Choice
	local decided = RunVariants.tally({ [1] = Choice.Risky }, 4)
	assert(decided == Choice.Safe, "One voter forced three abstaining crew members into Risky")

	decided = RunVariants.tally({ [1] = Choice.Risky, [2] = Choice.Risky, [3] = Choice.Safe }, 4)
	assert(decided == Choice.Safe, "Half the crew was treated as a strict majority")

	decided = RunVariants.tally({ [1] = Choice.Risky, [2] = Choice.Risky, [3] = Choice.Risky, [4] = Choice.Safe }, 4)
	assert(decided == Choice.Risky, "Three of four crew members could not choose Risky")

	decided = RunVariants.tally({ [1] = Choice.Risky }, 1)
	assert(decided == Choice.Risky, "A solo player could not choose Risky")
end)

check("only declared choices are accepted", function()
	assert(RunVariants.isChoice(RunVariants.Choice.Safe), "Safe is not a choice")
	assert(RunVariants.isChoice(RunVariants.Choice.Risky), "Risky is not a choice")
	assert(not RunVariants.isChoice(nil), "nil is a choice")
	assert(not RunVariants.isChoice("safe"), "Choices are case-sensitive identifiers")
	assert(not RunVariants.isChoice(""), "The empty string is a choice")
end)

check("the chosen card is the one the crew voted for", function()
	local offer = RunVariants.offer(3, 0.5, 0.9, 0.7)
	assert(RunVariants.variantFor(offer, RunVariants.Choice.Risky) == offer.risky, "Risky vote took the safe card")
	assert(RunVariants.variantFor(offer, RunVariants.Choice.Safe) == offer.safe, "Safe vote took the risky card")
	assert(RunVariants.variantFor(offer, nil) == offer.safe, "A missing decision did not fall back to safe")
	assert(RunVariants.variantFor(offer, "Nonsense") == offer.safe, "An unknown decision did not fall back to safe")
end)

check("respawns never attach to a wreck or result-phase truck", function()
	assert(not LabRespawnPolicy.shouldAttach("Result", false, 0, -200), "Result truck accepted a respawn")
	assert(not LabRespawnPolicy.shouldAttach("Run", true, 0, -200), "Wrecked truck accepted a respawn")
	assert(not LabRespawnPolicy.shouldAttach("Run", false, -180, -200), "Descending void truck accepted a respawn")
	assert(LabRespawnPolicy.shouldAttach("Staging", false, 0, -200), "Safe staging truck rejected a respawn")
	assert(LabRespawnPolicy.shouldAttach("Run", false, 0, -200), "Safe mid-run truck rejected a respawn")
	assert(LabRespawnPolicy.shouldAttach("Staging", false, -175, -200), "Staging truck above void buffer rejected")
end)

check("staging rebuilds after wreck, cargo loss, step fail, or incomplete rig", function()
	assert(
		LabRigPolicy.shouldRebuildRig({
			outcome = "TruckWrecked",
			stepFailed = false,
			hasChassis = true,
			hasCargo = true,
			wrecked = false,
			wheelsOk = true,
			cargoOk = true,
		}),
		"TruckWrecked must rebuild"
	)
	assert(
		LabRigPolicy.shouldRebuildRig({
			outcome = "CargoLost",
			stepFailed = false,
			hasChassis = true,
			hasCargo = true,
			wrecked = false,
			wheelsOk = true,
			cargoOk = true,
		}),
		"CargoLost must rebuild"
	)
	assert(
		LabRigPolicy.shouldRebuildRig({
			outcome = "Delivered",
			stepFailed = true,
			hasChassis = true,
			hasCargo = true,
			wrecked = false,
			wheelsOk = true,
			cargoOk = true,
		}),
		"stepFailed must rebuild"
	)
	assert(
		LabRigPolicy.shouldRebuildRig({
			outcome = "Delivered",
			stepFailed = false,
			hasChassis = true,
			hasCargo = true,
			wrecked = false,
			wheelsOk = false,
			cargoOk = true,
		}),
		"Incomplete wheels must rebuild"
	)
	assert(
		LabRigPolicy.shouldRebuildRig({
			outcome = "Delivered",
			stepFailed = false,
			hasChassis = true,
			hasCargo = true,
			wrecked = false,
			wheelsOk = true,
			cargoOk = false,
		}),
		"Incomplete cargo must rebuild"
	)
	assert(not LabRigPolicy.shouldRebuildRig({
		outcome = "Delivered",
		stepFailed = false,
		hasChassis = true,
		hasCargo = true,
		wrecked = false,
		wheelsOk = true,
		cargoOk = true,
	}), "Clean delivery must keep in-place reset")
end)

check("cargo offset thresholds are strictly increasing", function()
	assert(LabConfig.ShiftedOffset < LabConfig.SlidingOffset, "Shifted must be under Sliding")
	assert(LabConfig.SlidingOffset < LabConfig.HangingOffset, "Sliding must be under Hanging")
	assert(LabConfig.HangingOffset < LabConfig.LostOffset, "Hanging must be under Lost")
end)

check("delivery and rollover thresholds are sane", function()
	assert(LabConfig.DeliveryAcceptRadius > 0, "Delivery radius must be positive")
	assert(LabConfig.DeliveryMaxSpeed > 0, "Delivery max speed must be positive")
	assert(LabConfig.DeliveryCleanReadout > 0 and LabConfig.DeliveryCleanReadout <= 100, "Clean readout out of range")
	assert(LabConfig.LostSeparationStuds > LabConfig.LostOffset, "World separation must exceed local lost offset")
	assert(LabConfig.RolloverUpDot > 0 and LabConfig.RolloverUpDot < 1, "Rollover up-dot out of range")
	assert(LabConfig.RolloverSeconds > 0, "Rollover duration must be positive")
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

check("camera road feedback is quiet below its speed ramp", function()
	assert(LabConfig.CameraShakeSpeedFull > LabConfig.CameraShakeSpeedStart, "Camera speed ramp is inverted")
	assert(LabConfig.CameraImpactAccelFull > LabConfig.CameraImpactAccelStart, "Camera impact ramp is inverted")
	assert(LabConfig.CameraMotionStaleSeconds > LabConfig.CameraLeadSeconds, "Motion would expire before its lead cap")
	local amount = CameraFeedback.target(
		LabConfig.CameraShakeSpeedStart - 1,
		"Rough",
		LabConfig.CameraShakeSuspensionFull,
		LabConfig.CameraShakeGradeFullDeg,
		LabConfig
	)
	assert(amount == 0, "A parked or crawling truck should not inherit full road shake")
end)

check("camera feedback rises with speed and surface severity", function()
	local midSpeed = (LabConfig.CameraShakeSpeedStart + LabConfig.CameraShakeSpeedFull) * 0.5
	local slow = CameraFeedback.target(midSpeed, "Road", 0, 0, LabConfig)
	local rough = CameraFeedback.target(midSpeed, "Rough", 0, 0, LabConfig)
	local fast = CameraFeedback.target(LabConfig.CameraShakeSpeedFull, "Rough", 0, 0, LabConfig)
	assert(rough > slow, "Rough road must read more strongly than asphalt")
	assert(fast > rough, "The same rough road must ramp with speed")
end)

check("camera impact kick is bounded and thresholded", function()
	assert(CameraFeedback.impact(LabConfig.CameraImpactAccelStart - 1, LabConfig) == 0, "Small motion became an impact")
	assert(CameraFeedback.impact(LabConfig.CameraImpactAccelFull + 1, LabConfig) == 1, "Heavy impact did not saturate")
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

-- --------------------------------------------------------------------- done

print(string.format("\n%d checks, %d failed", checks, failures))
if failures > 0 then
	process.exit(1)
end
