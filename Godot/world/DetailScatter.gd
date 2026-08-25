# OpenRC Simulator - populating the ground you fly over.
#
# The streamed terrain is a shaded surface. From height that is enough; low over
# it, it is a coloured sheet, and low is where a model spends its life. This puts
# grass, scrub, trees, boulders and reeds on it, decided by the C++ scatter -
# which knows the biome, the slope and the water line, and is a pure function of
# position so nothing moves when you turn around.
#
# Pre-generated where it matters, streamed where it does not.
#
#   The circuit - everything within PREBUILT_RADIUS of the field - is built in
#   full before the first frame. That is the ground the pilot actually flies
#   over, and scenery appearing in it while they are looking at it is worse than
#   scenery that was never there.
#
#   Beyond that, cells are added and dropped a few at a time as the camera
#   moves. A baked scene file would avoid the streaming entirely and would also
#   give the world an edge, which is the thing this replaced.
#
# Two tiers, because the useful radius differs by an order of magnitude between
# a grass tuft and a tree on a ridgeline. Small cells close in carrying
# everything; large cells further out carrying only what is still a silhouette
# at that range.
extends Node3D

const Meshes := preload("res://world/DetailMeshes.gd")
const DetailShaders := preload("res://world/DetailShaders.gd")
const Assets := preload("res://world/DetailAssets.gd")
const Obstacles := preload("res://world/TreeObstacles.gd")

## Tiers: cell size, how far out to keep cells, candidate points per cell, and
## which kinds this tier is allowed to place.
const TIERS: Array[Dictionary] = [
	{
		"name": "cover",
		"layer": 0,                      # ground cover: dense, close in
		"cell": 72.0,
		"radius": 460.0,
		# Pre-generated only as far as it is worth seeing. Forcing the ground
		# cover out to the circuit radius built six hundred cells of grass that
		# is invisible past ninety metres, and spent several seconds of the load
		# doing it.
		"prebuild": 460.0,
		"count": 1000,
		"kinds": [Meshes.GRASS, Meshes.SHRUB, Meshes.REED],
	},
	{
		"name": "canopy_near",
		"layer": 1,                      # trees and boulders, full detail
		"cell": 120.0,
		"radius": 1000.0,
		"prebuild": 1200.0,
		"count": 240,
		"kinds": [Meshes.CONIFER, Meshes.BROADLEAF, Meshes.DEAD_TREE, Meshes.BOULDER],
	},
	{
		"name": "canopy_far",
		"layer": 1,                      # the same trees, out to the skyline
		"cell": 420.0,
		"radius": 3400.0,
		"prebuild": 2000.0,
		"count": 1500,
		"kinds": [Meshes.CONIFER, Meshes.BROADLEAF, Meshes.DEAD_TREE],
	},
]

## Everything within this of the field is generated before the first frame.
const PREBUILT_RADIUS: float = 900.0

## Cells added per frame once running. Enough to keep up with a trainer at
## cruise, few enough that a rebuild is never a visible hitch - and a hitch at
## 240 Hz physics is dropped steps.
const CELLS_PER_FRAME: int = 6

## Fraction of a kind's view distance at which it drops to its far model.
const LOD_SPLIT: float = 0.22

## How far the camera must move before the cell list is re-examined.
const SURVEY_STEP: float = 24.0

@export var simulation_path: NodePath
@export var camera_path: NodePath
@export var seed_value: int = 20260823

var _sim: RCSimulationNode
var _camera: Node3D
var _meshes: Array[ArrayMesh] = []
var _materials: Array[ShaderMaterial] = []
var _tier_roots: Array[Node3D] = []
## One entry per live cell, keyed "tier:x:y".
var _cells: Dictionary = {}
var _pending: Array = []
var _last_survey: Vector2 = Vector2(1e12, 1e12)


