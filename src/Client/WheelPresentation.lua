--!strict

--[[
	Client-rendered wheel visuals for the server-owned raycast truck.

	Source Wheel* Parts are cloned once for mesh/material, then ignored for pose.
	Each frame places visuals from chassis × LabConfig mounts × LabMotion
	steer/compression so anchored-part replication cannot hitch the suspension.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LabConfig = require(Shared:WaitForChild("LabConfig"))

local LabMotionState = require(script.Parent:WaitForChild("LabMotionState"))
local RigLocator = require(script.Parent:WaitForChild("RigLocator"))

local WHEEL_IDS = { "FL", "FR", "RL", "RR" }
local POSITION_RATE = 24
local STEERING_RATE = 28
local SPEED_RATE = 16
local TARGET_REFRESH_SECONDS = 0.25
local REBUILD_DEBOUNCE_SECONDS = 0.15
local FULL_TURN = 2 * math.pi

type WheelVisual = {
	source: BasePart,
	sourceHub: BasePart?,
	wheel: BasePart,
	hub: BasePart?,
	steer: boolean,
	localPosition: Vector3,
	localAxle: Vector3,
	spin: number,
}

local WheelPresentation = {}
local mounted = false

local function cloneVisualPart(source: BasePart, name: string, parent: Instance): BasePart
	local clone = source:Clone()
	for _, child in clone:GetChildren() do
		child:Destroy()
	end
	clone.Name = name
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanTouch = false
	clone.CanQuery = false
	clone.CastShadow = source.CastShadow
	clone.Transparency = 0
	clone.LocalTransparencyModifier = 0
	clone.Parent = parent
	return clone
end

local function findRig(): (Model?, BasePart?)
	local truck = RigLocator.truck()
	if not truck then
		return nil, nil
	end
	local chassis = truck:FindFirstChild("Chassis")
	if not chassis or not chassis:IsA("BasePart") then
		return nil, nil
	end
	return truck, chassis
end

local function compressionFor(id: string): number
	local motion = LabMotionState.get()
	if not motion then
		return LabConfig.SuspensionStaticCompression
	end
	if id == "FL" then
		return math.clamp(motion.cFL, 0, 1)
	elseif id == "FR" then
		return math.clamp(motion.cFR, 0, 1)
	elseif id == "RL" then
		return math.clamp(motion.cRL, 0, 1)
	end
	return math.clamp(motion.cRR, 0, 1)
end

local function targetWheelLocal(bodyFrame: CFrame, id: string, steerAngle: number): (Vector3, Vector3)
	local offset = LabConfig.WheelOffsets[id]
	local steer = id == "FL" or id == "FR"
	local compression = compressionFor(id)
	local travel = LabConfig.SuspensionRestLength * (1 - compression) - LabConfig.WheelRadius
	local steerRotation = if steer then CFrame.Angles(0, steerAngle, 0) else CFrame.identity
	local mountCF = bodyFrame * CFrame.new(offset) * steerRotation
	local center = mountCF.Position - mountCF.UpVector * math.max(0, travel)
	local localFrame =
		bodyFrame:ToObjectSpace(CFrame.fromMatrix(center, mountCF.RightVector, mountCF.UpVector, -mountCF.LookVector))
	return localFrame.Position, localFrame.RightVector
end

function WheelPresentation.mount()
	if mounted then
		return
	end
	mounted = true

	local existing = Workspace:FindFirstChild("CargoWheelVisuals")
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "CargoWheelVisuals"
	folder.Parent = Workspace

	local currentTruck: Model? = nil
	local chassis: BasePart? = nil
	local visuals: { [string]: WheelVisual } = {}
	local refreshAt = 0
	local lastRebuildAt = 0
	local smoothedForwardSpeed = 0

	local function clearVisuals()
		for _, visual in visuals do
			if visual.source and visual.source.Parent then
				visual.source.LocalTransparencyModifier = 0
			end
			if visual.sourceHub and visual.sourceHub.Parent then
				visual.sourceHub.LocalTransparencyModifier = 0
			end
		end
		table.clear(visuals)
		folder:ClearAllChildren()
		smoothedForwardSpeed = 0
	end

	local function rebuild(truck: Model, body: BasePart)
		clearVisuals()
		currentTruck = truck
		chassis = body
		lastRebuildAt = os.clock()

		local motion = LabMotionState.get()
		local steerAngle = if motion then motion.steer else 0
		local bodyFrame = body:GetRenderCFrame()
		smoothedForwardSpeed = if motion
			then motion.vx * bodyFrame.LookVector.X + motion.vz * bodyFrame.LookVector.Z
			else 0

		for _, id in WHEEL_IDS do
			local source = truck:FindFirstChild("Wheel" .. id)
			if not source or not source:IsA("BasePart") then
				continue
			end
			local sourceHub = source:FindFirstChild("Hub")
			local hubPart = if sourceHub and sourceHub:IsA("BasePart") then sourceHub else nil
			local localPosition, localAxle = targetWheelLocal(bodyFrame, id, steerAngle)

			source.LocalTransparencyModifier = 1
			if hubPart then
				hubPart.LocalTransparencyModifier = 1
			end

			visuals[id] = {
				source = source,
				sourceHub = hubPart,
				wheel = cloneVisualPart(source, "Wheel" .. id .. "_Visual", folder),
				hub = if hubPart then cloneVisualPart(hubPart, "Hub" .. id .. "_Visual", folder) else nil,
				steer = id == "FL" or id == "FR",
				localPosition = localPosition,
				localAxle = localAxle,
				spin = 0,
			}
		end
	end

	-- Identity / Parent only. Compression changes must not destroy clones.
	local function rigNeedsRebuild(truck: Model): boolean
		for _, id in WHEEL_IDS do
			local source = truck:FindFirstChild("Wheel" .. id)
			if not source or not source:IsA("BasePart") then
				return true
			end
			local visual = visuals[id]
			if not visual or visual.source ~= source or not visual.wheel.Parent then
				return true
			end
			if not visual.source.Parent then
				return true
			end
		end
		return false
	end

	RunService.RenderStepped:Connect(function(dt: number)
		local now = os.clock()
		local needsRefresh = now >= refreshAt
		if
			not needsRefresh
			and currentTruck
			and (not currentTruck.Parent or not chassis or not chassis.Parent or rigNeedsRebuild(currentTruck))
		then
			needsRefresh = true
		end
		if needsRefresh then
			refreshAt = now + TARGET_REFRESH_SECONDS
			local foundTruck, foundChassis = findRig()
			if
				foundTruck ~= currentTruck
				or foundChassis ~= chassis
				or (foundTruck ~= nil and rigNeedsRebuild(foundTruck))
			then
				if foundTruck and foundChassis then
					local identityChanged = foundTruck ~= currentTruck or foundChassis ~= chassis
					if identityChanged or now - lastRebuildAt >= REBUILD_DEBOUNCE_SECONDS then
						rebuild(foundTruck, foundChassis)
					end
				else
					clearVisuals()
					currentTruck = nil
					chassis = nil
				end
			end
		end

		local body = chassis
		if not body or not body.Parent then
			return
		end

		local motion = LabMotionState.get()
		local steerAngle = if motion then motion.steer else 0
		-- Visual wheels must share the chassis' rendered timeline. Using body.CFrame
		-- here causes the clones to advance in packet-sized steps against Roblox's
		-- interpolated chassis even when the underlying physics is smooth.
		local bodyFrame = body:GetRenderCFrame()
		local look = bodyFrame.LookVector
		local targetForwardSpeed = if motion then motion.vx * look.X + motion.vy * look.Y + motion.vz * look.Z else 0
		local speedAlpha = 1 - math.exp(-SPEED_RATE * dt)
		smoothedForwardSpeed += (targetForwardSpeed - smoothedForwardSpeed) * speedAlpha
		local forwardSpeed = smoothedForwardSpeed

		local positionAlpha = 1 - math.exp(-POSITION_RATE * dt)
		local steeringAlpha = 1 - math.exp(-STEERING_RATE * dt)

		for id, visual in visuals do
			if not visual.source.Parent then
				continue
			end

			local targetPos, targetAxle = targetWheelLocal(bodyFrame, id, steerAngle)
			if (targetPos - visual.localPosition).Magnitude > 4 then
				visual.localPosition = targetPos
			else
				visual.localPosition = visual.localPosition:Lerp(targetPos, positionAlpha)
			end

			if visual.localAxle:Dot(targetAxle) < 0 then
				targetAxle = -targetAxle
			end
			local axle = visual.localAxle:Lerp(targetAxle, steeringAlpha)
			visual.localAxle = if axle.Magnitude > 0.001 then axle.Unit else Vector3.xAxis

			local localForward = Vector3.new(0, 0, -1)
			local longitudinal = localForward - visual.localAxle * localForward:Dot(visual.localAxle)
			longitudinal = if longitudinal.Magnitude > 0.001 then longitudinal.Unit else Vector3.new(0, 0, -1)
			local upCross = visual.localAxle:Cross(longitudinal)
			local localUp = if upCross.Magnitude > 0.001 then upCross.Unit else Vector3.yAxis
			visual.spin = (visual.spin + (forwardSpeed / math.max(visual.wheel.Size.Y * 0.5, 0.1)) * dt) % FULL_TURN

			local localFrame = CFrame.fromMatrix(visual.localPosition, visual.localAxle, localUp, -longitudinal)
				* CFrame.Angles(visual.spin, 0, 0)
			local worldFrame = bodyFrame * localFrame
			visual.wheel.CFrame = worldFrame
			if visual.hub then
				visual.hub.CFrame = worldFrame
			end
		end
	end)
end

return WheelPresentation
