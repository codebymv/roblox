--!strict

--[[
	One route-aware lookup surface for every client presentation system.

	The world now contains multiple authored route folders, but only one is
	active and only that folder owns the live truck. Searching CargoLab's direct
	children was correct for the one-route world and silently stopped finding the
	rig when routes became nested. Recursive name searches are also insufficient:
	both routes have a DeliveryPad, so they can return the inactive destination.
]]

local Workspace = game:GetService("Workspace")

local RigLocator = {}

function RigLocator.worldRoot(): Instance?
	return Workspace:FindFirstChild("CargoLab")
end

function RigLocator.activeRoute(): Instance?
	local root = RigLocator.worldRoot()
	if not root then
		return nil
	end

	local activeId = root:GetAttribute("ActiveRouteId")
	if typeof(activeId) == "string" then
		local route = root:FindFirstChild("Route_" .. activeId)
		if route then
			return route
		end
	end

	for _, child in root:GetChildren() do
		if child:GetAttribute("Active") == true then
			return child
		end
	end
	return nil
end

function RigLocator.find(name: string): Instance?
	local route = RigLocator.activeRoute()
	return if route then route:FindFirstChild(name, true) else nil
end

function RigLocator.truck(): Model?
	local found = RigLocator.find("LabTruck")
	return if found and found:IsA("Model") then found else nil
end

function RigLocator.chassis(): BasePart?
	local truck = RigLocator.truck()
	local chassis = truck and truck:FindFirstChild("Chassis")
	return if chassis and chassis:IsA("BasePart") then chassis else nil
end

function RigLocator.part(name: string): BasePart?
	local found = RigLocator.find(name)
	return if found and found:IsA("BasePart") then found else nil
end

return RigLocator
