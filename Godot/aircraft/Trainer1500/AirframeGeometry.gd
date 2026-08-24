# OpenRC Simulator - building an airframe out of lofted sections.
#
# The first version of the visible aircraft was boxes: a flat plate per
# aerodynamic section, a rectangular fuselage, a cylinder per wheel. It read as a
# paper model, and it is the thing the pilot looks at for the entire session.
#
# This builds the same aircraft as lofted surfaces instead. A wing is its actual
# airfoil swept from root to tip and closed with a rounded tip; a fuselage is a
# set of cross-sections blended along its length. Nothing here invents geometry
# the flight model does not have - the span, chord, incidence and dihedral all
# still come from the aerodynamic sections - it just stops pretending they are
# rectangles.
#
# Everything returns an ArrayMesh with generated normals and tangents so the
# materials have something to work with.
class_name AirframeGeometry
extends RefCounted

## Points around one airfoil, as (fraction of chord, half thickness / chord).
## A NACA four-digit symmetric thickness distribution, which is close enough to
## the flat-bottomed trainer sections this aircraft actually uses and is exactly
## right for the tail surfaces.
static func airfoil_loop(segments: int, thickness: float, camber: float = 0.0) -> PackedVector2Array:
	var points := PackedVector2Array()

	# Upper surface, leading edge to trailing edge, then back along the lower.
	# Cosine spacing: the leading edge is where the curvature is, and uniform
	# spacing there is what makes a low-poly airfoil look faceted.
	for side in 2:
		var sign_y: float = 1.0 if side == 0 else -1.0
		for i in segments + 1:
			var t: float = float(i) / float(segments)
			var x: float = 0.5 - 0.5 * cos(t * PI)
			if side == 1:
				x = 1.0 - x
			var half: float = thickness / 0.2 * (
				0.2969 * sqrt(max(x, 0.0))
				- 0.1260 * x
				- 0.3516 * x * x
				+ 0.2843 * x * x * x
				- 0.1015 * x * x * x * x)
			# Camber lifts the whole section; a flat-bottomed trainer wing is
			# most of its lift at zero incidence and looks wrong without it.
			var mean: float = camber * 4.0 * x * (1.0 - x)
			points.append(Vector2(x, mean + sign_y * half))
	return points


## Loft an airfoil along a span, tapering and closing the tip.
##
## `stations` is an array of dictionaries: {offset, chord, thickness, twist}.
## offset is distance along the span axis, chord scales the profile, twist
## rotates it about the quarter chord. The result is in a local frame where X
## runs along the span, Z along the chord and Y is thickness - which is the
## frame the panel basis already puts things in.
static func loft_wing(stations: Array, segments: int = 14,
					  round_tip: bool = true) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	var rings: Array[PackedVector3Array] = []
	for station in stations:
		rings.append(_ring(station, segments))

	for i in rings.size() - 1:
		_bridge(surface, rings[i], rings[i + 1])

	# Caps. The root butts against the fuselage so it is closed flat; the tip is
	# rounded, because a wing that ends in a sharp rectangle is the single most
	# obvious tell that a model was made of boxes.
	_cap(surface, rings[0], true)
	if round_tip:
		var tip: Dictionary = stations[stations.size() - 1]
		_round_tip(surface, rings[rings.size() - 1], tip, segments)
	else:
		_cap(surface, rings[rings.size() - 1], false)

	surface.generate_normals()
	# No tangents: these surfaces carry no normal map, and generate_tangents()
	# needs UVs the loft does not produce.
	return surface.commit()


## Loft a fuselage from a set of cross-sections along its length.
##
## `stations` is an array of {z, width, height, offset_y, corner}. corner is how
## square the section is: 0 gives an ellipse, 1 a rounded rectangle. A model
## fuselage is somewhere in between and changes along its length - round at the
## nose, slab-sided at the tail.
static func loft_body(stations: Array, segments: int = 16) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	var rings: Array[PackedVector3Array] = []
	for station in stations:
		rings.append(_body_ring(station, segments))

	for i in rings.size() - 1:
		_bridge(surface, rings[i], rings[i + 1])

	_cap(surface, rings[0], true)
	_cap(surface, rings[rings.size() - 1], false)

	surface.generate_normals()
	# No tangents: these surfaces carry no normal map, and generate_tangents()
	# needs UVs the loft does not produce.
	return surface.commit()


