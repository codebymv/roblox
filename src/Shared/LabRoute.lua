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

local LabRoute = {}

LabRoute.Plan = PLAN

-- Where the blind right-hander is, for the landmark and the warp targets that
-- still name it directly.
LabRoute.CornerPosition = Vector3.new(0, 0, 420)

function LabRoute.nodes(): { RouteSections.RouteNode }
	return RouteSections.build(PLAN)
end

return LabRoute
