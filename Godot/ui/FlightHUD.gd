# OpenRC Simulator - the flight overlay.
#
# Laid out around one question: what does a pilot actually look at, and when?
#
#   - The model. It sits in the middle of the frame, so the middle of the frame
#     stays clear: no panels, no corner cards, nothing at eye level.
#   - At a glance: speed, attitude and height, together in one cluster under
#     the model, so a single glance down reads all three. Bare outlined type on
#     a soft scrim - the numbers sit in the world rather than in boxes.
#   - Their own thumbs, on a keyboard: the stick gates, bottom left.
#   - Only when it matters: warnings. A red banner for what needs doing now,
#     a chip for what to fold into the flying, a toast for confirmations.
#   - Only in the phase it matters in: speed and height are hidden while
#     parked, the battery shows in the air only when it is getting low, the
#     attitude ring only in the pilot's view (see HudPhase).
#
# Three presets (Settings interface/hud, V in flight): Clean, Standard and
# Detailed. Engineering numbers - angle of attack, stalled fraction, rpm,
# thrust, height against the field - live in Detailed and behind F2.
#
# Everything is drawn rather than assembled from controls, because every
# element here is a gauge rather than a widget. Values are eased towards their
# targets so a 240 Hz simulation does not produce a flickering readout.
extends CanvasLayer

const Settings := preload("res://ui/Settings.gd")
const Warnings := preload("res://ui/FlightWarnings.gd")
const Hints := preload("res://ui/ContextHints.gd")
const Phase := preload("res://ui/HudPhase.gd")

## How long a chip stays up after its condition clears. Without it a sink rate
## hovering on the threshold blinks the chip on and off several times a second,
## which reads as a fault rather than as a warning.
const CHIP_LINGER_S: float = 0.6
## The whole HUD fades out this fast when an overlay comes up.
const OVERLAY_FADE_S: float = 0.12
## Elements appearing or leaving with the phase of the flight.
const ELEMENT_FADE_S: float = 0.2
const HINT_IN_S: float = 0.18
const HINT_OUT_S: float = 0.24
const PRESET_TOAST_S: float = 1.5
## The identity block quietens once nothing about it has changed for a while.
const IDENTITY_IDLE_S: float = 4.0
## The key legend collapses to "H Help" after this long airborne...
const LEGEND_COLLAPSE_S: float = 20.0
## ...and opens again for this long on C, H, Esc or a reset.
const LEGEND_EXPAND_S: float = 6.0
const CRASH_DIM: float = 0.35
const VIGNETTE_S: float = 0.6
## Free flight: the one-time "C changes the view" lesson, after this long up.
const TEACH_VIEW_AFTER_S: float = 60.0
const TEACH_VIEW_SHOW_S: float = 10.0
## Only if the aircraft file carries no measured stall speed and no approach
## speed to derive one from. Every shipped aircraft has the measured figure.
const FALLBACK_STALL_MPS: float = 7.9
## The speed ribbon spans 0 to this multiple of the stall speed.
const RIBBON_SPAN: float = 2.5
const RIBBON_H: float = 108.0
## Chips, in display order, so one does not jump sideways when another clears.
const CHIP_ORDER: Array[String] = ["stall", "low", "far", "battery"]
const MAX_CHIPS: int = 3
const MAX_HINTS: int = 3

@export var simulation_path: NodePath
@export var input_path: NodePath
## Mode 2: throttle and rudder on the left gimbal, elevator and aileron on the
## right. The world default outside Japan.
@export var mode_two: bool = true

# ------------------------------------------------- contract with Flight.gd ---

## The field, for the home indicator and the far-from-home hint. Flight.gd sets
## it on every spawn; until it does, the HUD uses where the aircraft was last
## put down on the runway.
var home_position: Vector3 = Vector3.ZERO
var home_valid: bool = false
## When non-empty, the hint chip shows these [{keys, text}] instead of the
## context hints (the guided first flight).
var hint_override: Array = []
## The guided first flight's items [{text, done: bool, current: bool}], drawn
## top left in place of the identity when non-empty.
var checklist: Array = []

# ----------------------------------------------------------------- state ---

var _sim: RCSimulationNode
var _input: RCInputNode
var _canvas: Control
## The attitude ring, on its own child so it can fade as one piece.
var _ring_canvas: Control
var _diagnostics: bool = false

# Eased display values. The simulation runs at 240 Hz; the eye does not.
var _airspeed: float = 0.0
## Height above the ground directly below - what a crash is measured against.
var _altitude: float = 0.0
## Height relative to the flying field, which goes negative over a valley.
var _field_altitude: float = 0.0
var _climb: float = 0.0
var _throttle: float = 0.0
var _alpha: float = 0.0
var _stall: float = 0.0
var _fps: float = 0.0
var _fps_accumulator: float = 0.0
var _fps_frames: int = 0
var _alert_phase: float = 0.0
var _vario_shown: float = 0.0
## Chips on screen: id -> {text, level, left (seconds of linger), alpha}.
var _chips: Dictionary = {}

## Overlay fade. Driven from the tree's frame signal, so it still runs while
## the tree is paused under the pause card.
var _overlay_open: bool = false
var _master_alpha: float = 1.0
var _last_ticks: int = 0

var _preset: String = "standard"
var _view: String = "follow"
var _phase: String = Phase.PARKED
var _el: Dictionary = {}
## Eased per-element visibility, 0..1.
var _vis: Dictionary = {}
## The crash dimming of the cluster: 1, or CRASH_DIM on a wreck.
var _dim: float = 1.0
var _crash_t: float = -1.0

# Per flight.
var _air_s: float = 0.0
var _flown: bool = false
var _was_crashed: bool = false
var _last_at: Vector3 = Vector3.INF
var _last_heading: float = INF
var _turn_sum: float = 0.0
var _takeoff_counted: bool = false
var _turn_counted: bool = false
var _landing_counted: bool = false

# Home, when Flight.gd has not said: the last runway spawn.
var _auto_home: Vector3 = Vector3.ZERO
var _auto_home_valid: bool = false
var _runway_axis: Vector3 = Vector3.ZERO
var _home_dist: float = -1.0
## Bearing to the field relative to the camera, radians: 0 ahead, +PI/2 right.
var _home_bearing: float = 0.0

var _stall_for: String = ""
var _stall_mps: float = FALLBACK_STALL_MPS

# Identity and legend.
var _status: String = ""
var _identity_idle: float = 0.0
var _identity_fade: float = 1.0
var _legend_expand: float = LEGEND_EXPAND_S
var _legend_full: float = 1.0

# Toast: notices, and the preset name when V cycles it.
var _toast_text: String = ""
var _toast_left: float = 0.0
var _toast_alpha: float = 0.0
var _preset_seen: String = ""

# Hints.
var _hints: Array = []
var _hints_key: String = ""
var _hints_alpha: float = 0.0
var _cand_key: String = ""
var _stuck_s: float = 0.0
var _stuck_ref: PackedFloat64Array = PackedFloat64Array()
var _escalation: int = 0
var _pulse_t: float = 0.0
var _offscreen_s: float = 0.0
## The one-time view lesson: 0 not yet, 1 showing, 2 done.
var _teach_state: int = 0
var _teach_t: float = 0.0
static var _view_taught_session: bool = false

# Layout, worked out once a frame in _process and used by both draw passes.
var _cx: float = 960.0
var _B: float = 1040.0
var _fx: float = 0.0
var _fw: float = 1920.0


func _ready() -> void:
	layer = 5
	_sim = get_node_or_null(simulation_path) as RCSimulationNode
	_input = get_node_or_null(input_path) as RCInputNode

	_canvas = Control.new()
	_canvas.name = "HUD"
	_canvas.anchor_right = 1.0
	_canvas.anchor_bottom = 1.0
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_hud)
	add_child(_canvas)

	_ring_canvas = Control.new()
	_ring_canvas.name = "Ring"
	_ring_canvas.anchor_right = 1.0
	_ring_canvas.anchor_bottom = 1.0
	_ring_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring_canvas.draw.connect(_draw_ring)
	_canvas.add_child(_ring_canvas)

	for id in ["speed", "height", "throttle", "battery", "ring", "home", "identity",
			"legend", "gates", "lift", "engineering"]:
		_vis[id] = 0.0
	_last_ticks = Time.get_ticks_usec()
	# The tree's own frame signal fires while it is paused, which _process does
	# not: the fade under the pause card has to keep running.
	get_tree().process_frame.connect(_on_frame)


## Fades the whole HUD out (and the hints with it) while an overlay or menu is
## up. Flight.gd calls it; the pause, help and settings screens are also
## noticed on their own.
func set_overlay_open(open: bool) -> void:
	_overlay_open = open


func _overlay_up() -> bool:
	if _overlay_open:
		return true
	var parent: Node = get_parent()
	if parent == null:
		return false
	for overlay in ["PauseOverlay", "HelpOverlay", "SettingsScreen"]:
		if parent.has_node(overlay):
			return true
	return false


func _on_frame() -> void:
	var now: int = Time.get_ticks_usec()
	var dt: float = clampf(float(now - _last_ticks) / 1e6, 0.0, 0.1)
	_last_ticks = now
	if _canvas == null:
		return
	var target: float = 0.0 if _overlay_up() else 1.0
	var rate: float = 1000.0 if Settings.reduced_motion() else dt / OVERLAY_FADE_S
	_master_alpha = move_toward(_master_alpha, target, rate)
	_canvas.modulate.a = _master_alpha
	if get_tree().paused and visible:
		_canvas.queue_redraw()
		_ring_canvas.queue_redraw()


