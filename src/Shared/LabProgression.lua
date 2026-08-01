--!strict

--[[
	Engine-free reward policy for the current physics run.

	The server owns the inputs and the profile write. Keeping the arithmetic in
	a shared, dependency-free module makes the economy easy to test without
	Studio and prevents the result UI from inventing its own payout.
]]

local BASE_REWARD: { [string]: number } = {
	Delivered = 90,
	PartialLoss = 55,
	CargoLost = 15,
	TruckWrecked = 15,
	TimeExpired = 20,
}

local QUALITY_SCALE: { [string]: number } = {
	Delivered = 1,
	PartialLoss = 0.5,
}

local LabProgression = {}

function LabProgression.rewardFor(
	outcome: string,
	cargoReadout: number,
	chassisIntegrity: number,
	rewardMultiplier: number?
): number
	local base = BASE_REWARD[outcome]
	if not base then
		return 0
	end

	local scale = QUALITY_SCALE[outcome] or 0
	local cargoBonus = math.clamp(cargoReadout, 0, 100) * 0.3 * scale
	local truckBonus = math.clamp(chassisIntegrity, 0, 100) * 0.15 * scale
	local multiplier = math.clamp(rewardMultiplier or 1, 0.5, 3)
	return math.floor((base + cargoBonus + truckBonus) * multiplier + 0.5)
end

function LabProgression.isSuccessful(outcome: string): boolean
	return outcome == "Delivered" or outcome == "PartialLoss"
end

return LabProgression
