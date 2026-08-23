# OpenRC Simulator - renders the field and saves frames, so the visual milestone
# can be checked rather than asserted.
#
#   godot --path Godot --script res://tests/Screenshot.gd
#
# Writes into the project's shots/ directory.
extends SceneTree

var _frames: int = 0
var _shot: int = 0
var _scene: Node3D
var _rig: Node3D
var _aircraft: RCSimulationNode

# frame, camera mode, zoom, spawn mode, label
var _plan: Array = [
	[120, 0, 0, 0, "pilot_ground"],
	[200, 1, 0, 1, "chase"],
	[260, 0, 0, 1, "pilot_1x"],
	[300, 0, 1, 1, "pilot_2x"],
	[340, 0, 2, 1, "pilot_4x"],
	[380, 2, 0, 1, "fpv"],
]


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	_scene = load("res://scenes/Flight.tscn").instantiate()
	root.add_child(_scene)


func _process(_delta: float) -> bool:
	_frames += 1

	if _aircraft == null:
		# The menu opens on a cold start because no transmitter profile exists;
		# these shots are of the flight overlay, so dismiss it.
		var menu: Node = _scene.get_node_or_null("MainMenu")
		if menu != null:
			menu.queue_free()
		_aircraft = _scene.get_node_or_null("Aircraft") as RCSimulationNode
		_rig = _scene.get_node_or_null("CameraRig") as Node3D
		if _aircraft != null:
			_aircraft.spawn_mode = RCSimulationNode.SPAWN_RUNWAY
			_aircraft.spawn_altitude_m = 35.0
			_aircraft.wind_speed_mps = 3.0
			_aircraft.reset_state()
			# Fly it away down the strip so the later shots have it in the air.
			_aircraft.get_node("../Transmitter")
		return false

	if _shot >= _plan.size():
		print("wrote %d frames to res://shots/" % _shot)
		quit(0)
		return true

	var entry: Array = _plan[_shot]
	if _frames < int(entry[0]):
		return false

	# Reconfigure for this shot, let one frame settle, then capture.
	if _aircraft.spawn_mode != int(entry[3]):
		_aircraft.spawn_mode = int(entry[3])
		_aircraft.reset_state()
	_rig.mode = int(entry[1])
	_rig._zoom_index = int(entry[2])
	_rig._apply_zoom()

	var image: Image = root.get_texture().get_image()
	if image != null:
		var path: String = "res://shots/%d_%s.png" % [_shot, entry[4]]
		image.save_png(ProjectSettings.globalize_path(path))
		print("  %s  (%dx%d)" % [path, image.get_width(), image.get_height()])
	_shot += 1
	return false