func _shortcut_input(event: InputEvent) -> void:
	# Watched, never consumed: these keys belong to Flight.gd.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_C, KEY_H, KEY_ESCAPE, KEY_F1]:
			_legend_expand = LEGEND_EXPAND_S


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F9:
			visible = not visible
		elif event.keycode == KEY_F2:
			_diagnostics = not _diagnostics


## A short confirmation - "flight log saved" - for when a key did something with
## no other visible effect. A toast under the chips, never a banner.
func show_notice(text: String, seconds: float = 3.0) -> void:
	_toast_text = text
	_toast_left = seconds


func _process(delta: float) -> void:
	if _sim == null or not visible:
		return

	_fps_accumulator += delta
	_fps_frames += 1
	if _fps_accumulator >= 0.25:
		_fps = float(_fps_frames) / _fps_accumulator
		_fps_accumulator = 0.0
		_fps_frames = 0

	# Different quantities want different amounts of smoothing: a stall warning
	# has to be prompt, an airspeed readout has to be steady.
	var quick: float = clampf(delta * 14.0, 0.0, 1.0)
	var steady: float = clampf(delta * 6.0, 0.0, 1.0)
	_airspeed = lerpf(_airspeed, _sim.get_airspeed_mps(), steady)
	_altitude = lerpf(_altitude, _height_above_ground(), steady)
	_field_altitude = lerpf(_field_altitude, _sim.get_altitude_m(), steady)
	_climb = lerpf(_climb, _sim.get_velocity_world().y, steady)
	_alpha = lerpf(_alpha, _sim.get_alpha_degrees(), steady)
	_stall = lerpf(_stall, _sim.get_stalled_fraction(), quick)
	_throttle = lerpf(_throttle, _sim.get_channels()[2], quick)
	if _sim.get_lift_enabled():
		# Smoothed, hard. A real variometer lags because the air is turbulent
		# and an instantaneous reading is unreadable; so is this one without it.
		_vario_shown = lerpf(_vario_shown, _sim.get_air_vertical_speed_mps(),
				clampf(delta * 4.8, 0.0, 1.0))
	else:
		_vario_shown = 0.0

	# The radio in the pilot's hands decides which gimbal carries the throttle.
	mode_two = int(Settings.get_value("controls/stick_mode")) != 1

	_preset = String(Settings.get_value("interface/hud"))
	if _preset_seen.is_empty():
		_preset_seen = _preset
	elif _preset != _preset_seen:
		_preset_seen = _preset
		show_notice("HUD: %s" % _preset.capitalize(), PRESET_TOAST_S)
	_toast_left = maxf(_toast_left - delta, 0.0)
	var toast_rate: float = 1000.0 if Settings.reduced_motion() else delta / 0.2
	_toast_alpha = move_toward(_toast_alpha, 1.0 if _toast_left > 0.0 else 0.0, toast_rate)

	var rig: Node = _rig()
	var view: String = "follow"
	if rig != null and rig.has_method("get_mode_name"):
		view = String(rig.get_mode_name())
	if view != _view:
		_on_view_changed()
	_view = view

	var size: Vector2 = _canvas.size
	_fw = minf(size.x, size.y * 2.0)
	_fx = (size.x - _fw) * 0.5
	_cx = size.x * 0.5
	_B = size.y - UITheme.HUD_M - (140.0 if _replay_open() else 0.0)

	_update_flight(delta)
	_update_home()
	_update_phase()
	_update_chips(delta)
	_update_offscreen(delta)
	_update_hints(delta)
	_update_visibility(delta)

	_alert_phase += delta
	_canvas.queue_redraw()
	_ring_canvas.modulate.a = float(_vis["ring"]) * _dim
	_ring_canvas.queue_redraw()


func _rig() -> Node:
	return get_parent().get_node_or_null("CameraRig") if get_parent() != null else null


func _replay_open() -> bool:
	return get_parent() != null and get_parent().has_node("ReplayBar")


## The gap between the model and the ground straight below it, from the
## physics core's own sample (the same ground a crash is judged against).
func _height_above_ground() -> float:
	if _sim.has_method("get_height_above_ground_m"):
		var h: float = _sim.get_height_above_ground_m()
		if h >= 0.0:
			return h
	var at: Vector3 = _sim.global_position
	return at.y - _sim.get_terrain_height(at.x, at.z)


## The aircraft's own stall speed, as measured by the regression suite and
## quoted in the menu's brief. It was hard-coded at the trainer's 7.9 m/s,
## which made the ribbon lie for the glider and the warbird.
func _stall_speed() -> float:
	var aircraft: String = _sim.get_aircraft_name()
	if aircraft != _stall_for:
		_stall_for = aircraft
		var perf: Dictionary = _sim.get_performance()
		_stall_mps = float(perf.get("stall_speed_mps", 0.0))
		if _stall_mps <= 0.5:
			var approach: float = _sim.get_approach_speed_mps()
			_stall_mps = approach / 1.3 if approach > 0.5 else FALLBACK_STALL_MPS
	return _stall_mps


func _flying() -> bool:
	# Parked in a breeze the wing is technically separated - the relative wind
	# comes from behind it. Shouting STALL at a stationary model is noise, and
	# noise is how a warning stops being read.
	return not _sim.is_on_ground() or _sim.get_airspeed_mps() > 6.0


# ------------------------------------------------------------- per flight ---

## Per-flight bookkeeping: time in the air, whether it has left the ground, the
## crash clock, and the successes that teach the hints they are learned.
func _update_flight(delta: float) -> void:
	var at: Vector3 = _sim.global_position
	var crashed: bool = _sim.has_crashed()
	var first: bool = _last_at == Vector3.INF
	var jumped: bool = not first and at.distance_to(_last_at) > 15.0
	if first or jumped or (_was_crashed and not crashed):
		_air_s = 0.0
		_flown = false
		_turn_sum = 0.0
		_last_heading = INF
		_takeoff_counted = false
		_turn_counted = false
		_landing_counted = false
		_crash_t = -1.0
		_legend_expand = LEGEND_EXPAND_S
		_capture_auto_home(at)
	if crashed and not _was_crashed:
		_crash_t = 0.0
		_legend_expand = LEGEND_EXPAND_S
	if crashed:
		_crash_t += delta
	_was_crashed = crashed
	_last_at = at
	_legend_expand = maxf(_legend_expand - delta, 0.0)

	var airborne: bool = not _sim.is_on_ground() and not crashed
	if airborne:
		_air_s += delta
		if _air_s > 0.6:
			_flown = true

	var forward: Vector3 = -_sim.global_transform.basis.z
	forward.y = 0.0
	if forward.length() > 0.1:
		var heading: float = atan2(forward.x, -forward.z)
		if airborne and _last_heading != INF:
			_turn_sum += angle_difference(_last_heading, heading)
		_last_heading = heading

	# Successes, for "until learned" hints.
	if _flown and not crashed and not _takeoff_counted and _air_s >= 10.0:
		_takeoff_counted = true
		Settings.hint_success("throttle")
		Settings.hint_success("takeoff")
	if airborne and not _turn_counted and absf(_turn_sum) >= deg_to_rad(150.0):
		_turn_counted = true
		Settings.hint_success("turn")
	if _flown and not crashed and _sim.is_on_ground() and not _landing_counted \
			and _sim.get_ground_speed_mps() < 2.0:
		_landing_counted = true
		Settings.hint_success("land")


func _capture_auto_home(at: Vector3) -> void:
	var runway: bool = int(_sim.spawn_mode) == 0
	if runway or not _auto_home_valid:
		_auto_home = at
		_auto_home_valid = true
	if runway:
		var axis: Vector3 = -_sim.global_transform.basis.z
		axis.y = 0.0
		_runway_axis = axis.normalized() if axis.length() > 0.1 else Vector3.ZERO


func _home() -> Vector3:
	return home_position if home_valid else _auto_home


func _update_home() -> void:
	if not home_valid and not _auto_home_valid:
		_home_dist = -1.0
		return
	var at: Vector3 = _sim.global_position
	var to_home: Vector3 = _home() - at
	to_home.y = 0.0
	_home_dist = to_home.length()
	var camera: Camera3D = get_viewport().get_camera_3d()
	var basis: Basis = camera.global_transform.basis if camera != null \
			else _sim.global_transform.basis
	var forward: Vector3 = -basis.z
	forward.y = 0.0
	var right: Vector3 = basis.x
	right.y = 0.0
	if forward.length() < 0.05 or _home_dist < 0.5:
		_home_bearing = 0.0
		return
	_home_bearing = atan2(to_home.dot(right.normalized()), to_home.dot(forward.normalized()))


func _home_dir() -> String:
	var a: float = absf(_home_bearing)
	if a < PI * 0.25:
		return "ahead"
	if a > PI * 0.75:
		return "behind"
	return "right" if _home_bearing > 0.0 else "left"


## Lined up with the runway on the approach, either way along it. Unknown
## runway: assume so, rather than nag.
func _aligned() -> bool:
	if _runway_axis == Vector3.ZERO or home_valid:
		return true
	var v: Vector3 = _sim.get_velocity_world()
	v.y = 0.0
	if v.length() < 1.0:
		return true
	return absf(v.normalized().dot(_runway_axis)) > cos(deg_to_rad(20.0))


