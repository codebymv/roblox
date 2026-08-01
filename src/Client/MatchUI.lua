--!strict

--[[
	Crew HUD. Renders exactly one CrewSnapshot and nothing it invents itself.

	The three numbers that matter are on screen at all times: which leg you are on,
	what is riding on it unbanked, and what the next leg would be worth.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CargoManifest = require(Shared:WaitForChild("CargoManifest"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Net = require(Shared:WaitForChild("Net"))
local Roles = require(Shared:WaitForChild("Roles"))
local Types = require(Shared:WaitForChild("Types"))

local UIKit = require(script.Parent.UIKit)

local MatchUI = {}

local player = Players.LocalPlayer
local gui: ScreenGui
local phaseLabel: TextLabel
local objectiveLabel: TextLabel
local stackLabel: TextLabel
local timerLabel: TextLabel
local cargoLabel: TextLabel
local truckLabel: TextLabel
local progressLabel: TextLabel
local roleLabel: TextLabel
local toastLabel: TextLabel
local failureLabel: TextLabel
local endcardLabel: TextLabel
local manifestFrame: Frame
local manifestTitle: TextLabel
local manifestBody: TextLabel
local startButton: TextButton
local readyButton: TextButton
local newConvoyButton: TextButton
local bankButton: TextButton
local pushButton: TextButton
local actionButton: TextButton
local driveFrame: Frame
local throttleButton: TextButton
local reverseButton: TextButton
local brakeButton: TextButton
local leftButton: TextButton
local rightButton: TextButton

local latest: Types.CrewSnapshot? = nil
local actionHolding = false
local keyForward = false
local keyReverse = false
local keyLeft = false
local keyRight = false
local keyBrake = false
local touchForward = false
local touchReverse = false
local touchLeft = false
local touchRight = false
local touchBrake = false
local driveSendAccumulator = 0

local crewSnapshotRemote: RemoteEvent
local requestSnapshotRemote: RemoteEvent
local requestStartRemote: RemoteEvent
local requestReadyRemote: RemoteEvent
local requestDecisionRemote: RemoteEvent
local requestNewConvoyRemote: RemoteEvent
local roleActionRemote: RemoteEvent
local driveInputRemote: RemoteEvent

local function setToast(message: string)
	toastLabel.Text = message
	toastLabel.Visible = message ~= ""
end

local function isLivePhase(phase: Types.CrewPhase): boolean
	return phase == "Run" or phase == "DeliveryHold"
end

local function makeLabel(parent: Instance, name: string, order: number, height: number): TextLabel
	return UIKit.label({
		Name = name,
		Size = UDim2.new(1, 0, 0, height),
		TextSize = 16,
		TextColor3 = Color3.fromRGB(240, 240, 240),
		LayoutOrder = order,
		Text = name,
		Parent = parent,
	})
end

local function makeButton(parent: Instance, name: string, text: string, size: UDim2, color: Color3): TextButton
	return UIKit.button({
		Name = name,
		Size = size,
		BackgroundColor3 = color,
		BackgroundTransparency = 0.08,
		TextSize = 17,
		TextColor3 = Color3.new(1, 1, 1),
		Text = text,
		Visible = false,
		CornerRadius = 10,
		Parent = parent,
	})
end

local function getMyRole(snapshot: Types.CrewSnapshot): Types.RoleId?
	return snapshot.roles[player.Name]
end

local function amIReady(snapshot: Types.CrewSnapshot): boolean
	return snapshot.readyPlayers[player.Name] == true
end

local function stopActionHold()
	if not actionHolding then
		return
	end
	actionHolding = false
	roleActionRemote:FireServer("EndResolve")
end

local function failReasonCopy(snapshot: Types.CrewSnapshot): string
	local reason = snapshot.failReason
	if reason == "Banked" then
		return string.format("BANKED\n%d credits secured across %d legs.", snapshot.carriedValue, snapshot.leg)
	elseif reason == "TruckTotaled" then
		return "TRUCK TOTALED\nIntegrity hit zero. The stack is gone."
	elseif reason == "TimeExpired" then
		return "TIME EXPIRED\nThe delivery window closed on you."
	elseif reason == "CrewLeft" then
		return "CREW LEFT\nSomeone bailed mid-haul."
	elseif reason == "CargoDumped" then
		return "CARGO DUMPED\nThe load did not survive the leg."
	end
	return "CONVOY OVER\nStaging again shortly."
end

local function refreshManifest(snapshot: Types.CrewSnapshot)
	local cargo = snapshot.cargo
	if not cargo or snapshot.phase == "Idle" or snapshot.phase == "Staging" then
		manifestFrame.Visible = false
		return
	end
	manifestFrame.Visible = true
	manifestTitle.Text = string.upper(cargo.label)
	manifestTitle.TextColor3 = CargoManifest.rarityColor(cargo.rarity)
	manifestBody.Text =
		string.format("%s · x%.2f value\n%s", string.upper(cargo.rarity), cargo.valueMultiplier, cargo.blurb)
end

local function refresh()
	local snap = latest
	if not snap then
		return
	end

	local spectating = snap.spectating
	phaseLabel.Text = if spectating
		then string.format("WATCHING BAY %d · %s", snap.bayIndex, string.upper(snap.phase))
		else string.format("BAY %d · %s", snap.bayIndex, string.upper(snap.phase))
	objectiveLabel.Text = snap.objective

	if snap.leg > 0 then
		stackLabel.Text = string.format(
			"LEG %d · x%.2f · stack %d cr · this leg %d cr",
			snap.leg,
			snap.multiplier,
			snap.carriedValue,
			snap.legValue
		)
	else
		stackLabel.Text = "No convoy running"
	end

	timerLabel.Text = tostring(snap.timeRemaining) .. "s"
	cargoLabel.Text = "CARGO " .. tostring(snap.cargoStability) .. "% · " .. snap.cargoState
	truckLabel.Text = "TRUCK " .. tostring(snap.truckIntegrity) .. "% integrity"
	progressLabel.Text =
		string.format("ROUTE %d%% · %d mph · safe corner %d", snap.routeProgress, snap.speed, snap.safeSpeed)

	local myRole: Types.RoleId? = getMyRole(snap)
	if spectating then
		roleLabel.Text = "Spectating · " .. table.concat(snap.members, ", ")
	elseif myRole then
		local info = Roles.getInfo(myRole)
		roleLabel.Text = info.displayName .. " · " .. info.hudHint
	elseif snap.phase == "Staging" or snap.phase == "Departing" then
		roleLabel.Text = string.format(
			"Crew %d/%d · ready %d/%d · roles assign at departure",
			#snap.members,
			MatchConfig.CrewCapacity,
			snap.readyCount,
			snap.readyRequired
		)
	else
		roleLabel.Text = "Waiting for role assignment"
	end

	refreshManifest(snap)

	local active = snap.activeFailure
	if active and isLivePhase(snap.phase) then
		failureLabel.Visible = true
		failureLabel.Text = string.upper(active.label)
			.. " · "
			.. active.responsibleRole
			.. " · "
			.. string.format("%.0fs", active.secondsRemaining)
			.. "\n"
			.. active.description
	else
		failureLabel.Visible = false
	end

	local showEndcard = snap.phase == "Resolve"
	endcardLabel.Visible = showEndcard
	if showEndcard then
		endcardLabel.Text = failReasonCopy(snap)
			.. string.format("\nLegs %d · Survived %ds · Cascades %d", snap.leg, snap.timeSurvived, snap.cascadeCount)
	end

	local staging = snap.phase == "Staging" and not spectating
	readyButton.Visible = staging
	startButton.Visible = staging
	if staging then
		local ready = amIReady(snap)
		readyButton.Text = if ready then "UNREADY" else "READY"
		readyButton.BackgroundColor3 = if ready then Color3.fromRGB(180, 90, 50) else Color3.fromRGB(40, 150, 95)
	end

	newConvoyButton.Visible = snap.phase == "Resolve" and not spectating

	local deciding = snap.phase == "BankOrPush" and not spectating
	bankButton.Visible = deciding
	pushButton.Visible = deciding
	if deciding then
		bankButton.Text = string.format("BANK %d cr  (%d)", snap.carriedValue, snap.bankVotes)
		pushButton.Text = string.format("PUSH LEG %d  (%d)  %ds", snap.leg + 1, snap.pushVotes, snap.decisionSeconds)
		bankButton.BackgroundTransparency = if snap.myVote == "Bank" then 0 else 0.35
		pushButton.BackgroundTransparency = if snap.myVote == "Push" then 0 else 0.35
	end

	driveFrame.Visible = isLivePhase(snap.phase) and myRole == "Driver" and not spectating

	local canAct = isLivePhase(snap.phase)
		and not spectating
		and active ~= nil
		and myRole ~= nil
		and active.responsibleRole == myRole
		and active.interaction ~= "Brake"
	actionButton.Visible = canAct
	if canAct and active then
		if active.interaction == "Ping" then
			actionButton.Text = "PING HAZARD"
		else
			actionButton.Text = if actionHolding
				then "KEEP HOLDING..."
				else "HOLD TO FIX " .. string.upper(active.label)
		end
	elseif active and active.interaction == "Brake" and myRole == "Driver" then
		setToast(string.format("BRAKE BELOW %d MPH BEFORE THE TURN", snap.safeSpeed))
	else
		stopActionHold()
	end
end

local function setDriveTouch(name: string, value: boolean)
	if name == "Forward" then
		touchForward = value
	elseif name == "Reverse" then
		touchReverse = value
	elseif name == "Left" then
		touchLeft = value
	elseif name == "Right" then
		touchRight = value
	elseif name == "Brake" then
		touchBrake = value
	end
end

local function bindHoldButton(button: TextButton, inputName: string)
	button.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			setDriveTouch(inputName, true)
		end
	end)
	button.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			setDriveTouch(inputName, false)
		end
	end)
end

local function mountStatusPanel()
	local frame = UIKit.panel({
		Name = "Status",
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.new(1, -24, 0, 236),
		Position = UDim2.fromOffset(12, 12),
		BackgroundColor3 = Color3.fromRGB(20, 22, 28),
		BackgroundTransparency = 0.12,
		CornerRadius = 12,
		Parent = gui,
	})

	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(560, 236)
	constraint.MinSize = Vector2.new(290, 220)
	constraint.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 2)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = frame

	phaseLabel = makeLabel(frame, "Phase", 1, 20)
	phaseLabel.Font = Enum.Font.GothamBlack
	phaseLabel.TextColor3 = Color3.fromRGB(255, 190, 55)
	objectiveLabel = makeLabel(frame, "Objective", 2, 34)
	objectiveLabel.TextWrapped = true
	objectiveLabel.TextColor3 = Color3.fromRGB(180, 230, 255)
	stackLabel = makeLabel(frame, "Stack", 3, 20)
	stackLabel.Font = Enum.Font.GothamBold
	stackLabel.TextColor3 = Color3.fromRGB(255, 215, 120)
	timerLabel = makeLabel(frame, "Timer", 4, 18)
	cargoLabel = makeLabel(frame, "Cargo", 5, 18)
	truckLabel = makeLabel(frame, "Truck", 6, 18)
	progressLabel = makeLabel(frame, "Progress", 7, 18)
	roleLabel = makeLabel(frame, "Role", 8, 32)
	roleLabel.TextWrapped = true
	toastLabel = makeLabel(frame, "Toast", 9, 28)
	toastLabel.TextWrapped = true
	toastLabel.TextColor3 = Color3.fromRGB(120, 205, 255)

	-- Placeholders until the first snapshot lands, so the HUD never shows the
	-- label names it was built from.
	phaseLabel.Text = "DEPOT"
	objectiveLabel.Text = "Finding you a bay..."
	stackLabel.Text = ""
	timerLabel.Text = ""
	cargoLabel.Text = ""
	truckLabel.Text = ""
	progressLabel.Text = ""
	roleLabel.Text = ""
	toastLabel.Text = ""
end

local function mountManifestCard()
	manifestFrame = UIKit.panel({
		Name = "Manifest",
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(262, 104),
		Position = UDim2.new(1, -12, 0, 12),
		BackgroundColor3 = Color3.fromRGB(18, 20, 26),
		BackgroundTransparency = 0.1,
		Visible = false,
		CornerRadius = 12,
		Parent = gui,
	})

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = manifestFrame

	manifestTitle = UIKit.label({
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 22),
		Font = Enum.Font.GothamBlack,
		TextSize = 17,
		Parent = manifestFrame,
	})

	manifestBody = UIKit.label({
		Name = "Body",
		Size = UDim2.new(1, 0, 1, -30),
		Position = UDim2.fromOffset(0, 26),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = Color3.fromRGB(210, 215, 225),
		Parent = manifestFrame,
	})
