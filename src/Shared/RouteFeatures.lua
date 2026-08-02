--!strict

--[[
	Where a route's corners, descents and bridges are, read off the road itself.

	PressureDirector weights its events by terrain: cargo pressure near corners,
	mechanical wear on the descent, crosswind on the bridge. That weighting is
	the reason a failure feels earned rather than arbitrary. It located those
	places with hardcoded progress fractions -- 0.06 to 0.19 for the first
	corner, 0.30 to 0.48 for the descent -- which are measurements of one
	specific road.

	Point that at a second route and the director weights corners on a straight
	and crosswind where there is no bridge. The result is a level that is
	mechanically fine and reads as random, which is the failure mode the
	playtest protocol lists as a no-go.

	So a route describes itself. Give this the geometry and it finds the
	features, which means a route nobody has annotated still gets the right
	difficulty in the right places.

	Engine-free, and the detection is the part worth testing: thresholds that
	quietly stop matching a real corner are invisible until a playtest says the
	game got boring.
]]

local RouteFeatures = {}

export type Kind = "Corner" | "Descent" | "Bridge"

export type Feature = {
	kind: Kind,
	-- Progress along the route, 0 to 1. `from` includes the approach: pressure
	-- applied inside a corner is already too late to be a decision.
	from: number,
	to: number,
}

RouteFeatures.Kind = {
	Corner = "Corner" :: Kind,
	Descent = "Descent" :: Kind,
	Bridge = "Bridge" :: Kind,
}

--[[
	A node counts as cornering when the road's flat heading turns by more than
	this across it. Low enough to catch a long sweeping bend, high enough to
	ignore the one-degree wobble that a lane change leaves behind.
]]
RouteFeatures.CornerDegreesPerNode = 3

-- Downhill fraction, rise over run. The authored descent sits around 0.15, and
-- the gentle grade either side of the bridge sits near 0.02.
RouteFeatures.DescentGrade = 0.045

--[[
	How far back a window reaches. The interesting moment is the approach, not
	the feature: weakening a strap two seconds before a corner is the whole
	game, and weakening one inside the corner is just damage.
]]
RouteFeatures.ApproachStuds = 140

-- Windows shorter than this are noise -- a single kinked node, or one segment
-- of bridge decking. Merged into a neighbour or dropped.
RouteFeatures.MinSpanStuds = 30

local function flatHeading(from: Vector3, to: Vector3): Vector3?
	local delta = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if delta.Magnitude < 1e-3 then
		return nil
	end
	return delta.Unit
end

local function turnDegrees(a: Vector3, b: Vector3): number
	local dot = math.clamp(a:Dot(b), -1, 1)
	return math.deg(math.acos(dot))
end

--[[
	Collapse a set of flagged node indices into progress windows, widened by the
	approach distance and dropped if too short to mean anything.
]]
local function windowsFrom(
	flagged: { [number]: boolean },
	cumulative: { number },
	totalLength: number,
	kind: Kind
): { Feature }
	local features: { Feature } = {}
	local length = math.max(totalLength, 1)
	local index = 1
	local count = #cumulative

	while index <= count do
		if not flagged[index] then
			index += 1
			continue
		end

		local startIndex = index
		while index <= count and flagged[index] do
			index += 1
		end
		local endIndex = index - 1

		local startStud = cumulative[startIndex] or 0
		local endStud = cumulative[endIndex] or startStud
		if endStud - startStud >= RouteFeatures.MinSpanStuds or startIndex == endIndex then
			local from = math.clamp((startStud - RouteFeatures.ApproachStuds) / length, 0, 1)
			local to = math.clamp(endStud / length, 0, 1)
			if to > from then
				table.insert(features, { kind = kind, from = from, to = to })
			end
		end
	end

	return features
end

--[[
	Find every feature on a route.

	`surfaces` is per node and may be shorter than `points`; a missing entry is
	treated as ordinary road rather than as an error, because a route that
	forgot to label one segment should still be playable.
]]
function RouteFeatures.detect(
	points: { Vector3 },
	cumulative: { number },
	surfaces: { string },
	totalLength: number
): { Feature }
	local features: { Feature } = {}
	local count = #points
	if count < 3 then
		return features
	end

	local corners: { [number]: boolean } = {}
	local descents: { [number]: boolean } = {}
	local bridges: { [number]: boolean } = {}

	for index = 2, count - 1 do
		local previous = points[index - 1]
		local current = points[index]
		local nextPoint = points[index + 1]

		local incoming = flatHeading(previous, current)
		local outgoing = flatHeading(current, nextPoint)
		if incoming and outgoing and turnDegrees(incoming, outgoing) >= RouteFeatures.CornerDegreesPerNode then
			corners[index] = true
		end

		local run = Vector3.new(nextPoint.X - current.X, 0, nextPoint.Z - current.Z).Magnitude
		if run > 1e-3 then
			local grade = (current.Y - nextPoint.Y) / run
			if grade >= RouteFeatures.DescentGrade then
				descents[index] = true
			end
		end
	end

	for index = 1, count do
		if surfaces[index] == "Bridge" then
			bridges[index] = true
		end
	end

	for _, window in windowsFrom(corners, cumulative, totalLength, RouteFeatures.Kind.Corner) do
		table.insert(features, window)
	end
	for _, window in windowsFrom(descents, cumulative, totalLength, RouteFeatures.Kind.Descent) do
		table.insert(features, window)
	end
	for _, window in windowsFrom(bridges, cumulative, totalLength, RouteFeatures.Kind.Bridge) do
		table.insert(features, window)
	end

	table.sort(features, function(a, b)
		return a.from < b.from
	end)
	return features
end

function RouteFeatures.inKind(features: { Feature }, progress: number, kind: Kind): boolean
	for _, feature in features do
		if feature.kind == kind and progress >= feature.from and progress <= feature.to then
			return true
		end
	end
	return false
end

-- Progress of the first feature of a kind, or nil when the route has none. The
-- scripted opener uses this to place its setup just short of the first corner
-- whatever route it is running on.
function RouteFeatures.firstOf(features: { Feature }, kind: Kind): number?
	for _, feature in features do
		if feature.kind == kind then
			return feature.from
		end
	end
	return nil
end

function RouteFeatures.countOf(features: { Feature }, kind: Kind): number
	local total = 0
	for _, feature in features do
		if feature.kind == kind then
			total += 1
		end
	end
	return total
end

return RouteFeatures
