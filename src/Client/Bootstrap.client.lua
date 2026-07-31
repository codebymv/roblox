--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

ReplicatedStorage:WaitForChild("Shared")

local DepotUI = require(script.Parent:WaitForChild("DepotUI"))
local MatchUI = require(script.Parent:WaitForChild("MatchUI"))
local Nameplates = require(script.Parent:WaitForChild("Nameplates"))

MatchUI.mount()
DepotUI.mount()
Nameplates.mount()

print("[CargoCatastrophe] Client mounted (crew HUD + depot)")
