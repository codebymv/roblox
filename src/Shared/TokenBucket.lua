--!strict

--[[
	Token bucket, keyed by an arbitrary number.

	The maths used to live inside RateLimiter alongside a Players connection,
	which meant testing "does the bucket refill at the right rate" required a
	running DataModel. Splitting the arithmetic out makes it a pure function of
	(rate, burst, key, now), so CI can check it in milliseconds instead of
	waiting real seconds for tokens to come back.

	`now` is a parameter rather than a call to os.clock inside, for the same
	reason: a test can advance time instead of sleeping through it.
]]

export type Bucket = { tokens: number, updatedAt: number }

local TokenBucket = {}
TokenBucket.__index = TokenBucket

export type TokenBucket = typeof(setmetatable(
	{} :: { rate: number, burst: number, buckets: { [number]: Bucket } },
	TokenBucket
))

function TokenBucket.new(ratePerSecond: number, burst: number): TokenBucket
	return setmetatable({
		rate = ratePerSecond,
		burst = burst,
		buckets = {} :: { [number]: Bucket },
	}, TokenBucket)
end

function TokenBucket.allow(self: TokenBucket, key: number, now: number?): boolean
	local at = now or os.clock()
	local bucket = self.buckets[key]

	if not bucket then
		self.buckets[key] = { tokens = self.burst - 1, updatedAt = at }
		return true
	end

	bucket.tokens = math.min(self.burst, bucket.tokens + (at - bucket.updatedAt) * self.rate)
	bucket.updatedAt = at

	if bucket.tokens < 1 then
		return false
	end

	bucket.tokens -= 1
	return true
end

function TokenBucket.forget(self: TokenBucket, key: number)
	self.buckets[key] = nil
end

function TokenBucket.clear(self: TokenBucket)
	table.clear(self.buckets)
end

return TokenBucket
