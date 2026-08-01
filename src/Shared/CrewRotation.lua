--!strict

--[[
	Deterministic role rotation for a SWAP gate.

	The current Driver moves into the first occupied strap station, every
	Strapper advances to the next occupied station, and the final Strapper takes
	the wheel. Missing stations are filled from StationOrder, which keeps a
	thrown or respawning player in the rotation without producing duplicates.

	This module has no engine dependencies so the 2/3/4-player rule can be
	proved headlessly. StrapperStations applies the returned plan to real seats.
]]

export type Strapper = {
	id: any,
	station: string?,
}

export type Assignment = {
	role: "Driver" | "Strapper",
	station: string?,
}

local CrewRotation = {}

function CrewRotation.plan(driverId: any, currentStrappers: { Strapper }, stationOrder: { string })
	if driverId == nil or #currentStrappers == 0 then
		return {}, nil
	end

	local rank = {}
	for index, station in stationOrder do
		rank[station] = index
	end

	local strappers = {}
	for _, entry in currentStrappers do
		table.insert(strappers, { id = entry.id, station = entry.station })
	end
	table.sort(strappers, function(a, b)
		local aRank = if a.station then rank[a.station] or math.huge else math.huge
		local bRank = if b.station then rank[b.station] or math.huge else math.huge
		if aRank == bRank then
			return tostring(a.id) < tostring(b.id)
		end
		return aRank < bRank
	end)

	local stations = {}
	local used = {}
	for index, entry in strappers do
		local station = entry.station
		if not station or not rank[station] or used[station] then
			station = nil
			for _, candidate in stationOrder do
				if not used[candidate] then
					station = candidate
					break
				end
			end
		end
		if not station then
			return {}, nil
		end
		stations[index] = station
		used[station] = true
	end

	local assignments: { [any]: Assignment } = {}
	assignments[driverId] = { role = "Strapper", station = stations[1] }
	for index = 1, #strappers - 1 do
		assignments[strappers[index].id] = { role = "Strapper", station = stations[index + 1] }
	end

	local newDriverId = strappers[#strappers].id
	assignments[newDriverId] = { role = "Driver", station = nil }
	return assignments, newDriverId
end

return CrewRotation