func _ready() -> void:
	_sim = get_node_or_null(simulation_path) as RCSimulationNode
	if _sim == null:
		return

	for kind in Meshes.KIND_COUNT:
		var mesh: ArrayMesh = Meshes.build(kind) if kind != Meshes.NONE else null
		_meshes.append(mesh)
		var material: ShaderMaterial = DetailShaders.material_for(kind)
		# The sway needs to know how tall the thing it is bending actually is.
		# Left at its default of one metre, an eight-metre tree clamped to full
		# sway a metre off the ground and translated like a plank.
		if mesh != null and material != null:
			material.set_shader_parameter("top_height", maxf(mesh.get_aabb().size.y, 0.05))
		_materials.append(material)

	for tier in TIERS.size():
		var root := Node3D.new()
		root.name = "Tier_%s" % TIERS[tier]["name"]
		add_child(root)
		_tier_roots.append(root)

	# The circuit, in full, before anything is rendered.
	_queue_cells(Vector2.ZERO, PREBUILT_RADIUS)
	while not _pending.is_empty():
		_build_next()
	var built: int = 0
	for tier_root in _tier_roots:
		for holder in tier_root.get_children():
			for kind_node in holder.get_children():
				if kind_node is MultiMeshInstance3D:
					built += (kind_node as MultiMeshInstance3D).multimesh.instance_count
	print("[Detail] circuit pre-generated: %d cells, %d objects on the ground"
		% [_cells.size(), built])


## Throw away every scattered cell and regenerate the circuit. Called when a
## scene preset changes the world underneath them - vegetation placed by the old
## climate is standing in the wrong place, or in the sea.
func rebuild() -> void:
	Obstacles.clear_scatter()
	for key in _cells:
		var holder = _cells[key]
		if holder != null and is_instance_valid(holder):
			holder.queue_free()
	_cells.clear()
	_pending.clear()
	_last_survey = Vector2(1e12, 1e12)
	_queue_cells(_focus(), PREBUILT_RADIUS)
	while not _pending.is_empty():
		_build_next()
	Obstacles.flush(_sim)


func _process(_delta: float) -> void:
	if _sim == null:
		return

	# Only look for work when the camera has actually moved. Scanning every cell
	# in a dictionary of several hundred, every frame, to discover that nothing
	# needs building was costing milliseconds for nothing.
	var focus: Vector2 = _focus()
	if _pending.is_empty() and focus.distance_squared_to(_last_survey) > SURVEY_STEP * SURVEY_STEP:
		_last_survey = focus
		_queue_cells(focus, 0.0)
		_drop_distant()

	for i in CELLS_PER_FRAME:
		if _pending.is_empty():
			break
		_build_next()


func _focus() -> Vector2:
	# The active camera, not the rig that holds it. The rig stands still in the
	# pilot view while the camera inside it turns, and in the other views it is
	# the camera that has been moved - so following the rig generated the world
	# around a point nobody was looking from.
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera != null:
		return Vector2(camera.global_position.x, camera.global_position.z)

	if _camera == null:
		_camera = get_node_or_null(camera_path) as Node3D
	var here: Vector3 = _camera.global_position if _camera != null else _sim.global_position
	return Vector2(here.x, here.z)


## Queue every cell that should exist around `centre` and does not yet.
## `extra` widens the radius, which is how the pre-built circuit is requested.
func _queue_cells(centre: Vector2, extra: float) -> void:
	for tier in TIERS.size():
		var config: Dictionary = TIERS[tier]
		var cell: float = config["cell"]
		var radius: float = float(config["prebuild"]) if extra > 0.0 \
			else float(config["radius"])
		var span: int = int(ceil(radius / cell))

		var base_x: int = int(floor(centre.x / cell))
		var base_y: int = int(floor(centre.y / cell))

		for dy in range(-span, span + 1):
			for dx in range(-span, span + 1):
				var cx: int = base_x + dx
				var cy: int = base_y + dy
				var here := Vector2((float(cx) + 0.5) * cell, (float(cy) + 0.5) * cell)
				if here.distance_to(centre) > radius:
					continue
				var key: String = "%d:%d:%d" % [tier, cx, cy]
				if _cells.has(key):
					continue
				_cells[key] = null           # claimed, so it is queued once
				_pending.append([tier, cx, cy, key])

	# Nearest first, so what the pilot is about to fly over exists first.
	var centre_copy: Vector2 = centre
	_pending.sort_custom(func(a, b):
		var ca: float = TIERS[a[0]]["cell"]
		var cb: float = TIERS[b[0]]["cell"]
		var pa := Vector2((float(a[1]) + 0.5) * ca, (float(a[2]) + 0.5) * ca)
		var pb := Vector2((float(b[1]) + 0.5) * cb, (float(b[2]) + 0.5) * cb)
		return pa.distance_squared_to(centre_copy) < pb.distance_squared_to(centre_copy))


