--!nonstrict

--[[
	Purchases, and the promise that a player gets what they paid for.

	`ProcessReceipt` is not a callback that fires once. Roblox calls it again if
	the server never confirmed, calls it on a different server if the player
	moved, and considers the purchase settled only when it returns
	PurchaseGranted. The player's Robux is already gone in every one of those
	cases. Three rules follow, and the whole module is built around them:

	1. A repeated receipt must not grant twice. Granted purchase ids live in the
	   profile, so the check survives a server hop.
	2. A grant must not be confirmed before it is durable. If the save fails the
	   in-memory grant is rolled back and the receipt is left unconfirmed, so
	   Roblox retries later rather than the player losing what they bought at
	   logout.
	3. An unrecognised product is never confirmed. Leaving it pending means a
	   deploy that adds the product still grants it; confirming would take the
	   money and give nothing.

	Passes are the easy half: Roblox owns that record, so ownership is queried
	and cached rather than stored, and the derived grant is re-applied on join.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Commerce = require(Shared:WaitForChild("Commerce"))
local TruckPaints = require(Shared:WaitForChild("TruckPaints"))

local PlayerDataService = require(script.Parent.PlayerDataService)

local CommerceService = {}

local started = false
local analytics = nil
-- Pass ownership, per player per pass. Cleared on leave; refreshed when a
-- purchase completes.
local passOwnership: { [number]: { [string]: boolean } } = {}

local function log(message: string)
	print("[CargoCommerce] " .. message)
end

--[[
	Apply a grant, and hand back the inverse.

	The inverse exists for rule 2: if the durable save fails after the grant
	landed in memory, the profile has to go back exactly as it was. Restoring a
	captured value rather than subtracting means an unlock the player already
	owned before the purchase is not taken away by the rollback.
]]
local function applyGrant(profile, grant): () -> ()
	if grant.kind == "Credits" then
		local before = profile.credits
		profile.credits = math.max(0, before + math.max(0, grant.amount or 0))
		return function()
			profile.credits = before
		end
	end

	if grant.kind == "Paint" then
		local paintId = grant.paintId
		if paintId == nil or not TruckPaints.getPaint(paintId) then
			return function() end
		end
		local ownedBefore = profile.unlockedPaints[paintId]
		profile.unlockedPaints[paintId] = true
		return function()
			profile.unlockedPaints[paintId] = ownedBefore
		end
	end

	-- Commerce.CosmeticGrants is the allowlist and the headless suite holds it,
	-- so reaching here means a grant kind was added without a handler.
	warn("[CargoCommerce] No handler for grant kind: " .. tostring(grant.kind))
	return function() end
end

local function processReceipt(info): Enum.ProductPurchaseDecision
	local Decision = Enum.ProductPurchaseDecision
	local purchaseId = tostring(info.PurchaseId)

	local player = Players:GetPlayerByUserId(info.PlayerId)
	if not player then
		-- Gone. Roblox will offer this receipt again when they next play.
		return Decision.NotProcessedYet
	end

	local product = Commerce.byAssetId(info.ProductId, "Product")
	if not product then
		warn(
			string.format(
				"[CargoCommerce] Unknown product %s for %s. Leaving the receipt unconfirmed so a later build can honour it.",
				tostring(info.ProductId),
				player.Name
			)
		)
		return Decision.NotProcessedYet
	end

	local profile = PlayerDataService.waitFor(player, 10)
	if not profile then
		return Decision.NotProcessedYet
	end

	-- Rule 1. Already granted, possibly on another server.
	if Commerce.hasReceipt(profile.grantedReceipts, purchaseId) then
		return Decision.PurchaseGranted
	end

	--[[
		A volatile profile is one whose load failed, so it is deliberately never
		saved. Granting into it would hand over something that disappears at
		logout, and confirming would tell Roblox the sale is settled.
	]]
	if PlayerDataService.isVolatile(player) then
		warn("[CargoCommerce] Refusing to grant into a volatile profile for " .. player.Name)
		return Decision.NotProcessedYet
	end

	local revert: (() -> ())? = nil
	PlayerDataService.update(player, function(data)
		revert = applyGrant(data, product.grant)
		Commerce.appendReceipt(data.grantedReceipts, purchaseId)
	end)

	-- Rule 2. Confirm only once it is on disk.
	if not PlayerDataService.flush(player) then
		PlayerDataService.update(player, function(data)
			if revert then
				revert()
			end
			for index, recorded in data.grantedReceipts do
				if recorded == purchaseId then
					table.remove(data.grantedReceipts, index)
					break
				end
			end
		end)
		warn("[CargoCommerce] Save failed for " .. player.Name .. "; leaving the receipt for a retry.")
		return Decision.NotProcessedYet
	end

	log(string.format("granted %s to %s", product.key, player.Name))
	if analytics then
		analytics:purchaseGranted(player, product)
	end
	return Decision.PurchaseGranted
end

local function ownsPass(player: Player, product): boolean
	local cache = passOwnership[player.UserId]
	if cache and cache[product.key] ~= nil then
		return cache[product.key]
	end

	local ok, owned = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, product.assetId)
	end)
	if not ok then
		-- Do not cache a failure as "does not own": a transient outage would
		-- otherwise revoke a pass for the rest of the session.
		warn("[CargoCommerce] Pass check failed for " .. player.Name .. ": " .. tostring(owned))
		return false
	end

	cache = passOwnership[player.UserId] or {}
	cache[product.key] = owned
	passOwnership[player.UserId] = cache
	return owned
