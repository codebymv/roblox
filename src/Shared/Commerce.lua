--!strict

--[[
	What can be bought, and the rules for granting it.

	Infrastructure first, catalogue later. The expensive, risky, easy-to-get-
	wrong half of monetization is receipt handling: `ProcessReceipt` can fire
	more than once for the same purchase, fires again on a later server if it
	was not confirmed, and charges the player whether or not the grant landed.
	Getting that wrong takes real money for nothing. Adding a second paint pack
	afterwards is a table entry.

	So this ships with the pipeline complete and the catalogue nearly empty, and
	every product deliberately unconfigured: an asset id of zero is never
	offered, never prompted and never granted. Pasting a real id in turns one
	on, with nothing else to change.

	THE LINE

	Nothing here may sell an advantage. Credits buy paint, and paint changes a
	colour. A grant kind that affects strap strength, grip, cargo condition,
	timing windows or contract difficulty does not belong in this file, and the
	headless suite fails if one appears.
]]

local Cosmetics = require(script.Parent.Cosmetics)
local TruckPaints = require(script.Parent.TruckPaints)

local Commerce = {}

-- Grant kinds that are allowed to exist. Adding to this list is a deliberate
-- decision about what the game is willing to sell.
local COSMETIC_GRANTS = {
	Credits = true,
	Paint = true,
	-- A finish is how an owned shape looks. Liveries are deliberately absent
	-- and the suite enforces it: money may change the material, never the
	-- pattern, so a player who never spends can still own every shape.
	Finish = true,
}

Commerce.CosmeticGrants = COSMETIC_GRANTS

export type Grant = {
	kind: string,
	-- Credits grants. Ignored by other kinds.
	amount: number?,
	-- Paint grants. Must name an id in TruckPaints.
	paintId: string?,
	-- Finish grants. Must name an id in Cosmetics.
	finishId: string?,
}

export type Product = {
	key: string,
	-- Roblox asset id. Zero means unconfigured: the whole pipeline runs, but
	-- this entry is invisible and unpurchasable until a real id is pasted in.
	assetId: number,
	-- "Product" is a developer product, repeatable, settled through
	-- ProcessReceipt. "Pass" is a game pass, one-time, owned by Roblox and
	-- queried rather than recorded.
	kind: string,
	label: string,
	description: string,
	grant: Grant,
}

local CATALOG: { Product } = {
	{
		key = "CargoCashSmall",
		assetId = 3612861884,
		kind = "Product",
		label = "1,200 Cargo Cash",
		description = "A stack of Cargo Cash toward cab paint.",
		grant = { kind = "Credits", amount = 1200 },
	},
	{
		key = "HolographicFinish",
		assetId = 1934331260,
		kind = "Pass",
		label = "Holographic Finish",
		description = "A finish that never settles on a colour. Works with every livery you own.",
		grant = { kind = "Finish", finishId = "Holographic" },
	},
	{
		key = "SupporterPack",
		assetId = 1932105841,
		kind = "Pass",
		label = "Supporter Pack",
		description = "Prototype White cab paint, and thanks.",
		grant = { kind = "Paint", paintId = "Prototype" },
	},
}

Commerce.Catalog = CATALOG

-- Purchases already granted are remembered per profile so a repeated receipt
-- is recognised. Bounded because a profile is a DataStore value with a size
-- limit and a determined player could otherwise grow it without end.
Commerce.MaxReceiptHistory = 64

function Commerce.isConfigured(product: Product): boolean
	return product.assetId > 0
end

-- Everything the storefront may show. Unconfigured entries are omitted rather
-- than greyed out: an entry nobody can buy is not a product, it is a bug
-- waiting to be reported.
function Commerce.purchasable(): { Product }
	local list = {}
	for _, product in CATALOG do
		if Commerce.isConfigured(product) then
			table.insert(list, product)
		end
	end
	return list
end

function Commerce.byKey(key: string?): Product?
	if key == nil then
		return nil
	end
	for _, product in CATALOG do
		if product.key == key then
			return product
		end
	end
	return nil
end

--[[
	Look up by Roblox asset id, for ProcessReceipt and pass checks.

	Unconfigured entries are skipped on purpose: with every placeholder sitting
	at zero, matching on id would make a single stray zero resolve to whichever
	product happened to be first.
]]
function Commerce.byAssetId(assetId: number?, kind: string): Product?
	if assetId == nil or assetId <= 0 then
		return nil
	end
	for _, product in CATALOG do
		if product.assetId == assetId and product.kind == kind and Commerce.isConfigured(product) then
			return product
		end
	end
	return nil
end

--[[
	Give a profile what a product grants.

	Pure, and here rather than in CommerceService, because this is the most
	correctness-critical code in the project and it was the least testable. It
	is what a receipt actually does, it runs inside a DataStore transform, and
	getting it wrong takes real money for nothing.

	Returns whether anything was granted. An unknown grant kind, or one naming a
	cosmetic that does not exist, is refused rather than silently ignored: the
	caller needs to know not to confirm the sale.
]]
function Commerce.applyGrant(profile, grant: Grant): boolean
	if not COSMETIC_GRANTS[grant.kind] then
		return false
	end

	if grant.kind == "Credits" then
		local amount = math.max(0, grant.amount or 0)
		if amount <= 0 then
			return false
		end
		profile.credits = math.max(0, profile.credits + amount)
		return true
	end

	if grant.kind == "Paint" then
		local paintId = grant.paintId
		if paintId == nil or not TruckPaints.getPaint(paintId) then
			return false
		end
		profile.unlockedPaints[paintId] = true
		return true
	end

	if grant.kind == "Finish" then
		local finishId = grant.finishId
		if finishId == nil or not Cosmetics.finish(finishId) then
			return false
		end
		profile.unlockedFinishes[finishId] = true
		return true
	end

	-- Reachable only by adding a kind to the allowlist without a branch here,
	-- which the headless suite exists to catch.
	return false
end

function Commerce.hasReceipt(history: { string }, purchaseId: string): boolean
	for _, recorded in history do
		if recorded == purchaseId then
			return true
		end
	end
	return false
end

--[[
	Record a granted purchase, oldest dropped first.

	Returns false when the id was already present, which is the signal that a
	receipt is a repeat rather than a new sale.
]]
function Commerce.appendReceipt(history: { string }, purchaseId: string): boolean
	if Commerce.hasReceipt(history, purchaseId) then
		return false
	end
	table.insert(history, purchaseId)
	while #history > Commerce.MaxReceiptHistory do
		table.remove(history, 1)
	end
	return true
end

return Commerce