end

local function mountFailureBanner()
	failureLabel = Instance.new("TextLabel")
	failureLabel.Name = "FailureBanner"
	failureLabel.AnchorPoint = Vector2.new(0.5, 0)
	failureLabel.Size = UDim2.new(1, -30, 0, 78)
	failureLabel.Position = UDim2.new(0.5, 0, 0, 258)
	failureLabel.BackgroundColor3 = Color3.fromRGB(180, 48, 38)
	failureLabel.BackgroundTransparency = 0.05
	failureLabel.BorderSizePixel = 0
	failureLabel.Font = Enum.Font.GothamBold
	failureLabel.TextSize = 18
	failureLabel.TextColor3 = Color3.new(1, 1, 1)
	failureLabel.TextWrapped = true
	failureLabel.Visible = false
	failureLabel.Parent = gui

	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(680, 78)
	constraint.MinSize = Vector2.new(290, 78)
	constraint.Parent = failureLabel

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = failureLabel
end

local function mountEndcard()
	endcardLabel = Instance.new("TextLabel")
	endcardLabel.Name = "Endcard"
	endcardLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	endcardLabel.Size = UDim2.new(1, -40, 0, 130)
	endcardLabel.Position = UDim2.new(0.5, 0, 0.5, -30)
	endcardLabel.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
	endcardLabel.BackgroundTransparency = 0.08
	endcardLabel.BorderSizePixel = 0
	endcardLabel.Font = Enum.Font.GothamBold
	endcardLabel.TextSize = 18
	endcardLabel.TextColor3 = Color3.new(1, 1, 1)
	endcardLabel.TextWrapped = true
	endcardLabel.Visible = false
	endcardLabel.Parent = gui

	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(540, 150)
	constraint.MinSize = Vector2.new(280, 110)
	constraint.Parent = endcardLabel

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = endcardLabel
end

