--!strict

--[[
	One objective a day, the same one for everybody.

	The retention gap the audits kept finding is that there is no reason to come
	back tomorrow. Records give a player something to beat, but they beat it
	whenever they like; a second route gives an hour of novelty and then the
	game is where it was. What was missing is something that makes *today's* run
	different from yesterday's without any new geometry.

	Every objective is checked against the run summary the server already
	produces, so this adds a reason to return without adding a system to
	simulate. Deterministic from the day number, so two players on two servers
	are working on the same thing and can talk about it.

	Engine-free: the rotation and the checks are the part worth testing, and the
	claim is the part that needs a profile.
]]

local DailyContract = {}

-- What a finished run looked like, in the terms the objectives ask about.
export type RunFacts = {
	outcome: string,
	cargoReadout: number,
	chassisIntegrity: number,
	strapBreaks: number,
	strapRefits: number,
	throws: number,
	durationSeconds: number,
	riskyContract: boolean,
}

export type Objective = {
	id: string,
	label: string,
	brief: string,
	bonus: number,
	met: (RunFacts) -> boolean,
}

local function arrived(facts: RunFacts): boolean
	return facts.outcome == "Delivered" or facts.outcome == "PartialLoss"
end

--[[
	Every objective requires arriving. A daily that can be completed by wrecking
	would be a daily that rewards not playing the game.

	They are deliberately different in kind rather than in threshold: one asks
	for care, one for speed, one for nerve, one for recovery. A rotation of six
	numbers on the same axis is one objective wearing hats.
]]
local OBJECTIVES: { Objective } = {
	{
		id = "Spotless",
		label = "SPOTLESS",
		brief = "Deliver with the load at 90% or better.",
		bonus = 260,
		met = function(facts)
			return arrived(facts) and facts.cargoReadout >= 90
		end,
	},
	{
		id = "Unbroken",
		label = "UNBROKEN",
		brief = "Deliver without a single strap letting go.",
		bonus = 240,
		met = function(facts)
			return arrived(facts) and facts.strapBreaks == 0
		end,
	},
	{
		id = "Express",
		label = "AGAINST THE CLOCK",
		brief = "Deliver in under two minutes thirty.",
		bonus = 300,
		met = function(facts)
			return arrived(facts) and facts.durationSeconds > 0 and facts.durationSeconds <= 150
		end,
	},
	{
		id = "Straightener",
		label = "PUT IT BACK",
		brief = "Lose a strap on the way and still deliver.",
		bonus = 280,
		met = function(facts)
			return arrived(facts) and facts.strapBreaks > 0
		end,
	},
	{
		id = "Nerve",
		label = "NERVE",
		brief = "Take the risky contract and deliver it.",
		bonus = 340,
		met = function(facts)
			return arrived(facts) and facts.riskyContract
		end,
	},
	{
		id = "Panelbeater",
		label = "NOT A DENT",
		brief = "Deliver with the truck above 90% integrity.",
		bonus = 250,
		met = function(facts)
			return arrived(facts) and facts.chassisIntegrity >= 90
		end,
	},
}

DailyContract.Objectives = OBJECTIVES

-- Days since the epoch, UTC. The server is the only caller, so every server
-- agrees on which day it is regardless of where its players are.
function DailyContract.dayFromUnix(seconds: number): number
	return math.floor(math.max(0, seconds) / 86400)
end

--[[
	Which objective a given day is running.

	A plain rotation rather than a hash. It is deterministic across servers,
	guarantees the objective changes every day, and a player who notices the
	pattern has learned something true about the game rather than been fooled by
	a shuffle that repeats anyway.
]]
function DailyContract.forDay(day: number): Objective
	local index = math.floor(math.max(0, day)) % #OBJECTIVES
	return OBJECTIVES[index + 1]
end

function DailyContract.byId(id: string?): Objective?
	if id == nil then
		return nil
	end
	for _, objective in OBJECTIVES do
		if objective.id == id then
			return objective
		end
	end
	return nil
end

function DailyContract.isMet(objective: Objective?, facts: RunFacts): boolean
	if not objective then
		return false
	end
	return objective.met(facts)
end

-- Whether this profile has already banked today's bonus. Stored as the day
-- number rather than a flag, so it expires by itself.
function DailyContract.isClaimed(claimedDay: number?, today: number): boolean
	return claimedDay ~= nil and claimedDay == today
end

return DailyContract