# ------------------------------------------------------------------ internals

static func _ring(station: Dictionary, segments: int) -> PackedVector3Array:
	var chord: float = station.get("chord", 0.2)
	var thickness: float = station.get("thickness", 0.12)
	var camber: float = station.get("camber", 0.0)
	var twist: float = station.get("twist", 0.0)
	var offset: float = station.get("offset", 0.0)
	var sweep: float = station.get("sweep", 0.0)

	var profile: PackedVector2Array = airfoil_loop(segments, thickness, camber)
	var ring := PackedVector3Array()
	# Rotate about the quarter chord, which is where a wing is actually rigged
	# from and keeps a twisted tip in the right place.
	var pivot := Vector2(0.25, 0.0)
	for p in profile:
		var local: Vector2 = (p - pivot) * chord
		var rotated := Vector2(
			local.x * cos(twist) - local.y * sin(twist),
			local.x * sin(twist) + local.y * cos(twist))
		# X along the span, Z along the chord, Y thickness.
		ring.append(Vector3(offset, rotated.y, rotated.x + sweep))
	return ring


static func _body_ring(station: Dictionary, segments: int) -> PackedVector3Array:
	var z: float = station.get("z", 0.0)
	var half_width: float = station.get("width", 0.08) * 0.5
	var half_height: float = station.get("height", 0.10) * 0.5
	var centre_y: float = station.get("offset_y", 0.0)
	var corner: float = station.get("corner", 0.45)

	var ring := PackedVector3Array()
	for i in segments:
		var a: float = float(i) / float(segments) * TAU
		var c: float = cos(a)
		var s: float = sin(a)
		# Blend between an ellipse and a rounded rectangle - a superellipse by
		# another name, and cheaper than one.
		var square_x: float = signf(c) * pow(absf(c), 0.55)
		var square_y: float = signf(s) * pow(absf(s), 0.55)
		var x: float = lerp(c, square_x, corner) * half_width
		var y: float = lerp(s, square_y, corner) * half_height
		ring.append(Vector3(x, y + centre_y, z))
	return ring


## Two rings of equal length, joined into a tube. Clockwise winding, which is
## Godot's front face - the counter-clockwise order that looks obvious leaves
## every face back-facing.
static func _bridge(surface: SurfaceTool, a: PackedVector3Array,
					b: PackedVector3Array) -> void:
	var count: int = mini(a.size(), b.size())
	for i in count:
		var j: int = (i + 1) % count
		for v in [a[i], b[j], b[i], a[i], a[j], b[j]]:
			surface.add_vertex(v)


## Close a ring with a fan to its centroid.
static func _cap(surface: SurfaceTool, ring: PackedVector3Array, flip: bool) -> void:
	var centre := Vector3.ZERO
	for p in ring:
		centre += p
	centre /= float(ring.size())

	for i in ring.size():
		var j: int = (i + 1) % ring.size()
		if flip:
			for v in [ring[i], ring[j], centre]:
				surface.add_vertex(v)
		else:
			for v in [ring[j], ring[i], centre]:
				surface.add_vertex(v)


## A rounded wing tip: shrink the last ring over a quarter-ellipse rather than
## stopping dead.
static func _round_tip(surface: SurfaceTool, ring: PackedVector3Array,
					   station: Dictionary, segments: int) -> void:
	var chord: float = station.get("chord", 0.2)
	var steps: int = 4
	var radius: float = chord * 0.30
	var previous: PackedVector3Array = ring

	for step in range(1, steps + 1):
		var t: float = float(step) / float(steps)
		# Quarter ellipse: the section shrinks as the tip extends outward.
		var extend: float = radius * sin(t * PI * 0.5)
		var scale: float = cos(t * PI * 0.5)
		var scaled := PackedVector3Array()
		var centre := Vector3.ZERO
		for p in ring:
			centre += p
		centre /= float(ring.size())
		for p in ring:
			var flattened: Vector3 = centre + (p - centre) * scale
			scaled.append(Vector3(flattened.x + extend, flattened.y, flattened.z))
		_bridge(surface, previous, scaled)
		previous = scaled

	_cap(surface, previous, false)
	# segments is part of the signature so callers do not have to know that the
	# tip reuses the ring they already built.
	if segments < 0:
		push_warning("unreachable")
