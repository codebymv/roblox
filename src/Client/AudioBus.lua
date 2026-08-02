--!strict

--[[
	Owns the SoundGroups and the duck envelope.

	Both LabMusic and LabSFX used to create their own group, which meant nothing
	could hear anything else and the only way to change the balance was to edit
	per-sound volumes in two files. One owner instead: modules ask for a bus by
	name, and events ask for a duck.

	AudioMix.lua holds every number this reads. Nothing here decides a level.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioMix = require(Shared:WaitForChild("AudioMix"))

local AudioBus = {}

local BUS_NAMES = { "Music", "SfxBed", "SfxEvents" }

local groups: { [string]: SoundGroup } = {}
-- The envelope's peak, held for DuckHoldSeconds after the last request.
local requested = 0
-- Where the buses actually are, chasing `requested` at attack or release rate.
local applied = 0
local holdUntil = 0
local mounted = false

--[[
	Get, or create, a bus. Idempotent because the client bootstrap mounts music
	and SFX independently and either can be first.
]]
function AudioBus.get(name: string): SoundGroup
	local existing = groups[name]
	if existing and existing.Parent then
		return existing
	end

	local found = SoundService:FindFirstChild(name)
	if found and found:IsA("SoundGroup") then
		groups[name] = found
		return found
	end

	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Volume = AudioMix.busVolume(name, applied)
	group.Parent = SoundService
	groups[name] = group
	return group
end

--[[
	Attach the sidechain compressor a bus declares, if it declares one.

	Deferred until every bus exists, because SideChain names another SoundGroup
	and the event bus may not have been created when the music bus asks for its
	compressor. Idempotent: a second mount finds the effect already there.
]]
local function attachCompressor(name: string)
	local settings = AudioMix.Compressor[name]
	if not settings then
		return
	end

	local group = AudioBus.get(name)
	if group:FindFirstChild("SideChain") then
		return
	end

	local sideChain = AudioBus.get(AudioMix.SideChainBus)
	if sideChain == group then
		-- A bus keyed to itself is a limiter, not a sidechain, and would quietly
		-- squash the very transients this exists to protect.
		warn("[CargoAudio] Refusing to sidechain " .. name .. " to itself")
		return
	end

	local compressor = Instance.new("CompressorSoundEffect")
	compressor.Name = "SideChain"
	compressor.Threshold = settings.thresholdDb
	compressor.Ratio = settings.ratio
	compressor.Attack = settings.attackSeconds
	compressor.Release = settings.releaseSeconds
	compressor.GainMakeup = settings.gainMakeupDb
	compressor.SideChain = sideChain
	compressor.Parent = group
end

--[[
	Pull the mix down under something worth hearing. Amount is 0 to 1; the
	loudest request wins rather than accumulating, so a cargo impact landing
	inside a strap snap does not duck to silence.
]]
function AudioBus.duck(amount: number)
	local weight = math.clamp(amount, 0, 1)
	if weight <= 0 then
		return
	end
	requested = math.max(requested, weight)
	holdUntil = math.max(holdUntil, os.clock() + AudioMix.DuckHoldSeconds)
end

function AudioBus.mount()
	if mounted then
		return
	end
	mounted = true

	for _, name in BUS_NAMES do
		AudioBus.get(name)
	end
	-- Second pass: every bus exists now, so a compressor can name another one.
	for _, name in BUS_NAMES do
		attachCompressor(name)
	end

	RunService.Heartbeat:Connect(function(dt: number)
		if os.clock() >= holdUntil then
			requested = 0
		end

		local rising = requested > applied
		local speed = if rising then AudioMix.DuckAttackSpeed else AudioMix.DuckReleaseSpeed
		applied += (requested - applied) * (1 - math.exp(-speed * dt))
		if requested <= 0 and applied < 0.001 then
			applied = 0
		end

		for _, name in BUS_NAMES do
			local group = AudioBus.get(name)
			group.Volume = AudioMix.busVolume(name, applied)
		end
	end)
end

return AudioBus