func _update_phase() -> void:
	var state: Dictionary = {
		"crashed": _sim.has_crashed(),
		"on_ground": _sim.is_on_ground(),
		"ground_speed": _sim.get_ground_speed_mps(),
		"air_s": _air_s,
		"height_m": _altitude,
		"sink_mps": -_climb,
		"throttle": _throttle,
		"distance_home": _home_dist,
	}
	_phase = Phase.evaluate(state)
	var has_battery: bool = _sim.get_battery_cells() > 0
	_el = Phase.elements(_phase, _preset, _view,
			_sim.get_battery_charge() if has_battery else 1.0, _home_dist)
	if not has_battery:
		_el["battery"] = false


func _on_view_changed() -> void:
	_legend_expand = LEGEND_EXPAND_S
	# Pressing C at all is the lesson learned.
	if _teach_state == 1 or (_teach_state == 2 and not Settings.hint_learned("view")):
		_mark_view_learned()


func _mark_view_learned() -> void:
	_teach_state = 2
	_view_taught_session = true
	var guard: int = 0
	while Settings.hint_count("view") < Settings.HINT_LEARNED_AFTER and guard < 5:
		Settings.hint_success("view")
		guard += 1


func _update_visibility(delta: float) -> void:
	var rate: float = 1000.0 if Settings.reduced_motion() else delta / ELEMENT_FADE_S
	var targets: Dictionary = {}
	for id in ["speed", "height", "throttle", "battery", "ring", "home", "identity",
			"legend", "engineering"]:
		targets[id] = 1.0 if bool(_el.get(id, false)) else 0.0
	targets["engineering"] = 1.0 if (bool(_el.get("engineering", false)) or _diagnostics) \
			else 0.0
	targets["gates"] = 1.0 if _gates_wanted() else 0.0
	# With hysteresis, so air hovering around nothing does not blink it.
	var lift_on: float = 0.15 if float(_vis.get("lift", 0.0)) > 0.5 else 0.3
	targets["lift"] = 1.0 if _preset != "clean" and _sim.get_lift_enabled() \
			and absf(_vario_shown) > lift_on else 0.0
	for id in targets:
		_vis[id] = move_toward(float(_vis.get(id, 0.0)), float(targets[id]), rate)

	var dim_rate: float = 1000.0 if Settings.reduced_motion() else delta / 0.2
	_dim = move_toward(_dim, CRASH_DIM if _sim.has_crashed() else 1.0, dim_rate)

	var status: String = _status_word()
	if status != _status:
		_status = status
		_identity_idle = 0.0
	else:
		_identity_idle += delta
	var fade_target: float = 1.0 if _identity_idle < IDENTITY_IDLE_S else 0.55
	_identity_fade = move_toward(_identity_fade, fade_target,
			1000.0 if Settings.reduced_motion() else delta / 0.4)

	var collapsed: bool = Phase.is_airborne(_phase) and _air_s > LEGEND_COLLAPSE_S \
			and _legend_expand <= 0.0
	_legend_full = move_toward(_legend_full, 0.0 if collapsed else 1.0, rate)


## The stick display: on the keyboard by default (the keys are invisible, so
## the gates show what they are doing); with a radio only when asked for.
func _gates_wanted() -> bool:
	match String(Settings.get_value("interface/stick_display")):
		"on":
			return true
		"off":
			return false
	return _input == null or not _input.is_connected()


func _status_word() -> String:
	if _sim.has_crashed():
		return "Crashed"
	return "On ground" if _sim.is_on_ground() else "Airborne"


# ------------------------------------------------------------------ chips ---

## Works out which chips should be up, from the pure rules in FlightWarnings,
## and eases each one in and out.
func _update_chips(delta: float) -> void:
	var rig: Node = _rig()
	var at: Vector3 = _sim.global_position
	var span_px: float = -1.0
	# FAR is a pilot-view question: from the chase or the cockpit the model is
	# never far.
	if rig != null and rig.get("mode") == 0 and rig.has_method("get_narrowest_fov"):
		span_px = Warnings.span_pixels(_sim.get_wingspan_m(),
				(at - (rig as Node3D).global_position).length(),
				rig.get_narrowest_fov(), _canvas.size.y)
	var state: Dictionary = {
		"crashed": _sim.has_crashed(),
		"airborne": not _sim.is_on_ground(),
		"flying": _flying(),
		"stall": _stall,
		"sink_mps": -_climb,
		"height_m": at.y - _sim.get_terrain_height(at.x, at.z),
		"span_px": span_px,
		"battery": _sim.get_battery_charge(),
		"has_battery": _sim.get_battery_cells() > 0,
	}
	var live: Dictionary = {}
	for chip in Warnings.evaluate(state):
		live[chip["id"]] = chip

	var rate: float = 1000.0 if Settings.reduced_motion() else delta * 6.0
	for id in CHIP_ORDER:
		var entry: Dictionary = _chips.get(id, {})
		if live.has(id):
			entry["text"] = live[id]["text"]
			entry["level"] = live[id]["level"]
			entry["left"] = CHIP_LINGER_S
		elif not entry.is_empty():
			entry["left"] = float(entry["left"]) - delta
		if entry.is_empty():
			continue
		# Crashed clears at once: the chips would only be repeating stale news
		# about an aeroplane that is in the grass.
		var wanted: float = 1.0 if float(entry["left"]) > 0.0 \
				and not state["crashed"] else 0.0
		entry["alpha"] = move_toward(float(entry.get("alpha", 0.0)), wanted, rate)
		if wanted == 0.0 and float(entry["alpha"]) <= 0.0:
			_chips.erase(id)
		else:
			_chips[id] = entry


# ------------------------------------------------------------------ hints ---

func _update_offscreen(delta: float) -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null or _view != "pilot" or _sim.has_crashed():
		_offscreen_s = 0.0
		return
	var at: Vector3 = _sim.global_position
	var point: Vector2 = camera.unproject_position(at)
	var seen: bool = not camera.is_position_behind(at) \
			and Rect2(Vector2.ZERO, _canvas.size).has_point(point)
	_offscreen_s = 0.0 if seen else _offscreen_s + delta


func _update_hints(delta: float) -> void:
	var keyboard: bool = _input == null or not _input.is_connected()
	var crashed: bool = _sim.has_crashed()

	# The one-time view lesson, in free flight only.
	if _teach_state == 0 and not _view_taught_session and hint_override.is_empty() \
			and checklist.is_empty() and _phase == Phase.CRUISE \
			and _air_s > TEACH_VIEW_AFTER_S and _view == "follow" \
			and Settings.hint_mode() != "off" and not Settings.hint_learned("view"):
		_teach_state = 1
		_teach_t = 0.0
	if _teach_state == 1:
		_teach_t += delta
		if _teach_t > TEACH_VIEW_SHOW_S or crashed:
			_teach_state = 2
			_view_taught_session = true

	var learned: Array = []
	for id in Hints.LEARNABLE:
		if Settings.hint_learned(id):
			learned.append(id)
	var state: Dictionary = {
		"input": "keyboard" if keyboard else "radio",
		"mode": 2 if mode_two else 1,
		"crashed": crashed,
		"replay": _replay_open(),
		"armed": _input == null or _input.is_throttle_armed(),
		"on_ground": _sim.is_on_ground(),
		"airspeed": _sim.get_ground_speed_mps(),
		"throttle": _throttle,
		"air_s": _air_s,
		"flown": _flown,
		"phase": _phase,
		"view": _view,
		"offscreen_s": _offscreen_s,
		"distance_home": _home_dist,
		"home_dir": _home_dir(),
		"height_m": _altitude,
		"air_mps": _airspeed,
		"stall_mps": _stall_speed(),
		"aligned": _aligned(),
		"teach_view": _teach_state == 1,
		"hint_mode": Settings.hint_mode(),
		"learned": learned,
	}

	# How long has the same advice stood with the sticks left alone?
	var channels: PackedFloat64Array = _input.get_channels() if _input != null \
			else PackedFloat64Array()
	var candidate_key: String = _hint_key(Hints.candidates(state)) if hint_override.is_empty() \
			else _hint_key(hint_override)
	var moved: bool = false
	if channels.size() == _stuck_ref.size():
		for i in channels.size():
			if absf(channels[i] - _stuck_ref[i]) > 0.2:
				moved = true
				break
	if candidate_key != _cand_key or moved or channels.size() != _stuck_ref.size():
		_cand_key = candidate_key
		_stuck_s = 0.0
		_stuck_ref = channels.duplicate()
	else:
		_stuck_s += delta
	state["stuck_s"] = _stuck_s

	var wanted: Array
	if not hint_override.is_empty():
		wanted = hint_override.slice(0, MAX_HINTS)
		if Hints.escalation(_stuck_s) >= 2:
			wanted.append({"id": "help", "keys": ["H"], "text": "See all the controls",
					"line": 2})
	else:
		wanted = Hints.evaluate(state)
	if _preset == "clean" or not bool(_el.get("hints", true)):
		# Clean shows no lessons - only why the motor will not run.
		wanted = wanted.filter(func(h: Dictionary) -> bool: return h.get("id", "") == "arm")
	if _overlay_up() or crashed:
		wanted = []

	var level: int = Hints.escalation(_stuck_s)
	if level >= 1 and _escalation == 0 and not wanted.is_empty():
		_pulse_t = 0.9
	_escalation = level
	_pulse_t = maxf(_pulse_t - delta, 0.0)

	var key: String = _hint_key(wanted)
	var reduced: bool = Settings.reduced_motion()
	if key == _hints_key:
		# Same advice, perhaps new figures in it ("The field is 180 m"): update
		# the words without fading.
		_hints = wanted
	if key != _hints_key:
		# Fade the old set out before the new one comes in.
		_hints_alpha = move_toward(_hints_alpha, 0.0, 1000.0 if reduced else delta / HINT_OUT_S)
		if _hints_alpha <= 0.0:
			_hints = wanted
			_hints_key = key
	else:
		_hints_alpha = move_toward(_hints_alpha, 1.0, 1000.0 if reduced else delta / HINT_IN_S)


