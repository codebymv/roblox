--!strict

--[[
	Reasons to come back, and reasons to tell somebody.

	The audit's sharpest retention finding was that the whole progression
	catalogue is five paint colours, exhausted in an hour or two, after which
	credits accumulate against nothing. Records cost no content: they turn a run
	the player already did into a number they can beat, and they work at any
	population, which a global leaderboard does not.

	Badges are the social half. Fail-closed like Commerce: a badge id of zero is
	never awarded and never queried, so the pipeline ships before the ids exist.

	Engine-free, because record comparison is exactly the kind of arithmetic
	that looks obvious and is wrong. Lower-is-better with an unset sentinel has
	caught better codebases than this one.
]]

local Achievements = {}

export type Records = {
	deliveries: number,
	-- Cargo condition on arrival, 0-100. Higher is better.
	bestConditionPct: number,
	-- Seconds to deliver. Lower is better, and zero means never delivered,
	-- which is why this cannot be a plain math.min.
	bestTimeSeconds: number,
	bestPayout: number,
	deliveryStreak: number,
	bestDeliveryStreak: number,
}

export type Badge = {
	key: string,
	-- Roblox badge id. Zero means unconfigured: never awarded, never queried.
	assetId: number,
	label: string,
	description: string,
}

local BADGES: { Badge } = {
	{
		key = "FirstDelivery",
		assetId = 0,
		label = "First Haul",
		description = "Deliver a load to the depot.",
	},
	{
		key = "SpotlessDelivery",
		assetId = 0,
		label = "Not A Scratch",
		description = "Deliver with the load in perfect condition.",
	},
	{
		key = "SavedIt",
		assetId = 0,
		label = "Saved It",
		description = "Deliver a load after a strap let go on the way.",
	},
	{
		key = "TookTheRisk",
		assetId = 0,
		label = "Took The Risk",
		description = "Complete a contract the crew voted for under Catastrophe pressure.",
	},
}

Achievements.Badges = BADGES

function Achievements.badge(key: string?): Badge?
	if key == nil then
		return nil
	end
	for _, badge in BADGES do
		if badge.key == key then
			return badge
		end
	end
	return nil
end

function Achievements.isConfigured(badge: Badge): boolean
	return badge.assetId > 0
end

function Achievements.awardable(): { Badge }
	local list = {}
	for _, badge in BADGES do
		if Achievements.isConfigured(badge) then
			table.insert(list, badge)
		end
	end
	return list
end

function Achievements.defaultRecords(): Records
	return {
		deliveries = 0,
		bestConditionPct = 0,
		bestTimeSeconds = 0,
		bestPayout = 0,
		deliveryStreak = 0,
		bestDeliveryStreak = 0,
	}
end

local function arrived(outcome: string): boolean
	return outcome == "Delivered" or outcome == "PartialLoss"
end

--[[
	Fold a finished run into the records, and report what improved.

	Returns the list of record keys this run beat, so the result screen can say
	so at the moment it happened rather than the player finding out later in a
	menu. An empty list is the common case and is not a failure.

	Only a delivery advances anything. A wreck breaks the streak, and a run that
	never arrived has no time or condition worth recording.
]]
function Achievements.applyRun(
	records: Records,
	outcome: string,
	conditionPct: number,
	durationSeconds: number,
	payout: number
): { string }
	local beaten: { string } = {}

	if not arrived(outcome) then
		records.deliveryStreak = 0
		return beaten
	end

	records.deliveries += 1
	records.deliveryStreak += 1
	if records.deliveryStreak > records.bestDeliveryStreak then
		records.bestDeliveryStreak = records.deliveryStreak
		-- A streak of one is the first delivery, not an achievement to announce.
		if records.bestDeliveryStreak > 1 then
			table.insert(beaten, "bestDeliveryStreak")
		end
	end

	local condition = math.clamp(conditionPct, 0, 100)
	if condition > records.bestConditionPct then
		records.bestConditionPct = condition
		table.insert(beaten, "bestConditionPct")
	end

	local payoutValue = math.max(0, payout)
	if payoutValue > records.bestPayout then
		records.bestPayout = payoutValue
		table.insert(beaten, "bestPayout")
	end

	--[[
		Faster is better, and zero means no time has ever been set. A plain
		math.min would make the unset sentinel an unbeatable record forever.
	]]
	local duration = math.max(0, durationSeconds)
	if duration > 0 and (records.bestTimeSeconds <= 0 or duration < records.bestTimeSeconds) then
		local hadOne = records.bestTimeSeconds > 0
		records.bestTimeSeconds = duration
		if hadOne then
			table.insert(beaten, "bestTimeSeconds")
		end
	end

	return beaten
end

--[[
	Which badges a finished run has earned.

	Returns keys rather than awarding, so the decision is testable and the
	awarding stays where the network calls are.
]]
function Achievements.earnedBy(
	outcome: string,
	conditionPct: number,
	strapBreaks: number,
	riskyContract: boolean
): { string }
	local earned: { string } = {}
	if not arrived(outcome) then
		return earned
	end

	table.insert(earned, "FirstDelivery")
	if conditionPct >= 100 then
		table.insert(earned, "SpotlessDelivery")
	end
	if strapBreaks > 0 then
		table.insert(earned, "SavedIt")
	end
	if riskyContract then
		table.insert(earned, "TookTheRisk")
	end
	return earned
end

-- Human-readable record names, kept beside the keys so a new record cannot
-- ship without the words the result screen needs.
Achievements.RecordLabel = {
	deliveries = "Deliveries",
	bestConditionPct = "Best condition",
	bestTimeSeconds = "Fastest delivery",
	bestPayout = "Biggest payout",
	deliveryStreak = "Current streak",
	bestDeliveryStreak = "Best streak",
}

return Achievements
