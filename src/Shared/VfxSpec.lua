--!strict

--[[
	The visual half of the disaster.

	The build had thirty-six sounds for strap failures, scrapes, impacts and
	rollovers, and not one particle. That is a real problem rather than a polish
	item: PlaytestProtocol's clip test asks whether a stranger can follow a run
	with the sound off, and until now the answer was that the audio was carrying
	the entire read.

	Same discipline as the rest of the build. Nothing here fires because a timer
	said so; every continuous emitter is driven by a measured quantity — the
	surface a wheel is actually on, how far the crate has actually slid, how
	much integrity a hit actually took — and every burst is keyed to an event
	the server already reports.

	Deliberately free of NumberSequence, ColorSequence and Instance so the
	headless suite can load it. LabVfx turns these scalars into the sequences
	Roblox wants; the numbers worth arguing about live here.
]]

local VfxSpec = {}

export type Burst = {
	-- Particles per emission, before any tier scaling.
	count: number,
	lifetime: NumberRange,
	speed: NumberRange,
	spreadDegrees: number,
	sizeStart: number,
	sizeEnd: number,
	transparencyStart: number,
	color: Color3,
	-- Upward bias. Debris that only travels sideways reads as a glitch.
	acceleration: Vector3,
	drag: number,
	lightEmission: number,
}

export type Continuous = {
	-- Particles per second at full intensity. Intensity is always a measured
	-- ratio in the range 0 to 1, never a flag.
	rate: number,
	lifetime: NumberRange,
	speed: NumberRange,
	spreadDegrees: number,
	sizeStart: number,
	sizeEnd: number,
	transparencyStart: number,
	color: Color3,
	acceleration: Vector3,
	drag: number,
	lightEmission: number,
}

--[[
	A strap letting go is the single most important frame in the game: it is the
	moment PlaytestProtocol's clip is built around. Bright, fast, short-lived,
	and thrown along the rail rather than puffed upward, so it reads as
	something under tension releasing rather than an explosion.
]]
VfxSpec.StrapSnap = {
	count = 26,
	lifetime = NumberRange.new(0.35, 0.75),
	speed = NumberRange.new(16, 34),
	spreadDegrees = 55,
	sizeStart = 0.32,
	sizeEnd = 0.06,
	transparencyStart = 0.15,
	color = Color3.fromRGB(255, 214, 120),
	acceleration = Vector3.new(0, -48, 0),
	drag = 2.5,
	lightEmission = 0.65,
} :: Burst

-- Re-securing a strap is the recovery beat. Quieter and cooler than the break,
-- so a crew can tell the two apart at a glance from the driver's seat.
VfxSpec.StrapRefit = {
	count = 12,
	lifetime = NumberRange.new(0.25, 0.5),
	speed = NumberRange.new(6, 14),
	spreadDegrees = 40,
	sizeStart = 0.22,
	sizeEnd = 0.05,
	transparencyStart = 0.3,
	color = Color3.fromRGB(150, 220, 255),
	acceleration = Vector3.new(0, -30, 0),
	drag = 3,
	lightEmission = 0.4,
} :: Burst

--[[
	Impacts, by tier. The counts and speeds climb together so severity is
	readable from a still frame, matching what ImpactTiers told the audio.
]]
VfxSpec.CargoImpact = {
	Light = {
		count = 8,
		lifetime = NumberRange.new(0.25, 0.5),
		speed = NumberRange.new(5, 11),
		spreadDegrees = 70,
		sizeStart = 0.3,
		sizeEnd = 0.08,
		transparencyStart = 0.35,
		color = Color3.fromRGB(196, 170, 132),
		acceleration = Vector3.new(0, -36, 0),
		drag = 3,
		lightEmission = 0,
	} :: Burst,
	Medium = {
		count = 18,
		lifetime = NumberRange.new(0.3, 0.65),
		speed = NumberRange.new(9, 19),
		spreadDegrees = 80,
		sizeStart = 0.42,
		sizeEnd = 0.1,
		transparencyStart = 0.25,
		color = Color3.fromRGB(188, 158, 116),
		acceleration = Vector3.new(0, -40, 0),
		drag = 2.6,
		lightEmission = 0,
	} :: Burst,
	Heavy = {
		count = 34,
		lifetime = NumberRange.new(0.4, 0.9),
		speed = NumberRange.new(14, 30),
		spreadDegrees = 95,
		sizeStart = 0.55,
		sizeEnd = 0.12,
		transparencyStart = 0.15,
		color = Color3.fromRGB(176, 144, 100),
		acceleration = Vector3.new(0, -44, 0),
		drag = 2.2,
		lightEmission = 0,
	} :: Burst,
}