## Identity of a hint set, without its figures: a distance counting down in
## the text must not fade the chip out and in every metre.
static func _hint_key(hints: Array) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for h in hints:
		var id: String = String(h.get("id", ""))
		var text: String = "" if id == "far" else String(h.get("text", ""))
		parts.append("%s|%s|%s|%s" % [id, str(h.get("keys", [])),
				String(h.get("level", "")), text])
	return ";".join(parts)


# ---------------------------------------------------------------- drawing ---

static func _a(c: Color, alpha: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * alpha)


## Text over the world: outlined, semibold by default.
func _text(pos: Vector2, text: String, size: int, colour: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, f: Font = null) -> void:
	var face: Font = f if f != null else UITheme.font_semibold()
	var x: float = pos.x
	if align == HORIZONTAL_ALIGNMENT_RIGHT:
		x -= face.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	elif align == HORIZONTAL_ALIGNMENT_CENTER:
		x -= face.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x * 0.5
	UITheme.draw_text(_canvas, Vector2(x, pos.y), text, size, colour,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, true, face)


func _text_w(text: String, size: int, f: Font = null) -> float:
	var face: Font = f if f != null else UITheme.font_semibold()
	return face.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## Tracked caps over the world; `align` RIGHT puts the end at `pos.x`.
func _caps(pos: Vector2, text: String, colour: Color, size: int = UITheme.SIZE_CAPS,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, spacing: int = UITheme.TRACK_CAPS) -> void:
	var x: float = pos.x
	if align == HORIZONTAL_ALIGNMENT_RIGHT:
		x -= UITheme.label_width(text, spacing, size)
	elif align == HORIZONTAL_ALIGNMENT_CENTER:
		x -= UITheme.label_width(text, spacing, size) * 0.5
	UITheme.draw_label(_canvas, Vector2(x, pos.y), text, colour, spacing, size, true)


func _draw_hud() -> void:
	if _sim == null:
		return
	var size: Vector2 = _canvas.size
	_draw_scrims(size)
	_draw_vignette(size)
	if not checklist.is_empty():
		_draw_checklist(Vector2(_fx + UITheme.HUD_M, UITheme.HUD_M))
	else:
		_draw_identity(Vector2(_fx + UITheme.HUD_M, UITheme.HUD_M))
	_draw_legend(Vector2(_fx + _fw - UITheme.HUD_M, UITheme.HUD_M))
	if bool(_el.get("chips", true)):
		_draw_chips(Vector2(_cx, UITheme.HUD_M))
	_draw_toast(Vector2(_cx, 88.0))
	_draw_alerts(Vector2(_cx, 220.0))
	_draw_hints(Vector2(_cx, _B - 188.0))
	_draw_flight_cluster()
	_draw_power_column(_cx - 310.0)
	_draw_lift(_cx + 310.0)
	_draw_sticks(Vector2(_fx + UITheme.HUD_M, _B))
	_draw_engineering(Vector2(_fx + _fw - UITheme.HUD_M, _B))
	_draw_locator()
	if _diagnostics:
		# Left side: the tuning drawer owns the right edge, and two drawers
		# fighting for the same corner is worse than either of them.
		_draw_diagnostics(Vector2(_fx + UITheme.HUD_M, 170.0))


## Soft gradients under the top band and the bottom cluster: contrast for the
## type without a single box.
func _draw_scrims(size: Vector2) -> void:
	if _preset != "clean":
		UITheme.draw_scrim(_canvas, Rect2(0, 0, size.x, 140.0), 0.30, 0.0)
	var bottom: float = _B + UITheme.HUD_M
	var strength: float = 0.30 if _preset == "clean" else 0.45
	UITheme.draw_scrim(_canvas, Rect2(0, bottom - 300.0, size.x, 300.0), 0.0, strength)
	if bottom < size.y:
		_canvas.draw_rect(Rect2(0, bottom, size.x, size.y - bottom),
				_a(UITheme.SCRIM, strength))


## A short red flash at the edges of the frame on impact.
func _draw_vignette(size: Vector2) -> void:
	if _crash_t < 0.0 or _crash_t > VIGNETTE_S or Settings.reduced_motion():
		return
	var a: float = 0.22 * (1.0 - _crash_t / VIGNETTE_S)
	var d: float = 120.0
	var red: Color = UITheme.DANGER
	UITheme.draw_scrim(_canvas, Rect2(0, 0, size.x, d), a, 0.0, red)
	UITheme.draw_scrim(_canvas, Rect2(0, size.y - d, size.x, d), 0.0, a, red)
	UITheme.draw_scrim(_canvas, Rect2(0, 0, d, size.y), a, 0.0, red, true)
	UITheme.draw_scrim(_canvas, Rect2(size.x - d, 0, d, size.y), 0.0, a, red, true)


