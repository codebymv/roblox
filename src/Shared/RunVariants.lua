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

--[[
	The contract board. Two cards, offered after a run, decided by the crew.

	The eighteen later-run combinations already existed and were already shown
	on the HUD; what was missing is that the server picked. A run the crew chose
	badly is a story, and a run the server chose badly is a complaint, even when
	they are the same run.

	Deliberately two cards rather than three. The decision has to fit inside a
	result screen and stay a conversation rather than a menu, and a crew of four
	needs a majority that resolves.
]]
export type OfferChoice = "Safe" | "Risky"

export type ContractOffer = {
	runNumber: number,
	safe: RunVariant,
	risky: RunVariant,
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

RunVariants.Choice = {
	Safe = "Safe" :: OfferChoice,
	Risky = "Risky" :: OfferChoice,
}

-- A vote that does not resolve takes the safe card. Ties, an empty board, and
-- a crew that ignored the screen all mean the same thing: nobody asked for the
-- gamble, so do not hand them one.
local DEFAULT_CHOICE: OfferChoice = "Safe"
RunVariants.DefaultChoice = DEFAULT_CHOICE

local function indexFromRoll(roll: number?, count: number): number
	local value = math.clamp(roll or 0, 0, 0.999999)
	return math.floor(value * count) + 1
end

local function byId(list, id: string)
	for _, entry in list do
		if entry.id == id then
			return entry
		end
	end
	-- Looking the cards up by id rather than by index means reordering the
	-- tables above cannot silently change what the board offers.
	error("RunVariants is missing a required entry: " .. id)
end

local function weakStrapFor(runNumber: number): string
	return WEAK_STRAPS[((math.max(1, math.floor(runNumber)) - 1) % #WEAK_STRAPS) + 1]
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
		openingWeakStrap = weakStrapFor(safeRun),
	}
end

--[[
	Build the two cards for a run.

	The safe card is a plain delivery: ordinary clock, no condition floor,
	baseline pay. The risky card always pairs Catastrophe pressure with a
	contract that asks for something specific, so the two axes of the gamble
	read as one decision rather than two sliders.

	Cargo rolls independently on each card, because the shape of the load is the
	part worth talking about and holding it constant would make both cards look
	like the same job at two prices.

	The opening weak strap is shared. It follows the run number and is not part
	of what the crew is choosing between.
]]
function RunVariants.offer(
	runNumber: number,
	safeCargoRoll: number?,
	riskyCargoRoll: number?,
	riskyContractRoll: number?
): ContractOffer
	local safeRun = math.max(1, math.floor(runNumber))
	local weakStrap = weakStrapFor(safeRun)
	local riskyContracts = { byId(CONTRACTS, "Fragile"), byId(CONTRACTS, "Express") }

	return {
		runNumber = safeRun,
		safe = {
			cargo = CARGOS[indexFromRoll(safeCargoRoll, #CARGOS)],
			contract = byId(CONTRACTS, "Standard"),
			difficulty = byId(DIFFICULTIES, "Normal"),
			openingWeakStrap = weakStrap,
		},
		risky = {
			cargo = CARGOS[indexFromRoll(riskyCargoRoll, #CARGOS)],
			contract = riskyContracts[indexFromRoll(riskyContractRoll, #riskyContracts)],
			difficulty = byId(DIFFICULTIES, "Catastrophe"),
			openingWeakStrap = weakStrap,
		},
	}
end

function RunVariants.isChoice(value: string?): boolean
	return value == RunVariants.Choice.Safe or value == RunVariants.Choice.Risky
end

function RunVariants.variantFor(offer: ContractOffer, choice: string?): RunVariant
	return if choice == RunVariants.Choice.Risky then offer.risky else offer.safe
end

--[[
	Majority wins; anything else takes the safe card. Votes are whatever the
	session has collected, keyed however it likes, so this stays a pure count.
]]
function RunVariants.tally(votes: { [any]: string }): (OfferChoice, number, number)
	local safe, risky = 0, 0
	for _, choice in votes do
		if choice == RunVariants.Choice.Risky then
			risky += 1
		elseif choice == RunVariants.Choice.Safe then
			safe += 1
		end
	end

	if risky > safe then
		return RunVariants.Choice.Risky, safe, risky
	end
	return DEFAULT_CHOICE, safe, risky
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
