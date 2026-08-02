--!nonstrict

--[[
	The fun-test HUD.

	Deliberately thin. The load's condition is supposed to be legible from the
	truck itself, while the four strap bars expose the specific maintenance work
	the crew can act on. Only the numeric physics readout remains developer-only.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local SocialService = game:GetService("SocialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevConfig = require(Shared:WaitForChild("DevConfig"))
local LabConfig = require(Shared:WaitForChild("LabConfig"))
local CameraFeedback = require(Shared:WaitForChild("CameraFeedback"))
local LabRemotes = require(Shared:WaitForChild("LabRemotes"))
local LabTypes = require(Shared:WaitForChild("LabTypes"))
local Net = require(Shared:WaitForChild("Net"))
local PresentationMath = require(Shared:WaitForChild("PresentationMath"))
local Achievements = require(Shared:WaitForChild("Achievements"))
local TruckPaints = require(Shared:WaitForChild("TruckPaints"))
local RunCauses = require(Shared:WaitForChild("RunCauses"))

local DeviceInput = require(script.Parent.DeviceInput)
local LabMotionState = require(script.Parent.LabMotionState)
local UIKit = require(script.Parent.UIKit)

local LabUI = {}

local player = Players.LocalPlayer
local latest: LabTypes.LabSnapshot? = nil

local CONDITION_COLOR = {
	Secure = Color3.fromRGB(90, 210, 120),
	Shifted = Color3.fromRGB(190, 215, 90),
	Leaning = Color3.fromRGB(240, 200, 70),
	Sliding = Color3.fromRGB(250, 165, 55),
	PartiallyDetached = Color3.fromRGB(250, 130, 50),
	Hanging = Color3.fromRGB(250, 95, 60),
	Dragging = Color3.fromRGB(235, 70, 70),
	Lost = Color3.fromRGB(190, 55, 55),
}

local CONDITION_TEXT = {
	Secure = "LOAD SECURE",
	Shifted = "LOAD SHIFTED",
	Leaning = "LOAD LEANING",
	Sliding = "LOAD SLIDING",
	PartiallyDetached = "STRAP GONE",
	Hanging = "LOAD HANGING",
	Dragging = "LOAD DRAGGING",
	Lost = "LOAD LOST",
}

local INTEGRITY_WARN_BELOW = 85
local INTEGRITY_CRIT_BELOW = 35
local STICK_DEADZONE = 0.15
local TOUCH_MIN = 44

--[[
	Result panel rows when a contract board shares a short screen.

	DetailHeight is sized for the longest wreck explanation RunCauses can
	produce, wrapped at the panel's narrowest permitted width, rather than for
	the shortest one. The generic fallback is the long case.
]]
local COMPACT_RESULT = {
	TitleY = 4,
	TitleHeight = 30,
	-- Tall enough for the longest RunCauses wreck line at 13px on a 280px card.
	DetailHeight = 58,
	QuestionHeight = 18,
	Gap = 2,
	Padding = 6,
}
local TOAST_HOLD = 3.2
local TOAST_FADE_IN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TOAST_FADE_OUT = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local PRESENTATION_RATE = 14
local PRESENTATION_INTERVAL = 1 / 30
local PENDING_ACTION_TIMEOUT = 2
local STRAP_PANEL_HEIGHT = 194
local GARAGE_TOP = STRAP_PANEL_HEIGHT + 8

local keyForward, keyReverse, keyLeft, keyRight, keyBrake = false, false, false, false, false
local touchSteerAxis, touchThrottleAxis = 0, 0
local touchBrake = false
local padThrottle, padReverse, padSteer, padBrake = 0, 0, 0, false
local working = false
local driveAccumulator = 0
local presentationAccumulator = 0
local inputDevice = "Keyboard"
local toastQueue: { string } = {}
local toastShowing = false
local safeRoot: Frame? = nil
local lastOffTruckToastAt = 0
local chassisMissingFor = 0
local lastSentDrive = { throttle = 0, steering = 0, braking = false }
local lastDriveSendAt = 0
local DRIVE_FLUSH_SECONDS = 1 / 30
local DRIVE_KEEPALIVE_SECONDS = 0.5
local STEER_QUANTIZE = 0.01
local presented = nil
local pendingStation: string? = nil
local pendingStationAt = 0
local pendingRoleFrom: string? = nil
local pendingRoleAt = 0
local feedbackPending = false
local feedbackPendingAt = 0
local paintPending = false
local paintPendingAt = 0
local paintSelectionInitialized = false
local selectedPaintIndex = 1
local paintDefs = TruckPaints.getAllPaints()

-- ------------------------------------------------------------- ui helpers

--[[
	Positional wrappers over UIKit. The construction and the palette live in
	UIKit; these exist only because this file's call sites read better with
	fixed argument order than with a props table.
]]
local function panel(parent: Instance, name: string, position: UDim2, size: UDim2): Frame
	return UIKit.panel({ Name = name, Position = position, Size = size, Parent = parent })
end

local function label(
	parent: Instance,
	name: string,
	position: UDim2,
	size: UDim2,
	text: string,
	textSize: number,
	font: Enum.Font,
	fit: boolean?
): TextLabel
	local element = UIKit.label({
		Name = name,
		Position = position,
		Size = size,
		Text = text,
		TextSize = textSize,
		Font = font,
		Parent = parent,
	})
	if fit then
		UIKit.fitText(element, textSize, math.max(9, textSize - 6))
	end
	return element
end

local function actionButton(parent: Instance, name: string, text: string, flex: number, order: number): TextButton
	local element = UIKit.button({
		Name = name,
		-- Width comes from UIListLayout HorizontalFlex; scale widths were overflowing
		-- the padded row (0.48+0.26+0.26 + gaps + inset).
		Size = UDim2.fromScale(0, 1),
		Text = text,
		LayoutOrder = order,
		Parent = parent,
	})
	local flexItem = Instance.new("UIFlexItem")
	flexItem.FlexMode = Enum.UIFlexMode.Fill
	flexItem.GrowRatio = flex
	flexItem.ShrinkRatio = flex
	flexItem.Parent = element
	return element
end

local function button(parent: Instance, name: string, position: UDim2, size: UDim2, text: string): TextButton
	return UIKit.button({ Name = name, Position = position, Size = size, Text = text, Parent = parent })
end

-- --------------------------------------------------------------- build ui

type ContractCardUI = {
	button: TextButton,
	heading: TextLabel,
	pressure: TextLabel,
	cargo: TextLabel,
	brief: TextLabel,
	tally: TextLabel,
}

local gui, speedLabel, conditionLabel, readoutLabel, timeLabel, integrityLabel
local objectiveLabel, hintLabel, dailyLabel, toastLabel, resultFrame, resultTitle, resultDetail, cashLabel
local contractFrame, contractTitle, contractFooter
local inviteFrame, inviteButton
local canInvite = false
local contractCards: { [string]: ContractCardUI } = {}
local resultQuestion, resultConstraint, feedbackRow
local phaseBadge, countdownLabel
local statusFrame, briefFrame, strapPanelFrame, controlsFrame, driveFrame, garageFrame
local statusAccent, speedCaption, routeTrack, routeFill, routeLabel, roleLabel
local garagePaintName, garageHint, garageRecords, garagePrevious, garageAction, garageNext
local controlsTitle, stationRowFrame, actionRowFrame, runLockLabel
local strapRows: { [string]: any } = {}
local stationButtons: { [string]: TextButton } = {}
local workButton, restartButton, switchButton
local feedbackButtons: { TextButton } = {}
local refresh: () -> ()

local DISABLED_BUTTON = Color3.fromRGB(34, 38, 46)
local PHASE_BADGE = {
	Staging = { text = "PREP · TRUCK PARKED", color = Color3.fromRGB(255, 210, 110) },
	Run = { text = "GO · ON THE ROAD", color = Color3.fromRGB(110, 220, 140) },
	Result = { text = "RUN OVER", color = Color3.fromRGB(235, 130, 100) },
}
local SWAP_RED = Color3.fromRGB(235, 70, 70)

local function setDimOverlay(frame: Frame, dimmed: boolean, caption: string?)
	local overlay = frame:FindFirstChild("DimOverlay") :: Frame?
	if dimmed then
		if not overlay then
			overlay = Instance.new("Frame")
			overlay.Name = "DimOverlay"
			overlay.BackgroundColor3 = Color3.fromRGB(8, 10, 14)
			overlay.BackgroundTransparency = 0.42
			overlay.BorderSizePixel = 0
			overlay.Size = UDim2.fromScale(1, 1)
			overlay.ZIndex = 8
			overlay.Parent = frame
			UIKit.corner(overlay, UIKit.Theme.PanelCorner)

			local captionLabel = Instance.new("TextLabel")
			captionLabel.Name = "Caption"
			captionLabel.BackgroundTransparency = 1
			captionLabel.Size = UDim2.fromScale(1, 1)
			captionLabel.Font = Enum.Font.GothamBold
			captionLabel.TextSize = 13
			captionLabel.TextColor3 = UIKit.Theme.Muted
			captionLabel.TextWrapped = true
			captionLabel.TextXAlignment = Enum.TextXAlignment.Center
			captionLabel.TextYAlignment = Enum.TextYAlignment.Center
			captionLabel.ZIndex = 9
			captionLabel.Parent = overlay
		end
		local captionLabel = overlay:FindFirstChild("Caption") :: TextLabel
		if captionLabel then
			captionLabel.Text = caption or "Locked until GO"
		end
		overlay.Visible = true
	elseif overlay then
		overlay.Visible = false
	end
end

local function setButtonLive(btn: TextButton, live: boolean, baseColor: Color3)
	UIKit.setActive(btn, live)
	UIKit.setBackground(btn, if live then baseColor else DISABLED_BUTTON)
	UIKit.setTextColor(btn, if live then Color3.fromRGB(240, 240, 240) else UIKit.Theme.Dim)
end

local function drainToast()
	if toastShowing then
		return
	end
	local nextText = table.remove(toastQueue, 1)
	if not nextText or not toastLabel then
		return
	end
	toastShowing = true
	local toastPanel = toastLabel.Parent
	if toastPanel and toastPanel:IsA("GuiObject") then
		toastPanel.BackgroundTransparency = 0.55
		toastPanel.Visible = true
		TweenService:Create(toastPanel, TOAST_FADE_IN, { BackgroundTransparency = 0.12 }):Play()
	end
	toastLabel.TextTransparency = 1
	toastLabel.TextStrokeTransparency = 1
	toastLabel.Text = nextText
	TweenService:Create(toastLabel, TOAST_FADE_IN, { TextTransparency = 0, TextStrokeTransparency = 0.5 }):Play()
	task.delay(TOAST_HOLD, function()
		if toastPanel and toastPanel:IsA("GuiObject") then
			TweenService:Create(toastPanel, TOAST_FADE_OUT, { BackgroundTransparency = 1 }):Play()
		end
		local fadeOut = TweenService:Create(toastLabel, TOAST_FADE_OUT, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		})
		fadeOut:Play()
		fadeOut.Completed:Connect(function()
			toastLabel.Text = ""
			if toastPanel and toastPanel:IsA("GuiObject") then
				toastPanel.Visible = false
				toastPanel.BackgroundTransparency = 0.12
			end
			toastLabel.TextTransparency = 0
			toastLabel.TextStrokeTransparency = 0.5
			toastShowing = false
			drainToast()
		end)
	end)
end

local function showToast(text: string)
	table.insert(toastQueue, text)
	-- Cap so a spammy pressure cadence cannot bury the next landmark warning
	-- under twenty stale messages.
	while #toastQueue > 4 do
		table.remove(toastQueue, 1)
	end
	drainToast()
end

--[[
	The contract board.

	Its own panel rather than a section inside the result frame, because that
	frame positions its feedback prompt at fixed offsets against a height that
	is recomputed per state. Growing it for a third state would have made four
	magic numbers depend on each other; this just sits below it.

	Each card is one button. There is no confirm step: the decision is small,
	the window is short, and a vote can be changed until the timer runs out.
]]
local function buildContractCard(parent: Instance, name: string, order: number): ContractCardUI
	local card = UIKit.button({
		Name = name,
		Size = UDim2.fromScale(0, 1),
		Text = "",
		LayoutOrder = order,
		Parent = parent,
	})
	local flexItem = Instance.new("UIFlexItem")
	flexItem.FlexMode = Enum.UIFlexMode.Fill
	flexItem.GrowRatio = 1
	flexItem.ShrinkRatio = 1
	flexItem.Parent = card

	local heading =
		label(card, "Contract", UDim2.fromOffset(10, 8), UDim2.new(1, -20, 0, 18), "", 14, Enum.Font.GothamBold, true)
	heading.TextXAlignment = Enum.TextXAlignment.Left

	local pressure = label(
		card,
		"Pressure",
		UDim2.fromOffset(10, 27),
		UDim2.new(1, -20, 0, 15),
		"",
		12,
		Enum.Font.GothamMedium,
		true
	)
	pressure.TextXAlignment = Enum.TextXAlignment.Left

	local cargo =
		label(card, "Cargo", UDim2.fromOffset(10, 45), UDim2.new(1, -20, 0, 15), "", 12, Enum.Font.GothamMedium, true)
	cargo.TextXAlignment = Enum.TextXAlignment.Left
	cargo.TextColor3 = UIKit.Theme.Accent

	local brief =
		label(card, "Brief", UDim2.fromOffset(10, 63), UDim2.new(1, -20, 0, 32), "", 11, Enum.Font.Gotham, true)
	brief.TextXAlignment = Enum.TextXAlignment.Left
	brief.TextWrapped = true

	local tally =
		label(card, "Tally", UDim2.fromOffset(10, 97), UDim2.new(1, -20, 0, 16), "", 12, Enum.Font.GothamBold, true)
	tally.TextXAlignment = Enum.TextXAlignment.Left

	return { button = card, heading = heading, pressure = pressure, cargo = cargo, brief = brief, tally = tally }
end

local function buildContractBoard(parent: Instance)
	contractFrame = panel(parent, "ContractBoard", UDim2.new(0.5, 0, 0.5, 150), UDim2.new(0.72, 0, 0, 172))
	contractFrame.AnchorPoint = Vector2.new(0.5, 0)
	contractFrame.BackgroundTransparency = 0.08
	contractFrame.Visible = false

	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(560, 172)
	constraint.MinSize = Vector2.new(300, 172)
	constraint.Parent = contractFrame

	contractTitle = label(
		contractFrame,
		"Title",
		UDim2.fromOffset(12, 8),
		UDim2.new(1, -24, 0, 20),
		"NEXT DELIVERY",
		14,
		Enum.Font.GothamBold,
		true
	)
	contractTitle.TextXAlignment = Enum.TextXAlignment.Center
	contractTitle.TextColor3 = UIKit.Theme.Accent

	local row = UIKit.horizontalRow(contractFrame, "Cards", 118)
	row.Position = UDim2.fromOffset(0, 30)

	contractCards.Safe = buildContractCard(row, "Safe", 1)
	contractCards.Risky = buildContractCard(row, "Risky", 2)
	for choice, card in contractCards do
		local vote = choice
		card.button.Activated:Connect(function()
			local snap = latest
			if snap and snap.offer and snap.myRole and snap.myContractVote ~= vote then
				LabRemotes.fireServer(Net.Names.LabContractVote, vote)
			end
		end)
	end

	contractFooter = label(
		contractFrame,
		"Footer",
		UDim2.fromOffset(12, 150),
		UDim2.new(1, -24, 0, 16),
		"",
		11,
		Enum.Font.Gotham,
		true
	)
	contractFooter.TextXAlignment = Enum.TextXAlignment.Center
end

--[[
	Invite.

	The co-op premise is the game's clearest identity and intentional co-play is
	a published recommendation signal, but a solo arrival currently has no way
	to turn into a crew. This is the whole social layer for now: one button, on
	the screen where a player has just found out whether they liked the run.

	CanSendGameInviteAsync yields and can fail, so it is asked once and cached.
	A false answer hides the button rather than showing one that does nothing.
]]
local function buildInvite(parent: Instance)
	inviteFrame = panel(parent, "Invite", UDim2.new(0, 12, 1, -12), UDim2.fromOffset(196, 46))
	inviteFrame.AnchorPoint = Vector2.new(0, 1)
	inviteFrame.Visible = false

	inviteButton =
		button(inviteFrame, "InviteButton", UDim2.fromOffset(8, 6), UDim2.new(1, -16, 0, 34), "INVITE A CREW")
	inviteButton.Activated:Connect(function()
		if not canInvite then
			return
		end
		local opened = pcall(function()
			SocialService:PromptGameInvite(Players.LocalPlayer)
		end)
		if opened then
			LabRemotes.fireServer(Net.Names.LabInvite, true)
		end
	end)

	task.spawn(function()
		local ok, result = pcall(function()
			return SocialService:CanSendGameInviteAsync(Players.LocalPlayer)
		end)
		canInvite = ok and result == true
	end)
end

local function buildStrapPanel(parent: Instance): Frame
	local frame = panel(parent, "Straps", UDim2.new(1, -8, 0, 0), UDim2.fromOffset(236, STRAP_PANEL_HEIGHT))
	frame.AnchorPoint = Vector2.new(1, 0)

	label(frame, "Title", UDim2.fromOffset(12, 8), UDim2.new(1, -24, 0, 20), "STRAPS", 15, Enum.Font.GothamBlack)
	local legend = label(
		frame,
		"Legend",
		UDim2.fromOffset(44, 25),
		UDim2.new(1, -104, 0, 14),
		"HEALTH                         STATE",
		9,
		Enum.Font.GothamBold,
		true
	)
	legend.TextColor3 = UIKit.Theme.Dim

	for index, id in LabConfig.StrapOrder do
		local y = 42 + (index - 1) * 34

		local row = UIKit.frame({
			Name = id,
			Position = UDim2.fromOffset(12, y),
			Size = UDim2.new(1, -24, 0, 28),
			BackgroundTransparency = 1,
			Parent = frame,
		})

		local tag =
			label(row, "Tag", UDim2.fromOffset(0, 0), UDim2.fromOffset(28, 28), id, 14, Enum.Font.GothamBold, true)

		local track = UIKit.frame({
			Name = "Track",
			Position = UDim2.fromOffset(32, 8),
			Size = UDim2.new(1, -92, 0, 12),
			BackgroundColor3 = UIKit.Theme.Track,
			Parent = row,
		})
		UIKit.corner(track, 6)

		local fill = UIKit.frame({
			Name = "Fill",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = UIKit.Theme.Good,
			Parent = track,
		})
		UIKit.corner(fill, 6)

		local tension = UIKit.frame({
			Name = "Tension",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.fromOffset(0, 4),
			BackgroundColor3 = Color3.fromRGB(255, 235, 120),
			ZIndex = 2,
			Parent = track,
		})

		local status = label(
			row,
			"Status",
			UDim2.new(1, -58, 0, 0),
			UDim2.fromOffset(58, 28),
			"",
			11,
			Enum.Font.GothamMedium,
			true
		)
		status.TextXAlignment = Enum.TextXAlignment.Right

		strapRows[id] = { row = row, tag = tag, fill = fill, tension = tension, status = status }
	end

	return frame
end

-- Give discrete actions an immediate visual state while the server validates
-- them. The snapshot remains the authority; these pending values expire if an
-- acknowledgement is delayed or the request is rejected.
local function requestStation(id: string)
	local snap = latest
	if
		not snap
		or snap.myRole ~= "Strapper"
		or (snap.phase ~= "Staging" and snap.phase ~= "Run")
		or snap.swapWarning
		or snap.swapActive
	then
		return
	end
	pendingStation = id
	pendingStationAt = os.clock()
	LabRemotes.fireServer(Net.Names.LabMoveTo, id)
end

local function requestRoleSwitch()
	local snap = latest
	if
		not snap
		or snap.spectating
		or (snap.phase ~= "Staging" and snap.phase ~= "Run")
		or snap.swapWarning
		or snap.swapActive
	then
		return
	end
	pendingRoleFrom = snap.myRole
	pendingRoleAt = os.clock()
	LabRemotes.fireServer(Net.Names.LabSwitchRole)
end

local function buildControls(parent: Instance): Frame
	local frame = panel(parent, "Controls", UDim2.new(0, 8, 1, -8), UDim2.fromOffset(360, 164))
	frame.AnchorPoint = Vector2.new(0, 1)
	local controlsConstraint = Instance.new("UISizeConstraint")
	controlsConstraint.MinSize = Vector2.new(280, 164)
	controlsConstraint.MaxSize = Vector2.new(420, 180)
	controlsConstraint.Parent = frame

	controlsTitle = label(
		frame,
		"Title",
		UDim2.fromOffset(12, 8),
		UDim2.new(0.58, -12, 0, 18),
		"STATIONS",
		14,
		Enum.Font.GothamBlack
	)
	roleLabel = label(
		frame,
		"Role",
		UDim2.new(0.58, 0, 0, 8),
		UDim2.new(0.42, -12, 0, 18),
		"YOU · CREW",
		11,
		Enum.Font.GothamBold,
		true
	)
	roleLabel.TextXAlignment = Enum.TextXAlignment.Right
	roleLabel.TextColor3 = UIKit.Theme.Accent

	stationRowFrame = UIKit.horizontalRow(frame, "StationRow", TOUCH_MIN)
	stationRowFrame.Position = UDim2.fromOffset(0, 30)

	for index, id in LabConfig.StationOrder do
		local element = actionButton(stationRowFrame, id, tostring(index) .. " " .. id, 0.25, index)
		element.Activated:Connect(function()
			requestStation(id)
		end)
		stationButtons[id] = element
	end

	runLockLabel = label(
		frame,
		"RunLock",
		UDim2.fromOffset(12, 78),
		UDim2.new(1, -24, 0, 14),
		"Drive & straps unlock when GO hits",
		11,
		Enum.Font.GothamMedium
	)
	runLockLabel.TextColor3 = UIKit.Theme.Dim
	runLockLabel.TextXAlignment = Enum.TextXAlignment.Center

	actionRowFrame = UIKit.horizontalRow(frame, "ActionRow", TOUCH_MIN)
	actionRowFrame.Position = UDim2.fromOffset(0, 96)

	workButton = actionButton(actionRowFrame, "Work", "HOLD E · WORK", 0.48, 1)
	workButton.BackgroundColor3 = UIKit.Theme.Positive

	local function setWorking(state: boolean)
		local snap = latest
		local canWork = snap
			and snap.phase == "Run"
			and not snap.swapActive
			and (snap.myRole == "Strapper" or (snap.myRole == "Driver" and snap.solo))
		if state and not canWork then
			if snap and snap.phase ~= "Run" then
				showToast("Wait for GO to work a strap.")
			elseif snap and snap.myRole == "Driver" then
				showToast("Switch to strapper to work a strap.")
			end
			return
		end
		if working == state then
			return
		end
		working = state
		LabRemotes.fireServer(Net.Names.LabWork, state)
		workButton.BackgroundColor3 = if state then Color3.fromRGB(95, 180, 110) else UIKit.Theme.Positive
	end

	-- Always notify the server. setWorking(false) no-ops when already false, which
	-- left a held-E ghost through Result→GO because InputBegan never re-fired.
	local function releaseWorking()
		if working then
			working = false
			LabRemotes.fireServer(Net.Names.LabWork, false)
			workButton.BackgroundColor3 = UIKit.Theme.Positive
		end
	end

	local function clearDriveLocal()
		keyForward, keyReverse, keyLeft, keyRight, keyBrake = false, false, false, false, false
		touchSteerAxis, touchThrottleAxis = 0, 0
		touchBrake = false
		padThrottle, padReverse, padSteer, padBrake = 0, 0, 0, false
	end

	LabUI.setWorking = setWorking
	LabUI.releaseWorking = releaseWorking
	LabUI.clearDriveLocal = clearDriveLocal

	UIKit.bindHold(workButton, setWorking)

	switchButton = actionButton(actionRowFrame, "Switch", "T · ROLE", 0.26, 2)
	switchButton.Activated:Connect(function()
		requestRoleSwitch()
	end)

	restartButton = actionButton(actionRowFrame, "Restart", "R · RESET", 0.26, 3)
	restartButton.BackgroundColor3 = UIKit.Theme.Danger
	restartButton.Activated:Connect(function()
		LabRemotes.fireServer(Net.Names.LabRestart)
	end)

	return frame
end

local function controlChromeLabels(device: string): (string, string, string)
	if device == "Touch" then
		return "HOLD · WORK", "ROLE", "RESET"
	elseif device == "Gamepad" then
		return "HOLD A · WORK", "Y · ROLE", "SELECT · RESET"
	end
	return "HOLD E · WORK", "T · ROLE", "R · RESET"
end

local function workIdleLabel(snap: LabTypes.LabSnapshot, device: string): string
	local verb = if device == "Gamepad" then "A" elseif device == "Touch" then "HOLD" else "E"
	if snap.myStation then
		return verb .. " · " .. snap.myStation
	end
	if snap.myRole == "Driver" and snap.solo then
		return verb .. " · STRAP"
	end
	return "NO STATION"
end

local function currentDriveInput()
	local throttle = (if keyForward then 1 else 0) - (if keyReverse then 1 else 0)
	throttle += padThrottle - padReverse
	throttle += touchThrottleAxis

	local steering = (if keyRight then 1 else 0) - (if keyLeft then 1 else 0)
	if math.abs(padSteer) > math.abs(steering) then
		steering = padSteer
	end
	if math.abs(touchSteerAxis) > math.abs(steering) then
		steering = touchSteerAxis
	end

	local clampedSteer = math.clamp(steering, -1, 1)
	-- Quantize so stick micro-noise does not burn the LabDrive token bucket.
	clampedSteer = math.floor(clampedSteer / STEER_QUANTIZE + 0.5) * STEER_QUANTIZE
	return {
		throttle = math.clamp(throttle, -1, 1),
		steering = clampedSteer,
		braking = keyBrake or touchBrake or padBrake,
	}
end

--[[
	Gamepad stick Change can exceed the server LabDrive bucket. CAS/touch/keys
	update local axes; Heartbeat flushes at 30 Hz. Discrete Begin/End edges send
	immediately. Identical payloads are skipped except a keepalive so `at`
	stays fresh on the server.
]]
local function sendDriveInput(forceNeutral: boolean?, forceSend: boolean?)
	local snap = latest
	if not snap or snap.myRole ~= "Driver" or snap.phase ~= "Run" or snap.swapActive then
		return
	end
	local drive = if forceNeutral then { throttle = 0, steering = 0, braking = false } else currentDriveInput()
	local identical = drive.throttle == lastSentDrive.throttle
		and drive.steering == lastSentDrive.steering
		and drive.braking == lastSentDrive.braking
	local now = os.clock()
	if identical and not forceNeutral and not forceSend then
		if now - lastDriveSendAt < DRIVE_KEEPALIVE_SECONDS then
			return
		end
	end
	drive.sentAt = Workspace:GetServerTimeNow()
	LabRemotes.fireServer(Net.Names.LabDrive, drive)
	lastSentDrive = {
		throttle = drive.throttle,
		steering = drive.steering,
		braking = drive.braking,
	}
	lastDriveSendAt = now
end

local function buildTouchDrive(parent: Instance): Frame
	--[[
		One-thumb stick (X steer, Y throttle) + a large brake. Replaces the old
		digital GO/←/→/REV grid that felt nothing like driving on a phone.
	]]
	local frame = panel(parent, "Drive", UDim2.new(1, -8, 1, -8), UDim2.fromOffset(268, 200))
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.Visible = false
	label(frame, "Title", UDim2.fromOffset(12, 6), UDim2.new(1, -24, 0, 18), "DRIVE", 14, Enum.Font.GothamBlack)

	local stickWell = Instance.new("Frame")
	stickWell.Name = "StickWell"
	stickWell.BackgroundColor3 = UIKit.Theme.Track
	stickWell.BackgroundTransparency = 0.15
	stickWell.BorderSizePixel = 0
	stickWell.Position = UDim2.fromOffset(12, 36)
	stickWell.Size = UDim2.fromOffset(148, 148)
	stickWell.Parent = frame
	UIKit.corner(stickWell, 74)
	local wellStroke = Instance.new("UIStroke")
	wellStroke.Color = UIKit.Theme.PanelEdge
	wellStroke.Thickness = 1
	wellStroke.Transparency = 0.55
	wellStroke.Parent = stickWell

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.BackgroundColor3 = UIKit.Theme.Accent
	knob.BackgroundTransparency = 0.1
	knob.BorderSizePixel = 0
	knob.Position = UDim2.fromScale(0.5, 0.5)
	knob.Size = UDim2.fromOffset(52, 52)
	knob.Parent = stickWell
	UIKit.corner(knob, 26)

	local stickHint = label(
		frame,
		"StickHint",
		UDim2.fromOffset(12, 186),
		UDim2.fromOffset(148, 12),
		"STEER · THROTTLE",
		9,
		Enum.Font.GothamMedium,
		true
	)
	stickHint.TextXAlignment = Enum.TextXAlignment.Center
	stickHint.TextColor3 = UIKit.Theme.Dim

	local activeTouch: InputObject? = nil

	local function axisWithDeadzone(value: number): number
		local magnitude = math.abs(value)
		if magnitude < STICK_DEADZONE then
			return 0
		end
		return math.sign(value) * (magnitude - STICK_DEADZONE) / (1 - STICK_DEADZONE)
	end

	local function resetStick()
		activeTouch = nil
		touchSteerAxis = 0
		touchThrottleAxis = 0
		knob.Position = UDim2.fromScale(0.5, 0.5)
		sendDriveInput(false, true)
	end

	local function applyStick(screenPos: Vector2)
		local size = stickWell.AbsoluteSize
		if size.X < 1 or size.Y < 1 then
			return
		end
		local center = stickWell.AbsolutePosition + size * 0.5
		local delta = screenPos - center
		local maxRadius = math.max(8, size.X * 0.5 - 26)
		local magnitude = delta.Magnitude
		if magnitude > maxRadius and magnitude > 0 then
			delta = delta.Unit * maxRadius
		end
		knob.Position = UDim2.fromOffset(size.X * 0.5 + delta.X, size.Y * 0.5 + delta.Y)

		local nx = delta.X / maxRadius
		local ny = -delta.Y / maxRadius
		touchSteerAxis = axisWithDeadzone(nx)
		touchThrottleAxis = axisWithDeadzone(ny)
		sendDriveInput()
	end

	stickWell.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.Touch
			and input.UserInputType ~= Enum.UserInputType.MouseButton1
		then
			return
		end
		activeTouch = input
		applyStick(Vector2.new(input.Position.X, input.Position.Y))
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject)
		if input ~= activeTouch then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.Touch
			and input.UserInputType ~= Enum.UserInputType.MouseMovement
		then
			return
		end
		applyStick(Vector2.new(input.Position.X, input.Position.Y))
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input == activeTouch then
			resetStick()
		end
	end)

	local brake = button(frame, "Brake", UDim2.fromOffset(172, 48), UDim2.fromOffset(84, 136), "BRAKE")
	brake.BackgroundColor3 = UIKit.Theme.Danger
	UIKit.bindHold(brake, function(state: boolean)
		touchBrake = state
		sendDriveInput(false, true)
	end)

	return frame
