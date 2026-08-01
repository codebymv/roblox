--!strict

--[[
	Why a run ended, as identifiers rather than prose.

	`PhysicsChassis.lastCause` used to be read three ways at once: printed on the
	debug overlay, substring-matched into an analytics bucket, and used as a table
	key for the player-facing wreck explanation. It looked like log text, so
	nothing stopped it being reworded — and rewording it would have silently
	emptied an analytics category and silently dropped the sentence that tells a
	player what they did wrong. Neither failure raises anything.

	The identifiers below are that contract. Producers set one of these, both
	consumers key off the same constants, and the mapping to a bucket is a table
	lookup rather than a search for "roll" inside a sentence.

	Values are deliberately the strings the old code already emitted, so existing
	dashboard breakdowns and captured runs keep lining up.
]]

local RunCauses = {}

-- What wrecked the truck. Set by PhysicsChassis, shown to the player by LabUI,
-- and bucketed for analytics below.
export type WreckCause = "rolled" | "fell" | "impact"

RunCauses.Wreck = {
	Rolled = "rolled" :: WreckCause,
	Fell = "fell" :: WreckCause,
	Impact = "impact" :: WreckCause,
}

-- Iteration order for tests and for anything that needs to enumerate them.
local WRECK_ORDER: { WreckCause } = { "rolled", "fell", "impact" }
RunCauses.WreckOrder = WRECK_ORDER

--[[
	What the result screen tells the player. It lives beside the identifiers
	rather than in LabUI because it is the other half of the same contract: a
	cause with no explanation is a wreck the player cannot learn from, and that
	is only catchable by a test if both halves are in one testable place.
]]
-- Keyed by plain string rather than WreckCause so a strict consumer can index
-- it with a snapshot field without a cast. The headless suite is what enforces
-- that every key is a cause something can actually produce.
local WRECK_EXPLANATION: { [string]: string } = {
	rolled = "Upside down too long.",
	fell = "Dropped off the road edge. Bridge and shoulders count.",
	impact = "Integrity hit zero. Stay on asphalt, ease off the shoulder.",
}
RunCauses.WreckExplanation = WRECK_EXPLANATION

--[[
	Said when the cause is missing or is one this build does not have copy for.

	The result screen is the only place a wreck is ever explained, so falling
	silent there costs the player the lesson entirely. Generic advice that is
	true of every wreck beats an empty panel, and it degrades gracefully if a
	later build starts producing a cause this one has never heard of.
]]
local UNKNOWN_WRECK_EXPLANATION =
	"The truck did not survive the route. Ease off into corners and keep the load centred."
RunCauses.UnknownWreckExplanation = UNKNOWN_WRECK_EXPLANATION

function RunCauses.explain(wreckCause: string?): string
	if wreckCause == nil then
		return UNKNOWN_WRECK_EXPLANATION
	end
	return WRECK_EXPLANATION[wreckCause] or UNKNOWN_WRECK_EXPLANATION
end

--[[
	The analytics breakdown. Coarser than the wreck cause on purpose: this is the
	field a dashboard segments by, so it has to stay small and stable even as the
	simulation grows more ways to lose a truck.
]]
export type Bucket = "Delivery" | "CargoLost" | "TimeExpired" | "Rollover" | "Fall" | "Collision" | "TruckDamage"

local WRECK_BUCKET: { [string]: Bucket } = {
	rolled = "Rollover",
	fell = "Fall",
	impact = "Collision",
}

-- A wreck with no recorded cause still has to land somewhere countable.
local UNKNOWN_WRECK_BUCKET: Bucket = "TruckDamage"
RunCauses.UnknownWreckBucket = UNKNOWN_WRECK_BUCKET

function RunCauses.isWreckCause(value: string?): boolean
	return value ~= nil and WRECK_BUCKET[value] ~= nil
end

--[[
	Outcome plus wreck cause to a single breakdown value.

	Non-wreck outcomes never consult the cause: a delivered run has a `lastCause`
	left over from whatever last happened to the load, and reading it here is how
	the old substring version could have mislabelled a clean delivery.
]]
function RunCauses.bucket(outcome: string, wreckCause: string?): string
	if outcome == "Delivered" or outcome == "PartialLoss" then
		return "Delivery"
	elseif outcome == "CargoLost" then
		return "CargoLost"
	elseif outcome == "TimeExpired" then
		return "TimeExpired"
	elseif outcome ~= "TruckWrecked" then
		-- Abandoned, and anything a later phase machine adds, pass through.
		return outcome
	end

	if wreckCause == nil then
		return UNKNOWN_WRECK_BUCKET
	end
	return WRECK_BUCKET[wreckCause] or UNKNOWN_WRECK_BUCKET
end

return RunCauses
