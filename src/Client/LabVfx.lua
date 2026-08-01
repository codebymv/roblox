--!nonstrict

--[[
	Particles for the things the game already tells you about in sound.

	Mirrors LabSFX deliberately: same snapshot stream, same event moments, same
	tier thresholds through ImpactTiers, so a heavy hit never sounds heavy and
	looks light. Where LabSFX sets a loop's volume from a measured ratio, this
	sets an emitter's rate from the same one.

	Every emitter is created once and then enabled, disabled or pulsed. Creating
	a ParticleEmitter per event would allocate on exactly the frames that are
	already the busiest ones in the run.

	Client-side and presentation-only. The server replicates the facts; nothing
	here is authoritative and nothing here is replicated back.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ImpactTiers = require(Shared:WaitForChild("ImpactTiers"))
local LabConfig = require(Shared:WaitForChild("LabConfig"))
local LabRemotes = require(Shared:WaitForChild("LabRemotes"))
local LabTypes = require(Shared:WaitForChild("LabTypes"))
local Net = require(Shared:WaitForChild("Net"))
local RunCauses = require(Shared:WaitForChild("RunCauses"))
local VfxSpec = require(Shared:WaitForChild("VfxSpec"))

local LabVfx = {}

-- Roblox's default particle texture. Deliberately not an uploaded asset: an
-- unapproved or moderated image would take the whole layer down with it, and
-- the shapes here read from silhouette and colour rather than detail.
local PARTICLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local WHEEL_ORDER = { "FL", "FR", "RL", "RR" }
local REFRESH_SECONDS = 0.5
-- Weak keys let a rebuilt rig and its emitters disappear without a cleanup
-- pass. Spec tables are stable identities from VfxSpec.
local appliedSpecs = setmetatable({}, { __mode = "k" })

local function applyCommon(emitter: ParticleEmitter, spec)
	emitter.Texture = PARTICLE_TEXTURE
	emitter.Lifetime = spec.lifetime
	emitter.Speed = spec.speed
	emitter.SpreadAngle = Vector2.new(spec.spreadDegrees, spec.spreadDegrees)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, spec.sizeStart),
		NumberSequenceKeypoint.new(1, spec.sizeEnd),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, spec.transparencyStart),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Color = ColorSequence.new(spec.color)
	emitter.Acceleration = spec.acceleration
	emitter.Drag = spec.drag
	emitter.LightEmission = spec.lightEmission
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.Enabled = false
	emitter.Rate = 0
end

local function makeEmitter(parent: Instance, name: string, spec): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	applyCommon(emitter, spec)
	appliedSpecs[emitter] = spec
	emitter.Parent = parent
	return emitter
end

--[[
	Emitters need somewhere to live that survives the part they describe being
	rebuilt. An Attachment under the rig part is the natural anchor; if the rig
	is rebuilt by a dev command the attachment dies with it and gets recreated
	on the next refresh, exactly like LabSFX recreates its loops.
]]
local function makeAnchor(parent: BasePart, name: string, offset: Vector3): Attachment
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Attachment") then
		return existing
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Position = offset
	attachment.Parent = parent
	return attachment
end

local function findPart(name: string): BasePart?
	local root = Workspace:FindFirstChild("CargoLab")
	local found = root and root:FindFirstChild(name, true)
	return if found and found:IsA("BasePart") then found else nil
end

