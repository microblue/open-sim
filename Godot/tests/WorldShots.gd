# OpenRC Simulator - looking at the world from height.
#
# The flying field is what the pilot sees for most of a session, but it says
# nothing about whether the world beyond it is any good. These put the camera
# up where the landscape is, at a spread of altitudes, so the terrain, the
# coastline and the mountains can be looked at rather than assumed.
#
#   godot --path Godot --resolution 1600x900 --script res://tests/WorldShots.gd
extends SceneTree

var _frames: int = 0
var _shot: int = 0
var _scene: Node3D
var _aircraft: RCSimulationNode
var _camera: Camera3D

# settle frames, height, horizontal distance from the field, heading, pitch, label
var _plan: Array = [
	[40,   180.0,   0.0,    0.0, -12.0, "circuit"],
	[60,   600.0,   0.0,   35.0, -18.0, "high"],
	[80,  1800.0,   0.0,  110.0, -26.0, "region"],
	[100, 4500.0,   0.0,  200.0, -32.0, "continent"],
	[120,  260.0, 4200.0,  250.0, -10.0, "coast"],
	[140,  900.0, 7000.0,  300.0, -14.0, "mountains"],
]


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	_scene = load("res://scenes/Flight.tscn").instantiate()
	root.add_child(_scene)


func _process(_delta: float) -> bool:
	_frames += 1

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
			# Take the camera off the rig entirely: these are views of the
			# world, not of the model, and the rig exists to keep the aircraft
			# in frame.
			rig.set_process(false)
			_camera = rig.get_node_or_null("Camera") as Camera3D
			if _camera != null:
				_camera.far = 90000.0
		return false

	if _shot >= _plan.size() or _camera == null:
		print("wrote %d world frames to res://shots/" % _shot)
		quit(0)
		return true

	var entry: Array = _plan[_shot]
	if _frames < int(entry[0]):
		return false

	var height: float = entry[1]
	var distance: float = entry[2]
	var heading: float = deg_to_rad(entry[3])
	var pitch: float = deg_to_rad(entry[4])

	var position := Vector3(sin(heading) * distance, height, -cos(heading) * distance)
	_camera.global_position = position
	_camera.global_rotation = Vector3(pitch, heading, 0.0)

	# The streamer follows the camera, so it needs frames to reach a new place
	# before the frame is worth capturing.
	if _frames < int(entry[0]) + 14:
		return false

	var image: Image = root.get_texture().get_image()
	if image != null:
		var path: String = "res://shots/world_%d_%s.png" % [_shot, entry[5]]
		image.save_png(ProjectSettings.globalize_path(path))
		print("  %s" % path)
	_shot += 1
	_frames = int(entry[0]) + 20
	return false
