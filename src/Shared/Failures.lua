--!strict

local MatchConfig = require(script.Parent.MatchConfig)
local Types = require(script.Parent.Types)

local DECK: { Types.FailureDef } = {
	{
		id = "LooseStrap",
		label = "Loose Strap",
		description = "A cargo strap snaps free. Strapper must re-secure it.",
		responsibleRole = "Strapper",
		interaction = "Hold",
		holdSeconds = 1.5,
		windowSeconds = MatchConfig.StrapWindowSeconds,
		cascadeSeverity = 2,
		clipLine = "He didn't strap it.",
	},
	{
		id = "SharpTurn",
		label = "Sharp Turn",
		description = "Tight bend ahead. Driver must slow or cargo tilts.",
		responsibleRole = "Driver",
		interaction = "Brake",
		windowSeconds = 6,
		cascadeSeverity = 1,
		clipLine = "Took the corner too hot.",
	},
	{
		id = "EngineFault",
		label = "Engine Fault",
		description = "Engine sparks. Repair must clear it or power cuts.",
		responsibleRole = "Repair",
		interaction = "Hold",
		holdSeconds = 1.75,
		windowSeconds = MatchConfig.RepairWindowSeconds,
		cascadeSeverity = 1,
		clipLine = "Nobody fixed the engine.",
		damagesTruck = true,
	},
	{
		id = "WheelWobble",
		label = "Wheel Wobble",
		description = "Wheel assembly shakes. Repair or lose steering authority.",
		responsibleRole = "Repair",
		interaction = "Hold",
		holdSeconds = 1.5,
		windowSeconds = MatchConfig.RepairWindowSeconds,
		cascadeSeverity = 1,
		clipLine = "Wheel almost came off.",
		damagesTruck = true,
	},
	{
		id = "CargoTilt",
		label = "Cargo Tilt",
		description = "Load shifts. Strapper must brace before a dump.",
		responsibleRole = "Strapper",
		interaction = "Hold",
		holdSeconds = 1.75,
		windowSeconds = MatchConfig.StrapWindowSeconds,
		cascadeSeverity = 2,
		clipLine = "The whole load went over.",
	},
	{
		id = "RampDrop",
		label = "Ramp Drop",
		description = "Loading ramp unlatches mid-route.",
		responsibleRole = "Repair",
		interaction = "Hold",
		holdSeconds = 1.25,
		windowSeconds = MatchConfig.RepairWindowSeconds,
		cascadeSeverity = 1,
		clipLine = "Ramp dropped on the road.",
		damagesTruck = true,
	},
	{
		id = "BlindCorner",
		label = "Blind Corner",
		description = "Spotter should ping; Driver must respect the mark.",
		responsibleRole = "Spotter",
		interaction = "Ping",
		windowSeconds = 7,
		cascadeSeverity = 1,
		clipLine = "Nobody called the corner.",
	},
	{
		id = "Overheat",
		label = "Overheat",
		description = "Coolant warning. Repair vents heat or risk shutdown.",
		responsibleRole = "Repair",
		interaction = "Hold",
		holdSeconds = 1.75,
		windowSeconds = MatchConfig.RepairWindowSeconds,
		cascadeSeverity = 1,
		clipLine = "Truck cooked itself.",
		damagesTruck = true,
	},
}

local Failures = {}

function Failures.getDeck(): { Types.FailureDef }
	return DECK
end

function Failures.getById(id: Types.FailureId): Types.FailureDef?
	for _, def in DECK do
		if def.id == id then
			return def
		end
	end
	return nil
end

function Failures.pickRandom(
	rng: Random?,
	allowedRoles: { [Types.RoleId]: boolean }?,
	excludedId: Types.FailureId?
): Types.FailureDef?
	local random = rng or Random.new()
	local candidates: { Types.FailureDef } = {}
	for _, def in DECK do
		if (not allowedRoles or allowedRoles[def.responsibleRole]) and def.id ~= excludedId then
			table.insert(candidates, def)
		end
	end
	-- A solo Driver has only Sharp Turn in the current deck. In that case,
	-- repeating a valid event is better than scheduling nothing forever.
	if #candidates == 0 and excludedId then
		for _, def in DECK do
			if not allowedRoles or allowedRoles[def.responsibleRole] then
				table.insert(candidates, def)
			end
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[random:NextInteger(1, #candidates)]
end

return Failures
