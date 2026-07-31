--!nonstrict

--[[
	The fun-test HUD.

	Deliberately thin. The load's condition is supposed to be legible from the
	truck itself, so the HUD's job is only to name what you are looking at, show
	which straps are in trouble, and tell you which controls you have. If a
	playtester has to read this panel to know the load is sliding, the physical
	feedback has failed and no amount of UI will save it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LabConfig = require(Shared:WaitForChild("LabConfig"))
local Net = require(Shared:WaitForChild("Net"))

local LabUI = {}

local player = Players.LocalPlayer
local latest = nil

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

local keyForward, keyReverse, keyLeft, keyRight, keyBrake = false, false, false, false, false
local touchForward, touchReverse, touchLeft, touchRight, touchBrake = false, false, false, false, false
local working = false
local driveAccumulator = 0

local driveRemote, moveRemote, workRemote, restartRemote, switchRemote

-- ------------------------------------------------------------- ui helpers

local function panel(parent: Instance, name: string, position: UDim2, size: UDim2): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Position = position
	frame.Size = size
	frame.BackgroundColor3 = Color3.fromRGB(16, 18, 22)
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	return frame
end

local function label(
	parent: Instance,
	name: string,
	position: UDim2,
	size: UDim2,
	text: string,
	textSize: number,
	font: Enum.Font
): TextLabel
	local element = Instance.new("TextLabel")
	element.Name = name
	element.Position = position
	element.Size = size
	element.BackgroundTransparency = 1
	element.Font = font
	element.TextSize = textSize
	element.TextColor3 = Color3.fromRGB(235, 235, 235)
	element.TextXAlignment = Enum.TextXAlignment.Left
	element.Text = text
	element.Parent = parent
	return element
end

local function button(parent: Instance, name: string, position: UDim2, size: UDim2, text: string): TextButton
	local element = Instance.new("TextButton")
	element.Name = name
	element.Position = position
	element.Size = size
	element.BackgroundColor3 = Color3.fromRGB(48, 54, 64)
	element.BorderSizePixel = 0
	element.AutoButtonColor = true
	element.Font = Enum.Font.GothamBold
	element.TextSize = 16
	element.TextColor3 = Color3.fromRGB(240, 240, 240)
	element.Text = text
	element.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = element

	return element
end

-- --------------------------------------------------------------- build ui

local gui, speedLabel, conditionLabel, readoutLabel, timeLabel, integrityLabel
local objectiveLabel, hintLabel, toastLabel, resultFrame, resultTitle, resultDetail
local strapRows: { [string]: any } = {}
local stationButtons: { [string]: TextButton } = {}
local workButton, restartButton, switchButton

local function buildStrapPanel(parent: Instance)
	local frame = panel(parent, "Straps", UDim2.new(1, -238, 0, 16), UDim2.fromOffset(222, 168))

	label(frame, "Title", UDim2.fromOffset(12, 8), UDim2.new(1, -24, 0, 20), "STRAPS", 15, Enum.Font.GothamBlack)

	for index, id in LabConfig.StrapOrder do
		local y = 34 + (index - 1) * 32

		local row = Instance.new("Frame")
		row.Name = id
		row.Position = UDim2.fromOffset(12, y)
		row.Size = UDim2.new(1, -24, 0, 26)
		row.BackgroundTransparency = 1
		row.Parent = frame

		local tag = label(row, "Tag", UDim2.fromOffset(0, 0), UDim2.fromOffset(30, 26), id, 15, Enum.Font.GothamBold)

		local track = Instance.new("Frame")
		track.Name = "Track"
		track.Position = UDim2.fromOffset(34, 7)
		track.Size = UDim2.fromOffset(118, 12)
		track.BackgroundColor3 = Color3.fromRGB(40, 44, 52)
		track.BorderSizePixel = 0
		track.Parent = row

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.fromScale(1, 1)
		fill.BackgroundColor3 = Color3.fromRGB(90, 210, 120)
		fill.BorderSizePixel = 0
		fill.Parent = track

		-- Tension sits on top of health, so a bar that is full but glowing is a
		-- strap that is fine right now and about to stop being fine.
		local tension = Instance.new("Frame")
		tension.Name = "Tension"
		tension.AnchorPoint = Vector2.new(0, 1)
		tension.Position = UDim2.new(0, 0, 1, 0)
		tension.Size = UDim2.new(0, 0, 0, 4)
		tension.BackgroundColor3 = Color3.fromRGB(255, 235, 120)
		tension.BorderSizePixel = 0
		tension.ZIndex = 2
		tension.Parent = track

		local status = label(
			row,
			"Status",
			UDim2.fromOffset(158, 0),
			UDim2.fromOffset(60, 26),
			"",
			13,
			Enum.Font.GothamMedium
		)

		strapRows[id] = { row = row, tag = tag, fill = fill, tension = tension, status = status }
	end
end

local function buildControls(parent: Instance)
	local frame = panel(parent, "Controls", UDim2.new(0, 16, 1, -132), UDim2.fromOffset(300, 116))

	label(frame, "Title", UDim2.fromOffset(12, 8), UDim2.new(1, -24, 0, 18), "STATIONS", 14, Enum.Font.GothamBlack)

	for index, id in LabConfig.StationOrder do
		local element = button(
			frame,
			id,
			UDim2.fromOffset(12 + (index - 1) * 70, 32),
			UDim2.fromOffset(62, 32),
			tostring(index) .. "  " .. id
		)
		element.Activated:Connect(function()
			moveRemote:FireServer(id)
		end)
		stationButtons[id] = element
	end

	workButton = button(frame, "Work", UDim2.fromOffset(12, 72), UDim2.fromOffset(132, 32), "HOLD E: WORK STRAP")
	workButton.BackgroundColor3 = Color3.fromRGB(60, 110, 70)

	local function setWorking(state: boolean)
		if working == state then
			return
		end
		working = state
		workRemote:FireServer(state)
		workButton.BackgroundColor3 = if state
			then Color3.fromRGB(95, 180, 110)
			else Color3.fromRGB(60, 110, 70)
	end

	workButton.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			setWorking(true)
		end
	end)
	workButton.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			setWorking(false)
		end
	end)

	switchButton = button(frame, "Switch", UDim2.fromOffset(152, 72), UDim2.fromOffset(64, 32), "T: ROLE")
	switchButton.Activated:Connect(function()
		switchRemote:FireServer()
	end)

	restartButton = button(frame, "Restart", UDim2.fromOffset(224, 72), UDim2.fromOffset(64, 32), "R: RESET")
	restartButton.BackgroundColor3 = Color3.fromRGB(96, 54, 54)
	restartButton.Activated:Connect(function()
		restartRemote:FireServer()
	end)

	LabUI.setWorking = setWorking
