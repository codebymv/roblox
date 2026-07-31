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
local LabRemotes = require(Shared:WaitForChild("LabRemotes"))
local LabTypes = require(Shared:WaitForChild("LabTypes"))
local Net = require(Shared:WaitForChild("Net"))

local UIKit = require(script.Parent.UIKit)

local DebugOverlay = {}

local WHEEL_ORDER = { "FL", "FR", "RL", "RR" }

local function bar(value: number, width: number): string
	local filled = math.clamp(math.floor(value * width + 0.5), 0, width)
	return string.rep("#", filled) .. string.rep(".", width - filled)
end

--[[
	Tuning keybinds. Separate from the overlay panel on purpose: warping to the
	corner is useful whether or not the numbers are on screen, and the overlay
	gets switched off for real playtests while these stay available to whoever
	is running the session.
]]
local function bindDevCommands()
	if not DevConfig.isDevToolingEnabled() then
		return
	end

	local progress = 0

	LabRemotes.onClient(Net.Names.LabSnapshot, function(snap: LabTypes.LabSnapshot)
		progress = snap.routeProgress
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		local command = Net.Names.LabDevCommand
		if input.KeyCode == Enum.KeyCode.LeftBracket then
			LabRemotes.fireServer(command, { command = "warpStep", from = progress, direction = -1 })
		elseif input.KeyCode == Enum.KeyCode.RightBracket then
			LabRemotes.fireServer(command, { command = "warpStep", from = progress, direction = 1 })
		elseif input.KeyCode == Enum.KeyCode.BackSlash then
			LabRemotes.fireServer(command, { command = "rebuild" })
		elseif input.KeyCode == Enum.KeyCode.P then
			LabRemotes.fireServer(command, { command = "dump" })
		end
	end)
end

function DebugOverlay.mount()
	bindDevCommands()

	if not DevConfig.ShowDebugOverlay then
		return
	end

	local player = Players.LocalPlayer

	local gui = UIKit.screen("CargoLabDebug", player:WaitForChild("PlayerGui"))

	local frame = UIKit.panel({
		Name = "Panel",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -158),
		Size = UDim2.fromOffset(360, 258),
		BackgroundColor3 = Color3.fromRGB(8, 10, 14),
		BackgroundTransparency = 0.2,
		Parent = gui,
	})

	local text = UIKit.label({
		Name = "Text",
		Position = UDim2.fromOffset(10, 8),
		Size = UDim2.new(1, -20, 1, -16),
		Font = Enum.Font.Code,
		TextSize = 13,
		TextColor3 = Color3.fromRGB(150, 235, 175),
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "waiting for debug feed (F to toggle)",
		Parent = frame,
	})

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == Enum.KeyCode.F then
			frame.Visible = not frame.Visible
		end
	end)

	LabRemotes.onClient(Net.Names.LabDebug, function(snap: LabTypes.DebugSnapshot)
		if not frame.Visible then
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

		UIKit.setText(text, table.concat(lines, "\n"))
	end)
end

return DebugOverlay
