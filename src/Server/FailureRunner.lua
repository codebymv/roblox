--!nonstrict

--[[
	Drives one crew's failure cadence. One instance per bay.

	Pressure divides the interval between failures; window scale multiplies the
	response window. Role kits add a flat bonus on top of the window for the role
	that owns the failure, which is how a kit helps without removing the input.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Failures = require(Shared:WaitForChild("Failures"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Types = require(Shared:WaitForChild("Types"))

export type ActiveFailure = {
	def: Types.FailureDef,
	expiresAt: number,
	resolved: boolean,
	cascaded: boolean,
	token: number,
}

export type FailureCallbacks = {
	onPrompt: (def: Types.FailureDef, expiresAt: number) -> (),
	onResolved: (def: Types.FailureDef) -> (),
	onCascade: (def: Types.FailureDef) -> (),
	onToast: (message: string) -> (),
}

local FailureRunner = {}
FailureRunner.__index = FailureRunner

function FailureRunner.new(callbacks: FailureCallbacks)
	return setmetatable({
		_running = false,
		_thread = nil :: thread?,
		_active = nil :: ActiveFailure?,
		_callbacks = callbacks,
		_rng = Random.new(),
		_allowedRoles = nil :: { [Types.RoleId]: boolean }?,
		_lastFailureId = nil :: Types.FailureId?,
		_pressure = MatchConfig.BaseFailurePressure,
		_windowScale = 1,
		_roleWindowBonus = {} :: { [Types.RoleId]: number },
		_token = 0,
		cascadeCount = 0,
	}, FailureRunner)
end

function FailureRunner:setPressure(pressure: number, windowScale: number?)
	self._pressure = math.max(0.25, pressure)
	if windowScale ~= nil then
		self._windowScale = math.clamp(windowScale, 0.35, 1.5)
	end
end

function FailureRunner:setRoleWindowBonuses(bonuses: { [Types.RoleId]: number })
	self._roleWindowBonus = bonuses
end

function FailureRunner:startRandom(allowedRoles: { [Types.RoleId]: boolean })
	if self._thread then
		return
	end
	self._running = true
	self._allowedRoles = allowedRoles
	self._thread = task.spawn(function()
		while self._running do
			local waitTime = self._rng:NextNumber(
				MatchConfig.FailureMinIntervalSeconds,
				MatchConfig.FailureMaxIntervalSeconds
			) / self._pressure
			task.wait(waitTime)
			if not self._running then
				break
			end
			local active = self._active
			if active and not active.resolved and not active.cascaded then
				continue
			end
			local nextFailure = Failures.pickRandom(self._rng, self._allowedRoles, self._lastFailureId)
			if nextFailure then
				self:_fire(nextFailure)
			end
		end
	end)
end

function FailureRunner:stop()
	self._running = false
	self._active = nil
	self._token += 1
	local thread = self._thread
	self._thread = nil
	if thread and thread ~= coroutine.running() then
		task.cancel(thread)
	end
end

function FailureRunner:_fire(def: Types.FailureDef, windowOverride: number?): boolean
	local active = self._active
	if active and not active.resolved and not active.cascaded then
		return false
	end

	local bonus = self._roleWindowBonus[def.responsibleRole] or 0
	local window = windowOverride or math.max(2.5, def.windowSeconds * self._windowScale + bonus)

	self._token += 1
	local token = self._token
	local expiresAt = os.clock() + window
	self._active = {
		def = def,
		expiresAt = expiresAt,
		resolved = false,
		cascaded = false,
		token = token,
	}
	self._lastFailureId = def.id
	self._callbacks.onPrompt(def, expiresAt)
	self._callbacks.onToast(def.label .. " · " .. def.responsibleRole)

	task.delay(window, function()
		local current = self._active
		if not current or current.token ~= token then
			return
		end
		if current.resolved or current.cascaded then
			return
		end
		current.cascaded = true
		self.cascadeCount += def.cascadeSeverity
		self._callbacks.onCascade(def)
		self._callbacks.onToast(def.clipLine)
	end)
	return true
end

function FailureRunner:fireById(id: Types.FailureId, windowOverride: number?): boolean
	local def = Failures.getById(id)
	if not def then
		return false
	end
	return self:_fire(def, windowOverride)
end

function FailureRunner:tryResolve(roleId: Types.RoleId): boolean
	local active = self._active
	if not active or active.resolved or active.cascaded then
		return false
	end
	if active.def.responsibleRole ~= roleId then
		return false
	end
	if os.clock() > active.expiresAt then
		return false
	end
	active.resolved = true
	self._callbacks.onResolved(active.def)
	self._callbacks.onToast("Recovered: " .. active.def.label)
	return true
end

function FailureRunner:getActive(): ActiveFailure?
	return self._active
end

return FailureRunner
