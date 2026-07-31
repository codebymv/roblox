--!strict

--[[
	Profile persistence. Every top-performing Roblox experience has state that
	outlives the session; this is ours.

	Contract:
	- Nothing outside this module writes to a profile. Callers use update().
	- A failed load never blocks play: the player gets a volatile profile and we
	  refuse to save over whatever is really in the DataStore.
	- Studio needs Game Settings > Security > Enable Studio Access to API Services
	  for this to hit a real DataStore. Without it we run volatile and say so once.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"))

local PROFILE_VERSION = 1
local STORE_NAME = "CargoCatastropheProfiles_v1"
local AUTOSAVE_SECONDS = 90
local LOAD_ATTEMPTS = 4

type Entry = {
	data: Types.ProfileData,
	dirty: boolean,
	volatile: boolean,
	loaded: boolean,
}

local PlayerDataService = {}

local store: DataStore? = nil
local entries: { [number]: Entry } = {}
local warnedVolatile = false
local started = false

local function defaultProfile(): Types.ProfileData
	return {
		version = PROFILE_VERSION,
		credits = 0,
		lifetimeConvoys = 0,
		lifetimeLegs = 0,
		lifetimeBanked = 0,
		bestLeg = 0,
		bestBankedHaul = 0,
		currentStreak = 0,
		bestStreak = 0,
		unlockedKits = {},
		equippedKits = {},
		unlockedPaints = {},
		equippedPaint = "Factory",
		manifestJournal = {},
		lastDailyDay = 0,
	}
end

-- Fills in fields added by later versions without clobbering saved values.
local function reconcile(raw: any): Types.ProfileData
	local profile = defaultProfile()
	if typeof(raw) ~= "table" then
		return profile
	end
	for key, fallback in profile :: any do
		local saved = (raw :: any)[key]
		if typeof(saved) == typeof(fallback) then
			(profile :: any)[key] = saved
		end
	end
	profile.version = PROFILE_VERSION
	return profile
end

local function keyFor(userId: number): string
	return "u_" .. tostring(userId)
end

local function getStore(): DataStore?
	if store then
		return store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok and result then
		store = result
		return result
	end
	return nil
end

local function markVolatile(entry: Entry, reason: string)
	entry.volatile = true
	if not warnedVolatile then
		warnedVolatile = true
		warn(
			"[CargoCatastrophe] Profiles are running volatile (no saving): "
				.. reason
				.. ". In Studio, enable Game Settings > Security > Enable Studio Access to API Services."
		)
	end
end

local function loadProfile(player: Player): Entry
	local entry: Entry = {
		data = defaultProfile(),
		dirty = false,
		volatile = false,
		loaded = false,
	}
	entries[player.UserId] = entry

	local dataStore = getStore()
	if not dataStore then
		markVolatile(entry, "DataStoreService unavailable")
		entry.loaded = true
		return entry
	end

	local lastError: string? = nil
	for attempt = 1, LOAD_ATTEMPTS do
		local ok, result = pcall(function()
			return dataStore:GetAsync(keyFor(player.UserId))
		end)
		if ok then
			entry.data = reconcile(result)
			entry.loaded = true
			return entry
		end
		lastError = tostring(result)
		task.wait(attempt * 0.75)
	end

	markVolatile(entry, lastError or "GetAsync failed")
	entry.loaded = true
	return entry
end

local function saveEntry(userId: number, entry: Entry): boolean
	if entry.volatile or not entry.dirty then
		return false
	end
	local dataStore = getStore()
	if not dataStore then
		return false
	end
	local snapshot = entry.data
	local ok, err = pcall(function()
		dataStore:UpdateAsync(keyFor(userId), function()
			return snapshot
		end)
	end)
	if ok then
		entry.dirty = false
		return true
	end
	warn("[CargoCatastrophe] Profile save failed for " .. tostring(userId) .. ": " .. tostring(err))
	return false
end

function PlayerDataService.get(player: Player): Types.ProfileData?
	local entry = entries[player.UserId]
	return if entry then entry.data else nil
end

-- Blocks until the profile is resolved. Safe to call from any server thread.
function PlayerDataService.waitFor(player: Player, timeoutSeconds: number?): Types.ProfileData?
	local deadline = os.clock() + (timeoutSeconds or 10)
	while os.clock() < deadline do
		local entry = entries[player.UserId]
		if entry and entry.loaded then
			return entry.data
		end
		if not player.Parent then
			return nil
		end
		task.wait(0.1)
	end
	local entry = entries[player.UserId]
	return if entry then entry.data else nil
end

--[[
	The only write path. The mutator receives the live profile table; any change
	marks it dirty for the next autosave.
]]
function PlayerDataService.update(player: Player, mutator: (Types.ProfileData) -> ()): Types.ProfileData?
	local entry = entries[player.UserId]
	if not entry then
		return nil
	end
	mutator(entry.data)
	entry.dirty = true
	return entry.data
end

function PlayerDataService.isVolatile(player: Player): boolean
	local entry = entries[player.UserId]
	return entry == nil or entry.volatile
end

function PlayerDataService.flush(player: Player)
	local entry = entries[player.UserId]
	if entry then
		saveEntry(player.UserId, entry)
	end
end

function PlayerDataService.init()
	if started then
		return
	end
	started = true

	local function onPlayerAdded(player: Player)
		task.spawn(loadProfile, player)
	end

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)

	Players.PlayerRemoving:Connect(function(player: Player)
		local userId = player.UserId
		-- Deferred so other PlayerRemoving handlers (crew cleanup, streak reset)
		-- get their last writes in before the profile leaves the cache.
		task.defer(function()
			local entry = entries[userId]
			entries[userId] = nil
			if entry then
				saveEntry(userId, entry)
			end
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_SECONDS)
			for userId, entry in entries do
				saveEntry(userId, entry)
			end
		end
	end)

	game:BindToClose(function()
		if RunService:IsStudio() then
			return
		end
		for userId, entry in entries do
			saveEntry(userId, entry)
		end
		task.wait(1)
	end)

	print("[CargoCatastrophe] PlayerDataService ready")
end

return PlayerDataService
