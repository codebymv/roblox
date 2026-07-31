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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LabConfig = require(Shared:WaitForChild("LabConfig"))

local StrapperStations = {}
StrapperStations.__index = StrapperStations

function StrapperStations.new(chassisRig, cargoLoad)
	return setmetatable({
		chassisRig = chassisRig,
		cargoLoad = cargoLoad,
		slots = {},
		occupancy = {},
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

function StrapperStations:_makeSeat(name: string, offset: CFrame, density: number): (Seat, Weld)
	local chassis = self.chassisRig:getChassis()

	local seat = Instance.new("Seat")
	seat.Name = name
	seat.Size = LabConfig.StationSeatSize
	seat.Color = Color3.fromRGB(90, 100, 116)
	seat.Material = Enum.Material.DiamondPlate
	seat.Anchored = false
	seat.CanCollide = false
	seat.CustomPhysicalProperties = PhysicalProperties.new(density, 0.4, 0, 1, 1)
	seat.CFrame = chassis.CFrame * offset
	seat.Parent = self.chassisRig:getModel()

	-- A Weld, not a WeldConstraint: C0 is animatable, which is how a crew
	-- member travels the bed without ever leaving the assembly.
	local weld = Instance.new("Weld")
	weld.Name = name .. "Weld"
	weld.Part0 = chassis
	weld.Part1 = seat
	weld.C0 = offset
	weld.Parent = chassis

	return seat, weld
end

--[[
	Sitting a humanoid also hands that player network ownership of the truck,
	which would kill every server-applied force. Ownership is taken straight
	back on the next frame, once the SeatWeld exists.
]]
function StrapperStations:_seat(seat: Seat, humanoid: Humanoid)
	seat:Sit(humanoid)
	task.defer(function()
		self.chassisRig:claimOwnership()
	end)
end

function StrapperStations:attach(player: Player, role: string): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	-- Already have a slot: this is a respawn, so put the new character into the
	-- seat that is already welded to the truck rather than building another.
	local existing = self.slots[player.UserId]
	if existing then
		self:_seat(existing.seat, humanoid)
		return true
	end

	if role == "Driver" then
		local seat, weld = self:_makeSeat("DriverSeat", LabConfig.DriverSeatOffset, 8)
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

function StrapperStations:setWorking(player: Player, working: boolean)
	local slot = self.slots[player.UserId]
	if not slot or slot.role ~= "Strapper" then
		return
	end
	if not working and slot.station then
		self.cargoLoad:clearWorker(slot.station)
	end
	slot.working = working and slot.station ~= nil and not slot.thrown
end

function StrapperStations:_throw(slot)
	local chassis = self.chassisRig:getChassis()
	slot.thrown = true
	slot.thrownUntil = os.clock() + LabConfig.ThrowRecoverySeconds
	slot.working = false

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
		humanoid.Sit = false
	end
	if root and root:IsA("BasePart") then
		local away = chassis.CFrame.RightVector * (if math.random() > 0.5 then 1 else -1)
		root.AssemblyLinearVelocity = chassis.AssemblyLinearVelocity * 0.6 + away * 26 + Vector3.new(0, 22, 0)
	end
end

function StrapperStations:_reseat(slot)
	local station = self:_freeStation()
	if not station then
		-- Nowhere to put them yet; try again next frame.
		slot.thrownUntil = os.clock() + 0.5
		return
	end

	local character = slot.player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		slot.thrownUntil = os.clock() + 0.5
		return
	end

	slot.thrown = false
	slot.station = station
	self.occupancy[station] = slot.player.UserId
	slot.weld.C0 = LabConfig.StationLocal[station]
	self:_seat(slot.seat, humanoid)
end

function StrapperStations:step(dt: number)
	local lateral = math.abs(self.chassisRig.lateralAccel)

	for _, slot in self.slots do
		if slot.thrown then
			if os.clock() >= slot.thrownUntil then
				self:_reseat(slot)
			end
			continue
		end

		if slot.role ~= "Strapper" then
			continue
		end

		if slot.movingTo then
			slot.travelElapsed += dt

			-- Caught out of position by a hard direction change.
			if lateral > LabConfig.ThrowLateralAccel then
				self:_throw(slot)
				continue
			end

			local t = math.clamp(slot.travelElapsed / slot.travelDuration, 0, 1)
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
		if lateral > LabConfig.ThrowLateralAccel * 1.55 then
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
	for _, slot in self.slots do
		slot.thrown = false
		slot.thrownUntil = 0
		slot.movingTo = nil
		slot.working = false
		slot.travelElapsed = 0

		if slot.role == "Driver" then
			slot.weld.C0 = LabConfig.DriverSeatOffset
		elseif slot.station then
			slot.weld.C0 = LabConfig.StationLocal[slot.station]
		end

		local character = slot.player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			self:_seat(slot.seat, humanoid)
		end
	end
end

function StrapperStations:reseatAll()
	for userId, slot in self.slots do
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			continue
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and not slot.thrown then
			self:_seat(slot.seat, humanoid)
		end
	end
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
end

return StrapperStations
