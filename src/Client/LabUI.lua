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
local LabRemotes = require(Shared:WaitForChild("LabRemotes"))
local LabTypes = require(Shared:WaitForChild("LabTypes"))
local Net = require(Shared:WaitForChild("Net"))

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

local keyForward, keyReverse, keyLeft, keyRight, keyBrake = false, false, false, false, false
local touchForward, touchReverse, touchLeft, touchRight, touchBrake = false, false, false, false, false
local working = false
local driveAccumulator = 0

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
	font: Enum.Font
): TextLabel
	return UIKit.label({
		Name = name,
		Position = position,
		Size = size,
		Text = text,
		TextSize = textSize,
		Font = font,
		Parent = parent,
	})
end

local function button(parent: Instance, name: string, position: UDim2, size: UDim2, text: string): TextButton
	return UIKit.button({ Name = name, Position = position, Size = size, Text = text, Parent = parent })
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

		local row = UIKit.frame({
			Name = id,
			Position = UDim2.fromOffset(12, y),
			Size = UDim2.new(1, -24, 0, 26),
			BackgroundTransparency = 1,
			Parent = frame,
		})

		local tag = label(row, "Tag", UDim2.fromOffset(0, 0), UDim2.fromOffset(30, 26), id, 15, Enum.Font.GothamBold)

		local track = UIKit.frame({
			Name = "Track",
			Position = UDim2.fromOffset(34, 7),
			Size = UDim2.fromOffset(118, 12),
			BackgroundColor3 = Color3.fromRGB(40, 44, 52),
			Parent = row,
		})

		local fill = UIKit.frame({
			Name = "Fill",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = UIKit.Theme.Good,
			Parent = track,
		})

		-- Tension sits on top of health, so a bar that is full but glowing is a
		-- strap that is fine right now and about to stop being fine.
		local tension = UIKit.frame({
			Name = "Tension",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			-- Width is driven by tension each refresh; this is the resting state.
			Size = UDim2.fromOffset(0, 4),
			BackgroundColor3 = Color3.fromRGB(255, 235, 120),
			ZIndex = 2,
			Parent = track,
		})

		local status =
			label(row, "Status", UDim2.fromOffset(158, 0), UDim2.fromOffset(60, 26), "", 13, Enum.Font.GothamMedium)

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
			LabRemotes.fireServer(Net.Names.LabMoveTo, id)
		end)
		stationButtons[id] = element
	end

	workButton = button(frame, "Work", UDim2.fromOffset(12, 72), UDim2.fromOffset(132, 32), "HOLD E: WORK STRAP")
	workButton.BackgroundColor3 = UIKit.Theme.Positive

	local function setWorking(state: boolean)
		if working == state then
			return
		end
		working = state
		LabRemotes.fireServer(Net.Names.LabWork, state)
		workButton.BackgroundColor3 = if state then Color3.fromRGB(95, 180, 110) else UIKit.Theme.Positive
	end

	UIKit.bindHold(workButton, setWorking)

	switchButton = button(frame, "Switch", UDim2.fromOffset(152, 72), UDim2.fromOffset(64, 32), "T: ROLE")
	switchButton.Activated:Connect(function()
		LabRemotes.fireServer(Net.Names.LabSwitchRole)
	end)

	restartButton = button(frame, "Restart", UDim2.fromOffset(224, 72), UDim2.fromOffset(64, 32), "R: RESET")
	restartButton.BackgroundColor3 = UIKit.Theme.Danger
	restartButton.Activated:Connect(function()
		LabRemotes.fireServer(Net.Names.LabRestart)
	end)

	LabUI.setWorking = setWorking
end

