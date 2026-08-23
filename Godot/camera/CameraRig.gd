# OpenRC Simulator - the three camera modes.
#
# The pilot view is the one that matters. Everything about it is shaped by one
# constraint from the design brief:
#
#     the aircraft must NOT be pinned to the centre of the screen
#
# Half of learning to fly RC is keeping track of a small object against a big
# sky while its orientation reverses every time it turns towards you. A camera
# that locks the model dead centre at a constant size removes exactly the skill
# the simulator exists to teach. So the pilot camera stands still, tracks
# loosely, and lets the aircraft wander within the frame.
extends Node3D

enum Mode { PILOT, CHASE, FPV }

const ZOOM_STEPS: Array[float] = [1.0, 2.0, 4.0]
const BASE_FOV: float = 50.0

## How far off-centre the aircraft may drift before the camera starts to follow.
const TRACKING_DEADZONE_DEGREES: float = 7.0
## How quickly it catches up once it does. Deliberately unhurried.
const TRACKING_RATE: float = 2.2

@export var simulation_path: NodePath
@export var pilot_eye_height: float = 1.65

var mode: Mode = Mode.PILOT
var _zoom_index: int = 0
var _sim: Node3D
var _camera: Camera3D
var _look_offset: Vector2 = Vector2.ZERO
var _mouse_look: bool = false
var _tracked_direction: Vector3 = Vector3(0.0, 0.0, -1.0)


func _ready() -> void:
	_sim = get_node_or_null(simulation_path) as Node3D

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.fov = BASE_FOV
	_camera.near = 0.05
	_camera.far = 9000.0
	_camera.current = true
	add_child(_camera)

	position = Vector3(0.0, pilot_eye_height, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1: _set_mode(Mode.PILOT)
			KEY_2: _set_mode(Mode.CHASE)
			KEY_3: _set_mode(Mode.FPV)
			KEY_Z: _cycle_zoom()

	elif event is InputEventMouseButton:
		# Hold the right button to look around, the way a pilot turns their head.
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_mouse_look = event.pressed
			Input.mouse_mode = (Input.MOUSE_MODE_CAPTURED if event.pressed
				else Input.MOUSE_MODE_VISIBLE)

	elif event is InputEventMouseMotion and _mouse_look:
		_look_offset.x -= event.relative.x * 0.0016
		_look_offset.y = clampf(_look_offset.y - event.relative.y * 0.0016, -1.2, 1.2)


func _set_mode(new_mode: Mode) -> void:
	mode = new_mode
	_look_offset = Vector2.ZERO
	if mode != Mode.PILOT:
		# Optical zoom is a pilot-view idea: it stands in for a spotter, or for
		# simply having better eyes. It makes no sense from the cockpit.
		_zoom_index = 0
	_apply_zoom()


func _cycle_zoom() -> void:
	if mode != Mode.PILOT:
		return
	_zoom_index = (_zoom_index + 1) % ZOOM_STEPS.size()
	_apply_zoom()


func _apply_zoom() -> void:
	if _camera != null:
		_camera.fov = BASE_FOV / ZOOM_STEPS[_zoom_index]


func get_zoom() -> float:
	return ZOOM_STEPS[_zoom_index]


func get_mode_name() -> String:
	match mode:
		Mode.PILOT: return "pilot"
		Mode.CHASE: return "chase"
		Mode.FPV:   return "FPV"
	return "?"


func _process(delta: float) -> void:
	if _sim == null or _camera == null:
		return

	match mode:
		Mode.PILOT: _update_pilot(delta)
		Mode.CHASE: _update_chase(delta)
		Mode.FPV:   _update_fpv()


func _update_pilot(delta: float) -> void:
	# The pilot does not move. Ever. Distance and apparent size are the pilot's
	# only cues to how far away the model is, and moving the viewpoint destroys
	# both.
	global_position = Vector3(0.0, pilot_eye_height, 0.0)

	var to_aircraft: Vector3 = _sim.global_position - global_position
	if to_aircraft.length() < 0.5:
		return
	var direction: Vector3 = to_aircraft.normalized()

	# Soft tracking with a deadzone: the head only turns once the model has
	# drifted far enough off-centre to be worth turning for, and then it turns
	# unhurriedly. The aircraft is therefore almost never dead centre, which is
	# the point.
	var error: float = rad_to_deg(_tracked_direction.angle_to(direction))
	if error > TRACKING_DEADZONE_DEGREES:
		var catch_up: float = clampf(TRACKING_RATE * delta
			* ((error - TRACKING_DEADZONE_DEGREES) / 25.0), 0.0, 1.0)
		_tracked_direction = _tracked_direction.slerp(direction, catch_up).normalized()

	var target: Vector3 = global_position + _tracked_direction * 100.0
	look_at(target, Vector3.UP)
	rotate_object_local(Vector3.UP, _look_offset.x)
	rotate_object_local(Vector3.RIGHT, _look_offset.y)


func _update_chase(delta: float) -> void:
	var behind: Vector3 = _sim.global_transform.basis.z.normalized()
	var up: Vector3 = _sim.global_transform.basis.y.normalized()
	var desired: Vector3 = _sim.global_position + behind * 5.5 + up * 1.4 + Vector3.UP * 0.6

	global_position = global_position.lerp(desired, clampf(6.0 * delta, 0.0, 1.0))
	look_at(_sim.global_position, Vector3.UP)
	rotate_object_local(Vector3.UP, _look_offset.x)
	rotate_object_local(Vector3.RIGHT, _look_offset.y)


func _update_fpv() -> void:
	# Rigidly attached, looking out over the nose. No smoothing: an FPV camera
	# is bolted to the airframe and shakes with it, and that is information.
	global_transform = _sim.global_transform
	translate_object_local(Vector3(0.0, 0.10, -0.28))
	rotate_object_local(Vector3.UP, _look_offset.x)
	rotate_object_local(Vector3.RIGHT, _look_offset.y)
