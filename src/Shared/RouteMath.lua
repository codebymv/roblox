--!strict

--[[
	Arc-length maths for a polyline route.

	Pulled out of WorldBuilder so it can be tested without an engine. It touches
	no service, requires no module, and reads no global other than the Vector3
	and CFrame constructors, which is exactly what makes it runnable under Lune
	in CI rather than only inside Studio.

	Keeping this file dependency-free is the point of it. If it ever needs a
	service, the thing it needs belongs in the caller.
]]

export type Route = {
	points: { Vector3 },
	cumulative: { number },
	totalLength: number,
}

local RouteMath = {}

--[[
	How far along the route a position is, as a fraction.

	Projects onto the nearest centreline segment rather than reading a single
	world axis, so a route that turns a corner still measures as forward
	movement. Reading Z alone reports no progress at all along a leg that runs
	east, which is the bug this replaces.
]]
function RouteMath.progress(route: Route, position: Vector3): number
	local bestDistance = math.huge
	local bestLength = 0

	for index = 1, #route.points - 1 do
		local a = route.points[index]
		local b = route.points[index + 1]
		local segment = b - a
		local segmentLength = segment.Magnitude
		if segmentLength > 0.001 then
			local t = math.clamp((position - a):Dot(segment) / (segmentLength * segmentLength), 0, 1)
			local closest = a + segment * t
			local distance = (position - closest).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				bestLength = route.cumulative[index] + segmentLength * t
			end
		end
	end

	return math.clamp(bestLength / route.totalLength, 0, 1)
end

--[[
	The inverse: a CFrame on the centreline at a given fraction of the route,
	raised by `height` and facing the way the route runs.
]]
function RouteMath.cframeAt(route: Route, progress: number, height: number): CFrame
	local lift = Vector3.new(0, height, 0)
	local target = math.clamp(progress, 0, 1) * route.totalLength

	for index = 1, #route.points - 1 do
		local spanStart = route.cumulative[index]
		local spanEnd = route.cumulative[index + 1]
		local span = spanEnd - spanStart
		if span > 0.001 and target <= spanEnd then
			local a = route.points[index]
			local b = route.points[index + 1]
			local position = a:Lerp(b, math.clamp((target - spanStart) / span, 0, 1)) + lift
			local direction = b - a
			if direction.Magnitude < 0.001 then
				direction = Vector3.new(0, 0, 1)
			end
			return CFrame.lookAt(position, position + direction.Unit)
		end
	end

	local count = #route.points
	local last = route.points[count] + lift
	local direction = route.points[count] - route.points[math.max(count - 1, 1)]
	if direction.Magnitude < 0.001 then
		direction = Vector3.new(0, 0, 1)
	end
	return CFrame.lookAt(last, last + direction.Unit)
end

return RouteMath
