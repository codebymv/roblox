--!strict

-- Engine-free decision shared by the session and its regression tests.

local LabRespawnPolicy = {}

function LabRespawnPolicy.shouldAttach(phase: string, truckWrecked: boolean, chassisY: number, voidY: number): boolean
	if phase == "Result" or truckWrecked then
		return false
	end
	-- Leave a buffer above the wreck threshold. A truck still descending at the
	-- exact threshold is not a safe place for a newly spawned character.
	return chassisY > voidY + 24
end

return LabRespawnPolicy
