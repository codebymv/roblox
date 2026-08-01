--!strict

--[[
	Every tuning number for the fun-test build lives here so the whole feel of
	the truck can be moved without touching logic.

	Geometry convention: the chassis local forward is -Z (Roblox LookVector), so
	the cab sits at negative Z and the load bed at positive Z.
]]

local LabConfig = {
	-- ---------------------------------------------------------------- chassis
	ChassisSize = Vector3.new(9, 2.6, 16),
	-- Roblox mass = volume * density. 9*2.6*16 = 374 studs^3.
	ChassisDensity = 3.4,

	CabSize = Vector3.new(8.4, 5, 6),
	CabOffset = Vector3.new(0, 3.8, -5),
	CabDensity = 0.6,

	RailHeight = 1.4,

	-- Visual-only parts (massless, welded to chassis/cab).
	BedDeckSize = Vector3.new(8.2, 0.22, 10.2),
	BedDeckOffset = Vector3.new(0, 1.42, 2.4),
	WindshieldSize = Vector3.new(7.2, 2.1, 0.28),
	WindshieldOffset = Vector3.new(0, 0.55, -3.05),
	WindshieldRakeDeg = 14,
	HeadlightOffset = Vector3.new(2.75, -0.45, -3.15),
	TaillightOffset = Vector3.new(2.6, 0.35, 8.05),
	HubRadius = 0.62,
	BumperSize = Vector3.new(8.6, 0.75, 0.55),
	BumperOffset = Vector3.new(0, -0.15, -3.35),
	MirrorArmOffset = Vector3.new(4.2, 1.55, -1.6),
	StrapRatchetSize = Vector3.new(0.55, 0.42, 0.75),
	StrapRopeThickness = 0.34,

	-- --------------------------------------------------------------- wheels
	-- Local mount points. Front wheels are at negative Z.
	WheelOffsets = {
		FL = Vector3.new(-3.7, -0.6, -5.2),
		FR = Vector3.new(3.7, -0.6, -5.2),
		RL = Vector3.new(-3.7, -0.6, 5.2),
		RR = Vector3.new(3.7, -0.6, 5.2),
	},
	WheelRadius = 1.5,
	WheelWidth = 1.1,

	-- ----------------------------------------------------------- suspension
	-- Ray length from the mount. Ground contact anywhere shorter compresses.
	SuspensionRestLength = 3.1,
	-- Fraction of rest length compressed when the truck is parked and level.
	SuspensionStaticCompression = 0.34,
	-- 1.0 would be critically damped. This leaves readable body roll without
	-- letting a reset or road seam ring through several oscillations.
	SuspensionDampingRatio = 0.68,
	-- Hard cap so a single frame can never launch the truck.
	SuspensionMaxForceScale = 3.2,

	-- ---------------------------------------------------------------- engine
	-- Acceleration in studs/s^2 that the drive wheels try to deliver.
	EngineAccel = 34,
	ReverseAccel = 16,
	BrakeAccel = 46,
	-- Constant drag so releasing throttle actually slows you.
	CoastDecel = 5,
	MaxForwardSpeed = 64,
	MaxReverseSpeed = 22,
	-- Below this the drivetrain stops pushing back, or a parked truck jitters.
	SpeedDeadzone = 0.6,
	-- Gravity freely exceeds MaxForwardSpeed on grades because that cap only
	-- stops throttle. Soft-cap engine-brakes toward this ceiling so steering
	-- authority is not wiped out the moment a hill tips you over falloff.
	DownhillSoftCap = 54,
	DownhillBrakeAccel = 18,

	-- ----------------------------------------------------------------- grip
	-- Fraction of lateral slip velocity cancelled per second, per axle.
	-- Rear slightly lower than front so the back steps out before the front
	-- washes wide, which is the readable, recoverable failure mode.
	GripFront = 15.5,
	GripRear = 12.5,
	-- Above this lateral force per wheel the tyre breaks traction.
	GripLimitPerWheel = 2.1,

	MaxSteerAngleDeg = 28,
	-- Steering authority falls off with speed or the truck flips on a tap.
	SteerSpeedFalloff = 52,
	MinSteerFactor = 0.34,
	SteerRateDegPerSec = 105,

	-- Kills the slow spin a raycast vehicle accumulates with no real tyres.
	YawDamping = 1.4,
	MaxAngularSpeed = 3.2,

	-- ------------------------------------------------------------ surfaces
	-- gripScale, rollingResistance (studs/s^2)
	Surfaces = {
		Road = { grip = 1, resistance = 0 },
		Rough = { grip = 0.82, resistance = 3.5 },
		Shoulder = { grip = 0.5, resistance = 11 },
		Bridge = { grip = 1, resistance = 0 },
	},

	-- ----------------------------------------------------------------- cargo
	CrateSize = Vector3.new(5.5, 5.5, 5.5),
	-- Heavy enough that where it sits genuinely changes how the truck handles.
	CrateDensity = 2.6,
	-- Crate centre in chassis local space when seated on the bed.
	CrateHome = Vector3.new(0, 4.05, 3),

	-- Strap anchors. Rail end is on the chassis, crate end on the load's top
	-- corners, so a strap resists both sliding and tipping.
	StrapOrder = { "FL", "FR", "RL", "RR" },
	StrapRailLocal = {
		FL = Vector3.new(-4.35, 1.4, 0.25),
		FR = Vector3.new(4.35, 1.4, 0.25),
		RL = Vector3.new(-4.35, 1.4, 5.75),
		RR = Vector3.new(4.35, 1.4, 5.75),
	},
	StrapCrateLocal = {
		FL = Vector3.new(-2.75, 2.75, -2.75),
		FR = Vector3.new(2.75, 2.75, -2.75),
		RL = Vector3.new(-2.75, 2.75, 2.75),
		RR = Vector3.new(2.75, 2.75, 2.75),
	},

	StrapMaxHealth = 100,
	-- Load above this (in crate-weights) starts chewing through a strap.
	StrapTensionThreshold = 0.55,
	-- Health lost per second per unit of tension over the threshold.
	StrapWearRate = 46,
	-- Straps recover slowly when nothing is pulling on them.
	StrapRecoverRate = 1.6,
	-- Slack added to a rope each time it takes a shock, which is what lets a
	-- load creep out of position over a run instead of failing all at once.
	StrapStretchPerShock = 0.11,
	StrapMaxStretch = 2.6,

	-- Strapper work rates.
	StrapTightenPerSecond = 42,
	StrapReattachSeconds = 1.9,
	-- A broken strap can only be refitted if its two ends are close enough.
	StrapReattachMaxGap = 8.5,

	-- ------------------------------------------------------- cargo readout
	-- Thresholds on measured crate displacement, in studs from home.
	ShiftedOffset = 0.75,
	SlidingOffset = 1.9,
	-- Crate roll relative to the bed, in degrees.
	LeaningAngleDeg = 11,
	HangingAngleDeg = 26,
	-- Beyond this the load is off the deck and only the straps hold it.
	HangingOffset = 3.4,
	LostOffset = 9,
	DragForcePerStud = 320,

	-- --------------------------------------------------------------- crew
	MaxCrew = 4,
	StationOrder = { "FL", "FR", "RL", "RR" },
	-- Where a strapper stands to work each strap, in chassis local space.
	StationLocal = {
		FL = CFrame.new(-5.9, 1.9, 0.25) * CFrame.Angles(0, math.rad(90), 0),
		FR = CFrame.new(5.9, 1.9, 0.25) * CFrame.Angles(0, math.rad(-90), 0),
		RL = CFrame.new(-5.9, 1.9, 5.75) * CFrame.Angles(0, math.rad(90), 0),
		RR = CFrame.new(5.9, 1.9, 5.75) * CFrame.Angles(0, math.rad(-90), 0),
	},
	StationSeatSize = Vector3.new(2.5, 0.85, 2.5),
	--[[
		A character's own mass is negligible next to a truck, so the station
		platform carries the crew member's braced weight instead. This is what
		makes "get to the high side" a real instruction: moving a station moves
		real mass within the assembly and genuinely changes the roll balance.
	]]
	StationSeatDensity = 60,
	DriverSeatOffset = CFrame.new(-1.6, 2.2, -5.4),

	TraversalSecondsPerStud = 0.085,
	TraversalMinSeconds = 0.45,
	--[[
		Lateral acceleration that throws a crew member off mid-traversal. Read
		against the smoothed chassis acceleration, so this is a sustained hard
		corner rather than a single-frame contact spike. Primary tuning knob for
		how dangerous crossing the bed feels.
	]]
	ThrowLateralAccel = 52,
	ThrowRecoverySeconds = 4,

	-- ---------------------------------------------------------- SWAP gates
	-- Fixed route fractions keep the handoffs learnable. A gate is ignored for
	-- solo play; with 2-4 crew it rotates everyone through the occupied slots.
	SwapGateProgress = { 0.3, 0.77 },
	-- Start the personalized warning this far before the physical red signs.
	SwapWarningProgress = 0.05,
	-- Server-applied brake and throw immunity while seats and controls rotate.
	SwapHandoffSeconds = 1.25,

	-- ------------------------------------------------------------ pressure
	-- The director perturbs state. It never assigns damage to a meter.
	PressureFirstEventSeconds = 26,
	PressureIntervalSeconds = NumberRange.new(17, 30),
	StrapWeakenAmount = NumberRange.new(24, 44),
	SuspensionDamageAmount = NumberRange.new(0.3, 0.55),
	SteeringDegradeAmount = NumberRange.new(0.2, 0.4),
	GustAccel = NumberRange.new(14, 26),
	GustSeconds = NumberRange.new(1.4, 2.6),

	-- The scripted opener: one strap starts compromised so the first corner
	-- has something to find.
	OpeningWeakStrap = "FR",
	OpeningWeakHealth = 38,

	-- ------------------------------------------------------------- session
	-- Route is roughly two to three minutes of clean driving. The clock is
	-- tight enough that a crew which parks to refit every strap will feel it,
	-- but not so tight that a careful first run is doomed.
	RunTimeLimitSeconds = 210,
	-- Prep beat: long enough to switch roles, park at a station, and read the
	-- opener toast before the truck rolls.
	RestartDelaySeconds = 8,
	ResultDisplaySeconds = 6,
	-- First-time feedback needs a longer result beat than ordinary restarts.
	FeedbackResultDisplaySeconds = 11,
	-- Below this the truck is written off.
	MinChassisIntegrity = 0,
	MaxChassisIntegrity = 100,
	ImpactDamageScale = 1.2,
	-- Per-frame spike above the drivetrain budget before a hit registers.
	ImpactThreshold = 85,
	-- One lip-bump should not write off the truck in a single frame.
	ImpactDamageCap = 22,
	-- Bridge deck sits at Y = -136. Leave enough air under it that driving off
	-- is a fall you watch, not an instant wreck.
	VoidY = -200,
}

function LabConfig.surface(name: string?)
	if name and LabConfig.Surfaces[name] then
		return LabConfig.Surfaces[name]
	end
	return LabConfig.Surfaces.Road
end

return LabConfig
