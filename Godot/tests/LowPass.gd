# OpenRC Simulator - what the ground looks like from low down.
#
# The scenery only has to hold up at the height a model is actually flown at, so
# these put the camera there: a few metres up, a few hundred metres out from the
# field, looking across the ground rather than down at it.
extends SceneTree

var _frames: int = 0
var _shot: int = 0
var _scene: Node3D
var _aircraft: RCSimulationNode
var _camera: Camera3D

# settle, height above ground, distance out, heading, pitch, label
var _plan: Array = [
	[60,   6.0,  700.0,  40.0,  -4.0, "low_grass"],
	[90,  14.0, 1500.0, 120.0,  -6.0, "low_scrub"],
	[120, 25.0, 2600.0, 210.0,  -8.0, "low_trees"],
	[150,  9.0, 3400.0, 285.0,  -3.0, "low_shore"],
]


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	_scene = load("res://scenes/Flight.tscn").instantiate()
	root.add_child(_scene)


## The menu opens a second or so in when no transmitter profile binds, which is
## after a one-shot dismissal has already run. Freeing it every frame is the
## only version of this that works whether or not a radio is plugged in.
func _dismiss_overlays() -> void:
	for name in ["MainMenu", "FlightHUD", "Hangar"]:
		var node: Node = _scene.get_node_or_null(name)
		if node != null:
			node.queue_free()


func _process(_delta: float) -> bool:
	_frames += 1
	_dismiss_overlays()

	if _aircraft == null:
		var menu: Node = _scene.get_node_or_null("MainMenu")
		if menu != null:
			menu.queue_free()
		var hud: Node = _scene.get_node_or_null("FlightHUD")
		if hud != null:
			hud.queue_free()
		_aircraft = _scene.get_node_or_null("Aircraft") as RCSimulationNode
		var rig: Node3D = _scene.get_node_or_null("CameraRig") as Node3D
		if rig != null:
			rig.set_process(false)
			_camera = rig.get_node_or_null("Camera") as Camera3D
			if _camera != null:
				_camera.far = 60000.0
		return false

	if _shot >= _plan.size() or _camera == null:
		print("wrote %d low passes to res://shots/" % _shot)
		quit(0)
		return true

	var entry: Array = _plan[_shot]
	if _frames < int(entry[0]):
		return false

	var heading: float = deg_to_rad(entry[3])
	var distance: float = entry[2]
	var x: float = sin(heading) * distance
	var z: float = -cos(heading) * distance
	# Above the ground, not above sea level: this is a low pass over whatever
	# happens to be there.
	var ground: float = _aircraft.get_terrain_height(x, z)

	_camera.global_position = Vector3(x, ground + float(entry[1]), z)
	_camera.global_rotation = Vector3(deg_to_rad(entry[4]), heading, 0.0)

	# The scatter streams around the camera, so it needs frames to populate a
	# place it has just been moved to.
	if _frames < int(entry[0]) + 45:
		return false

	var image: Image = root.get_texture().get_image()
	if image != null:
		var path: String = "res://shots/%s.png" % entry[5]
		image.save_png(ProjectSettings.globalize_path(path))
		print("  %s" % path)
	_shot += 1
	_frames = int(entry[0]) + 50
	return false
