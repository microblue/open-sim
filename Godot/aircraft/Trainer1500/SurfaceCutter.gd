# OpenRC Simulator - cutting control surfaces out of a downloaded airframe.
#
# The generated aeroplane hinged every aileron, elevator and rudder off the
# aerodynamic section the flight model was deflecting, so the surfaces moved
# because the flight model moved them. A downloaded airframe is one solid mesh
# and has none of that: the aeroplane looked far better and stopped responding,
# which in a TRAINING simulator is the wrong trade. A student learning
# orientation watches the ailerons.
#
# So the surfaces are cut out of the mesh at load time. Each one is a region of
# the aeroplane - a span band, a height band, and everything aft of a hinge line
# - and the triangles inside it are clipped away from the ones outside and
# reparented to a pivot on the hinge. Triangles that straddle a boundary are
# split, not rounded to the nearest side: on a wing of a few hundred triangles
# a jagged seam is the whole trailing edge.
#
# This is per-vertex work at load time, which is only reasonable because the
# airframes are small - 5 to 23 thousand triangles, one pass over which costs
# under seven milliseconds (tests/MeshBudget.gd). It would not be reasonable on
# a film asset, and the alternative - baking the cut offline - would mean
# reimplementing the fit in a second language, which is exactly how the last
# orientation bug survived.
extends RefCounted

## One vertex of a polygon being clipped. Kept as a dictionary rather than a
## packed struct because GDScript has no struct and the counts are small.
const POSITION := "p"
const NORMAL := "n"
const UV := "t"


## Clips `polygon` by the plane `normal . x = distance`, keeping the side the
## normal points AWAY from as "inside".
##
## Returns [inside, outside]. Either may be empty. Vertices created on the cut
## are interpolated, so the two halves share an edge exactly and no light leaks
## between them.
static func clip(polygon: Array, normal: Vector3, distance: float) -> Array:
	var inside: Array = []
	var outside: Array = []
	var count: int = polygon.size()
	if count == 0:
		return [inside, outside]

	for i in count:
		var a: Dictionary = polygon[i]
		var b: Dictionary = polygon[(i + 1) % count]
		var da: float = normal.dot(a[POSITION]) - distance
		var db: float = normal.dot(b[POSITION]) - distance

		if da <= 0.0:
			inside.append(a)
		else:
			outside.append(a)
		# A sign change means the edge crosses the plane: both halves get the
		# crossing point, which is what keeps the seam watertight.
		if (da < 0.0 and db > 0.0) or (da > 0.0 and db < 0.0):
			var t: float = da / (da - db)
			var cut := _lerp_vertex(a, b, t)
			inside.append(cut)
			outside.append(cut)
	return [inside, outside]


static func _lerp_vertex(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	return {
		POSITION: (a[POSITION] as Vector3).lerp(b[POSITION], t),
		NORMAL: ((a[NORMAL] as Vector3).lerp(b[NORMAL], t)).normalized(),
		UV: (a[UV] as Vector2).lerp(b[UV], t),
	}


## Splits a triangle soup into the part inside `region` and aft of `hinge`, and
## everything else.
##
## `planes` is an array of [normal, distance]; a triangle is "inside" only if it
## is inside every one of them. Pieces that fall outside any plane are put back
## with the fixed structure rather than discarded, so no geometry is lost - the
## aeroplane after the cut has exactly the surface area it had before.
static func split(vertices: Array, planes: Array) -> Array:
	var moving: Array = []
	var fixed: Array = []

	var triangle: int = 0
	while triangle + 2 < vertices.size():
		var polygon: Array = [vertices[triangle], vertices[triangle + 1],
							  vertices[triangle + 2]]
		triangle += 3
		for plane in planes:
			if polygon.is_empty():
				break
			var halves: Array = clip(polygon, plane[0], plane[1])
			polygon = halves[0]
			_fan(fixed, halves[1])
		_fan(moving, polygon)
	return [moving, fixed]


## Fan-triangulates a convex polygon into `out`.
static func _fan(out: Array, polygon: Array) -> void:
	if polygon.size() < 3:
		return
	for i in range(1, polygon.size() - 1):
		out.append(polygon[0])
		out.append(polygon[i])
		out.append(polygon[i + 1])