end

--[[
	Re-apply what a pass entitles the owner to.

	Passes are not receipts: Roblox holds the ownership record, so the grant is
	reconstructed on every join rather than remembered. That also means a pass
	bought while the profile was volatile repairs itself next session.
]]
function CommerceService.syncPasses(player: Player)
	local profile = PlayerDataService.waitFor(player, 10)
	if not profile or PlayerDataService.isVolatile(player) then
		return
	end

	for _, product in Commerce.Catalog do
		if product.kind == "Pass" and Commerce.isConfigured(product) and ownsPass(player, product) then
			PlayerDataService.update(player, function(data)
				applyGrant(data, product.grant)
			end)
		end
	end
end

--[[
	Prompt from the server rather than the client.

	The client sends a product key it wants; the server decides which asset id
	that is. A client that could name an asset id could prompt for anything,
	including a product belonging to somebody else's experience.
]]
function CommerceService.prompt(player: Player, key: string?): boolean
	local product = Commerce.byKey(key)
	if not product or not Commerce.isConfigured(product) then
		return false
	end

	local ok, err = pcall(function()
		if product.kind == "Pass" then
			MarketplaceService:PromptGamePassPurchase(player, product.assetId)
		else
			MarketplaceService:PromptProductPurchase(player, product.assetId)
		end
	end)
	if not ok then
		warn("[CargoCommerce] Prompt failed: " .. tostring(err))
		return false
	end

	if analytics then
		analytics:purchasePrompted(player, product)
	end
	return true
end

--[[
	Analytics arrive later than the receipt binding does.

	Bootstrap stands commerce up for both modes before either composition root
	has built a session, and the session owns the analytics instance. Binding
	ProcessReceipt as early as possible matters more than funnel events do: a
	receipt that arrives before the callback exists is retried, but only after a
	delay the player experiences as a purchase that did nothing.
]]
function CommerceService.attachAnalytics(labAnalytics)
	analytics = labAnalytics
end

function CommerceService.init()
	if started then
		return
	end
	started = true

	MarketplaceService.ProcessReceipt = processReceipt

	for _, player in Players:GetPlayers() do
		task.spawn(CommerceService.syncPasses, player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(CommerceService.syncPasses, player)
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			local product = Commerce.byAssetId(passId, "Pass")
			if not product then
				return
			end
			local cache = passOwnership[player.UserId] or {}
			cache[product.key] = purchased
			passOwnership[player.UserId] = cache
			if purchased then
				task.spawn(CommerceService.syncPasses, player)
				if analytics then
					analytics:purchaseGranted(player, product)
				end
			end
		end
	)

	Players.PlayerRemoving:Connect(function(player: Player)
		passOwnership[player.UserId] = nil
	end)

	local configured = #Commerce.purchasable()
	if configured == 0 then
		-- Not a warning. The pipeline shipping ahead of the catalogue is the
		-- intended state, and the message is here so nobody has to read code to
		-- work out why nothing is for sale.
		log("ready. No products configured, so nothing is purchasable yet.")
	else
		log(string.format("ready with %d purchasable product(s)", configured))
	end
end

return CommerceService