## Aircraft name and what it is doing. Quiet, top left, where a title goes.
func _draw_identity(origin: Vector2) -> void:
	var a: float = float(_vis["identity"]) * _identity_fade
	if a <= 0.01:
		return
	UITheme.draw_display(_canvas, Vector2(origin.x, 68.0), _sim.get_aircraft_name(),
			30, _a(UITheme.TEXT, a), HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
	var colour: Color = UITheme.HUD_LABEL
	if _status == "Crashed":
		colour = UITheme.DANGER
	elif _status == "Airborne":
		colour = UITheme.ACCENT
	_canvas.draw_circle(Vector2(origin.x + 4.0, 90.0), 5.5, _a(UITheme.SCRIM, 0.6 * a))
	_canvas.draw_circle(Vector2(origin.x + 4.0, 90.0), 4.0, _a(colour, a))
	_text(Vector2(origin.x + 16.0, 96.0), _status, UITheme.SIZE_BODY_S, _a(colour, a))


## The guided first flight: what has been done, what is being done now.
func _draw_checklist(origin: Vector2) -> void:
	var pitch: float = 36.0
	var width: float = 360.0
	for item in checklist:
		width = maxf(width, 64.0 + _text_w(String(item.get("text", "")), 20))
	var height: float = 52.0 + pitch * float(checklist.size()) + 8.0
	var card := Rect2(origin, Vector2(width, height))
	_canvas.draw_colored_polygon(UITheme.rounded_rect(card, UITheme.R_LG),
			_a(UITheme.BASE, 0.74))
	var edge: PackedVector2Array = UITheme.rounded_rect(card, UITheme.R_LG)
	edge.append(edge[0])
	_canvas.draw_polyline(edge, UITheme.STROKE_STRONG, 1.0, true)

	var done: int = 0
	for item in checklist:
		if bool(item.get("done", false)):
			done += 1
	UITheme.draw_label(_canvas, origin + Vector2(20, 32), "First flight", UITheme.ACCENT)
	var count: String = "%d / %d" % [done, checklist.size()]
	UITheme.draw_text(_canvas, Vector2(card.end.x - 20.0 - _text_w(count, 18), origin.y + 32.0),
			count, 18, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false,
			UITheme.font_semibold())
	var y: float = origin.y + 52.0
	for i in checklist.size():
		var item: Dictionary = checklist[i]
		var is_done: bool = bool(item.get("done", false))
		var current: bool = bool(item.get("current", false))
		var row := Rect2(origin.x + 8.0, y, width - 16.0, pitch - 4.0)
		if current:
			_canvas.draw_colored_polygon(UITheme.rounded_rect(row, UITheme.R_SM),
					_a(UITheme.ACCENT, 0.12))
			_canvas.draw_rect(Rect2(row.position.x, row.position.y + 6.0, 3.0, row.size.y - 12.0),
					UITheme.ACCENT)
		var centre := Vector2(origin.x + 30.0, y + (pitch - 4.0) * 0.5)
		UITheme.draw_step_circle(_canvas, centre, i + 1,
				"done" if is_done else ("current" if current else "todo"), 22.0)
		var colour: Color = UITheme.TEXT if current else \
				(UITheme.TEXT_DIM if is_done else _a(UITheme.TEXT_DIM, 0.8))
		UITheme.draw_text(_canvas, Vector2(origin.x + 52.0, centre.y + 7.0),
				String(item.get("text", "")), 20 if current else 19, colour,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, false,
				UITheme.font_semibold() if current else UITheme.font())
		y += pitch


## Top right: the keys that open everything else. After a while in the air it
## folds down to "H Help"; it opens again on C, H, Esc or a reset.
func _draw_legend(anchor: Vector2) -> void:
	var a: float = float(_vis["legend"]) * _dim
	if a > 0.01:
		var view: String = {"follow": "Follow view", "pilot": "Pilot view",
				"FPV": "FPV view"}.get(_view, "View")
		var rows: Array = [[["H"], "Help", 1.0], [["C"], view, _legend_full],
				[["ESC"], "Menu", _legend_full]]
		var y: float = anchor.y + 13.0
		for row in rows:
			var ra: float = a * float(row[2])
			if row[1] == "Help":
				ra = a * lerpf(0.7, 1.0, _legend_full)
			if ra > 0.01:
				var w: float = UITheme.key_hint_width(row[0], row[1], UITheme.SIZE_KEY)
				UITheme.draw_key_hint(_canvas, Vector2(anchor.x - w, y), row[0], row[1],
						UITheme.SIZE_KEY, UITheme.HUD_LABEL, ra, true)
			y += 34.0
	_draw_home(Vector2(anchor.x, anchor.y + 13.0 + 34.0 * lerpf(1.0, 3.0, _legend_full) + 6.0))


## "Field 180 m" and an arrow that points at it, relative to the view.
func _draw_home(anchor: Vector2) -> void:
	var a: float = float(_vis["home"])
	if a <= 0.01 or _home_dist < 0.0:
		return
	var parts: PackedStringArray = Settings.format_height(_home_dist, Settings.units())
	var text: String = "Field %s %s" % [parts[0], parts[1]]
	var centre := Vector2(anchor.x - 15.0, anchor.y + 4.0)
	_canvas.draw_circle(centre, 15.0, _a(UITheme.SCRIM, 0.45 * a))
	_canvas.draw_arc(centre, 15.0, 0.0, TAU, 32, _a(UITheme.ACCENT, 0.55 * a), 1.5, true)
	var dir := Vector2(sin(_home_bearing), -cos(_home_bearing))
	var n := Vector2(-dir.y, dir.x)
	var tip: Vector2 = centre + dir * 9.0
	var tail: Vector2 = centre - dir * 9.0
	_canvas.draw_line(tail, tip - dir * 2.0, _a(UITheme.ACCENT, a), 2.0, true)
	_canvas.draw_colored_polygon(PackedVector2Array([tip, tip - dir * 7.0 + n * 5.0,
			tip - dir * 7.0 - n * 5.0]), _a(UITheme.ACCENT, a))
	_text(Vector2(anchor.x - 40.0, anchor.y + 10.0), text, UITheme.SIZE_BODY_S,
			_a(UITheme.TEXT, a), HORIZONTAL_ALIGNMENT_RIGHT)


## The chip row: short facts, top centre, above the banner and separate from
## it. Only the red ones pulse.
func _draw_chips(top_centre: Vector2) -> void:
	if _chips.is_empty():
		return
	var spacing: int = 2
	var size: int = UITheme.SIZE_CAPS_L
	var height: float = 36.0
	var gap: float = UITheme.S3
	var widths: Array[float] = []
	var shown: Array[Dictionary] = []
	var total: float = 0.0
	# The banner and the chips never say the same thing: once the banner says
	# STALL, the lingering stall chip goes at once.
	var banner_stall: bool = _flying() and _stall > Warnings.STALL_BANNER
	for id in CHIP_ORDER:
		if not _chips.has(id) or shown.size() >= MAX_CHIPS:
			continue
		if id == "stall" and banner_stall:
			continue
		var chip: Dictionary = _chips[id]
		var w: float = UITheme.label_width(chip["text"], spacing, size) + 34.0 + 18.0
		widths.append(w)
		shown.append(chip)
		total += w
	total += gap * float(shown.size() - 1)
	var x: float = top_centre.x - total * 0.5
	for i in shown.size():
		var chip: Dictionary = shown[i]
		var danger: bool = chip["level"] == Warnings.DANGER
		var colour: Color = UITheme.DANGER if danger else UITheme.WARN
		var a: float = float(chip["alpha"])
		# Only the red ones pulse, and only their edge: the words stay steady.
		var pulse: float = 1.0
		if danger and not Settings.reduced_motion():
			pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(_alert_phase * TAU / 1.2))
		var rect := Rect2(Vector2(roundf(x), top_centre.y), Vector2(roundf(widths[i]), height))
		var fill: Color = UITheme.DANGER_BG if danger else UITheme.WARN_BG
		var shape: PackedVector2Array = UITheme.rounded_rect(rect, height * 0.5)
		_canvas.draw_colored_polygon(shape, _a(fill, a))
		shape.append(shape[0])
		_canvas.draw_polyline(shape, _a(colour, 0.8 * a * pulse), 1.5, true)
		_canvas.draw_circle(rect.position + Vector2(17.0, height * 0.5), 3.5, _a(colour, a * pulse))
		UITheme.draw_label(_canvas, rect.position + Vector2(30.0, height * 0.5 + size * 0.36),
				chip["text"], _a(colour, a), spacing, size)
		x += widths[i] + gap


## Confirmations - "HUD: Clean", "flight log saved" - under the chips.
func _draw_toast(top_centre: Vector2) -> void:
	if _toast_alpha <= 0.01 or _toast_text.is_empty():
		return
	var a: float = _toast_alpha
	var size: int = UITheme.SIZE_BODY_S
	var w: float = _text_w(_toast_text, size) + 44.0
	var rect := Rect2(Vector2(roundf(top_centre.x - w * 0.5), top_centre.y - 6.0 * (1.0 - a)),
			Vector2(roundf(w), 36.0))
	var shape: PackedVector2Array = UITheme.rounded_rect(rect, 18.0)
	_canvas.draw_colored_polygon(shape, _a(UITheme.BASE, 0.72 * a))
	shape.append(shape[0])
	_canvas.draw_polyline(shape, _a(UITheme.STROKE_STRONG, a), 1.0, true)
	UITheme.draw_text(_canvas, Vector2(rect.position.x + 22.0, rect.position.y + 24.0),
			_toast_text, size, _a(UITheme.TEXT, a), HORIZONTAL_ALIGNMENT_LEFT, -1.0, false,
			UITheme.font_semibold())


## One banner slot, for the one thing that has to be done now. Red only:
## everything amber is a chip, and a crash is the crash card's to explain.
func _draw_alerts(centre: Vector2) -> void:
	var text: String = ""
	# Failure practice can hide the words and keep the symptoms, so the pilot
	# has to work out what broke from how the aeroplane is behaving.
	if _sim.has_failure() and bool(Settings.get_value("practice/failure_notice")):
		text = _sim.get_failure_text().to_upper()
	elif _sim.has_crashed():
		return
	elif _flying() and _stall > Warnings.STALL_BANNER:
		text = "STALL — LOWER THE NOSE"
	elif _input != null and _input.is_connected() \
			and not _input.get_profile_problem().is_empty():
		var problem: String = _input.get_profile_problem()
		# The silent-radio case gets its own words: sending the pilot to the
		# wizard would be sending them somewhere that cannot help.
		if problem.find("not sending anything") >= 0:
			text = "TRANSMITTER SENDING NOTHING · IS THE RADIO ON?"
		else:
			text = "TRANSMITTER BINDING LOOKS WRONG · PRESS F3"
	else:
		return

	var pulse: float = 1.0 if Settings.reduced_motion() \
			else 0.85 + 0.15 * sin(_alert_phase * TAU / 1.2)
	var size: int = UITheme.SIZE_BANNER
	var text_w: float = UITheme.label_width(text, 3, size)
	var width: float = maxf(text_w + 28.0 * 2.0 + 32.0, 280.0)
	var rect := Rect2((centre - Vector2(width * 0.5, 26.0)).round(), Vector2(roundf(width), 52.0))
	UITheme.draw_glow(_canvas, rect, UITheme.DANGER, UITheme.R_MD, 2)
	var shape: PackedVector2Array = UITheme.rounded_rect(rect, UITheme.R_MD)
	_canvas.draw_colored_polygon(shape, UITheme.DANGER_BG)
	shape.append(shape[0])
	_canvas.draw_polyline(shape, _a(UITheme.DANGER, pulse), 2.0, true)
	var x: float = rect.position.x + (rect.size.x - text_w - 32.0) * 0.5
	UITheme.draw_warn_triangle(_canvas, Vector2(x + 10.0, rect.get_center().y), 20.0,
			_a(UITheme.DANGER, pulse))
	UITheme.draw_label(_canvas, Vector2(x + 32.0, rect.get_center().y + size * 0.36), text,
			_a(UITheme.TEXT, 0.6 + 0.4 * pulse), 3, size)


