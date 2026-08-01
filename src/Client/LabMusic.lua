--!strict

--[[
	Background music for the fun-test lab.

	Starts on the first playlist cue. When a track nears its end, the next cue
	is chosen at random among the others (never the same track twice in a row)
	and crossfaded in. Phase volume and window-focus ducking sit on top.

	Levels come from AudioMix and the group comes from AudioBus, which is also
	what pulls this down under a strap snap. Music is loudest in Staging, where
	there is nothing it can bury, and steps back for the run itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioIds = require(Shared:WaitForChild("AudioIds"))
local AudioMix = require(Shared:WaitForChild("AudioMix"))
local LabRemotes = require(Shared:WaitForChild("LabRemotes"))
local LabTypes = require(Shared:WaitForChild("LabTypes"))
local Net = require(Shared:WaitForChild("Net"))

local AudioBus = require(script.Parent:WaitForChild("AudioBus"))

local LabMusic = {}

local PHASE_FADE_SPEED = 4
local CROSSFADE_SECONDS = 5
local CROSSFADE_SPEED = 1.35

local function targetVolume(phase: string): number
	return AudioMix.musicPhaseVolume(phase)
end

local function collectTracks(): { string }
	local list = {}
	if typeof(AudioIds.OstTracks) == "table" then
		for _, id in AudioIds.OstTracks do
			if typeof(id) == "string" and id ~= "" and string.find(id, "PLACEHOLDER", 1, true) == nil then
				table.insert(list, id)
			end
		end
	elseif typeof(AudioIds.OstLoop) == "string" and AudioIds.OstLoop ~= "" then
		table.insert(list, AudioIds.OstLoop)
	end
	return list
end

--[[
	Pick any playlist index except `current`. With one track this returns
	current so a solo cue can still restart via Ended.
]]
local function pickNextIndex(count: number, current: number): number
	if count <= 1 then
		return current
	end
	local choice = math.random(1, count - 1)
	if choice >= current then
		choice += 1
	end
	return choice
end

function LabMusic.mount()
	local trackIds = collectTracks()
	if #trackIds == 0 then
		return
	end

	AudioBus.mount()
	local group = AudioBus.get("Music")

	type Slot = {
		sound: Sound,
		weight: number,
	}

	local slots: { Slot } = {}
	for index, id in trackIds do
		local sound = Instance.new("Sound")
		sound.Name = "CargoOST_" .. tostring(index)
		sound.SoundId = id
		sound.Looped = false
		sound.Volume = 0
		sound.SoundGroup = group
		sound.Parent = SoundService
		table.insert(slots, { sound = sound, weight = 0 })
	end

	-- Always open on the first uploaded cue.
	local activeIndex = 1
	local nextIndex = 1
	local crossfade = 0
	local crossfading = false
	local desired = targetVolume("Staging")
	local phase = "Staging"
	local focused = true

	local function playSlot(index: number, atZero: boolean)
		local slot = slots[index]
		if not slot then
			return
		end
		slot.weight = if atZero then 0 else 1
		if not slot.sound.IsPlaying then
			slot.sound.TimePosition = 0
			slot.sound:Play()
		end
	end

	local function stopSlot(index: number)
		local slot = slots[index]
		if not slot then
			return
		end
		slot.weight = 0
		if slot.sound.IsPlaying then
			slot.sound:Stop()
		end
		slot.sound.Volume = 0
	end

	local function beginCrossfade()
		if crossfading then
			return
		end
		nextIndex = pickNextIndex(#slots, activeIndex)
		if nextIndex == activeIndex then
			-- Solo track: restart cleanly instead of crossfading into itself.
			local slot = slots[activeIndex]
			if slot then
				slot.sound.TimePosition = 0
				if not slot.sound.IsPlaying then
					slot.sound:Play()
				end
			end
			return
		end
		crossfading = true
		crossfade = 0
		playSlot(nextIndex, true)
	end

	local function finishCrossfade()
		stopSlot(activeIndex)
		activeIndex = nextIndex
		slots[activeIndex].weight = 1
		crossfading = false
		crossfade = 0
	end

	local function ensurePlaying()
		local active = slots[activeIndex]
		if active and not active.sound.IsPlaying and not crossfading then
			playSlot(activeIndex, false)
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

	for index, slot in slots do
		slot.sound.Ended:Connect(function()
			if index ~= activeIndex then
				return
			end
			if crossfading then
				finishCrossfade()
			else
				beginCrossfade()
				if crossfading then
					finishCrossfade()
				end
			end
		end)
	end

	-- Volume lerps do not need pre-render timing; Heartbeat is enough.
	RunService.Heartbeat:Connect(function(dt: number)
		local master = if focused then desired else 0
		local phaseAlpha = 1 - math.exp(-PHASE_FADE_SPEED * dt)

		local active = slots[activeIndex]
		if active then
			local length = active.sound.TimeLength
			local position = active.sound.TimePosition
			if
				not crossfading
				and #slots > 1
				and length > CROSSFADE_SECONDS + 1
				and position >= length - CROSSFADE_SECONDS
			then
				beginCrossfade()
			end
		end

		if crossfading then
			crossfade = math.clamp(crossfade + dt * CROSSFADE_SPEED, 0, 1)
			slots[activeIndex].weight = 1 - crossfade
			slots[nextIndex].weight = crossfade
			if crossfade >= 1 then
				finishCrossfade()
			end
		elseif active then
			active.weight = 1
		end

		for _, entry in slots do
			local target = master * entry.weight
			entry.sound.Volume += (target - entry.sound.Volume) * phaseAlpha
		end

		ensurePlaying()
	end)

	UserInputService.WindowFocusReleased:Connect(function()
		focused = false
	end)
	UserInputService.WindowFocused:Connect(function()
		focused = true
		desired = targetVolume(phase)
		ensurePlaying()
	end)

	playSlot(activeIndex, false)
end

return LabMusic
