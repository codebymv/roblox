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
	pitch: number,
	steer: number,
	speed: number,
	ax: number,
	ay: number,
	az: number,
	cFL: number,
	cFR: number,
	cRL: number,
	cRR: number,
}

export type ResolvedMotion = {
	sample: MotionSample,
	position: Vector3,
	velocity: Vector3,
	forward: Vector3,
	age: number,
	suspensionEnergy: number,
	acceleration: number,
}

local LabMotionState = {}

local latest: MotionSample? = nil
local previous: MotionSample? = nil
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
			"pitch",
			"steer",
			"speed",
			"ax",
			"ay",
			"az",
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
		-- Unreliable samples may be dropped or reordered. A stale packet must not
		-- pull the camera backward after a newer one has already been presented.
		if sample and (not latest or sample.t > latest.t) then
			previous = latest
			latest = sample
		end
	end)
end

function LabMotionState.get(): MotionSample?
	return latest
end

function LabMotionState.resolve(serverNow: number, maxLead: number, staleSeconds: number): ResolvedMotion?
	local sample = latest
	if not sample then
		return nil
	end
	local rawAge = serverNow - sample.t
	if rawAge > math.max(0, staleSeconds) then
		return nil
	end
	local age = math.clamp(rawAge, 0, math.max(0, maxLead))
	local velocity = Vector3.new(sample.vx, sample.vy, sample.vz)
	local position = Vector3.new(sample.px, sample.py, sample.pz) + velocity * age
	local forward = Vector3.new(math.sin(sample.yaw), 0, math.cos(sample.yaw))
	forward = if forward.Magnitude > 0.001 then forward.Unit else Vector3.new(0, 0, 1)

	local suspensionEnergy = 0
	local before = previous
	if before then
		local sampleDt = sample.t - before.t
		if sampleDt > 1e-4 then
			local fl = (sample.cFL - before.cFL) / sampleDt
			local fr = (sample.cFR - before.cFR) / sampleDt
			local rl = (sample.cRL - before.cRL) / sampleDt
			local rr = (sample.cRR - before.cRR) / sampleDt
			suspensionEnergy = math.sqrt((fl * fl + fr * fr + rl * rl + rr * rr) / 4)
		end
	end

	return {
		sample = sample,
		position = position,
		velocity = velocity,
		forward = forward,
		age = age,
		suspensionEnergy = suspensionEnergy,
		acceleration = Vector3.new(sample.ax, sample.ay, sample.az).Magnitude,
	}
end

function LabMotionState.clear()
	latest = nil
	previous = nil
end

return LabMotionState
