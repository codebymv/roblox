--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FOLDER_NAME = "CargoCatastropheRemotes"

local REMOTE_NAMES = {
	-- Server to client state
	CrewSnapshot = "CrewSnapshot",
	DepotSnapshot = "DepotSnapshot",
	FailurePrompt = "FailurePrompt",
	CargoReveal = "CargoReveal",
	Toast = "Toast",

	-- Client intent
	RequestSnapshot = "RequestSnapshot",
	RequestJoinBay = "RequestJoinBay",
	RequestLeaveBay = "RequestLeaveBay",
	RequestSpectate = "RequestSpectate",
	RequestReady = "RequestReady",
	RequestStart = "RequestStart",
	RequestDecision = "RequestDecision",
	RequestNewConvoy = "RequestNewConvoy",
	RequestPurchase = "RequestPurchase",
	RequestEquip = "RequestEquip",
	RequestDaily = "RequestDaily",
	RoleAction = "RoleAction",
	DriveInput = "DriveInput",

	-- Fun-test build. Unused when DevConfig.Mode is "Depot".
	LabSnapshot = "LabSnapshot",
	LabDebug = "LabDebug",
	LabEvent = "LabEvent",
	LabDrive = "LabDrive",
	LabMoveTo = "LabMoveTo",
	LabWork = "LabWork",
	LabRestart = "LabRestart",
	LabSwitchRole = "LabSwitchRole",
}

local Net = {
	Names = REMOTE_NAMES,
}

local function getFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if folder and folder:IsA("Folder") then
		return folder
	end

	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = ReplicatedStorage
	return created
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
	local folder = getFolder()
	local remote = folder:WaitForChild(name, 10)
	assert(remote and remote:IsA("RemoteEvent"), "Missing RemoteEvent: " .. name)
	return remote
end

return Net
