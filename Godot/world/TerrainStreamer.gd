# OpenRC Simulator - the world, generated as you reach it.
#
# The field used to be a 520 m square. Fly out and you were looking down at a
# small green tile floating in fog, which is exactly what it was.
#
# This streams terrain instead. Concentric rings of chunks are built around the
# camera - fine and small near it, coarse and vast further out - and rebuilt as
# it moves, so there is no edge and no end. The furthest ring reaches tens of
# kilometres, which is what puts real mountains on the horizon rather than a
# painted backdrop.
#
# Every height comes from the C++ TerrainField, the same function the aircraft
# collides with. That is not a detail: two implementations of the world's shape
# drift, and the way you find out is by flying through a mountain.
extends Node3D

const WorldShaders := preload("res://world/WorldShaders.gd")
const WorldTex := preload("res://world/WorldTextures.gd")

## A geometric clipmap.
##
## Level 0 is a 4x4 block of small chunks around the camera. Every level after
## it doubles the chunk size and cuts out its inner 2x2 - which is exactly the
## area the level below already covers - so the levels tile rather than stack.
##
## The first version got this wrong and made every level a full square centred
## on the camera. They all overlapped, and the outermost, with two-kilometre
## quads, was drawn straight over the flying field: the aircraft and the grass
## were buried under a mesh whose nearest vertices were a kilometre away.
const BASE_CHUNK: float = 320.0
const LEVELS: int = 6
const GRID: int = 4

## Vertices along one edge of a chunk. The same at every level - what changes is
## how much ground a chunk covers, which is what makes the cost per level
## constant and the detail fall off with distance.
## Vertices along one edge of a chunk. Raised from 40 once the frame time was
## understood: this is what decides how sharp a ridgeline is.
const CHUNK_RESOLUTION: int = 96

## Levels beyond this do not cast shadows. A shadow map stretched over tens of
## kilometres has no resolution left for the aircraft, and a mountain twenty
## kilometres away shades nothing the pilot can see.
const SHADOW_LEVELS: int = 3

@export var simulation_path: NodePath
@export var camera_path: NodePath

var _sim: RCSimulationNode
var _camera: Node3D
var _terrain_material: ShaderMaterial
var _water_material: ShaderMaterial
var _levels: Array[Dictionary] = []
var _water: MeshInstance3D


func _ready() -> void:
	_sim = get_node_or_null(simulation_path) as RCSimulationNode
	if _sim == null:
		return

	_terrain_material = ShaderMaterial.new()
	_terrain_material.shader = WorldShaders.terrain_shader()
	_terrain_material.set_shader_parameter("snow_line", 1250.0)
	_terrain_material.set_shader_parameter("field_radius", 300.0)
	_terrain_material.set_shader_parameter("field_blend", 420.0)
	_terrain_material.set_shader_parameter("sea_level", _sim.get_sea_level_y())

	# Real scanned surfaces where they have been fetched, procedural colouring
	# where they have not. See Docs/ASSETS.md.
	var ground: Dictionary = WorldTex.build(_sim)
	if ground.is_empty():
		push_warning("Ground textures not found - run scripts/fetch-assets.sh. "
				+ "Falling back to procedural terrain colouring.")
	else:
		_terrain_material.set_shader_parameter("ground_albedo", ground["albedo"])
		_terrain_material.set_shader_parameter("ground_normal", ground["normal"])
		_terrain_material.set_shader_parameter("ground_rough", ground["roughness"])
		_terrain_material.set_shader_parameter("textured", not OS.has_environment("RC_FLAT_TERRAIN"))
		print("[World] ground: %d scanned PBR materials" % ground["count"])

	for level in LEVELS:
		var holder := Node3D.new()
		holder.name = "Level%d" % level
		add_child(holder)
		_levels.append({
			"level": level,
			"size": BASE_CHUNK * pow(2.0, float(level)),
			"holder": holder,
			"anchor": Vector2(1e12, 1e12),
		})

	if not OS.has_environment("RC_NO_WATER"):
		_build_water()
	for level in _levels:
		_rebuild_level(level, _anchor_for(level, _focus()))


## Throw away every chunk and let them build again from the current terrain
## settings. Called when a scene preset changes the world's shape.
## The ground reads the weather: snow covers it, rain wets it. Called by the
## world director whenever the weather state changes.
func apply_weather_ground(snow: float, wet: float) -> void:
	if _terrain_material == null:
		return
	_terrain_material.set_shader_parameter("weather_snow", snow)
	_terrain_material.set_shader_parameter("weather_wet", wet)


