--!strict

--[[
	Engine-free run variation policy. The server rolls one authoritative card
	for the next delivery, while the client only receives the descriptive
	fields it needs to present that card.

	Run one is intentionally fixed: a new player should learn the truck before
	the contract system starts asking them to reinterpret it. Later runs combine
	a cargo shape, a contract, a pressure profile, and a different weak strap.
]]

export type CargoVariant = {
	id: string,
	label: string,
	description: string,
	scaleX: number,
	scaleY: number,
	scaleZ: number,
	density: number,
}

export type Contract = {
	id: string,
	label: string,
	brief: string,
	timeLimit: number,
	minimumReadout: number,
	rewardMultiplier: number,
}

export type Difficulty = {
	id: string,
	label: string,
	intervalScale: number,
	pressureScale: number,
	rewardMultiplier: number,
}

export type RunVariant = {
	cargo: CargoVariant,
	contract: Contract,
	difficulty: Difficulty,
	openingWeakStrap: string,
}

local CARGOS: { CargoVariant } = {
	{
		id = "GeneralFreight",
		label = "GENERAL FREIGHT",
		description = "Balanced crate with familiar handling.",
		scaleX = 1,
		scaleY = 1,
		scaleZ = 1,
		density = 2.6,
	},
	{
		id = "TowerLoad",
		label = "TOWER LOAD",
		description = "Tall center of mass. Corners punish speed.",
		scaleX = 0.84,
		scaleY = 1.38,
		scaleZ = 0.84,
		density = 2.15,
	},
	{
		id = "CompactGenerator",
		label = "COMPACT GENERATOR",
		description = "Dense low cargo. Heavy impacts upset the truck.",
		scaleX = 0.9,
		scaleY = 0.76,
		scaleZ = 0.9,
		density = 4.6,
	},
}

local CONTRACTS: { Contract } = {
	{
		id = "Standard",
		label = "STANDARD DELIVERY",
		brief = "Get the load to the depot.",
		timeLimit = 210,
		minimumReadout = 0,
		rewardMultiplier = 1,
	},
	{
		id = "Fragile",
		label = "FRAGILE CONTRACT",
		brief = "Finish with cargo condition at 75% or better.",
		timeLimit = 210,
		minimumReadout = 75,
		rewardMultiplier = 1.3,
	},
	{
		id = "Express",
		label = "EXPRESS CONTRACT",
		brief = "Reach the depot before the short clock expires.",
		timeLimit = 165,
		minimumReadout = 0,
		rewardMultiplier = 1.25,
	},
}

local DIFFICULTIES: { Difficulty } = {
	{
		id = "Normal",
		label = "NORMAL",
		intervalScale = 1,
		pressureScale = 1,
		rewardMultiplier = 1,
	},
	{
		id = "Catastrophe",
		label = "CATASTROPHE",
		intervalScale = 0.72,
		pressureScale = 1.15,
		rewardMultiplier = 1.35,
	},
}

local WEAK_STRAPS = { "FR", "RL", "FL", "RR" }

local RunVariants = {}

local function indexFromRoll(roll: number?, count: number): number
	local value = math.clamp(roll or 0, 0, 0.999999)
	return math.floor(value * count) + 1
end

function RunVariants.select(
	runNumber: number,
	cargoRoll: number?,
	contractRoll: number?,
	difficultyRoll: number?
): RunVariant
	local safeRun = math.max(1, math.floor(runNumber))
	if safeRun == 1 then
		return {
			cargo = CARGOS[1],
			contract = CONTRACTS[1],
			difficulty = DIFFICULTIES[1],
			openingWeakStrap = "FR",
		}
	end

	return {
		cargo = CARGOS[indexFromRoll(cargoRoll, #CARGOS)],
		contract = CONTRACTS[indexFromRoll(contractRoll, #CONTRACTS)],
		difficulty = if (difficultyRoll or 1) < 0.35 then DIFFICULTIES[2] else DIFFICULTIES[1],
		openingWeakStrap = WEAK_STRAPS[((safeRun - 1) % #WEAK_STRAPS) + 1],
	}
end

function RunVariants.contractMet(variant: RunVariant, outcome: string, cargoReadout: number): boolean
	local arrived = outcome == "Delivered" or outcome == "PartialLoss"
	return arrived and math.clamp(cargoReadout, 0, 100) >= variant.contract.minimumReadout
end

function RunVariants.rewardMultiplier(variant: RunVariant, contractMet: boolean): number
	local contractMultiplier = if contractMet then variant.contract.rewardMultiplier else 1
	return variant.difficulty.rewardMultiplier * contractMultiplier
end

function RunVariants.cargos(): { CargoVariant }
	return table.clone(CARGOS)
end

function RunVariants.contracts(): { Contract }
	return table.clone(CONTRACTS)
end

return RunVariants
