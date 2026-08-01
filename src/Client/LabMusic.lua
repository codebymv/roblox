--!strict

--[[
	Background music for the fun-test lab. One loop, phase-aware volume only;
	no stacking tracks on reset.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioIds = require(Shared:WaitForChild("AudioIds"))
local LabRemotes = require(Shared:WaitForChild("LabRemotes"))
local LabTypes = require(Shared:WaitForChild("LabTypes"))
local Net = require(Shared:WaitForChild("Net"))

local LabMusic = {}

local VOLUME = {
	Staging = 0.34,
	Run = 0.42,
	Result = 0.16,
}

local FADE_SPEED = 4

local function targetVolume(phase: string): number
	if phase == "Run" then
		return VOLUME.Run
	end
	if phase == "Result" then
		return VOLUME.Result
	end
	return VOLUME.Staging
end

function LabMusic.mount()
	if AudioIds.OstLoop == "" then
		return
	end

	local group = Instance.new("SoundGroup")
	group.Name = "Music"
	group.Parent = SoundService

	local track = Instance.new("Sound")
	track.Name = "CargoOST"
	track.SoundId = AudioIds.OstLoop
	track.Looped = true
	track.Volume = VOLUME.Staging
	track.SoundGroup = group
	track.Parent = SoundService

	local desired = VOLUME.Staging
	local phase = "Staging"
	local focused = true

	local function ensurePlaying()
		if not track.IsPlaying then
			-- Play starts loading asynchronously. Waiting on Loaded here can block
			-- the entire client bootstrap forever when an asset is unavailable or
			-- not permitted for the current place.
			track:Play()
		end
	end

	LabRemotes.onClient(Net.Names.LabSnapshot, function(snap: LabTypes.LabSnapshot)
		if snap.phase == phase then
			return
		end
		phase = snap.phase
		desired = targetVolume(phase)
		ensurePlaying()
	end)

	RunService.RenderStepped:Connect(function(dt: number)
		if not track.IsPlaying then
			return
		end
		local target = if focused then desired else 0
		local alpha = 1 - math.exp(-FADE_SPEED * dt)
		track.Volume += (target - track.Volume) * alpha
	end)

	UserInputService.WindowFocusReleased:Connect(function()
		focused = false
	end)
	UserInputService.WindowFocused:Connect(function()
		focused = true
		desired = targetVolume(phase)
		ensurePlaying()
	end)

	ensurePlaying()
end

return LabMusic
