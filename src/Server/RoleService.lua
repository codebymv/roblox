--!nonstrict

--[[
	Role assignment for a single crew. One instance per bay.

	Roles rotate between convoys rather than being sticky, which is the same
	reason MM2 re-rolls its three roles every round: the variety is the content.
	Solo players always get Driver so a first session is never unplayable.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local RoleKits = require(Shared:WaitForChild("RoleKits"))
local Roles = require(Shared:WaitForChild("Roles"))
local Types = require(Shared:WaitForChild("Types"))

local PlayerDataService = require(script.Parent.PlayerDataService)

local RoleService = {}
RoleService.__index = RoleService

function RoleService.new()
	return setmetatable({
		assignments = {} :: { [number]: Types.RoleId },
		kits = {} :: { [Types.RoleId]: string },
		rng = Random.new(),
	}, RoleService)
end

function RoleService:clear()
	for userId in self.assignments do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			player:SetAttribute("CargoRole", nil)
		end
	end
	table.clear(self.assignments)
	table.clear(self.kits)
end

function RoleService:assignForPlayers(players: { Player })
	self:clear()

	local ordered = table.clone(players)
	if #ordered > 1 then
		for index = #ordered, 2, -1 do
			local swap = self.rng:NextInteger(1, index)
			ordered[index], ordered[swap] = ordered[swap], ordered[index]
		end
	end

	local roleList = Roles.assign(#ordered)
	for index, player in ordered do
		local roleId = roleList[index] or "Driver"
		self.assignments[player.UserId] = roleId
		player:SetAttribute("CargoRole", roleId)

		local profile = PlayerDataService.get(player)
		local equipped = if profile then profile.equippedKits[roleId] else nil
		if equipped and (RoleKits.isStarterKit(equipped) or (profile and profile.unlockedKits[equipped])) then
			self.kits[roleId] = equipped
		else
			self.kits[roleId] = RoleKits.starterFor(roleId)
		end
	end
end

function RoleService:getRole(player: Player): Types.RoleId?
	return self.assignments[player.UserId]
end

function RoleService:getAssignmentMap(): { [string]: Types.RoleId }
	local map: { [string]: Types.RoleId } = {}
	for userId, roleId in self.assignments do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			map[player.Name] = roleId
		end
	end
	return map
end

function RoleService:getPlayersWithRole(roleId: Types.RoleId): { Player }
	local result: { Player } = {}
	for userId, assigned in self.assignments do
		if assigned == roleId then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				table.insert(result, player)
			end
		end
	end
	return result
end

function RoleService:hasRole(roleId: Types.RoleId): boolean
	for _, assigned in self.assignments do
		if assigned == roleId then
			return true
		end
	end
	return false
end

function RoleService:getActiveRoles(): { [Types.RoleId]: boolean }
	local result: { [Types.RoleId]: boolean } = {}
	for _, roleId in self.assignments do
		result[roleId] = true
	end
	return result
end

-- Kit effect for whoever is holding a role this convoy.
function RoleService:effectFor(roleId: Types.RoleId?): Types.KitEffect
	if not roleId then
		return {}
	end
	return RoleKits.effectFor(self.kits[roleId])
end

function RoleService:getKitId(roleId: Types.RoleId): string?
	return self.kits[roleId]
end

return RoleService
