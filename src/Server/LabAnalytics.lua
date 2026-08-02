--!strict

--[[
	Published-playtest analytics.

	Roblox only accepts AnalyticsService events from published servers. This
	wrapper still maintains its small amount of session state in Studio so the
	feedback UI and smoke tests behave exactly as they will in production, while
	the actual platform calls remain silent until the place is live.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LabTypes = require(Shared:WaitForChild("LabTypes"))
local RunVariants = require(Shared:WaitForChild("RunVariants"))

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
		runStartedCrewSize = 0,
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

function LabAnalytics:_custom(player: Player, eventName: string, value: number, customFields: { [string]: string }?)
	if not self.enabled then
		return
	end
	local ok, err = pcall(function()
		AnalyticsService:LogCustomEvent(player, eventName, value, customFields)
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
	self.runStartedCrewSize = #crew
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

function LabAnalytics:runFinished(outcome: string, crew: { Player }, summary: LabTypes.RunSummary?)
	local duration = math.max(0, os.clock() - self.runStartedAt)
	local outcomeEvent = OUTCOME_EVENT[outcome] or "CargoRunFinishedOther"
	local crewSize = if self.runStartedCrewSize == #crew
		then tostring(#crew)
		else string.format("%d->%d", self.runStartedCrewSize, #crew)
	local fields = {
		[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = "Outcome - " .. outcome,
		[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = "Crew - " .. crewSize,
		[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = "Variant - "
			.. (if summary then summary.variantKey else "unknown"),
	}
	for _, player in crew do
		local state: PlayerState = self:_state(player)
		state.runsFinished += 1
		self:_custom(player, outcomeEvent, 1, fields)
		self:_custom(player, "CargoRunDuration", duration, fields)
		if state.runsFinished == 1 then
			self:_onboarding(player, 4, "First Run Finished")
		end
	end

	-- AnalyticsService requires a Player, but these are run-level measurements.
	-- Emit them once through one crew member so a four-player run is not counted
	-- four times and weighted more heavily than a solo run.
	local reporter = crew[1]
	if summary and reporter then
		self:_custom(reporter, "CargoRunProgressPct", summary.routeProgress * 100, fields)
		self:_custom(reporter, "CargoRunCargoReadout", summary.cargoReadout, fields)
		self:_custom(reporter, "CargoRunChassisIntegrity", summary.chassisIntegrity, fields)
		self:_custom(reporter, "CargoRunStrapBreaks", summary.strapBreaks, fields)
		self:_custom(reporter, "CargoRunStrapRefits", summary.strapRefits, fields)
		self:_custom(reporter, "CargoRunRecoveries", summary.recoveries, fields)
		self:_custom(reporter, "CargoRunThrows", summary.throws, fields)
		self:_custom(reporter, "CargoRunCrewSwaps", summary.crewSwaps, fields)
		self:_custom(reporter, "CargoRunManualResets", summary.manualResets, fields)
		self:_custom(reporter, "CargoRunSimulationErrors", summary.simulationErrors, fields)
		self:_custom(reporter, "CargoDriveInputAgeAverageMs", summary.driveInputAgeAverageMs, fields)
		self:_custom(reporter, "CargoDriveInputAgeMaxMs", summary.driveInputAgeMaxMs, fields)
		self:_custom(reporter, "CargoDriveInputAgeOver200Pct", summary.driveInputAgeOver200Pct, fields)
		self:_custom(reporter, "CargoDriveInputAgeOver400Pct", summary.driveInputAgeOver400Pct, fields)
		self:_custom(reporter, "CargoRunEndCause", 1, {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = "Cause - " .. summary.endCause,
			[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = "Outcome - " .. outcome,
			[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = "Crew - " .. crewSize,
		})
	end
end

--[[
	What the crew chose, and what they were choosing between.

	The offered pair is recorded alongside the winner because a card that is
	never taken is the interesting result: it means either the risk is priced
	wrong or the crew cannot read it. Vote counts separate "we decided" from
	"the timer decided for us", which are the same outcome and different
	problems.
]]
function LabAnalytics:contractChosen(
	crew: { Player },
	choice: string,
	safeVotes: number,
	riskyVotes: number,
	offer: RunVariants.ContractOffer
)
	local reporter = crew[1]
	if not reporter then
		return
	end

	--[[
		One dimension per field. Crew size rides as the event value instead of
		being packed in beside the choice: packed, every breakdown on "was the
		risky card taken" splits into one bucket per crew size and stops
		answering the question it was added for.
	]]
	local fields = {
		[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = "Choice - " .. choice,
		[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = "Safe - "
			.. offer.safe.cargo.id
			.. "/"
			.. offer.safe.contract.id
			.. "/"
			.. offer.safe.difficulty.id,
		[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = "Risky - "
			.. offer.risky.cargo.id
			.. "/"
			.. offer.risky.contract.id
			.. "/"
			.. offer.risky.difficulty.id,
	}

	-- Count answers "how many boards resolved this way", sum answers "how many
	-- players it decided for". Both are worth having and neither needs a field.
	self:_custom(reporter, "CargoContractChosen", math.max(1, #crew), fields)
	self:_custom(reporter, "CargoContractVotesSafe", safeVotes, fields)
	self:_custom(reporter, "CargoContractVotesRisky", riskyVotes, fields)
	-- No vote at all is the board failing to land, not a preference for safe.
	if safeVotes + riskyVotes == 0 then
		self:_custom(reporter, "CargoContractNoVote", 1, fields)
	end
end

--[[
	The purchase funnel, such as it is.

	Two events rather than one because the gap between them is the number worth
	having: prompts that never become grants are a pricing or presentation
	problem, and a grant with no prompt before it means something is granting
	outside the flow.
]]
function LabAnalytics:purchasePrompted(player: Player, product)
	self:_custom(player, "CargoPurchasePrompted", 1, {
		[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = "Product - " .. product.key,
		[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = "Kind - " .. product.kind,
	})
end

function LabAnalytics:purchaseGranted(player: Player, product)
	self:_custom(player, "CargoPurchaseGranted", 1, {
		[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = "Product - " .. product.key,
		[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = "Kind - " .. product.kind,
	})
end

function LabAnalytics:invitePrompted(player: Player, crewSize: number, phase: string)
	self:_custom(player, "CargoInvitePrompted", 1, {
		[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = "Crew - " .. tostring(crewSize),
		[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = "Phase - " .. phase,
	})
end

--[[
	A completed daily. The objective id is the breakdown that matters: a rotation
	entry nobody ever completes is either unreadable or badly priced, and the
	only way to tell them apart is to see how often it is attempted versus met.
]]
function LabAnalytics:dailyCompleted(player: Player, objective)
	self:_custom(player, "CargoDailyCompleted", math.max(0, objective.bonus), {
		[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = "Daily - " .. objective.id,
	})
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
