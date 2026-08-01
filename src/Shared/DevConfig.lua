--!strict

local RunService = game:GetService("RunService")

local BuildProfiles = require(script.Parent.BuildProfiles)

--[[
	Which tooling is live, and whether this is a published server.

	There used to be a Mode switch here as well, choosing between the depot
	prototype and the physics-first build. The depot build has been deleted, so
	there is one game and the switch was only a way to boot a version of it that
	no longer exists.
]]

export type BuildProfile = BuildProfiles.Name

-- Normal behavior is automatic: Studio gets development tools and every
-- published server gets release-safe settings. Force "Release" temporarily
-- to rehearse the published configuration inside Studio.
local FORCE_PROFILE: BuildProfile? = nil
local activeProfile: BuildProfile = FORCE_PROFILE or if RunService:IsStudio() then "Development" else "Release"
local settings = BuildProfiles.get(activeProfile)

local DevConfig = {
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

function DevConfig.isDevToolingEnabled(): boolean
	return DevConfig.Profile == "Development" and DevConfig.LiveTuning
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