end

local function buildTouchDrive(parent: Instance)
	if not UserInputService.TouchEnabled then
		return
	end

	local frame = panel(parent, "Drive", UDim2.new(1, -206, 1, -172), UDim2.fromOffset(190, 156))
	label(frame, "Title", UDim2.fromOffset(12, 6), UDim2.new(1, -24, 0, 18), "DRIVE", 14, Enum.Font.GothamBlack)

	local function hold(element: TextButton, setter: (boolean) -> ())
		element.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Touch then
				setter(true)
			end
		end)
		element.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Touch then
				setter(false)
			end
		end)
	end

	hold(button(frame, "Fwd", UDim2.fromOffset(66, 28), UDim2.fromOffset(56, 38), "GO"), function(state)
		touchForward = state
	end)
	hold(button(frame, "Left", UDim2.fromOffset(8, 70), UDim2.fromOffset(56, 38), "<"), function(state)
		touchLeft = state
	end)
	hold(button(frame, "Right", UDim2.fromOffset(124, 70), UDim2.fromOffset(56, 38), ">"), function(state)
		touchRight = state
	end)
	hold(button(frame, "Rev", UDim2.fromOffset(8, 112), UDim2.fromOffset(56, 34), "REV"), function(state)
		touchReverse = state
	end)
	hold(button(frame, "Brake", UDim2.fromOffset(66, 70), UDim2.fromOffset(56, 76), "BRAKE"), function(state)
		touchBrake = state
	end)
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "CargoLabHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local status = panel(gui, "Status", UDim2.fromOffset(16, 16), UDim2.fromOffset(300, 128))
	speedLabel = label(status, "Speed", UDim2.fromOffset(12, 8), UDim2.new(1, -24, 0, 30), "0", 28, Enum.Font.GothamBlack)
	conditionLabel = label(
		status,
		"Condition",
		UDim2.fromOffset(12, 42),
		UDim2.new(1, -24, 0, 24),
		"LOAD SECURE",
		19,
		Enum.Font.GothamBlack
	)
	readoutLabel = label(
		status,
		"Readout",
		UDim2.fromOffset(12, 66),
		UDim2.new(1, -24, 0, 18),
		"",
		14,
		Enum.Font.GothamMedium
	)
	readoutLabel.TextColor3 = Color3.fromRGB(170, 178, 190)
	integrityLabel = label(
		status,
		"Integrity",
		UDim2.fromOffset(12, 86),
		UDim2.new(1, -24, 0, 18),
		"",
		14,
		Enum.Font.GothamMedium
	)
	integrityLabel.TextColor3 = Color3.fromRGB(170, 178, 190)
	timeLabel = label(
		status,
		"Time",
		UDim2.fromOffset(12, 104),
		UDim2.new(1, -24, 0, 18),
		"",
		13,
		Enum.Font.GothamMedium
	)
	timeLabel.TextColor3 = Color3.fromRGB(140, 148, 160)

	local brief = panel(gui, "Brief", UDim2.new(0.5, -260, 0, 16), UDim2.fromOffset(520, 66))
	objectiveLabel = label(
		brief,
		"Objective",
		UDim2.fromOffset(14, 8),
		UDim2.new(1, -28, 0, 24),
		"",
		18,
		Enum.Font.GothamBold
	)
	objectiveLabel.TextXAlignment = Enum.TextXAlignment.Center
	hintLabel = label(brief, "Hint", UDim2.fromOffset(14, 34), UDim2.new(1, -28, 0, 22), "", 14, Enum.Font.GothamMedium)
	hintLabel.TextXAlignment = Enum.TextXAlignment.Center
	hintLabel.TextColor3 = Color3.fromRGB(170, 178, 190)

	toastLabel = label(
		gui,
		"Toast",
		UDim2.new(0.5, -300, 0, 92),
		UDim2.fromOffset(600, 26),
		"",
		17,
		Enum.Font.GothamBold
	)
	toastLabel.TextXAlignment = Enum.TextXAlignment.Center
	toastLabel.TextColor3 = Color3.fromRGB(255, 210, 110)
	toastLabel.TextStrokeTransparency = 0.5

	resultFrame = panel(gui, "Result", UDim2.new(0.5, -220, 0.5, -70), UDim2.fromOffset(440, 128))
	resultFrame.BackgroundTransparency = 0.08
	resultFrame.Visible = false
	resultTitle = label(
		resultFrame,
		"Title",
		UDim2.fromOffset(0, 22),
		UDim2.new(1, 0, 0, 36),
		"",
		30,
		Enum.Font.GothamBlack
	)
	resultTitle.TextXAlignment = Enum.TextXAlignment.Center
	resultDetail = label(
		resultFrame,
		"Detail",
		UDim2.fromOffset(0, 64),
		UDim2.new(1, 0, 0, 46),
		"",
		16,
		Enum.Font.GothamMedium
	)
	resultDetail.TextXAlignment = Enum.TextXAlignment.Center
	resultDetail.TextWrapped = true

	buildStrapPanel(gui)
	buildControls(gui)
	buildTouchDrive(gui)
