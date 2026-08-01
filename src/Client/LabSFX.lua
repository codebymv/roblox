--!strict

--[[
	Reactive client audio for the fun-test run. The server already replicates
	the facts that matter (speed, surface, damage, straps, role and outcome), so
	each client can render one coherent mix without multiplying sounds by crew
	count. Empty or unavailable IDs fail silently and never block bootstrap.
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
local LabRemotes = require(Shared:WaitForChild("LabRemotes"))
local LabTypes = require(Shared:WaitForChild("LabTypes"))
local Net = require(Shared:WaitForChild("Net"))

local LabSFX = {}
local SFX_IDS: { [string]: string } = AudioIds.Sfx

local FADE_SPEED = 7
local DAMAGE_COOLDOWN = 0.4

local LOOP_VOLUME = {
	EngineIdleLoop = 0.2,
	EngineDriveLoop = 0.38,
	TireAsphaltLoop = 0.25,
	TireOffroadLoop = 0.34,
	TireSkidLoop = 0.32,
	CargoScrapeLoop = 0.34,
	StrapRatchetLoop = 0.38,
	StrapTensionLoop = 0.22,
	BridgeRumbleLoop = 0.3,
	RoughRoadRattleLoop = 0.32,
	WarehouseAmbienceLoop = 0.22,
}

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
	sound.RollOffMinDistance = 14
	sound.RollOffMaxDistance = 150
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

	local group = SoundService:FindFirstChild("CargoSFXGroup")
	if not group or not group:IsA("SoundGroup") then
		group = Instance.new("SoundGroup")
		group.Name = "CargoSFXGroup"
		group.Volume = 1
		group.Parent = SoundService
	end

	local container = Instance.new("Folder")
	container.Name = "CargoSFX"
	container.Parent = SoundService

	local templates: { [string]: Sound } = {}
	for key, id in SFX_IDS do
		if typeof(id) == "string" and id ~= "" then
			local template = makeSound(key, id, group :: SoundGroup, false)
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
			local sound = makeSound(key, id, group :: SoundGroup, true)
			sound.Parent = container
			loops[key] = { sound = sound, target = 0 }
		end
	end

	local latest: LabTypes.LabSnapshot? = nil
	local previous: LabTypes.LabSnapshot? = nil
	local previousStraps: { [string]: boolean } = {}
	local lastDamageAt = 0
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

	local function play(key: string, category: string, volume: number?, playbackSpeed: number?)
		local template = templates[key]
		if not template then
			return
		end
		local sound = template:Clone()
		sound.Name = key .. "_OneShot"
		sound.Volume = volume or 0.55
		sound.PlaybackSpeed = playbackSpeed or 1
		sound.Parent = positionalParent(category)
		sound:Play()
		Debris:AddItem(sound, 12)
	end

	local function setLoopTarget(key: string, amount: number)
		local state = loops[key]
		if state then
			state.target = math.clamp(amount, 0, 1) * (LOOP_VOLUME[key] or 0.25)
		end
	end

	local function handleSnapshot(snap: LabTypes.LabSnapshot)
		latest = snap

		if not previous or previous.myRole ~= snap.myRole then
			if snap.myRole == "Driver" then
				play("RoleDriver", "ui", 0.48)
			elseif snap.myRole == "Strapper" then
				play("RoleStrapper", "ui", 0.48)
			end
		end

		if previous then
			if not previous.myThrown and snap.myThrown then
				play("PlayerThrown", "player", 0.7)
			elseif previous.myThrown and not snap.myThrown then
				play("PlayerReseat", "player", 0.58)
			end

			if not previous.swapWarning and snap.swapWarning then
				play("SwapWarning", "ui", 0.58)
			end
			if not previous.swapActive and snap.swapActive then
				play("SwapActivate", "ui", 0.68)
			end

			if previous.phase ~= "Run" and snap.phase == "Run" then
				play("RunGo", "ui", 0.62)
			end

			if previous.phase ~= "Result" and snap.phase == "Result" then
				local resultKey = if snap.outcome == "Delivered"
					then "DeliverySuccess"
					elseif snap.outcome == "PartialLoss" then "DeliveryPartial"
					else "DeliveryFailure"
				play(resultKey, "ui", 0.72)
				if snap.rewardEarned > 0 then
					task.delay(0.45, function()
						play("CargoCashReward", "ui", 0.52)
					end)
				end
			end

			if snap.phase == "Run" then
				local cargoLoss = previous.cargoReadout - snap.cargoReadout
				if cargoLoss >= 1 and os.clock() - lastDamageAt >= DAMAGE_COOLDOWN then
					local key = if cargoLoss >= 8
						then "CargoImpactHeavy"
						elseif cargoLoss >= 3 then "CargoImpactMedium"
						else "CargoImpactLight"
					play(key, "cargo", 0.62)
					lastDamageAt = os.clock()
				end

				local chassisLoss = previous.chassisIntegrity - snap.chassisIntegrity
				if chassisLoss >= 1 and os.clock() - lastDamageAt >= DAMAGE_COOLDOWN then
					local key = if chassisLoss >= 10
						then "TruckCollisionHeavy"
						elseif chassisLoss >= 4 then "TruckCollisionMedium"
						else "TruckCollisionLight"
					play(key, "truck", 0.68)
					lastDamageAt = os.clock()
				end
			end

			if not previous.braking and snap.braking then
				play("BrakeHiss", "truck", 0.4)
			end
		end

		if snap.phase == "Staging" and snap.restartSeconds > 0 and snap.restartSeconds <= 3 then
			if snap.restartSeconds ~= lastCountdown then
				lastCountdown = snap.restartSeconds
				play("CountdownTick", "ui", 0.48, 1 + (3 - snap.restartSeconds) * 0.08)
			end
		else
			lastCountdown = -1
		end

		for index, strap in snap.straps do
			local wasBroken = previousStraps[strap.id]
			if wasBroken ~= nil and snap.phase == "Run" then
				if not wasBroken and strap.broken then
					play(
						chooseVariant("StrapSnap1", "StrapSnap2", index + math.floor(snap.timeRemaining)),
						"strap",
						0.72
					)
				elseif wasBroken and not strap.broken then
					play(
						chooseVariant("StrapRefit1", "StrapRefit2", index + math.floor(snap.timeRemaining)),
						"strap",
						0.6
					)
				end
			end
			previousStraps[strap.id] = strap.broken
		end

		previous = snap
	end

	LabRemotes.onClient(Net.Names.LabSnapshot, handleSnapshot)

	RunService.RenderStepped:Connect(function(dt: number)
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
			play(chooseVariant("SuspensionHit1", "SuspensionHit2", roughHitIndex), "truck", 0.38)
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
				local replacement = makeSound(key, soundId(key), group :: SoundGroup, true)
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
			drive.sound.PlaybackSpeed = 0.86 + speedMix * 0.34
		end
	end)
end

return LabSFX
