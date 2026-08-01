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

local LabProgression = require(Shared:WaitForChild("LabProgression"))
local RoleKits = require(Shared:WaitForChild("RoleKits"))

local EconomyService = require(script.Parent.EconomyService)
local PlayerDataService = require(script.Parent.PlayerDataService)

export type Snapshot = {
	ready: boolean,
	saving: boolean,
	credits: number,
	equippedPaint: string,
	unlockedPaints: { [string]: boolean },
}

local LabProgressionService = {}

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
		return {
			ready = false,
			saving = false,
			credits = 0,
			equippedPaint = "Factory",
			unlockedPaints = { Factory = true },
		}
	end

	local unlocked: { [string]: boolean } = {}
	for _, paint in RoleKits.getAllPaints() do
		if paint.cost <= 0 or profile.unlockedPaints[paint.id] then
			unlocked[paint.id] = true
		end
	end

	local equippedPaint = if RoleKits.getPaint(profile.equippedPaint) then profile.equippedPaint else "Factory"
	return {
		ready = true,
		saving = not PlayerDataService.isVolatile(player),
		credits = profile.credits,
		equippedPaint = equippedPaint,
		unlockedPaints = unlocked,
	}
end

function LabProgressionService.selectPaint(player: Player, paintId: string): (boolean, string)
	local profile = PlayerDataService.get(player)
	local paint = RoleKits.getPaint(paintId)
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
		return EconomyService.equipPaint(player, paintId)
	end
	return EconomyService.purchasePaint(player, paintId)
end

function LabProgressionService.paintColorFor(player: Player?): Color3
	local paintId = "Factory"
	if player then
		local profile = PlayerDataService.get(player)
		if profile then
			paintId = profile.equippedPaint
		end
	end
	local paint = RoleKits.getPaint(paintId) or RoleKits.getPaint("Factory")
	assert(paint, "Factory paint is missing")
	return paint.color
end

return LabProgressionService
