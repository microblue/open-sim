# OpenRC Simulator - the things that stand on the ground.
#
# Low-poly by design. There are tens of thousands of these in view at once and
# they are seen from a model aircraft, so what matters is the silhouette and
# that no two are identical - not the triangle count. Everything is built in
# code, so the repository stays text and a species can be changed by editing a
# function rather than by opening a modelling package.
#
# One mesh per kind, instanced through a MultiMesh per cell. Per-instance colour
# carries the tint the scatter chose, which is what stops a hillside of the same
# tree reading as a repeated stamp.
class_name DetailMeshes
extends RefCounted

# Kinds, matching rc::ScatterKind.
const NONE := 0
const GRASS := 1
const SHRUB := 2
const CONIFER := 3
const BROADLEAF := 4
const DEAD_TREE := 5
const BOULDER := 6
const REED := 7
const KIND_COUNT := 8


static func build(kind: int) -> ArrayMesh:
	match kind:
		GRASS:     return _grass_tuft()
		SHRUB:     return _shrub()
		CONIFER:   return _conifer()
		BROADLEAF: return _broadleaf()
		DEAD_TREE: return _dead_tree()
		BOULDER:   return _boulder()
		REED:      return _reeds()
		_:         return _shrub()


## How far each kind is worth drawing, in metres. Grass is only there for the
## near field; a tree is a silhouette on the skyline and earns its distance.
static func view_distance(kind: int) -> float:
	match kind:
		GRASS:     return 150.0
		REED:      return 200.0
		SHRUB:     return 420.0
		BOULDER:   return 700.0
		DEAD_TREE: return 1500.0
		CONIFER, BROADLEAF: return 3200.0
		_:         return 320.0


# ------------------------------------------------------------------ species --

static func _grass_tuft() -> ArrayMesh:
	# Three crossed blades, tapering. The same idea as the flying field's grass,
	# which is deliberate: the two have to meet at the edge of the field without
	# a visible change of species.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for blade in 3:
		var angle: float = float(blade) / 3.0 * PI
		var right := Vector3(cos(angle), 0.0, sin(angle)) * 0.030
		var top := Vector3(0.0, 0.34, 0.0) + right * 0.5
		var normal := Vector3(-sin(angle) * 0.3, 0.95, cos(angle) * 0.3).normalized()
		surface.set_normal(normal)
		for v in [-right, right, top]:
			surface.add_vertex(v)
	surface.generate_normals()
	return surface.commit()


static func _shrub() -> ArrayMesh:
	# A lumpy hemisphere. Bushes are read entirely by outline at these ranges.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: int = 3
	var segments: int = 7
	var radius: float = 0.55
	for ring in rings:
		var t0: float = float(ring) / float(rings) * PI * 0.5
		var t1: float = float(ring + 1) / float(rings) * PI * 0.5
		for segment in segments:
			var a0: float = float(segment) / float(segments) * TAU
			var a1: float = float(segment + 1) / float(segments) * TAU
			var points := []
			for pair in [[t0, a0], [t0, a1], [t1, a1], [t1, a0]]:
				var t: float = pair[0]
				var a: float = pair[1]
				var wobble: float = 0.80 + 0.20 * sin(a * 3.0 + t * 4.0)
				points.append(Vector3(
					sin(t) * cos(a) * radius * wobble,
					cos(t) * radius * 0.85 * wobble,
					sin(t) * sin(a) * radius * wobble))
			# Clockwise, Godot's front face.
			for v in [points[0], points[1], points[2], points[0], points[2], points[3]]:
				surface.add_vertex(v)
	surface.generate_normals()
	return surface.commit()


static func _conifer() -> ArrayMesh:
	var surface := SurfaceTool.new()
	_trunk(surface, 2.4, 0.16, 6)
	var levels := [
		{"y": 1.6, "radius": 1.9, "height": 3.0},
		{"y": 3.3, "radius": 1.4, "height": 2.6},
		{"y": 4.8, "radius": 0.9, "height": 2.1},
	]
	for level in levels:
		_cone(surface, level["y"], level["radius"], level["height"], 8)
	surface.generate_normals()
	return surface.commit()


static func _broadleaf() -> ArrayMesh:
	var surface := SurfaceTool.new()
	_trunk(surface, 2.9, 0.20, 6)
	_blob(surface, Vector3(0.0, 4.6, 0.0), 2.4, 5, 8)
	surface.generate_normals()
	return surface.commit()


