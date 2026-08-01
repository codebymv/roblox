--!strict

--[[
	Small, engine-free helpers for smoothing replicated presentation values.

	Gameplay stays authoritative on the server. These functions are only for
	client-side readouts, where stepping from one 10 Hz snapshot to the next is
	visually noisy. Exponential smoothing is frame-rate independent, so the HUD
	feels the same at 30, 60, or 144 FPS.
]]

local PresentationMath = {}

function PresentationMath.alpha(rate: number, dt: number): number
	if rate <= 0 or dt <= 0 then
		return 0
	end
	return 1 - math.exp(-rate * dt)
end

function PresentationMath.approach(current: number, target: number, rate: number, dt: number): number
	return current + (target - current) * PresentationMath.alpha(rate, dt)
end

return PresentationMath