end

-- ---------------------------------------------------------------- refresh

local RESULT_DETAIL = {
	Delivered = "Every strap held and the load never left the deck.",
	PartialLoss = "You got there, but the load is not what it was.",
	CargoLost = "The load is somewhere back on the road.",
	TruckWrecked = "The truck is not going anywhere.",
	TimeExpired = "The clock beat you to the depot.",
}

local function refresh()
	local snap = latest
	if not snap then
		return
	end

	speedLabel.Text = tostring(snap.speed)
	conditionLabel.Text = CONDITION_TEXT[snap.condition] or snap.condition
	conditionLabel.TextColor3 = CONDITION_COLOR[snap.condition] or Color3.fromRGB(235, 235, 235)
	readoutLabel.Text = string.format(
		"condition %d%%   offset %.1f studs   lean %d deg",
		snap.cargoReadout,
		snap.cargoOffset,
		snap.cargoLeanDeg
	)
	integrityLabel.Text = string.format("truck %d%%", snap.chassisIntegrity)
	timeLabel.Text = string.format("%ds left   route %d%%", snap.timeRemaining, math.floor(snap.routeProgress * 100))

	objectiveLabel.Text = snap.objective
	hintLabel.Text = snap.hint

	for _, entry in snap.straps do
		local row = strapRows[entry.id]
		if not row then
			continue
		end

		local ratio = math.clamp(entry.health / LabConfig.StrapMaxHealth, 0, 1)
		row.fill.Size = UDim2.fromScale(ratio, 1)
		row.fill.BackgroundColor3 = if entry.broken
			then Color3.fromRGB(120, 44, 44)
			elseif ratio > 0.6 then Color3.fromRGB(90, 210, 120)
			elseif ratio > 0.28 then Color3.fromRGB(240, 200, 70)
			else Color3.fromRGB(240, 110, 60)

		row.tension.Size = UDim2.fromScale(math.clamp(entry.tension / 2.5, 0, 1), 0)
			+ UDim2.fromOffset(0, 4)

		if entry.broken then
			row.status.Text = if entry.reattachable then "REFIT" else "GONE"
			row.status.TextColor3 = if entry.reattachable
				then Color3.fromRGB(255, 205, 90)
				else Color3.fromRGB(220, 90, 90)
		elseif entry.workedBy then
			row.status.Text = "WORKED"
			row.status.TextColor3 = Color3.fromRGB(120, 220, 150)
		else
			row.status.Text = ""
		end

		row.tag.TextColor3 = if snap.myStation == entry.id
			then Color3.fromRGB(255, 210, 110)
			else Color3.fromRGB(200, 205, 215)
	end

	for id, element in stationButtons do
		local isMine = snap.myStation == id
		local isTarget = snap.myMovingTo == id
		element.BackgroundColor3 = if isMine
			then Color3.fromRGB(95, 130, 190)
			elseif isTarget then Color3.fromRGB(140, 120, 60)
			else Color3.fromRGB(48, 54, 64)
	end

	local isStrapper = snap.myRole == "Strapper"
	for _, element in stationButtons do
		element.Visible = isStrapper
	end
	workButton.Visible = isStrapper
	if snap.myThrown then
		workButton.Text = "THROWN OFF"
	elseif snap.myMovingTo then
		workButton.Text = "MOVING TO " .. snap.myMovingTo
	elseif snap.myStation then
		workButton.Text = "HOLD E: WORK " .. snap.myStation
	else
		workButton.Text = "NO STATION"
	end

	if snap.phase == "Result" and snap.outcome then
		resultFrame.Visible = true
		resultTitle.Text = string.upper(snap.outcome)
		resultTitle.TextColor3 = if snap.outcome == "Delivered"
			then Color3.fromRGB(110, 220, 140)
			elseif snap.outcome == "PartialLoss" then Color3.fromRGB(245, 195, 80)
			else Color3.fromRGB(235, 95, 85)
		resultDetail.Text = (RESULT_DETAIL[snap.outcome] or "")
			.. string.format("\n\nRestarting in %ds. Press R to go now.", snap.restartSeconds)
	else
		resultFrame.Visible = false
	end