static func _dead_tree() -> ArrayMesh:
	# A bare trunk with a couple of broken limbs. At the tree line and in the
	# desert these are most of what is standing, and a bare silhouette against
	# the sky is very readable.
	var surface := SurfaceTool.new()
	_trunk(surface, 3.6, 0.15, 5)
	for limb in 3:
		var angle: float = float(limb) / 3.0 * TAU + 0.7
		var base := Vector3(0.0, 1.9 + limb * 0.7, 0.0)
		var tip: Vector3 = base + Vector3(cos(angle), 0.55, sin(angle)) * 1.15
		var side := Vector3(-sin(angle), 0.0, cos(angle)) * 0.055
		for v in [base - side, base + side, tip, base - side, tip, tip - side * 0.3]:
			surface.add_vertex(v)
	surface.generate_normals()
	return surface.commit()


static func _boulder() -> ArrayMesh:
	# An irregular lump. Rocks are all silhouette and shading; a sphere reads as
	# a ball and a box reads as a crate, so this is neither.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: int = 4
	var segments: int = 7
	for ring in rings:
		var t0: float = float(ring) / float(rings) * PI
		var t1: float = float(ring + 1) / float(rings) * PI
		for segment in segments:
			var a0: float = float(segment) / float(segments) * TAU
			var a1: float = float(segment + 1) / float(segments) * TAU
			var points := []
			for pair in [[t0, a0], [t0, a1], [t1, a1], [t1, a0]]:
				var t: float = pair[0]
				var a: float = pair[1]
				# Faceted and asymmetric, the way weathered rock breaks.
				var lump: float = 0.72 + 0.28 * sin(a * 2.0 + t * 3.0) \
					+ 0.16 * cos(a * 5.0 - t * 2.0)
				points.append(Vector3(
					sin(t) * cos(a) * 0.75 * lump,
					cos(t) * 0.52 * lump + 0.30,
					sin(t) * sin(a) * 0.85 * lump))
			for v in [points[0], points[1], points[2], points[0], points[2], points[3]]:
				surface.add_vertex(v)
	surface.generate_normals()
	return surface.commit()


static func _reeds() -> ArrayMesh:
	# A clump of tall thin blades, leaning. Only at the water's edge.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for blade in 5:
		var angle: float = float(blade) / 5.0 * TAU
		var lean := Vector3(cos(angle), 0.0, sin(angle)) * 0.22
		var base := Vector3(cos(angle), 0.0, sin(angle)) * 0.10
		var right := Vector3(-sin(angle), 0.0, cos(angle)) * 0.022
		var top: Vector3 = base + lean + Vector3(0.0, 1.05 + 0.2 * sin(float(blade)), 0.0)
		for v in [base - right, base + right, top]:
			surface.add_vertex(v)
	surface.generate_normals()
	return surface.commit()


# ------------------------------------------------------------------ helpers --

static func _trunk(surface: SurfaceTool, height: float, radius: float, sides: int) -> void:
	if surface.get_primitive_type() != Mesh.PRIMITIVE_TRIANGLES:
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in sides:
		var a0: float = float(side) / float(sides) * TAU
		var a1: float = float(side + 1) / float(sides) * TAU
		var p0 := Vector3(cos(a0) * radius, 0.0, sin(a0) * radius)
		var p1 := Vector3(cos(a1) * radius, 0.0, sin(a1) * radius)
		var q0: Vector3 = p0 * 0.68 + Vector3(0.0, height, 0.0)
		var q1: Vector3 = p1 * 0.68 + Vector3(0.0, height, 0.0)
		for v in [p0, q1, q0, p0, p1, q1]:
			surface.add_vertex(v)


static func _cone(surface: SurfaceTool, y: float, radius: float,
				  height: float, sides: int) -> void:
	var apex := Vector3(0.0, y + height, 0.0)
	for side in sides:
		var a0: float = float(side) / float(sides) * TAU
		var a1: float = float(side + 1) / float(sides) * TAU
		var p0 := Vector3(cos(a0) * radius, y, sin(a0) * radius)
		var p1 := Vector3(cos(a1) * radius, y, sin(a1) * radius)
		for v in [p0, p1, apex]:
			surface.add_vertex(v)


static func _blob(surface: SurfaceTool, centre: Vector3, radius: float,
				  rings: int, segments: int) -> void:
	for ring in rings:
		var t0: float = float(ring) / float(rings) * PI
		var t1: float = float(ring + 1) / float(rings) * PI
		for segment in segments:
			var a0: float = float(segment) / float(segments) * TAU
			var a1: float = float(segment + 1) / float(segments) * TAU
			var points := []
			for pair in [[t0, a0], [t0, a1], [t1, a1], [t1, a0]]:
				var t: float = pair[0]
				var a: float = pair[1]
				var wobble: float = 0.84 + 0.16 * sin(a * 3.0 + t * 5.0)
				points.append(centre + Vector3(
					sin(t) * cos(a) * radius * wobble,
					cos(t) * radius * 0.82 * wobble,
					sin(t) * sin(a) * radius * wobble))
			for v in [points[0], points[1], points[2], points[0], points[2], points[3]]:
				surface.add_vertex(v)
