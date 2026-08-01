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
local AudioMix = loadShared("AudioMix")
local ImpactTiers = loadShared("ImpactTiers")
local VfxSpec = loadShared("VfxSpec")
local PresentationMath = loadShared("PresentationMath")
local CrewRotation = loadShared("CrewRotation")
local LabProgression = loadShared("LabProgression")
local LabRespawnPolicy = loadShared("LabRespawnPolicy")
local RunVariants = loadShared("RunVariants")
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
