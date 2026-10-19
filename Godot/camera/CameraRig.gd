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

const Settings := preload("res://ui/Settings.gd")
const Warnings := preload("res://ui/FlightWarnings.gd")

enum Mode { PILOT, CHASE, FPV }

const ZOOM_STEPS: Array[float] = [1.0, 2.0, 4.0]
## How much tighter the pilot looks once the model is in the grass. A third of
## the field: enough to see which way up it ended and what came off.
const CRASH_ZOOM: float = 0.34
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

## Pilot-view auto-zoom.
##
## The fixed 38 degree field was chosen so a trainer reads well on a circuit, and
## past a couple of hundred metres the same model is a dozen pixels: its
## attitude is gone and the pilot is guessing which way up it is. Auto-zoom
## narrows the field just enough to keep the wingspan at least AUTO_SPAN_PX
## tall. It never widens past BASE_FOV, so up close nothing changes - and the
## eye still does not move, so apparent size still falls with distance until
## the floor is reached. It is a spotter's binoculars, not a chase camera.
##
## The manual Z steps are a multiplier on top of it rather than an alternative:
## "closer than this" means the same thing whether auto-zoom is on or off, and
## the pilot never has to know which mode is active to get a tighter view.
const AUTO_SPAN_PX: float = Warnings.FAR_SPAN_PX
## Narrower than this and the tracking clamp is chasing a model across a field a
## few metres wide at the aeroplane; any further out than that is FAR anyway.
const AUTO_MIN_FOV: float = 6.0
## Half-life of the zoom blend. Quick enough to keep up with a model flying
## away, slow enough that a turn towards the pilot is not a lurch.
const AUTO_HALF_LIFE_S: float = 0.15

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
## How far into the "walk over and look at it" zoom we are, 0 to 1.
var _crash_zoom: float = 0.0
var _was_zoomed_on_wreck: bool = false
var _sim: Node3D
var _camera: Camera3D
var _look_offset: Vector2 = Vector2.ZERO
var _mouse_look: bool = false
var _tracked_direction: Vector3 = Vector3(0.0, 0.0, -1.0)
var _field: Node3D
## The pilot view's field before the crash zoom, eased towards its target.
var _pilot_fov: float = BASE_FOV
var auto_zoom: bool = true


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

	auto_zoom = bool(Settings.get_value("camera/auto_zoom"))
	position = Vector3(0.0, pilot_eye_height, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1: _set_mode(Mode.PILOT)
			KEY_2: _set_mode(Mode.CHASE)
			KEY_3: _set_mode(Mode.FPV)
			KEY_Z: _cycle_zoom()
			# X, beside Z: the other half of the zoom.
			KEY_X: set_auto_zoom(not auto_zoom)

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


func set_auto_zoom(enabled: bool) -> void:
	auto_zoom = enabled
	Settings.set_value("camera/auto_zoom", enabled)
	print("Pilot auto-zoom %s." % ("on" if enabled else "off"))


## The narrowest field the pilot view will reach without the pilot pressing Z:
## what the FAR chip measures against. With auto-zoom off it is the plain
## field, because that is what the pilot is actually looking through.
func get_narrowest_fov() -> float:
	return AUTO_MIN_FOV if auto_zoom else BASE_FOV


## The field auto-zoom wants for the aircraft where it is now, before Z.
func _auto_fov() -> float:
	if not auto_zoom or _sim == null or not _sim.has_method("get_wingspan_m"):
		return BASE_FOV
	var span: float = float(_sim.get_wingspan_m())
	var distance: float = (_sim.global_position - global_position).length()
	if span <= 0.0 or distance <= 0.01:
		return BASE_FOV
	var frame_h: float = get_viewport().get_visible_rect().size.y
	# The field at which the span is exactly AUTO_SPAN_PX tall.
	var subtended: float = rad_to_deg(2.0 * atan(span * 0.5 / distance))
	var wanted: float = subtended * frame_h / AUTO_SPAN_PX
	return clampf(wanted, AUTO_MIN_FOV, BASE_FOV)


## After a crash, look at the wreck.
##
## A pilot who has just put a model into the grass walks over to see what they
## did, and that looking IS the lesson - a beginner crashes constantly and the
## seconds afterwards are one of the most-visited screens in the product. What
## they got was a white speck twenty-eight metres away on a 1920-pixel frame,
## which teaches nothing about what just happened.
##
## Only in the pilot view, and only as a field-of-view change: the viewpoint
## still does not move, because apparent size is the pilot's only distance cue
## and moving the eye would throw it away.
func _update_crash_zoom(delta: float) -> void:
	if _camera == null or _sim == null:
		return
	var wrecked: bool = mode == Mode.PILOT and _sim.has_crashed()
	# Eased, not snapped. A cut to a different focal length reads as a bug -
	# unless the pilot has asked for less motion, in which case it is a cut.
	var target: float = 1.0 if wrecked else 0.0
	if Settings.reduced_motion():
		_crash_zoom = target
	else:
		_crash_zoom = move_toward(_crash_zoom, target, delta * 0.9)
	_was_zoomed_on_wreck = _crash_zoom > 0.001


## The pilot view's field, composed every frame: auto-zoom, then the Z step on
## top of it, then the walk-over-to-the-wreck zoom on top of that.
##
## Blended in log space with a half-life, so the blend takes the same time
## whatever the frame rate and a 38-to-19 change feels like a 12-to-6 one.
func _update_pilot_fov(delta: float) -> void:
	var target: float = _auto_fov() / ZOOM_STEPS[_zoom_index]
	if Settings.reduced_motion() or delta <= 0.0:
		_pilot_fov = target
	else:
		var keep: float = pow(0.5, delta / AUTO_HALF_LIFE_S)
		_pilot_fov = exp(lerpf(log(target), log(maxf(_pilot_fov, 0.01)), keep))
	_camera.fov = lerpf(_pilot_fov, _pilot_fov * CRASH_ZOOM, _crash_zoom)


func _apply_zoom() -> void:
	if _camera == null:
		return
	if mode == Mode.PILOT:
		# The step is the pilot's own keypress, so it is not eased: Z means now.
		_pilot_fov = _auto_fov() / ZOOM_STEPS[_zoom_index]
		_camera.fov = _pilot_fov
	else:
		_camera.fov = BASE_FOV


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
	# Read every frame rather than cached: the settings screen can change it
	# while the sortie is running.
	auto_zoom = bool(Settings.get_value("camera/auto_zoom"))

	match mode:
		Mode.PILOT: _update_pilot(delta)
		Mode.CHASE: _update_chase(delta)
		Mode.FPV:   _update_fpv()

	_update_crash_zoom(delta)
	if mode == Mode.PILOT:
		_update_pilot_fov(delta)


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
	#
	# Both are measured in fractions of the FIELD, not in degrees, so the
	# framing behaves the same through a 4x zoom or a 6 degree auto-zoom as it
	# does at the base field. In degrees, a 7 degree deadzone is wider than the
	# whole half-field of a zoomed view and the clamp below did all the work.
	var scale: float = _camera.fov / BASE_FOV if _camera != null else 1.0
	var deadzone: float = TRACKING_DEADZONE_DEGREES * scale
	var error: float = rad_to_deg(_tracked_direction.angle_to(direction))
	if error > deadzone:
		var catch_up: float = clampf(TRACKING_RATE * delta
			* ((error - deadzone) / (25.0 * scale)), 0.0, 1.0)
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
