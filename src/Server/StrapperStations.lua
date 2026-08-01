--!nonstrict

--[[
	The Strapper's body is the interface.

	Four stations sit outboard on the rails, one per strap. A crew member holds
	one station at a time, commits to a traversal to reach another, and works
	whichever strap they are standing at. Three things make this a real role
	rather than a contextual button:

	1. Only one crew member can hold a station, so a crew has to divide the bed.
	2. A traversal cannot be cancelled, so choosing to cross while the driver is
	   mid-corner is a genuine risk, and enough lateral load throws you off.
	3. The station platform carries real mass, so standing on the high side of
	   the truck is itself a way of saving the load.

	Crew are welded into the chassis assembly rather than walking on it.
	Humanoids do not stay on a platform moving at 70 studs/s, and the weld is
	the only version of this that is not a jitter bug. The cost is that crew
	visibly sit rather than stand, which is a cosmetic debt, not a design one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CrewRotation = require(Shared:WaitForChild("CrewRotation"))
local LabConfig = require(Shared:WaitForChild("LabConfig"))

local StrapperStations = {}
StrapperStations.__index = StrapperStations

function StrapperStations.new(chassisRig, cargoLoad)
	return setmetatable({
		chassisRig = chassisRig,
		cargoLoad = cargoLoad,
		slots = {},
		occupancy = {},
		pendingThrows = {} :: { string },
		rotationGraceUntil = 0,
	}, StrapperStations)
end

local function bezier(a: Vector3, control: Vector3, b: Vector3, t: number): Vector3
	local inv = 1 - t
	return a * (inv * inv) + control * (2 * inv * t) + b * (t * t)
end

function StrapperStations:_freeStation(): string?
	for _, id in LabConfig.StationOrder do
		if not self.occupancy[id] then
			return id
		end
	end
	return nil
end

function StrapperStations:_makeSeat(name: string, offset: CFrame, density: number): (Seat?, Weld?)
	local chassis = self.chassisRig:getChassis()
	local model = self.chassisRig:getModel()
	if not chassis or not chassis.Parent or not model or not model.Parent then
		return nil, nil
	end

	local seat = Instance.new("Seat")
	seat.Name = name
	seat.Size = LabConfig.StationSeatSize
	seat.Color = Color3.fromRGB(90, 100, 116)
	seat.Material = Enum.Material.DiamondPlate
	seat.Anchored = false
	seat.CanCollide = false
	seat.CustomPhysicalProperties = PhysicalProperties.new(density, 0.4, 0, 1, 1)
	seat.CFrame = chassis.CFrame * offset
	seat.Parent = model

	-- A Weld, not a WeldConstraint: C0 is animatable, which is how a crew
	-- member travels the bed without ever leaving the assembly.
	local weld = Instance.new("Weld")
	weld.Name = name .. "Weld"
	weld.Part0 = chassis
	weld.Part1 = seat
	weld.C0 = offset
	weld.Parent = chassis

	if string.sub(name, 1, 7) == "Station" then
		local grabRail = Instance.new("Part")
		grabRail.Name = name .. "GrabRail"
		grabRail.Size = Vector3.new(0.2, 2.2, 2.4)
		grabRail.Color = Color3.fromRGB(118, 126, 138)
		grabRail.Material = Enum.Material.Metal
		grabRail.Anchored = false
		grabRail.CanCollide = false
		grabRail.Massless = true
		grabRail.CFrame = seat.CFrame * CFrame.new(0, 1.15, -1.05)
		grabRail.Parent = model

		local railWeld = Instance.new("WeldConstraint")
		railWeld.Part0 = seat
		railWeld.Part1 = grabRail
		railWeld.Parent = seat
	end

	return seat, weld
end

--[[
	Freeze the default walk controller. LabUI owns WASD for the truck; if the
	character can still walk, a failed Sit looks like "I am walking around while
	driving", and falling off-camera paints the Roblox damage vignette.
]]
function StrapperStations:_lockHumanoid(humanoid: Humanoid)
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	humanoid.AutoRotate = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
end

function StrapperStations:_unlockHumanoid(humanoid: Humanoid)
	humanoid.WalkSpeed = 16
	humanoid.JumpPower = 50
	humanoid.JumpHeight = 7.2
	humanoid.AutoRotate = true
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
end

--[[
	A distant respawn (LabSpawn) with WalkSpeed already locked looks like a
	frozen avatar on the pad. Snap the root onto the seat before Sit so the
	character cannot be stranded a route-length away from the truck.
]]
function StrapperStations:_snapToSeat(seat: Seat, humanoid: Humanoid)
	local character = humanoid.Parent
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	if (root.Position - seat.Position).Magnitude < 6 then
		return
	end
	root.CFrame = seat.CFrame + seat.CFrame.UpVector * 2.5
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

--[[
	Sitting a humanoid also hands that player network ownership of the truck,
	which would kill every server-applied force. Ownership is taken straight
	back once the SeatWeld exists, and that reclaim often breaks the weld, so
	we Sit again after. Without the second Sit the avatar walks free while the
	camera and drive inputs still follow the truck.
]]
function StrapperStations:_seat(seat: Seat, humanoid: Humanoid)
	if not seat.Parent or not humanoid.Parent then
		return
	end

	self:_lockHumanoid(humanoid)
	self:_snapToSeat(seat, humanoid)
	seat:Sit(humanoid)

	task.defer(function()
		if not seat.Parent or not humanoid.Parent then
			return
		end
		self.chassisRig:claimOwnership()
		if seat.Occupant ~= humanoid then
			self:_snapToSeat(seat, humanoid)
			seat:Sit(humanoid)
			task.defer(function()
				self.chassisRig:claimOwnership()
			end)
		end
	end)
end

function StrapperStations:isSeated(player: Player): boolean
	local slot = self.slots[player.UserId]
	if not slot or not slot.seat then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and slot.seat.Occupant == humanoid
end

function StrapperStations:isOffTruck(player: Player): boolean
	local slot = self.slots[player.UserId]
	if not slot then
		return false
	end
	if slot.thrown then
		return true
	end
	if slot.respawnBlocked then
		return true
	end
	-- Ignore one-frame SeatWeld drops from claimOwnership; only surface the
	-- HUD warning once soft Sit retries have already failed.
	if self:isSeated(player) then
		return false
	end
	return (slot.missedSeat or 0) >= 2
end

--[[
	Hard recovery used by reset / R during Staging. Clears throw state, snaps
	every living crew member onto their seat, and reclaims ownership.
]]
function StrapperStations:recoverAll()
	for _, id in LabConfig.StationOrder do
		self.cargoLoad:clearWorker(id)
	end
	table.clear(self.occupancy)

	for _, slot in self.slots do
		slot.thrown = false
		slot.thrownUntil = 0
		slot.respawnBlocked = false
		slot.missedSeat = 0
		slot.working = false
		slot.travelElapsed = 0

		local weldLive = slot.weld and slot.weld.Parent
		local seatLive = slot.seat and slot.seat.Parent
		if not weldLive and not seatLive then
			continue
		end

		if slot.role == "Driver" then
			slot.station = nil
			slot.movingTo = nil
			if weldLive then
				slot.weld.C0 = LabConfig.DriverSeatOffset
			end
		else
			local station = slot.station or slot.movingTo
			if not station or self.occupancy[station] then
				station = self:_freeStation()
			end
			slot.station = station
			slot.movingTo = nil
			if station then
				self.occupancy[station] = slot.player.UserId
				if weldLive then
					slot.weld.C0 = LabConfig.StationLocal[station]
				end
			end
		end

		local humanoid = self:_humanoidReady(slot.player)
		if humanoid and seatLive then
			self:_seat(slot.seat, humanoid)
		end
	end
	self.chassisRig:claimOwnership()
end

-- A dead character must not be auto-seated by step() while Roblox is creating
-- its replacement. LabSession clears this through attach() when the truck is
-- safe, or recoverAll() after the wreck has reset in Staging.
function StrapperStations:suspendRespawn(player: Player)
	local slot = self.slots[player.UserId]
	if not slot then
		return
	end
	if slot.station then
		self.cargoLoad:clearWorker(slot.station)
	end
	if slot.movingTo then
		slot.station = slot.movingTo
		slot.movingTo = nil
		slot.travelElapsed = 0
		if slot.weld and slot.weld.Parent and slot.station then
			slot.weld.C0 = LabConfig.StationLocal[slot.station]
		end
	end
	slot.working = false
	slot.thrown = false
	slot.thrownUntil = 0
	slot.respawnBlocked = true
	slot.missedSeat = 0
end

function StrapperStations:_humanoidReady(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	-- Never WaitForChild here: this runs from Heartbeat. A yield mid-step is how
	-- a respawn after a wreck latched the simulation into "Simulation error".
	if not character:FindFirstChild("HumanoidRootPart") then
		return nil
	end
	return humanoid
end

function StrapperStations:attach(player: Player, role: string): boolean
	local chassis = self.chassisRig:getChassis()
	if not chassis or not chassis.Parent then
		return false
	end

	local humanoid = self:_humanoidReady(player)
	if not humanoid then
		return false
	end

	-- Already have a slot: this is a respawn, so put the new character into the
	-- seat that is already welded to the truck rather than building another.
	local existing = self.slots[player.UserId]
	if existing then
		existing.thrown = false
		existing.thrownUntil = 0
		existing.respawnBlocked = false
		existing.missedSeat = 0
		if existing.role == "Strapper" and not existing.station then
			self:_reseat(existing)
		elseif existing.seat and existing.seat.Parent then
			self:_seat(existing.seat, humanoid)
		else
			return false
		end
		return true
	end

	if role == "Driver" then
		local seat, weld = self:_makeSeat("DriverSeat", LabConfig.DriverSeatOffset, 8)
		if not seat or not weld then
			return false
		end
		self.slots[player.UserId] = {
			player = player,
			role = "Driver",
			seat = seat,
			weld = weld,
			station = nil,
			movingTo = nil,
			travelElapsed = 0,
			travelDuration = 0,
			thrown = false,
			thrownUntil = 0,
			working = false,
			respawnBlocked = false,
			lastReseatAt = 0,
		}
		self:_seat(seat, humanoid)
		return true
	end

	local station = self:_freeStation()
	if not station then
		return false
	end

	local offset = LabConfig.StationLocal[station]
	local seat, weld = self:_makeSeat("Station_" .. station, offset, LabConfig.StationSeatDensity)
	if not seat or not weld then
		return false
	end
	self.occupancy[station] = player.UserId
	self.slots[player.UserId] = {
		player = player,
		role = "Strapper",
		seat = seat,
		weld = weld,
		station = station,
		movingTo = nil,
		travelElapsed = 0,
		travelDuration = 0,
		travelFrom = offset,
		thrown = false,
		thrownUntil = 0,
		working = false,
		respawnBlocked = false,
		lastReseatAt = 0,
	}
	self:_seat(seat, humanoid)
	return true
end

function StrapperStations:detach(player: Player)
	local slot = self.slots[player.UserId]
	if not slot then
		return
	end
	if slot.station then
		self.occupancy[slot.station] = nil
		self.cargoLoad:clearWorker(slot.station)
	end
	if slot.movingTo then
		self.occupancy[slot.movingTo] = nil
	end
	if slot.weld then
		slot.weld:Destroy()
	end
	if slot.seat then
		slot.seat:Destroy()
	end
	self.slots[player.UserId] = nil
end

function StrapperStations:getSlot(player: Player)
	return self.slots[player.UserId]
end

function StrapperStations:_rotationPlan()
	local driverId = nil
	local strappers = {}
	for userId, slot in self.slots do
		if slot.role == "Driver" then
			if driverId == nil or tostring(userId) < tostring(driverId) then
				driverId = userId
			end
		elseif slot.role == "Strapper" then
			table.insert(strappers, {
				id = userId,
				station = slot.station or slot.movingTo,
			})
		end
	end
	return CrewRotation.plan(driverId, strappers, LabConfig.StationOrder)
end

function StrapperStations:previewRotationFor(player: Player)
	local assignments = self:_rotationPlan()
	return assignments[player.UserId]
end

--[[
	Apply a SWAP as one server-side transaction. Seats are reused instead of
	destroyed, so the truck never briefly has two Drivers or two owners for the
	same corner. Density moves with the role because station mass is part of the
	truck's handling model.
]]
function StrapperStations:rotateCrew(graceSeconds: number)
	local assignments, newDriverId = self:_rotationPlan()
	if not newDriverId then
		return nil, nil
	end

	for _, id in LabConfig.StationOrder do
		self.cargoLoad:clearWorker(id)
	end
	table.clear(self.occupancy)
	self.rotationGraceUntil = os.clock() + math.max(0, graceSeconds)

	for userId, assignment in assignments do
		local slot = self.slots[userId]
		if not slot then
			continue
		end
		if not slot.seat or not slot.seat.Parent or not slot.weld or not slot.weld.Parent then
			continue
		end

		slot.role = assignment.role
		slot.station = assignment.station
		slot.movingTo = nil
		slot.travelElapsed = 0
		slot.travelDuration = 0
		slot.working = false
		slot.thrown = false
		slot.thrownUntil = 0
		slot.respawnBlocked = false
		slot.missedSeat = 0
		slot.lastReseatAt = 0

		local density = if assignment.role == "Driver" then 8 else LabConfig.StationSeatDensity
		slot.seat.CustomPhysicalProperties = PhysicalProperties.new(density, 0.4, 0, 1, 1)
		if assignment.role == "Driver" then
			slot.seat.Name = "DriverSeat"
			slot.weld.Name = "DriverSeatWeld"
			slot.weld.C0 = LabConfig.DriverSeatOffset
		else
			local station = assignment.station
			if not station then
				continue
			end
			self.occupancy[station] = userId
			slot.seat.Name = "Station_" .. station
			slot.weld.Name = "Station_" .. station .. "Weld"
			slot.weld.C0 = LabConfig.StationLocal[station]
		end

		local humanoid = self:_humanoidReady(slot.player)
		if humanoid then
			self:_seat(slot.seat, humanoid)
		end
	end

	self.chassisRig:claimOwnership()
	return assignments, newDriverId
end

function StrapperStations:requestMove(player: Player, target: string): (boolean, string)
	local slot = self.slots[player.UserId]
	if not slot or slot.role ~= "Strapper" then
		return false, "Only crew on the bed can move stations."
	end
	if slot.thrown then
		return false, "You are still getting back on."
	end
	if slot.movingTo then
		return false, "Already moving."
	end
	if not LabConfig.StationLocal[target] then
		return false, "No such station."
	end
	if slot.station == target then
		return false, "Already there."
	end
	if self.occupancy[target] then
		return false, "Someone is already on that corner."
	end

	local fromCF = if slot.station then LabConfig.StationLocal[slot.station] else LabConfig.StationLocal.FL
	local toCF = LabConfig.StationLocal[target]
	local distance = (toCF.Position - fromCF.Position).Magnitude

	-- Reserve the destination immediately so two crew cannot both commit to it.
	if slot.station then
		self.occupancy[slot.station] = nil
		self.cargoLoad:clearWorker(slot.station)
	end
	self.occupancy[target] = player.UserId

	slot.travelFrom = fromCF
	slot.travelTo = toCF
	slot.travelElapsed = 0
	slot.travelDuration = math.max(LabConfig.TraversalMinSeconds, distance * LabConfig.TraversalSecondsPerStud)
	slot.movingTo = target
	slot.station = nil
	slot.working = false

	-- Crossing the bed routes through the gap ahead of the crate, which is
	-- both the longest trip and the most exposed one.
	local crossing = math.sign(fromCF.Position.X) ~= math.sign(toCF.Position.X)
	local midpoint = (fromCF.Position + toCF.Position) / 2
	slot.travelControl = if crossing
		then Vector3.new(0, 3.6, -1)
		else midpoint + Vector3.new(math.sign(fromCF.Position.X) * 0.8, 1, 0)

	return true, "Moving to " .. target .. "."
end

function StrapperStations:setWorking(player: Player, working: boolean): (boolean, string?)
	local slot = self.slots[player.UserId]
	if not slot or slot.role ~= "Strapper" then
		return false, "Only crew on the bed can work a strap."
	end
	if not working then
		if slot.station then
			self.cargoLoad:clearWorker(slot.station)
		end
		slot.working = false
		return true, nil
	end
	if slot.thrown then
		slot.working = false
		return false, "You are still getting back on."
	end
	if not slot.station then
		slot.working = false
		return false, "You are not at a strap yet."
	end
	slot.working = true
	return true, nil
end

function StrapperStations:_throw(slot)
	local chassis = self.chassisRig:getChassis()
	slot.thrown = true
	slot.thrownUntil = os.clock() + LabConfig.ThrowRecoverySeconds
	slot.working = false
	table.insert(self.pendingThrows, slot.player.Name)

	if slot.movingTo then
		self.occupancy[slot.movingTo] = nil
		slot.movingTo = nil
	end
	if slot.station then
		self.occupancy[slot.station] = nil
		self.cargoLoad:clearWorker(slot.station)
		slot.station = nil
	end

	local character = slot.player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid then
		self:_unlockHumanoid(humanoid)
		humanoid.Sit = false
	end
	if root and root:IsA("BasePart") then
		local away = chassis.CFrame.RightVector * (if math.random() > 0.5 then 1 else -1)
		root.AssemblyLinearVelocity = chassis.AssemblyLinearVelocity * 0.6 + away * 26 + Vector3.new(0, 22, 0)
	end
end

-- A throw is instantaneous, while the thrown state lasts several seconds.
-- Consumers need the edge so telemetry and callouts count it exactly once.
function StrapperStations:consumeThrows(): { string }
	local throws = self.pendingThrows
	if #throws == 0 then
		return throws
	end
	self.pendingThrows = {}
	return throws
end

function StrapperStations:_reseat(slot)
	if not slot.seat or not slot.seat.Parent or not slot.weld or not slot.weld.Parent then
		slot.thrownUntil = os.clock() + 0.5
		return
	end

	local humanoid = self:_humanoidReady(slot.player)
	if not humanoid then
		slot.thrownUntil = os.clock() + 0.5
		return
	end

	-- Drivers go straight back to the wheel. Strappers need a free station.
	if slot.role == "Driver" then
		slot.thrown = false
		slot.missedSeat = 0
		slot.station = nil
		slot.weld.C0 = LabConfig.DriverSeatOffset
		self:_seat(slot.seat, humanoid)
		return
	end

	local station = slot.station or self:_freeStation()
	if not station then
		-- Nowhere to put them yet; try again next frame.
		slot.thrownUntil = os.clock() + 0.5
		return
	end

	slot.thrown = false
	slot.missedSeat = 0
	slot.station = station
	self.occupancy[station] = slot.player.UserId
	slot.weld.C0 = LabConfig.StationLocal[station]
	self:_seat(slot.seat, humanoid)
end

function StrapperStations:step(dt: number)
	local chassis = self.chassisRig:getChassis()
	-- Parked / Result trucks keep stale lateralAccel; never throw while frozen.
	local throwsAllowed = chassis ~= nil and chassis.Parent ~= nil and not chassis.Anchored
	local lateral = if throwsAllowed then math.abs(self.chassisRig.lateralAccel) else 0
	local inRotationGrace = os.clock() < self.rotationGraceUntil

	for _, slot in self.slots do
		if slot.respawnBlocked then
			continue
		end
		local seatLive = slot.seat and slot.seat.Parent
		local weldLive = slot.weld and slot.weld.Parent
		if slot.thrown then
			if os.clock() >= slot.thrownUntil then
				self:_reseat(slot)
			end
			continue
		end

		-- claimOwnership after Sit can break the SeatWeld. Put anyone who
		-- slipped out back in before they walk off-camera and take void damage.
		local humanoid = self:_humanoidReady(slot.player)
		local seated = humanoid and seatLive and slot.seat.Occupant == humanoid
		if seated then
			slot.missedSeat = 0
		elseif seatLive and humanoid and os.clock() - (slot.lastReseatAt or 0) > 0.35 then
			slot.lastReseatAt = os.clock()
			slot.missedSeat = (slot.missedSeat or 0) + 1
			-- After a couple of soft Sit attempts, snap the body onto the seat
			-- so a respawn on LabSpawn cannot leave them frozen off-route.
			if slot.missedSeat >= 2 then
				self:_snapToSeat(slot.seat, humanoid)
			end
			self:_seat(slot.seat, humanoid)
		end

		if slot.role ~= "Strapper" then
			continue
		end

		if slot.movingTo then
			slot.travelElapsed += dt

			-- Caught out of position by a hard direction change.
			if throwsAllowed and not inRotationGrace and lateral > LabConfig.ThrowLateralAccel then
				self:_throw(slot)
				continue
			end

			if not weldLive then
				continue
			end

			local travelDuration = math.max(slot.travelDuration or 0, 1e-3)
			local t = math.clamp(slot.travelElapsed / travelDuration, 0, 1)
			local position = bezier(slot.travelFrom.Position, slot.travelControl, slot.travelTo.Position, t)
			local rotation = if t < 0.5 then slot.travelFrom.Rotation else slot.travelTo.Rotation
			slot.weld.C0 = CFrame.new(position) * rotation

			if t >= 1 then
				slot.station = slot.movingTo
				slot.movingTo = nil
				slot.weld.C0 = slot.travelTo
			end
			continue
		end

		-- Standing at a station and holding the work input.
		if slot.working and slot.station then
			self.cargoLoad:tighten(slot.station, dt, slot.player.Name)
		end

		-- Even braced at a station, a big enough hit puts you over the side.
		if throwsAllowed and not inRotationGrace and lateral > LabConfig.ThrowLateralAccel * 1.55 then
			self:_throw(slot)
		end
	end
end

function StrapperStations:snapshot()
	local list = {}
	for _, slot in self.slots do
		table.insert(list, {
			name = slot.player.Name,
			role = slot.role,
			station = slot.station,
			movingTo = slot.movingTo,
			thrown = slot.thrown,
		})
	end
	table.sort(list, function(a, b)
		return a.name < b.name
	end)
	return list
end

function StrapperStations:reset()
	self:recoverAll()
end

function StrapperStations:reseatAll()
	self:recoverAll()
end

function StrapperStations:destroy()
	for _, slot in self.slots do
		if slot.weld then
			slot.weld:Destroy()
		end
		if slot.seat then
			slot.seat:Destroy()
		end
	end
	self.slots = {}
	self.occupancy = {}
	self.pendingThrows = {}
	self.rotationGraceUntil = 0
end

return StrapperStations
