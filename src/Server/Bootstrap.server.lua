--!strict

local DepotService = require(script.Parent.DepotService)
local PlayerDataService = require(script.Parent.PlayerDataService)

-- Profiles first: the depot auto-crews players as soon as their profile resolves.
PlayerDataService.init()
DepotService.init()
