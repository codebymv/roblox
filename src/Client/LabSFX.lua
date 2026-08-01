--!strict

--[[
	Reactive client audio for the fun-test run. The server already replicates
	the facts that matter (speed, surface, damage, straps, role and outcome), so
	each client can render one coherent mix without multiplying sounds by crew
	count. Empty or unavailable IDs fail silently and never block bootstrap.

	Loops and one-shots sit on separate buses. The loops are a bed: continuous,
	low, and almost entirely texture. The one-shots are the game telling you
	something. Sharing a bus meant the bed set the ceiling for the events, which
	is why a strap snapping was quieter than the tyres it snapped over.

	No level is written here. AudioMix owns them, AudioBus owns the groups.
]]

local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioIds = require(Shared:WaitForChild("AudioIds"))
local AudioMix = require(Shared:WaitForChild("AudioMix"))
local ImpactTiers = require(Shared:WaitForChild("ImpactTiers"))
local LabRemotes = require(Shared:WaitForChild("LabRemotes"))
local LabTypes = require(Shared:WaitForChild("LabTypes"))
local Net = require(Shared:WaitForChild("Net"))

local AudioBus = require(script.Parent:WaitForChild("AudioBus"))

local LabSFX = {}
local SFX_IDS: { [string]: string } = AudioIds.Sfx

local FADE_SPEED = 7
local DAMAGE_COOLDOWN = 0.4

local LOOP_KEYS = {
	"EngineIdleLoop",
	"EngineDriveLoop",
	"TireAsphaltLoop",
	"TireOffroadLoop",
	"TireSkidLoop",
	"CargoScrapeLoop",
	"StrapRatchetLoop",
	"StrapTensionLoop",
	"BridgeRumbleLoop",
	"RoughRoadRattleLoop",
	"WarehouseAmbienceLoop",
}

type LoopState = {
	sound: Sound,
	target: number,
}

local function soundId(key: string): string
	local value = SFX_IDS[key]
	return if typeof(value) == "string" then value else ""
end

local function makeSound(name: string, id: string, group: SoundGroup, looped: boolean): Sound
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = id
	sound.Looped = looped
	sound.Volume = 0
	sound.SoundGroup = group
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	-- Events hold full level across the whole truck; the bed is allowed to be
	-- local to the part it belongs to.
	sound.RollOffMinDistance = if looped then AudioMix.BedRollOffMin else AudioMix.EventRollOffMin
	sound.RollOffMaxDistance = AudioMix.RollOffMax
	return sound
end

local function findPart(name: string): BasePart?
	local root = Workspace:FindFirstChild("CargoLab")
	local found = root and root:FindFirstChild(name, true)
	return if found and found:IsA("BasePart") then found else nil
end

local function localCharacterPart(): BasePart?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function chooseVariant(first: string, second: string, salt: number): string
	return if salt % 2 == 0 then first else second
end