## What to do now, as keycaps and a few words, above the cluster. Fades between
## states rather than blinking - see ContextHints for the rules.
func _draw_hints(centre: Vector2) -> void:
	if _hints.is_empty() or _hints_alpha <= 0.01:
		return
	var a: float = _hints_alpha
	var main: Array = []
	var second: Array = []
	for hint in _hints:
		if int(hint.get("line", 1)) == 2:
			second.append(hint)
		elif main.size() < MAX_HINTS:
			main.append(hint)
	if main.is_empty():
		return
	var warn: bool = false
	for hint in main:
		if String(hint.get("level", "")) == "warn":
			warn = true
	var bold: bool = _escalation >= 1 and Settings.reduced_motion()
	var text_size: int = 19
	var face: Font = UITheme.font_bold() if bold else UITheme.font_semibold()
	var gap: float = 28.0
	var widths: Array[float] = []
	var total: float = 0.0
	for hint in main:
		var w: float = _hint_width(hint, text_size, face)
		widths.append(w)
		total += w
	total += gap * float(main.size() - 1)
	if warn:
		total += 18.0
	var height: float = 44.0
	var pill := Rect2(Vector2(roundf(centre.x - total * 0.5 - 20.0), roundf(centre.y - height * 0.5)),
			Vector2(roundf(total + 40.0), height))
	var shape: PackedVector2Array = UITheme.rounded_rect(pill, height * 0.5)
	# The escalation pulse: once, a soft accent swell around the chip.
	if _pulse_t > 0.0 and not Settings.reduced_motion():
		var p: float = sin((1.0 - _pulse_t / 0.9) * PI)
		UITheme.draw_glow(_canvas, pill, UITheme.ACCENT, height * 0.5, 2)
		var ring: PackedVector2Array = UITheme.rounded_rect(pill.grow(2.0 + 4.0 * p), height * 0.5 + 3.0)
		ring.append(ring[0])
		_canvas.draw_polyline(ring, _a(UITheme.ACCENT, 0.7 * p * a), 2.0, true)
	_canvas.draw_colored_polygon(shape, _a(UITheme.WARN_BG if warn else UITheme.BASE,
			(0.78 if warn else 0.62) * a))
	shape.append(shape[0])
	_canvas.draw_polyline(shape, _a(UITheme.WARN, 0.7 * a) if warn
			else _a(UITheme.STROKE_STRONG, a), 1.0, true)
	var x: float = pill.position.x + 20.0
	if warn:
		_canvas.draw_circle(Vector2(x + 4.0, centre.y), 3.5, _a(UITheme.WARN, a))
		x += 18.0
	var lit: bool = _pulse_t > 0.3 and _pulse_t < 0.75
	for i in main.size():
		_draw_hint_row(Vector2(x, centre.y), main[i], text_size, face,
				_a(UITheme.WARN if String(main[i].get("level", "")) == "warn" else UITheme.TEXT, 1.0),
				a, lit)
		x += widths[i] + gap
	# The escalation's second line: the full controls card is one key away.
	if not second.is_empty():
		var hint: Dictionary = second[0]
		var w: float = UITheme.key_hint_width(hint["keys"], hint["text"], UITheme.SIZE_KEY)
		UITheme.draw_key_hint(_canvas, Vector2(roundf(centre.x - w * 0.5), centre.y + height * 0.5 + 24.0),
				hint["keys"], hint["text"], UITheme.SIZE_KEY, UITheme.HUD_LABEL, a, true)


func _hint_width(hint: Dictionary, size: int, face: Font) -> float:
	var w: float = 0.0
	for k in hint.get("keys", []):
		w += UITheme.keycap_width(String(k), UITheme.SIZE_KEY) + 4.0
	var text: String = String(hint.get("text", ""))
	if not text.is_empty():
		if w > 0.0:
			w += 6.0
		w += face.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	return w


func _draw_hint_row(pos: Vector2, hint: Dictionary, size: int, face: Font, colour: Color,
		alpha: float, lit: bool) -> void:
	var x: float = pos.x
	var keys: Array = hint.get("keys", [])
	var cap_h: float = roundf(UITheme.KEYCAP_H * UITheme.SIZE_KEY / UITheme.SIZE_LABEL)
	for k in keys:
		x += UITheme.draw_keycap(_canvas, Vector2(x, pos.y - cap_h * 0.5), String(k),
				UITheme.SIZE_KEY, lit, alpha)
		x += 4.0
	var text: String = String(hint.get("text", ""))
	if text.is_empty():
		return
	if not keys.is_empty():
		x += 6.0
	UITheme.draw_text(_canvas, Vector2(x, pos.y + size * 0.36), text, size,
			_a(colour, alpha), HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, face)


# --------------------------------------------------------- flight cluster ---

## Half the gap between the speed and height blocks: room for the attitude
## ring when it shows, closed up when it does not.
func _half_gap() -> float:
	return lerpf(30.0, 66.0, float(_vis["ring"]))


## Speed, attitude, height: one cluster under the model.
func _draw_flight_cluster() -> void:
	var half: float = _half_gap()
	var system: String = Settings.units()
	var airborne: bool = not _sim.is_on_ground() and not _sim.has_crashed()
	var vs: float = _stall_speed()

	# ---- speed ----
	var sa: float = float(_vis["speed"]) * _dim
	if sa > 0.01:
		var right: float = _cx - half - 36.0
		var colour: Color = UITheme.TEXT
		if airborne and _airspeed < vs * 1.15:
			colour = UITheme.WARN
		if airborne and _airspeed < vs:
			colour = UITheme.DANGER
		_caps(Vector2(right, _B - 118.0), "Speed", _a(UITheme.HUD_LABEL, sa),
				UITheme.SIZE_CAPS, HORIZONTAL_ALIGNMENT_RIGHT)
		var speed: PackedStringArray = Settings.format_speed(maxf(_airspeed, 0.0), system)
		var w: float = UITheme.draw_numeral(_canvas, Vector2(right, _B - 50.0), speed[0],
				UITheme.SIZE_NUM_XL, _a(colour, sa), true, true)
		_text(Vector2(right - w - 8.0, _B - 50.0), speed[1], 20, _a(UITheme.HUD_LABEL, sa),
				HORIZONTAL_ALIGNMENT_RIGHT)
		var secondary: String = ("%.0f km/h" % (_airspeed * 3.6)) if system == "si" \
				else ("%.1f m/s" % _airspeed)
		_text(Vector2(right, _B - 18.0), secondary, UITheme.SIZE_BODY_S,
				_a(UITheme.HUD_LABEL, sa), HORIZONTAL_ALIGNMENT_RIGHT)
		_draw_speed_ribbon(_cx - half - 24.0, _B - 128.0, vs, sa)

	# ---- height ----
	var ha: float = float(_vis["height"]) * _dim
	if ha > 0.01:
		var left: float = _cx + half + 36.0
		var low: bool = _chips.has("low") and float(_chips["low"]["alpha"]) > 0.5
		_caps(Vector2(left, _B - 118.0), "Height", _a(UITheme.HUD_LABEL, ha))
		var height: PackedStringArray = Settings.format_height(maxf(_altitude, 0.0), system)
		var w: float = UITheme.draw_numeral(_canvas, Vector2(left, _B - 50.0), height[0],
				UITheme.SIZE_NUM_XL, _a(UITheme.DANGER if low else UITheme.TEXT, ha), false, true)
		_text(Vector2(left + w + 6.0, _B - 50.0), height[1], 20, _a(UITheme.HUD_LABEL, ha))
		# Climb rate, as an arrow and a figure.
		var climbing: bool = _climb > 0.15
		var sinking: bool = _climb < -0.15
		if climbing or sinking:
			var colour: Color = UITheme.GOOD if climbing else \
					(UITheme.WARN if _climb < -2.5 else UITheme.HUD_LABEL)
			UITheme.draw_arrow_glyph(_canvas, Vector2(left + 7.0, _B - 24.0),
					0 if climbing else 2, 13.0, _a(UITheme.SCRIM, 0.6 * ha), 4.0)
			UITheme.draw_arrow_glyph(_canvas, Vector2(left + 7.0, _B - 24.0),
					0 if climbing else 2, 13.0, _a(colour, ha))
			_text(Vector2(left + 20.0, _B - 18.0),
					Settings.format_climb(absf(_climb), system).trim_prefix("+"),
					UITheme.SIZE_BODY_S, _a(colour, ha))
		else:
			_text(Vector2(left, _B - 18.0), "level", UITheme.SIZE_BODY_S,
					_a(UITheme.HUD_LABEL, ha))
		_draw_vario_ribbon(_cx + half + 20.0, _B - 128.0, ha)


## Stall margin, on a vertical ribbon: 0 to 2.5x the stall speed, red below
## the stall, amber in the margin, a caret at the speed now.
func _draw_speed_ribbon(x: float, top: float, vs: float, a: float) -> void:
	var span: float = vs * RIBBON_SPAN
	var bottom: float = top + RIBBON_H
	var y_of := func(v: float) -> float:
		return bottom - clampf(v / span, 0.0, 1.0) * RIBBON_H
	_canvas.draw_rect(Rect2(x - 1.0, top - 1.0, 6.0, RIBBON_H + 2.0), _a(UITheme.SCRIM, 0.6 * a))
	var y_vs: float = y_of.call(vs)
	var y_margin: float = y_of.call(vs * 1.15)
	_canvas.draw_rect(Rect2(x, y_vs, 4.0, bottom - y_vs), _a(UITheme.DANGER, 0.85 * a))
	_canvas.draw_rect(Rect2(x, y_margin, 4.0, y_vs - y_margin), _a(UITheme.WARN, 0.85 * a))
	_canvas.draw_rect(Rect2(x, top, 4.0, y_margin - top), _a(UITheme.TEXT, 0.35 * a))
	# The caret sits on the ribbon's inner side, pointing back at it, so it
	# never collides with the SPEED label above the numeral.
	var y: float = roundf(y_of.call(_airspeed))
	var caret := PackedVector2Array([Vector2(x + 6.0, y), Vector2(x + 16.0, y - 6.0),
			Vector2(x + 16.0, y + 6.0)])
	var outline: PackedVector2Array = caret.duplicate()
	outline.append(caret[0])
	_canvas.draw_polyline(outline, _a(UITheme.SCRIM, 0.7 * a), 3.0, true)
	_canvas.draw_colored_polygon(caret, _a(UITheme.TEXT, a))


