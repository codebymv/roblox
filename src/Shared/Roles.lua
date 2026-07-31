--!strict

local Types = require(script.Parent.Types)

export type RoleInfo = {
	id: Types.RoleId,
	displayName: string,
	job: string,
	hudHint: string,
}

local ORDER: { Types.RoleId } = { "Driver", "Strapper", "Spotter", "Repair" }

local INFO: { [Types.RoleId]: RoleInfo } = {
	Driver = {
		id = "Driver",
		displayName = "Driver",
		job = "Steer, brake, and pace turns so cargo stays on the bed.",
		hudHint = "Keep turns smooth. Brake before corners.",
	},
	Strapper = {
		id = "Strapper",
		displayName = "Strapper",
		job = "Re-secure loose straps before cargo dumps.",
		hudHint = "When prompted, hold the strap interact.",
	},
	Spotter = {
		id = "Spotter",
		displayName = "Spotter",
		job = "Ping hazards early so the crew can prepare.",
		hudHint = "Ping ahead when you see trouble.",
	},
	Repair = {
		id = "Repair",
		displayName = "Repair",
		job = "Clear engine, wheel, and ramp faults.",
		hudHint = "Get to the sparking fault and repair it.",
	},
}

local Roles = {}

function Roles.getOrder(): { Types.RoleId }
	return table.clone(ORDER)
end

function Roles.getInfo(roleId: Types.RoleId): RoleInfo
	return INFO[roleId]
end

function Roles.assign(playerCount: number): { Types.RoleId }
	local count = math.clamp(playerCount, 1, #ORDER)
	local assigned: { Types.RoleId } = table.create(count)
	for i = 1, count do
		assigned[i] = ORDER[i]
	end
	return assigned
end

return Roles
