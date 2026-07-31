--!strict

--[[
	Sole authority for Freight Credits, payout curves, and unlocks.

	The client never sends an amount. It sends intent ("buy this kit id") and this
	module decides whether that is legal and what it costs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local CargoManifest = require(Shared:WaitForChild("CargoManifest"))
local LiveOps = require(Shared:WaitForChild("LiveOps"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local RoleKits = require(Shared:WaitForChild("RoleKits"))
local Types = require(Shared:WaitForChild("Types"))

local PlayerDataService = require(script.Parent.PlayerDataService)

local EconomyService = {}

-- Multiplier the crew is playing for on this leg. Leg 1 is 1x by definition.
function EconomyService.multiplierForLeg(leg: number): number
	return MatchConfig.LegPayoutGrowth ^ math.max(0, leg - 1)
end

function EconomyService.legValue(leg: number, cargo: Types.CargoDef?): number
	local cargoMultiplier = if cargo then cargo.valueMultiplier else 1
	local raw = MatchConfig.LegPayoutBase
		* EconomyService.multiplierForLeg(leg)
		* cargoMultiplier
		* LiveOps.getActive().payoutMultiplier
	return math.floor(raw + 0.5)
end

function EconomyService.recordLeg(player: Player, cargo: Types.CargoDef?)
	PlayerDataService.update(player, function(profile)
		profile.lifetimeLegs += 1
		if cargo then
			profile.manifestJournal[cargo.id] = (profile.manifestJournal[cargo.id] or 0) + 1
		end
	end)
end

--[[
	Convoy banked. Every crew member is paid the full amount rather than a split:
	splitting punishes bringing friends, which is the exact behaviour the platform
	algorithm rewards us for encouraging.
]]
function EconomyService.awardBank(player: Player, amount: number, legsCompleted: number)
	local payout = math.max(0, math.floor(amount))
	PlayerDataService.update(player, function(profile)
		profile.credits += payout
		profile.lifetimeBanked += payout
		profile.lifetimeConvoys += 1
		profile.currentStreak += 1
		if profile.currentStreak > profile.bestStreak then
			profile.bestStreak = profile.currentStreak
		end
		if legsCompleted > profile.bestLeg then
			profile.bestLeg = legsCompleted
		end
		if payout > profile.bestBankedHaul then
			profile.bestBankedHaul = payout
		end
	end)
	player:SetAttribute("ConvoyStreak", EconomyService.getStreak(player))
end

function EconomyService.registerWipe(player: Player, legsReached: number)
	PlayerDataService.update(player, function(profile)
		profile.lifetimeConvoys += 1
		profile.currentStreak = 0
		if legsReached > profile.bestLeg then
			profile.bestLeg = legsReached
		end
	end)
	player:SetAttribute("ConvoyStreak", 0)
end

function EconomyService.getStreak(player: Player): number
	local profile = PlayerDataService.get(player)
	return if profile then profile.currentStreak else 0
end

function EconomyService.getCredits(player: Player): number
	local profile = PlayerDataService.get(player)
	return if profile then profile.credits else 0
end

function EconomyService.ownsKit(player: Player, kitId: string): boolean
	local profile = PlayerDataService.get(player)
	if not profile then
		return false
	end
	if RoleKits.isStarterKit(kitId) then
		return true
	end
	return profile.unlockedKits[kitId] == true
end

function EconomyService.purchaseKit(player: Player, kitId: string): (boolean, string)
	local kit = RoleKits.getKit(kitId)
	if not kit then
		return false, "Unknown kit."
	end
	local profile = PlayerDataService.get(player)
	if not profile then
		return false, "Profile still loading."
	end
	if profile.unlockedKits[kitId] or RoleKits.isStarterKit(kitId) then
		return false, "Already owned."
	end
	if profile.credits < kit.cost then
		return false, string.format("Need %d more credits.", kit.cost - profile.credits)
	end

	PlayerDataService.update(player, function(data)
		data.credits -= kit.cost
		data.unlockedKits[kitId] = true
		data.equippedKits[kit.roleId] = kitId
	end)
	return true, "Unlocked " .. kit.label .. "."
end

function EconomyService.equipKit(player: Player, kitId: string): (boolean, string)
	local kit = RoleKits.getKit(kitId)
	if not kit then
		return false, "Unknown kit."
	end
	if not EconomyService.ownsKit(player, kitId) then
		return false, "You do not own that kit."
	end
	PlayerDataService.update(player, function(data)
		data.equippedKits[kit.roleId] = kitId
	end)
	return true, "Equipped " .. kit.label .. "."
end

function EconomyService.purchasePaint(player: Player, paintId: string): (boolean, string)
	local paint = RoleKits.getPaint(paintId)
	if not paint then
		return false, "Unknown paint."
	end
	local profile = PlayerDataService.get(player)
	if not profile then
		return false, "Profile still loading."
	end
	local owned = profile.unlockedPaints[paintId] == true or paint.cost <= 0
	if not owned then
		if profile.credits < paint.cost then
			return false, string.format("Need %d more credits.", paint.cost - profile.credits)
		end
		PlayerDataService.update(player, function(data)
			data.credits -= paint.cost
			data.unlockedPaints[paintId] = true
			data.equippedPaint = paintId
		end)
		return true, "Unlocked " .. paint.label .. "."
	end

	PlayerDataService.update(player, function(data)
		data.equippedPaint = paintId
	end)
	return true, paint.label .. " equipped."
end

--[[
	Equipping is not buying.

	Kits already separated the two, but paint only had purchasePaint, so the
	client's "equip" button silently spent credits on anything the player did
	not already own. This is the missing counterpart to equipKit.
]]
function EconomyService.equipPaint(player: Player, paintId: string): (boolean, string)
	local paint = RoleKits.getPaint(paintId)
	if not paint then
		return false, "Unknown paint."
	end
	local profile = PlayerDataService.get(player)
	if not profile then
		return false, "Profile still loading."
	end
	if profile.unlockedPaints[paintId] ~= true and paint.cost > 0 then
		return false, "You do not own that paint."
	end
	PlayerDataService.update(player, function(data)
		data.equippedPaint = paintId
	end)
	return true, paint.label .. " equipped."
end

function EconomyService.isDailyReady(player: Player): boolean
	local profile = PlayerDataService.get(player)
	if not profile then
		return false
	end
	return profile.lastDailyDay < LiveOps.getDayIndex()
end

function EconomyService.claimDaily(player: Player): (boolean, number, string)
	if not EconomyService.isDailyReady(player) then
		return false, 0, "Already claimed today."
	end
	local amount = MatchConfig.DailyBonusCredits
	PlayerDataService.update(player, function(profile)
		profile.lastDailyDay = LiveOps.getDayIndex()
		profile.credits += amount
	end)
	return true, amount, string.format("Daily dispatch bonus: +%d credits.", amount)
end

--[[
	Rolls the manifest for a leg. Rarity odds tighten toward the exotic end as the
	convoy pushes deeper, so the jackpot cargo is a reward for greed rather than a
	slot machine you can farm on leg 1.
]]
function EconomyService.rollCargo(rng: Random, leg: number): Types.CargoDef
	return CargoManifest.roll(rng, leg)
end

return EconomyService
