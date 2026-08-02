--!strict

--[[
	Route one, as data.

	Every coordinate below is exactly what WorldBuilder authored in code; this
	is a move, not a redesign. The road has been tuned and driven, and the point
	of the exercise is to make a second route cheap without changing the first
	one by a stud.

	What moving it buys: the road is now buildable without the engine, so the
	headless suite can assert its length, its widths, and where its corners and
	bridges actually are. Before this, the only level in the game was the least
	testable thing in the repository.

	A second route is a second table in this shape. It is not a second function
	in an engine module.
]]

local RouteSections = require(script.Parent.RouteSections)

local Point = RouteSections.Kind.Point
local Curve = RouteSections.Kind.Curve
local EasedTurn = RouteSections.Kind.EasedTurn

--[[
	Road width ramps down over the run. Early sections are deliberately wide so
	a crew learns throttle and load shift with room to recover; the tight widths
	are the late-run target, not the opening lane.

	  ~0-17%   44 -> 36   warm-up and blind corner
	  ~17-40%  38 -> 32   breather and staged descent
	  ~40-60%  32 -> 28   rough and left bend
	  ~60%+    13 bridge, 26-28 S-bends, endgame
]]
local PLAN: { RouteSections.Step } = {
	-- 1. Warm-up straight. Long enough to find the throttle, the brake, and the
	--    fact that the load moves when you use either.
	{ kind = Point, at = Vector3.new(0, 0, 0), width = 44 },
	{ kind = Point, at = Vector3.new(0, 0, 420), width = 44 },

	-- 2. The blind right-hander, cambered the wrong way so the load wants to go
	--    outboard exactly when the driver is already committed.
	{
		kind = Curve,
		control = Vector3.new(0, -2, 570),
		at = Vector3.new(150, -6, 604),
		width = 36,
		bankDeg = -6,
		steps = 16,
	},

	-- 3. Breather, and the last flat road for a while.
	{ kind = Point, at = Vector3.new(430, -12, 644), width = 38 },

	-- 4. Long descent in three stages. The lane narrows as speed and stakes
	--    build toward the rough section.
	{ kind = Point, at = Vector3.new(637, -38, 683), width = 38 },
	{ kind = Point, at = Vector3.new(843, -77, 723), width = 34 },
	{ kind = Point, at = Vector3.new(950, -96, 744), width = 34 },
	{ kind = Point, at = Vector3.new(1050, -110, 762), width = 32 },
	{ kind = Point, at = Vector3.new(1160, -121, 786), width = 32, surface = "Rough" },

	-- 5. Broken surface. Bumps do the work, not a failure event.
	{ kind = Point, at = Vector3.new(1320, -128, 822), width = 32, surface = "Rough" },
	{ kind = Point, at = Vector3.new(1560, -132, 900), width = 30, surface = "Rough" },

	-- 6. Left-hander, so a crew that spent the whole first half braced on one
	--    side of the bed is now on the wrong side.
	{
		kind = Curve,
		control = Vector3.new(1700, -134, 948),
		at = Vector3.new(1700, -136, 1120),
		width = 28,
		bankDeg = 5,
		steps = 12,
	},

	-- 7. Bridge. No shoulders, no rails, no second chance.
	{ kind = Point, at = Vector3.new(1700, -136, 1150), width = 28 },
	{ kind = Point, at = Vector3.new(1700, -136, 1164), width = 24 },
	{ kind = Point, at = Vector3.new(1700, -136, 1176), width = 19 },
	{ kind = Point, at = Vector3.new(1700, -136, 1190), width = 13, surface = "Bridge", shoulders = false },
	{ kind = Point, at = Vector3.new(1700, -136, 1444), width = 13, surface = "Bridge", shoulders = false },

	-- 8. Climb out, which is where a dragging load really costs you.
	{ kind = Point, at = Vector3.new(1700, -136, 1458), width = 18, shoulders = false },
	{ kind = Point, at = Vector3.new(1700, -136, 1472), width = 24 },
	{ kind = Point, at = Vector3.new(1700, -136, 1490), width = 30 },
	{ kind = EasedTurn, at = Vector3.new(1622, -102, 1700), width = 30, steps = 10 },

	-- 9. S-bends. Two direction changes in a row is the cheapest way to make an
	--    already-shifted load into a second crisis.
	{
		kind = Curve,
		control = Vector3.new(1600, -94, 1822),
		at = Vector3.new(1784, -88, 1902),
		width = 28,
		bankDeg = -5,
		steps = 12,
	},
	{
		kind = Curve,
		control = Vector3.new(1962, -82, 1982),
		at = Vector3.new(1962, -76, 2122),
		width = 26,
		bankDeg = 5,
		steps = 12,
	},

	-- 10. Rough descent to finish, taken with whatever is left.
	{ kind = Point, at = Vector3.new(1962, -79.7, 2174), width = 26, surface = "Rough" },
	{ kind = Point, at = Vector3.new(1962, -88.7, 2226), width = 27, surface = "Rough" },
	{ kind = Point, at = Vector3.new(1962, -99.3, 2278), width = 27, surface = "Rough" },
	{ kind = Point, at = Vector3.new(1962, -108.3, 2330), width = 28, surface = "Rough" },
	{ kind = Point, at = Vector3.new(1962, -112, 2382), width = 28, surface = "Rough" },

	-- 11. Run-in to the depot.
	{ kind = Point, at = Vector3.new(1962, -111.1, 2441.5), width = 28 },
	{ kind = Point, at = Vector3.new(1962, -109, 2501), width = 29 },
	{ kind = Point, at = Vector3.new(1962, -106.9, 2560.5), width = 30 },
	{ kind = Point, at = Vector3.new(1962, -106, 2620), width = 30 },
}

