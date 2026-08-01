--!strict

-- Engine-free rebuild decision shared by LabSession and headless tests.

local LabRigPolicy = {}

export type RebuildFlags = {
	outcome: string?,
	stepFailed: boolean?,
	hasChassis: boolean?,
	hasCargo: boolean?,
	wrecked: boolean?,
	wheelsOk: boolean?,
	cargoOk: boolean?,
}

function LabRigPolicy.shouldRebuildRig(flags: RebuildFlags): boolean
	local outcome = flags.outcome
	return outcome == "TruckWrecked"
		or outcome == "CargoLost"
		or flags.stepFailed == true
		or flags.hasChassis == false
		or flags.hasCargo == false
		or flags.wrecked == true
		or flags.wheelsOk == false
		or flags.cargoOk == false
end

return LabRigPolicy
