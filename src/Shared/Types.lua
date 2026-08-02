--!strict

--[[
	The persistent profile, and the cosmetic it points at.

	This used to carry the depot build's wire contracts as well. Those went with
	the depot; the fun-test build has its own in LabTypes.lua, and what is left
	here is only what outlives a session.
]]

export type PaintDef = {
	id: string,
	label: string,
	cost: number,
	color: Color3,
}

export type ProfileData = {
	version: number,
	credits: number,
	lifetimeConvoys: number,
	lifetimeLegs: number,
	lifetimeBanked: number,
	bestLeg: number,
	bestBankedHaul: number,
	currentStreak: number,
	bestStreak: number,
	unlockedKits: { [string]: boolean },
	equippedKits: { [string]: string },
	unlockedPaints: { [string]: boolean },
	equippedPaint: string,
	manifestJournal: { [string]: number },
	-- Day number of the last banked daily bonus. A day rather than a flag, so it
	-- expires without anything having to reset it. Was lastDailyDay, which
	-- belonged to the depot build's daily credit and outlived its only reader.
	dailyContractDay: number,
	-- Purchase ids already granted, oldest first. ProcessReceipt can fire more
	-- than once for the same sale, so this is what makes a grant idempotent.
	-- Bounded by Commerce.MaxReceiptHistory.
	grantedReceipts: { string },
	-- Fun-test personal records. Deliberately separate from the Depot streak
	-- fields above, which count convoy legs and mean something else.
	labRecords: {
		deliveries: number,
		bestConditionPct: number,
		bestTimeSeconds: number,
		bestPayout: number,
		deliveryStreak: number,
		bestDeliveryStreak: number,
	},
	-- Badge keys already awarded, so a repeat run does not re-query Roblox.
	awardedBadges: { [string]: boolean },
}

return {}
