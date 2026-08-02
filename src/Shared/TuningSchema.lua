--!nonstrict

--[[
	Which LabConfig values can be moved while the game is running, and which
	cannot.

	The split is not a matter of taste. Most of LabConfig is read at the point
	of use every frame -- PhysicsChassis:step reads LabConfig.GripFront inside
	the wheel loop rather than hoisting it into a local -- so writing a new
	value into the table is picked up on the very next frame with no rebuild.

	A minority of values are read exactly once, while the rig is being built:
	part sizes, densities, and mount offsets. Changing those does nothing until
	the truck is constructed again, so they are marked runtime = false and the
	rebuild command has to be used.

	Anything not listed here is not exposed. That is deliberate: the list is
	the set of knobs worth turning during a tuning session, not every constant
	in the file.

	This module deliberately does not require LabConfig. get and set take the
	config table as an argument instead, which keeps the file free of any engine
	or DataModel dependency and lets the headless suite check that every path
	here still resolves against the real config.
]]

export type Kind = "number" | "range" | "vector3"

export type Entry = {
	path: string,
	attribute: string,
	kind: Kind,
	group: string,
	runtime: boolean,
	min: number?,
	max: number?,
}

local TuningSchema = {}

local entries: { Entry } = {}

local function add(group: string, runtime: boolean, kind: Kind, path: string, min: number?, max: number?)
	table.insert(entries, {
		path = path,
		-- Attribute names allow alphanumerics and underscores only, so a
		-- nested path such as Surfaces.Rough.grip becomes Surfaces_Rough_grip.
		attribute = (path:gsub("%.", "_")),
		kind = kind,
		group = group,
		runtime = runtime,
		min = min,
		max = max,
	})
end

local function num(group: string, path: string, min: number, max: number)
	add(group, true, "number", path, min, max)
end

local function range(group: string, path: string)
	add(group, true, "range", path)
end

local function rebuilt(kind: Kind, path: string)
	add("Rebuild", false, kind, path)
end

-- ---------------------------------------------------------------- runtime

num("Engine", "EngineAccel", 0, 160)
num("Engine", "ReverseAccel", 0, 80)
num("Engine", "BrakeAccel", 0, 200)
num("Engine", "CoastDecel", 0, 40)
num("Engine", "MaxForwardSpeed", 10, 200)
num("Engine", "MaxReverseSpeed", 5, 80)
num("Engine", "SpeedDeadzone", 0, 5)
num("Engine", "DownhillSoftCap", 20, 120)
num("Engine", "DownhillBrakeAccel", 0, 80)

num("Grip", "GripFront", 0, 60)
num("Grip", "GripRear", 0, 60)
num("Grip", "GripLimitPerWheel", 0.1, 8)

num("Steering", "MaxSteerAngleDeg", 5, 60)
num("Steering", "SteerSpeedFalloff", 5, 200)
num("Steering", "MinSteerFactor", 0.05, 1)
num("Steering", "SteerRateDegPerSec", 20, 600)
num("Steering", "YawDamping", 0, 10)
num("Steering", "MaxAngularSpeed", 0.5, 12)

num("Camera", "CameraFollowRate", 1, 60)
num("Camera", "CameraVerticalFollowRate", 0.5, 40)
num("Camera", "CameraHeadingFollowRate", 1, 60)
num("Camera", "CameraLeadSeconds", 0, 0.3)
num("Camera", "CameraMotionStaleSeconds", 0.1, 2)
num("Camera", "CameraMotionCorrectionRate", 1, 60)
num("Camera", "CameraSnapDistance", 10, 300)
num("Camera", "CameraShakeSpeedStart", 0, 100)
num("Camera", "CameraShakeSpeedFull", 1, 200)
num("Camera", "CameraShakeRoad", 0, 2)
num("Camera", "CameraShakeRough", 0, 3)
num("Camera", "CameraShakeShoulder", 0, 3)
num("Camera", "CameraShakeBridge", 0, 3)
num("Camera", "CameraShakeSuspensionFull", 0.1, 20)
num("Camera", "CameraShakeGradeFullDeg", 1, 45)
num("Camera", "CameraShakeGradeInfluence", 0, 2)
num("Camera", "CameraShakeMaxTranslation", 0, 2)
num("Camera", "CameraShakeMaxRotationDeg", 0, 8)
num("Camera", "CameraShakeFrequency", 0.5, 30)
num("Camera", "CameraShakeAttackRate", 0.5, 40)
num("Camera", "CameraShakeReleaseRate", 0.5, 40)
num("Camera", "CameraImpactAccelStart", 0, 300)
num("Camera", "CameraImpactAccelFull", 1, 500)
num("Camera", "CameraImpactTranslation", 0, 3)
num("Camera", "CameraImpactRotationDeg", 0, 12)
num("Camera", "CameraImpactDecay", 0.5, 30)
num("Camera", "CameraImpactMinRise", 0, 200)
num("Camera", "CameraImpactRetriggerSeconds", 0, 2)

