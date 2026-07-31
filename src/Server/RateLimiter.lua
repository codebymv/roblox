--!strict

--[[
	A token bucket keyed by UserId.

	Every client-to-server remote in this project accepted unlimited calls. Most
	handlers are cheap, but the ones that spawn a task.delay per call are not,
	so intent remotes get a bucket in front of them.
]]

local Players = game:GetService("Players")

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type Bucket = { tokens: number, updatedAt: number }

export type RateLimiter = typeof(setmetatable(
	{} :: { rate: number, burst: number, buckets: { [number]: Bucket } },
	RateLimiter
))

function RateLimiter.new(ratePerSecond: number, burst: number): RateLimiter
	local self = setmetatable({
		rate = ratePerSecond,
		burst = burst,
		buckets = {} :: { [number]: Bucket },
	}, RateLimiter)

	Players.PlayerRemoving:Connect(function(player: Player)
		self.buckets[player.UserId] = nil
	end)

	return self
end

function RateLimiter.allow(self: RateLimiter, player: Player): boolean
	local now = os.clock()
	local bucket = self.buckets[player.UserId]

	if not bucket then
		self.buckets[player.UserId] = { tokens = self.burst - 1, updatedAt = now }
		return true
	end

	bucket.tokens = math.min(self.burst, bucket.tokens + (now - bucket.updatedAt) * self.rate)
	bucket.updatedAt = now

	if bucket.tokens < 1 then
		return false
	end

	bucket.tokens -= 1
	return true
end

return RateLimiter
