--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DevConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DevConfig"))
local CommerceService = require(script.Parent.CommerceService)
local PlayerDataService = require(script.Parent.PlayerDataService)

if DevConfig.isRelease() then
	local issues = DevConfig.releaseSafetyIssues()
	assert(#issues == 0, "Unsafe release profile: " .. table.concat(issues, ", "))
end

-- Profiles first, so rewards and cosmetics never race the first run.
PlayerDataService.init()

-- Then commerce, before anything is built. A receipt that arrives before
-- ProcessReceipt is bound gets retried, which the player experiences as a
-- purchase that did nothing for a while.
CommerceService.init()

--[[
	Physics-first public build. Profiles, cosmetics, commerce and achievements
	sit around one truck on one route.
]]
local TruckLab = require(script.Parent.TruckLab)
TruckLab.init()
