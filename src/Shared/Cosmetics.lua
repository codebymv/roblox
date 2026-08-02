--!strict

--[[
	The collection: what is painted on the truck, and what it is made of.

	Two axes that multiply rather than one list that grows. Eight liveries and
	six finishes is forty-eight looks out of fourteen authored things, and a
	finish applies to whichever livery is equipped -- gold flames and gold
	stripes are different items but one finish. That is the same property that
	made route sections worth building: content that generates itself.

	The axes are earned differently on purpose, and each one answers a different
	question the game currently has no answer to.

	  Livery   from daily wins    Time. Cannot be rushed by playing more, and
	                              cannot be bought at all.
	  Finish   from credits       Play. This is the credit sink that does not
	                              exist today, where the economy dies after the
	                              five paints are bought.
	  Premium  from Robux         Optional, and only ever on the finish axis.

	WHAT MONEY MAY NOT DO

	Money never gates a pattern. Every livery is reachable by showing up, and a
	player who never spends can own all eight. Robux buys a finish, which is how
	an already-owned shape looks. The headless suite fails if a product ever
	grants a livery.

	Nothing here is random. Every unlock states its requirement up front and
	meeting it grants the item. A paid randomised reward is a loot box, and the
	existing cosmetic-only check would happily pass one, so this is a separate
	rule that is separately tested.

	Engine-free: materials are named as strings and the client maps them to
	Enum.Material, the same way VfxSpec keeps its colours without importing
	NumberSequence.
]]

local Cosmetics = {}

export type Livery = {
	id: string,
	label: string,
	blurb: string,
	-- Cumulative daily wins required. Zero is the default everybody starts with.
	dailyWins: number,
}

export type Finish = {
	id: string,
	label: string,
	blurb: string,
	-- Cargo Cash. Zero is free; premium entries cost Robux instead and are
	-- marked rather than priced here.
	cost: number,
	premium: boolean,
	-- Named rather than an Enum so this module stays loadable without Roblox.
	material: string,
	-- Multiplies the equipped paint colour rather than replacing it, so a
	-- finish reads as a treatment of a colour the player chose.
	tint: Color3,
	reflectance: number,
	-- Client-side colour cycle, for the one finish that cannot be a static
	-- material without an uploaded texture.
	cycles: boolean,
}

--[[
	Liveries, in ladder order.

	The gaps widen as they go: the first is one win away so the mechanism is
	felt immediately, and the last is far enough out to still be worth having a
	month in. Deliberately corny at the start -- flames on a cargo truck is the
	joke the game is already telling.
]]
local LIVERIES: { Livery } = {
	{ id = "Plain", label = "PLAIN", blurb = "Straight off the lot.", dailyWins = 0 },
	{ id = "Flames", label = "CLASSIC FLAMES", blurb = "Nobody asked. Nobody regrets it.", dailyWins = 1 },
	{ id = "Stripes", label = "TWIN STRIPES", blurb = "Down the middle, like it matters.", dailyWins = 2 },
	{ id = "Chevrons", label = "HAZARD CHEVRONS", blurb = "Borrowed from a road crew.", dailyWins = 4 },
	{ id = "Checkers", label = "CHECKER BAND", blurb = "For a truck that never races.", dailyWins = 7 },
	{ id = "Rust", label = "HONEST RUST", blurb = "Every scrape, kept.", dailyWins = 11 },
	{ id = "Pinstripe", label = "PINSTRIPE", blurb = "Somebody's uncle did this by hand.", dailyWins = 16 },
	{ id = "Lightning", label = "LIGHTNING BOLT", blurb = "Speed, implied.", dailyWins = 22 },
	{ id = "Skulls", label = "SKULL RUN", blurb = "The cargo is fine. Probably.", dailyWins = 29 },
}

--[[
	Finishes. Costs climb steeply, because this axis is the long sink: the five
	paints run out in an hour or two and then credits stop meaning anything.
]]
local FINISHES: { Finish } = {
	{
		id = "Matte",
		label = "MATTE",
		blurb = "Paint, and nothing else.",
		cost = 0,
		premium = false,
		material = "SmoothPlastic",
		tint = Color3.fromRGB(255, 255, 255),
		reflectance = 0,
		cycles = false,
	},
	{
		id = "Gloss",
		label = "GLOSS",
		blurb = "Washed, for once.",
		cost = 600,
		premium = false,
		material = "SmoothPlastic",
		tint = Color3.fromRGB(255, 255, 255),
		reflectance = 0.22,
		cycles = false,
	},
	{
		id = "Carbon",
		label = "CARBON",
		blurb = "Weave under the colour.",
		cost = 1400,
		premium = false,
		material = "DiamondPlate",
		tint = Color3.fromRGB(140, 144, 150),
		reflectance = 0.1,
		cycles = false,
	},
	{
		id = "Chrome",
		label = "CHROME",
		blurb = "Mirror bright, dirt magnet.",
		cost = 2600,
		premium = false,
		material = "Metal",
		tint = Color3.fromRGB(228, 232, 238),
		reflectance = 0.55,
		cycles = false,
	},
	{
		id = "Gold",
		label = "SOLID GOLD",
		blurb = "Tasteless, and it knows.",
		cost = 4500,
		premium = false,
		material = "Metal",
		tint = Color3.fromRGB(255, 205, 90),
		reflectance = 0.45,
		cycles = false,
	},
	{
		--[[
			The only finish that cannot be a static material without an uploaded
			texture, so it is a client-side colour cycle instead. That is also
			why it is the premium one: it is the look that is hardest to fake,
			and putting it behind money keeps every *shape* free.
		]]
		id = "Holographic",
		label = "HOLOGRAPHIC",
		blurb = "Never the same colour twice.",
		cost = 0,
		premium = true,
		material = "Neon",
		tint = Color3.fromRGB(255, 255, 255),
		reflectance = 0.3,
		cycles = true,
	},
}

