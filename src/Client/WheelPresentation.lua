--!strict

--[[
	Client-rendered wheel visuals for the server-owned raycast truck.

	The server wheel Parts remain the authoritative suspension targets, but
	anchored Part CFrames replicate in discrete updates. Rendering those Parts
	directly makes them vibrate independently of Roblox's interpolated chassis.
	This module hides them locally, smooths their chassis-relative suspension
	position and steering axis, and integrates spin every render frame.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LabConfig = require(Shared:WaitForChild("LabConfig"))

local WHEEL_IDS = { "FL", "FR", "RL", "RR" }
local POSITION_RATE = 24
local STEERING_RATE = 28
local TARGET_REFRESH_SECONDS = 0.25
local REBUILD_DEBOUNCE_SECONDS = 0.15
local FULL_TURN = 2 * math.pi

type WheelVisual = {
	source: BasePart,
	sourceHub: BasePart?,
	wheel: BasePart,
	hub: BasePart?,
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
	-- Server targets are fully transparent; the client copy must paint itself.
	clone.Transparency = 0
	clone.LocalTransparencyModifier = 0
	clone.Parent = parent
	return clone
end

local function findRig(): (Model?, BasePart?)
	local root = Workspace:FindFirstChild("CargoLab")
	local truck = root and root:FindFirstChild("LabTruck")
	if not truck or not truck:IsA("Model") then
		return nil, nil
	end
	local chassis = truck:FindFirstChild("Chassis")
	if not chassis or not chassis:IsA("BasePart") then
		return nil, nil
	end
	return truck, chassis
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
	local lastBodyPos: Vector3? = nil

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
		lastBodyPos = nil
	end

	local function rebuild(truck: Model, body: BasePart)
		clearVisuals()
		currentTruck = truck
		chassis = body
		lastRebuildAt = os.clock()
		lastBodyPos = body.Position

		for _, id in WHEEL_IDS do
			local source = truck:FindFirstChild("Wheel" .. id)
			if not source or not source:IsA("BasePart") then
				continue
			end
			local sourceHub = source:FindFirstChild("Hub")
			local hubPart = if sourceHub and sourceHub:IsA("BasePart") then sourceHub else nil
			local targetLocal = body.CFrame:ToObjectSpace(source.CFrame)

			source.LocalTransparencyModifier = 1
			if hubPart then
				hubPart.LocalTransparencyModifier = 1
			end

			visuals[id] = {
				source = source,
				sourceHub = hubPart,
				wheel = cloneVisualPart(source, "Wheel" .. id .. "_Visual", folder),
				hub = if hubPart then cloneVisualPart(hubPart, "Hub" .. id .. "_Visual", folder) else nil,
				localPosition = targetLocal.Position,
				localAxle = targetLocal.RightVector,
				spin = 0,
			}
		end
	end

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
			local sourceHub = source:FindFirstChild("Hub")
			if
				not sourceHub
				or not sourceHub:IsA("BasePart")
				or visual.sourceHub ~= sourceHub
				or not visual.hub
				or not visual.hub.Parent
			then
				return true
			end
		end
		return false
	end

	RunService.RenderStepped:Connect(function(dt: number)
		local now = os.clock()
		local needsRefresh = now >= refreshAt
		if not needsRefresh then
			if
				currentTruck
				and (not currentTruck.Parent or not chassis or not chassis.Parent or rigNeedsRebuild(currentTruck))
			then
				needsRefresh = true
			else
				for _, visual in visuals do
					if not visual.source.Parent then
						needsRefresh = true
						break
					end
				end
			end
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

		local positionAlpha = 1 - math.exp(-POSITION_RATE * dt)
		local steeringAlpha = 1 - math.exp(-STEERING_RATE * dt)
		-- Server-owned assemblies often expose sparse AssemblyLinearVelocity on
		-- the client; position delta matches the interpolated chassis motion.
		local bodyPos = body.Position
		local forwardSpeed = 0
		local previousPos = lastBodyPos
		if previousPos and dt > 1e-4 then
			local delta = bodyPos - previousPos
			-- A reset teleports the same truck back to the start, so lifecycle
			-- invalidation cannot catch it by model identity. Treat distances no
			-- physically plausible frame can cover as a new motion sample.
			local maxFrameDistance = math.max(8, LabConfig.MaxForwardSpeed * dt * 3)
			if delta.Magnitude <= maxFrameDistance then
				forwardSpeed = delta:Dot(body.CFrame.LookVector) / dt
			end
		end
		lastBodyPos = bodyPos

		for _, visual in visuals do
			if not visual.source.Parent then
				continue
			end

			local target = body.CFrame:ToObjectSpace(visual.source.CFrame)
			if (target.Position - visual.localPosition).Magnitude > 4 then
				visual.localPosition = target.Position
			else
				visual.localPosition = visual.localPosition:Lerp(target.Position, positionAlpha)
			end

			local targetAxle = target.RightVector
			if visual.localAxle:Dot(targetAxle) < 0 then
				targetAxle = -targetAxle
			end
			local axle = visual.localAxle:Lerp(targetAxle, steeringAlpha)
			visual.localAxle = if axle.Magnitude > 0.001 then axle.Unit else Vector3.xAxis

			-- Build a stable unspun wheel frame. RightVector is the cylinder axle
			-- and is invariant under the server's tread spin, so packet gaps cannot
			-- make interpolation choose the wrong side of a 180-degree rotation.
			local localForward = Vector3.new(0, 0, -1)
			local longitudinal = localForward - visual.localAxle * localForward:Dot(visual.localAxle)
			longitudinal = if longitudinal.Magnitude > 0.001 then longitudinal.Unit else Vector3.new(0, 0, -1)
			local upCross = visual.localAxle:Cross(longitudinal)
			local localUp = if upCross.Magnitude > 0.001 then upCross.Unit else Vector3.yAxis
			visual.spin = (visual.spin + (forwardSpeed / math.max(visual.wheel.Size.Y * 0.5, 0.1)) * dt) % FULL_TURN

			local localFrame = CFrame.fromMatrix(visual.localPosition, visual.localAxle, localUp, -longitudinal)
				* CFrame.Angles(visual.spin, 0, 0)
			local worldFrame = body.CFrame * localFrame
			visual.wheel.CFrame = worldFrame
			if visual.hub then
				visual.hub.CFrame = worldFrame
			end
		end
	end)
end

return WheelPresentation
