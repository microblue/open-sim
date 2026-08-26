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
## 38 degrees, not 50.
##
## The pilot's viewpoint does not move - apparent size is the only distance cue
## a standing pilot has, and that is worth defending. But the FIELD is a free
## choice, and 50 degrees is a wide-angle lens: it drew a 1.5 m trainer at
## eighty metres about twelve pixels across, which is smaller than it looks to
## a person standing on the strip, because a person's attention is foveal.
## Narrowing the field makes the model bigger without moving the eye, so the
## cue still scales correctly with distance.
const BASE_FOV: float = 38.0

## How far off-centre the aircraft may drift before the camera starts to follow.
const TRACKING_DEADZONE_DEGREES: float = 7.0
## How quickly it catches up once it does. Deliberately unhurried.
const TRACKING_RATE: float = 2.2

## No camera may go below this height above the ground. The chase camera sits
## behind and below the aircraft's own up axis, so an inverted pass or a low
## rolling turn used to put it under the field - and from under a single-sided
## ground plane you see the sky through the world, which reads as the terrain
## having vanished. Enough clearance that the near plane stays clear of the
## grass as well.
const MINIMUM_GROUND_CLEARANCE: float = 0.55

## Layers the cameras draw. The propeller is on its own so the FPV view can
## leave it out: it is a tractor model, the disc is directly in front of any
## camera mounted behind it, and at flying rpm it fills the frame.
const LAYER_ALL: int = 0xFFFFF
const LAYER_PROPELLER: int = 2

@export var simulation_path: NodePath
@export var field_path: NodePath
@export var pilot_eye_height: float = 1.65

var mode: Mode = Mode.PILOT
var _zoom_index: int = 0
var _sim: Node3D
var _camera: Camera3D
var _look_offset: Vector2 = Vector2.ZERO
var _mouse_look: bool = false
var _tracked_direction: Vector3 = Vector3(0.0, 0.0, -1.0)
var _field: Node3D


func _ready() -> void:
	_sim = get_node_or_null(simulation_path) as Node3D
	_field = get_node_or_null(field_path) as Node3D

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.fov = BASE_FOV
	_camera.near = 0.05
	# Far enough to see the world. At 9000 m the outer terrain rings - which
	# reach tens of kilometres - were clipped away, so the horizon ended in a
	# hard line partway across the landscape.
	_camera.far = 60000.0
	_camera.current = true
	add_child(_camera)
	_apply_cull_mask()

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


## Everything except the propeller in FPV, everything in the other views.
func _apply_cull_mask() -> void:
	if _camera == null:
		return
	_camera.cull_mask = (LAYER_ALL & ~LAYER_PROPELLER) if mode == Mode.FPV else LAYER_ALL


func _set_mode(new_mode: Mode) -> void:
	mode = new_mode
	_look_offset = Vector2.ZERO
	if mode != Mode.PILOT:
		# Optical zoom is a pilot-view idea: it stands in for a spotter, or for
		# simply having better eyes. It makes no sense from the cockpit.
		_zoom_index = 0
	_apply_zoom()
	_apply_cull_mask()


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

	# The head lags on purpose, but it may not LOSE the aeroplane.
	#
	# Measured at 22 % of the time out of frame, worst case 23.2 degrees off
	# centre against a 19 degree half-field (tests/PilotViewCheck.gd) - and
	# narrowing the field from 50 to 38 degrees, to make the model bigger,
	# halved the tolerance without anything noticing. A student who cannot see
	# the model is not being taught anything.
	#
	# So the deadzone and the unhurried catch-up stay, and on top of them the
	# error is CLAMPED: past a little over half the half-field, the head simply
	# is where it has to be. In ordinary flying this never engages.
	var limit: float = deg_to_rad(_camera.fov * 0.5 * 0.55) if _camera != null \
			else deg_to_rad(12.0)
	if _tracked_direction.angle_to(direction) > limit:
		_tracked_direction = direction.rotated(
			direction.cross(_tracked_direction).normalized(), limit).normalized()

	var target: Vector3 = global_position + _tracked_direction * 100.0
	look_at(target, Vector3.UP)
	rotate_object_local(Vector3.UP, _look_offset.x)
	rotate_object_local(Vector3.RIGHT, _look_offset.y)


func _update_chase(delta: float) -> void:
	var behind: Vector3 = _sim.global_transform.basis.z.normalized()
	var up: Vector3 = _sim.global_transform.basis.y.normalized()
	# Closer in than it was - 5.5 m behind a 1.5 m aeroplane left it a third of
	# the frame tall on a wide field and much less on a narrow one.
	var desired: Vector3 = _sim.global_position + behind * 3.4 + up * 0.9 \
			+ Vector3.UP * 0.4

	global_position = global_position.lerp(desired, clampf(6.0 * delta, 0.0, 1.0))
	_keep_above_ground()
	look_at(_sim.global_position, Vector3.UP)
	rotate_object_local(Vector3.UP, _look_offset.x)
	rotate_object_local(Vector3.RIGHT, _look_offset.y)


## Lift the camera to the surface if it has gone under.
##
## Done on the camera rather than by shrinking the chase distance: pulling the
## camera in changes the framing every time the aircraft flies low, whereas
## sliding it up keeps the aircraft the same size and just refuses to go
## underground. The ground is a single-sided plane, so from below you see
## straight through the world.
func _keep_above_ground() -> void:
	var floor_height: float = 0.0
	if _field != null and _field.has_method("height_at"):
		floor_height = _field.height_at(global_position.x, global_position.z)
	var lowest: float = floor_height + MINIMUM_GROUND_CLEARANCE
	if global_position.y < lowest:
		global_position.y = lowest


func _update_fpv() -> void:
	# Rigidly attached, looking out over the nose. No smoothing: an FPV camera
	# is bolted to the airframe and shakes with it, and that is information.
	global_transform = _sim.global_transform
	translate_object_local(Vector3(0.0, 0.10, -0.28))
	_keep_above_ground()
	rotate_object_local(Vector3.UP, _look_offset.x)
	rotate_object_local(Vector3.RIGHT, _look_offset.y)
