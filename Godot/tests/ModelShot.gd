# OpenRC Simulator - the aeroplane, alone, from four sides.
#
#   RC_MODEL_STEM=Glider2400 godot --path Godot --resolution 1400x900 \
#       --script res://tests/ModelShot.gd
#
# The turntable in the menu showed the model was wrong in several ways at once
# and a 300-pixel thumbnail could not say which. This renders it big, on a
# plain ground, from the four angles a plan view is drawn from, so the geometry
# is unambiguous.
extends SceneTree

const StageScript := preload("res://ui/AircraftStage.gd")

const VIEWS: Array = [
	{"name": "side",  "yaw": 90.0,  "pitch": 0.0},
	{"name": "top",   "yaw": 0.0,   "pitch": 89.0},
	{"name": "front", "yaw": 0.0,   "pitch": 0.0},
	{"name": "three_quarter", "yaw": 42.0, "pitch": 18.0},
]

var _stage: Node
var _index: int = -1
var _settle: int = 0
var _stem: String = "Trainer1500"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://shots/model"))
	# From the environment, not the command line: with --script, Godot does not
	# hand user arguments through reliably, and a tool that silently renders
	# the wrong aeroplane is worse than one that needs an env var.
	if OS.has_environment("RC_MODEL_STEM"):
		_stem = OS.get_environment("RC_MODEL_STEM")
	_stage = StageScript.new()
	root.add_child(_stage)
	_stage.set_process(false)


func _process(_delta: float) -> bool:
	if _index < 0 and _settle == 0:
		# Set up on the first frame, not in _initialize: a node added to the
		# tree there has not run _ready yet, so the stage had no simulation
		# node to load into and every render came out as the default aeroplane.
		_stage.call("set_stage_size", Vector2i(1400, 900))
		_stage.call("show_aircraft", _stem, 1.5)

	_settle -= 1
	if _settle > 0:
		return false
	if _settle == 0:
		_capture()
		return false

	_index += 1
	if _index >= VIEWS.size():
		print("wrote %d model views" % VIEWS.size())
		quit(0)
		return true

	if _index == 0:
		var model: Node = _stage.get_node("Stage/Turntable/Model")
		for child in model.get_children():
			if child is MeshInstance3D:
				var aabb: AABB = (child as MeshInstance3D).get_aabb()
				aabb.position += (child as MeshInstance3D).position
				print("  %-28s y %+0.4f..%+0.4f  z %+0.4f..%+0.4f" % [
					child.name, aabb.position.y, aabb.end.y,
					aabb.position.z, aabb.end.z])

	# RC_MODEL_DEFLECT throws every cut control surface hard over, so the shape
	# that moves can be SEEN. A surface hinged to the wrong geometry looks
	# perfectly correct until it deflects and takes half the fuselage with it.
	if OS.has_environment("RC_MODEL_DEFLECT"):
		var model: Node = _stage.get_node_or_null("Stage/Turntable/Model")
		if model != null:
			for pivot in model.find_children("ctl_*", "Node3D", true, false):
				var angle: float = deg_to_rad(
					float(OS.get_environment("RC_MODEL_DEFLECT")))
				if String(pivot.name).find("rudder") >= 0:
					(pivot as Node3D).rotation = Vector3(0.0, angle, 0.0)
				else:
					(pivot as Node3D).rotation = Vector3(angle, 0.0, 0.0)

	var view: Dictionary = VIEWS[_index]
	var turntable: Node3D = _stage.get_node("Stage/Turntable")
	turntable.rotation = Vector3(0.0, deg_to_rad(float(view["yaw"])), 0.0)
	var camera := _stage.get_node("Stage/Camera") as Camera3D
	# Computed rather than read back: at _initialize() time the stage has not
	# framed itself yet, and a zero-length position makes look_at fail.
	var distance: float = maxf(camera.position.length(), 3.5)
	var pitch: float = deg_to_rad(float(view["pitch"]))
	camera.position = Vector3(0.0, sin(pitch), cos(pitch)) * distance
	camera.look_at(Vector3.ZERO, Vector3.UP)
	_settle = 8
	return false


func _capture() -> void:
	var image: Image = _stage.call("texture").get_image()
	var path: String = "res://shots/model/%s.png" % VIEWS[_index]["name"]
	image.save_png(ProjectSettings.globalize_path(path))
	print("  %s" % path)
