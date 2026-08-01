--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DevConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DevConfig"))
local PlayerDataService = require(script.Parent.PlayerDataService)

if DevConfig.isRelease() then
	local issues = DevConfig.releaseSafetyIssues()
	assert(#issues == 0, "Unsafe release profile: " .. table.concat(issues, ", "))
end

-- Both builds now have progression. Initialise profiles before either mode
-- starts assigning players so rewards and cosmetics never race the first run.
PlayerDataService.init()

if DevConfig.isFunTest() then
	--[[
		Physics-first public build. It reuses profiles and cosmetics, while the
		obsolete depot, bays, role kits and leg ladder remain dormant.
	]]
	local TruckLab = require(script.Parent.TruckLab)
	TruckLab.init()
else
	local DepotService = require(script.Parent.DepotService)
	DepotService.init()
end
