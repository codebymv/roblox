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

	-- Mirrors the tunable half of LabConfig onto attributes of a folder in
	-- ReplicatedStorage, editable live from the Studio Explorer, and enables
	-- the developer commands (warp, rebuild, dump). Turn off for anything a
	-- player will see.
	LiveTuning = true,

	-- Writes each finished run to ServerStorage as JSON so it survives the
	-- output window and can be diffed against another tuning pass.
	RunArtifacts = true,

	-- Extra server prints for physics tuning. Noisy.
	VerbosePhysics = false,
}

--[[
	Developer affordances are gated on being in the fun-test build as well as
	on their own flag, so shipping Depot can never expose them by accident.
]]
function DevConfig.isDevToolingEnabled(): boolean
	return DevConfig.Mode == "FunTest" and DevConfig.LiveTuning
end

function DevConfig.isFunTest(): boolean
	return DevConfig.Mode == "FunTest"
end

return DevConfig
