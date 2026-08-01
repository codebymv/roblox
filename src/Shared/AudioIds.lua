--!strict

--[[
	Uploaded audio asset IDs. Keep masters on disk; the place only references
	these rbxassetid strings.
]]

return {
	-- LabMusic starts on the first cue, then picks a different cue at random
	-- for each crossfade (never the same track twice in a row).
	-- OstLoop is kept as an alias of the first cue for older call sites.
	OstTracks = {
		"rbxassetid://122768801108112", -- cargo_ost
		"rbxassetid://98660810477229", -- cargo_ost2
		"rbxassetid://135309223240228", -- cargo_ost3
	},
	OstLoop = "rbxassetid://122768801108112",

	Sfx = {
		CargoImpactLight = "rbxassetid://97136339617734",
		EngineIdleLoop = "rbxassetid://72290187945883",
		PlayerReseat = "rbxassetid://82937065842590",
		DeliveryPartial = "rbxassetid://81558549056397",
		RoleStrapper = "rbxassetid://140674293470981",
		WarehouseAmbienceLoop = "rbxassetid://81353225104050",
		TireOffroadLoop = "rbxassetid://106021574275299",
		DeliverySuccess = "rbxassetid://83666372689861",
		TruckCollisionHeavy = "rbxassetid://123329045834609",
		TruckCollisionLight = "rbxassetid://94201243519747",
		TireAsphaltLoop = "rbxassetid://84482199513691",
		StrapSnap1 = "rbxassetid://125513595522973",
		BridgeRumbleLoop = "rbxassetid://108895501019065",
		TruckCollisionMedium = "rbxassetid://100497796509290",
		PlayerThrown = "rbxassetid://103078881671379",
		SwapActivate = "rbxassetid://116964726569784",
		CargoScrapeLoop = "rbxassetid://116211956538252",
		StrapRatchetLoop = "rbxassetid://76548369593847",
		StrapRefit1 = "rbxassetid://136750750708924",
		BrakeHiss = "rbxassetid://130116681539017",
		StrapSnap2 = "rbxassetid://107335236051997",
		StrapTensionLoop = "rbxassetid://138733722931885",
		RoleDriver = "rbxassetid://101018792572510",
		EngineDriveLoop = "rbxassetid://125573274430449",
		CargoImpactHeavy = "rbxassetid://79814501978013",
		RunGo = "rbxassetid://129953137402834",
		SwapWarning = "rbxassetid://79726634395054",
		SuspensionHit1 = "rbxassetid://74710360998689",
		CargoImpactMedium = "rbxassetid://73372874507789",
		StrapRefit2 = "rbxassetid://84073481026574",
		SuspensionHit2 = "rbxassetid://79223228643630",
		RoughRoadRattleLoop = "rbxassetid://77776500482329",
		DeliveryFailure = "rbxassetid://105012928491012",
		CountdownTick = "rbxassetid://75178453797240",
		TireSkidLoop = "rbxassetid://138158201752557",
		CargoCashReward = "rbxassetid://114785256512904",
	},
}
