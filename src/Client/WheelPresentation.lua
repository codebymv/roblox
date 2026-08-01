--!strict

--[[
	Client-rendered wheel visuals for the server-owned raycast truck.

	The server wheel Parts remain the authoritative suspension targets, but
	anchored Part CFrames replicate in discrete updates. Rendering those Parts
	directly makes them vibrate independently of Roblox's interpolated chassis.
	This module hides them locally, smooths their chassis-relative suspension
	position and steering axis, and integrates spin every render frame.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WHEEL_IDS = { "FL", "FR", "RL", "RR" }
local POSITION_RATE = 24
local STEERING_RATE = 28
local TARGET_REFRESH_SECONDS = 0.25
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
	end

	local function rebuild(truck: Model, body: BasePart)
		clearVisuals()
		currentTruck = truck
		chassis = body

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
		if now >= refreshAt then
			refreshAt = now + TARGET_REFRESH_SECONDS
			local foundTruck, foundChassis = findRig()
			if
				foundTruck ~= currentTruck
				or foundChassis ~= chassis
				or (foundTruck ~= nil and rigNeedsRebuild(foundTruck))
			then
				if foundTruck and foundChassis then
					rebuild(foundTruck, foundChassis)
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
		local forwardSpeed = body.AssemblyLinearVelocity:Dot(body.CFrame.LookVector)

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
			local localUp = visual.localAxle:Cross(longitudinal).Unit
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
