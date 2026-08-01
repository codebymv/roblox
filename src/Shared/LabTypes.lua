--!strict

--[[
	Wire contracts for the fun-test build. Deliberately separate from Types.lua
	so the lab can change shape fast without destabilising the depot build.
]]

export type LabPhase = "Staging" | "Run" | "Result"

export type LabRole = "Driver" | "Strapper"

export type StrapId = "FL" | "FR" | "RL" | "RR"

--[[
	Cargo condition is a readout, never an input. Every value below is computed
	from measured crate displacement, lean, strap state and ground contact.
]]
export type CargoCondition =
	"Secure"
	| "Shifted"
	| "Leaning"
	| "Sliding"
	| "PartiallyDetached"
	| "Hanging"
	| "Dragging"
	| "Lost"

export type Outcome = "Delivered" | "PartialLoss" | "CargoLost" | "TruckWrecked" | "TimeExpired"

-- Compact, release-safe diagnostics. Unlike the Studio artifact this contains
-- no player names, raw timeline, or high-frequency input stream.
export type RunSummary = {
	duration: number,
	routeProgress: number,
	cargoReadout: number,
	chassisIntegrity: number,
	strapBreaks: number,
	strapRefits: number,
	recoveries: number,
	throws: number,
	crewSwaps: number,
	pressureEvents: number,
	manualResets: number,
	simulationErrors: number,
	driveInputAgeSamples: number,
	driveInputAgeAverageMs: number,
	driveInputAgeMaxMs: number,
	driveInputAgeOver200Pct: number,
	driveInputAgeOver400Pct: number,
	variantKey: string,
	endCause: string,
}

-- Direction of travel on the condition ladder, not a second meter.
export type ConditionTrend = "Worsening" | "Recovering" | "Stable"

-- One side of the contract board. Purely descriptive: the client renders it
-- and sends back a choice, and never computes anything from it.
export type ContractCard = {
	cargoLabel: string,
	cargoDescription: string,
	contractLabel: string,
	contractBrief: string,
	difficultyLabel: string,
	-- What this card pays if its contract is met, relative to a plain delivery.
	rewardMultiplier: number,
	votes: number,
}

export type ContractOfferView = {
	runNumber: number,
	safe: ContractCard,
	risky: ContractCard,
	-- Where the tally currently stands. A crew that never votes gets the safe
	-- card, so this is never nil while the board is up.
	leading: string,
	secondsRemaining: number,
}

export type StrapSnapshot = {
	id: StrapId,
	health: number,
	tension: number,
	broken: boolean,
	stretch: number,
	-- Set when a broken strap's two ends are close enough to refit.
	reattachable: boolean,
	-- Name of the crew member working this strap right now, if any.
	workedBy: string?,
}

export type CrewSnapshot = {
	name: string,
	role: LabRole,
	station: StrapId?,
	movingTo: StrapId?,
	thrown: boolean,
}

export type LabSnapshot = {
	phase: LabPhase,
	timeRemaining: number,
	routeProgress: number,
	speed: number,
	roadSurface: string,
	braking: boolean,

	-- Cargo condition, derived.
	condition: CargoCondition,
	conditionTrend: ConditionTrend,
	-- A 0-100 readout of that condition for the HUD. Nothing writes to it
	-- directly; it is computed from the physical state every frame.
	cargoReadout: number,
	cargoOffset: number,
	cargoLeanDeg: number,

	chassisIntegrity: number,
	straps: { StrapSnapshot },
	crew: { CrewSnapshot },
	crewCount: number,
	crewCapacity: number,

	myRole: LabRole?,
	-- A server-enforced overflow state. Published servers are capped to the
	-- same crew size, but this also makes oversized Studio tests fail clearly.
	spectating: boolean,
	queuePosition: number?,
	myStation: StrapId?,
	myMovingTo: StrapId?,
	myThrown: boolean,
	-- True when this player has a seat but is not Occupant (slipped weld,
	-- respawned on LabSpawn, etc). Distinct from myThrown: a throw is the
	-- intentional recovery beat; this is the "you are stranded" signal.
	myOffTruck: boolean,
	-- True when this player is the only one in the session, so a Driver can
	-- work straps without abandoning the wheel.
	solo: boolean,

	-- Personalized SWAP gate presentation. The server computes the next role
	-- from the same deterministic plan it will apply at the physical sign.
	swapWarning: boolean,
	swapActive: boolean,
	swapNextRole: LabRole?,
	swapNextStation: StrapId?,

	-- The card this delivery is running under.
	cargoLabel: string,
	cargoDescription: string,
	contractLabel: string,
	contractBrief: string,
	difficultyLabel: string,
	contractComplete: boolean?,
	rewardMultiplier: number,

	--[[
		The contract board, offered on the result screen once a run has been
		completed. The server keeps the authoritative RunVariant for each side;
		only what the client has to draw crosses the wire.

		Absent whenever there is nothing to decide: during a run, and before the
		fixed onboarding run has been played.
	]]
	offer: ContractOfferView?,

	objective: string,
	outcome: Outcome?,
	outcomeCause: string?,
	crateSaved: boolean?,
	restartSeconds: number,
	-- Heartbeat step latched after an error. Anyone may press R to clear it.
	simHalted: boolean,
	-- Personalized, structured public-playtest feedback. Asked once per player
	-- session after they finish a run; no free text is collected.
	feedbackRequested: boolean,
	feedbackSubmitted: boolean,
	-- This player's own contract vote, alongside the other personal fields
	-- rather than inside `offer`, which is one table shared by every client.
	myContractVote: string?,

	-- Persistent public-build progression. Paint definitions themselves are
	-- static in RoleKits; only ownership and the equipped choice cross the wire.
	progressionReady: boolean,
	progressionSaving: boolean,
	credits: number,
	rewardEarned: number,
	equippedPaint: string,
	unlockedPaints: { [string]: boolean },
}

export type DebugSnapshot = {
	loadLocalX: number,
	loadLocalY: number,
	loadLocalZ: number,
	lateralAccel: number,
	longitudinalAccel: number,
	turnSeverity: number,
	brakeForce: number,
	rollDeg: number,
	pitchDeg: number,
	wheelCompression: { number },
	wheelGrounded: { boolean },
	wheelSurface: { string },
	suspensionHealth: { number },
	steeringHealth: number,
	strapTension: { number },
	strapHealth: { number },
	activePressure: string,
	lastCause: string,
}

return {}
