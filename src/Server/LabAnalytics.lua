--!strict

--[[
	Published-playtest analytics.

	Roblox only accepts AnalyticsService events from published servers. This
	wrapper still maintains its small amount of session state in Studio so the
	feedback UI and smoke tests behave exactly as they will in production, while
	the actual platform calls remain silent until the place is live.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

type PlayerState = {
	joinedAt: number,
	seatAssigned: boolean,
	firstInput: boolean,
	runsStarted: number,
	runsFinished: number,
	feedback: string?,
	lastRole: string?,
}

local OUTCOME_EVENT: { [string]: string } = {
	Delivered = "CargoRunFinishedDelivered",
	PartialLoss = "CargoRunFinishedPartialLoss",
	CargoLost = "CargoRunFinishedCargoLost",
	TruckWrecked = "CargoRunFinishedTruckWrecked",
	TimeExpired = "CargoRunFinishedTimeExpired",
	Abandoned = "CargoRunFinishedAbandoned",
}

local FEEDBACK_EVENT: { [string]: string } = {
	Yes = "CargoFeedbackYes",
	Maybe = "CargoFeedbackMaybe",
	No = "CargoFeedbackNo",
}

local LabAnalytics = {}
LabAnalytics.__index = LabAnalytics

function LabAnalytics.new()
	return setmetatable({
		enabled = not RunService:IsStudio(),
		players = {} :: { [number]: PlayerState },
		currentRunIndex = 0,
		runStartedAt = 0,
		crisisRuns = {} :: { [number]: boolean },
		warned = false,
	}, LabAnalytics)
end

function LabAnalytics:_reportFailure(label: string, err: any)
	if self.warned then
		return
	end
	self.warned = true
	warn(string.format("[CargoAnalytics] %s failed: %s", label, tostring(err)))
end

function LabAnalytics:_custom(player: Player, eventName: string, value: number)
	if not self.enabled then
		return
	end
	local ok, err = pcall(function()
		AnalyticsService:LogCustomEvent(player, eventName, value)
	end)
	if not ok then
		self:_reportFailure(eventName, err)
	end
end

function LabAnalytics:_onboarding(player: Player, step: number, name: string)
	if not self.enabled then
		return
	end
	local ok, err = pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, name)
	end)
	if not ok then
		self:_reportFailure("onboarding " .. name, err)
	end
end

function LabAnalytics:_state(player: Player): PlayerState
	local state = self.players[player.UserId]
	if state then
		return state
	end

	state = {
		joinedAt = os.clock(),
		seatAssigned = false,
		firstInput = false,
		runsStarted = 0,
		runsFinished = 0,
		feedback = nil,
		lastRole = nil,
	}
	self.players[player.UserId] = state
	self:_custom(player, "CargoPlayerJoined", 1)
	self:_onboarding(player, 1, "Joined Game")
	return state
end

function LabAnalytics:playerJoined(player: Player)
	self:_state(player)
end

function LabAnalytics:roleAssigned(player: Player, role: string)
	local state = self:_state(player)
	if not state.seatAssigned then
		state.seatAssigned = true
		self:_onboarding(player, 2, "Crew Seat Assigned")
	end
	if state.lastRole == role then
		return
	end
	state.lastRole = role
	self:_custom(player, if role == "Driver" then "CargoRoleDriver" else "CargoRoleStrapper", 1)
end

function LabAnalytics:noteInput(player: Player, role: string)
	local state = self:_state(player)
	if state.firstInput then
		return
	end
	state.firstInput = true
	local elapsed = math.max(0, os.clock() - state.joinedAt)
	self:_custom(player, if role == "Driver" then "CargoFirstInputDriver" else "CargoFirstInputStrapper", elapsed)
	self:_onboarding(player, 3, "First Crew Input")
end

function LabAnalytics:runStarted(runIndex: number, crew: { Player })
	self.currentRunIndex = runIndex
	self.runStartedAt = os.clock()
	for _, player in crew do
		local state: PlayerState = self:_state(player)
		state.runsStarted += 1
		self:_custom(player, "CargoRunStarted", #crew)
		if state.runsStarted == 2 then
			self:_custom(player, "CargoSecondRunStarted", #crew)
			self:_onboarding(player, 5, "Second Run Started")
		end
	end
end

function LabAnalytics:firstCrisis(runIndex: number, crew: { Player })
	if self.crisisRuns[runIndex] then
		return
	end
	self.crisisRuns[runIndex] = true
	local elapsed = math.max(0, os.clock() - self.runStartedAt)
	for _, player in crew do
		self:_custom(player, "CargoFirstCrisis", elapsed)
	end
end

function LabAnalytics:crewSwap(gateIndex: number, crew: { Player })
	for _, player in crew do
		self:_custom(player, "CargoCrewSwap", gateIndex)
	end
end

function LabAnalytics:creditsEarned(player: Player, amount: number)
	self:_custom(player, "CargoCreditsEarned", math.max(0, amount))
end

function LabAnalytics:runFinished(outcome: string, crew: { Player })
	local duration = math.max(0, os.clock() - self.runStartedAt)
	local outcomeEvent = OUTCOME_EVENT[outcome] or "CargoRunFinishedOther"
	for _, player in crew do
		local state: PlayerState = self:_state(player)
		state.runsFinished += 1
		self:_custom(player, outcomeEvent, 1)
		self:_custom(player, "CargoRunDuration", duration)
		if state.runsFinished == 1 then
			self:_onboarding(player, 4, "First Run Finished")
		end
	end
end

function LabAnalytics:shouldAskForFeedback(player: Player): boolean
	local state = self.players[player.UserId]
	return state ~= nil and state.runsFinished >= 1 and state.feedback == nil
end

function LabAnalytics:hasFeedback(player: Player): boolean
	local state = self.players[player.UserId]
	return state ~= nil and state.feedback ~= nil
end

function LabAnalytics:anyFeedbackNeeded(crew: { Player }): boolean
	for _, player in crew do
		if self:shouldAskForFeedback(player) then
			return true
		end
	end
	return false
end

function LabAnalytics:submitFeedback(player: Player, answer: string): boolean
	local eventName = FEEDBACK_EVENT[answer]
	local state = self.players[player.UserId]
	if not eventName or not state or state.runsFinished < 1 or state.feedback ~= nil then
		return false
	end

	state.feedback = answer
	self:_custom(player, eventName, 1)
	return true
end

function LabAnalytics:playerLeaving(player: Player, leftDuringRun: boolean)
	local state = self.players[player.UserId]
	if not state then
		return
	end
	self:_custom(player, "CargoSessionDuration", math.max(0, os.clock() - state.joinedAt))
	if leftDuringRun then
		self:_custom(player, "CargoDepartedDuringRun", 1)
	end
	self.players[player.UserId] = nil
end

function LabAnalytics:destroy()
	table.clear(self.players)
	table.clear(self.crisisRuns)
end

return LabAnalytics