VfxSpec.TruckCollision = {
	Light = {
		count = 10,
		lifetime = NumberRange.new(0.2, 0.45),
		speed = NumberRange.new(7, 15),
		spreadDegrees = 65,
		sizeStart = 0.24,
		sizeEnd = 0.05,
		transparencyStart = 0.25,
		color = Color3.fromRGB(255, 198, 110),
		acceleration = Vector3.new(0, -52, 0),
		drag = 3,
		lightEmission = 0.7,
	} :: Burst,
	Medium = {
		count = 22,
		lifetime = NumberRange.new(0.25, 0.6),
		speed = NumberRange.new(12, 26),
		spreadDegrees = 80,
		sizeStart = 0.32,
		sizeEnd = 0.06,
		transparencyStart = 0.15,
		color = Color3.fromRGB(255, 186, 92),
		acceleration = Vector3.new(0, -54, 0),
		drag = 2.6,
		lightEmission = 0.8,
	} :: Burst,
	Heavy = {
		count = 42,
		lifetime = NumberRange.new(0.35, 0.85),
		speed = NumberRange.new(18, 38),
		spreadDegrees = 100,
		sizeStart = 0.44,
		sizeEnd = 0.08,
		transparencyStart = 0.1,
		color = Color3.fromRGB(255, 170, 78),
		acceleration = Vector3.new(0, -56, 0),
		drag = 2.2,
		lightEmission = 0.95,
	} :: Burst,
}

-- The truck going over. One large, slow, dirty burst rather than sparks: this
-- is mass hitting ground, not metal shearing.
VfxSpec.Rollover = {
	count = 60,
	lifetime = NumberRange.new(0.7, 1.6),
	speed = NumberRange.new(10, 26),
	spreadDegrees = 120,
	sizeStart = 1.4,
	sizeEnd = 3.2,
	transparencyStart = 0.35,
	color = Color3.fromRGB(158, 142, 118),
	acceleration = Vector3.new(0, -12, 0),
	drag = 4.5,
	lightEmission = 0,
} :: Burst

--[[
	Continuous emitters.

	Wheel spray is per-surface because the surface is already a measured
	property of each contact patch. Driving off the asphalt should look
	different before the handling tells you, which is the whole point of having
	shoulders that behave differently.
]]
VfxSpec.WheelSpray = {
	Road = {
		rate = 0,
		lifetime = NumberRange.new(0.2, 0.4),
		speed = NumberRange.new(1, 3),
		spreadDegrees = 25,
		sizeStart = 0.3,
		sizeEnd = 0.7,
		transparencyStart = 0.85,
		color = Color3.fromRGB(150, 150, 150),
		acceleration = Vector3.new(0, 2, 0),
		drag = 4,
		lightEmission = 0,
	} :: Continuous,
	Shoulder = {
		rate = 46,
		lifetime = NumberRange.new(0.4, 0.85),
		speed = NumberRange.new(3, 9),
		spreadDegrees = 42,
		sizeStart = 0.5,
		sizeEnd = 1.7,
		transparencyStart = 0.42,
		color = Color3.fromRGB(196, 176, 138),
		acceleration = Vector3.new(0, 3, 0),
		drag = 3.6,
		lightEmission = 0,
	} :: Continuous,
	Grass = {
		rate = 38,
		lifetime = NumberRange.new(0.35, 0.8),
		speed = NumberRange.new(3, 10),
		spreadDegrees = 45,
		sizeStart = 0.42,
		sizeEnd = 1.3,
		transparencyStart = 0.4,
		color = Color3.fromRGB(122, 152, 92),
		acceleration = Vector3.new(0, 2, 0),
		drag = 3.8,
		lightEmission = 0,
	} :: Continuous,
	Rough = {
		rate = 34,
		lifetime = NumberRange.new(0.3, 0.7),
		speed = NumberRange.new(2, 8),
		spreadDegrees = 38,
		sizeStart = 0.44,
		sizeEnd = 1.4,
		transparencyStart = 0.5,
		color = Color3.fromRGB(168, 160, 150),
		acceleration = Vector3.new(0, 2, 0),
		drag = 3.8,
		lightEmission = 0,
	} :: Continuous,
	--[[
		Ice throws almost nothing. That is the point: the surface that most
		deserves a warning is the one that looks calmest, and the spray staying
		quiet while the handling changes is the trap working as intended. The
		tyre note and the steering tell the story instead.
	]]
	Ice = {
		rate = 14,
		lifetime = NumberRange.new(0.25, 0.5),
		speed = NumberRange.new(1, 4),
		spreadDegrees = 22,
		sizeStart = 0.22,
		sizeEnd = 0.5,
		transparencyStart = 0.62,
		color = Color3.fromRGB(214, 232, 245),
		acceleration = Vector3.new(0, 2, 0),
		drag = 4,
		lightEmission = 0.35,
	} :: Continuous,
	Snow = {
		rate = 52,
		lifetime = NumberRange.new(0.45, 0.95),
		speed = NumberRange.new(4, 11),
		spreadDegrees = 46,
		sizeStart = 0.55,
		sizeEnd = 2,
		transparencyStart = 0.32,
		color = Color3.fromRGB(238, 244, 250),
		acceleration = Vector3.new(0, 3, 0),
		drag = 3.4,
		lightEmission = 0.2,
	} :: Continuous,
	Bridge = {
		rate = 12,
		lifetime = NumberRange.new(0.2, 0.45),
		speed = NumberRange.new(1, 4),
		spreadDegrees = 28,
		sizeStart = 0.28,
		sizeEnd = 0.8,
		transparencyStart = 0.7,
		color = Color3.fromRGB(170, 166, 158),
		acceleration = Vector3.new(0, 2, 0),
		drag = 4,
		lightEmission = 0,
	} :: Continuous,
}

