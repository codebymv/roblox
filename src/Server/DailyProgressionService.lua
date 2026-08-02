--!nonstrict

--[[
	Banking the daily bonus.

	DailyContract decides what today asks for and whether a run met it; this
	decides whether this particular player has already been paid for it, and
	pays them if not.

	The claim is stored as a day number rather than a flag, so it expires on its
	own when the day rolls over. Nothing has to reset anything at midnight, and
	a server that happens to be running across the boundary starts offering the
	new objective the moment os.time crosses it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DailyContract = require(Shared:WaitForChild("DailyContract"))

local PlayerDataService = require(script.Parent.PlayerDataService)

local DailyProgressionService = {}

--[[
	Pay today's bonus, once.

	Returns whether this call is the one that paid, so the caller can announce it
	without having to ask again. A second qualifying run on the same day is not
	an error and is not announced: the objective is still met, it has simply
	already been banked.

	A volatile profile is refused. Paying into one hands over credits that
	vanish at logout and, worse, marks the day claimed in memory so the player
	cannot earn it again on a healthy server.
]]
function DailyProgressionService.claim(player: Player, today: number, objective): boolean
	if not objective then
		return false
	end

	local profile = PlayerDataService.get(player)
	if not profile or PlayerDataService.isVolatile(player) then
		return false
	end
	if DailyContract.isClaimed(profile.dailyContractDay, today) then
		return false
	end

	PlayerDataService.update(player, function(data)
		data.dailyContractDay = today
		data.credits += math.max(0, objective.bonus)
		-- The count the livery ladder is derived from. Cumulative and never
		-- reset: the collection is the one thing a bad run cannot take away.
		data.dailyWins += 1
	end)
	return true
end

function DailyProgressionService.isClaimed(player: Player, today: number): boolean
	local profile = PlayerDataService.get(player)
	return profile ~= nil and DailyContract.isClaimed(profile.dailyContractDay, today)
end

return DailyProgressionService
