--!strict

--[[
	The single switch that decides which game boots.

	FunTest strips the build down to the one question worth answering: is
	operating an unstable cargo vehicle together actually fun? It bypasses the
	depot, the economy, persistence, kits, paints, live-ops and the leg ladder.
	None of that is deleted, it just never initialises.

	Set Mode to "Depot" to get the full meta build back.
]]

export type Mode = "FunTest" | "Depot"

local DevConfig = {
	Mode = "FunTest" :: Mode,

	-- Draws the tuning overlay: load position, per-strap tension, chassis
	-- accelerations, suspension state. Turn off before showing anyone.
	ShowDebugOverlay = true,

	-- In-memory run telemetry, printed to the server log on every run end.
	Telemetry = true,

	-- Extra server prints for physics tuning. Noisy.
	VerbosePhysics = false,
}

function DevConfig.isFunTest(): boolean
	return DevConfig.Mode == "FunTest"
end

return DevConfig
