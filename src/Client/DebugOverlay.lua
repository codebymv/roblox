--!nonstrict

--[[
	Tuning overlay. Not player-facing.

	Exists so the questions "why did that strap go?" and "why did the truck
	understeer there?" have an answer other than a guess. Toggle with F, or turn
	it off for real playtests with DevConfig.ShowDebugOverlay.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevConfig = require(Shared:WaitForChild("DevConfig"))
local LabConfig = require(Shared:WaitForChild("LabConfig"))
local Net = require(Shared:WaitForChild("Net"))

local DebugOverlay = {}

local WHEEL_ORDER = { "FL", "FR", "RL", "RR" }

local function bar(value: number, width: number): string
	local filled = math.clamp(math.floor(value * width + 0.5), 0, width)
	return string.rep("#", filled) .. string.rep(".", width - filled)
end

function DebugOverlay.mount()
	if not DevConfig.ShowDebugOverlay then
		return
	end

	local player = Players.LocalPlayer

	local gui = Instance.new("ScreenGui")
	gui.Name = "CargoLabDebug"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.Position = UDim2.new(0, 16, 1, -158)
	frame.Size = UDim2.fromOffset(360, 258)
	frame.BackgroundColor3 = Color3.fromRGB(8, 10, 14)
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local text = Instance.new("TextLabel")
	text.Name = "Text"
	text.Position = UDim2.fromOffset(10, 8)
	text.Size = UDim2.new(1, -20, 1, -16)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.Code
	text.TextSize = 13
	text.TextColor3 = Color3.fromRGB(150, 235, 175)
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.Text = "waiting for debug feed (F to toggle)"
	text.Parent = frame

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == Enum.KeyCode.F then
			frame.Visible = not frame.Visible
		end
	end)

	Net.get(Net.Names.LabDebug).OnClientEvent:Connect(function(snap: any)
		if typeof(snap) ~= "table" or not frame.Visible then
			return
		end

		local lines = {
			string.format(
				"load  x %+.2f  y %+.2f  z %+.2f",
				snap.loadLocalX,
				snap.loadLocalY,
				snap.loadLocalZ
			),
			string.format(
				"accel lat %+4d  long %+4d   roll %+3d  pitch %+3d",
				snap.lateralAccel,
				snap.longitudinalAccel,
				snap.rollDeg,
				snap.pitchDeg
			),
			string.format(
				"turn  %.2f [%s]  brake %d  steer %.2f",
				snap.turnSeverity,
				bar(snap.turnSeverity, 10),
				snap.brakeForce,
				snap.steeringHealth
			),
			"",
			"wheel  comp  grip-surface     susp",
		}

		for index, id in WHEEL_ORDER do
			table.insert(
				lines,
				string.format(
					"  %-3s  %.2f  %-14s  %.2f%s",
					id,
					snap.wheelCompression[index] or 0,
					snap.wheelSurface[index] or "?",
					snap.suspensionHealth[index] or 1,
					if snap.wheelGrounded[index] then "" else "  AIR"
				)
			)
		end

		table.insert(lines, "")
		table.insert(lines, "strap  health          tension")
		for index, id in LabConfig.StrapOrder do
			local health = snap.strapHealth[index] or 0
			table.insert(
				lines,
				string.format(
					"  %-3s  %3d [%s]  %.2f",
					id,
					health,
					bar(health / LabConfig.StrapMaxHealth, 8),
					snap.strapTension[index] or 0
				)
			)
		end

		table.insert(lines, "")
		table.insert(lines, "pressure  " .. tostring(snap.activePressure))
		table.insert(lines, "cause     " .. tostring(snap.lastCause))

		text.Text = table.concat(lines, "\n")
	end)
end

return DebugOverlay
