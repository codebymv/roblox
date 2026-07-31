--!strict

--[[
	The depot panel: the thing our lobby was missing.

	It is a shop, a status board, and a bay switcher in one place, and it is the
	only screen where a player sees what they own and what everyone else has done.
	Rows are built once and only their text changes, so buttons never move under a
	click mid-refresh.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Net = require(Shared:WaitForChild("Net"))
local RoleKits = require(Shared:WaitForChild("RoleKits"))
local Types = require(Shared:WaitForChild("Types"))

local UIKit = require(script.Parent.UIKit)

local DepotUI = {}

type Row = {
	label: TextLabel,
	button: TextButton,
}

local player = Players.LocalPlayer
local gui: ScreenGui
local panel: Frame
local scroller: ScrollingFrame
local toggleButton: TextButton
local headerLabel: TextLabel
local eventLabel: TextLabel
local dailyButton: TextButton
local bayRows: { Row } = {}
local kitRows: { [string]: Row } = {}
local paintRows: { [string]: Row } = {}
local streakRows: { TextLabel } = {}
local haulRows: { TextLabel } = {}
local orderCounter = 0

local latest: Types.DepotSnapshot? = nil
local isOpen = false

local requestJoinRemote: RemoteEvent
local requestLeaveRemote: RemoteEvent
local requestSpectateRemote: RemoteEvent
local requestPurchaseRemote: RemoteEvent
local requestEquipRemote: RemoteEvent
local requestDailyRemote: RemoteEvent

local function nextOrder(): number
	orderCounter += 1
	return orderCounter
end

local function makeSection(text: string): TextLabel
	return UIKit.label({
		Name = "Section",
		Size = UDim2.new(1, 0, 0, 30),
		Font = Enum.Font.GothamBlack,
		TextSize = 15,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		TextColor3 = Color3.fromRGB(255, 190, 55),
		Text = text,
		LayoutOrder = nextOrder(),
		Parent = scroller,
	})
end

local function makeRow(buttonWidth: number): Row
	local frame = UIKit.panel({
		Name = "Row",
		Size = UDim2.new(1, 0, 0, 44),
		BackgroundColor3 = Color3.fromRGB(28, 31, 39),
		BackgroundTransparency = 0.25,
		LayoutOrder = nextOrder(),
		Parent = scroller,
	})

	local label = UIKit.label({
		Name = "Label",
		Size = UDim2.new(1, -(buttonWidth + 20), 1, 0),
		Position = UDim2.fromOffset(10, 0),
		TextSize = 13,
		TextWrapped = true,
		TextColor3 = Color3.fromRGB(232, 235, 240),
		Parent = frame,
	})

	local button = UIKit.button({
		Name = "Action",
		AnchorPoint = Vector2.new(1, 0.5),
		Size = UDim2.fromOffset(buttonWidth, 32),
		Position = UDim2.new(1, -8, 0.5, 0),
		BackgroundColor3 = Color3.fromRGB(65, 120, 225),
		TextSize = 13,
		TextColor3 = Color3.new(1, 1, 1),
		CornerRadius = 7,
		Parent = frame,
	})

	return { label = label, button = button }
end

local function makeTextRow(): TextLabel
	return UIKit.label({
		Name = "Entry",
		Size = UDim2.new(1, 0, 0, 22),
		TextSize = 13,
		TextColor3 = Color3.fromRGB(205, 212, 222),
		LayoutOrder = nextOrder(),
		Parent = scroller,
	})
end

local function setOpen(open: boolean)
	isOpen = open
	panel.Visible = open
	toggleButton.Text = if open then "CLOSE DEPOT" else "DEPOT"
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local function refreshHeader(snap: Types.DepotSnapshot)
	headerLabel.Text = string.format(
		"%d credits  ·  streak %d (best %d)\nBest leg %d  ·  best haul %d cr  ·  %d convoys\nManifest journal %d/%d",
		snap.credits,
		snap.streak,
		snap.bestStreak,
		snap.bestLeg,
		snap.bestBankedHaul,
		snap.lifetimeConvoys,
		snap.journalCount,
		snap.journalTotal
	)
	eventLabel.Text = string.format(
		"%s  ·  payouts x%.2f\n%s",
		snap.eventLabel,
		snap.payoutMultiplier,
		snap.eventBlurb
	)

	dailyButton.Visible = snap.dailyBonusReady
	dailyButton.Text = string.format("CLAIM DAILY DISPATCH BONUS (+%d)", snap.dailyBonusAmount)
end

local function refreshBays(snap: Types.DepotSnapshot)
	for index, row in bayRows do
		local status = snap.bays[index]
		if not status then
			row.label.Text = "Bay offline"
			row.button.Visible = false
			continue
		end

		local roster = if #status.members > 0 then table.concat(status.members, ", ") else "empty"
		local detail = if status.leg > 0
			then string.format("leg %d · %d cr on the stack", status.leg, status.carriedValue)
			else status.phase
		if status.cargoLabel then
			detail ..= " · " .. status.cargoLabel
		end
		row.label.Text = string.format(
			"BAY %d (%d/%d)  %s\n%s",
			status.index,
			status.memberCount,
			status.capacity,
			detail,
			roster
		)

		row.button.Visible = true
		if snap.myBay == index then
			row.button.Text = "LEAVE"
			row.button.BackgroundColor3 = Color3.fromRGB(180, 80, 60)
		elseif status.memberCount >= status.capacity
			or (status.phase ~= "Idle" and status.phase ~= "Staging" and status.phase ~= "Resolve")
		then
			row.button.Text = "WATCH"
			row.button.BackgroundColor3 = Color3.fromRGB(80, 88, 104)
		else
			row.button.Text = "JOIN"
			row.button.BackgroundColor3 = Color3.fromRGB(45, 150, 95)
		end
	end
end

local function refreshKits(snap: Types.DepotSnapshot)
	for _, kit in RoleKits.getAllKits() do
		local row = kitRows[kit.id]
		if not row then
			continue
		end
		local owned = RoleKits.isStarterKit(kit.id) or snap.unlockedKits[kit.id] == true
		local equipped = snap.equippedKits[kit.roleId] == kit.id
			or (RoleKits.isStarterKit(kit.id) and snap.equippedKits[kit.roleId] == nil)

		row.label.Text = string.format("%s · %s\n%s", kit.label, kit.roleId, kit.blurb)
		if equipped then
			row.button.Text = "EQUIPPED"
			row.button.BackgroundColor3 = Color3.fromRGB(60, 70, 90)
		elseif owned then
			row.button.Text = "EQUIP"
			row.button.BackgroundColor3 = Color3.fromRGB(45, 150, 95)
		else
			row.button.Text = tostring(kit.cost) .. " cr"
			row.button.BackgroundColor3 = if snap.credits >= kit.cost
				then Color3.fromRGB(65, 120, 225)
				else Color3.fromRGB(80, 82, 92)
		end
	end
end

local function refreshPaints(snap: Types.DepotSnapshot)
	for _, paint in RoleKits.getAllPaints() do
		local row = paintRows[paint.id]
		if not row then
			continue
		end
		local owned = paint.cost <= 0 or snap.unlockedPaints[paint.id] == true
		row.label.Text = paint.label
		if snap.equippedPaint == paint.id then
			row.button.Text = "ON TRUCK"
			row.button.BackgroundColor3 = Color3.fromRGB(60, 70, 90)
		elseif owned then
			row.button.Text = "EQUIP"
			row.button.BackgroundColor3 = Color3.fromRGB(45, 150, 95)
		else
			row.button.Text = tostring(paint.cost) .. " cr"
			row.button.BackgroundColor3 = if snap.credits >= paint.cost
				then Color3.fromRGB(65, 120, 225)
				else Color3.fromRGB(80, 82, 92)
		end
	end
end

local function refreshStandings(snap: Types.DepotSnapshot)
	for index, label in streakRows do
		local row = snap.topStreak[index]
		label.Text = if row
			then string.format("  %d. %s — %d (%s)", index, row.name, row.value, row.detail)
			else ""
	end
	for index, label in haulRows do
		local row = snap.topHaul[index]
		label.Text = if row
			then string.format("  %d. %s — %d cr (%s)", index, row.name, row.value, row.detail)
			else ""
	end
end

local function refresh()
	local snap = latest
	if not snap then
		return
	end
	refreshHeader(snap)
	refreshBays(snap)
	refreshKits(snap)
	refreshPaints(snap)
	refreshStandings(snap)
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function buildPanel()
	panel = UIKit.panel({
		Name = "DepotPanel",
		AnchorPoint = Vector2.new(1, 0.5),
		Size = UDim2.new(0, 420, 1, -180),
		Position = UDim2.new(1, -12, 0.5, 30),
		BackgroundColor3 = Color3.fromRGB(16, 18, 24),
		BackgroundTransparency = 0.06,
		Visible = false,
		CornerRadius = 14,
		Parent = gui,
	})

	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(420, 640)
	constraint.MinSize = Vector2.new(280, 320)
	constraint.Parent = panel

	scroller = Instance.new("ScrollingFrame")
	scroller.Name = "Content"
	scroller.Size = UDim2.new(1, -20, 1, -20)
	scroller.Position = UDim2.fromOffset(10, 10)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 5
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroller

	headerLabel = UIKit.label({
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 62),
		Font = Enum.Font.GothamBold,
		TextColor3 = Color3.fromRGB(255, 215, 120),
		LayoutOrder = nextOrder(),
		Parent = scroller,
	})

	eventLabel = UIKit.label({
		Name = "Event",
		Size = UDim2.new(1, 0, 0, 46),
		TextSize = 13,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = Color3.fromRGB(130, 205, 255),
		LayoutOrder = nextOrder(),
		Parent = scroller,
	})

	dailyButton = UIKit.button({
		Name = "Daily",
		Size = UDim2.new(1, 0, 0, 38),
		BackgroundColor3 = Color3.fromRGB(215, 150, 40),
		TextSize = 14,
		TextColor3 = Color3.new(1, 1, 1),
		Visible = false,
		LayoutOrder = nextOrder(),
		CornerRadius = 8,
		Parent = scroller,
	})

	dailyButton.Activated:Connect(function()
		requestDailyRemote:FireServer()
	end)

	makeSection("LOADING BAYS")
	for index = 1, MatchConfig.BayCount do
		local row = makeRow(78)
		row.label.Size = UDim2.new(1, -98, 1, 0)
		bayRows[index] = row
		row.button.Activated:Connect(function()
			local snap = latest
			if snap and snap.myBay == index then
				requestLeaveRemote:FireServer()
			elseif row.button.Text == "WATCH" then
				requestSpectateRemote:FireServer(index)
			else
				requestJoinRemote:FireServer(index)
			end
		end)
	end

	makeSection("OUTFITTER — ROLE KITS")
	for _, kit in RoleKits.getAllKits() do
		local row = makeRow(88)
		row.label.Size = UDim2.new(1, -108, 1, 0)
		kitRows[kit.id] = row
		row.button.Activated:Connect(function()
			local snap = latest
			local owned = RoleKits.isStarterKit(kit.id)
				or (snap ~= nil and snap.unlockedKits[kit.id] == true)
			if owned then
				requestEquipRemote:FireServer({ kind = "Kit", id = kit.id })
			else
				requestPurchaseRemote:FireServer({ kind = "Kit", id = kit.id })
			end
		end)
	end

	makeSection("OUTFITTER — CAB PAINT")
	for _, paint in RoleKits.getAllPaints() do
		local row = makeRow(88)
		row.label.Size = UDim2.new(1, -108, 1, 0)
		paintRows[paint.id] = row
		row.button.Activated:Connect(function()
			-- Buying and equipping are separate on the server now, so the
			-- button has to say which one it means. A price on the button
			-- spends credits; EQUIP never does.
			local snap = latest
			local owned = paint.cost <= 0 or (snap ~= nil and snap.unlockedPaints[paint.id] == true)
			if owned then
				requestEquipRemote:FireServer({ kind = "Paint", id = paint.id })
			else
				requestPurchaseRemote:FireServer({ kind = "Paint", id = paint.id })
			end
		end)
	end

	makeSection("LONGEST ACTIVE STREAK")
	for index = 1, 5 do
		streakRows[index] = makeTextRow()
	end

	makeSection("BIGGEST BANKED HAUL")
	for index = 1, 5 do
		haulRows[index] = makeTextRow()
	end
end

function DepotUI.mount()
	gui = UIKit.screen("CargoCatastropheDepot", player:WaitForChild("PlayerGui"))
	gui.DisplayOrder = 25

	requestJoinRemote = Net.get(Net.Names.RequestJoinBay)
	requestLeaveRemote = Net.get(Net.Names.RequestLeaveBay)
	requestSpectateRemote = Net.get(Net.Names.RequestSpectate)
	requestPurchaseRemote = Net.get(Net.Names.RequestPurchase)
	requestEquipRemote = Net.get(Net.Names.RequestEquip)
	requestDailyRemote = Net.get(Net.Names.RequestDaily)

	toggleButton = UIKit.button({
		Name = "DepotToggle",
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(150, 40),
		Position = UDim2.new(1, -12, 0, 126),
		BackgroundColor3 = Color3.fromRGB(40, 44, 56),
		TextSize = 15,
		TextColor3 = Color3.new(1, 1, 1),
		Text = "DEPOT",
		CornerRadius = 10,
		Parent = gui,
	})

	buildPanel()

	toggleButton.Activated:Connect(function()
		setOpen(not isOpen)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == Enum.KeyCode.Tab then
			setOpen(not isOpen)
		end
	end)

	Net.get(Net.Names.DepotSnapshot).OnClientEvent:Connect(function(snapshot: Types.DepotSnapshot)
		latest = snapshot
		refresh()
	end)

	Net.get(Net.Names.RequestSnapshot):FireServer()
end

return DepotUI
