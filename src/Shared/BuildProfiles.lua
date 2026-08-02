--!strict

export type Name = "Development" | "Release"

export type Settings = {
	ShowDebugOverlay: boolean,
	Telemetry: boolean,
	LiveTuning: boolean,
	RunArtifacts: boolean,
	VerbosePhysics: boolean,
}

local PROFILES: { [Name]: Settings } = {
	Development = {
		-- Off by default; F-toggle only mounts when this is true. Chat owns TL.
		ShowDebugOverlay = false,
		Telemetry = true,
		LiveTuning = true,
		RunArtifacts = true,
		VerbosePhysics = false,
	},
	Release = {
		ShowDebugOverlay = false,
		Telemetry = true,
		LiveTuning = false,
		RunArtifacts = false,
		VerbosePhysics = false,
	},
}

local BuildProfiles = {}

function BuildProfiles.get(name: Name): Settings
	local profile = PROFILES[name]
	assert(profile, string.format("Unknown build profile: %s", tostring(name)))

	return {
		ShowDebugOverlay = profile.ShowDebugOverlay,
		Telemetry = profile.Telemetry,
		LiveTuning = profile.LiveTuning,
		RunArtifacts = profile.RunArtifacts,
		VerbosePhysics = profile.VerbosePhysics,
	}
end

function BuildProfiles.releaseSafetyIssues(settings: Settings): { string }
	local issues = {}
	if settings.ShowDebugOverlay then
		table.insert(issues, "debug overlay is enabled")
	end
	if settings.LiveTuning then
		table.insert(issues, "live tuning and developer commands are enabled")
	end
	if settings.RunArtifacts then
		table.insert(issues, "in-memory Studio run artifacts are enabled")
	end
	if settings.VerbosePhysics then
		table.insert(issues, "verbose physics logging is enabled")
	end
	return issues
end

return BuildProfiles
