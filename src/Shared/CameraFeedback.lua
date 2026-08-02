--!strict

-- Engine-free camera feedback maths. The client owns temporal state and noise;
-- this module turns measured gameplay signals into bounded 0..1 envelopes.

local CameraFeedback = {}

local function clamp01(value: number): number
	return math.clamp(value, 0, 1)
end

function CameraFeedback.smoothstep(value: number, from: number, to: number): number
	if to <= from then
		return if value >= to then 1 else 0
	end
	local t = clamp01((value - from) / (to - from))
	return t * t * (3 - 2 * t)
end

function CameraFeedback.surfaceAmount(surface: string, config: any): number
	if surface == "Rough" then
		return math.max(0, config.CameraShakeRough)
	elseif surface == "Shoulder" then
		return math.max(0, config.CameraShakeShoulder)
	elseif surface == "Bridge" then
		return math.max(0, config.CameraShakeBridge)
	end
	return math.max(0, config.CameraShakeRoad)
end

function CameraFeedback.target(
	speed: number,
	surface: string,
	suspensionEnergy: number,
	gradeDeg: number,
	config: any
): number
	local speedAmount = CameraFeedback.smoothstep(speed, config.CameraShakeSpeedStart, config.CameraShakeSpeedFull)
	local suspensionAmount = clamp01(suspensionEnergy / math.max(config.CameraShakeSuspensionFull, 0.001))
	local gradeAmount = clamp01(math.abs(gradeDeg) / math.max(config.CameraShakeGradeFullDeg, 0.001))
	local road = CameraFeedback.surfaceAmount(surface, config)
	return clamp01(speedAmount * (road + suspensionAmount * 0.55 + gradeAmount * config.CameraShakeGradeInfluence))
end

function CameraFeedback.impact(acceleration: number, config: any): number
	return CameraFeedback.smoothstep(
		math.abs(acceleration),
		config.CameraImpactAccelStart,
		config.CameraImpactAccelFull
	)
end

return CameraFeedback