local function mountDriveControls()
	driveFrame = UIKit.frame({
		Name = "DriveControls",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	})

	leftButton = makeButton(driveFrame, "Left", "<", UDim2.fromOffset(72, 72), Color3.fromRGB(55, 85, 135))
	leftButton.AnchorPoint = Vector2.new(0, 1)
	leftButton.Position = UDim2.new(0, 18, 1, -28)
	leftButton.Visible = true

	rightButton = makeButton(driveFrame, "Right", ">", UDim2.fromOffset(72, 72), Color3.fromRGB(55, 85, 135))
	rightButton.AnchorPoint = Vector2.new(0, 1)
	rightButton.Position = UDim2.new(0, 100, 1, -28)
	rightButton.Visible = true

	throttleButton = makeButton(driveFrame, "Forward", "GO", UDim2.fromOffset(86, 72), Color3.fromRGB(40, 160, 90))
	throttleButton.AnchorPoint = Vector2.new(1, 1)
	throttleButton.Position = UDim2.new(1, -18, 1, -110)
	throttleButton.Visible = true

	brakeButton = makeButton(driveFrame, "Brake", "BRAKE", UDim2.fromOffset(86, 72), Color3.fromRGB(210, 72, 55))
	brakeButton.AnchorPoint = Vector2.new(1, 1)
	brakeButton.Position = UDim2.new(1, -18, 1, -28)
	brakeButton.Visible = true

	reverseButton = makeButton(driveFrame, "Reverse", "REV", UDim2.fromOffset(64, 54), Color3.fromRGB(85, 88, 100))
	reverseButton.AnchorPoint = Vector2.new(1, 1)
	reverseButton.Position = UDim2.new(1, -114, 1, -28)
	reverseButton.Visible = true

	bindHoldButton(leftButton, "Left")
	bindHoldButton(rightButton, "Right")
	bindHoldButton(throttleButton, "Forward")
	bindHoldButton(reverseButton, "Reverse")
	bindHoldButton(brakeButton, "Brake")
