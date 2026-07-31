--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DevConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DevConfig"))

if DevConfig.isFunTest() then
	--[[
		Fun-test build. The depot, the economy and persistence are not deleted,
		they simply never initialise, so there is no DataStore traffic and no
		meta systems standing between a player and the truck.
	]]
	local TruckLab = require(script.Parent.TruckLab)
	TruckLab.init()
else
	local DepotService = require(script.Parent.DepotService)
	local PlayerDataService = require(script.Parent.PlayerDataService)

	-- Profiles first: the depot auto-crews players as soon as their profile resolves.
	PlayerDataService.init()
	DepotService.init()
end
