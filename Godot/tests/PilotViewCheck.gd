# OpenRC Simulator - can the pilot see the aeroplane?
#
#   godot --path Godot --script res://tests/PilotViewCheck.gd
#
# The pilot view is the default camera and the one a training simulator is
# actually about: a student stands on the ground and learns to read a model's
# attitude from behind it. If the aeroplane leaves the frame the simulator has
# stopped teaching anything.
#
# The head tracks with a deadzone on purpose - a real pilot's head lags, and
# the model is almost never dead centre. This measures how far "almost never
# dead centre" actually goes.
extends SceneTree

var _scene: Node3D
var _sim: RCSimulationNode
var _rig: Node3D
var _camera: Camera3D
var _frame: int = 0
var _worst: float = 0.0
var _lost: int = 0
var _samples: int = 0


func _initialize() -> void:
	_scene = load("res://scenes/Flight.tscn").instantiate()
	root.add_child(_scene)


func _process(_delta: float) -> bool:
	_frame += 1
	if _sim == null:
		if _frame < 30:
			return false
		_sim = _scene.get_node_or_null("Aircraft") as RCSimulationNode
		_rig = _scene.get_node_or_null("CameraRig") as Node3D
		_camera = _rig.get_node_or_null("Camera3D") as Camera3D
		if _camera == null:
			for child in _rig.find_children("*", "Camera3D", true, false):
				_camera = child as Camera3D
				break
		# Airborne, under power, turning: the case the pilot view has to cope
		# with is a model going somewhere, not one hanging in front of them.
		_sim.input_path = NodePath("")
		_sim.spawn_mode = RCSimulationNode.SPAWN_AIR
		_sim.spawn_altitude_m = 45.0
		_sim.reset_state()
		_sim.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 0.7)
		_sim.set_manual_channel(RCInputNode.CHANNEL_AILERON, 0.35)
		return false

	if _frame < 90 or _camera == null:
		return false

	var to_model: Vector3 = _sim.global_position - _camera.global_position
	if to_model.length() > 1.0:
		var forward: Vector3 = -_camera.global_transform.basis.z
		var off: float = rad_to_deg(forward.angle_to(to_model.normalized()))
		_worst = maxf(_worst, off)
		_samples += 1
		# Half the vertical field, near enough: past that it is off the screen.
		if off > _camera.fov * 0.5:
			_lost += 1

	if _frame > 900:
		print("  pilot view over %d samples: worst off-centre %.1f deg, "
			% [_samples, _worst] + "out of frame %d%% of the time"
			% int(100.0 * float(_lost) / maxf(float(_samples), 1.0)))
		if _lost > 0:
			printerr("the pilot loses sight of the aeroplane")
			quit(1)
		else:
			print("  the aeroplane stays in the pilot's view")
			quit(0)
		return true
	return false
