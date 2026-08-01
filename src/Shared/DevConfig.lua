--!strict

local RunService = game:GetService("RunService")

local BuildProfiles = require(script.Parent.BuildProfiles)

--[[
	The single switch that decides which game boots.

	FunTest is the physics-first public build. It bypasses the old depot, role
	kits, live-ops and leg ladder, but now retains player profiles, run rewards
	and cosmetic truck paints so the validated interaction can grow a meta loop.

	Set Mode to "Depot" to get the full meta build back.
]]

export type Mode = "FunTest" | "Depot"
export type BuildProfile = BuildProfiles.Name

-- Normal behavior is automatic: Studio gets development tools and every
-- published server gets release-safe settings. Force "Release" temporarily
-- to rehearse the published configuration inside Studio.
local FORCE_PROFILE: BuildProfile? = nil
local activeProfile: BuildProfile = FORCE_PROFILE or if RunService:IsStudio() then "Development" else "Release"
local settings = BuildProfiles.get(activeProfile)

local DevConfig = {
	Mode = "FunTest" :: Mode,
	Profile = activeProfile,

	-- Draws the tuning overlay: load position, per-strap tension, chassis
	-- accelerations, suspension state. Turn off before showing anyone.
	ShowDebugOverlay = settings.ShowDebugOverlay,

	-- Run telemetry. Development prints the timeline and may write a Studio
	-- artifact; Release sends only the compact anonymous summary through
	-- AnalyticsService.
	Telemetry = settings.Telemetry,

	-- Mirrors the tunable half of LabConfig onto attributes of a folder in
	-- ReplicatedStorage, editable live from the Studio Explorer, and enables
	-- the developer commands (warp, rebuild, dump). Turn off for anything a
	-- player will see.
	LiveTuning = settings.LiveTuning,

	-- Writes each finished run to ServerStorage as JSON so it survives the
	-- output window and can be diffed against another tuning pass.
	RunArtifacts = settings.RunArtifacts,

	-- Extra server prints for physics tuning. Noisy.
	VerbosePhysics = settings.VerbosePhysics,
}

--[[
	Developer affordances are gated on being in the fun-test build as well as
	on their own flag, so shipping Depot can never expose them by accident.
]]
function DevConfig.isDevToolingEnabled(): boolean
	return DevConfig.Mode == "FunTest" and DevConfig.Profile == "Development" and DevConfig.LiveTuning
end

function DevConfig.isFunTest(): boolean
	return DevConfig.Mode == "FunTest"
end

function DevConfig.isRelease(): boolean
	return DevConfig.Profile == "Release"
end

function DevConfig.releaseSafetyIssues(): { string }
	return BuildProfiles.releaseSafetyIssues({
		ShowDebugOverlay = DevConfig.ShowDebugOverlay,
		Telemetry = DevConfig.Telemetry,
		LiveTuning = DevConfig.LiveTuning,
		RunArtifacts = DevConfig.RunArtifacts,
		VerbosePhysics = DevConfig.VerbosePhysics,
	})
end

return DevConfig
