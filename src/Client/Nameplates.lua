--!strict

--[[
	Convoy streak badges over heads.

	A streak that only exists on a menu is not a flex. This is the cheap version of
	Animal Hospital showing total shifts in the lobby: you should be able to see
	who in the yard is on a run of banked convoys.
]]

local Players = game:GetService("Players")

local Nameplates = {}

local localPlayer = Players.LocalPlayer

local function updateLabel(label: TextLabel, player: Player)
	local streak = player:GetAttribute("ConvoyStreak")
	local role = player:GetAttribute("CargoRole")
	local parts: { string } = {}
	if typeof(streak) == "number" and streak > 0 then
		table.insert(parts, string.format("%d CONVOY STREAK", streak))
	end
	if typeof(role) == "string" then
		table.insert(parts, string.upper(role))
	end
	label.Text = table.concat(parts, "  ·  ")
	label.Visible = #parts > 0
end

local function attach(player: Player, character: Model)
	local head = character:WaitForChild("Head", 10)
	if not head or not head:IsA("BasePart") then
		return
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "ConvoyBadge"
	billboard.Size = UDim2.fromOffset(240, 30)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	billboard.MaxDistance = 120
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextSize = 14
	label.TextStrokeTransparency = 0.4
	label.TextColor3 = Color3.fromRGB(255, 205, 90)
	label.Text = ""
	label.Parent = billboard

	updateLabel(label, player)

	local connections: { RBXScriptConnection } = {
		player:GetAttributeChangedSignal("ConvoyStreak"):Connect(function()
			updateLabel(label, player)
		end),
		player:GetAttributeChangedSignal("CargoRole"):Connect(function()
			updateLabel(label, player)
		end),
	}

	billboard.Destroying:Connect(function()
		for _, connection in connections do
			connection:Disconnect()
		end
	end)
end

local function track(player: Player)
	if player.Character then
		task.spawn(attach, player, player.Character)
	end
	player.CharacterAdded:Connect(function(character: Model)
		task.spawn(attach, player, character)
	end)
end

function Nameplates.mount()
	for _, player in Players:GetPlayers() do
		if player ~= localPlayer then
			track(player)
		end
	end
	Players.PlayerAdded:Connect(function(player: Player)
		if player ~= localPlayer then
			track(player)
		end
	end)
end

return Nameplates
