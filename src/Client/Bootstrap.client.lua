--!strict

local DebugOverlay = require(script.Parent:WaitForChild("DebugOverlay"))
local LabMotionState = require(script.Parent:WaitForChild("LabMotionState"))
local LabMusic = require(script.Parent:WaitForChild("LabMusic"))
local LabSFX = require(script.Parent:WaitForChild("LabSFX"))
local LabUI = require(script.Parent:WaitForChild("LabUI"))
local LabVfx = require(script.Parent:WaitForChild("LabVfx"))
local WheelPresentation = require(script.Parent:WaitForChild("WheelPresentation"))

LabMotionState.mount()
LabUI.mount()
LabMusic.mount()
LabSFX.mount()
LabVfx.mount()
WheelPresentation.mount()
DebugOverlay.mount()

print("[CargoLab] Client mounted")
