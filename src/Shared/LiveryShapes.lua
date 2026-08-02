--!strict

--[[
	Liveries as geometry, because the truck is geometry.

	Every panel on this vehicle is a Part. A decal needs an upload per pattern
	and a SurfaceAppearance needs a MeshPart, which the truck does not have --
	so a pattern made of thin Parts welded to the cab is not a compromise here,
	it is the same technique the grille bars and the mirror arms already use.
	Nine liveries cost nine tables and no uploads, and nothing can be moderated
	out from under a player who earned one.

	Shapes are authored for the left flank and mirrored, so a livery is written
	once and is symmetrical by construction rather than by careful typing.

	Colour is a shade of the equipped paint rather than a colour of its own.
	That is what keeps forty-eight combinations from containing ugly ones: a
	livery cannot clash with a paint it was never designed against, because it
	is always made of that paint.

	Engine-free, so the suite can check that every shape actually sits on the
	cab instead of floating beside it -- which is exactly the kind of thing that
	looks fine in the one place it was authored and wrong everywhere else.
]]

local LiveryShapes = {}

export type Shape = {
	-- Thickness on X, then height and length. The panel is a flank, so X is
	-- always the thin axis.
	size: Vector3,
	-- From the cab centre. X is set by the mirror, so it is written as the
	-- distance out from the centreline and applied to both sides.
	offset: Vector3,
	-- Tilt within the flank plane. A flame lick and a chevron are the same
	-- rectangle at different angles.
	rollDeg: number,
	--[[
		Multiplies the paint colour. Below one is a shadow of the player's
		colour, above one is a highlight of it. Both stay recognisably the same
		paint, which is why no combination can clash.
	]]
	shade: number,
}

-- Cab half-extents, from LabConfig.CabSize. Shapes are validated against these
-- so a livery cannot be authored hanging off the bodywork.
LiveryShapes.CabHalfWidth = 4.2
LiveryShapes.CabHalfHeight = 3.3
LiveryShapes.CabHalfDepth = 3

-- Just proud of the door, which sits at 4.23 and is 0.14 thick.
LiveryShapes.FlankX = 4.33

local function lick(height: number, length: number, y: number, z: number, roll: number, shade: number): Shape
	return {
		size = Vector3.new(0.06, height, length),
		offset = Vector3.new(LiveryShapes.FlankX, y, z),
		rollDeg = roll,
		shade = shade,
	}
end

--[[
	One entry per livery. Plain is empty on purpose: the default is the truck
	with nothing on it, and an empty list is a livery rather than a missing one.
]]
local SHAPES: { [string]: { Shape } } = {
	Plain = {},

	-- Tapering licks swept backward, biggest at the front. Corny by design.
	Flames = {
		lick(1.7, 2.2, -0.5, -1.5, 8, 1.55),
		lick(1.3, 1.9, 0.35, -0.4, 14, 1.55),
		lick(1.0, 1.7, -0.9, 0.5, -6, 1.55),
		lick(0.7, 1.2, 0.9, 1.3, 18, 1.75),
	},

	-- Two bands down the flank. The only livery that reads at any distance.
	Stripes = {
		lick(0.55, 5.4, 0.55, 0, 0, 1.6),
		lick(0.55, 5.4, -0.35, 0, 0, 1.6),
	},

	-- Angled bars, borrowed off a road crew's tailgate.
	Chevrons = {
		lick(0.75, 2.4, -0.6, -1.8, 38, 1.7),
		lick(0.75, 2.4, -0.6, -0.6, 38, 0.45),
		lick(0.75, 2.4, -0.6, 0.6, 38, 1.7),
		lick(0.75, 2.4, -0.6, 1.8, 38, 0.45),
	},

	-- A single band of alternating squares.
	Checkers = {
		lick(0.7, 0.7, 0.4, -2.1, 0, 0.4),
		lick(0.7, 0.7, 1.1, -1.4, 0, 1.7),
		lick(0.7, 0.7, 0.4, -0.7, 0, 0.4),
		lick(0.7, 0.7, 1.1, 0, 0, 1.7),
		lick(0.7, 0.7, 0.4, 0.7, 0, 0.4),
		lick(0.7, 0.7, 1.1, 1.4, 0, 1.7),
	},

	-- Patches low on the panel, where a truck actually corrodes.
	Rust = {
		lick(1.1, 1.6, -1.9, -1.9, 4, 0.5),
		lick(0.8, 2.2, -2.2, -0.2, -3, 0.45),
		lick(1.3, 1.3, -1.7, 1.6, 7, 0.55),
		lick(0.6, 1.0, -2.4, 2.3, 0, 0.4),
	},

	-- One thin line, done by hand by somebody's uncle.
	Pinstripe = {
		lick(0.16, 5.5, 0.9, 0, 0, 1.9),
		lick(0.16, 5.5, 0.62, 0, 0, 1.9),
	},

	-- A zigzag, which is three rectangles pretending.
	Lightning = {
		lick(0.45, 2.2, 0.9, -1.7, 34, 1.85),
		lick(0.45, 1.8, 0, 0, -40, 1.85),
		lick(0.45, 2.2, -0.9, 1.6, 34, 1.85),
	},

	-- Blocky, unconvincing, and that is the joke.
	Skulls = {
		lick(1.2, 1.0, 0.5, -1.2, 0, 1.8),
		lick(0.45, 1.0, -0.35, -1.2, 0, 1.8),
		lick(0.3, 0.28, 0.55, -1.45, 0, 0.25),
		lick(0.3, 0.28, 0.55, -0.95, 0, 0.25),
		lick(1.2, 1.0, 0.5, 1.4, 0, 1.8),
		lick(0.45, 1.0, -0.35, 1.4, 0, 1.8),
		lick(0.3, 0.28, 0.55, 1.15, 0, 0.25),
		lick(0.3, 0.28, 0.55, 1.65, 0, 0.25),
	},
}

function LiveryShapes.forLivery(id: string?): { Shape }
	if id == nil then
		return SHAPES.Plain
	end
	return SHAPES[id] or SHAPES.Plain
end

function LiveryShapes.has(id: string?): boolean
	return id ~= nil and SHAPES[id] ~= nil
end

-- Ids that have shapes, for the suite to check against the Cosmetics ladder.
function LiveryShapes.ids(): { string }
	local list = {}
	for id in SHAPES do
		table.insert(list, id)
	end
	table.sort(list)
	return list
end

--[[
	Does a shape sit on the cab?

	Checked against the panel's own extents rather than eyeballed, because a
	livery that hangs off the bodywork looks like a bug and is authored by
	typing one number wrong.
]]
function LiveryShapes.fitsOnCab(shape: Shape): boolean
	local halfHeight = shape.size.Y * 0.5
	local halfLength = shape.size.Z * 0.5
	--[[
		The bounding box of the shape at its own angle, not the diagonal. The
		diagonal is the box a shape would need if it could be rotated to any
		angle, which is far larger than the truth for the shallow tilts a flame
		lick or a chevron actually uses, and it rejects shapes that fit.
	]]
	local roll = math.rad(shape.rollDeg or 0)
	local cos, sin = math.abs(math.cos(roll)), math.abs(math.sin(roll))
	local sweptHeight = halfHeight * cos + halfLength * sin
	local sweptLength = halfHeight * sin + halfLength * cos

	if math.abs(shape.offset.Y) + sweptHeight > LiveryShapes.CabHalfHeight then
		return false
	end
	if math.abs(shape.offset.Z) + sweptLength > LiveryShapes.CabHalfDepth then
		return false
	end
	return true
end

return LiveryShapes