## Centre-zero ribbon beside the height: what the air is doing where there is
## lift, otherwise the aircraft's own climb and sink.
func _draw_vario_ribbon(x: float, top: float, a: float) -> void:
	var lift: bool = _sim.get_lift_enabled()
	var value: float = _vario_shown if lift else _climb
	var full: float = 4.0 if lift else 5.0
	var mid: float = top + RIBBON_H * 0.5
	_canvas.draw_rect(Rect2(x - 1.0, top - 1.0, 6.0, RIBBON_H + 2.0), _a(UITheme.SCRIM, 0.6 * a))
	_canvas.draw_rect(Rect2(x, top, 4.0, RIBBON_H), _a(UITheme.TEXT, 0.18 * a))
	var bar: float = clampf(value / full, -1.0, 1.0) * RIBBON_H * 0.5
	if bar > 0.5:
		_canvas.draw_rect(Rect2(x, mid - bar, 4.0, bar), _a(UITheme.GOOD, 0.9 * a))
	elif bar < -0.5:
		_canvas.draw_rect(Rect2(x, mid, 4.0, -bar), _a(UITheme.WARN, 0.9 * a))
	_canvas.draw_line(Vector2(x - 3.0, mid), Vector2(x + 7.0, mid), _a(UITheme.TEXT, 0.5 * a), 2.0)


## The attitude ring, on its own canvas so it fades as one piece.
func _draw_ring() -> void:
	if _sim == null or _ring_canvas.modulate.a <= 0.01:
		return
	var attitude: Vector3 = _sim.get_attitude_degrees()
	var colour: Color = _a(UITheme.TEXT, 0.45)
	if _flying() and _stall > Warnings.STALL_WARN:
		colour = UITheme.WARN
	if _flying() and _stall > Warnings.STALL_BANNER:
		colour = UITheme.DANGER
	# The sim's roll is positive right wing down, and in a right bank the
	# horizon on an attitude indicator rises to the RIGHT (the world turns the
	# other way to the aeroplane). draw_attitude_ring tilts its horizon down to
	# the right for a positive angle, so the roll goes in negated.
	UITheme.draw_attitude_ring(_ring_canvas, Vector2(_cx, _B - 74.0), 66.0,
			-attitude.x, attitude.y, colour)


## Throttle and battery. The bar is what the MOTOR is doing, not the stick: on
## a wreck it once read 90 % in confident cyan next to an rpm of zero.
func _draw_power_column(right: float) -> void:
	var ta: float = float(_vis["throttle"]) * _dim
	if ta > 0.01:
		var dead: bool = _sim.has_crashed() or _sim.get_rpm() < 1.0
		var shown: float = 0.0 if _sim.has_crashed() else clampf(_throttle, 0.0, 1.0)
		_caps(Vector2(right, _B - 118.0), "Thr", _a(UITheme.HUD_LABEL, ta),
				UITheme.SIZE_CAPS, HORIZONTAL_ALIGNMENT_RIGHT)
		var value: String = "%d%%" % roundi(shown * 100.0)
		UITheme.draw_numeral(_canvas, Vector2(right, _B - 74.0), value, UITheme.SIZE_NUM_M,
				_a(UITheme.HUD_LABEL if dead and shown > 0.01 else UITheme.TEXT, ta), true, true)
		# Five segments, lit from the left.
		var seg_w: float = 11.0
		var x0: float = right - (seg_w * 5.0 + 2.0 * 4.0)
		var lit: int = roundi(shown * 5.0)
		if shown > 0.02:
			lit = maxi(lit, 1)
		for i in 5:
			var r := Rect2(x0 + float(i) * (seg_w + 2.0), _B - 60.0, seg_w, 6.0)
			_canvas.draw_rect(r.grow(1.0), _a(UITheme.SCRIM, 0.45 * ta))
			var c: Color = _a(UITheme.TEXT, 0.18)
			if i < lit:
				c = UITheme.DANGER if dead else UITheme.ACCENT
			_canvas.draw_rect(r, _a(c, ta))

	var ba: float = float(_vis["battery"]) * _dim
	if ba > 0.01:
		var charge: float = _sim.get_battery_charge()
		var colour: Color = UITheme.GOOD
		if charge < 0.35: colour = UITheme.WARN
		if charge < 0.15: colour = UITheme.DANGER
		var blink: float = 1.0
		if charge < 0.15 and not Settings.reduced_motion():
			blink = 0.35 if fmod(_alert_phase, 1.0) > 0.5 else 1.0
		var text: String = "%d%%" % roundi(charge * 100.0)
		var tw: float = _text_w(text, UITheme.SIZE_BODY_S)
		_text(Vector2(right, _B - 18.0), text, UITheme.SIZE_BODY_S, _a(colour, ba),
				HORIZONTAL_ALIGNMENT_RIGHT)
		UITheme.draw_battery(_canvas, Rect2(right - tw - 8.0 - 34.0, _B - 31.0, 30.0, 14.0),
				charge, _a(colour, ba * blink), _a(UITheme.HUD_LABEL, ba))


## Lift, where there is any: what the air is doing, and where it comes from.
## A pilot who can tell a thermal from a hillside knows whether to circle or to
## beat along the ridge.
func _draw_lift(left: float) -> void:
	var a: float = float(_vis["lift"]) * _dim
	if a <= 0.01:
		return
	var colour: Color = UITheme.GOOD if _vario_shown > 0.0 else UITheme.WARN
	_caps(Vector2(left, _B - 118.0), "Vario", _a(UITheme.HUD_LABEL, a))
	var value: String = ("%+.0f" % (_vario_shown * 196.8504)) if Settings.units() == "imperial" \
			else ("%+.1f" % _vario_shown)
	UITheme.draw_numeral(_canvas, Vector2(left, _B - 74.0), value, UITheme.SIZE_NUM_M,
			_a(colour, a), false, true)
	var source: String = ""
	var thermal: float = _sim.get_thermal_lift_mps()
	var slope: float = _sim.get_slope_lift_mps()
	if absf(thermal) > absf(slope) and absf(thermal) > 0.25:
		source = "Thermal"
	elif absf(slope) > 0.25:
		source = "Slope"
	if not source.is_empty():
		_caps(Vector2(left, _B - 18.0), source, _a(UITheme.ACCENT, a))


## The transmitter, mirrored: two gates at gimbal proportions, so a glance at
## the screen answers the same question as a glance at the pilot's thumbs.
func _draw_sticks(origin: Vector2) -> void:
	var a: float = float(_vis["gates"]) * _dim
	if a <= 0.01:
		return
	var connected: bool = _input != null and _input.is_connected()
	var caption: String = "Keyboard"
	if connected:
		caption = _input.get_device_name().substr(0, 22)
	_caps(Vector2(origin.x, _B - 144.0), caption, _a(UITheme.HUD_LABEL, a))
	if _input != null and _input.raw_mode:
		_caps(Vector2(origin.x + 208.0, _B - 144.0), "Raw", _a(UITheme.ACCENT, a),
				UITheme.SIZE_CAPS, HORIZONTAL_ALIGNMENT_RIGHT)

	var channels: PackedFloat64Array = _input.get_channels() if _input != null \
			else PackedFloat64Array([0, 0, 0, 0, 0, 0])
	var aileron: float = channels[0]
	var elevator: float = channels[1]
	var throttle: float = channels[2]
	var rudder: float = channels[3]
	var left := Rect2(Vector2(origin.x, _B - 132.0), Vector2(96, 96))
	var right := Rect2(Vector2(origin.x + 112.0, _B - 132.0), Vector2(96, 96))
	if mode_two:
		# Left gimbal: throttle up, rudder across. Throttle is unipolar, so it
		# is mapped onto the gate the way a real stick sits.
		_draw_gate(left, rudder, throttle * 2.0 - 1.0, a, true)
		_draw_gate(right, aileron, -elevator, a, false)
		_caps(Vector2(left.position.x, _B - 12.0), "Thr·Rud", _a(UITheme.HUD_LABEL, a))
		_caps(Vector2(right.position.x, _B - 12.0), "Ele·Ail", _a(UITheme.HUD_LABEL, a))
	else:
		_draw_gate(left, rudder, -elevator, a, false)
		_draw_gate(right, aileron, throttle * 2.0 - 1.0, a, true)
		_caps(Vector2(left.position.x, _B - 12.0), "Ele·Rud", _a(UITheme.HUD_LABEL, a))
		_caps(Vector2(right.position.x, _B - 12.0), "Thr·Ail", _a(UITheme.HUD_LABEL, a))


func _draw_gate(rect: Rect2, x: float, y: float, a: float, detent: bool) -> void:
	var shape: PackedVector2Array = UITheme.rounded_rect(rect, UITheme.R_SM)
	_canvas.draw_colored_polygon(shape, _a(UITheme.SCRIM, 0.35 * a))
	shape.append(shape[0])
	_canvas.draw_polyline(shape, _a(UITheme.TEXT, 0.30 * a), 1.5, true)
	var centre: Vector2 = rect.get_center()
	_canvas.draw_line(Vector2(rect.position.x + 6.0, centre.y), Vector2(rect.end.x - 6.0, centre.y),
			_a(UITheme.TEXT, 0.10 * a), 1.0)
	_canvas.draw_line(Vector2(centre.x, rect.position.y + 6.0), Vector2(centre.x, rect.end.y - 6.0),
			_a(UITheme.TEXT, 0.10 * a), 1.0)
	if detent:
		_canvas.draw_line(Vector2(rect.position.x, centre.y), Vector2(rect.position.x + 6.0, centre.y),
				_a(UITheme.TEXT, 0.5 * a), 2.0)
	var reach: Vector2 = rect.size * 0.5 - Vector2(9, 9)
	var knob: Vector2 = centre + Vector2(clampf(x, -1.0, 1.0), -clampf(y, -1.0, 1.0)) * reach
	_canvas.draw_line(centre, knob, _a(UITheme.ACCENT, 0.35 * a), 2.0, true)
	_canvas.draw_circle(knob, 9.0, _a(UITheme.SCRIM, 0.7 * a))
	_canvas.draw_circle(knob, 7.0, _a(UITheme.ACCENT, a))


