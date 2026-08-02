--!strict

--[[
	Local motion for the Holographic finish.

	The server replicates which parts belong to the cosmetic and the paint each
	one started from. Only the hue animation lives here. That keeps an always-on
	visual effect out of replication while still making every client derive the
	same appearance from synchronized server time.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cosmetics = require(Shared:WaitForChild("Cosmetics"))

local RigLocator = require(script.Parent:WaitForChild("RigLocator"))

local HUE_CYCLES_PER_SECOND = 0.08
local REFRESH_SECONDS = 0.25

type AnimatedPart = {
	part: BasePart,
	baseColor: Color3,
	shade: number,
}

local CosmeticPresentation = {}
local mounted = false

function CosmeticPresentation.mount()
	if mounted then
		return
	end
	mounted = true

	local currentTruck: Model? = nil
	local currentRevision: number? = nil
	local animated: { AnimatedPart } = {}
	local refreshAt = 0

	local function rebuild(truck: Model?)
		currentTruck = truck
		currentRevision = if truck then truck:GetAttribute("CosmeticRevision") :: number? else nil
		table.clear(animated)
		if not truck or truck:GetAttribute("CosmeticCycles") ~= true then
			return
		end

		for _, descendant in truck:GetDescendants() do
			if not descendant:IsA("BasePart") or descendant:GetAttribute("CosmeticCycles") ~= true then
				continue
			end
			local baseColor = descendant:GetAttribute("CosmeticBaseColor")
			local shade = descendant:GetAttribute("CosmeticShade")
			if typeof(baseColor) == "Color3" and typeof(shade) == "number" then
				table.insert(animated, {
					part = descendant,
					baseColor = baseColor,
					shade = shade,
				})
			end
		end
	end

	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		local truck = currentTruck
		local revision = if truck and truck.Parent then truck:GetAttribute("CosmeticRevision") :: number? else nil
		if now >= refreshAt or not truck or not truck.Parent or revision ~= currentRevision then
			refreshAt = now + REFRESH_SECONDS
			local found = RigLocator.truck()
			if found ~= currentTruck or (found and found:GetAttribute("CosmeticRevision") ~= currentRevision) then
				rebuild(found)
			end
		end

		if #animated == 0 then
			return
		end
		local phase = (Workspace:GetServerTimeNow() * HUE_CYCLES_PER_SECOND) % 1
		for index = #animated, 1, -1 do
			local entry = animated[index]
			if not entry.part.Parent then
				table.remove(animated, index)
			else
				entry.part.Color = Cosmetics.holographicColor(entry.baseColor, entry.shade, phase)
			end
		end
	end)
end

return CosmeticPresentation