func rebuild() -> void:
	for level in _levels:
		for child in (level["holder"] as Node3D).get_children():
			child.queue_free()
		level["anchor"] = Vector2(1e12, 1e12)
	if _water != null and _sim != null:
		_water.position.y = _sim.get_sea_level_y()
	for level in _levels:
		_rebuild_level(level, _anchor_for(level, _focus()))


func _process(_delta: float) -> void:
	if _sim == null:
		return

	var focus: Vector2 = _focus()
	# At most one level per frame. A level is a dozen chunks of a couple of
	# thousand vertices; rebuilding several at once shows up as a hitch, and a
	# hitch at 240 Hz physics is dropped steps.
	for level in _levels:
		var anchor: Vector2 = _anchor_for(level, focus)
		if anchor.is_equal_approx(level["anchor"]):
			continue
		_rebuild_level(level, anchor)
		return


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


## Snap every level to the SAME base grid.
##
## This is what makes the levels tile. Level k's hollow (its inner 2x2) is
## exactly the block the level below covers - when the anchors agree. The
## first version snapped each level to its own grid (a 640 m level to the
## 640 m grid, a 320 m level to the 320 m grid), so the two anchors could
## differ by half a chunk. Where they did, a strip of ground the level below
## did not cover and the level above had hollowed out was left with no mesh at
## all - visible as a ragged hole in the terrain a few hundred metres out,
## exactly where a pilot is looking for somewhere to put down.
##
## Every level size is a power of two times BASE_CHUNK, so a single anchor on
## the base grid lands on every level's own grid too: level 0's block is then
## exactly level 1's hollow, level 1's ring exactly level 2's hollow, and so
## on out to the horizon.
func _anchor_for(_level: Dictionary, focus: Vector2) -> Vector2:
	return Vector2(floor(focus.x / BASE_CHUNK) * BASE_CHUNK,
				   floor(focus.y / BASE_CHUNK) * BASE_CHUNK)


func _rebuild_level(level: Dictionary, anchor: Vector2) -> void:
	var holder: Node3D = level["holder"]
	var size: float = level["size"]
	var index: int = level["level"]

	var old: Array[Node] = holder.get_children()

	# Levels above the first are hollow: the inner 2x2 is what the level below
	# covers. A small vertical bias downwards keeps a coarse chunk from fighting
	# the finer mesh where they meet - the fine one always wins, and at these
	# distances the offset is far below anything the eye resolves.
	# Half of what it was: at the higher levels the old bias was a visible
	# step (0.42 m at level 3) that read as a lattice of grey lines across the
	# mountains. It only needs to tuck the coarse edge under the fine one.
	var bias: float = -(pow(2.0, float(index)) - 1.0) * 0.03

	for row in range(-GRID / 2, GRID / 2):
		for column in range(-GRID / 2, GRID / 2):
			var hollow: bool = index > 0 and row >= -1 and row <= 0 \
				and column >= -1 and column <= 0
			if hollow:
				continue

			var centre := Vector2(
				anchor.x + (float(column) + 0.5) * size,
				anchor.y + (float(row) + 0.5) * size)

			var instance := MeshInstance3D.new()
			instance.name = "Chunk_%d_%d" % [column, row]
			instance.mesh = _sim.build_terrain_chunk(centre.x, centre.y, size,
													CHUNK_RESOLUTION)
			instance.material_override = _terrain_material
			instance.position = Vector3(centre.x, bias, centre.y)
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
				if index < SHADOW_LEVELS else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			holder.add_child(instance)

	level["anchor"] = anchor

	# Freed only once the replacements are in the tree, so there is never a
	# frame with a hole in the world.
	for node in old:
		node.queue_free()


## The sea. One large plane at sea level with the wave motion in the shader -
## the terrain dips below it wherever there is water, so the plane only has to
## reach the horizon.
func _build_water() -> void:
	_water_material = ShaderMaterial.new()
	_water_material.shader = WorldShaders.water_shader()

	var mesh := PlaneMesh.new()
	mesh.size = Vector2(160000.0, 160000.0)
	mesh.subdivide_width = 240
	mesh.subdivide_depth = 240

	_water = MeshInstance3D.new()
	_water.name = "Ocean"
	_water.mesh = mesh
	_water.material_override = _water_material
	_water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Placed at sea level immediately. Leaving it at the origin until the first
	# physics frame put a sheet of water at field level, over the strip the
	# pilot was standing on.
	_water.position = Vector3(0.0, _sim.get_sea_level_y(), 0.0)
	add_child(_water)


func _physics_process(_delta: float) -> void:
	# The ocean follows the camera so its subdivision is spent where it is
	# visible and the wave function never loses precision far from the origin.
	if _water == null:
		return
	var focus: Vector2 = _focus()
	_water.global_position = Vector3(focus.x, _sim.get_sea_level_y(), focus.y)