## Engineering numbers, for tuners: Detailed, or F2. A glass panel bottom right.
func _draw_engineering(anchor: Vector2) -> void:
	var a: float = float(_vis["engineering"])
	if a <= 0.01:
		return
	var flying: bool = _flying()
	var stall_colour: Color = UITheme.TEXT
	if flying and _stall > Warnings.STALL_WARN: stall_colour = UITheme.WARN
	if flying and _stall > Warnings.STALL_BANNER: stall_colour = UITheme.DANGER
	var field: PackedStringArray = Settings.format_height(absf(_field_altitude), Settings.units())
	var rows: Array = [
		# Parked in a breeze the relative wind comes from behind the wing, so
		# the angle of attack is near 180 degrees: correct and useless.
		["AoA", ("%+.1f°" % _alpha) if flying else "--", stall_colour],
		["Stalled", ("%d%%" % roundi(_stall * 100.0)) if flying else "--", stall_colour],
		["RPM", "%d" % roundi(_sim.get_rpm()), UITheme.TEXT],
		["Thrust", "%.1f N" % _sim.get_thrust_n(), UITheme.TEXT],
		["Field", "%s%s %s" % ["-" if _field_altitude < -0.5 else "+", field[0], field[1]],
				UITheme.TEXT],
		["Frame", "%d fps · %d Hz" % [roundi(_fps), _sim.physics_rate_hz], UITheme.TEXT_DIM],
	]
	var dropped: int = _sim.get_dropped_steps()
	if dropped > 0:
		rows.append(["Dropped", "%d steps" % dropped, UITheme.WARN])
	var pitch: float = 26.0
	var w: float = 232.0
	var h: float = 40.0 + pitch * float(rows.size())
	var card := Rect2(Vector2(anchor.x - w, anchor.y - h), Vector2(w, h))
	var shape: PackedVector2Array = UITheme.rounded_rect(card, UITheme.R_MD)
	_canvas.draw_colored_polygon(shape, _a(UITheme.BASE, 0.62 * a))
	shape.append(shape[0])
	_canvas.draw_polyline(shape, _a(UITheme.STROKE_STRONG, a), 1.0, true)
	UITheme.draw_label(_canvas, card.position + Vector2(16, 26), "Flight data",
			_a(UITheme.TEXT_DIM, a))
	var y: float = card.position.y + 52.0
	for row in rows:
		UITheme.draw_text(_canvas, Vector2(card.position.x + 16.0, y), row[0], UITheme.SIZE_BODY_S,
				_a(UITheme.TEXT_DIM, a), HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UITheme.font())
		var value: String = row[1]
		UITheme.draw_text(_canvas, Vector2(card.end.x - 16.0 - _text_w(value, UITheme.SIZE_BODY_S),
				y), value, UITheme.SIZE_BODY_S, _a(row[2], a), HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				false, UITheme.font_semibold())
		y += pitch


## Where is it? A beginner loses the model constantly - against the trees, in
## the sun, or simply out of frame. When it is small on screen it gets four
## corner brackets and its distance; when it is out of frame, a chevron on the
## edge points to it, kept clear of the top band and the cluster. Off in the
## FPV view, and when the setting is off.
func _draw_locator() -> void:
	if not bool(Settings.get_value("interface/locator")) or _sim.has_crashed():
		return
	if _view == "FPV":
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	var at: Vector3 = _sim.global_position
	var distance: float = camera.global_position.distance_to(at)
	if distance < 0.5:
		return
	var size: Vector2 = _canvas.size
	var pulse: float = 1.0 if Settings.reduced_motion() \
			else 0.9 + 0.1 * sin(_alert_phase * TAU / 1.6)
	var colour: Color = _a(UITheme.ACCENT, pulse)
	var parts: PackedStringArray = Settings.format_height(distance, Settings.units())
	var label: String = "%s %s" % [parts[0], parts[1]]
	var behind: bool = camera.is_position_behind(at)
	var point: Vector2 = camera.unproject_position(at)
	var margin: float = 48.0
	var inside: bool = not behind and point.x > margin and point.x < size.x - margin \
			and point.y > margin and point.y < size.y - margin
	if inside:
		var focal: float = size.y * 0.5 / tan(deg_to_rad(camera.fov) * 0.5)
		var span_px: float = _sim.get_wingspan_m() / distance * focal
		if span_px > 46.0:
			return
		var half: float = maxf(span_px * 0.5, 10.0) + 12.0
		var arm: float = 10.0
		for pass_i in 2:
			var c_line: Color = _a(UITheme.SCRIM, 0.55) if pass_i == 0 else colour
			var wdt: float = 4.0 if pass_i == 0 else 2.0
			for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				var c: Vector2 = (point + corner * half).round()
				_canvas.draw_polyline(PackedVector2Array([c - Vector2(corner.x * arm, 0), c,
						c - Vector2(0, corner.y * arm)]), c_line, wdt)
		_text(point + Vector2(0, half + 22.0), label, UITheme.SIZE_BODY_S, colour,
				HORIZONTAL_ALIGNMENT_CENTER)
		return
	# Out of frame: a chevron on the edge of the clear area, on the line from
	# the centre towards it.
	var area := Rect2(Vector2(72.0, 150.0), Vector2(size.x - 144.0, _B - 170.0 - 150.0))
	var centre: Vector2 = area.get_center()
	var direction: Vector2 = point - centre
	if behind:
		direction = -direction
	if direction.length() < 1.0:
		direction = Vector2(0, 1)
	direction = direction.normalized()
	var half_box: Vector2 = area.size * 0.5
	var reach: float = minf(half_box.x / maxf(absf(direction.x), 0.001),
			half_box.y / maxf(absf(direction.y), 0.001))
	var tip: Vector2 = centre + direction * reach
	var n := Vector2(-direction.y, direction.x)
	var chevron := PackedVector2Array([tip, tip - direction * 28.0 + n * 11.0,
			tip - direction * 18.0, tip - direction * 28.0 - n * 11.0])
	var outline: PackedVector2Array = chevron.duplicate()
	outline.append(chevron[0])
	_canvas.draw_polyline(outline, _a(UITheme.SCRIM, 0.7), 4.0, true)
	_canvas.draw_colored_polygon(chevron, colour)
	var text_at: Vector2 = tip - direction * 64.0
	_text(text_at + Vector2(0, 6.0), label, UITheme.SIZE_BODY_S, colour,
			HORIZONTAL_ALIGNMENT_CENTER)


## The per-section drawer. This is the wall of numbers, and it is behind a key
## for exactly that reason: it is a development tool, not part of flying.
func _draw_diagnostics(origin: Vector2) -> void:
	var count: int = _sim.get_section_count()
	var row_height: float = 18.0
	var width: float = 320.0
	var height: float = 100.0 + float(count) * row_height
	var card := Rect2(origin, Vector2(width, height))
	var shape: PackedVector2Array = UITheme.rounded_rect(card, UITheme.R_MD)
	_canvas.draw_colored_polygon(shape, _a(UITheme.BASE, 0.78))
	shape.append(shape[0])
	_canvas.draw_polyline(shape, UITheme.STROKE_STRONG, 1.0, true)

	UITheme.draw_label(_canvas, origin + Vector2(16, 26), "Aerodynamic sections")
	UITheme.draw_rule(_canvas, origin + Vector2(16, 36), width - 32.0)
	UITheme.draw_label(_canvas, origin + Vector2(16, 56), "Section", UITheme.TEXT_FAINT)
	UITheme.draw_label(_canvas, origin + Vector2(176, 56), "AoA", UITheme.TEXT_FAINT)
	UITheme.draw_label(_canvas, origin + Vector2(240, 56), "Sep.", UITheme.TEXT_FAINT)

	for i in count:
		var y: float = origin.y + 76.0 + float(i) * row_height
		var separation: float = _sim.get_section_separation(i)
		var colour: Color = UITheme.TEXT_DIM
		if separation > 0.5: colour = UITheme.DANGER
		elif separation > 0.05: colour = UITheme.WARN
		UITheme.draw_text(_canvas, Vector2(origin.x + 16.0, y), _sim.get_section_name(i),
				16, colour)
		UITheme.draw_text(_canvas, Vector2(origin.x + 176.0, y),
				"%+5.1f" % _sim.get_section_alpha_degrees(i), 16, colour)
		UITheme.draw_track(_canvas, Rect2(Vector2(origin.x + 240.0, y - 7.0), Vector2(60, 3)),
				separation, colour)

	var footer: float = origin.y + 80.0 + float(count) * row_height
	UITheme.draw_rule(_canvas, Vector2(origin.x + 16.0, footer), width - 32.0)
	UITheme.draw_text(_canvas, Vector2(origin.x + 16.0, footer + 20.0),
			"lift %.1f N   drag %.1f N   L/D %.1f"
			% [_sim.get_total_lift_n(), _sim.get_total_drag_n(),
			   _sim.get_total_lift_n() / maxf(_sim.get_total_drag_n(), 0.01)],
			16, UITheme.TEXT_DIM)
