--!nonstrict

--[[
	The wire contract for the fun-test build.

	Net.get hands back a bare RemoteEvent, which meant every handler opened
	with its own hand-rolled typeof checks and every client sent whatever shape
	it felt like. The payload type existed only as a comment, and LabUI typed
	its snapshot handler as `any` while LabTypes.LabSnapshot sat unused.

	Each client-to-server remote is declared here once, with a validator that
	either returns a clean, clamped payload or returns nil. Handlers receive
	values that have already been checked, so a malformed or hostile payload is
	dropped at the boundary rather than inside gameplay code.

	Validators return nil to reject. They must therefore never return nil as a
	success value, which is why the boolean remotes return a table.
]]

local Net = require(script.Parent.Net)
local LabConfig = require(script.Parent.LabConfig)
local RoleKits = require(script.Parent.RoleKits)

local LabRemotes = {}

export type DrivePayload = {
	throttle: number,
	steering: number,
	braking: boolean,
}

export type MovePayload = { station: string }
export type WorkPayload = { working: boolean }
export type FeedbackPayload = { answer: "Yes" | "Maybe" | "No" }
export type PaintPayload = { paintId: string }
export type EmptyPayload = {}

export type DevPayload = {
	command: string,
	progress: number?,
	from: number?,
	direction: number?,
}

local function isFinite(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isStation(value: any): boolean
	if typeof(value) ~= "string" then
		return false
	end
	return table.find(LabConfig.StationOrder, value) ~= nil
end

--[[
	One entry per client-to-server remote. Anything not listed cannot be bound
	through this module, which is the point: a new remote has to declare what
	it accepts before it can accept anything.
]]
local validators: { [string]: (any) -> any } = {
	[Net.Names.LabDrive] = function(payload: any): DrivePayload?
		if typeof(payload) ~= "table" then
			return nil
		end
		if not isFinite(payload.throttle) or not isFinite(payload.steering) then
			return nil
		end
		if typeof(payload.braking) ~= "boolean" then
			return nil
		end
		return {
			throttle = math.clamp(payload.throttle, -1, 1),
			steering = math.clamp(payload.steering, -1, 1),
			braking = payload.braking,
		}
	end,

	[Net.Names.LabMoveTo] = function(payload: any): MovePayload?
		if not isStation(payload) then
			return nil
		end
		return { station = payload }
	end,

	[Net.Names.LabWork] = function(payload: any): WorkPayload?
		if typeof(payload) ~= "boolean" then
			return nil
		end
		return { working = payload }
	end,

	[Net.Names.LabRestart] = function(): EmptyPayload
		return {}
	end,

	[Net.Names.LabSwitchRole] = function(): EmptyPayload
		return {}
	end,

	[Net.Names.LabFeedback] = function(payload: any): FeedbackPayload?
		if payload ~= "Yes" and payload ~= "Maybe" and payload ~= "No" then
			return nil
		end
		return { answer = payload }
	end,

	[Net.Names.LabPaint] = function(payload: any): PaintPayload?
		if typeof(payload) ~= "string" or not RoleKits.getPaint(payload) then
			return nil
		end
		return { paintId = payload }
	end,

	[Net.Names.LabDevCommand] = function(payload: any): DevPayload?
		if typeof(payload) ~= "table" or typeof(payload.command) ~= "string" then
			return nil
		end
		local result: DevPayload = { command = payload.command }

		if payload.progress ~= nil then
			if not isFinite(payload.progress) then
				return nil
			end
			result.progress = math.clamp(payload.progress, 0, 1)
		end
		if payload.from ~= nil then
			if not isFinite(payload.from) then
				return nil
			end
			result.from = math.clamp(payload.from, 0, 1)
		end
		if payload.direction ~= nil then
			if not isFinite(payload.direction) then
				return nil
			end
			result.direction = math.sign(payload.direction)
		end

		return result
	end,
}

LabRemotes.Names = Net.Names

--[[
	Binds a server handler behind this remote's validator. The handler is only
	reached with a payload that has already passed, so it can index fields
	without guarding them.
]]
function LabRemotes.bindServer(name: string, handler: (Player, any) -> ()): RBXScriptConnection
	local validate = validators[name]
	assert(validate, "No validator declared for remote: " .. tostring(name))

	return Net.get(name).OnServerEvent:Connect(function(player: Player, payload: any)
		local value = validate(payload)
		if value == nil then
			return
		end
		handler(player, value)
	end)
end

function LabRemotes.fireServer(name: string, payload: any?)
	Net.get(name):FireServer(payload)
end

function LabRemotes.fireClient(name: string, player: Player, payload: any)
	Net.get(name):FireClient(player, payload)
end

function LabRemotes.fireAllClients(name: string, payload: any)
	Net.get(name):FireAllClients(payload)
end

function LabRemotes.onClient(name: string, handler: (any) -> ()): RBXScriptConnection
	return Net.get(name).OnClientEvent:Connect(handler)
end

-- Exposed so the smoke test can exercise the validators without a live player.
function LabRemotes.validate(name: string, payload: any): any
	local validate = validators[name]
	assert(validate, "No validator declared for remote: " .. tostring(name))
	return validate(payload)
end

return LabRemotes
