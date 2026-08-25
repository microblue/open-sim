# Renders ONE review shot per run, chosen by RC_SHOT, for a vision model.
#   RC_SHOT=menu|pilot|grass_low|landscape|desert godot ... --script res://tests/ReviewShot.gd
extends SceneTree

var _frames: int = 0
var _shot: String = OS.get_environment("RC_SHOT")

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	var scene: Node3D = load("res://scenes/Flight.tscn").instantiate()
	root.add_child(scene)

func _process(_d: float) -> bool:
	_frames += 1
	var scene: Node3D = root.get_child(root.get_child_count() - 1)

	if _shot == "menu":
		if scene.get_node_or_null("MainMenu") != null and _frames > 90:
			_capture("menu")
			return true
		return false

	# Scene shots: dismiss overlays and wait for the world to settle.
	for name in ["MainMenu", "FlightHUD"]:
		var n: Node = scene.get_node_or_null(name)
		if n != null: n.queue_free()

	if _frames < 60:
		return false

	var camera: Camera3D = scene.get_viewport().get_camera_3d()
	var director: Node = scene.get_node_or_null("WorldDirector")
	# Freeze the rig so the pilot/chase logic does not fight the review camera.
	var rig: Node3D = scene.get_node_or_null("CameraRig") as Node3D
	if rig != null:
		rig.set_process(false)
	if camera != null:
		camera.far = 60000.0
		match _shot:
			"pilot":
				camera.global_position = Vector3(0.0, 1.7, 0.0)
				camera.global_rotation = Vector3(deg_to_rad(-4.0), deg_to_rad(12.0), 0.0)
			"grass_low":
				camera.global_position = Vector3(-20.0, 0.6, -12.0)
				camera.global_rotation = Vector3(deg_to_rad(-14.0), deg_to_rad(22.0), 0.0)
			"landscape":
				director.call("apply_scene", "meadow")
				camera.global_position = Vector3(0.0, 240.0, 620.0)
				camera.global_rotation = Vector3(deg_to_rad(-11.0), deg_to_rad(6.0), 0.0)
			"desert":
				director.call("apply_scene", "desert")
				camera.global_position = Vector3(0.0, 200.0, 700.0)
				camera.global_rotation = Vector3(deg_to_rad(-12.0), deg_to_rad(8.0), 0.0)
			"alpine":
				director.call("apply_scene", "alpine")
				camera.global_position = Vector3(0.0, 300.0, 700.0)
				camera.global_rotation = Vector3(deg_to_rad(-11.0), deg_to_rad(5.0), 0.0)

	if _frames == 120:
		_capture(_shot)
		return true
	return false

func _capture(name: String) -> void:
	root.get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://shots/review_%s.png" % name))
	print("saved review_%s" % name)
	quit(0)