-- Locked tyres. Pale, slow and persistent, so a long brake leaves a visible
-- trail behind the truck rather than a puff at the moment of pressing.
VfxSpec.TyreSmoke = {
	rate = 58,
	lifetime = NumberRange.new(0.6, 1.3),
	speed = NumberRange.new(1, 5),
	spreadDegrees = 30,
	sizeStart = 0.6,
	sizeEnd = 2.4,
	transparencyStart = 0.45,
	color = Color3.fromRGB(214, 214, 216),
	acceleration = Vector3.new(0, 4, 0),
	drag = 4.2,
	lightEmission = 0,
} :: Continuous

--[[
	The load grinding along the road. This is the state the HUD calls Sliding or
	Dragging, and it is currently invisible unless you are looking at the crate
	itself — which the driver, by definition, is not.
]]
VfxSpec.CargoScrape = {
	rate = 70,
	lifetime = NumberRange.new(0.3, 0.7),
	speed = NumberRange.new(6, 16),
	spreadDegrees = 50,
	sizeStart = 0.34,
	sizeEnd = 0.9,
	transparencyStart = 0.3,
	color = Color3.fromRGB(255, 190, 120),
	acceleration = Vector3.new(0, -18, 0),
	drag = 3,
	lightEmission = 0.5,
} :: Continuous

--[[
	Strap tension. Not debris — a faint shimmer along a rope that is close to
	going, so a Strapper has a reason to look at the load rather than the panel.
	Intensity is the measured tension, so it appears before the break.
]]
VfxSpec.StrapStress = {
	rate = 16,
	lifetime = NumberRange.new(0.15, 0.35),
	speed = NumberRange.new(0.5, 2.5),
	spreadDegrees = 20,
	sizeStart = 0.14,
	sizeEnd = 0.02,
	transparencyStart = 0.4,
	color = Color3.fromRGB(255, 158, 92),
	acceleration = Vector3.new(0, 1, 0),
	drag = 2,
	lightEmission = 0.8,
} :: Continuous

-- Tension below this fraction of a strap's failure threshold shows nothing.
-- A load under ordinary cornering load should not look like it is failing.
VfxSpec.StrapStressFloor = 0.55

-- Speed at which wheel spray reaches full rate, in studs per second.
VfxSpec.SpraySpeedReference = 42

function VfxSpec.wheelSpray(surface: string?): Continuous
	return VfxSpec.WheelSpray[surface or "Road"] or VfxSpec.WheelSpray.Road
end

function VfxSpec.cargoImpact(tier: string): Burst
	return VfxSpec.CargoImpact[tier] or VfxSpec.CargoImpact.Light
end

function VfxSpec.truckCollision(tier: string): Burst
	return VfxSpec.TruckCollision[tier] or VfxSpec.TruckCollision.Light
end

return VfxSpec
