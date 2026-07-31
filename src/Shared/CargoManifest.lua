--!strict

--[[
	The manifest is our variance surface. Each leg rolls one cargo with a rarity,
	a value multiplier, and exactly one mechanical quirk.

	Two rules keep this from becoming a slot machine:
	1. Rarity odds only improve as the convoy pushes deeper, so the jackpot is a
	   reward for greed rather than something you can reroll on leg 1.
	2. Nothing here is purchasable. It is variance inside a run, not a paid pull.
]]

local Types = require(script.Parent.Types)

local RARITY_ORDER: { Types.CargoRarity } = {
	"Standard",
	"Uncommon",
	"Rare",
	"Exotic",
	"Prototype",
}

local RARITY_TIER: { [Types.CargoRarity]: number } = {
	Standard = 1,
	Uncommon = 2,
	Rare = 3,
	Exotic = 4,
	Prototype = 5,
}

local RARITY_COLOR: { [Types.CargoRarity]: Color3 } = {
	Standard = Color3.fromRGB(215, 215, 215),
	Uncommon = Color3.fromRGB(110, 220, 130),
	Rare = Color3.fromRGB(95, 175, 255),
	Exotic = Color3.fromRGB(205, 125, 255),
	Prototype = Color3.fromRGB(255, 190, 60),
}

local CRATE_COLOR: { [string]: Color3 } = {
	PalletGoods = Color3.fromRGB(238, 119, 36),
	LumberStack = Color3.fromRGB(150, 106, 62),
	VendingStock = Color3.fromRGB(220, 80, 90),
	GlassPanes = Color3.fromRGB(150, 210, 225),
	FuelDrums = Color3.fromRGB(210, 60, 45),
	FrozenCatch = Color3.fromRGB(120, 190, 215),
	LiveOstriches = Color3.fromRGB(235, 205, 140),
	MuseumCrate = Color3.fromRGB(180, 150, 90),
	ReactorCore = Color3.fromRGB(120, 255, 190),
	PrototypeEngine = Color3.fromRGB(255, 205, 70),
}

local DECK: { Types.CargoDef } = {
	{
		id = "PalletGoods",
		label = "Palletized Goods",
		blurb = "Boxes on a pallet. Nothing clever, nothing fragile.",
		rarity = "Standard",
		weight = 100,
		valueMultiplier = 1,
		quirk = "None",
	},
	{
		id = "LumberStack",
		label = "Lumber Stack",
		blurb = "Long, heavy, and happy to shift on a corner.",
		rarity = "Standard",
		weight = 85,
		valueMultiplier = 1.05,
		quirk = "None",
	},
	{
		id = "VendingStock",
		label = "Vending Restock",
		blurb = "Snacks for the depot. The crew will ask. The answer is no.",
		rarity = "Standard",
		weight = 70,
		valueMultiplier = 1.1,
		quirk = "None",
	},
	{
		id = "GlassPanes",
		label = "Glass Panes",
		blurb = "Fragile. Take corners slower than feels necessary.",
		rarity = "Uncommon",
		weight = 55,
		valueMultiplier = 1.4,
		quirk = "Fragile",
		safeSpeedDelta = -3,
	},
	{
		id = "FrozenCatch",
		label = "Frozen Catch",
		blurb = "Refrigerated. Engine faults hurt more when the compressor stalls.",
		rarity = "Uncommon",
		weight = 48,
		valueMultiplier = 1.45,
		quirk = "Volatile",
		truckDamageScale = 1.25,
	},
	{
		id = "FuelDrums",
		label = "Fuel Drums",
		blurb = "Volatile. Every cascade bites deeper into the truck.",
		rarity = "Uncommon",
		weight = 44,
		valueMultiplier = 1.55,
		quirk = "Volatile",
		truckDamageScale = 1.5,
	},
	{
		id = "LiveOstriches",
		label = "Live Ostriches",
		blurb = "They panic. When they panic, the load moves on its own.",
		rarity = "Rare",
		weight = 22,
		valueMultiplier = 2,
		quirk = "Livestock",
		panicChance = 0.35,
	},
	{
		id = "MuseumCrate",
		label = "Museum Crate",
		blurb = "Insured for more than the truck. Drive like it.",
		rarity = "Rare",
		weight = 19,
		valueMultiplier = 2.2,
		quirk = "Fragile",
		safeSpeedDelta = -5,
	},
	{
		id = "ReactorCore",
		label = "Reactor Core",
		blurb = "Exotic freight. Do not let the integrity light stay red.",
		rarity = "Exotic",
		weight = 8,
		valueMultiplier = 3.1,
		quirk = "Volatile",
		truckDamageScale = 1.9,
		minLeg = 2,
	},
	{
		id = "PrototypeEngine",
		label = "Prototype Engine",
		blurb = "The jackpot. Bank this and the whole convoy was worth it.",
		rarity = "Prototype",
		weight = 3,
		valueMultiplier = 5,
		quirk = "Jackpot",
		minLeg = 3,
	},
}

local BY_ID: { [string]: Types.CargoDef } = {}
for _, def in DECK do
	BY_ID[def.id] = def
end

local CargoManifest = {}

CargoManifest.RarityOrder = RARITY_ORDER

function CargoManifest.getById(id: string): Types.CargoDef?
	return BY_ID[id]
end

function CargoManifest.count(): number
	return #DECK
end

function CargoManifest.rarityColor(rarity: Types.CargoRarity): Color3
	-- Bracketed, because a table declared with a union-keyed indexer does not
	-- accept dot access on one of its keys.
	return RARITY_COLOR[rarity] or RARITY_COLOR["Standard"]
end

function CargoManifest.crateColor(id: string): Color3
	return CRATE_COLOR[id] or CRATE_COLOR.PalletGoods
end

function CargoManifest.getAll(): { Types.CargoDef }
	return DECK
end

--[[
	Weighted roll. Each leg past the first multiplies the weight of every rarity
	tier above Standard, so deep convoys visibly change what shows up on the bed.
]]
function CargoManifest.roll(rng: Random, leg: number): Types.CargoDef
	local bias = 1 + (math.max(1, leg) - 1) * 0.28
	local total = 0
	local weights: { number } = table.create(#DECK, 0)

	for index, def in DECK do
		local weight = 0
		if leg >= (def.minLeg or 1) then
			local tier = RARITY_TIER[def.rarity] or 1
			weight = def.weight * (bias ^ (tier - 1))
		end
		weights[index] = weight
		total += weight
	end

	if total <= 0 then
		return DECK[1]
	end

	local pick = rng:NextNumber(0, total)
	for index, weight in weights do
		pick -= weight
		if pick <= 0 then
			return DECK[index]
		end
	end
	return DECK[1]
end

return CargoManifest