function LabSFX.mount()
	if SoundService:FindFirstChild("CargoSFX") then
		return
	end

	AudioBus.mount()
	local bedGroup = AudioBus.get("SfxBed")
	local eventGroup = AudioBus.get("SfxEvents")

	local container = Instance.new("Folder")
	container.Name = "CargoSFX"
	container.Parent = SoundService

	local templates: { [string]: Sound } = {}
	for key, id in SFX_IDS do
		if typeof(id) == "string" and id ~= "" then
			local template = makeSound(key, id, eventGroup, false)
			template.Parent = container
			templates[key] = template
		end
	end

	-- Preload opportunistically. Playback remains available even when Roblox
	-- moderation or permissions make one asset fail to load.
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(container:GetChildren())
		end)
	end)

	local loops: { [string]: LoopState } = {}
	for _, key in LOOP_KEYS do
		local id = soundId(key)
		if id ~= "" then
			local sound = makeSound(key, id, bedGroup, true)
			sound.Parent = container
			loops[key] = { sound = sound, target = 0 }
		end
	end

	local latest: LabTypes.LabSnapshot? = nil
	local previous: LabTypes.LabSnapshot? = nil
	local previousStraps: { [string]: boolean } = {}
	-- Separate cooldowns. Sharing one meant a wreck that damaged both the load
	-- and the truck played whichever was tested first and swallowed the other,
	-- at the exact moment the player most needs to hear what broke.
	local lastCargoDamageAt = 0
	local lastChassisDamageAt = 0
	local roughHitAt = 0
	local roughHitIndex = 0
	local lastCountdown = -1
	local targetRefreshAt = 0
	local chassis: BasePart? = nil
	local crate: BasePart? = nil
	local depot: BasePart? = nil

	local function positionalParent(category: string): Instance
		if category == "cargo" or category == "strap" then
			return crate or SoundService
		end
		if category == "truck" then
			return chassis or SoundService
		end
		if category == "player" then
			return localCharacterPart() or SoundService
		end
		return SoundService
	end

	local function play(key: string, category: string, playbackSpeed: number?)
		local template = templates[key]
		if not template then
			return
		end
		local sound = template:Clone()
		sound.Name = key .. "_OneShot"
		sound.Volume = AudioMix.eventVolume(key)
		sound.PlaybackSpeed = playbackSpeed or 1
		sound.Parent = positionalParent(category)
		sound:Play()
		Debris:AddItem(sound, 12)

		-- Pull the music and the bed down under anything worth hearing. Most
		-- keys carry a weight of zero and leave the mix alone.
		AudioBus.duck(AudioMix.duckWeight(key))
	end

	local function setLoopTarget(key: string, amount: number)
		local state = loops[key]
		if state then
			state.target = math.clamp(amount, 0, 1) * (AudioMix.LoopVolume[key] or 0.25)
		end
	end

	local function handleSnapshot(snap: LabTypes.LabSnapshot)
		latest = snap

		if not previous or previous.myRole ~= snap.myRole then
			if snap.myRole == "Driver" then
				play("RoleDriver", "ui")
			elseif snap.myRole == "Strapper" then
				play("RoleStrapper", "ui")
			end
		end

		if previous then
			if not previous.myThrown and snap.myThrown then
				play("PlayerThrown", "player")
			elseif previous.myThrown and not snap.myThrown then
				play("PlayerReseat", "player")
			end

			if not previous.swapWarning and snap.swapWarning then
				play("SwapWarning", "ui")
			end
			if not previous.swapActive and snap.swapActive then
				play("SwapActivate", "ui")
			end

			if previous.phase ~= "Run" and snap.phase == "Run" then
				play("RunGo", "ui")
			end

			if previous.phase ~= "Result" and snap.phase == "Result" then
				local resultKey = if snap.outcome == "Delivered"
					then "DeliverySuccess"
					elseif snap.outcome == "PartialLoss" then "DeliveryPartial"
					else "DeliveryFailure"
				play(resultKey, "ui")
				if snap.rewardEarned > 0 then
					task.delay(0.45, function()
						play("CargoCashReward", "ui")
					end)
				end
			end

			if snap.phase == "Run" then
				-- Tiers come from ImpactTiers so the particle layer cannot
				-- disagree with the sound about how hard something hit.
				local cargoTier = ImpactTiers.cargo(previous.cargoReadout - snap.cargoReadout)
				if cargoTier and os.clock() - lastCargoDamageAt >= DAMAGE_COOLDOWN then
					play("CargoImpact" .. cargoTier, "cargo")
					lastCargoDamageAt = os.clock()
				end

				local chassisTier = ImpactTiers.chassis(previous.chassisIntegrity - snap.chassisIntegrity)
				if chassisTier and os.clock() - lastChassisDamageAt >= DAMAGE_COOLDOWN then
					play("TruckCollision" .. chassisTier, "truck")
					lastChassisDamageAt = os.clock()
				end
			end

			if not previous.braking and snap.braking then
				play("BrakeHiss", "truck")
			end
		end

		if snap.phase == "Staging" and snap.restartSeconds > 0 and snap.restartSeconds <= 3 then
			if snap.restartSeconds ~= lastCountdown then
				lastCountdown = snap.restartSeconds
				play("CountdownTick", "ui", 1 + (3 - snap.restartSeconds) * 0.08)
			end
		else
			lastCountdown = -1
		end

		-- Reset strap memory outside Run so a Staging heal after a wreck does
		-- not fire a false StrapRefit one-shot on the next GO.
		if snap.phase ~= "Run" then
			table.clear(previousStraps)
		else
			for index, strap in snap.straps do
				local wasBroken = previousStraps[strap.id]
				if wasBroken ~= nil then
					if not wasBroken and strap.broken then
						play(chooseVariant("StrapSnap1", "StrapSnap2", index + math.floor(snap.timeRemaining)), "strap")
					elseif wasBroken and not strap.broken then
						play(
							chooseVariant("StrapRefit1", "StrapRefit2", index + math.floor(snap.timeRemaining)),
							"strap"
						)
					end
				end
				previousStraps[strap.id] = strap.broken
			end
		end

		previous = snap
	end

	LabRemotes.onClient(Net.Names.LabSnapshot, handleSnapshot)

	-- Loop fades track simulation state, not the camera; Heartbeat is enough.
	RunService.Heartbeat:Connect(function(dt: number)
		local snap = latest
		if not snap then
			return
		end

		if os.clock() >= targetRefreshAt then
			targetRefreshAt = os.clock() + 0.5
			chassis = findPart("Chassis")
			crate = findPart("Crate")
			depot = findPart("DeliveryPad")
		end

		local speed = math.max(0, snap.speed)
		local speedMix = math.clamp(speed / 42, 0, 1)
		local moving = snap.phase == "Run" and math.clamp(speed / 8, 0, 1) or 0
		local surface = snap.roadSurface
		local offroad = surface == "Shoulder" or surface == "Grass"
		local rough = surface == "Rough"
		local bridge = surface == "Bridge"

		setLoopTarget("EngineIdleLoop", if snap.phase == "Result" then 0 else 1 - speedMix * 0.8)
		setLoopTarget("EngineDriveLoop", speedMix)
		setLoopTarget("TireAsphaltLoop", if not offroad and not rough and not bridge then moving else 0)
		setLoopTarget("TireOffroadLoop", if offroad then moving else 0)
		setLoopTarget("TireSkidLoop", if snap.braking and speed >= 10 then math.clamp(speed / 45, 0, 1) else 0)
		setLoopTarget("BridgeRumbleLoop", if bridge then moving else 0)
		setLoopTarget("RoughRoadRattleLoop", if rough then moving else 0)
		setLoopTarget(
			"CargoScrapeLoop",
			if snap.phase == "Run" and (snap.condition == "Sliding" or snap.condition == "Dragging") then moving else 0
		)

		local maxTension = 0
		local working = false
		for _, strap in snap.straps do
			maxTension = math.max(maxTension, strap.tension)
			if strap.workedBy == Players.LocalPlayer.Name then
				working = true
			end
		end
		setLoopTarget("StrapRatchetLoop", if working and snap.phase == "Run" then 1 else 0)
		setLoopTarget(
			"StrapTensionLoop",
			if snap.phase == "Run" then math.clamp((maxTension - 0.35) / 0.85, 0, 1) else 0
		)
		setLoopTarget("WarehouseAmbienceLoop", if depot then 1 else 0)

		if rough and speed >= 12 and os.clock() >= roughHitAt then
			roughHitIndex += 1
			roughHitAt = os.clock() + 0.65 + math.random() * 0.55
			play(chooseVariant("SuspensionHit1", "SuspensionHit2", roughHitIndex), "truck")
		end

		for key, state in loops do
			local parent: Instance = container
			if key == "WarehouseAmbienceLoop" then
				parent = depot or container
			elseif string.find(key, "Strap") or string.find(key, "Cargo") then
				parent = crate or container
			else
				parent = chassis or container
			end
			-- A developer rig rebuild destroys client sounds parented to the old
			-- chassis/crate too. Recreate that loop instead of retaining a dead
			-- Instance and losing vehicle audio for the rest of the session.
			if not state.sound.Parent then
				local replacement = makeSound(key, soundId(key), bedGroup, true)
				replacement.Parent = parent
				state.sound = replacement
			elseif state.sound.Parent ~= parent then
				state.sound.Parent = parent
			end

			if state.target > 0.001 and not state.sound.IsPlaying then
				state.sound:Play()
			end
			local alpha = 1 - math.exp(-FADE_SPEED * dt)
			state.sound.Volume += (state.target - state.sound.Volume) * alpha
			if state.target <= 0.001 and state.sound.Volume <= 0.004 and state.sound.IsPlaying then
				state.sound:Stop()
			end
		end

		local drive = loops.EngineDriveLoop
		if drive then
			-- Snapshot speed is 10 Hz; hard-assigning pitch stair-steps RPM.
			local pitchTarget = 0.86 + speedMix * 0.34
			local pitchAlpha = 1 - math.exp(-FADE_SPEED * dt)
			drive.sound.PlaybackSpeed += (pitchTarget - drive.sound.PlaybackSpeed) * pitchAlpha
		end
	end)
end

return LabSFX
