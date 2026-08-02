--!strict

--[[
	The mix, as numbers.

	Every level in the game lives here rather than next to the code that plays
	the sound, because a mix is only judgeable as a whole: a strap snap is not
	"loud enough" in isolation, it is loud enough relative to the engine loop
	and the music underneath it at the moment it fires.

	Three buses, and the split is the point. The bed is continuous and carries
	almost no information; events are transient and carry all of it. Keeping
	them on one bus is what made the snap quieter than the tyres, because there
	was no way to lower one without lowering the other.

	Two things close the rest of the gap, and they answer different questions. A
	sidechain compressor on the music and the bed, keyed to the event bus, reacts
	to how loud an event actually is. A manual duck reacts to how much an event
	is meant to matter, which is design intent the compressor cannot infer.

	Either way the principle is the same: rather than raising events until they
	clip, the layers underneath give way. Music gives up the most, because it is
	the layer with the least to say during a crisis.

	Engine-free on purpose, so Tests/Headless.luau can assert that the bed never
	sums above the event bus.
]]

local AudioMix = {}

-- Final gain is bus volume times sound volume, so these two tables multiply.
AudioMix.Bus = {
	Music = 0.62,
	SfxBed = 0.85,
	SfxEvents = 1,
}

--[[
	Music by phase. Run is the cut that matters: it used to sit at 0.42 against
	a bed of roughly the same size, which is why nothing on top of it read.
	Staging keeps its level, because there is nothing there for it to bury.
]]
AudioMix.MusicPhaseVolume = {
	Staging = 0.4,
	Run = 0.32,
	Result = 0.2,
}

--[[
	Loops. Split by what the sound is for, not by how loud it happened to be.

	Environmental (tyres, rumble, rattle, ambience) came down: it is texture,
	and texture is exactly what masks a transient. Informational (scrape,
	ratchet, tension, skid) went up, because each one is the only non-visual
	signal that a specific thing is going wrong.
]]
AudioMix.LoopVolume = {
	EngineIdleLoop = 0.2,
	EngineDriveLoop = 0.36,
	TireAsphaltLoop = 0.22,
	TireOffroadLoop = 0.3,
	TireSkidLoop = 0.34,
	CargoScrapeLoop = 0.38,
	StrapRatchetLoop = 0.4,
	StrapTensionLoop = 0.24,
	BridgeRumbleLoop = 0.26,
	RoughRoadRattleLoop = 0.26,
	WarehouseAmbienceLoop = 0.18,
}

--[[
	One-shots. The three-tier impact and collision sets were previously played
	at one volume each, so a heavy hit sounded exactly like a light one and the
	tiers existed only in the code. Severity now has to be audible, since it is
	the thing the player is being told.
]]
AudioMix.EventVolume = {
	StrapSnap1 = 0.95,
	StrapSnap2 = 0.95,
	StrapRefit1 = 0.78,
	StrapRefit2 = 0.78,

	CargoImpactLight = 0.55,
	CargoImpactMedium = 0.7,
	CargoImpactHeavy = 0.88,

	TruckCollisionLight = 0.55,
	TruckCollisionMedium = 0.72,
	TruckCollisionHeavy = 0.9,

	PlayerThrown = 0.85,
	PlayerReseat = 0.6,

	SwapWarning = 0.7,
	SwapActivate = 0.8,

	RunGo = 0.75,
	CountdownTick = 0.6,
	DeliverySuccess = 0.85,
	DeliveryPartial = 0.85,
	DeliveryFailure = 0.85,
	CargoCashReward = 0.65,

	RoleDriver = 0.6,
	RoleStrapper = 0.6,

	BrakeHiss = 0.5,
	SuspensionHit1 = 0.5,
	SuspensionHit2 = 0.5,
}

AudioMix.DefaultEventVolume = 0.6

--[[
	How hard each event ducks, 0 to 1. Zero means the sound is not important
	enough to move the mix, which is most of them: ducking on every tick would
	turn the whole mix into a pump and stop signalling anything at all.
]]
AudioMix.DuckWeight = {
	StrapSnap1 = 1,
	StrapSnap2 = 1,
	StrapRefit1 = 0.5,
	StrapRefit2 = 0.5,

	CargoImpactMedium = 0.55,
	CargoImpactHeavy = 0.85,
	TruckCollisionMedium = 0.7,
	TruckCollisionHeavy = 1,

	PlayerThrown = 0.8,

	SwapWarning = 0.45,
	SwapActivate = 0.6,
	RunGo = 0.7,
	DeliverySuccess = 1,
	DeliveryPartial = 1,
	DeliveryFailure = 1,
}

--[[
	Manual duck depth, now that a real sidechain compressor sits underneath.

	The compressor reacts to how loud an event actually is; this reacts to how
	much an event is meant to matter, which is information the compressor cannot
	have. A strap snapping and a countdown tick can hit the same peak level and
	deserve completely different amounts of room.

	Both cut, so both came down when the compressor went in. Leaving them at the
	old depths stacked two ducks on the same transient and pumped.
]]
AudioMix.DuckDepth = {
	Music = 0.45,
	SfxBed = 0.25,
	SfxEvents = 0,
}

--[[
	Sidechain compression, done by the engine rather than by an envelope.

	CompressorSoundEffect takes a SoundGroup as its SideChain, so the music and
	the bed can be compressed by the level of the event bus directly: continuous,
	sample-accurate, and proportional to the actual signal instead of to a
	per-event weight sampled at Heartbeat.

	Attack is fast enough to catch a transient's leading edge; release is several
	times longer, because a release shorter than the attack is audible as
	pumping rather than as space. Music takes the harder ratio and the lower
	threshold: it is the layer with the least to say during a crisis.
]]
AudioMix.SideChainBus = "SfxEvents"

AudioMix.Compressor = {
	Music = {
		thresholdDb = -24,
		ratio = 6,
		attackSeconds = 0.02,
		releaseSeconds = 0.3,
		gainMakeupDb = 0,
	},
	SfxBed = {
		thresholdDb = -18,
		ratio = 3.5,
		attackSeconds = 0.03,
		releaseSeconds = 0.22,
		gainMakeupDb = 0,
	},
}

-- Fast in, hold through the transient, slow out. A quick release is audible as
-- the music swelling back, which draws attention to the mix instead of the hit.
AudioMix.DuckAttackSpeed = 30
AudioMix.DuckHoldSeconds = 0.18
AudioMix.DuckReleaseSpeed = 2.8

-- Events keep full level across the length of the truck and only fall off for
-- someone who has already been thrown clear of it. At the bed's 14 studs a
-- strap snapping at the far corner was arriving attenuated.
AudioMix.BedRollOffMin = 14
AudioMix.EventRollOffMin = 30
AudioMix.RollOffMax = 150

function AudioMix.eventVolume(key: string): number
	return AudioMix.EventVolume[key] or AudioMix.DefaultEventVolume
end

function AudioMix.duckWeight(key: string): number
	return AudioMix.DuckWeight[key] or 0
end

function AudioMix.musicPhaseVolume(phase: string): number
	return AudioMix.MusicPhaseVolume[phase] or AudioMix.MusicPhaseVolume.Staging
end

--[[
	A bus's volume at the current duck amount. Pure, so the headless suite can
	assert the relationship between the buses without a DataModel.
]]
function AudioMix.busVolume(name: string, duck: number): number
	local base = AudioMix.Bus[name] or 1
	local depth = AudioMix.DuckDepth[name] or 0
	return base * (1 - depth * math.clamp(duck, 0, 1))
end

return AudioMix
