--!strict

--[[
	Shared contracts. Everything the client renders comes from CrewSnapshot or
	DepotSnapshot; the server is the only writer of both.
]]

export type CrewPhase = "Idle" | "Staging" | "Departing" | "Run" | "DeliveryHold" | "BankOrPush" | "Resolve"

export type FailReason = "Banked" | "Delivered" | "CargoDumped" | "TruckTotaled" | "TimeExpired" | "CrewLeft"

export type RoleId = "Driver" | "Strapper" | "Spotter" | "Repair"

export type FailureId =
	"LooseStrap"
	| "SharpTurn"
	| "EngineFault"
	| "WheelWobble"
	| "CargoTilt"
	| "RampDrop"
	| "BlindCorner"
	| "Overheat"

export type FailureDef = {
	id: FailureId,
	label: string,
	description: string,
	responsibleRole: RoleId,
	interaction: "Brake" | "Hold" | "Ping",
	holdSeconds: number?,
	windowSeconds: number,
	cascadeSeverity: number,
	clipLine: string,
	damagesTruck: boolean?,
}

export type ActiveFailureSnapshot = {
	id: FailureId,
	label: string,
	description: string,
	responsibleRole: RoleId,
	interaction: "Brake" | "Hold" | "Ping",
	secondsRemaining: number,
}

export type CargoRarity = "Standard" | "Uncommon" | "Rare" | "Exotic" | "Prototype"

export type CargoQuirk = "None" | "Fragile" | "Volatile" | "Livestock" | "Jackpot"

export type CargoDef = {
	id: string,
	label: string,
	blurb: string,
	rarity: CargoRarity,
	weight: number,
	valueMultiplier: number,
	quirk: CargoQuirk,
	-- Quirk tuning. Absent means "no effect".
	safeSpeedDelta: number?,
	truckDamageScale: number?,
	panicChance: number?,
	minLeg: number?,
}

export type KitEffect = {
	windowBonusSeconds: number?,
	safeSpeedBonus: number?,
	integrityRestoreBonus: number?,
	stabilityRecoveryBonus: number?,
}

export type KitDef = {
	id: string,
	roleId: RoleId,
	label: string,
	blurb: string,
	cost: number,
	effect: KitEffect,
}

export type PaintDef = {
	id: string,
	label: string,
	cost: number,
	color: Color3,
}

export type ProfileData = {
	version: number,
	credits: number,
	lifetimeConvoys: number,
	lifetimeLegs: number,
	lifetimeBanked: number,
	bestLeg: number,
	bestBankedHaul: number,
	currentStreak: number,
	bestStreak: number,
	unlockedKits: { [string]: boolean },
	equippedKits: { [string]: string },
	unlockedPaints: { [string]: boolean },
	equippedPaint: string,
	manifestJournal: { [string]: number },
	lastDailyDay: number,
}

export type CrewSnapshot = {
	bayIndex: number,
	phase: CrewPhase,
	leg: number,
	timeRemaining: number,
	cargoStability: number,
	truckIntegrity: number,
	cargoState: "Stable" | "Tipping" | "Dumped",
	routeProgress: number,
	speed: number,
	objective: string,
	lastFailureLabel: string?,
	activeFailure: ActiveFailureSnapshot?,
	failReason: FailReason?,
	cascadeCount: number,
	timeSurvived: number,
	readyCount: number,
	readyRequired: number,
	countdownSeconds: number,
	readyPlayers: { [string]: boolean },
	roles: { [string]: RoleId },
	members: { string },
	cargo: CargoDef?,
	carriedValue: number,
	legValue: number,
	multiplier: number,
	decisionSeconds: number,
	pushVotes: number,
	bankVotes: number,
	myVote: string?,
	spectating: boolean,
	safeSpeed: number,
}

export type BayStatus = {
	index: number,
	phase: CrewPhase,
	leg: number,
	memberCount: number,
	capacity: number,
	members: { string },
	carriedValue: number,
	cargoLabel: string?,
	rarity: CargoRarity?,
}

export type LeaderRow = {
	name: string,
	value: number,
	detail: string,
}

export type DepotSnapshot = {
	bays: { BayStatus },
	myBay: number?,
	spectatingBay: number?,
	credits: number,
	streak: number,
	bestStreak: number,
	bestLeg: number,
	bestBankedHaul: number,
	lifetimeConvoys: number,
	unlockedKits: { [string]: boolean },
	equippedKits: { [string]: string },
	unlockedPaints: { [string]: boolean },
	equippedPaint: string,
	journalCount: number,
	journalTotal: number,
	topStreak: { LeaderRow },
	topHaul: { LeaderRow },
	eventLabel: string,
	eventBlurb: string,
	payoutMultiplier: number,
	dailyBonusReady: boolean,
	dailyBonusAmount: number,
}

return {}
