# OpenRC Simulator - one frame of every scene and weather state.
#
#   godot --path Godot --resolution 1600x900 --script res://tests/SceneShots.gd
#
# Writes res://shots/scene_<id>.png and res://shots/weather_<id>.png. A preset
# is a climate and a geology; the only way to know what one produced is to look
# at it.
extends SceneTree

const ScenePresetsLib := preload("res://world/ScenePresets.gd")
const WeatherLib := preload("res://world/Weather.gd")

var _scene: Node3D
var _director: Node
var _camera: Camera3D
var _plan: Array = []
var _index: int = -1
var _frames: int = 0
var _settle: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	_scene = load("res://scenes/Flight.tscn").instantiate()
	root.add_child(_scene)

	for preset in ScenePresetsLib.all():
		_plan.append({"kind": "scene", "id": preset["id"]})
	for state in WeatherLib.all():
		_plan.append({"kind": "weather", "id": state["id"]})


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

	if _director == null:
		if _frames < 30:
			return false
		var menu: Node = _scene.get_node_or_null("MainMenu")
		if menu != null:
			menu.queue_free()
		var hud: Node = _scene.get_node_or_null("FlightHUD")
		if hud != null:
			hud.queue_free()
		_director = _scene.get_node_or_null("WorldDirector")
		var rig: Node3D = _scene.get_node_or_null("CameraRig") as Node3D
		if rig != null:
			rig.set_process(false)
			_camera = rig.get_node_or_null("Camera") as Camera3D
			if _camera != null:
				_camera.far = 60000.0
		return false

	if _settle > 0:
		_settle -= 1
		if _settle == 0:
			_capture()
		return false

	_index += 1
	if _index >= _plan.size():
		print("wrote %d scene frames" % _plan.size())
		quit(0)
		return true

	var entry: Dictionary = _plan[_index]
	if entry["kind"] == "scene":
		_director.call("apply_scene", entry["id"])
	else:
		_director.call("apply_weather", entry["id"])

	# A vantage that shows the landscape rather than the strip.
	if _camera != null:
		var here := Vector3(0.0, 240.0, 620.0)
		_camera.global_position = here
		_camera.global_rotation = Vector3(deg_to_rad(-11.0), deg_to_rad(6.0), 0.0)

	# Terrain and scenery are rebuilt from scratch on a scene change, and the
	# streamer spreads that over frames.
	_settle = 50
	return false


func _capture() -> void:
	var entry: Dictionary = _plan[_index]
	var path: String = "res://shots/%s_%s.png" % [entry["kind"], entry["id"]]
	var image: Image = root.get_texture().get_image()
	if image != null:
		image.save_png(ProjectSettings.globalize_path(path))
		print("  %s" % path)
		# The main menu shows these previews, and the export excludes shots/ -
		# so the same frame is also written where the export will pick it up.
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path("res://assets/previews"))
		var preview: String = "res://assets/previews/%s_%s.png" % [entry["kind"], entry["id"]]
		image.save_png(ProjectSettings.globalize_path(preview))