end

local function mountMainButtons()
	readyButton = makeButton(gui, "Ready", "READY", UDim2.fromOffset(230, 52), Color3.fromRGB(40, 150, 95))
	readyButton.AnchorPoint = Vector2.new(0.5, 1)
	readyButton.Position = UDim2.new(0.5, 0, 1, -104)

	startButton = makeButton(gui, "Start", "ROLL OUT NOW", UDim2.fromOffset(230, 52), Color3.fromRGB(65, 120, 225))
	startButton.AnchorPoint = Vector2.new(0.5, 1)
	startButton.Position = UDim2.new(0.5, 0, 1, -44)

	newConvoyButton =
		makeButton(gui, "NewConvoy", "NEW CONVOY", UDim2.fromOffset(230, 52), Color3.fromRGB(65, 120, 225))
	newConvoyButton.AnchorPoint = Vector2.new(0.5, 1)
	newConvoyButton.Position = UDim2.new(0.5, 0, 1, -44)

	bankButton = makeButton(gui, "Bank", "BANK", UDim2.fromOffset(196, 62), Color3.fromRGB(40, 150, 95))
	bankButton.AnchorPoint = Vector2.new(1, 1)
	bankButton.Position = UDim2.new(0.5, -8, 1, -44)

	pushButton = makeButton(gui, "Push", "PUSH", UDim2.fromOffset(196, 62), Color3.fromRGB(215, 110, 40))
	pushButton.AnchorPoint = Vector2.new(0, 1)
	pushButton.Position = UDim2.new(0.5, 8, 1, -44)

	actionButton = makeButton(gui, "Action", "HOLD TO FIX", UDim2.new(1, -36, 0, 68), Color3.fromRGB(230, 130, 40))
	actionButton.AnchorPoint = Vector2.new(0.5, 1)
	actionButton.Position = UDim2.new(0.5, 0, 1, -110)

	local actionConstraint = Instance.new("UISizeConstraint")
	actionConstraint.MaxSize = Vector2.new(360, 68)
	actionConstraint.MinSize = Vector2.new(250, 68)
	actionConstraint.Parent = actionButton
