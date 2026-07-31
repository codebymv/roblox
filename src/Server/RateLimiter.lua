--!strict

--[[
	A token bucket keyed by UserId.

	Every client-to-server remote in this project accepted unlimited calls. Most
	handlers are cheap, but the ones that spawn a task.delay per call are not,
	so intent remotes get a bucket in front of them.

	The arithmetic lives in Shared/TokenBucket, which has no engine dependency
	and is covered by the headless tests. What is left here is the part that
	genuinely needs Roblox: mapping a Player to a key, and forgetting the bucket
	when they leave.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TokenBucket = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TokenBucket"))

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable(
	{} :: {
		bucket: TokenBucket.TokenBucket,
		connection: RBXScriptConnection?,
	},
	RateLimiter
))

function RateLimiter.new(ratePerSecond: number, burst: number): RateLimiter
	local self = setmetatable({
		bucket = TokenBucket.new(ratePerSecond, burst),
		connection = nil :: RBXScriptConnection?,
	}, RateLimiter)

	self.connection = Players.PlayerRemoving:Connect(function(player: Player)
		self.bucket:forget(player.UserId)
	end)

	return self
end

function RateLimiter.allow(self: RateLimiter, player: Player): boolean
	return self.bucket:allow(player.UserId)
end

-- Owners that can be torn down and rebuilt need this, or every rebuild leaves
-- another live PlayerRemoving handler behind.
function RateLimiter.destroy(self: RateLimiter)
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
	self.bucket:clear()
end

return RateLimiter