--[[
	Leg two: The Pass.

	Route one teaches. This one tests, and it tests different things rather than
	the same things harder -- a longer version of the foothills would just be
	attrition.

	  - The run-up is a fifth as long. The crew is warm; re-teaching the throttle
	    would waste the only stretch where nobody is in trouble.
	  - It opens with a switchback instead of a single blind corner, so a crew
	    that braced for the first turn is on the wrong side for the second.
	  - Ice replaces the rough section as the surface hazard. Rough takes speed
	    away with the grip, which forgives; ice takes only the grip, so a driver
	    arrives at the next corner carrying exactly the speed that got them into
	    trouble.
	  - Two bridges, and the second one is entered off a descending traverse, so
	    the speed you cross it with is not a speed you chose.
	  - It ends short. The last quarter of route one is a run-in; here the road
	    is still asking questions at the depot gate.

	Authored well clear of route one in world space so both can exist at once.
]]
local PASS_PLAN: { RouteSections.Step } = {
	-- 1. Short run-up. Long enough to settle the load, not long enough to relax.
	{ kind = Point, at = Vector3.new(6000, 0, 0), width = 32 },
	{ kind = Point, at = Vector3.new(6000, 0, 180), width = 32 },

	-- 2. Switchback. Right, then immediately left.
	{
		kind = Curve,
		control = Vector3.new(6000, -2, 300),
		at = Vector3.new(6120, -6, 340),
		width = 28,
		bankDeg = -7,
		steps = 14,
	},
	{
		kind = Curve,
		control = Vector3.new(6260, -10, 380),
		at = Vector3.new(6260, -16, 520),
		width = 26,
		bankDeg = 6,
		steps = 14,
	},

	-- 3. Ice. Flat, fast, and it looks like the breather it is not.
	{ kind = Point, at = Vector3.new(6260, -18, 700), width = 26, surface = "Ice" },
	{ kind = Point, at = Vector3.new(6260, -20, 980), width = 26, surface = "Ice" },

	-- 4. Climb to the first crossing. A load already sliding costs you here in
	--    a way it never does on the flat.
	{ kind = Point, at = Vector3.new(6260, -8, 1120), width = 26 },
	{ kind = Point, at = Vector3.new(6260, 10, 1260), width = 24 },

	-- 5. First bridge, at the top, in the wind.
	{ kind = Point, at = Vector3.new(6260, 14, 1300), width = 20, shoulders = false },
	{ kind = Point, at = Vector3.new(6260, 16, 1330), width = 13, surface = "Bridge", shoulders = false },
	{ kind = Point, at = Vector3.new(6260, 16, 1480), width = 13, surface = "Bridge", shoulders = false },
	{ kind = Point, at = Vector3.new(6260, 14, 1510), width = 20, shoulders = false },

	-- 6. Descending traverse, on ice. The hardest stretch on either route: the
	--    grade adds the speed and the surface refuses to take it back.
	{ kind = Point, at = Vector3.new(6260, -2, 1620), width = 24, surface = "Ice" },
	{ kind = Point, at = Vector3.new(6300, -26, 1760), width = 22, surface = "Ice" },
	{ kind = Point, at = Vector3.new(6380, -52, 1900), width = 22, surface = "Ice" },

	-- 7. Second bridge, entered with whatever the traverse gave you.
	{ kind = Point, at = Vector3.new(6420, -62, 1960), width = 18, shoulders = false },
	{ kind = Point, at = Vector3.new(6440, -66, 1990), width = 13, surface = "Bridge", shoulders = false },
	{ kind = Point, at = Vector3.new(6440, -66, 2200), width = 13, surface = "Bridge", shoulders = false },
	{ kind = Point, at = Vector3.new(6440, -64, 2230), width = 20, shoulders = false },

	-- 8. Chicane through deep snow, so a wide line costs drag and not just time.
	{
		kind = Curve,
		control = Vector3.new(6440, -62, 2320),
		at = Vector3.new(6360, -58, 2400),
		width = 22,
		bankDeg = 5,
		steps = 12,
	},
	{
		kind = Curve,
		control = Vector3.new(6280, -54, 2480),
		at = Vector3.new(6360, -50, 2560),
		width = 22,
		bankDeg = -5,
		steps = 12,
	},

	-- 9. Climb out.
	{ kind = Point, at = Vector3.new(6380, -36, 2680), width = 24 },

	-- 10. Rough shelf, taken with whatever is left.
	{ kind = Point, at = Vector3.new(6400, -30, 2800), width = 26, surface = "Rough" },
	{ kind = Point, at = Vector3.new(6400, -28, 2900), width = 26, surface = "Rough" },

	-- 11. Short run-in. Still asking questions at the gate.
	{ kind = Point, at = Vector3.new(6400, -26, 3000), width = 28 },
	{ kind = Point, at = Vector3.new(6400, -25, 3120), width = 30 },
}

