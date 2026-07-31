--!strict

--[[
	Permanent per-role unlocks bought with Freight Credits.

	Hard rule: a kit may tilt a timing window, a recovery rate, or a safe speed.
	No kit may skip an interaction, auto-resolve a failure, or be sold for Robux.
	Paid items are paint only.
]]

local Types = require(script.Parent.Types)

local STARTERS: { [Types.RoleId]: string } = {
	Driver = "StockCab",
	Strapper = "StockStraps",
	Spotter = "StockRadio",
	Repair = "StockToolbag",
}

local KITS: { Types.KitDef } = {
	{
		id = "StockCab",
		roleId = "Driver",
		label = "Stock Cab",
		blurb = "Standard issue. No help, no excuses.",
		cost = 0,
		effect = {},
	},
	{
		id = "AirBrakes",
		roleId = "Driver",
		label = "Air Brakes",
		blurb = "Corner three notches faster before the load complains.",
		cost = 400,
		effect = { safeSpeedBonus = 3 },
	},
	{
		id = "RoadSense",
		roleId = "Driver",
		label = "Road Sense Package",
		blurb = "Corner warnings land earlier, giving you longer to scrub speed.",
		cost = 1100,
		effect = { safeSpeedBonus = 5, windowBonusSeconds = 1.5 },
	},
	{
		id = "StockStraps",
		roleId = "Strapper",
		label = "Stock Straps",
		blurb = "Frayed but functional.",
		cost = 0,
		effect = {},
	},
	{
		id = "RatchetStrap",
		roleId = "Strapper",
		label = "Ratchet Strap",
		blurb = "Two extra seconds to re-secure a loose load.",
		cost = 350,
		effect = { windowBonusSeconds = 2 },
	},
	{
		id = "LoadBars",
		roleId = "Strapper",
		label = "Load Bars",
		blurb = "The bed settles faster once the cargo is back in place.",
		cost = 950,
		effect = { windowBonusSeconds = 2, stabilityRecoveryBonus = 2.5 },
	},
	{
		id = "StockRadio",
		roleId = "Spotter",
		label = "Stock Radio",
		blurb = "Crackly, but it reaches the cab.",
		cost = 0,
		effect = {},
	},
	{
		id = "SignalFlare",
		roleId = "Spotter",
		label = "Signal Flare",
		blurb = "Hazards stay callable for longer.",
		cost = 300,
		effect = { windowBonusSeconds = 2.5 },
	},
	{
		id = "ConvoyRadio",
		roleId = "Spotter",
		label = "Convoy Radio",
		blurb = "The whole crew hears it. Every window stretches.",
		cost = 1000,
		effect = { windowBonusSeconds = 4 },
	},
	{
		id = "StockToolbag",
		roleId = "Repair",
		label = "Stock Toolbag",
		blurb = "A wrench and optimism.",
		cost = 0,
		effect = {},
	},
	{
		id = "SpareFuse",
		roleId = "Repair",
		label = "Spare Fuse Box",
		blurb = "Each fix puts more integrity back into the truck.",
		cost = 500,
		effect = { integrityRestoreBonus = 10 },
	},
	{
		id = "FieldWelder",
		roleId = "Repair",
		label = "Field Welder",
		blurb = "Serious repairs, mid-haul.",
		cost = 1400,
		effect = { integrityRestoreBonus = 22, windowBonusSeconds = 1.5 },
	},
}

local PAINTS: { Types.PaintDef } = {
	{ id = "Factory", label = "Factory Red", cost = 0, color = Color3.fromRGB(170, 66, 48) },
	{ id = "DepotGrey", label = "Depot Grey", cost = 200, color = Color3.fromRGB(110, 116, 126) },
	{ id = "HazardYellow", label = "Hazard Yellow", cost = 450, color = Color3.fromRGB(240, 190, 55) },
	{ id = "Midnight", label = "Midnight Blue", cost = 900, color = Color3.fromRGB(40, 62, 110) },
	{ id = "Prototype", label = "Prototype White", cost = 2200, color = Color3.fromRGB(238, 240, 245) },
}

local KIT_BY_ID: { [string]: Types.KitDef } = {}
for _, kit in KITS do
	KIT_BY_ID[kit.id] = kit
end

local PAINT_BY_ID: { [string]: Types.PaintDef } = {}
for _, paint in PAINTS do
	PAINT_BY_ID[paint.id] = paint
end

local RoleKits = {}

function RoleKits.getKit(id: string): Types.KitDef?
	return KIT_BY_ID[id]
end

function RoleKits.getPaint(id: string): Types.PaintDef?
	return PAINT_BY_ID[id]
end

function RoleKits.getAllKits(): { Types.KitDef }
	return KITS
end

function RoleKits.getAllPaints(): { Types.PaintDef }
	return PAINTS
end

function RoleKits.isStarterKit(id: string): boolean
	for _, starterId in STARTERS do
		if starterId == id then
			return true
		end
	end
	return false
end

function RoleKits.starterFor(roleId: Types.RoleId): string
	return STARTERS[roleId]
end

function RoleKits.kitsForRole(roleId: Types.RoleId): { Types.KitDef }
	local result: { Types.KitDef } = {}
	for _, kit in KITS do
		if kit.roleId == roleId then
			table.insert(result, kit)
		end
	end
	return result
end

function RoleKits.effectFor(kitId: string?): Types.KitEffect
	local kit = if kitId then KIT_BY_ID[kitId] else nil
	return if kit then kit.effect else {}
end

return RoleKits
