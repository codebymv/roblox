--!strict

--[[
	How hard something just hit, as one shared answer.

	The thresholds lived inside LabSFX, which was fine while sound was the only
	thing that reacted to damage. It is not any more: the particle layer has to
	agree with the audio about whether a hit was heavy, or a run produces a
	light scuff sound over a heavy debris burst and the player learns to trust
	neither.

	Engine-free, so the headless suite can hold the ordering.
]]

local ImpactTiers = {}

export type Tier = "Light" | "Medium" | "Heavy"

ImpactTiers.Order = { "Light", "Medium", "Heavy" }

-- Points of cargo condition lost in one snapshot step.
ImpactTiers.CargoMedium = 3
ImpactTiers.CargoHeavy = 8

-- Points of chassis integrity lost in one snapshot step. Higher than the cargo
-- thresholds because the truck has more integrity to give and loses it in
-- bigger pieces.
ImpactTiers.ChassisMedium = 4
ImpactTiers.ChassisHeavy = 10

-- Below this, nothing fired at all. A run bleeds fractions of a point
-- constantly and reacting to every one would be a permanent rattle.
ImpactTiers.Minimum = 1

local function classify(loss: number, medium: number, heavy: number): Tier?
	if loss < ImpactTiers.Minimum then
		return nil
	end
	if loss >= heavy then
		return "Heavy"
	end
	if loss >= medium then
		return "Medium"
	end
	return "Light"
end

function ImpactTiers.cargo(loss: number): Tier?
	return classify(loss, ImpactTiers.CargoMedium, ImpactTiers.CargoHeavy)
end

function ImpactTiers.chassis(loss: number): Tier?
	return classify(loss, ImpactTiers.ChassisMedium, ImpactTiers.ChassisHeavy)
end

return ImpactTiers
