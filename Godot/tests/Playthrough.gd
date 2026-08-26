# OpenRC Simulator - what a player actually sees, in the order they see it.
#
#   godot --path Godot --resolution 1920x1080 --script res://tests/Playthrough.gd
#
# Not a test. A walkthrough, captured so the screens can be looked at as screens
# rather than reasoned about as code. Every interface in this project was
# written from a description of what it should show; this is the only way to
# find out what it does show.
extends SceneTree

var _scene: Node3D
var _sim: RCSimulationNode
var _rig: Node3D
var _step: int = -1
var _frames: int = 0
var _settle: int = 0
var _plan: Array = []


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots/play"))
	_scene = load("res://scenes/Flight.tscn").instantiate()
	root.add_child(_scene)

	_plan = [
		{"id": "01_first_launch", "settle": 60, "do": func() -> void: pass},
		# Every step of the briefing, because each one is a screen a player
		# looks at and the walkthrough only ever showed the first.
		{"id": "02_location", "settle": 30, "do": func() -> void:
			_menu().call("_set_step", 1)},
		{"id": "03_weather", "settle": 30, "do": func() -> void:
			_menu().call("_set_step", 2)},
		{"id": "04_review", "settle": 30, "do": func() -> void:
			_menu().call("_set_step", 3)},
		{"id": "05_hangar", "settle": 40, "do": func() -> void:
			_menu().call("_set_step", 0)
			_scene.call("_open_hangar")},
		{"id": "06_hangar_glider", "settle": 30, "do": func() -> void:
			var h: Node = _scene.get_node_or_null("Hangar")
			if h: h.set("_index", 0); h.get_node("Canvas").queue_redraw()},
		{"id": "07_world", "settle": 30, "do": func() -> void:
			var h: Node = _scene.get_node_or_null("Hangar")
			if h: h.free()
			_scene.call("_open_world_screen")},
		# The real path: the menu's own Fly button, which is what builds the
		# world. Captured part-way through, because a loading screen nobody
		# has looked at is a loading screen nobody has checked.
		{"id": "08_loading", "settle": 30, "do": func() -> void:
			var w: Node = _scene.get_node_or_null("WorldScreen")
			if w: w.free()
			var menu: Node = _scene.get_node_or_null("MainMenu")
			if menu != null:
				menu.call("_begin_fly")},
		{"id": "09_flying_pilot", "settle": 240, "do": func() -> void: _fly()},
		{"id": "10_flying_chase", "settle": 30, "do": func() -> void: _rig.set("mode", 1)},
		{"id": "11_flying_fpv", "settle": 30, "do": func() -> void: _rig.set("mode", 2)},
		{"id": "12_failure", "settle": 40, "do": func() -> void:
			_rig.set("mode", 1)
			_sim.induce_failure(1, 0)},
		{"id": "13_replay", "settle": 40, "do": func() -> void:
			_sim.clear_failures()
			_scene.call("_toggle_replay")},
	]


## The menu, which every briefing step is driven through.
func _menu() -> Node:
	return _scene.get_node_or_null("MainMenu")


func _fly() -> void:
	_sim.spawn_mode = RCSimulationNode.SPAWN_AIR
	_sim.spawn_altitude_m = 45.0
	_sim.reset_state()
	# Enough throttle to hold height: at 0.55 the trainer sank at five metres
	# a second, so every "in flight" frame was captured mid-dive with the
	# camera pointed at the grass and no horizon in it.
	#
	# The manual channels only apply when no input node is wired up: with one
	# present it wins every frame, so the walkthrough's throttle went nowhere
	# and every "in flight" frame was a glide with the motor stopped.
	_sim.input_path = NodePath("")
	_sim.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 0.72)
	_sim.set_manual_channel(RCInputNode.CHANNEL_ELEVATOR, 0.0)


func _process(_delta: float) -> bool:
	_frames += 1

	if _sim == null:
		if _frames < 20:
			return false
		_sim = _scene.get_node_or_null("Aircraft") as RCSimulationNode
		_rig = _scene.get_node_or_null("CameraRig") as Node3D
		return false

	if _settle > 0:
		_settle -= 1
		if _settle == 0:
			_capture()
		return false

	_step += 1
	if _step >= _plan.size():
		print("captured %d screens" % _plan.size())
		quit(0)
		return true

	var entry: Dictionary = _plan[_step]
	(entry["do"] as Callable).call()
	_settle = int(entry["settle"])
	return false


func _capture() -> void:
	var path: String = "res://shots/play/%s.png" % _plan[_step]["id"]
	var image: Image = root.get_texture().get_image()
	if image != null:
		image.save_png(ProjectSettings.globalize_path(path))
		print("  %s" % path)
