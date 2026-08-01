--!nonstrict

--[[
	The smallest thing that answers the go/no-go questions.

	Development keeps an in-memory event list, prints it at run end, and may
	write a Studio artifact. The same counters also produce an anonymous compact
	summary for published AnalyticsService events; raw events and input samples
	never leave the server.

	The metrics exist to catch the two failure modes the design is most at risk
	of: a role that never acts, and a run where nothing physically happened.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevConfig = require(Shared:WaitForChild("DevConfig"))

local TuningService = require(script.Parent.TuningService)

local ARTIFACT_FOLDER = "LabRuns"
local ARTIFACT_SCHEMA = 2

-- Roughly five minutes at the sample rate below. A guard against a run that is
-- left going, not an expected limit.
local MAX_INPUT_SAMPLES = 4000

local LabTelemetry = {}
LabTelemetry.__index = LabTelemetry

function LabTelemetry.new()
	local self = setmetatable({ runIndex = 0 }, LabTelemetry)
	self:reset()
	return self
end

function LabTelemetry:reset()
	self.runIndex += 1
	self.runStart = os.clock()
	self.startedAt = os.time()
	self.events = {}
	self.inputSamples = {}
	self.perPlayer = {}
	self.conditionChanges = 0
	self.recoveries = 0
	self.strapBreaks = 0
	self.strapRefits = 0
	self.stationMoves = 0
	self.throws = 0
	self.crewSwaps = 0
	self.pressureEvents = 0
	self.manualResets = 0
	self.simulationErrors = 0
	self.driveInputAgeSamples = 0
	self.driveInputAgeTotal = 0
	self.driveInputAgeMax = 0
	self.driveInputAgeOver200 = 0
	self.driveInputAgeOver400 = 0
	self.firstInputAt = nil
	self.firstMovementAt = nil
	self.firstCrisisAt = nil
	self.designedCascade = false
	self.emergentCascade = false
	self.worstCondition = "Secure"
end

-- Client timestamps use Workspace:GetServerTimeNow(), so they share the
-- server's clock. We retain only aggregate age: published servers never store
-- the raw input stream or a per-player latency history.
function LabTelemetry:noteDriveInputAge(seconds: number)
	if not DevConfig.Telemetry or seconds < 0 or seconds > 10 then
		return
	end
	self.driveInputAgeSamples += 1
	self.driveInputAgeTotal += seconds
	self.driveInputAgeMax = math.max(self.driveInputAgeMax, seconds)
	if seconds >= 0.2 then
		self.driveInputAgeOver200 += 1
	end
	if seconds >= 0.4 then
		self.driveInputAgeOver400 += 1
	end
end

function LabTelemetry:noteManualReset()
	self.manualResets += 1
	self:log("manual_reset")
end

function LabTelemetry:noteSimulationError(detail: string)
	self.simulationErrors += 1
	self:log("simulation_error", detail)
end

function LabTelemetry:_player(name: string)
	local entry = self.perPlayer[name]
	if not entry then
		entry = { name = name, role = "?", actions = 0, moves = 0, idleSeconds = 0, lastActionAt = os.clock() }
		self.perPlayer[name] = entry
	end
	return entry
end

function LabTelemetry:log(kind: string, detail: string?)
	if not DevConfig.Telemetry then
		return
	end
	table.insert(self.events, {
		t = math.floor((os.clock() - self.runStart) * 100) / 100,
		kind = kind,
		detail = detail,
	})
end

function LabTelemetry:noteRole(name: string, role: string)
	self:_player(name).role = role
end

function LabTelemetry:noteInput(name: string)
	if not self.firstInputAt then
		self.firstInputAt = os.clock() - self.runStart
		self:log("first_input", name)
	end
	local entry = self:_player(name)
	entry.lastActionAt = os.clock()
end

function LabTelemetry:noteMovement()
	if not self.firstMovementAt then
		self.firstMovementAt = os.clock() - self.runStart
		self:log("first_movement")
	end
end

--[[
	A coarse trace of what the driver was doing and what the truck did about
	it. Not enough to reproduce a run -- Roblox's solver is not deterministic,
	so replaying these inputs gives a similar run, never the same one -- but
	enough to answer "was the driver hard on the brakes before that strap
	went?" after the fact.
]]
function LabTelemetry:noteDriveSample(
	throttle: number,
	steering: number,
	braking: boolean,
	speed: number,
	progress: number
)
	if not DevConfig.Telemetry or #self.inputSamples >= MAX_INPUT_SAMPLES then
		return
	end
	table.insert(self.inputSamples, {
		t = math.floor((os.clock() - self.runStart) * 10) / 10,
		th = math.floor(throttle * 100) / 100,
		st = math.floor(steering * 100) / 100,
		br = braking,
		sp = math.floor(speed),
		pr = math.floor(progress * 1000) / 1000,
	})
end

function LabTelemetry:noteAction(name: string, action: string)
	local entry = self:_player(name)
	entry.actions += 1
	local gap = os.clock() - entry.lastActionAt
	if gap > 3 then
		entry.idleSeconds += gap
	end
	entry.lastActionAt = os.clock()
	self:log("action", name .. ":" .. action)
end

function LabTelemetry:noteStationMove(name: string, target: string)
	self:_player(name).moves += 1
	self.stationMoves += 1
	self:noteAction(name, "move_" .. target)
end

function LabTelemetry:noteThrow(name: string)
	self.throws += 1
	self:log("thrown", name)
end

function LabTelemetry:noteCrewSwap(gateIndex: number, driverName: string)
	self.crewSwaps += 1
	self:log("crew_swap", string.format("gate_%d:%s", gateIndex, driverName))
end

local SEVERITY = {
	Secure = 0,
	Shifted = 1,
	Leaning = 2,
	Sliding = 3,
	PartiallyDetached = 4,
	Hanging = 5,
	Dragging = 6,
	Lost = 7,
}

function LabTelemetry:noteCondition(from: string?, to: string, cause: string)
	self.conditionChanges += 1
	self:log("cargo", string.format("%s -> %s (%s)", tostring(from), to, cause))

	if (SEVERITY[to] or 0) > (SEVERITY[self.worstCondition] or 0) then
		self.worstCondition = to
	end
	if (SEVERITY[to] or 0) >= 3 and not self.firstCrisisAt then
		self.firstCrisisAt = os.clock() - self.runStart
		self:log("first_crisis", to)
	end
	if from and (SEVERITY[to] or 0) < (SEVERITY[from] or 0) and (SEVERITY[from] or 0) >= 3 then
		self.recoveries += 1
		self:log("recovery", from .. " -> " .. to)
	end
end

function LabTelemetry:noteStrapBreak(id: string)
	self.strapBreaks += 1
	self:log("strap_break", id)
end

function LabTelemetry:noteStrapRefit(id: string)
	self.strapRefits += 1
	self:log("strap_refit", id)
end

function LabTelemetry:notePressure(label: string, progress: number)
	self.pressureEvents += 1
	self:log("pressure", string.format("%s @ %.2f", label, progress))
end

function LabTelemetry:noteDesignedCascade()
	if not self.designedCascade then
		self.designedCascade = true
		self:log("designed_cascade")
	end
end

function LabTelemetry:noteEmergentCascade(detail: string)
	if not self.emergentCascade then
		self.emergentCascade = true
		self:log("emergent_cascade", detail)
	end
end

--[[
	The run as data rather than as a wall of text.

	The printed summary is fine while you are sitting in front of the output
	window, and useless an hour later or on somebody else's machine. This
	writes each run to ServerStorage as JSON, where it survives the run ending,
	survives the output window being cleared, and can be copied out of the
	Explorer after the session to diff two tuning passes against each other.

	The tuning block is the important part: a run is close to meaningless
	unless you know which truck produced it.
]]
function LabTelemetry:_writeArtifact(outcome: string, crateSaved: boolean, summary)
	if not DevConfig.RunArtifacts then
		return
	end

	local crew = {}
	for _, entry in self.perPlayer do
		table.insert(crew, {
			name = entry.name,
			role = entry.role,
			actions = entry.actions,
			moves = entry.moves,
			idleSeconds = math.floor(entry.idleSeconds * 10) / 10,
		})
	end
	table.sort(crew, function(a, b)
		return a.name < b.name
	end)

	local artifact = {
		schema = ARTIFACT_SCHEMA,
		runIndex = self.runIndex,
		startedAt = self.startedAt,
		outcome = outcome,
		crateSaved = crateSaved,
		duration = summary.duration,
		metrics = {
			timeToInput = self.firstInputAt,
			timeToMovement = self.firstMovementAt,
			timeToCrisis = self.firstCrisisAt,
			worstCondition = self.worstCondition,
			conditionChanges = self.conditionChanges,
			recoveries = self.recoveries,
			strapBreaks = self.strapBreaks,
			strapRefits = self.strapRefits,
			stationMoves = self.stationMoves,
			throws = self.throws,
			crewSwaps = self.crewSwaps,
			pressureEvents = self.pressureEvents,
			designedCascade = self.designedCascade,
			emergentCascade = self.emergentCascade,
			finalProgress = summary.routeProgress,
			finalCargoReadout = summary.cargoReadout,
			finalChassisIntegrity = summary.chassisIntegrity,
			manualResets = summary.manualResets,
			simulationErrors = summary.simulationErrors,
			driveInputAgeSamples = summary.driveInputAgeSamples,
			driveInputAgeAverageMs = summary.driveInputAgeAverageMs,
			driveInputAgeMaxMs = summary.driveInputAgeMaxMs,
			driveInputAgeOver200Pct = summary.driveInputAgeOver200Pct,
			driveInputAgeOver400Pct = summary.driveInputAgeOver400Pct,
			variantKey = summary.variantKey,
			endCause = summary.endCause,
		},
		crew = crew,
		timeline = self.events,
		inputs = self.inputSamples,
		tuning = TuningService.changedValues(),
	}

	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(artifact)
	end)
	if not ok then
		warn("[CargoLab] could not encode run artifact: " .. tostring(encoded))
		return
	end

	local folder = ServerStorage:FindFirstChild(ARTIFACT_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = ARTIFACT_FOLDER
		folder.Parent = ServerStorage
	end

	local value = Instance.new("StringValue")
	value.Name = string.format("Run_%03d_%s", self.runIndex, outcome)
	value.Value = encoded
	value.Parent = folder

	print(
		string.format(
			"[CargoLab] run artifact written to ServerStorage.%s.%s (%d bytes)",
			ARTIFACT_FOLDER,
			value.Name,
			#encoded
		)
	)
end

function LabTelemetry:finish(outcome: string, crateSaved: boolean, finalState)
	if not DevConfig.Telemetry then
		return nil
	end

	local duration = os.clock() - self.runStart
	self:log("run_end", outcome)
	local ageSamples = self.driveInputAgeSamples
	local summary = {
		duration = math.floor(duration * 10) / 10,
		routeProgress = math.floor(math.clamp(finalState.routeProgress or 0, 0, 1) * 1000) / 1000,
		cargoReadout = math.floor(math.clamp(finalState.cargoReadout or 0, 0, 100)),
		chassisIntegrity = math.floor(math.clamp(finalState.chassisIntegrity or 0, 0, 100)),
		strapBreaks = self.strapBreaks,
		strapRefits = self.strapRefits,
		recoveries = self.recoveries,
		throws = self.throws,
		crewSwaps = self.crewSwaps,
		pressureEvents = self.pressureEvents,
		manualResets = self.manualResets,
		simulationErrors = self.simulationErrors,
		driveInputAgeSamples = ageSamples,
		driveInputAgeAverageMs = if ageSamples > 0 then math.floor(self.driveInputAgeTotal * 1000 / ageSamples) else 0,
		driveInputAgeMaxMs = math.floor(self.driveInputAgeMax * 1000),
		driveInputAgeOver200Pct = if ageSamples > 0
			then math.floor(self.driveInputAgeOver200 * 100 / ageSamples)
			else 0,
		driveInputAgeOver400Pct = if ageSamples > 0
			then math.floor(self.driveInputAgeOver400 * 100 / ageSamples)
			else 0,
		variantKey = finalState.variantKey or "unknown",
		endCause = finalState.endCause or "Unknown",
	}

	local lines = {
		"",
		"===== CARGO LAB RUN =====",
		string.format("outcome            %s (crate saved: %s)", outcome, tostring(crateSaved)),
		string.format("duration           %.1fs", duration),
		string.format(
			"time to input      %s",
			self.firstInputAt and string.format("%.1fs", self.firstInputAt) or "never"
		),
		string.format(
			"time to movement   %s",
			self.firstMovementAt and string.format("%.1fs", self.firstMovementAt) or "never"
		),
		string.format(
			"time to crisis     %s",
			self.firstCrisisAt and string.format("%.1fs", self.firstCrisisAt) or "never"
		),
		string.format("worst condition    %s", self.worstCondition),
		string.format("cargo transitions  %d (%d recoveries)", self.conditionChanges, self.recoveries),
		string.format("straps             %d broken, %d refitted", self.strapBreaks, self.strapRefits),
		string.format("station moves      %d (%d throws)", self.stationMoves, self.throws),
		string.format("crew swaps         %d", self.crewSwaps),
		string.format("pressure events    %d", self.pressureEvents),
		string.format("manual resets      %d", self.manualResets),
		string.format("simulation errors  %d", self.simulationErrors),
		string.format(
			"drive input age    %d samples, avg %dms, max %dms, >=200ms %d%%, >=400ms %d%%",
			summary.driveInputAgeSamples,
			summary.driveInputAgeAverageMs,
			summary.driveInputAgeMaxMs,
			summary.driveInputAgeOver200Pct,
			summary.driveInputAgeOver400Pct
		),
		string.format("designed cascade   %s", tostring(self.designedCascade)),
		string.format("emergent cascade   %s", tostring(self.emergentCascade)),
		"-- crew --",
	}

	for _, entry in self.perPlayer do
		table.insert(
			lines,
			string.format(
				"  %-16s %-9s actions %-4d moves %-3d idle %.0fs",
				entry.name,
				entry.role,
				entry.actions,
				entry.moves,
				entry.idleSeconds
			)
		)
	end

	table.insert(lines, "-- timeline --")
	for _, event in self.events do
		table.insert(lines, string.format("  %6.2f  %-18s %s", event.t, event.kind, event.detail or ""))
	end
	table.insert(lines, "=========================")

	print(table.concat(lines, "\n"))

	self:_writeArtifact(outcome, crateSaved, summary)
	return summary
end

return LabTelemetry