local function buildTouchDrive(parent: Instance)
	if not UserInputService.TouchEnabled then
		return
	end

	local frame = panel(parent, "Drive", UDim2.new(1, -206, 1, -172), UDim2.fromOffset(190, 156))
	label(frame, "Title", UDim2.fromOffset(12, 6), UDim2.new(1, -24, 0, 18), "DRIVE", 14, Enum.Font.GothamBlack)

	local hold = UIKit.bindHold

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
	gui = UIKit.screen("CargoLabHUD", player:WaitForChild("PlayerGui"))

	local status = panel(gui, "Status", UDim2.fromOffset(16, 16), UDim2.fromOffset(300, 128))
	speedLabel =
		label(status, "Speed", UDim2.fromOffset(12, 8), UDim2.new(1, -24, 0, 30), "0", 28, Enum.Font.GothamBlack)
	conditionLabel = label(
		status,
		"Condition",
		UDim2.fromOffset(12, 42),
		UDim2.new(1, -24, 0, 24),
		"LOAD SECURE",
		19,
		Enum.Font.GothamBlack
	)
	readoutLabel =
		label(status, "Readout", UDim2.fromOffset(12, 66), UDim2.new(1, -24, 0, 18), "", 14, Enum.Font.GothamMedium)
	readoutLabel.TextColor3 = UIKit.Theme.Muted
	integrityLabel =
		label(status, "Integrity", UDim2.fromOffset(12, 86), UDim2.new(1, -24, 0, 18), "", 14, Enum.Font.GothamMedium)
	integrityLabel.TextColor3 = UIKit.Theme.Muted
	timeLabel =
		label(status, "Time", UDim2.fromOffset(12, 104), UDim2.new(1, -24, 0, 18), "", 13, Enum.Font.GothamMedium)
	timeLabel.TextColor3 = UIKit.Theme.Dim

	local brief = panel(gui, "Brief", UDim2.new(0.5, -260, 0, 16), UDim2.fromOffset(520, 66))
	objectiveLabel =
		label(brief, "Objective", UDim2.fromOffset(14, 8), UDim2.new(1, -28, 0, 24), "", 18, Enum.Font.GothamBold)
	objectiveLabel.TextXAlignment = Enum.TextXAlignment.Center
	hintLabel = label(brief, "Hint", UDim2.fromOffset(14, 34), UDim2.new(1, -28, 0, 22), "", 14, Enum.Font.GothamMedium)
	hintLabel.TextXAlignment = Enum.TextXAlignment.Center
	hintLabel.TextColor3 = UIKit.Theme.Muted

	toastLabel =
		label(gui, "Toast", UDim2.new(0.5, -300, 0, 92), UDim2.fromOffset(600, 26), "", 17, Enum.Font.GothamBold)
	toastLabel.TextXAlignment = Enum.TextXAlignment.Center
	toastLabel.TextColor3 = UIKit.Theme.Accent
	toastLabel.TextStrokeTransparency = 0.5

	resultFrame = panel(gui, "Result", UDim2.new(0.5, -220, 0.5, -70), UDim2.fromOffset(440, 128))
	resultFrame.BackgroundTransparency = 0.08
	resultFrame.Visible = false
	resultTitle =
		label(resultFrame, "Title", UDim2.fromOffset(0, 22), UDim2.new(1, 0, 0, 36), "", 30, Enum.Font.GothamBlack)
	resultTitle.TextXAlignment = Enum.TextXAlignment.Center
	resultDetail =
		label(resultFrame, "Detail", UDim2.fromOffset(0, 64), UDim2.new(1, 0, 0, 46), "", 16, Enum.Font.GothamMedium)
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

local STATION_MINE = Color3.fromRGB(95, 130, 190)
local STATION_TARGET = Color3.fromRGB(140, 120, 60)
local STRAP_BROKEN = Color3.fromRGB(120, 44, 44)
local STATUS_REFIT = Color3.fromRGB(255, 205, 90)
local STATUS_GONE = Color3.fromRGB(220, 90, 90)
local STATUS_WORKED = Color3.fromRGB(120, 220, 150)
local TAG_IDLE = Color3.fromRGB(200, 205, 215)

