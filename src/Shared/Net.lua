--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "CargoCatastropheRemotes"

local REMOTE_NAMES = {
	LabSnapshot = "LabSnapshot",
	LabDebug = "LabDebug",
	LabEvent = "LabEvent",
	LabDrive = "LabDrive",
	-- Authoritative chassis motion for client camera/wheels (server → clients).
	LabMotion = "LabMotion",
	LabMoveTo = "LabMoveTo",
	LabWork = "LabWork",
	LabRestart = "LabRestart",
	LabSwitchRole = "LabSwitchRole",
	LabFeedback = "LabFeedback",
	LabContractVote = "LabContractVote",
	LabInvite = "LabInvite",
	LabPurchase = "LabPurchase",
	LabPaint = "LabPaint",
	LabDevCommand = "LabDevCommand",
}

-- Droppable high-rate samples; missing a packet must not stall gameplay.
local UNRELIABLE_REMOTES: { [string]: boolean } = {
	[REMOTE_NAMES.LabMotion] = true,
}

export type AnyRemote = RemoteEvent | UnreliableRemoteEvent

local Net = {
	Names = REMOTE_NAMES,
}

--[[
	Both the folder and each remote are cached after first resolution. Net.get
	used to walk ReplicatedStorage on every call, which the snapshot broadcast
	and every toast paid for.

	Only the server may create the folder. The client waiting for replication
	is correct; the client creating its own empty folder is not, and the old
	code did exactly that whenever a client got here before replication landed,
	leaving it waiting on a remote that would never arrive.
]]
local isServer = RunService:IsServer()

local cachedFolder: Folder? = nil
local cachedRemotes: { [string]: AnyRemote } = {}

local function isRemote(instance: Instance): boolean
	return instance:IsA("RemoteEvent") or instance:IsA("UnreliableRemoteEvent")
end

local function createRemote(name: string): AnyRemote
	local remote: AnyRemote = if UNRELIABLE_REMOTES[name]
		then Instance.new("UnreliableRemoteEvent")
		else Instance.new("RemoteEvent")
	remote.Name = name
	return remote
end

local function getFolder(): Folder
	local cached = cachedFolder
	if cached and cached.Parent then
		return cached
	end

	local found = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if not found then
		if isServer then
			local created = Instance.new("Folder")
			created.Name = FOLDER_NAME
			created.Parent = ReplicatedStorage
			found = created
		else
			found = ReplicatedStorage:WaitForChild(FOLDER_NAME, 20)
		end
	end

	assert(found and found:IsA("Folder"), "Remote folder never replicated: " .. FOLDER_NAME)
	cachedFolder = found
	return found
end

function Net.ensureServer(): Folder
	local folder = getFolder()
	for _, name in pairs(REMOTE_NAMES) do
		local existing = folder:FindFirstChild(name)
		local wantsUnreliable = UNRELIABLE_REMOTES[name] == true
		local wrongKind = existing ~= nil
			and (
				(wantsUnreliable and not existing:IsA("UnreliableRemoteEvent"))
				or (not wantsUnreliable and not existing:IsA("RemoteEvent"))
			)
		if not existing or wrongKind then
			if existing then
				-- Rolling publish: replace leftover reliable/unreliable mismatch.
				existing:Destroy()
			end
			local remote = createRemote(name)
			remote.Parent = folder
		end
	end
	return folder
end

function Net.get(name: string): AnyRemote
	local cached = cachedRemotes[name]
	if cached and cached.Parent then
		return cached
	end

	local folder = getFolder()
	local remote = folder:WaitForChild(name, 10)
	assert(remote and isRemote(remote), "Missing remote: " .. name)
	cachedRemotes[name] = remote :: AnyRemote
	return remote :: AnyRemote
end

return Net