end

local function findCrewTruck(bayIndex: number): BasePart?
	local prototype = Workspace:FindFirstChild("CargoPrototype")
	local lane = prototype and prototype:FindFirstChild("Lane" .. tostring(bayIndex))
	local truck = lane and lane:FindFirstChild("CargoTruck")
	local body = truck and truck:FindFirstChild("Body")
	return if body and body:IsA("BasePart") then body else nil
end

local function bindInputs()
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.W or input.KeyCode == Enum.KeyCode.Up then
			keyForward = true
		elseif input.KeyCode == Enum.KeyCode.S or input.KeyCode == Enum.KeyCode.Down then
			keyReverse = true
		elseif input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.Left then
			keyLeft = true
		elseif input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.Right then
			keyRight = true
		elseif input.KeyCode == Enum.KeyCode.Space then
			keyBrake = true
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.W or input.KeyCode == Enum.KeyCode.Up then
			keyForward = false
		elseif input.KeyCode == Enum.KeyCode.S or input.KeyCode == Enum.KeyCode.Down then
			keyReverse = false
		elseif input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.Left then
			keyLeft = false
		elseif input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.Right then
			keyRight = false
		elseif input.KeyCode == Enum.KeyCode.Space then
			keyBrake = false
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			touchForward = false
			touchReverse = false
			touchLeft = false
			touchRight = false
			touchBrake = false
			stopActionHold()
		end
	end)

	actionButton.InputBegan:Connect(function(input: InputObject)
		local active = latest and latest.activeFailure
		if not active or active.interaction ~= "Hold" then
			return
		end
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			actionHolding = true
			roleActionRemote:FireServer("BeginResolve")
			refresh()
		end
	end)
	actionButton.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			stopActionHold()
			refresh()
		end
	end)
	actionButton.Activated:Connect(function()
		local active = latest and latest.activeFailure
		if active and active.interaction == "Ping" then
			roleActionRemote:FireServer("Ping")
		end
	end)

	RunService.Heartbeat:Connect(function(dt: number)
		driveSendAccumulator += dt
		if driveSendAccumulator < 0.1 then
			return
		end
		driveSendAccumulator = 0
		local snap = latest
		if not snap or snap.spectating or not isLivePhase(snap.phase) or getMyRole(snap) ~= "Driver" then
			return
		end
		local throttle = (if keyForward or touchForward then 1 else 0) - (if keyReverse or touchReverse then 1 else 0)
		local steering = (if keyRight or touchRight then 1 else 0) - (if keyLeft or touchLeft then 1 else 0)
		driveInputRemote:FireServer({
			throttle = throttle,
			steering = steering,
			braking = keyBrake or touchBrake,
		})
	end)

	RunService.RenderStepped:Connect(function()
		local snap = latest
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local shouldFollow = snap ~= nil
			and (isLivePhase(snap.phase) or snap.phase == "BankOrPush" or snap.phase == "Resolve")
		if not shouldFollow or not snap then
			if camera.CameraType == Enum.CameraType.Scriptable then
				camera.CameraType = Enum.CameraType.Custom
			end
			return
		end
		local body = findCrewTruck(snap.bayIndex)
		if not body then
			return
		end
		camera.CameraType = Enum.CameraType.Scriptable
		local cameraPosition = body.CFrame:PointToWorldSpace(Vector3.new(0, 13, -24))
		local lookPosition = body.CFrame:PointToWorldSpace(Vector3.new(0, 3, 9))
		camera.CFrame = CFrame.lookAt(cameraPosition, lookPosition)
	end)