--[[
	Every write here goes through a guarded setter.

	The snapshot arrives at 10 Hz whether or not anything in it moved, and most
	of what it carries is stable for seconds at a time: the objective text, the
	hint, four strap colours, four station button colours. Writing all forty
	properties unconditionally meant the great majority of writes were setting a
	value to itself.
]]
local function refresh()
	local snap = latest
	if not snap then
		return
	end

	UIKit.setText(speedLabel, tostring(snap.speed))
	UIKit.setText(conditionLabel, CONDITION_TEXT[snap.condition] or snap.condition)
	UIKit.setTextColor(conditionLabel, CONDITION_COLOR[snap.condition] or UIKit.Theme.Text)
	UIKit.setText(
		readoutLabel,
		string.format(
			"condition %d%%   offset %.1f studs   lean %d deg",
			snap.cargoReadout,
			snap.cargoOffset,
			snap.cargoLeanDeg
		)
	)
	UIKit.setText(integrityLabel, string.format("truck %d%%", snap.chassisIntegrity))
	UIKit.setText(
		timeLabel,
		string.format("%ds left   route %d%%", snap.timeRemaining, math.floor(snap.routeProgress * 100))
	)

	UIKit.setText(objectiveLabel, snap.objective)
	UIKit.setText(hintLabel, snap.hint)

	for _, entry in snap.straps do
		local row = strapRows[entry.id]
		if not row then
			continue
		end

		local ratio = math.clamp(entry.health / LabConfig.StrapMaxHealth, 0, 1)
		UIKit.setSize(row.fill, UDim2.fromScale(ratio, 1))
		UIKit.setBackground(
			row.fill,
			if entry.broken
				then STRAP_BROKEN
				elseif ratio > 0.6 then UIKit.Theme.Good
				elseif ratio > 0.28 then UIKit.Theme.Warn
				else UIKit.Theme.Bad
		)

		UIKit.setSize(row.tension, UDim2.fromScale(math.clamp(entry.tension / 2.5, 0, 1), 0) + UDim2.fromOffset(0, 4))

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
	for id, element in stationButtons do
		UIKit.setBackground(
			element,
			if snap.myStation == id
				then STATION_MINE
				elseif snap.myMovingTo == id then STATION_TARGET
				else UIKit.Theme.Button
		)
		UIKit.setVisible(element, isStrapper)
	end

	UIKit.setVisible(workButton, isStrapper)
	UIKit.setText(
		workButton,
		if snap.myThrown
			then "THROWN OFF"
			elseif snap.myMovingTo then "MOVING TO " .. snap.myMovingTo
			elseif snap.myStation then "HOLD E: WORK " .. snap.myStation
			else "NO STATION"
	)

	local showResult = snap.phase == "Result" and snap.outcome ~= nil
	UIKit.setVisible(resultFrame, showResult)
	if showResult then
		UIKit.setText(resultTitle, string.upper(snap.outcome))
		UIKit.setTextColor(
			resultTitle,
			if snap.outcome == "Delivered"
				then Color3.fromRGB(110, 220, 140)
				elseif snap.outcome == "PartialLoss" then Color3.fromRGB(245, 195, 80)
				else Color3.fromRGB(235, 95, 85)
		)
		UIKit.setText(
			resultDetail,
			(RESULT_DETAIL[snap.outcome] or "")
				.. string.format("\n\nRestarting in %ds. Press R to go now.", snap.restartSeconds)
		)
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
			LabRemotes.fireServer(Net.Names.LabRestart)
		elseif code == Enum.KeyCode.T then
			LabRemotes.fireServer(Net.Names.LabSwitchRole)
		elseif code == Enum.KeyCode.One then
			LabRemotes.fireServer(Net.Names.LabMoveTo, LabConfig.StationOrder[1])
		elseif code == Enum.KeyCode.Two then
			LabRemotes.fireServer(Net.Names.LabMoveTo, LabConfig.StationOrder[2])
		elseif code == Enum.KeyCode.Three then
			LabRemotes.fireServer(Net.Names.LabMoveTo, LabConfig.StationOrder[3])
		elseif code == Enum.KeyCode.Four then
			LabRemotes.fireServer(Net.Names.LabMoveTo, LabConfig.StationOrder[4])
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
	build()
	bindInputs()
	bindCamera()

	LabRemotes.onClient(Net.Names.LabSnapshot, function(snap: LabTypes.LabSnapshot)
		latest = snap
		refresh()
	end)

	local toastToken = 0
	LabRemotes.onClient(Net.Names.LabEvent, function(text: any)
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

		LabRemotes.fireServer(Net.Names.LabDrive, {
			throttle = (if keyForward or touchForward then 1 else 0) - (if keyReverse or touchReverse then 1 else 0),
			steering = (if keyRight or touchRight then 1 else 0) - (if keyLeft or touchLeft then 1 else 0),
			braking = keyBrake or touchBrake,
		})
	end)
end

return LabUI