func _build_next() -> void:
	var entry: Array = _pending.pop_front()
	var tier: int = entry[0]
	var config: Dictionary = TIERS[tier]
	var cell: float = config["cell"]
	var centre := Vector2((float(entry[1]) + 0.5) * cell, (float(entry[2]) + 0.5) * cell)

	var data: Dictionary = _sim.scatter_detail(centre.x, centre.y, cell,
											   int(config["count"]), seed_value,
											   int(config["layer"]))
	var positions: PackedVector3Array = data["positions"]
	if positions.is_empty():
		_cells[entry[3]] = Node3D.new()   # an empty marker, so it is not requeued
		return

	var kinds: PackedInt32Array = data["kinds"]
	var yaws: PackedFloat32Array = data["yaws"]
	var scales: PackedFloat32Array = data["scales"]
	var tints: PackedFloat32Array = data["tints"]
	var normals: PackedVector3Array = data["normals"]

	var holder := Node3D.new()
	holder.name = "Cell_%d_%d" % [entry[1], entry[2]]

	var allowed: Array = config["kinds"]
	for kind in allowed:
		# Gather this kind's instances once, then split them across the scanned
		# species so a wood is not one tree repeated, and across two levels of
		# detail so a tree passed at fifty metres and one on a ridgeline two
		# kilometres away are not the same object.
		var indices := PackedInt32Array()
		for i in positions.size():
			if kinds[i] == kind:
				indices.push_back(i)
		if indices.is_empty():
			continue

		var far_start: float = Meshes.view_distance(kind) * LOD_SPLIT

		# Foliage first: an impostor is the only affordable way to draw a
		# scanned tree, so where one has been baked it carries the whole range.
		var impostor_variants: int = Assets.impostor_variants(kind)
		var used_impostors := false
		for variant in impostor_variants:
			var impostor: Dictionary = Assets.impostor_for(_sim, kind, variant)
			if impostor.is_empty():
				continue
			used_impostors = true
			_add_batch(holder, indices, positions, normals, yaws, scales, tints,
					   kind, impostor["mesh"], false, variant, impostor_variants,
					   -1, far_start, tier, impostor["material"])
		if used_impostors:
			continue

		var variants: int = Assets.variant_count(kind)
		for variant in variants:
			for level in 2:
				var mesh: Mesh = Assets.mesh_for(_sim, kind, level, variant)
				var generated: bool = mesh == null
				if generated:
					if variant > 0 or level > 0:
						continue          # only one generated shape per kind
					mesh = _meshes[kind]
				_add_batch(holder, indices, positions, normals, yaws, scales, tints,
						   kind, mesh, generated, variant, variants, level,
						   far_start, tier, null)

	_tier_roots[tier].add_child(holder)
	_cells[entry[3]] = holder
	Obstacles.flush(_sim)


