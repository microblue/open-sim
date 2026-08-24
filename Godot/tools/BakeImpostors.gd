# OpenRC Simulator - baking trees into impostors.
#
# A scanned tree cannot be decimated. Its leaves are thousands of separate
# alpha-cut cards, and collapsing an edge between two of them destroys both - a
# general simplifier has no way to tell a leaf from a facet. island_tree_02
# keeps its canopy at 131,477 triangles and loses it entirely at 9,264. There is
# nothing in between, so there is no triangle budget at which a forest of real
# scanned trees is possible.
#
# The answer, and what every flight simulator does: render the tree offline from
# a ring of angles into one atlas, then draw a quad that picks the view nearest
# to how the camera is looking at it. Two triangles carrying a photograph of a
# real tree, from any direction.
#
# Run once, after scripts/build-assets.sh:
#
#   godot --path Godot --script res://tools/BakeImpostors.gd
#
# Writes Godot/assets/impostors/<name>.png plus a small .json of the metrics the
# renderer needs to size and place the quad. Not committed - it is derived from
# assets that are not committed either.
extends SceneTree

## Views around the tree. Eight is the usual compromise: the seam between two
## adjacent views is 45 degrees, which at the range an impostor is used is below
## what the eye tracks.
const ANGLES: int = 12

## Pixels per view.
const TILE: int = 1024

const MODELS: Array[String] = [
	"fir_tree_01",
	"pine_tree_01",
	"island_tree_02",
	"jacaranda_tree",
	"wild_rooibos_bush",
	"fern_02",
	"grass_medium_01",
	"grass_medium_02",
]

var _viewport: SubViewport
var _camera: Camera3D
var _queue: Array = []
var _current: Dictionary = {}
var _frames: int = 0
var _tiles: Array[Image] = []


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://assets/impostors"))

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(TILE, TILE)
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	# Flat white ambient and no tone mapping: the atlas has to hold the tree's
	# own albedo so the scene it is placed in can light it. Baking the lighting
	# in would freeze one time of day into every distant tree in the world.
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(1, 1, 1)
	environment.ambient_light_energy = 1.0
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var holder := WorldEnvironment.new()
	holder.environment = environment
	_viewport.add_child(holder)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.near = 0.05
	_camera.far = 600.0
	_viewport.add_child(_camera)

	# A weak key so bark and leaves are not perfectly flat. Most of the light is
	# the white ambient: this is a texture, not a lit object.
	var key := DirectionalLight3D.new()
	key.light_energy = 0.55
	key.rotation_degrees = Vector3(-35.0, 40.0, 0.0)
	_viewport.add_child(key)

	root.add_child(_viewport)
	_queue = MODELS.duplicate()
	print("Baking %d impostors, %d views each at %dx%d" % [MODELS.size(), ANGLES, TILE, TILE])


func _process(_delta: float) -> bool:
	_frames += 1

	if _current.is_empty():
		if _queue.is_empty():
			print("done")
			quit(0)
			return true
		_begin(_queue.pop_front())
		return false

	if _frames < int(_current["ready_at"]):
		return false

	var view: int = _current["view"]
	if view < ANGLES:
		_tiles.append(_viewport.get_texture().get_image())
		_current["view"] = view + 1
		_current["ready_at"] = _frames + 2
		if _current["view"] < ANGLES:
			_aim(_current["view"])
		return false

	_finish()
	return false


func _begin(name: String) -> void:
	# The bake source, not the instanced LOD: the LOD has had its canopy
	# decimated away, and an impostor baked off that is a photograph of a
	# bare trunk. That is exactly what the first run produced.
	var path: String = "res://assets/lod/%s_bake.glb" % name
	if not ResourceLoader.exists(path):
		push_warning("%s not built - run scripts/build-assets.sh" % name)
		return

	var scene: PackedScene = load(path)
	if scene == null:
		push_warning("%s failed to load" % name)
		return

	var instance: Node3D = scene.instantiate()
	_viewport.add_child(instance)

	# Measured rather than assumed: these are scans, and a "grass" model is a
	# clump the size of a dinner plate while a pine is twenty metres.
	var bounds: AABB = _bounds(instance)
	if bounds.size.length() <= 0.0:
		instance.queue_free()
		return

	_current = {
		"name": name,
		"node": instance,
		"bounds": bounds,
		"view": 0,
		"ready_at": _frames + 4,
	}
	_tiles.clear()
	_aim(0)
	print("  %s  %.2f x %.2f x %.2f m" % [name, bounds.size.x, bounds.size.y, bounds.size.z])


## Point the camera at view `index`, level with the middle of the model.
func _aim(index: int) -> void:
	var bounds: AABB = _current["bounds"]
	var centre: Vector3 = bounds.position + bounds.size * 0.5
	# Framed square on the largest dimension, so every view shares one scale and
	# the quad can be sized from a single number.
	var extent: float = maxf(maxf(bounds.size.x, bounds.size.z), bounds.size.y) * 0.55

	var angle: float = TAU * float(index) / float(ANGLES)
	_camera.size = extent * 2.0
	_camera.global_position = centre + Vector3(sin(angle), 0.0, cos(angle)) * (extent * 6.0 + 20.0)
	_camera.look_at(centre, Vector3.UP)
	_current["extent"] = extent


func _finish() -> void:
	var name: String = _current["name"]
	var bounds: AABB = _current["bounds"]
	var extent: float = _current["extent"]

	# One row of views, so the shader picks a view with a single coordinate.
	var atlas := Image.create(TILE * ANGLES, TILE, true, Image.FORMAT_RGBA8)
	for i in _tiles.size():
		atlas.blit_rect(_tiles[i], Rect2i(0, 0, TILE, TILE), Vector2i(TILE * i, 0))
	atlas.generate_mipmaps()
	atlas.save_png(ProjectSettings.globalize_path("res://assets/impostors/%s.png" % name))

	var metrics := {
		"views": ANGLES,
		"tile": TILE,
		"extent": extent * 2.0,
		"centre_y": bounds.position.y + bounds.size.y * 0.5,
		"height": bounds.size.y,
	}
	var handle := FileAccess.open("res://assets/impostors/%s.json" % name, FileAccess.WRITE)
	if handle != null:
		handle.store_string(JSON.stringify(metrics, "  "))
		handle.close()

	print("    -> %s.png  %dx%d  quad %.2f m" % [name, atlas.get_width(), atlas.get_height(), extent * 2.0])

	(_current["node"] as Node3D).queue_free()
	_current = {}
	_tiles.clear()


static func _bounds(node: Node) -> AABB:
	var total := AABB()
	var started := false
	for child in _all(node):
		if child is MeshInstance3D:
			var instance: MeshInstance3D = child
			if instance.mesh == null:
				continue
			var box: AABB = instance.transform * instance.get_aabb()
			total = box if not started else total.merge(box)
			started = true
	return total


static func _all(node: Node) -> Array[Node]:
	var found: Array[Node] = [node]
	for child in node.get_children():
		found.append_array(_all(child))
	return found
