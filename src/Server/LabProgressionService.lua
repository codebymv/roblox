--!strict

--[[
	Persistent progression adapter for the physics fun-test.

	The older depot build already owns a safe profile cache and a paint catalog.
	This module reuses those authorities without bringing the obsolete depot
	match loop back into the published game.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Cosmetics = require(Shared:WaitForChild("Cosmetics"))
local LabProgression = require(Shared:WaitForChild("LabProgression"))
local TruckPaints = require(Shared:WaitForChild("TruckPaints"))
local Types = require(Shared:WaitForChild("Types"))

local PlayerDataService = require(script.Parent.PlayerDataService)

export type Snapshot = {
	ready: boolean,
	saving: boolean,
	credits: number,
	equippedPaint: string,
	unlockedPaints: { [string]: boolean },
}

local NOT_READY: Snapshot = {
	ready = false,
	saving = false,
	credits = 0,
	equippedPaint = "Factory",
	unlockedPaints = { Factory = true },
}

-- Unlocked-paint tables are rebuilt only when a purchase/unlock lands. Credits
-- and equipped paint still refresh every snapshot read.
local unlockedByUser: { [number]: { [string]: boolean } } = {}

local LabProgressionService = {}

local function buildUnlocked(profile: Types.ProfileData): { [string]: boolean }
	local unlocked: { [string]: boolean } = {}
	for _, paint in TruckPaints.getAllPaints() do
		if paint.cost <= 0 or profile.unlockedPaints[paint.id] then
			unlocked[paint.id] = true
		end
	end
	return unlocked
end

function LabProgressionService.invalidatePaints(player: Player)
	unlockedByUser[player.UserId] = nil
end

function LabProgressionService.awardRun(
	player: Player,
	outcome: string,
	cargoReadout: number,
	chassisIntegrity: number,
	rewardMultiplier: number?
): number?
	local reward = LabProgression.rewardFor(outcome, cargoReadout, chassisIntegrity, rewardMultiplier)
	if reward <= 0 then
		return nil
	end

	local successful = LabProgression.isSuccessful(outcome)
	local profile = PlayerDataService.update(player, function(data)
		data.credits += reward
		data.lifetimeBanked += reward
		data.lifetimeConvoys += 1
		if successful then
			data.currentStreak += 1
			data.bestLeg = math.max(data.bestLeg, 1)
			data.bestStreak = math.max(data.bestStreak, data.currentStreak)
		else
			data.currentStreak = 0
		end
		data.bestBankedHaul = math.max(data.bestBankedHaul, reward)
	end)
	if not profile then
		return nil
	end

	player:SetAttribute("CargoCredits", profile.credits)
	player:SetAttribute("ConvoyStreak", profile.currentStreak)
	return reward
end

function LabProgressionService.snapshot(player: Player): Snapshot
	local profile = PlayerDataService.get(player)
	if not profile then
		return NOT_READY
	end

	local unlocked = unlockedByUser[player.UserId]
	if not unlocked then
		unlocked = buildUnlocked(profile)
		unlockedByUser[player.UserId] = unlocked
	end

	local equippedPaint = if TruckPaints.getPaint(profile.equippedPaint) then profile.equippedPaint else "Factory"
	return {
		ready = true,
		saving = not PlayerDataService.isVolatile(player),
		credits = profile.credits,
		equippedPaint = equippedPaint,
		unlockedPaints = unlocked,
	}
end

--[[
	Paint purchase and equip.

	These lived in EconomyService alongside convoy banking, kit shops and daily
	bonuses. That module went with the rest of the depot build; paint is the
	only part of it the fun-test ever used, so it moved here rather than keeping
	four hundred lines alive to reach two functions.

	Equipping is not buying. Paint once had only a purchase path, so the
	client's equip button silently spent credits on anything not already owned.
	Keeping them separate is what fixed that, and it stays separate here.
]]
local function purchasePaint(player: Player, paintId: string): (boolean, string)
	local paint = TruckPaints.getPaint(paintId)
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

local function equipPaint(player: Player, paintId: string): (boolean, string)
	local paint = TruckPaints.getPaint(paintId)
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

function LabProgressionService.selectPaint(player: Player, paintId: string): (boolean, string)
	local profile = PlayerDataService.get(player)
	local paint = TruckPaints.getPaint(paintId)
	if not profile then
		return false, "Profile still loading."
	end
	if not paint then
		return false, "Unknown truck paint."
	end
	if PlayerDataService.isVolatile(player) and not RunService:IsStudio() then
		return false, "Saving is temporarily unavailable. Try again later."
	end

	local owned = paint.cost <= 0 or profile.unlockedPaints[paintId] == true
	if owned then
		if profile.equippedPaint == paintId then
			return false, paint.label .. " is already equipped."
		end
		return equipPaint(player, paintId)
	end
	local ok, message = purchasePaint(player, paintId)
	if ok then
		LabProgressionService.invalidatePaints(player)
	end
	return ok, message
end

function LabProgressionService.paintColorFor(player: Player?): Color3
	local paintId = "Factory"
	if player then
		local profile = PlayerDataService.get(player)
		if profile then
			paintId = profile.equippedPaint
		end
	end
	local paint = TruckPaints.getPaint(paintId) or TruckPaints.getPaint("Factory")
	assert(paint, "Factory paint is missing")
	return paint.color
end

-- The current Driver owns the shared truck's appearance. Resolution happens
-- server-side so a stale or edited profile can only fall back to defaults; it
-- can never equip an unearned livery or a finish the player does not own.
function LabProgressionService.cosmeticsFor(player: Player?)
	local profile = if player then PlayerDataService.get(player) else nil
	local paintId = if profile then profile.equippedPaint else "Factory"
	local paint = TruckPaints.getPaint(paintId) or TruckPaints.getPaint("Factory")
	assert(paint, "Factory paint is missing")

	local livery, finish = Cosmetics.resolve(
		if profile then profile.equippedLivery else Cosmetics.DefaultLivery,
		if profile then profile.equippedFinish else Cosmetics.DefaultFinish,
		if profile then profile.dailyWins else 0,
		if profile then profile.unlockedFinishes else {}
	)
	return livery, finish, paint.color
end

return LabProgressionService