function LabVfx.mount()
	local latest: LabTypes.LabSnapshot? = nil
	local previous: LabTypes.LabSnapshot? = nil
	local previousStraps: { [string]: boolean } = {}
	local lastCargoDamageAt = 0
	local lastChassisDamageAt = 0
	local wreckShown = false
	local refreshAt = 0

	local chassis: BasePart? = nil
	local crate: BasePart? = nil

	-- Built lazily against whatever rig currently exists, and rebuilt whenever
	-- the parts they hang from go away.
	local wheelSpray: { [string]: ParticleEmitter } = {}
	local tyreSmoke: { [string]: ParticleEmitter } = {}
	local strapStress: { [string]: ParticleEmitter } = {}
	local strapBurst: { [string]: ParticleEmitter } = {}
	local cargoScrape: ParticleEmitter? = nil
	local cargoImpact: ParticleEmitter? = nil
	local truckImpact: ParticleEmitter? = nil
	local wreckBurst: ParticleEmitter? = nil

	local function alive(emitter: ParticleEmitter?): boolean
		return emitter ~= nil and emitter.Parent ~= nil
	end

	local function rebuild()
		chassis = findPart("Chassis")
		crate = findPart("Crate")

		if chassis and chassis.Parent then
			for _, id in WHEEL_ORDER do
				local offset = LabConfig.WheelOffsets[id]
				if offset and (not alive(wheelSpray[id]) or not alive(tyreSmoke[id])) then
					-- Under the wheel rather than at the hub, so spray leaves the
					-- contact patch instead of the middle of the tyre.
					local anchor = makeAnchor(
						chassis,
						"Vfx_Wheel_" .. id,
						offset - Vector3.new(0, LabConfig.SuspensionRestLength * 0.5, 0)
					)
					wheelSpray[id] = makeEmitter(anchor, "Spray", VfxSpec.wheelSpray("Shoulder"))
					tyreSmoke[id] = makeEmitter(anchor, "Smoke", VfxSpec.TyreSmoke)
				end
			end

			for _, id in LabConfig.StrapOrder do
				local railLocal = LabConfig.StrapRailLocal[id]
				if railLocal and (not alive(strapStress[id]) or not alive(strapBurst[id])) then
					local anchor = makeAnchor(chassis, "Vfx_Strap_" .. id, railLocal)
					strapStress[id] = makeEmitter(anchor, "Stress", VfxSpec.StrapStress)
					strapBurst[id] = makeEmitter(anchor, "Snap", VfxSpec.StrapSnap)
				end
			end

			if not alive(truckImpact) then
				truckImpact = makeEmitter(
					makeAnchor(chassis, "Vfx_Impact", Vector3.zero),
					"Impact",
					VfxSpec.TruckCollision.Medium
				)
			end
			if not alive(wreckBurst) then
				wreckBurst = makeEmitter(makeAnchor(chassis, "Vfx_Wreck", Vector3.zero), "Wreck", VfxSpec.Rollover)
			end
		end

		if crate and crate.Parent then
			if not alive(cargoScrape) then
				cargoScrape = makeEmitter(
					makeAnchor(crate, "Vfx_Scrape", Vector3.new(0, -crate.Size.Y * 0.5, 0)),
					"Scrape",
					VfxSpec.CargoScrape
				)
			end
			if not alive(cargoImpact) then
				cargoImpact = makeEmitter(
					makeAnchor(crate, "Vfx_CargoImpact", Vector3.zero),
					"Impact",
					VfxSpec.CargoImpact.Medium
				)
			end
		end
	end

	-- Retune an emitter to a different spec and fire it once. Cheaper than
	-- holding one emitter per tier, and the tiers differ only in numbers.
	local function burst(emitter: ParticleEmitter?, spec, scale: number?)
		if not alive(emitter) then
			return
		end
		if appliedSpecs[emitter] ~= spec then
			applyCommon(emitter, spec)
			appliedSpecs[emitter] = spec
		end
		emitter:Emit(math.max(1, math.floor(spec.count * (scale or 1))))
	end

	local function setContinuous(emitter: ParticleEmitter?, spec, intensity: number)
		if not alive(emitter) then
			return
		end
		local amount = math.clamp(intensity, 0, 1)
		if amount <= 0.01 or spec.rate <= 0 then
			if emitter.Enabled then
				emitter.Enabled = false
			end
			if emitter.Rate ~= 0 then
				emitter.Rate = 0
			end
			return
		end
		if appliedSpecs[emitter] ~= spec then
			applyCommon(emitter, spec)
			appliedSpecs[emitter] = spec
		end
		local rate = spec.rate * amount
		if math.abs(emitter.Rate - rate) > 0.05 then
			emitter.Rate = rate
		end
		if not emitter.Enabled then
			emitter.Enabled = true
		end
	end

	local function handleSnapshot(snap: LabTypes.LabSnapshot)
		latest = snap

		if previous then
			if snap.phase == "Run" then
				local cargoLoss = previous.cargoReadout - snap.cargoReadout
				local cargoTier = ImpactTiers.cargo(cargoLoss)
				if cargoTier and os.clock() - lastCargoDamageAt >= 0.4 then
					burst(cargoImpact, VfxSpec.cargoImpact(cargoTier))
					lastCargoDamageAt = os.clock()
				end

				local chassisLoss = previous.chassisIntegrity - snap.chassisIntegrity
				local chassisTier = ImpactTiers.chassis(chassisLoss)
				if chassisTier and os.clock() - lastChassisDamageAt >= 0.4 then
					burst(truckImpact, VfxSpec.truckCollision(chassisTier))
					lastChassisDamageAt = os.clock()
				end
			end

			-- The wreck burst is the last thing that happens, and it should
			-- happen once. Rollovers and falls get it; a cargo-only loss does not,
			-- because the truck is still intact and still on the road.
			if not wreckShown and snap.outcome == "TruckWrecked" then
				wreckShown = true
				if RunCauses.isWreckCause(snap.outcomeCause) then
					burst(wreckBurst, VfxSpec.Rollover)
				end
			end
		end

		if snap.phase ~= "Result" then
			wreckShown = false
		end

		for _, strap in snap.straps do
			local wasBroken = previousStraps[strap.id]
			if wasBroken ~= nil and snap.phase == "Run" then
				if not wasBroken and strap.broken then
					burst(strapBurst[strap.id], VfxSpec.StrapSnap)
				elseif wasBroken and not strap.broken then
					burst(strapBurst[strap.id], VfxSpec.StrapRefit)
				end
			end
			previousStraps[strap.id] = strap.broken
		end

		previous = snap
	end

	LabRemotes.onClient(Net.Names.LabSnapshot, handleSnapshot)

	RunService.Heartbeat:Connect(function()
		local snap = latest
		if not snap then
			return
		end

		if os.clock() >= refreshAt then
			refreshAt = os.clock() + REFRESH_SECONDS
			rebuild()
		end

		local running = snap.phase == "Run"
		local speed = math.max(0, snap.speed)
		local speedRatio = math.clamp(speed / VfxSpec.SpraySpeedReference, 0, 1)
		local surface = snap.roadSurface

		--[[
			Wheel spray. The snapshot reports one surface for the truck rather
			than one per wheel, so all four share it; per-wheel surface would
			need a wider snapshot and is only visible when the truck is halfway
			off the road, which is already obvious for other reasons.
		]]
		local spraySpec = VfxSpec.wheelSpray(surface)
		local sprayAmount = if running then speedRatio else 0
		local smokeAmount = if running and snap.braking and speed >= 10 then speedRatio else 0
		for _, id in WHEEL_ORDER do
			setContinuous(wheelSpray[id], spraySpec, sprayAmount)
			setContinuous(tyreSmoke[id], VfxSpec.TyreSmoke, smokeAmount)
		end

		--[[
			The load grinding along the road, driven by the same condition the
			HUD reports. Scaled by speed so a crate resting against the rail at
			walking pace does not throw sparks.
		]]
		local scraping = running and (snap.condition == "Sliding" or snap.condition == "Dragging")
		setContinuous(cargoScrape, VfxSpec.CargoScrape, if scraping then speedRatio else 0)

		--[[
			Tension shimmer per strap. This is the one effect that shows a player
			something before it happens rather than after, which is what gives a
			Strapper a reason to be looking at the load.
		]]
		for _, strap in snap.straps do
			local emitter = strapStress[strap.id]
			if emitter then
				local stress = 0
				if running and not strap.broken then
					local floor = VfxSpec.StrapStressFloor
					stress = (math.clamp(strap.tension, 0, 2) - floor) / math.max(1 - floor, 0.01)
				end
				setContinuous(emitter, VfxSpec.StrapStress, stress)
			end
		end
	end)
end

return LabVfx
