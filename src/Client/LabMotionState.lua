--!strict

--[[
	Latest authoritative LabMotion sample from the server.

	Camera and wheel presentation both need velocity/steer/compression that do
	not come from client AssemblyLinearVelocity on a server-owned chassis.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LabRemotes = require(Shared:WaitForChild("LabRemotes"))
local Net = require(Shared:WaitForChild("Net"))

export type MotionSample = {
	t: number,
	px: number,
	py: number,
	pz: number,
	vx: number,
	vy: number,
	vz: number,
	yaw: number,
	steer: number,
	speed: number,
	cFL: number,
	cFR: number,
	cRL: number,
	cRR: number,
}

local LabMotionState = {}

local latest: MotionSample? = nil
local mounted = false

local function isFinite(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function accept(payload: any): MotionSample?
	if typeof(payload) ~= "table" then
		return nil
	end
	for _, key in
		{
			"t",
			"px",
			"py",
			"pz",
			"vx",
			"vy",
			"vz",
			"yaw",
			"steer",
			"speed",
			"cFL",
			"cFR",
			"cRL",
			"cRR",
		}
	do
		if not isFinite(payload[key]) then
			return nil
		end
	end
	return payload :: MotionSample
end

function LabMotionState.mount()
	if mounted then
		return
	end
	mounted = true
	LabRemotes.onClient(Net.Names.LabMotion, function(payload: any)
		local sample = accept(payload)
		if sample then
			latest = sample
		end
	end)
end

function LabMotionState.get(): MotionSample?
	return latest
end

function LabMotionState.clear()
	latest = nil
end

return LabMotionState