Cosmetics.Liveries = LIVERIES
Cosmetics.Finishes = FINISHES

Cosmetics.DefaultLivery = "Plain"
Cosmetics.DefaultFinish = "Matte"

function Cosmetics.livery(id: string?): Livery?
	if id == nil then
		return nil
	end
	for _, entry in LIVERIES do
		if entry.id == id then
			return entry
		end
	end
	return nil
end

function Cosmetics.finish(id: string?): Finish?
	if id == nil then
		return nil
	end
	for _, entry in FINISHES do
		if entry.id == id then
			return entry
		end
	end
	return nil
end

--[[
	Livery ownership is derived from the daily-win count rather than stored.

	One number instead of a set that has to be kept in step with it, which means
	the ladder can be retuned later without stranding anybody: change a
	threshold and every profile re-evaluates on its next load. A stored set
	would have to be migrated, and a player who unlocked something under the old
	numbers would either lose it or keep it inconsistently.

	The trade is that a livery cannot come from anywhere else. When one needs to
	-- an event, a badge, a gift -- that is the point to add a stored set
	alongside this, not before.
]]
function Cosmetics.ownsLivery(id: string?, dailyWins: number): boolean
	local entry = Cosmetics.livery(id)
	if not entry then
		return false
	end
	return math.max(0, dailyWins or 0) >= entry.dailyWins
end

function Cosmetics.unlockedLiveries(dailyWins: number): { Livery }
	local owned: { Livery } = {}
	for _, entry in LIVERIES do
		if Cosmetics.ownsLivery(entry.id, dailyWins) then
			table.insert(owned, entry)
		end
	end
	return owned
end

--[[
	The next thing to earn, and how far away it is. This is what a collection
	screen shows in its empty slots: a grid with holes and a stated requirement
	is the return driver, not the items already in it.
]]
function Cosmetics.nextLivery(dailyWins: number): (Livery?, number)
	local wins = math.max(0, dailyWins or 0)
	for _, entry in LIVERIES do
		if wins < entry.dailyWins then
			return entry, entry.dailyWins - wins
		end
	end
	return nil, 0
end

-- Finishes are bought, so ownership is stored. Free and premium entries are
-- both handled by the caller; this only answers what the profile records.
function Cosmetics.ownsFinish(id: string?, unlocked: { [string]: boolean }): boolean
	local entry = Cosmetics.finish(id)
	if not entry then
		return false
	end
	if entry.cost <= 0 and not entry.premium then
		return true
	end
	return unlocked[entry.id] == true
end

--[[
	Resolve what to actually render.

	Falls back rather than failing: a profile naming a livery it no longer
	qualifies for, or a finish it does not own, shows the default instead of
	nothing. Cosmetics are the last thing that should be able to break a run.
]]
function Cosmetics.resolve(
	liveryId: string?,
	finishId: string?,
	dailyWins: number,
	unlockedFinishes: { [string]: boolean }
): (Livery, Finish)
	local livery = Cosmetics.livery(liveryId)
	if not livery or not Cosmetics.ownsLivery(livery.id, dailyWins) then
		livery = Cosmetics.livery(Cosmetics.DefaultLivery) :: Livery
	end

	local finish = Cosmetics.finish(finishId)
	if not finish or not Cosmetics.ownsFinish(finish.id, unlockedFinishes) then
		finish = Cosmetics.finish(Cosmetics.DefaultFinish) :: Finish
	end

	return livery, finish
end

-- How much of the collection is owned, for the grid's counter.
function Cosmetics.progress(dailyWins: number, unlockedFinishes: { [string]: boolean }): (number, number)
	local owned = 0
	for _, entry in LIVERIES do
		if Cosmetics.ownsLivery(entry.id, dailyWins) then
			owned += 1
		end
	end
	for _, entry in FINISHES do
		if Cosmetics.ownsFinish(entry.id, unlockedFinishes) then
			owned += 1
		end
	end
	return owned, #LIVERIES + #FINISHES
end

return Cosmetics
