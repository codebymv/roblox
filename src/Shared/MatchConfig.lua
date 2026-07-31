--!strict

local MatchConfig = {
	-- Depot
	BayCount = 4,
	CrewCapacity = 4,
	LaneSpacingStuds = 150,
	MinPlayersToStart = 1,
	IdealPartySize = 4,

	-- Pacing
	DepartCountdownSeconds = 3,
	-- A lone player should be driving inside ten seconds of spawning; a forming
	-- crew gets longer so friends can actually gather.
	SoloAutoDepartSeconds = 5,
	AutoDepartSeconds = 14,
	ResolveDisplaySeconds = 7,
	CargoRevealSeconds = 3,

	--[[
		The leg ladder. Each delivered leg raises the multiplier and the pressure
		and shortens the clock, so leg 5 is a genuinely different game than leg 1
		without any new content.
	]]
	LegBaseDurationSeconds = 105,
	LegDurationDecayPerLeg = 7,
	LegMinDurationSeconds = 62,
	LegPressurePerLeg = 0.22,
	LegMaxPressure = 3.2,
	LegWindowScalePerLeg = 0.05,
	LegMinWindowScale = 0.55,

	-- Payout curve. Carried value is the sum of leg values and is lost on a wipe.
	LegPayoutBase = 120,
	LegPayoutGrowth = 1.6,
	DecisionSeconds = 12,
	DailyBonusCredits = 250,

	-- Driving
	MaxTruckSpeed = 28,
	SafeCornerSpeed = 13,
	RouteLengthStuds = 260,

	-- Route beats, expressed as fractions of the leg.
	SpotterWarningProgress = 0.24,
	SharpTurnProgress = 0.34,
	RandomFailureStartProgress = 0.52,
	DeliveryHoldProgress = 0.82,
	TutorialStrapProgress = 0.08,

	-- Failure cadence
	FailureMinIntervalSeconds = 12,
	FailureMaxIntervalSeconds = 22,
	StrapWindowSeconds = 8,
	RepairWindowSeconds = 8,
	CargoDumpFailThreshold = 3,

	-- Truck integrity, separate from the cargo tip meter.
	MaxTruckIntegrity = 100,
	RepairIntegrityRestore = 18,
	RepairDamageThreshold = 5,
	TruckDamagePerCascade = 22,
	OffRoadTruckDamagePerSecond = 6,

	-- Pressure: interval /= pressure; windows *= windowScale.
	BaseFailurePressure = 1,
	DeliveryHoldPressure = 1.75,
	DeliveryHoldWindowScale = 0.7,
}

-- Deeper legs are shorter, which is what makes the push feel like a real bet.
function MatchConfig.legDuration(leg: number): number
	local decayed = MatchConfig.LegBaseDurationSeconds
		- (math.max(1, leg) - 1) * MatchConfig.LegDurationDecayPerLeg
	return math.max(MatchConfig.LegMinDurationSeconds, decayed)
end

function MatchConfig.legPressure(leg: number): number
	local pressure = MatchConfig.BaseFailurePressure
		+ (math.max(1, leg) - 1) * MatchConfig.LegPressurePerLeg
	return math.min(MatchConfig.LegMaxPressure, pressure)
end

function MatchConfig.legWindowScale(leg: number): number
	local scale = 1 - (math.max(1, leg) - 1) * MatchConfig.LegWindowScalePerLeg
	return math.max(MatchConfig.LegMinWindowScale, scale)
end

return MatchConfig
