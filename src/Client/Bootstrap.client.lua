--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevConfig = require(Shared:WaitForChild("DevConfig"))

if DevConfig.isFunTest() then
	local DebugOverlay = require(script.Parent:WaitForChild("DebugOverlay"))
	local LabMusic = require(script.Parent:WaitForChild("LabMusic"))
	local LabSFX = require(script.Parent:WaitForChild("LabSFX"))
	local LabUI = require(script.Parent:WaitForChild("LabUI"))
	local WheelPresentation = require(script.Parent:WaitForChild("WheelPresentation"))

	LabUI.mount()
	LabMusic.mount()
	LabSFX.mount()
	WheelPresentation.mount()
	DebugOverlay.mount()

	print("[CargoLab] Client mounted (fun-test HUD)")
else
	local DepotUI = require(script.Parent:WaitForChild("DepotUI"))
	local MatchUI = require(script.Parent:WaitForChild("MatchUI"))
	local Nameplates = require(script.Parent:WaitForChild("Nameplates"))

	MatchUI.mount()
	DepotUI.mount()
	Nameplates.mount()

	print("[CargoCatastrophe] Client mounted (crew HUD + depot)")
end
