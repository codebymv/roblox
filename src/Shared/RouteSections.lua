--!strict

--[[
	Turning a route plan into road nodes.

	The generators here were inside WorldBuilder, which is an engine module: it
	touches Workspace on the first line, so nothing about the road's shape could
	be checked without Studio running. The road is the game's only level and its
	geometry decides where every corner, descent and bridge is, which made it
	the least testable and most load-bearing thing in the project.

	Moving the generators out makes a route a value. A plan is data, building it
	is a pure function, and the headless suite can now assert things about the
	actual road people drive rather than about a synthetic one.

	The three step kinds are the three the authored route already used. They are
	deliberately not a general curve vocabulary: they are what this road is made
	of, and inventing shapes nobody has driven would be adding surface area to
	an untested area.
]]

local RouteSections = {}

export type RouteNode = {
	position: Vector3,
	width: number,
	surface: string,
	bankDeg: number,
	shoulders: boolean,
}

--[[
	Plan steps, in the absolute world coordinates the road was authored in.

	Absolute rather than relative on purpose. Converting the existing route to
	offsets is thirty subtractions with no way to check the answer short of
	driving it, and the road is already tuned. Relative composition is worth
	having when there is a second route to compose; it is not worth silently
	moving this one.
]]
export type Step = {
	kind: string,
	-- Point: the node lands here. Curve: the Bezier ends here. EasedTurn: the
	-- turn ends here.
	at: Vector3,
	-- Curve only. The Bezier control point.
	control: Vector3?,
	width: number,
	surface: string?,
	bankDeg: number?,
	shoulders: boolean?,
	-- Curve and EasedTurn only. How many nodes the shape is cut into.
	steps: number?,
}

RouteSections.Kind = {
	Point = "Point",
	Curve = "Curve",
	EasedTurn = "EasedTurn",
}

local function node(position: Vector3, width: number, surface: string, bankDeg: number, shoulders: boolean): RouteNode
	return { position = position, width = width, surface = surface, bankDeg = bankDeg, shoulders = shoulders }
end

local function quadratic(a: Vector3, control: Vector3, b: Vector3, t: number): Vector3
	local inv = 1 - t
	return a * (inv * inv) + control * (2 * inv * t) + b * (t * t)
end

local function smoothstep(alpha: number): number
	return alpha * alpha * (3 - 2 * alpha)
end

local function appendCurve(nodes: { RouteNode }, step: Step)
	local previous = nodes[#nodes]
	local from = previous.position
	local startWidth = previous.width
	local control = step.control or from
	local count = math.max(1, math.floor(step.steps or 12))
	local bank = step.bankDeg or 0

	for index = 1, count do
		local alpha = index / count
		local smooth = smoothstep(alpha)
		local width = startWidth + (step.width - startWidth) * smooth
		-- Camber eases in and out instead of changing the collision normal by
		-- three degrees at each end of every authored curve.
		local curveBank = bank * math.sin(math.pi * alpha)
		table.insert(nodes, node(quadratic(from, control, step.at, alpha), width, "Road", curveBank, true))
	end
end

--[[
	A mostly-forward lane change with its grade eased together. Linear X here
	made the bridge exit turn almost eighteen degrees at a single collision seam
	even though the following points looked visually gradual.
]]
local function appendEasedTurn(nodes: { RouteNode }, step: Step)
	local previous = nodes[#nodes]
	local from = previous.position
	local startWidth = previous.width
	local count = math.max(1, math.floor(step.steps or 10))
	local surface = step.surface or "Road"

	for index = 1, count do
		local alpha = index / count
		local smooth = smoothstep(alpha)
		local position = Vector3.new(
			from.X + (step.at.X - from.X) * smooth,
			from.Y + (step.at.Y - from.Y) * smooth,
			from.Z + (step.at.Z - from.Z) * alpha
		)
		local width = startWidth + (step.width - startWidth) * smooth
		table.insert(nodes, node(position, width, surface, 0, true))
	end
end

--[[
	Fold a plan into nodes.

	The first step has to be a Point: a curve and an eased turn are both defined
	relative to where the road already is, so there is nothing for them to start
	from.
]]
function RouteSections.build(plan: { Step }): { RouteNode }
	local nodes: { RouteNode } = {}
	if #plan == 0 then
		return nodes
	end

	assert(plan[1].kind == RouteSections.Kind.Point, "A route plan must open with a Point step")

	for _, step in plan do
		if step.kind == RouteSections.Kind.Point then
			table.insert(
				nodes,
				node(
					step.at,
					step.width,
					step.surface or "Road",
					step.bankDeg or 0,
					if step.shoulders == nil then true else step.shoulders
				)
			)
		elseif step.kind == RouteSections.Kind.Curve then
			appendCurve(nodes, step)
		elseif step.kind == RouteSections.Kind.EasedTurn then
			appendEasedTurn(nodes, step)
		else
			error("Unknown route step kind: " .. tostring(step.kind))
		end
	end

	return nodes
end

-- Arc length of a built route, and the running length at each node. The same
-- numbers WorldBuilder needs, available without the engine.
function RouteSections.measure(nodes: { RouteNode }): ({ Vector3 }, { number }, { string }, number)
	local points: { Vector3 } = {}
	local cumulative: { number } = {}
	local surfaces: { string } = {}
	local total = 0

	for index, entry in nodes do
		points[index] = entry.position
		surfaces[index] = entry.surface
		if index == 1 then
			cumulative[index] = 0
		else
			total += (entry.position - nodes[index - 1].position).Magnitude
			cumulative[index] = total
		end
	end

	return points, cumulative, surfaces, math.max(total, 1)
end

return RouteSections
