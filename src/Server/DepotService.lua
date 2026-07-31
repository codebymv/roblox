--!nonstrict

--[[
	The depot. Owns the world, four bays, and every client request.

	Two structural jobs beyond routing:
	1. Nobody is ever in an empty room. A player with no bay is put on a live one
	   as a spectator, and a new player is auto-crewed into the emptiest bay so
	   they are driving within about ten seconds of spawning.
	2. Other crews are visible. The board and the bay tags are the envy surface
	   that a single-crew-per-server design cannot produce.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local CargoManifest = require(Shared:WaitForChild("CargoManifest"))
local LiveOps = require(Shared:WaitForChild("LiveOps"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))

local CrewMatch = require(script.Parent.CrewMatch)
local EconomyService = require(script.Parent.EconomyService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RateLimiter = require(script.Parent.RateLimiter)
local WorldBuilder = require(script.Parent.WorldBuilder)

local DepotService = {}

local world: WorldBuilder.WorldInfo
local crews: { any } = {}
local spectating: { [number]: number } = {}
local padDebounce: { [number]: number } = {}
local depotDirty = true

--[[
	Every client-to-server remote used to accept unlimited calls. RoleAction is
	the one that actually matters, because each accepted call spawns a
	task.delay, but a shared bucket is cheap enough to put in front of all of
	them. Drive input gets its own, looser bucket since it is sent on a timer.
]]
local driveLimiter = RateLimiter.new(25, 40)
local actionLimiter = RateLimiter.new(10, 15)
local menuLimiter = RateLimiter.new(6, 12)

local function toast(player: Player, message: string)
	Net.get(Net.Names.Toast):FireClient(player, message)
end

local function markDirty()
	depotDirty = true
end

--------------------------------------------------------------------------------
-- Bay lookup
--------------------------------------------------------------------------------

local function crewFor(player: Player): any?
	for _, crew in crews do
		if table.find(crew.members, player) then
			return crew
		end
	end
	return nil
end

local function bestJoinableCrew(): any?
	local best: any? = nil
	for _, crew in crews do
		if crew:isJoinable() then
			if not best or #crew.members < #best.members then
				best = crew
			end
		end
	end
	return best
end

-- The bay worth watching: deepest live convoy, else any crewed bay.
local function bestSpectateCrew(): any?
	local best: any? = nil
	local bestScore = -1
	for _, crew in crews do
		local score = -1
		if crew:isLiveRun() or crew.phase == "BankOrPush" then
			score = 1000 + crew.leg
		elseif #crew.members > 0 then
			score = #crew.members
		end
		if score > bestScore then
			bestScore = score
			best = crew
		end
	end
	return if bestScore >= 0 then best else nil
end

local function clearSpectate(player: Player)
	local bayIndex = spectating[player.UserId]
	if bayIndex and crews[bayIndex] then
		crews[bayIndex]:removeSpectator(player)
	end
	spectating[player.UserId] = nil
end

local function setSpectate(player: Player, bayIndex: number?)
	clearSpectate(player)
	local crew = if bayIndex then crews[bayIndex] else bestSpectateCrew()
	if not crew then
		return
	end
	spectating[player.UserId] = crew.bayIndex
	crew:addSpectator(player)
end

local function joinBay(player: Player, bayIndex: number?): boolean
	local existing = crewFor(player)
	if existing and existing.bayIndex == bayIndex then
		return true
	end

	local crew = if bayIndex then crews[bayIndex] else bestJoinableCrew()
	if not crew then
		toast(player, "No bay is open right now — watching instead.")
		setSpectate(player, nil)
		return false
	end
	if not crew:isJoinable() then
		toast(player, "Bay " .. tostring(crew.bayIndex) .. " is mid-convoy. Watching instead.")
		setSpectate(player, crew.bayIndex)
		return false
	end

	if existing then
		existing:removeMember(player)
	end
	clearSpectate(player)
	local joined = crew:addMember(player)
	markDirty()
	return joined
end

local function leaveBay(player: Player)
	local crew = crewFor(player)
	if crew then
		crew:removeMember(player)
	end
	setSpectate(player, nil)
	markDirty()
end

--------------------------------------------------------------------------------
-- Depot snapshot
--------------------------------------------------------------------------------

local function sortedRows(
	valueFor: (Types.ProfileData) -> number,
	detailFor: (Types.ProfileData) -> string
): { Types.LeaderRow }
	local rows: { Types.LeaderRow } = {}
	for _, player in Players:GetPlayers() do
		local profile = PlayerDataService.get(player)
		if profile then
			table.insert(rows, {
				name = player.Name,
				value = valueFor(profile),
				detail = detailFor(profile),
			})
		end
	end
	table.sort(rows, function(a, b)
		if a.value == b.value then
			return a.name < b.name
		end
		return a.value > b.value
	end)
	while #rows > 5 do
		table.remove(rows)
	end
	return rows
end

local function countJournal(profile: Types.ProfileData): number
	local count = 0
	for _, hauled in profile.manifestJournal do
		if hauled > 0 then
			count += 1
		end
	end
	return count
end

local function buildDepotSnapshot(player: Player): Types.DepotSnapshot
	local profile = PlayerDataService.get(player)
	local crew = crewFor(player)
	local event = LiveOps.getActive()

	local bays: { Types.BayStatus } = {}
	for index, entry in crews do
		bays[index] = entry:getStatus()
	end

	return {
		bays = bays,
		myBay = if crew then crew.bayIndex else nil,
		spectatingBay = spectating[player.UserId],
		credits = if profile then profile.credits else 0,
		streak = if profile then profile.currentStreak else 0,
		bestStreak = if profile then profile.bestStreak else 0,
		bestLeg = if profile then profile.bestLeg else 0,
		bestBankedHaul = if profile then profile.bestBankedHaul else 0,
		lifetimeConvoys = if profile then profile.lifetimeConvoys else 0,
		unlockedKits = if profile then profile.unlockedKits else {},
		equippedKits = if profile then profile.equippedKits else {},
		unlockedPaints = if profile then profile.unlockedPaints else {},
		equippedPaint = if profile then profile.equippedPaint else "Factory",
		journalCount = if profile then countJournal(profile) else 0,
		journalTotal = CargoManifest.count(),
		topStreak = sortedRows(function(data)
			return data.currentStreak
		end, function(data)
			return "best " .. tostring(data.bestStreak)
		end),
		topHaul = sortedRows(function(data)
			return data.bestBankedHaul
		end, function(data)
			return "leg " .. tostring(data.bestLeg)
		end),
		eventLabel = event.label,
		eventBlurb = event.blurb,
		payoutMultiplier = event.payoutMultiplier,
		dailyBonusReady = EconomyService.isDailyReady(player),
		dailyBonusAmount = MatchConfig.DailyBonusCredits,
	}
end

local function broadcastDepot()
	local remote = Net.get(Net.Names.DepotSnapshot)
	for _, player in Players:GetPlayers() do
		remote:FireClient(player, buildDepotSnapshot(player))
	end
end

local function updateBoard()
	local event = LiveOps.getActive()
	world.eventLabel.Text = string.format("%s  ·  payouts x%.2f", event.label, event.payoutMultiplier)

	local lines: { string } = { "LONGEST ACTIVE STREAK" }
	local streaks = sortedRows(function(data)
		return data.currentStreak
	end, function(data)
		return "best " .. tostring(data.bestStreak)
	end)
	if #streaks == 0 then
		table.insert(lines, "  no crews on shift")
	end
	for rank, row in streaks do
		if rank > 3 then
			break
		end
		table.insert(lines, string.format("  %d. %s — %d (%s)", rank, row.name, row.value, row.detail))
	end

	table.insert(lines, "")
	table.insert(lines, "BIGGEST BANKED HAUL")
	local hauls = sortedRows(function(data)
		return data.bestBankedHaul
	end, function(data)
		return "leg " .. tostring(data.bestLeg)
	end)
	if #hauls == 0 then
		table.insert(lines, "  nothing banked yet")
	end
	for rank, row in hauls do
		if rank > 3 then
			break
		end
		table.insert(lines, string.format("  %d. %s — %d cr (%s)", rank, row.name, row.value, row.detail))
	end

	table.insert(lines, "")
	for _, crew in crews do
		local status = crew:getStatus()
		local descriptor = if status.memberCount == 0
			then "open"
			else string.format("%d crew · %s · leg %d", status.memberCount, status.phase, status.leg)
		table.insert(lines, string.format("BAY %d — %s", status.index, descriptor))
	end

	world.boardLabel.Text = table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- Remote handling
--------------------------------------------------------------------------------

local function handlePurchase(player: Player, payload: any)
	if not menuLimiter:allow(player) then
		return
	end
	if typeof(payload) ~= "table" or typeof(payload.id) ~= "string" then
		return
	end
	local ok, message
	if payload.kind == "Paint" then
		ok, message = EconomyService.purchasePaint(player, payload.id)
	else
		ok, message = EconomyService.purchaseKit(player, payload.id)
	end
	toast(player, message)
	if ok then
		markDirty()
	end
end

local function handleEquip(player: Player, payload: any)
	if not menuLimiter:allow(player) then
		return
	end
	if typeof(payload) ~= "table" or typeof(payload.id) ~= "string" then
		return
	end
	local ok, message
	if payload.kind == "Paint" then
		ok, message = EconomyService.equipPaint(player, payload.id)
	else
		ok, message = EconomyService.equipKit(player, payload.id)
	end
	toast(player, message)
	if ok then
		markDirty()
	end
end

local function bindRemotes()
	Net.get(Net.Names.RequestSnapshot).OnServerEvent:Connect(function(player: Player)
		if not menuLimiter:allow(player) then
			return
		end
		Net.get(Net.Names.DepotSnapshot):FireClient(player, buildDepotSnapshot(player))
		local crew = crewFor(player)
		if crew then
			crew:replicateTo(player)
		else
			local index = spectating[player.UserId]
			if index and crews[index] then
				crews[index]:replicateTo(player)
			end
		end
	end)

	Net.get(Net.Names.RequestJoinBay).OnServerEvent:Connect(function(player: Player, bayIndex: unknown)
		if not menuLimiter:allow(player) then
			return
		end
		local index = if typeof(bayIndex) == "number" then math.floor(bayIndex) else nil
		if index and (index < 1 or index > #crews) then
			return
		end
		joinBay(player, index)
	end)

	Net.get(Net.Names.RequestLeaveBay).OnServerEvent:Connect(function(player: Player)
		if not menuLimiter:allow(player) then
			return
		end
		leaveBay(player)
	end)

	Net.get(Net.Names.RequestSpectate).OnServerEvent:Connect(function(player: Player, bayIndex: unknown)
		if not menuLimiter:allow(player) then
			return
		end
		if crewFor(player) then
			return
		end
		local index = if typeof(bayIndex) == "number" then math.floor(bayIndex) else nil
		if index and (index < 1 or index > #crews) then
			return
		end
		setSpectate(player, index)
		markDirty()
	end)

	Net.get(Net.Names.RequestReady).OnServerEvent:Connect(function(player: Player, isReady: unknown)
		if not actionLimiter:allow(player) then
			return
		end
		local crew = crewFor(player)
		if not crew then
			return
		end
		local flag = if typeof(isReady) == "boolean" then isReady else not crew.readyPlayers[player.UserId]
		crew:setReady(player, flag)
	end)

	Net.get(Net.Names.RequestStart).OnServerEvent:Connect(function(player: Player)
		if not actionLimiter:allow(player) then
			return
		end
		local crew = crewFor(player)
		if crew then
			crew:forceStart(player)
		end
	end)

	Net.get(Net.Names.RequestDecision).OnServerEvent:Connect(function(player: Player, choice: unknown)
		if not actionLimiter:allow(player) then
			return
		end
		local crew = crewFor(player)
		if crew and typeof(choice) == "string" then
			crew:vote(player, choice)
		end
	end)

	Net.get(Net.Names.RequestNewConvoy).OnServerEvent:Connect(function(player: Player)
		if not actionLimiter:allow(player) then
			return
		end
		local crew = crewFor(player)
		if crew then
			crew:requestNewConvoy(player)
		end
	end)

	Net.get(Net.Names.RequestPurchase).OnServerEvent:Connect(handlePurchase)
	Net.get(Net.Names.RequestEquip).OnServerEvent:Connect(handleEquip)

	Net.get(Net.Names.RequestDaily).OnServerEvent:Connect(function(player: Player)
		if not menuLimiter:allow(player) then
			return
		end
		local ok, _amount, message = EconomyService.claimDaily(player)
		toast(player, message)
		if ok then
			markDirty()
		end
	end)

	Net.get(Net.Names.DriveInput).OnServerEvent:Connect(function(player: Player, payload: any)
		if not driveLimiter:allow(player) then
			return
		end
		local crew = crewFor(player)
		if crew then
			crew:handleDriveInput(player, payload)
		end
	end)

	Net.get(Net.Names.RoleAction).OnServerEvent:Connect(function(player: Player, action: unknown)
		if not actionLimiter:allow(player) then
			return
		end
		local crew = crewFor(player)
		if crew and typeof(action) == "string" then
			crew:handleRoleAction(player, action)
		end
	end)
end

local function bindPads()
	for _, crew in crews do
		local pad = crew.lane.bayPad
		pad.Touched:Connect(function(hit: BasePart)
			local character = hit.Parent
			local player = if character then Players:GetPlayerFromCharacter(character) else nil
			if not player then
				return
			end
			local now = os.clock()
			if (padDebounce[player.UserId] or 0) > now then
				return
			end
			padDebounce[player.UserId] = now + 1.5
			local current = crewFor(player)
			if current and current.bayIndex == crew.bayIndex then
				return
			end
			joinBay(player, crew.bayIndex)
		end)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	task.spawn(function()
		PlayerDataService.waitFor(player, 12)
		if not player.Parent then
			return
		end
		player:SetAttribute("ConvoyStreak", EconomyService.getStreak(player))

		-- Auto-crew so a first session starts driving instead of reading a lobby.
		if not joinBay(player, nil) then
			setSpectate(player, nil)
		end
		markDirty()
		Net.get(Net.Names.DepotSnapshot):FireClient(player, buildDepotSnapshot(player))
	end)
end

local function onPlayerRemoving(player: Player)
	local crew = crewFor(player)
	if crew then
		crew:removeMember(player)
	end
	clearSpectate(player)
	padDebounce[player.UserId] = nil
	markDirty()
end

function DepotService.init()
	Net.ensureServer()
	world = WorldBuilder.build()

	for index, lane in world.lanes do
		crews[index] = CrewMatch.new(lane, markDirty)
	end

	bindRemotes()
	bindPads()

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	task.spawn(function()
		while true do
			task.wait(1)
			-- Keep bayless players watching whichever convoy is deepest.
			for _, player in Players:GetPlayers() do
				if not crewFor(player) and not spectating[player.UserId] then
					setSpectate(player, nil)
				end
			end
			if depotDirty then
				depotDirty = false
				broadcastDepot()
			end
			updateBoard()
		end
	end)

	print(string.format("[CargoCatastrophe] Depot online — %d bays, event: %s", #crews, LiveOps.getActive().label))
end

function DepotService.getCrewFor(player: Player): any?
	return crewFor(player)
end

return DepotService
