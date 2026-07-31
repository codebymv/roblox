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

	-- Cargo condition, derived.
	condition: CargoCondition,
	-- A 0-100 readout of that condition for the HUD. Nothing writes to it
	-- directly; it is computed from the physical state every frame.
	cargoReadout: number,
	cargoOffset: number,
	cargoLeanDeg: number,

	chassisIntegrity: number,
	straps: { StrapSnapshot },
	crew: { CrewSnapshot },

	myRole: LabRole?,
	myStation: StrapId?,
	myMovingTo: StrapId?,
	myThrown: boolean,

	objective: string,
	hint: string,
	outcome: Outcome?,
	crateSaved: boolean?,
	restartSeconds: number,
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