end

function MatchUI.mount()
	gui = UIKit.screen("CargoCatastropheUI", player:WaitForChild("PlayerGui"))
	gui.DisplayOrder = 20

	crewSnapshotRemote = Net.get(Net.Names.CrewSnapshot)
	requestSnapshotRemote = Net.get(Net.Names.RequestSnapshot)
	requestStartRemote = Net.get(Net.Names.RequestStart)
	requestReadyRemote = Net.get(Net.Names.RequestReady)
	requestDecisionRemote = Net.get(Net.Names.RequestDecision)
	requestNewConvoyRemote = Net.get(Net.Names.RequestNewConvoy)
	roleActionRemote = Net.get(Net.Names.RoleAction)
	driveInputRemote = Net.get(Net.Names.DriveInput)

	mountStatusPanel()
	mountManifestCard()
	mountFailureBanner()
	mountEndcard()
	mountDriveControls()
	mountMainButtons()
	bindInputs()

	startButton.Activated:Connect(function()
		requestStartRemote:FireServer()
	end)
	readyButton.Activated:Connect(function()
		local snap = latest
		requestReadyRemote:FireServer(not (snap ~= nil and amIReady(snap)))
	end)
	newConvoyButton.Activated:Connect(function()
		requestNewConvoyRemote:FireServer()
	end)
	bankButton.Activated:Connect(function()
		requestDecisionRemote:FireServer("Bank")
	end)
	pushButton.Activated:Connect(function()
		requestDecisionRemote:FireServer("Push")
	end)

	crewSnapshotRemote.OnClientEvent:Connect(function(snapshot: Types.CrewSnapshot)
		latest = snapshot
		refresh()
	end)

	Net.get(Net.Names.Toast).OnClientEvent:Connect(function(message: string)
		setToast(message)
	end)

	Net.get(Net.Names.FailurePrompt).OnClientEvent:Connect(function(payload: any)
		if typeof(payload) == "table" and typeof(payload.label) == "string" then
			setToast("Crew response needed: " .. payload.label)
		end
	end)

	Net.get(Net.Names.CargoReveal).OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or typeof(payload.cargo) ~= "table" then
			return
		end
		setToast(
			string.format(
				"LEG %d MANIFEST: %s (%s) · worth %d credits",
				payload.leg,
				payload.cargo.label,
				payload.cargo.rarity,
				payload.legValue
			)
		)
	end)

	setToast("Cargo Catastrophe · step on a bay pad, then keep the load alive.")
	requestSnapshotRemote:FireServer()
end

return MatchUI