end

-- ----------------------------------------------------------------- inputs

local function bindInputs()
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
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
			restartRemote:FireServer()
		elseif code == Enum.KeyCode.T then
			switchRemote:FireServer()
		elseif code == Enum.KeyCode.One then
			moveRemote:FireServer(LabConfig.StationOrder[1])
		elseif code == Enum.KeyCode.Two then
			moveRemote:FireServer(LabConfig.StationOrder[2])
		elseif code == Enum.KeyCode.Three then
			moveRemote:FireServer(LabConfig.StationOrder[3])
		elseif code == Enum.KeyCode.Four then
			moveRemote:FireServer(LabConfig.StationOrder[4])
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
	end)
end

-- ----------------------------------------------------------------- camera

local function findChassis(): BasePart?
	local root = Workspace:FindFirstChild("CargoLab")
	local truck = root and root:FindFirstChild("LabTruck")
	local chassis = truck and truck:FindFirstChild("Chassis")
	return if chassis and chassis:IsA("BasePart") then chassis else nil
end

local function bindCamera()
	local camera = Workspace.CurrentCamera

	RunService.RenderStepped:Connect(function(dt: number)
		local chassis = findChassis()
		if not chassis then
			if camera.CameraType == Enum.CameraType.Scriptable then
				camera.CameraType = Enum.CameraType.Custom
			end
			return
		end

		camera.CameraType = Enum.CameraType.Scriptable

		-- Follow the truck's heading but never its roll, or a rollover makes
		-- the viewer motion sick instead of making them laugh.
		local look = chassis.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		flat = if flat.Magnitude < 0.01 then Vector3.new(0, 0, 1) else flat.Unit

		local focus = chassis.Position + Vector3.new(0, 3, 0)
		local desired = CFrame.lookAt(focus - flat * 34 + Vector3.new(0, 14, 0), focus)
		camera.CFrame = camera.CFrame:Lerp(desired, 1 - math.exp(-7 * dt))

		local speed = chassis.AssemblyLinearVelocity.Magnitude
		local targetFov = 68 + math.clamp(speed / LabConfig.MaxForwardSpeed, 0, 1) * 18
		camera.FieldOfView += (targetFov - camera.FieldOfView) * math.min(1, dt * 4)
	end)
