--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "CargoCatastropheRemotes"

local REMOTE_NAMES = {
	LabSnapshot = "LabSnapshot",
	LabDebug = "LabDebug",
	LabEvent = "LabEvent",
	LabDrive = "LabDrive",
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
local cachedRemotes: { [string]: RemoteEvent } = {}

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
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end
	return folder
end

function Net.get(name: string): RemoteEvent
	local cached = cachedRemotes[name]
	if cached and cached.Parent then
		return cached
	end

	local folder = getFolder()
	local remote = folder:WaitForChild(name, 10)
	assert(remote and remote:IsA("RemoteEvent"), "Missing RemoteEvent: " .. name)
	cachedRemotes[name] = remote
	return remote
end

return Net