end

local function buildGarage(parent: Instance)
	garageFrame = panel(parent, "Garage", UDim2.new(1, -8, 0, GARAGE_TOP), UDim2.fromOffset(300, 148))
	garageFrame.AnchorPoint = Vector2.new(1, 0)
	label(
		garageFrame,
		"Title",
		UDim2.fromOffset(12, 8),
		UDim2.new(1, -24, 0, 18),
		"GARAGE - TRUCK PAINT",
		14,
		Enum.Font.GothamBlack
	)
	garagePaintName = label(
		garageFrame,
		"PaintName",
		UDim2.fromOffset(12, 30),
		UDim2.new(1, -24, 0, 22),
		"FACTORY RED",
		17,
		Enum.Font.GothamBold,
		true
	)
	garagePaintName.TextXAlignment = Enum.TextXAlignment.Center

	garagePrevious = button(garageFrame, "Previous", UDim2.fromOffset(8, 56), UDim2.fromOffset(44, TOUCH_MIN), "<")
	garageAction = button(garageFrame, "Action", UDim2.fromOffset(58, 56), UDim2.new(1, -116, 0, TOUCH_MIN), "EQUIPPED")
	garageNext = button(garageFrame, "Next", UDim2.new(1, -52, 0, 56), UDim2.fromOffset(44, TOUCH_MIN), ">")
	garageHint = label(
		garageFrame,
		"Hint",
		UDim2.fromOffset(10, 104),
		UDim2.new(1, -20, 0, 16),
		"Driver paint applies to the shared truck.",
		11,
		Enum.Font.GothamMedium,
		true
	)
	garageHint.TextXAlignment = Enum.TextXAlignment.Center
	garageHint.TextColor3 = UIKit.Theme.Muted
	garageRecords = label(
		garageFrame,
		"Records",
		UDim2.fromOffset(10, 122),
		UDim2.new(1, -20, 0, 16),
		"NO DELIVERIES YET",
		10,
		Enum.Font.GothamBold,
		true
	)
	garageRecords.TextXAlignment = Enum.TextXAlignment.Center
	garageRecords.TextColor3 = UIKit.Theme.Accent

	garagePrevious.Activated:Connect(function()
		if #paintDefs == 0 then
			return
		end
		selectedPaintIndex = ((selectedPaintIndex - 2) % #paintDefs) + 1
		refresh()
	end)
	garageNext.Activated:Connect(function()
		if #paintDefs == 0 then
			return
		end
		selectedPaintIndex = (selectedPaintIndex % #paintDefs) + 1
		refresh()
	end)
	garageAction.Activated:Connect(function()
		local snap = latest
		local paint = paintDefs[selectedPaintIndex]
		if not snap or not paint or paintPending or snap.phase == "Run" or snap.spectating then
			return
		end
		local owned = paint.cost <= 0 or snap.unlockedPaints[paint.id] == true
		if (owned and snap.equippedPaint == paint.id) or (not owned and snap.credits < paint.cost) then
			return
		end
		paintPending = true
		paintPendingAt = os.clock()
		LabRemotes.fireServer(Net.Names.LabPaint, paint.id)
		refresh()
	end)
end

local function build()
	gui = UIKit.screen("CargoLabHUD", player:WaitForChild("PlayerGui"))
	safeRoot = UIKit.safeArea(gui)
	local root = safeRoot

	-- Without the numeric readout the status card is three lines tall, with
	-- room left for the integrity warning that only appears when damaged.
	local statusHeight = if DevConfig.ShowDebugOverlay then 198 else 162
	statusFrame = panel(root, "Status", UDim2.fromOffset(8, 0), UDim2.fromOffset(300, statusHeight))
	local status = statusFrame
	statusAccent = UIKit.frame({
		Name = "Accent",
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(4, statusHeight),
		BackgroundColor3 = UIKit.Theme.Good,
		Parent = status,
	})
	speedCaption = label(
		status,
		"SpeedCaption",
		UDim2.fromOffset(14, 7),
		UDim2.fromOffset(90, 14),
		"SPEED",
		10,
		Enum.Font.GothamBold
	)
	speedCaption.TextColor3 = UIKit.Theme.Dim
	speedLabel =
		label(status, "Speed", UDim2.fromOffset(14, 19), UDim2.fromOffset(100, 32), "0", 29, Enum.Font.GothamBlack)
	conditionLabel = label(
		status,
		"Condition",
		UDim2.fromOffset(14, 52),
		UDim2.new(1, -24, 0, 24),
		"LOAD SECURE",
		19,
		Enum.Font.GothamBlack,
		true
	)

	routeTrack = UIKit.frame({
		Name = "RouteTrack",
		Position = UDim2.fromOffset(14, 82),
		Size = UDim2.new(1, -28, 0, 8),
		BackgroundColor3 = UIKit.Theme.Track,
		Parent = status,
	})
	UIKit.corner(routeTrack, 5)
	routeFill = UIKit.frame({
		Name = "RouteFill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = UIKit.Theme.Accent,
		Parent = routeTrack,
	})
	UIKit.corner(routeFill, 5)
	routeLabel =
		label(status, "Route", UDim2.fromOffset(14, 93), UDim2.new(1, -28, 0, 16), "ROUTE 0%", 11, Enum.Font.GothamBold)
	routeLabel.TextColor3 = UIKit.Theme.Dim

	if DevConfig.ShowDebugOverlay then
		readoutLabel = label(
			status,
			"Readout",
			UDim2.fromOffset(14, 112),
			UDim2.new(1, -24, 0, 32),
			"",
			12,
			Enum.Font.GothamMedium,
			true
		)
		readoutLabel.TextColor3 = UIKit.Theme.Muted
		readoutLabel.TextWrapped = true
	end

	integrityLabel = label(
		status,
		"Integrity",
		UDim2.fromOffset(14, if DevConfig.ShowDebugOverlay then 150 else 112),
		UDim2.new(1, -24, 0, 18),
		"",
		14,
		Enum.Font.GothamMedium
	)
	integrityLabel.TextColor3 = UIKit.Theme.Muted
	integrityLabel.Visible = false

	timeLabel =
		label(status, "Time", UDim2.new(0.42, 0, 0, 13), UDim2.new(0.58, -14, 0, 30), "", 13, Enum.Font.GothamMedium)
	timeLabel.TextXAlignment = Enum.TextXAlignment.Right
	timeLabel.TextColor3 = UIKit.Theme.Dim

	cashLabel = label(
		status,
		"Cash",
		UDim2.fromOffset(14, if DevConfig.ShowDebugOverlay then 176 else 138),
		UDim2.new(1, -24, 0, 18),
		"CARGO CASH - LOADING",
		13,
		Enum.Font.GothamBold
	)
	cashLabel.TextColor3 = UIKit.Theme.Accent
	cashLabel.ZIndex = 9

	-- Scale-based width with a max so wide monitors do not stretch the brief
	-- into a banner, and phones do not clip a 520px fixed card.
	briefFrame = panel(root, "Brief", UDim2.fromScale(0.5, 0), UDim2.new(0.72, 0, 0, 104))
	local brief = briefFrame
	brief.AnchorPoint = Vector2.new(0.5, 0)
	local briefConstraint = Instance.new("UISizeConstraint")
	briefConstraint.MaxSize = Vector2.new(560, 104)
	briefConstraint.MinSize = Vector2.new(220, 78)
	briefConstraint.Parent = brief

	phaseBadge = label(
		brief,
		"Phase",
		UDim2.fromOffset(14, 6),
		UDim2.new(1, -28, 0, 18),
		"PREP",
		13,
		Enum.Font.GothamBlack,
		true
	)
	phaseBadge.TextXAlignment = Enum.TextXAlignment.Center

	countdownLabel =
		label(brief, "Countdown", UDim2.fromOffset(14, 24), UDim2.new(1, -28, 0, 32), "8", 32, Enum.Font.GothamBlack)
	countdownLabel.TextXAlignment = Enum.TextXAlignment.Center
	countdownLabel.TextColor3 = UIKit.Theme.Accent

	objectiveLabel = label(
		brief,
		"Objective",
		UDim2.fromOffset(14, 58),
		UDim2.new(1, -28, 0, 22),
		"",
		16,
		Enum.Font.GothamBold,
		true
	)
	objectiveLabel.TextXAlignment = Enum.TextXAlignment.Center
	objectiveLabel.TextWrapped = true
	hintLabel =
		label(brief, "Hint", UDim2.fromOffset(14, 80), UDim2.new(1, -28, 0, 20), "", 12, Enum.Font.GothamMedium, true)
	hintLabel.TextXAlignment = Enum.TextXAlignment.Center
	hintLabel.TextColor3 = UIKit.Theme.Muted
	hintLabel.TextWrapped = true

	--[[
		Today's objective, on the prep screen and nowhere else. This is the one
		moment it can change how somebody drives; during a run it would be a line
		of text competing with the load, and on the result screen the payout says
		it better than the brief would.
	]]
	dailyLabel =
		label(brief, "Daily", UDim2.fromOffset(14, 100), UDim2.new(1, -28, 0, 18), "", 11, Enum.Font.GothamBold, true)
	dailyLabel.TextXAlignment = Enum.TextXAlignment.Center
	dailyLabel.Visible = false

	local toastPanel = panel(root, "Toast", UDim2.new(0.5, 0, 0, 112), UDim2.new(0.62, 0, 0, 36))
	toastPanel.AnchorPoint = Vector2.new(0.5, 0)
	toastPanel.BackgroundTransparency = 0.12
	toastPanel.Visible = false
	local toastConstraint = Instance.new("UISizeConstraint")
	toastConstraint.MaxSize = Vector2.new(520, 40)
	toastConstraint.MinSize = Vector2.new(200, 32)
	toastConstraint.Parent = toastPanel
	toastLabel =
		label(toastPanel, "Text", UDim2.fromOffset(10, 0), UDim2.new(1, -20, 1, 0), "", 15, Enum.Font.GothamBold, true)
	toastLabel.TextXAlignment = Enum.TextXAlignment.Center
	toastLabel.TextYAlignment = Enum.TextYAlignment.Center
	toastLabel.TextColor3 = UIKit.Theme.Accent
	toastLabel.TextStrokeTransparency = 0.5

	resultFrame = panel(root, "Result", UDim2.fromScale(0.5, 0.5), UDim2.new(0.7, 0, 0, 168))
	resultFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	resultFrame.BackgroundTransparency = 0.08
	resultFrame.Visible = false
	resultConstraint = Instance.new("UISizeConstraint")
	resultConstraint.MaxSize = Vector2.new(520, 168)
	resultConstraint.MinSize = Vector2.new(280, 168)
	resultConstraint.Parent = resultFrame
	resultTitle = label(
		resultFrame,
		"Title",
		UDim2.fromOffset(16, 14),
		UDim2.new(1, -32, 0, 44),
		"",
		26,
		Enum.Font.GothamBlack,
		true
	)
	resultTitle.TextXAlignment = Enum.TextXAlignment.Center
	resultTitle.TextYAlignment = Enum.TextYAlignment.Center
	resultDetail =
		label(resultFrame, "Detail", UDim2.fromOffset(16, 62), UDim2.new(1, -32, 0, 88), "", 15, Enum.Font.GothamMedium)
	resultDetail.TextXAlignment = Enum.TextXAlignment.Center
	resultDetail.TextWrapped = true

	resultQuestion = label(
		resultFrame,
		"FeedbackQuestion",
		UDim2.fromOffset(12, 156),
		UDim2.new(1, -24, 0, 22),
		"WOULD YOU PLAY ANOTHER RUN?",
		14,
		Enum.Font.GothamBold,
		true
	)
	resultQuestion.TextXAlignment = Enum.TextXAlignment.Center
	resultQuestion.TextColor3 = UIKit.Theme.Accent
	resultQuestion.Visible = false

	feedbackRow = UIKit.horizontalRow(resultFrame, "FeedbackRow", TOUCH_MIN)
	feedbackRow.Position = UDim2.fromOffset(0, 186)
	feedbackRow.Visible = false
	for order, answer in { "Yes", "Maybe", "No" } do
		local response = answer
		local element = actionButton(feedbackRow, answer, string.upper(answer), 1 / 3, order)
		element.Activated:Connect(function()
			if latest and latest.feedbackRequested and not feedbackPending then
				feedbackPending = true
				feedbackPendingAt = os.clock()
				LabRemotes.fireServer(Net.Names.LabFeedback, response)
				refresh()
			end
		end)
		table.insert(feedbackButtons, element)
	end

	buildContractBoard(root)
	buildInvite(root)

	strapPanelFrame = buildStrapPanel(root)
	buildGarage(root)
	controlsFrame = buildControls(root)
	driveFrame = buildTouchDrive(root)
end

-- ---------------------------------------------------------------- refresh

local OUTCOME_HEADLINE = {
	Delivered = "Clean delivery.",
	PartialLoss = "Delivered, but the load took a beating.",
	CargoLost = "You lost the load.",
	TruckWrecked = "Not going anywhere. 🥀",
	TimeExpired = "Ran out of road time.",
}

local OUTCOME_DETAIL = {
	Delivered = "Every strap held and the load never left the deck.",
	PartialLoss = "You got there, but the load is not what it was.",
	CargoLost = "The load is somewhere back on the road.",
	TimeExpired = "The clock beat you to the depot.",
}

--[[
	Draw the board, or hide it.

	A spectator sees the cards and the tally but cannot press either: they are
	not going to be on the run this decides. The leading card is highlighted
	rather than the one this player voted for, because the interesting state on
	a four-player crew is where the crew is, not where you are.
]]
local function refreshContractBoard(snap: LabTypes.LabSnapshot, compact: boolean, topOffset: number?)
	local offer = snap.offer
	UIKit.setVisible(contractFrame, offer ~= nil)
	if not offer then
		return
	end

	UIKit.set(contractFrame, "AnchorPoint", Vector2.new(0.5, 0))
	UIKit.set(
		contractFrame,
		"Position",
		if compact then UDim2.new(0.5, 0, 0, topOffset or 0) else UDim2.new(0.5, 0, 0.5, 150)
	)
	UIKit.setSize(contractFrame, UDim2.new(if compact then 0.92 else 0.72, 0, 0, 172))

	local canVote = snap.myRole ~= nil
	UIKit.setText(
		contractTitle,
		string.format("RUN %d · CHOOSE THE CONTRACT · %ds", offer.runNumber, offer.secondsRemaining)
	)

	for choice, card in contractCards do
		local view = if choice == "Risky" then offer.risky else offer.safe
		UIKit.setText(card.heading, view.contractLabel)
		UIKit.setText(card.pressure, string.format("%s · x%.2g PAY", view.difficultyLabel, view.rewardMultiplier))
		UIKit.setText(card.cargo, view.cargoLabel)
		UIKit.setText(card.brief, view.contractBrief)

		local mine = snap.myContractVote == choice
		UIKit.setText(
			card.tally,
			if view.votes == 0
				then (if mine then "YOUR PICK" else "")
				else string.format(
					"%d VOTE%s%s",
					view.votes,
					if view.votes == 1 then "" else "S",
					if mine then " · YOURS" else ""
				)
		)

		setButtonLive(
			card.button,
			canVote and not mine,
			if offer.leading == choice
				then (if choice == "Risky" then UIKit.Theme.Danger else UIKit.Theme.Positive)
				else UIKit.Theme.Button
		)
	end

	UIKit.setText(
		contractFooter,
		if not canVote
			then "Spectating. The crew decides this one."
			elseif snap.myContractVote == nil then "No vote yet. A tie or an empty board takes the safe run."
			else "Tap the other card to change your vote."
	)
end

local function formatRecordTime(seconds: number): string
	local whole = math.max(0, math.floor(seconds + 0.5))
	return string.format("%d:%02d", math.floor(whole / 60), whole % 60)
end

local function recordValue(records: LabTypes.PersonalRecords?, key: string): string
	if not records then
		return ""
	end
	if key == "bestConditionPct" then
		return string.format("%d%%", math.floor(records.bestConditionPct + 0.5))
	elseif key == "bestTimeSeconds" then
		return formatRecordTime(records.bestTimeSeconds)
	elseif key == "bestPayout" then
		return tostring(math.floor(records.bestPayout + 0.5)) .. " CASH"
	elseif key == "bestDeliveryStreak" then
		return tostring(records.bestDeliveryStreak)
	elseif key == "deliveries" then
		return tostring(records.deliveries)
	end
	return ""
end

local function recordsSummary(records: LabTypes.PersonalRecords?): string
	if not records or records.deliveries <= 0 then
		return "NO DELIVERIES YET"
	end
	return string.format(
		"BEST %s  |  %d%% CARGO  |  STREAK %d",
		formatRecordTime(records.bestTimeSeconds),
		math.floor(records.bestConditionPct + 0.5),
		records.deliveryStreak
	)
end

local function resultBody(snap: LabTypes.LabSnapshot): string
	local lines: { string } = {}
	if snap.outcome == "TruckWrecked" then
		-- Always says something. RunCauses.explain falls back to generic advice
		-- rather than leaving the one screen that explains a wreck blank.
		table.insert(lines, RunCauses.explain(snap.outcomeCause))
	elseif snap.outcome and OUTCOME_DETAIL[snap.outcome] then
		table.insert(lines, OUTCOME_DETAIL[snap.outcome])
	end
	if snap.contractComplete ~= nil then
		table.insert(
			lines,
			if snap.contractComplete
				then string.format("%s COMPLETE · x%.2g PAY", snap.contractLabel, snap.rewardMultiplier)
				else snap.contractLabel .. " MISSED"
		)
	end
	if snap.rewardEarned > 0 then
		table.insert(lines, string.format("+%d CARGO CASH · BALANCE %d", snap.rewardEarned, snap.credits))
	end

	-- The daily gets its own line rather than being folded into the payout. It
	-- is the reason to come back tomorrow, so it should be legible as a separate
	-- thing that happened rather than as a bigger number.
	if snap.dailyEarned > 0 then
		table.insert(
			lines,
			string.upper(string.format("DAILY COMPLETE · %s · +%d", snap.dailyLabel, snap.dailyEarned))
		)
	end

	--[[
		Records, named while the run that beat them is still on screen. Only the
		first is shown: a run that beats three at once is usually the first
		delivery, and listing all of them buries the one that means something.
	]]
	local beaten = snap.recordsBeaten
	if beaten and #beaten > 0 then
		local key = beaten[1]
		local recordName = Achievements.RecordLabel[key] or "Record"
		local value = recordValue(snap.records, key)
		table.insert(lines, string.upper("NEW BEST | " .. recordName .. (if value ~= "" then " " .. value else "")))
	end

	table.insert(lines, string.format("Restarting in %ds · Press R to go now", snap.restartSeconds))
	return table.concat(lines, "\n")
end

local STATION_MINE = Color3.fromRGB(95, 130, 190)
local STATION_TARGET = Color3.fromRGB(140, 120, 60)
local STRAP_BROKEN = Color3.fromRGB(120, 44, 44)
local STATUS_REFIT = Color3.fromRGB(255, 205, 90)
local STATUS_GONE = Color3.fromRGB(220, 90, 90)
local STATUS_WORKED = Color3.fromRGB(120, 220, 150)
local TAG_IDLE = Color3.fromRGB(200, 205, 215)

local function resetPresentation(snap: LabTypes.LabSnapshot)
	local straps = {}
	for _, entry in snap.straps do
		straps[entry.id] = { health = entry.health, tension = entry.tension }
	end
	presented = {
		phase = snap.phase,
		speed = snap.speed,
		routeProgress = snap.routeProgress,
		cargoReadout = snap.cargoReadout,
		cargoOffset = snap.cargoOffset,
		cargoLeanDeg = snap.cargoLeanDeg,
		chassisIntegrity = snap.chassisIntegrity,
		straps = straps,
	}
end

local function hintFor(role: string?, device: string, solo: boolean?, offTruck: boolean?, phase: string): string
	if offTruck then
		if device == "Gamepad" then
			return "Press Select if you stay stuck."
		end
		return "Press R if you stay stuck."
	end
	if phase == "Staging" then
		if role == "Driver" then
			if solo then
				return "T swaps Driver and Strapper before GO."
			end
			return "You drive when the countdown hits GO."
		elseif role == "Strapper" then
			return "Tap 1-4 or D-pad to pick your corner."
		end
		return "T switches Driver and Strapper."
	end
	if phase == "Result" then
		return "Press R to skip the wait."
	end
	if role == "Driver" then
		if solo then
			if device == "Gamepad" then
				return "Drive with triggers and stick. Hold A to work the weakest strap."
			elseif device == "Touch" then
				return "Stick to drive, BRAKE to stop. Hold WORK to tighten the weakest strap."
			end
			return "W/S drive, A/D steer, Space brake. Hold E to work the weakest strap."
		end
		if device == "Gamepad" then
			return "Right trigger drive, left stick steer, X brake. Slow down before the corner."
		elseif device == "Touch" then
			return "Stick steers and throttles; BRAKE stops. Slow down before the corner."
		end
		return "W/S drive, A/D steer, Space brake. Slow down before you can see round the corner."
	elseif role == "Strapper" then
		if device == "Gamepad" then
			return "D-pad cycle corners. Hold A to work the strap you are standing at."
		elseif device == "Touch" then
			return "Tap a station, then hold WORK on the strap you are standing at."
		end
		return "1-4 to move to a corner. Hold E to work the strap you are standing at."
	end
	return "Waiting for a seat on the truck."
end

local function conditionLine(snap: LabTypes.LabSnapshot): string
	local base = CONDITION_TEXT[snap.condition] or snap.condition
	if snap.conditionTrend == "Worsening" then
		return base .. "  ↓"
	elseif snap.conditionTrend == "Recovering" then
		return base .. "  ↑"
	end
	return base
end

--[[
	Every write here goes through a guarded setter.

	The snapshot arrives at 10 Hz whether or not anything in it moved, and most
	of what it carries is stable for seconds at a time: the objective text, the
	hint, four strap colours, four station button colours. Writing all forty
	properties unconditionally meant the great majority of writes were setting a
	value to itself.
]]
refresh = function()
	local snap = latest
	if not snap then
		return
	end
	local view = presented or snap

	local phase = snap.phase
	local isPrep = phase == "Staging"
	local isRun = phase == "Run"
	local isResult = phase == "Result"
	local offTruck = snap.myOffTruck or snap.myThrown
	local swapWarning = isRun and snap.swapWarning
	local swapActive = isRun and snap.swapActive
	local spectating = snap.spectating
	if feedbackPending and os.clock() - feedbackPendingAt >= PENDING_ACTION_TIMEOUT then
		feedbackPending = false
	end
	if paintPending and os.clock() - paintPendingAt >= PENDING_ACTION_TIMEOUT then
		paintPending = false
	end
	if not paintSelectionInitialized and snap.progressionReady then
		for index, paint in paintDefs do
			if paint.id == snap.equippedPaint then
				selectedPaintIndex = index
				break
			end
		end
		paintSelectionInitialized = true
	end

	UIKit.setText(
		cashLabel,
		if not snap.progressionReady
			then "CARGO CASH - LOADING"
			elseif snap.progressionSaving then string.format("CARGO CASH %d", snap.credits)
			else string.format("CARGO CASH %d - NOT SAVING", snap.credits)
	)

	local badge = PHASE_BADGE[phase] or PHASE_BADGE.Staging
	local conditionColor = CONDITION_COLOR[snap.condition] or UIKit.Theme.Text
	UIKit.setBackground(statusAccent, if isPrep or isResult then UIKit.Theme.Dim else conditionColor)
	UIKit.setSize(routeFill, UDim2.fromScale(math.clamp(view.routeProgress, 0, 1), 1))
	UIKit.setText(routeLabel, string.format("ROUTE %d%%", math.floor(view.routeProgress * 100 + 0.5)))
	UIKit.setBackground(routeFill, UIKit.Theme.Accent)
	UIKit.setText(
		phaseBadge,
		if swapActive
			then "SWAP · HANDOFF"
			elseif swapWarning then "SWAP AHEAD"
			else badge.text .. " · " .. snap.difficultyLabel
	)
	UIKit.setTextColor(
		phaseBadge,
		if swapActive or swapWarning
			then SWAP_RED
			elseif snap.difficultyLabel == "CATASTROPHE" then UIKit.Theme.Bad
			else badge.color
	)
	UIKit.setVisible(countdownLabel, isPrep)
	if isPrep then
		local seconds = snap.restartSeconds
		UIKit.setText(countdownLabel, if seconds > 0 then tostring(seconds) else "GO!")
		UIKit.setSize(briefFrame, UDim2.new(0.72, 0, 0, 126))
		UIKit.set(objectiveLabel, "Position", UDim2.fromOffset(14, 58))
		UIKit.set(hintLabel, "Position", UDim2.fromOffset(14, 80))
		UIKit.setVisible(dailyLabel, true)
		UIKit.setText(
			dailyLabel,
			if snap.dailyClaimed
				then string.upper("DAILY DONE - " .. snap.dailyLabel)
				else string.upper(string.format("DAILY: %s  +%d", snap.dailyLabel, snap.dailyBonus))
		)
		UIKit.setTextColor(dailyLabel, if snap.dailyClaimed then UIKit.Theme.Muted else UIKit.Theme.Accent)
	else
		UIKit.setVisible(dailyLabel, false)
		UIKit.setSize(briefFrame, UDim2.new(0.72, 0, 0, 78))
		UIKit.set(objectiveLabel, "Position", UDim2.fromOffset(14, 28))
		UIKit.set(hintLabel, "Position", UDim2.fromOffset(14, 52))
	end

	if isPrep then
		UIKit.setText(speedLabel, "-")
		UIKit.setTextColor(speedLabel, UIKit.Theme.Dim)
		UIKit.setText(conditionLabel, "PARKED")
		UIKit.setTextColor(conditionLabel, UIKit.Theme.Muted)
	elseif isResult then
		UIKit.setText(speedLabel, tostring(math.floor(view.speed + 0.5)))
		UIKit.setTextColor(speedLabel, UIKit.Theme.Text)
		UIKit.setText(conditionLabel, "FINISHED")
		UIKit.setTextColor(conditionLabel, UIKit.Theme.Muted)
	else
		UIKit.setText(speedLabel, tostring(math.floor(view.speed + 0.5)))
		UIKit.setTextColor(speedLabel, UIKit.Theme.Text)
		UIKit.setText(conditionLabel, conditionLine(snap))
		UIKit.setTextColor(conditionLabel, conditionColor)
	end

	if readoutLabel then
		UIKit.setVisible(readoutLabel, isRun)
		if isRun then
			UIKit.setText(
				readoutLabel,
				string.format(
					"condition %d%%   offset %.1f studs   lean %d deg",
					math.floor(view.cargoReadout + 0.5),
					view.cargoOffset,
					math.floor(view.cargoLeanDeg + 0.5)
				)
			)
		end
	end

	local showIntegrity = isRun and view.chassisIntegrity < INTEGRITY_WARN_BELOW
	UIKit.setVisible(integrityLabel, showIntegrity)
	if showIntegrity then
		UIKit.setText(integrityLabel, string.format("truck %d%%", math.floor(view.chassisIntegrity + 0.5)))
		UIKit.setTextColor(integrityLabel, if view.chassisIntegrity < 40 then UIKit.Theme.Bad else UIKit.Theme.Warn)
	elseif isRun and view.chassisIntegrity < INTEGRITY_CRIT_BELOW and os.clock() - lastOffTruckToastAt > 6 then
		lastOffTruckToastAt = os.clock()
		showToast("Truck taking heavy damage. Ease off the shoulder.")
	end

	if isPrep then
		UIKit.setText(timeLabel, "READY")
	elseif isResult then
		UIKit.setText(timeLabel, "FINISHED")
	else
		UIKit.setText(timeLabel, string.format("%s LEFT", formatRecordTime(snap.timeRemaining)))
	end

	setDimOverlay(statusFrame, isPrep or isResult, if isPrep then "Run stats unlock at GO" else "Run finished")

	local swapObjective = nil
	local swapHint = nil
	if swapActive then
		swapObjective = if snap.myRole == "Driver"
			then "YOU HAVE THE WHEEL"
			elseif snap.myStation then "YOU ARE NOW AT " .. snap.myStation
			else "CREW ROTATING"
		swapHint = "Controls locked briefly while everyone is reseated."
	elseif swapWarning then
		swapObjective = if snap.swapNextRole == "Driver"
			then "SWAP AHEAD · YOU DRIVE NEXT"
			elseif snap.swapNextStation then "SWAP AHEAD · MOVING TO " .. snap.swapNextStation
			else "SWAP AHEAD · HOLD YOUR POSITION"
		swapHint = "Everyone rotates at the red signs."
	end

	local showResult = isResult and snap.outcome ~= nil
	UIKit.setText(
		objectiveLabel,
		if showResult
			then ""
			elseif spectating then if snap.crewCount >= snap.crewCapacity
				then string.format("CREW FULL · SPECTATING (%d/%d)", snap.crewCount, snap.crewCapacity)
				else "WAITING FOR CREW SEAT"
			elseif offTruck and not isResult then "Getting you back on."
			elseif swapObjective then swapObjective
			elseif isPrep then snap.cargoLabel .. " · " .. snap.cargoDescription
			else snap.objective
	)
	UIKit.setText(
		hintLabel,
		if showResult
			then "Press R to skip the wait."
			elseif spectating then if snap.crewCount >= snap.crewCapacity
				then string.format("Queue #%d", snap.queuePosition or 1)
				else "Waiting for your character to attach."
			elseif swapHint then swapHint
			elseif isPrep then hintFor(snap.myRole, inputDevice, snap.solo, offTruck, phase)
			else hintFor(snap.myRole, inputDevice, snap.solo, offTruck, phase)
	)
	if offTruck and not isResult and os.clock() - lastOffTruckToastAt > 12 then
		lastOffTruckToastAt = os.clock()
		showToast("Press R if you stay stuck.")
	end

	if strapPanelFrame then
		setDimOverlay(strapPanelFrame, not isRun, if isPrep then "Straps matter once GO hits" else "Run finished")
	end

	if driveFrame then
		local showPad = isRun and DeviceInput.wantsTouchDrive()
		UIKit.setVisible(driveFrame, showPad)
		if swapActive then
			setDimOverlay(driveFrame, true, "Crew handoff")
		elseif not isRun then
			setDimOverlay(driveFrame, true, "Drive unlocks at GO")
		else
			setDimOverlay(driveFrame, false)
		end
	end

	for _, entry in snap.straps do
		local row = strapRows[entry.id]
		if not row then
			continue
		end

		local shown = view.straps and view.straps[entry.id]
		local shownHealth = if shown then shown.health else entry.health
		local shownTension = if shown then shown.tension else entry.tension
		local ratio = math.clamp(shownHealth / LabConfig.StrapMaxHealth, 0, 1)
		UIKit.setSize(row.fill, UDim2.fromScale(ratio, 1))
		UIKit.setBackground(
			row.fill,
			if entry.broken
				then STRAP_BROKEN
				elseif ratio > 0.6 then UIKit.Theme.Good
				elseif ratio > 0.28 then UIKit.Theme.Warn
				else UIKit.Theme.Bad
		)

		UIKit.setSize(row.tension, UDim2.fromScale(math.clamp(shownTension / 2.5, 0, 1), 0) + UDim2.fromOffset(0, 4))

		if entry.broken then
			UIKit.setText(row.status, if entry.reattachable then "REFIT" else "GONE")
			UIKit.setTextColor(row.status, if entry.reattachable then STATUS_REFIT else STATUS_GONE)
		elseif entry.workedBy then
			UIKit.setText(row.status, "WORKED")
			UIKit.setTextColor(row.status, STATUS_WORKED)
		else
			UIKit.setText(row.status, "")
		end

		UIKit.setTextColor(row.tag, if snap.myStation == entry.id then UIKit.Theme.Accent else TAG_IDLE)
	end

	local isStrapper = snap.myRole == "Strapper"
	local canWork = isRun and not swapActive and (isStrapper or (snap.myRole == "Driver" and snap.solo))
	local now = os.clock()
	if pendingStation and now - pendingStationAt >= PENDING_ACTION_TIMEOUT then
		pendingStation = nil
	end
	if pendingRoleAt > 0 and now - pendingRoleAt >= PENDING_ACTION_TIMEOUT then
		pendingRoleAt = 0
		pendingRoleFrom = nil
	end
	local shownStationTarget = snap.myMovingTo or pendingStation

	if swapActive then
		UIKit.setText(controlsTitle, "SWAPPING CREW")
		UIKit.setTextColor(controlsTitle, SWAP_RED)
		UIKit.setVisible(runLockLabel, false)
	elseif swapWarning then
		UIKit.setText(controlsTitle, "SWAP INCOMING")
		UIKit.setTextColor(controlsTitle, SWAP_RED)
		UIKit.setVisible(runLockLabel, false)
	elseif spectating then
		UIKit.setText(controlsTitle, "SPECTATING")
		UIKit.setTextColor(controlsTitle, UIKit.Theme.Muted)
		UIKit.setVisible(runLockLabel, true)
		UIKit.setText(runLockLabel, "A seat opens automatically when crew leaves")
	elseif isPrep then
		UIKit.setText(controlsTitle, if isStrapper then "NOW · pick a corner" else "NOW · pick your job")
		UIKit.setTextColor(controlsTitle, UIKit.Theme.Accent)
		UIKit.setVisible(runLockLabel, true)
		UIKit.setText(runLockLabel, "Drive & straps unlock when GO hits")
	elseif isRun then
		UIKit.setText(controlsTitle, if isStrapper then "STATIONS" else "CREW")
		UIKit.setTextColor(controlsTitle, UIKit.Theme.Text)
		UIKit.setVisible(runLockLabel, false)
	else
		UIKit.setText(controlsTitle, "RUN OVER")
		UIKit.setTextColor(controlsTitle, UIKit.Theme.Muted)
		UIKit.setVisible(runLockLabel, false)
	end
	UIKit.setText(
		roleLabel,
		if spectating
			then "YOU · SPECTATOR"
			elseif snap.myRole then "YOU · " .. string.upper(snap.myRole)
			else "YOU · CREW"
	)
	UIKit.setTextColor(
		roleLabel,
		if spectating then UIKit.Theme.Muted elseif snap.myRole == "Driver" then UIKit.Theme.Good else UIKit.Theme.Accent
	)

	for id, element in stationButtons do
		local stationLive = (isPrep or isRun) and isStrapper and not swapWarning and not swapActive
		UIKit.setVisible(element, isStrapper and (isPrep or isRun))
		if stationLive then
			UIKit.setActive(element, true)
			UIKit.setTextColor(element, Color3.fromRGB(240, 240, 240))
			UIKit.setBackground(
				element,
				if snap.myStation == id
					then STATION_MINE
					elseif shownStationTarget == id then STATION_TARGET
					else UIKit.Theme.Button
			)
		else
			setButtonLive(element, false, UIKit.Theme.Button)
		end
	end

	local workChrome, switchChrome, restartChrome = controlChromeLabels(inputDevice)
	setButtonLive(
		switchButton,
		(isPrep or isRun) and not spectating and not swapWarning and not swapActive,
		UIKit.Theme.Button
	)
	UIKit.setText(switchButton, if pendingRoleAt > 0 then "SWITCHING…" else switchChrome)
	-- Spectators may still clear a halted sim; otherwise a role-wipe soft-locks R.
	setButtonLive(restartButton, (not spectating) or snap.simHalted == true, UIKit.Theme.Danger)
	UIKit.setText(restartButton, restartChrome)

	UIKit.setVisible(workButton, (isPrep or isRun) and (isStrapper or (snap.myRole == "Driver" and snap.solo)))
	setButtonLive(workButton, canWork, UIKit.Theme.Positive)
	if working and canWork then
		UIKit.setBackground(workButton, Color3.fromRGB(95, 180, 110))
	end
	UIKit.setText(
		workButton,
		if swapActive
			then "HANDOFF"
			elseif not isRun and (isStrapper or snap.myRole == "Driver") then "LOCKED"
			elseif offTruck then "OFF TRUCK"
			elseif working and snap.myStation then "WORKING · " .. snap.myStation
			elseif working and snap.myRole == "Driver" and snap.solo then "WORKING · STRAP"
			elseif shownStationTarget then "→ " .. shownStationTarget
			elseif canWork then workIdleLabel(snap, inputDevice)
			else workChrome
	)

	setDimOverlay(stationRowFrame, isResult, "Run finished")

	local camera = Workspace.CurrentCamera
	local narrow = camera ~= nil and camera.ViewportSize.X < 760
	local viewportHeight = if safeRoot and safeRoot.AbsoluteSize.Y > 0
		then safeRoot.AbsoluteSize.Y
		elseif camera then camera.ViewportSize.Y
		else 720
	local shortViewport = viewportHeight < 700
	local compactContract = showResult and snap.offer ~= nil and shortViewport
	-- On short screens these corner panels would sit underneath the centered
	-- result/decision stack. Restore them as soon as the board closes.
	UIKit.setVisible(statusFrame, not compactContract)
	UIKit.setVisible(briefFrame, not compactContract)
	UIKit.setVisible(strapPanelFrame, not compactContract)
	UIKit.setVisible(controlsFrame, not compactContract)
	-- Offered between runs, once there is a verdict to share. Hidden on short
	-- screens with a board up, where it would sit under the decision stack.
	UIKit.setVisible(inviteFrame, canInvite and not spectating and (isResult or isPrep) and not compactContract)
	-- The contract decision is the between-run interaction. Do not make it
	-- compete with paint browsing for either attention or screen space.
	local showGarage = (isPrep or (isResult and snap.offer == nil)) and not spectating
	UIKit.set(garageFrame, "AnchorPoint", if narrow then Vector2.new(0.5, 0) else Vector2.new(1, 0))
	UIKit.set(
		garageFrame,
		"Position",
		if narrow then UDim2.new(0.5, 0, 0, GARAGE_TOP) else UDim2.new(1, -8, 0, GARAGE_TOP)
	)
	UIKit.setSize(garageFrame, UDim2.fromOffset(if narrow then 260 else 300, 148))
	UIKit.setVisible(garageFrame, showGarage)
	if showGarage then
		local paint = paintDefs[selectedPaintIndex]
		if paint then
			local owned = paint.cost <= 0 or snap.unlockedPaints[paint.id] == true
			local equipped = snap.equippedPaint == paint.id
			UIKit.setText(garagePaintName, string.upper(paint.label))
			UIKit.setTextColor(garagePaintName, paint.color)
			local actionText = if not snap.progressionReady
				then "LOADING"
				elseif equipped then "EQUIPPED"
				elseif owned then "EQUIP"
				elseif snap.credits >= paint.cost then string.format("UNLOCK %d", paint.cost)
				else string.format("NEED %d", paint.cost - snap.credits)
			UIKit.setText(garageAction, actionText)
			setButtonLive(
				garageAction,
				snap.progressionReady and not paintPending and not equipped and (owned or snap.credits >= paint.cost),
				UIKit.Theme.Positive
			)
			setButtonLive(garagePrevious, not paintPending, UIKit.Theme.Button)
			setButtonLive(garageNext, not paintPending, UIKit.Theme.Button)
			UIKit.setText(
				garageHint,
				if not snap.progressionReady
					then "Loading garage progress..."
					elseif not snap.progressionSaving then if RunService:IsStudio()
						then "Studio test mode - changes will not save."
						else "Progress saving is temporarily unavailable."
					else "Driver paint applies to the shared truck."
			)
			UIKit.setText(garageRecords, recordsSummary(snap.records))
		end
	end

	local feedbackRequested = showResult and snap.feedbackRequested
	local feedbackSubmitted = showResult and snap.feedbackSubmitted

	--[[
		Compact rows stack: each one starts where the previous ends, so a height
		change is one number rather than four offsets that have to agree.
	]]
	local detailY = COMPACT_RESULT.TitleY + COMPACT_RESULT.TitleHeight
	local questionY = detailY + COMPACT_RESULT.DetailHeight + COMPACT_RESULT.Gap
	local feedbackY = questionY + COMPACT_RESULT.QuestionHeight + COMPACT_RESULT.Gap
	local compactHeight = if feedbackRequested
		then feedbackY + TOUCH_MIN + COMPACT_RESULT.Padding
		elseif feedbackSubmitted then questionY + COMPACT_RESULT.QuestionHeight + COMPACT_RESULT.Padding
		else detailY + COMPACT_RESULT.DetailHeight + COMPACT_RESULT.Padding

	local resultHeight = if compactContract
		then compactHeight
		else if feedbackRequested then 242 elseif feedbackSubmitted then 198 else 168
	local compactTop = math.max(4, math.floor((viewportHeight - (resultHeight + 8 + 172)) / 2))

	UIKit.setVisible(resultFrame, showResult)
	UIKit.set(resultFrame, "AnchorPoint", if compactContract then Vector2.new(0.5, 0) else Vector2.new(0.5, 0.5))
	UIKit.set(
		resultFrame,
		"Position",
		if compactContract then UDim2.new(0.5, 0, 0, compactTop) else UDim2.fromScale(0.5, 0.5)
	)
	UIKit.setSize(resultFrame, UDim2.new(if compactContract then 0.9 else 0.7, 0, 0, resultHeight))
	resultConstraint.MaxSize = Vector2.new(520, resultHeight)
	resultConstraint.MinSize = Vector2.new(280, resultHeight)

	UIKit.set(resultTitle, "Position", if compactContract then UDim2.fromOffset(12, 4) else UDim2.fromOffset(16, 14))
	UIKit.setSize(resultTitle, if compactContract then UDim2.new(1, -24, 0, 30) else UDim2.new(1, -32, 0, 44))
	UIKit.set(resultTitle, "TextSize", if compactContract then 20 else 26)
	--[[
		The explanation survives compact mode. It is the only place a player is
		told what went wrong, RunCauses guarantees it always says something, and
		dropping it on small screens would spend that guarantee on exactly the
		players most likely to be seeing their first wreck.
	]]
	UIKit.setVisible(resultDetail, showResult)
	UIKit.set(
		resultDetail,
		"Position",
		if compactContract then UDim2.fromOffset(12, detailY) else UDim2.fromOffset(16, 62)
	)
	UIKit.setSize(
		resultDetail,
		if compactContract then UDim2.new(1, -24, 0, COMPACT_RESULT.DetailHeight) else UDim2.new(1, -32, 0, 88)
	)
	UIKit.set(resultDetail, "TextSize", if compactContract then 13 else 15)
	UIKit.set(
		resultQuestion,
		"Position",
		if compactContract then UDim2.fromOffset(12, questionY) else UDim2.fromOffset(12, 156)
	)
	UIKit.set(resultQuestion, "TextSize", if compactContract then 12 else 14)
	UIKit.set(
		feedbackRow,
		"Position",
		if compactContract then UDim2.fromOffset(0, feedbackY) else UDim2.fromOffset(0, 186)
	)
	UIKit.setVisible(resultQuestion, feedbackRequested or feedbackSubmitted)
	UIKit.setVisible(feedbackRow, feedbackRequested)
	if feedbackRequested or feedbackSubmitted then
		UIKit.setText(
			resultQuestion,
			if feedbackSubmitted then "FEEDBACK SAVED · THANK YOU" else "WOULD YOU PLAY ANOTHER RUN?"
		)
	end
	for index, element in feedbackButtons do
		local color = if index == 1
			then UIKit.Theme.Positive
			elseif index == 3 then UIKit.Theme.Danger
			else UIKit.Theme.Button
		setButtonLive(element, feedbackRequested and not feedbackPending, color)
	end
	refreshContractBoard(snap, compactContract, compactTop + resultHeight + 8)

	if showResult then
		local headline = OUTCOME_HEADLINE[snap.outcome] or string.upper(snap.outcome or "")
		UIKit.setText(resultTitle, headline)
		UIKit.setTextColor(
			resultTitle,
			if snap.outcome == "Delivered"
				then Color3.fromRGB(110, 220, 140)
				elseif snap.outcome == "PartialLoss" then Color3.fromRGB(245, 195, 80)
				else Color3.fromRGB(235, 95, 85)
		)
		UIKit.setText(resultDetail, resultBody(snap))
	end
end

local function smoothValue(current: number, target: number, dt: number, snapGap: number): number
	if math.abs(target - current) >= snapGap then
		return target
	end
	return PresentationMath.approach(current, target, PRESENTATION_RATE, dt)
end

local function stepPresentation(dt: number)
	local snap = latest
	if not snap then
		return
	end
	if not presented or presented.phase ~= snap.phase then
		resetPresentation(snap)
		refresh()
		return
	end

	presentationAccumulator += dt
	if presentationAccumulator < PRESENTATION_INTERVAL then
		return
	end
	local elapsed = presentationAccumulator
	presentationAccumulator = 0

	local dirty = false
	local function trackSmooth(current: number, target: number, snapGap: number): number
		local nextValue = smoothValue(current, target, elapsed, snapGap)
		if math.abs(nextValue - current) > 1e-3 then
			dirty = true
		end
		return nextValue
	end

	presented.speed = trackSmooth(presented.speed, snap.speed, 80)
	presented.routeProgress = trackSmooth(presented.routeProgress, snap.routeProgress, 0.08)
	presented.cargoReadout = trackSmooth(presented.cargoReadout, snap.cargoReadout, 35)
	presented.cargoOffset = trackSmooth(presented.cargoOffset, snap.cargoOffset, 3)
	presented.cargoLeanDeg = trackSmooth(presented.cargoLeanDeg, snap.cargoLeanDeg, 25)
	presented.chassisIntegrity = trackSmooth(presented.chassisIntegrity, snap.chassisIntegrity, 30)

	for _, entry in snap.straps do
		local shown = presented.straps[entry.id]
		if not shown then
			shown = { health = entry.health, tension = entry.tension }
			presented.straps[entry.id] = shown
			dirty = true
		end
		if entry.broken then
			-- A break is gameplay-critical feedback, so it never eases in.
			if shown.health ~= entry.health or shown.tension ~= entry.tension then
				dirty = true
			end
			shown.health = entry.health
			shown.tension = entry.tension
		else
			local nextHealth = smoothValue(shown.health, entry.health, elapsed, LabConfig.StrapMaxHealth * 0.6)
			local nextTension = smoothValue(shown.tension, entry.tension, elapsed, 2)
			if math.abs(nextHealth - shown.health) > 1e-3 or math.abs(nextTension - shown.tension) > 1e-3 then
				dirty = true
			end
			shown.health = nextHealth
			shown.tension = nextTension
		end
	end

	if dirty then
		refresh()
	end
end

-- ----------------------------------------------------------------- inputs

local function rescaledAxis(value: number): number
	local magnitude = math.abs(value)
	if magnitude < STICK_DEADZONE then
		return 0
	end
	local signed = math.sign(value) * ((magnitude - STICK_DEADZONE) / (1 - STICK_DEADZONE))
	return math.clamp(signed, -1, 1)
end

local function cycleStation(direction: number)
	local snap = latest
	if not snap or snap.myRole ~= "Strapper" then
		return
	end

	local order = LabConfig.StationOrder
	local current = snap.myMovingTo or snap.myStation
	local index = table.find(order, current) or 1
	local nextIndex = ((index - 1 + direction) % #order) + 1
	requestStation(order[nextIndex])
end

local function isTruckControlKey(code: Enum.KeyCode): boolean
	return code == Enum.KeyCode.W
		or code == Enum.KeyCode.Up
		or code == Enum.KeyCode.S
		or code == Enum.KeyCode.Down
		or code == Enum.KeyCode.A
		or code == Enum.KeyCode.Left
		or code == Enum.KeyCode.D
		or code == Enum.KeyCode.Right
		or code == Enum.KeyCode.Space
		or code == Enum.KeyCode.E
		or code == Enum.KeyCode.R
		or code == Enum.KeyCode.T
		or code == Enum.KeyCode.One
		or code == Enum.KeyCode.Two
		or code == Enum.KeyCode.Three
		or code == Enum.KeyCode.Four
end

local function bindKeyboard()
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		-- Seated Drivers get WASD marked processed by the default PlayerModule.
		-- After wreck→reseat that path is reliable, so ignoring processed here
		-- was leaving throttle at 0 forever while the truck looked fine.
		if processed and not isTruckControlKey(input.KeyCode) then
			return
		end
		if UserInputService:GetFocusedTextBox() then
			return
		end
		local code = input.KeyCode
		if code == Enum.KeyCode.W or code == Enum.KeyCode.Up then
			keyForward = true
		elseif code == Enum.KeyCode.S or code == Enum.KeyCode.Down then
			keyReverse = true
		elseif code == Enum.KeyCode.A or code == Enum.KeyCode.Left then
			keyLeft = true
		elseif code == Enum.KeyCode.D or code == Enum.KeyCode.Right then
			keyRight = true
		elseif code == Enum.KeyCode.Space then
			keyBrake = true
		elseif code == Enum.KeyCode.E then
			LabUI.setWorking(true)
		elseif code == Enum.KeyCode.R then
			LabRemotes.fireServer(Net.Names.LabRestart)
		elseif code == Enum.KeyCode.T then
			requestRoleSwitch()
		elseif code == Enum.KeyCode.One then
			requestStation(LabConfig.StationOrder[1])
		elseif code == Enum.KeyCode.Two then
			requestStation(LabConfig.StationOrder[2])
		elseif code == Enum.KeyCode.Three then
			requestStation(LabConfig.StationOrder[3])
		elseif code == Enum.KeyCode.Four then
			requestStation(LabConfig.StationOrder[4])
		end

		if
			code == Enum.KeyCode.W
			or code == Enum.KeyCode.Up
			or code == Enum.KeyCode.S
			or code == Enum.KeyCode.Down
			or code == Enum.KeyCode.A
			or code == Enum.KeyCode.Left
			or code == Enum.KeyCode.D
			or code == Enum.KeyCode.Right
			or code == Enum.KeyCode.Space
		then
			sendDriveInput()
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		local code = input.KeyCode
		if code == Enum.KeyCode.W or code == Enum.KeyCode.Up then
			keyForward = false
		elseif code == Enum.KeyCode.S or code == Enum.KeyCode.Down then
			keyReverse = false
		elseif code == Enum.KeyCode.A or code == Enum.KeyCode.Left then
			keyLeft = false
		elseif code == Enum.KeyCode.D or code == Enum.KeyCode.Right then
			keyRight = false
		elseif code == Enum.KeyCode.Space then
			keyBrake = false
		elseif code == Enum.KeyCode.E then
			LabUI.setWorking(false)
		end

		if
			code == Enum.KeyCode.W
			or code == Enum.KeyCode.Up
			or code == Enum.KeyCode.S
			or code == Enum.KeyCode.Down
			or code == Enum.KeyCode.A
			or code == Enum.KeyCode.Left
			or code == Enum.KeyCode.D
			or code == Enum.KeyCode.Right
			or code == Enum.KeyCode.Space
		then
			sendDriveInput()
		end
	end)
end

--[[
	ButtonA and Thumbstick1 are claimed by the default control scripts, so
	InputBegan arrives with processed = true. ContextActionService sinks them
	before that path and is the only reliable way to drive from a pad.
]]
local function bindGamepad()
	local function driveAction(_name, state, input)
		local code = input.KeyCode
		if code == Enum.KeyCode.Thumbstick1 then
			padSteer = rescaledAxis(input.Position.X)
			-- Stick Change is high-frequency; Heartbeat flush carries axes.
		elseif code == Enum.KeyCode.ButtonR2 then
			padThrottle = if state == Enum.UserInputState.End then 0 else math.clamp(input.Position.Z, 0, 1)
			if state == Enum.UserInputState.Begin or state == Enum.UserInputState.End then
				sendDriveInput(false, true)
			end
		elseif code == Enum.KeyCode.ButtonL2 then
			padReverse = if state == Enum.UserInputState.End then 0 else math.clamp(input.Position.Z, 0, 1)
			if state == Enum.UserInputState.Begin or state == Enum.UserInputState.End then
				sendDriveInput(false, true)
			end
		elseif code == Enum.KeyCode.ButtonX then
			local braking = state == Enum.UserInputState.Begin or state == Enum.UserInputState.Change
			if braking ~= padBrake then
				padBrake = braking
				sendDriveInput(false, true)
			end
		end
		return Enum.ContextActionResult.Sink
	end

	local function workAction(_name, state)
		LabUI.setWorking(state == Enum.UserInputState.Begin or state == Enum.UserInputState.Change)
		return Enum.ContextActionResult.Sink
	end

	local function roleAction(_name, state)
		if state == Enum.UserInputState.Begin then
			requestRoleSwitch()
		end
		return Enum.ContextActionResult.Sink
	end

	local function restartAction(_name, state)
		if state == Enum.UserInputState.Begin then
			LabRemotes.fireServer(Net.Names.LabRestart)
		end
		return Enum.ContextActionResult.Sink
	end

	local function stationAction(_name, state, input)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Sink
		end
		if input.KeyCode == Enum.KeyCode.DPadLeft then
			cycleStation(-1)
		elseif input.KeyCode == Enum.KeyCode.DPadRight then
			cycleStation(1)
		end
		return Enum.ContextActionResult.Sink
	end

	ContextActionService:BindAction(
		"LabDrivePad",
		driveAction,
		false,
		Enum.KeyCode.Thumbstick1,
		Enum.KeyCode.ButtonR2,
		Enum.KeyCode.ButtonL2,
		Enum.KeyCode.ButtonX
	)
	ContextActionService:BindAction("LabWorkPad", workAction, false, Enum.KeyCode.ButtonA)
	ContextActionService:BindAction("LabRolePad", roleAction, false, Enum.KeyCode.ButtonY)
	ContextActionService:BindAction("LabRestartPad", restartAction, false, Enum.KeyCode.ButtonSelect)
	ContextActionService:BindAction(
		"LabStationPad",
		stationAction,
		false,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight
	)
end

local function bindInputs()
	inputDevice = DeviceInput.bucketFor(UserInputService:GetLastInputType())
	UserInputService.LastInputTypeChanged:Connect(function(inputType)
		inputDevice = DeviceInput.bucketFor(inputType)
		if latest then
			local off = latest.myOffTruck or latest.myThrown
			UIKit.setText(hintLabel, hintFor(latest.myRole, inputDevice, latest.solo, off, latest.phase))
			if driveFrame then
				local showPad = latest.phase == "Run" and DeviceInput.wantsTouchDrive()
				UIKit.setVisible(driveFrame, showPad)
			end
			-- Refresh chrome verbs immediately so Touch does not keep "HOLD E".
			if workButton and switchButton and restartButton then
				local workChrome, switchChrome, restartChrome = controlChromeLabels(inputDevice)
				if pendingRoleAt <= 0 then
					UIKit.setText(switchButton, switchChrome)
				end
				UIKit.setText(restartButton, restartChrome)
				local snap = latest
				local canWorkNow = snap.phase == "Run"
					and not snap.swapActive
					and (snap.myRole == "Strapper" or (snap.myRole == "Driver" and snap.solo))
					and not (snap.myOffTruck or snap.myThrown)
				if canWorkNow and not working then
					UIKit.setText(workButton, workIdleLabel(snap, inputDevice))
				elseif not canWorkNow and snap.phase ~= "Result" then
					UIKit.setText(workButton, workChrome)
				end
			end
		end
	end)
	DeviceInput.onPreferredInputChanged(function()
		if driveFrame and latest then
			local showPad = latest.phase == "Run" and DeviceInput.wantsTouchDrive()
			UIKit.setVisible(driveFrame, showPad)
		end
	end)

	-- Studio multi-client testing and ordinary alt-tabbing can swallow key-up
	-- events. Release everything explicitly so a background client never keeps
	-- steering, accelerating, braking, or working a strap for a full timeout.
	UserInputService.WindowFocusReleased:Connect(function()
		if LabUI.clearDriveLocal then
			LabUI.clearDriveLocal()
		end
		if LabUI.releaseWorking then
			LabUI.releaseWorking()
		elseif working then
			LabUI.setWorking(false)
		end
		sendDriveInput(true)
	end)

	bindKeyboard()
	bindGamepad()
end

-- ----------------------------------------------------------------- camera

--[[
	Three FindFirstChild calls per rendered frame, for a part that changes at
	most once a session. Caching it and checking Parent is one field read;
	losing the parent is also exactly what happens when the rebuild command
	swaps the rig out, so the check doubles as the invalidation.
]]
local cachedChassis: BasePart? = nil

local function findChassis(): BasePart?
	local cached = cachedChassis
	if cached and cached.Parent then
		return cached
	end

	local root = Workspace:FindFirstChild("CargoLab")
	local truck = root and root:FindFirstChild("LabTruck")
	local chassis = truck and truck:FindFirstChild("Chassis")
	cachedChassis = if chassis and chassis:IsA("BasePart") then chassis else nil
	return cachedChassis
end

local lastReplicatedPos: Vector3? = nil
local smoothedCameraPos: Vector3? = nil
local smoothedCameraFocus: Vector3? = nil
local smoothedCameraForward: Vector3? = nil
local lastMotionTime = 0
local cameraShakeIntensity = 0
local cameraImpactKick = 0

local function bindCamera()
	RunService:BindToRenderStep("CargoLabCamera", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local chassis = findChassis()
		if not chassis then
			chassisMissingFor += dt
			-- Ignore one-frame cache misses; only drop Scriptable after a real gap.
			if chassisMissingFor > 0.2 and camera.CameraType == Enum.CameraType.Scriptable then
				camera.CameraType = Enum.CameraType.Custom
			end
			local snap = latest
			if
				chassisMissingFor > 1.5
				and snap
				and (snap.phase == "Run" or snap.phase == "Staging")
				and os.clock() - lastOffTruckToastAt > 8
			then
				lastOffTruckToastAt = os.clock()
				showToast("Lost the truck view. Press R to reset.")
			end
			if chassisMissingFor > 0.2 then
				lastReplicatedPos = nil
				smoothedCameraPos = nil
				smoothedCameraFocus = nil
				smoothedCameraForward = nil
				cameraShakeIntensity = 0
				cameraImpactKick = 0
			end
			return
		end

		local longGap = chassisMissingFor > 0.2
		chassisMissingFor = 0
		camera.CameraType = Enum.CameraType.Scriptable

		-- Anchor the camera to the same interpolated transform Roblox renders for
		-- the truck. LabMotion is deliberately limited to feedback signals; using
		-- its extrapolated position here makes the visible truck skip against the
		-- camera whenever the two interpolation timelines disagree.
		local motion = if latest and latest.phase ~= "Result"
			then LabMotionState.resolve(
				Workspace:GetServerTimeNow(),
				LabConfig.CameraLeadSeconds,
				LabConfig.CameraMotionStaleSeconds
			)
			else nil
		local renderedFrame = chassis:GetRenderCFrame()
		local replicatedPos = renderedFrame.Position
		local previousReplicatedPos = lastReplicatedPos
		local correctionDistance = if previousReplicatedPos
			then (replicatedPos - previousReplicatedPos).Magnitude
			else 0
		local teleported = previousReplicatedPos ~= nil and correctionDistance > 24
		lastReplicatedPos = replicatedPos

		local targetPosition = replicatedPos
		local velocity = if motion then motion.velocity else chassis.AssemblyLinearVelocity
		local look = renderedFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		flat = if flat.Magnitude < 0.01 then Vector3.new(0, 0, 1) else flat.Unit
		local suspensionEnergy = 0
		local gradeDeg = 0
		if motion then
			suspensionEnergy = motion.suspensionEnergy
			gradeDeg = math.deg(motion.sample.pitch)
		end

		local targetFocus = targetPosition + Vector3.new(0, 3, 0)

		local needsSnap = longGap
			or teleported
			or not smoothedCameraPos
			or not smoothedCameraFocus
			or not smoothedCameraForward
		if needsSnap then
			smoothedCameraFocus = targetFocus
			smoothedCameraForward = flat
			smoothedCameraPos = targetFocus - flat * 34 + Vector3.new(0, 14, 0)
		else
			local followAlpha = PresentationMath.alpha(LabConfig.CameraFollowRate, dt)
			local headingAlpha = PresentationMath.alpha(LabConfig.CameraHeadingFollowRate, dt)
			local horizontalFocus = smoothedCameraFocus:Lerp(targetFocus, followAlpha)
			smoothedCameraFocus = Vector3.new(
				horizontalFocus.X,
				PresentationMath.approach(smoothedCameraFocus.Y, targetFocus.Y, LabConfig.CameraVerticalFollowRate, dt),
				horizontalFocus.Z
			)
			local blendedForward = smoothedCameraForward:Lerp(flat, headingAlpha)
			smoothedCameraForward = if blendedForward.Magnitude > 0.001 then blendedForward.Unit else flat
			local desired = smoothedCameraFocus - smoothedCameraForward * 34 + Vector3.new(0, 14, 0)
			if (smoothedCameraPos - desired).Magnitude > LabConfig.CameraSnapDistance then
				smoothedCameraPos = desired
			else
				local horizontalCamera = smoothedCameraPos:Lerp(desired, followAlpha)
				smoothedCameraPos = Vector3.new(
					horizontalCamera.X,
					PresentationMath.approach(smoothedCameraPos.Y, desired.Y, LabConfig.CameraVerticalFollowRate, dt),
					horizontalCamera.Z
				)
			end
		end

		local speed = math.abs(velocity:Dot(flat))
		local surface = if latest then latest.roadSurface else "Road"
		local feedbackTarget = if latest and latest.phase == "Run"
			then CameraFeedback.target(speed, surface, suspensionEnergy, gradeDeg, LabConfig)
			else 0
		local feedbackRate = if feedbackTarget > cameraShakeIntensity
			then LabConfig.CameraShakeAttackRate
			else LabConfig.CameraShakeReleaseRate
		cameraShakeIntensity = PresentationMath.approach(cameraShakeIntensity, feedbackTarget, feedbackRate, dt)

		if motion and motion.sample.t ~= lastMotionTime then
			lastMotionTime = motion.sample.t
			if latest and latest.phase == "Run" then
				cameraImpactKick = math.max(cameraImpactKick, CameraFeedback.impact(motion.acceleration, LabConfig))
			end
		end
		cameraImpactKick *= math.exp(-LabConfig.CameraImpactDecay * dt)

		local clock = os.clock()
		local frequency = LabConfig.CameraShakeFrequency
		local noiseX = math.noise(clock * frequency, 3.1, 7.7) * 2
		local noiseY = math.noise(clock * frequency * 1.13, 11.9, 2.3) * 2
		local noiseRoll = math.noise(clock * frequency * 0.83, 19.7, 5.1) * 2
		local impactWave = math.sin(clock * frequency * 2.4) * cameraImpactKick
		local translation = cameraShakeIntensity * LabConfig.CameraShakeMaxTranslation
		local rotation = math.rad(cameraShakeIntensity * LabConfig.CameraShakeMaxRotationDeg)
		local impactTranslation = impactWave * LabConfig.CameraImpactTranslation
		local impactRotation = math.rad(impactWave * LabConfig.CameraImpactRotationDeg)

		local baseCamera = CFrame.lookAt(smoothedCameraPos, smoothedCameraFocus)
		camera.CFrame = baseCamera
			* CFrame.new(noiseX * translation * 0.45, noiseY * translation + impactTranslation, 0)
			* CFrame.Angles(noiseY * rotation + impactRotation, 0, noiseRoll * rotation)

		local targetFov = 68 + math.clamp(speed / LabConfig.MaxForwardSpeed, 0, 1) * 18
		camera.FieldOfView += (targetFov - camera.FieldOfView) * math.min(1, dt * 4)
	end)
end

-- ------------------------------------------------------------------ mount

function LabUI.mount()
	build()
	bindInputs()
	bindCamera()

	LabRemotes.onClient(Net.Names.LabSnapshot, function(snap: LabTypes.LabSnapshot)
		local previousRole = latest and latest.myRole
		local previousPhase = latest and latest.phase
		latest = snap
		if not presented or presented.phase ~= snap.phase then
			resetPresentation(snap)
		end
		if pendingStation and (snap.myStation == pendingStation or snap.myMovingTo == pendingStation) then
			pendingStation = nil
		end
		if pendingRoleAt > 0 and snap.myRole ~= pendingRoleFrom then
			pendingRoleAt = 0
			pendingRoleFrom = nil
		end
		if snap.swapWarning or snap.swapActive then
			pendingStation = nil
			pendingRoleAt = 0
			pendingRoleFrom = nil
		end
		-- On phase change / swap / role change: release Work to the server and
		-- drop sticky drive flags so a held key through Result cannot ghost
		-- throttle at GO. Do not clear every Staging tick — that would eat a
		-- held W during the countdown.
		local phaseChanged = previousPhase ~= nil and previousPhase ~= snap.phase
		local roleChanged = previousRole ~= nil and previousRole ~= snap.myRole
		if phaseChanged or roleChanged or snap.swapActive or snap.phase ~= "Run" then
			if LabUI.releaseWorking then
				LabUI.releaseWorking()
			else
				working = false
			end
		end
		-- Preserve inputs gathered during the countdown when Staging becomes Run.
		-- InputBegan will not fire again for a key the player is already holding.
		local leavingRun = previousPhase == "Run" and snap.phase ~= "Run"
		if leavingRun or roleChanged or snap.swapActive then
			if LabUI.clearDriveLocal then
				LabUI.clearDriveLocal()
			end
		end
		if snap.feedbackSubmitted or not snap.feedbackRequested then
			feedbackPending = false
			feedbackPendingAt = 0
		end
		local selectedPaint = paintDefs[selectedPaintIndex]
		if paintPending and selectedPaint and snap.equippedPaint == selectedPaint.id then
			paintPending = false
			paintPendingAt = 0
		end
		refresh()
	end)

	LabRemotes.onClient(Net.Names.LabEvent, function(text: any)
		if typeof(text) ~= "string" then
			return
		end
		if
			pendingStation
			and (
				string.find(text, "already", 1, true)
				or string.find(text, "Already", 1, true)
				or string.find(text, "Only crew", 1, true)
				or string.find(text, "Wait for", 1, true)
				or string.find(text, "No such", 1, true)
			)
		then
			pendingStation = nil
		end
		if pendingRoleAt > 0 and string.find(text, "already has the wheel", 1, true) then
			pendingRoleAt = 0
			pendingRoleFrom = nil
		end
		if
			working
			and (
				string.find(text, "not at a strap", 1, true)
				or string.find(text, "getting back on", 1, true)
				or string.find(text, "Wait for the run", 1, true)
				or string.find(text, "Only crew on the bed", 1, true)
			)
		then
			working = false
		end
		showToast(text)
	end)

	RunService.Heartbeat:Connect(function(dt: number)
		stepPresentation(dt)

		driveAccumulator += dt
		if driveAccumulator < DRIVE_FLUSH_SECONDS then
			return
		end
		driveAccumulator = 0

		local snap = latest
		if not snap or snap.myRole ~= "Driver" or snap.phase ~= "Run" then
			return
		end

		sendDriveInput()
	end)
end

return LabUI
