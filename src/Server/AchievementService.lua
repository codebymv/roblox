--!nonstrict

--[[
	Records and badges, applied when a run ends.

	Achievements holds the arithmetic and the badge list; this holds the profile
	writes and the one network call. Badge ids are fail-closed the same way
	product ids are, so this runs harmlessly against an empty badge list until
	the ids exist.
]]

local BadgeService = game:GetService("BadgeService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Achievements = require(Shared:WaitForChild("Achievements"))

local PlayerDataService = require(script.Parent.PlayerDataService)

local AchievementService = {}

--[[
	Award a badge, at most once per player per badge.

	The profile flag is a cache rather than the authority: Roblox will not
	award the same badge twice, so a lost flag costs one wasted call and never
	a double award. It exists to keep a network round trip out of every single
	delivery once a player already has the badge.
]]
local function awardBadge(player: Player, key: string)
	local badge = Achievements.badge(key)
	if not badge or not Achievements.isConfigured(badge) then
		return
	end

	local profile = PlayerDataService.get(player)
	if profile and profile.awardedBadges[key] then
		return
	end

	task.spawn(function()
		local ok, awarded = pcall(function()
			return BadgeService:AwardBadgeAsync(player.UserId, badge.assetId)
		end)
		if not ok then
			warn("[CargoAchievements] Could not award " .. key .. ": " .. tostring(awarded))
			return
		end
		if not awarded then
			warn("[CargoAchievements] Roblox did not award " .. key .. " to " .. player.Name)
			return
		end
		PlayerDataService.update(player, function(data)
			data.awardedBadges[key] = true
		end)
	end)
end

--[[
	Fold a finished run into one player's profile.

	Returns the record keys this run beat so the result screen can say so while
	the player is still looking at the run that did it.
]]
function AchievementService.applyRun(player: Player, run): { string }
	local profile = PlayerDataService.get(player)
	if not profile then
		return {}
	end

	local beaten: { string } = {}
	PlayerDataService.update(player, function(data)
		beaten = Achievements.applyRun(data.labRecords, run.outcome, run.conditionPct, run.durationSeconds, run.payout)
	end)

	for _, key in Achievements.earnedBy(run.outcome, run.conditionPct, run.strapBreaks, run.riskyContract) do
		awardBadge(player, key)
	end

	return beaten
end

function AchievementService.records(player: Player)
	local profile = PlayerDataService.get(player)
	return if profile then profile.labRecords else Achievements.defaultRecords()
end

return AchievementService