export type Route = {
	id: string,
	label: string,
	blurb: string,
	-- Palette the dressing reads. Geometry and look are separate on purpose: a
	-- third route can be this one in a different season.
	skin: string,
	plan: { RouteSections.Step },
	-- Named for the landmark and the warp targets that still point at it.
	cornerPosition: Vector3,
}

--[[
	Legs, in the order a session climbs them. Index is the leg number, so
	finishing leg one puts a crew on leg two rather than back where they started.
]]
local ROUTES: { Route } = {
	{
		id = "Foothills",
		label = "THE FOOTHILLS",
		blurb = "Long road, one blind corner, one bridge.",
		skin = "Temperate",
		plan = PLAN,
		cornerPosition = Vector3.new(0, 0, 420),
	},
	{
		id = "ThePass",
		label = "THE PASS",
		blurb = "Switchbacks, ice, and two crossings.",
		skin = "Alpine",
		plan = PASS_PLAN,
		cornerPosition = Vector3.new(6120, -6, 340),
	},
}

local LabRoute = {}

LabRoute.Routes = ROUTES
LabRoute.Plan = PLAN

-- Where the blind right-hander is, for the landmark and the warp targets that
-- still name it directly.
LabRoute.CornerPosition = ROUTES[1].cornerPosition

-- A leg past the last authored route repeats the hardest one rather than
-- ending the session. Running out of road should not be a failure state.
function LabRoute.forLeg(leg: number): Route
	local index = math.clamp(math.floor(leg or 1), 1, #ROUTES)
	return ROUTES[index]
end

function LabRoute.byId(id: string?): Route?
	for _, route in ROUTES do
		if route.id == id then
			return route
		end
	end
	return nil
end

function LabRoute.nodes(routeId: string?): { RouteSections.RouteNode }
	local route = LabRoute.byId(routeId) or ROUTES[1]
	return RouteSections.build(route.plan)
end

return LabRoute