## One MultiMesh: the instances of `kind` that belong to this species and this
## level of detail.
func _add_batch(holder: Node3D, indices: PackedInt32Array,
				positions: PackedVector3Array, normals: PackedVector3Array,
				yaws: PackedFloat32Array, scales: PackedFloat32Array,
				tints: PackedFloat32Array, kind: int, mesh: Mesh,
				generated: bool, variant: int, variants: int, level: int,
				far_start: float, tier: int, override: Material) -> void:
	# Which instances belong to this species. Chosen by index rather than at
	# random so the split is stable when the cell is rebuilt.
	var mine := PackedInt32Array()
	for slot in indices.size():
		if variants <= 1 or slot % variants == variant:
			mine.push_back(indices[slot])
	if mine.is_empty():
		return

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.mesh = mesh
	multi.instance_count = mine.size()

	# An impostor is sized in metres by its own bake metrics, so the scatter's
	# scale only varies it; a generated mesh is nominal and gets the full range.
	var asset_scale: float = Assets.scale_for(kind) if not generated else 1.0

	for slot in mine.size():
		var i: int = mine[slot]
		var scale: float = scales[i] * asset_scale
		# Leaned into the slope rather than standing vertical on it. A tree at
		# right angles to a hillside is one of the immediate tells that scenery
		# was dropped on rather than grown.
		var up: Vector3 = normals[i].normalized().lerp(Vector3.UP, 0.55).normalized()
		var basis := Basis(Vector3.UP, yaws[i])
		if up.dot(Vector3.UP) < 0.999:
			basis = Basis(Vector3.UP.cross(up).normalized(),
						  acos(clampf(up.dot(Vector3.UP), -1.0, 1.0))) * basis
		basis = basis.scaled(Vector3(scale, scale, scale))
		multi.set_instance_transform(slot, Transform3D(basis, positions[i]))
		var tint: float = tints[i]
		# A narrow spread. Wide per-instance tinting was fine over flat colours
		# and blows the highlights out of a photograph.
		multi.set_instance_color(slot, Color(0.90 + tint * 0.16,
											 0.93 + tint * 0.12,
											 0.90 + tint * 0.15))

		# The physics needs to know the trees are solid. One cylinder per
		# tree, registered once: impostors (level < 0) carry the whole range
		# in one batch, and generated meshes register at the near level only.
		if level < 0 or level == 0:
			var trunk_radius: float = Meshes.collision_radius(kind) * scale
			var tree_height: float = Meshes.collision_height(kind) * scale
			if trunk_radius > 0.0:
				Obstacles.add_scatter(positions[i].x, positions[i].z,
									  trunk_radius, tree_height)

	var instance := MultiMeshInstance3D.new()
	instance.name = "K%d_v%d_l%d" % [kind, variant, level]
	instance.multimesh = multi
	# A scanned model brings its own PBR materials - albedo, normal, roughness,
	# all from the scan. Overriding them would throw away the entire reason for
	# using it. Only the generated fallbacks get a shader.
	if override != null:
		instance.material_override = override
	elif generated:
		instance.material_override = _materials[kind]

	# Near level draws up to the split, far level from there to the kind's
	# limit. A hard cutoff, not a fade: FADE_SELF needs a material that supports
	# dithered transparency, and with an opaque one it simply does not draw.
	if level < 0:
		# An impostor covers the whole range for its kind: there is no nearer
		# form of it to hand over to.
		instance.visibility_range_end = Meshes.view_distance(kind)
	elif level == 0:
		instance.visibility_range_end = far_start
	else:
		instance.visibility_range_begin = far_start
		instance.visibility_range_end = Meshes.view_distance(kind)
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if tier <= 1 \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(instance)


## Drop cells the camera has left behind, with hysteresis so a cell on the
## boundary is not rebuilt every few frames.
func _drop_distant() -> void:
	var centre: Vector2 = _focus()
	var stale: Array = []

	for key in _cells:
		var parts: PackedStringArray = key.split(":")
		var tier: int = int(parts[0])
		var cell: float = TIERS[tier]["cell"]
		var limit: float = float(TIERS[tier]["radius"]) * 1.35
		var here := Vector2((float(parts[1]) + 0.5) * cell, (float(parts[2]) + 0.5) * cell)
		if here.distance_to(centre) > limit:
			stale.append(key)

	for key in stale:
		var holder = _cells[key]
		if holder != null and is_instance_valid(holder):
			holder.queue_free()
		_cells.erase(key)
