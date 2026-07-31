--!nonstrict

--[[
	Commands that exist to make a tuning pass cheap.

	The expensive part of tuning a physics vehicle is not changing the number,
	it is getting back to the piece of road where the number matters. The blind
	right-hander sits around 12% of a 3,900 stud route, so evaluating a grip
	change meant driving the warm-up straight again every single time.

	  warp      jump to a named landmark, or to an explicit route fraction
	  rebuild   tear the rig down and build it again, for the LabConfig values
	            that are only read while the truck is being assembled
	  dump      print the tuning values that have moved from the file defaults

	Everything here is gated on DevConfig.isDevToolingEnabled, and every command
	is refused outright when it is off, so there is no path to this from a
	player build.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevConfig = require(Shared:WaitForChild("DevConfig"))
local LabRemotes = require(Shared:WaitForChild("LabRemotes"))
local Net = require(Shared:WaitForChild("Net"))

local RateLimiter = require(script.Parent.RateLimiter)
local TuningService = require(script.Parent.TuningService)

local DevCommands = {}

export type Handlers = {
	warp: (progress: number) -> string,
	rebuild: () -> string,
	landmarks: () -> { { name: string, progress: number } },
}

local handlers: Handlers? = nil
local limiter = RateLimiter.new(6, 10)

local function reply(player: Player, text: string)
	LabRemotes.fireClient(Net.Names.LabEvent, player, text)
end

--[[
	Landmarks are ordered by progress, so stepping is just an index walk. The
	small epsilon stops a step from finding the landmark you are already
	standing on when floating point puts you a fraction behind it.
]]
local function stepLandmark(current: number, direction: number)
	if not handlers then
		return nil
	end
	local list = handlers.landmarks()
	if #list == 0 then
		return nil
	end

	if direction > 0 then
		for _, entry in list do
			if entry.progress > current + 0.005 then
				return entry
			end
		end
		return list[#list]
	end

	for index = #list, 1, -1 do
		if list[index].progress < current - 0.005 then
			return list[index]
		end
	end
	return list[1]
end

--[[
	Payload shape has already been validated and clamped by LabRemotes, so this
	only has to decide whether the command exists and whether the tooling is on.
]]
local function handle(player: Player, payload: LabRemotes.DevPayload)
	if not DevConfig.isDevToolingEnabled() or not handlers then
		return
	end
	if not limiter:allow(player) then
		return
	end

	local command = payload.command

	if command == "warp" then
		if not payload.progress then
			return
		end
		reply(player, handlers.warp(payload.progress))
	elseif command == "warpStep" then
		if not payload.from or not payload.direction then
			return
		end
		local target = stepLandmark(payload.from, payload.direction)
		if not target then
			return
		end
		reply(player, string.format("%s -- %s", handlers.warp(target.progress), target.name))
	elseif command == "rebuild" then
		reply(player, handlers.rebuild())
	elseif command == "dump" then
		TuningService.dump()
		reply(player, "Tuning diff printed to the server output.")
	end
end

function DevCommands.init(commandHandlers: Handlers): RBXScriptConnection?
	if not DevConfig.isDevToolingEnabled() then
		return nil
	end

	handlers = commandHandlers
	local connection = LabRemotes.bindServer(Net.Names.LabDevCommand, function(player: Player, payload)
		local ok, err = pcall(handle, player, payload)
		if not ok then
			warn("[DevCommands] " .. tostring(err))
		end
	end)

	print("[DevCommands] warp [ ], rebuild \\, dump P. Disable with DevConfig.LiveTuning.")
	return connection
end

return DevCommands