end

-- ------------------------------------------------------------------ mount

function LabUI.mount()
	driveRemote = Net.get(Net.Names.LabDrive)
	moveRemote = Net.get(Net.Names.LabMoveTo)
	workRemote = Net.get(Net.Names.LabWork)
	restartRemote = Net.get(Net.Names.LabRestart)
	switchRemote = Net.get(Net.Names.LabSwitchRole)

	build()
	bindInputs()
	bindCamera()

	Net.get(Net.Names.LabSnapshot).OnClientEvent:Connect(function(snap: any)
		latest = snap
		refresh()
	end)

	local toastToken = 0
	Net.get(Net.Names.LabEvent).OnClientEvent:Connect(function(text: any)
		if typeof(text) ~= "string" then
			return
		end
		toastLabel.Text = text
		toastToken += 1
		local token = toastToken
		task.delay(3.5, function()
			if token == toastToken then
				toastLabel.Text = ""
			end
		end)
	end)

	RunService.Heartbeat:Connect(function(dt: number)
		driveAccumulator += dt
		if driveAccumulator < 0.06 then
			return
		end
		driveAccumulator = 0

		local snap = latest
		if not snap or snap.myRole ~= "Driver" or snap.phase ~= "Run" then
			return
		end

		driveRemote:FireServer({
			throttle = (if keyForward or touchForward then 1 else 0)
				- (if keyReverse or touchReverse then 1 else 0),
			steering = (if keyRight or touchRight then 1 else 0) - (if keyLeft or touchLeft then 1 else 0),
			braking = keyBrake or touchBrake,
		})
	end)
end

return LabUI
