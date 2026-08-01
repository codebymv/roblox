--!strict

--[[
	Cab paint, bought with Cargo Cash or granted by a purchase.

	This was RoleKits, and it also held the per-role kits that tilted timing
	windows and safe speeds. Those belonged to the depot build and went with it.
	What is left is the whole cosmetic catalogue, and the rule it always had:
	paint changes a colour and nothing else, so it is the only thing the game
	is willing to sell.
]]

local Types = require(script.Parent.Types)

local PAINTS: { Types.PaintDef } = {
	{ id = "Factory", label = "Factory Red", cost = 0, color = Color3.fromRGB(170, 66, 48) },
	{ id = "DepotGrey", label = "Depot Grey", cost = 200, color = Color3.fromRGB(110, 116, 126) },
	{ id = "HazardYellow", label = "Hazard Yellow", cost = 450, color = Color3.fromRGB(240, 190, 55) },
	{ id = "Midnight", label = "Midnight Blue", cost = 900, color = Color3.fromRGB(40, 62, 110) },
	{ id = "Prototype", label = "Prototype White", cost = 2200, color = Color3.fromRGB(238, 240, 245) },
}

local PAINT_BY_ID: { [string]: Types.PaintDef } = {}
for _, paint in PAINTS do
	PAINT_BY_ID[paint.id] = paint
end

local TruckPaints = {}

function TruckPaints.getPaint(id: string): Types.PaintDef?
	return PAINT_BY_ID[id]
end

function TruckPaints.getAllPaints(): { Types.PaintDef }
	return PAINTS
end

return TruckPaints
