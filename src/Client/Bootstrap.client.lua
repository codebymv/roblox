--!strict

local DebugOverlay = require(script.Parent:WaitForChild("DebugOverlay"))
local ClientTuning = require(script.Parent:WaitForChild("ClientTuning"))
local LabMotionState = require(script.Parent:WaitForChild("LabMotionState"))
local LabMusic = require(script.Parent:WaitForChild("LabMusic"))
local LabSFX = require(script.Parent:WaitForChild("LabSFX"))
local LabUI = require(script.Parent:WaitForChild("LabUI"))
local LabVfx = require(script.Parent:WaitForChild("LabVfx"))
local WheelPresentation = require(script.Parent:WaitForChild("WheelPresentation"))

ClientTuning.mount()
LabMotionState.mount()
LabUI.mount()
LabMusic.mount()
LabSFX.mount()
LabVfx.mount()
WheelPresentation.mount()
DebugOverlay.mount()

print("[CargoLab] Client mounted")
