# OpenRC Simulator - what is on the screen, frame by frame, from a cold start.
#
#   godot --path Godot --resolution 1280x720 --script res://tests/StartupTrace.gd
#
# "It still loads the scene before showing the menu" is a claim about the first
# second of the program, and the first second is not something to reason about.
# This captures the actual frames and says how long each one took, so the
# question becomes what the player sees rather than what the code says it does.
extends SceneTree

const CAPTURE_AT: Array[int] = [1, 2, 3, 5, 8, 12, 20, 30, 45, 60, 90, 120]

var _scene: Node
var _frame: int = 0
var _started: int = 0
var _last: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://shots/startup"))
	_started = Time.get_ticks_msec()
	_last = _started
	print("  loading Flight.tscn at +%d ms" % (Time.get_ticks_msec() - _started))
	_scene = load("res://scenes/Flight.tscn").instantiate()
	print("  instantiated at    +%d ms" % (Time.get_ticks_msec() - _started))
	root.add_child(_scene)
	print("  in the tree at     +%d ms" % (Time.get_ticks_msec() - _started))


func _process(_delta: float) -> bool:
	_frame += 1
	var now: int = Time.get_ticks_msec()
	var step: int = now - _last
	_last = now

	if _frame in CAPTURE_AT:
		var image: Image = root.get_texture().get_image()
		if image != null:
			image.save_png(ProjectSettings.globalize_path(
				"res://shots/startup/f%03d.png" % _frame))
		var menu: bool = _scene.has_node("MainMenu")
		var world: bool = _scene.has_node("Field/GrassField01")
		print("  frame %3d  +%5d ms (step %3d)   menu %s   world %s"
			% [_frame, now - _started, step,
			   "yes" if menu else "no ", "BUILT" if world else "no"])

	if _frame >= 120:
		quit(0)
		return true
	return false
