--!strict

-- Mirrors ReplicatedStorage.LabTuning attributes into the client's LabConfig
-- table during Development. Server and client require separate module copies,
-- so server-side live tuning does not otherwise reach camera/presentation code.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevConfig = require(Shared:WaitForChild("DevConfig"))
local LabConfig = require(Shared:WaitForChild("LabConfig"))
local TuningSchema = require(Shared:WaitForChild("TuningSchema"))

local ClientTuning = {}
local mounted = false

function ClientTuning.mount()
	if mounted or not DevConfig.isDevToolingEnabled() then
		return
	end
	mounted = true

	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("LabTuning", 20)
		if not folder or not folder:IsA("Folder") then
			warn("[Tuning] Client mirror could not find ReplicatedStorage.LabTuning")
			return
		end

		for _, entry in TuningSchema.Entries do
			local function apply()
				local value = folder:GetAttribute(entry.attribute)
				if value ~= nil then
					TuningSchema.set(LabConfig, entry.path, value)
				end
			end
			apply()
			folder:GetAttributeChangedSignal(entry.attribute):Connect(apply)
		end
	end)
end

return ClientTuning
