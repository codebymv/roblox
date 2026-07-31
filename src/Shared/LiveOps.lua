--!strict

--[[
	Live-ops hooks. The point of this file is that shipping an event is editing a
	table, not writing a system. The top performers run a visible weekly rhythm;
	this is the cheapest honest version of that.
]]

export type EventDef = {
	id: string,
	label: string,
	blurb: string,
	payoutMultiplier: number,
	pressureBonus: number,
}

local WEEKLY: { EventDef } = {
	{
		id = "StandardDispatch",
		label = "Standard Dispatch",
		blurb = "Normal freight week. Nothing unusual on the boards.",
		payoutMultiplier = 1,
		pressureBonus = 0,
	},
	{
		id = "StormWeek",
		label = "Storm Week",
		blurb = "Weather is against the convoy. Faults come faster, freight pays 20% more.",
		payoutMultiplier = 1.2,
		pressureBonus = 0.2,
	},
	{
		id = "RushContracts",
		label = "Rush Contracts",
		blurb = "Everything is late. Shorter windows, 35% bigger payouts.",
		payoutMultiplier = 1.35,
		pressureBonus = 0.35,
	},
	{
		id = "AuditWeek",
		label = "Audit Week",
		blurb = "Inspectors on the route. Calm haul, modest bonus.",
		payoutMultiplier = 1.1,
		pressureBonus = -0.1,
	},
}

local LiveOps = {}

function LiveOps.getDayIndex(): number
	return math.floor(os.time() / 86400)
end

function LiveOps.getWeekIndex(): number
	return math.floor(os.time() / 604800)
end

function LiveOps.getActive(): EventDef
	local index = (LiveOps.getWeekIndex() % #WEEKLY) + 1
	return WEEKLY[index]
end

function LiveOps.getAll(): { EventDef }
	return WEEKLY
end

return LiveOps