num("Suspension", "SuspensionRestLength", 0.5, 10)
num("Suspension", "SuspensionStaticCompression", 0.05, 0.9)
num("Suspension", "SuspensionDampingRatio", 0.05, 2)
num("Suspension", "SuspensionMaxForceScale", 1, 10)

num("Surfaces", "Surfaces.Rough.grip", 0.1, 1)
num("Surfaces", "Surfaces.Rough.resistance", 0, 40)
num("Surfaces", "Surfaces.Shoulder.grip", 0.05, 1)
num("Surfaces", "Surfaces.Shoulder.resistance", 0, 60)
num("Surfaces", "Surfaces.Bridge.grip", 0.1, 1)
num("Surfaces", "Surfaces.Bridge.resistance", 0, 40)

num("Straps", "StrapMaxHealth", 10, 400)
num("Straps", "StrapTensionThreshold", 0.05, 3)
num("Straps", "StrapWearRate", 0, 300)
num("Straps", "StrapRecoverRate", 0, 40)
num("Straps", "StrapStretchPerShock", 0, 1)
num("Straps", "StrapMaxStretch", 0, 10)
num("Straps", "StrapTightenPerSecond", 0, 200)
num("Straps", "StrapReattachSeconds", 0.2, 10)
num("Straps", "StrapReattachMaxGap", 1, 30)

num("Cargo", "ShiftedOffset", 0.05, 6)
num("Cargo", "SlidingOffset", 0.1, 10)
num("Cargo", "LeaningAngleDeg", 1, 60)
num("Cargo", "HangingAngleDeg", 2, 89)
num("Cargo", "HangingOffset", 0.5, 14)
num("Cargo", "LostOffset", 1, 30)
num("Cargo", "DragForcePerStud", 0, 2000)

num("Crew", "TraversalSecondsPerStud", 0.01, 0.6)
num("Crew", "TraversalMinSeconds", 0.05, 4)
num("Crew", "ThrowLateralAccel", 5, 200)
num("Crew", "ThrowRecoverySeconds", 0.5, 15)
num("Crew", "SwapWarningProgress", 0.005, 0.15)
num("Crew", "SwapHandoffSeconds", 0.25, 4)

num("Pressure", "PressureFirstEventSeconds", 2, 120)
range("Pressure", "PressureIntervalSeconds")
range("Pressure", "StrapWeakenAmount")
range("Pressure", "SuspensionDamageAmount")
range("Pressure", "SteeringDegradeAmount")
range("Pressure", "GustAccel")
range("Pressure", "GustSeconds")
num("Pressure", "OpeningWeakHealth", 0, 100)

num("Session", "RunTimeLimitSeconds", 30, 900)
num("Session", "RestartDelaySeconds", 0.5, 20)
num("Session", "ResultDisplaySeconds", 1, 30)
num("Session", "ImpactDamageScale", 0, 10)
num("Session", "MaxChassisIntegrity", 10, 500)
num("Session", "VoidY", -2000, 0)

-- ------------------------------------------------- read once, at build time

rebuilt("vector3", "ChassisSize")
rebuilt("number", "ChassisDensity")
rebuilt("vector3", "CabSize")
rebuilt("vector3", "CabOffset")
rebuilt("number", "CabDensity")
rebuilt("number", "WheelRadius")
rebuilt("number", "WheelWidth")
rebuilt("vector3", "WheelOffsets.FL")
rebuilt("vector3", "WheelOffsets.FR")
rebuilt("vector3", "WheelOffsets.RL")
rebuilt("vector3", "WheelOffsets.RR")
rebuilt("vector3", "CrateSize")
rebuilt("number", "CrateDensity")
rebuilt("vector3", "CrateHome")
rebuilt("number", "StationSeatDensity")

TuningSchema.Entries = entries

function TuningSchema.byAttribute(attribute: string): Entry?
	for _, entry in entries do
		if entry.attribute == attribute then
			return entry
		end
	end
	return nil
end

--[[
	Walks a dotted path down a config table and returns the owning table plus
	the final key, so callers can read and write the same location.
]]
local function resolve(config: any, path: string): (any?, string?)
	local parts = path:split(".")
	local node: any = config
	for index = 1, #parts - 1 do
		node = node[parts[index]]
		if type(node) ~= "table" then
			return nil, nil
		end
	end
	return node, parts[#parts]
end

function TuningSchema.get(config: any, path: string): any
	local owner, key = resolve(config, path)
	if not owner or not key then
		return nil
	end
	return owner[key]
end

function TuningSchema.set(config: any, path: string, value: any): boolean
	local owner, key = resolve(config, path)
	if not owner or not key then
		return false
	end
	owner[key] = value
	return true
end

return TuningSchema
