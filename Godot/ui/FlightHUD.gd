# OpenRC Simulator - the flight overlay.
#
# Laid out around one question: what does a pilot actually look at, and when?
#
#   - Almost never: exact numbers. Those live in the diagnostic drawer (F2).
#   - Constantly: their own thumbs. Hence the transmitter gates, bottom left, at
#     the proportions of the gimbals on a real radio - the single element that
#     makes this read as an RC simulator rather than a flight game.
#   - At a glance: speed, height, power. Big figures, one accent colour, nothing
#     else competing.
#   - Only when it matters: the stall. It arrives as a state, not as a number
#     that the pilot is expected to be watching.
#
# Everything is drawn rather than assembled from controls, because every element
# here is a gauge rather than a widget. Values are eased towards their targets
# so a 240 Hz simulation does not produce a flickering readout.
extends CanvasLayer

@export var simulation_path: NodePath
@export var input_path: NodePath
## Mode 2: throttle and rudder on the left gimbal, elevator and aileron on the
## right. The world default outside Japan.
@export var mode_two: bool = true

var _sim: RCSimulationNode
var _input: RCInputNode
var _canvas: Control
var _diagnostics: bool = false

# Eased display values. The simulation runs at 240 Hz; the eye does not.
var _airspeed: float = 0.0
var _altitude: float = 0.0
var _climb: float = 0.0
var _throttle: float = 0.0
var _alpha: float = 0.0
var _stall: float = 0.0
var _fps: float = 0.0
var _fps_accumulator: float = 0.0
var _fps_frames: int = 0
var _alert_phase: float = 0.0
var _vario_shown: float = 0.0


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


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			visible = not visible
		elif event.keycode == KEY_F2:
			_diagnostics = not _diagnostics


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
	_altitude = lerpf(_altitude, _sim.get_altitude_m(), steady)
	_climb = lerpf(_climb, _sim.get_velocity_world().y, steady)
	_alpha = lerpf(_alpha, _sim.get_alpha_degrees(), steady)
	_stall = lerpf(_stall, _sim.get_stalled_fraction(), quick)
	_throttle = lerpf(_throttle, _sim.get_channels()[2], quick)

	_alert_phase += delta
	_canvas.queue_redraw()


# ---------------------------------------------------------------- drawing ---

func _draw_hud() -> void:
	if _sim == null:
		return
	var size: Vector2 = _canvas.size

	_draw_identity(Vector2(UITheme.S5, UITheme.S5))
	_draw_performance(Vector2(size.x - UITheme.S5, UITheme.S5))
	_draw_speed(Vector2(UITheme.S5, size.y * 0.42))
	_draw_altitude(Vector2(size.x - UITheme.S5 - 168.0, size.y * 0.42))
	var strip: float = size.y - UITheme.S5 - 172.0
	_draw_transmitter(Vector2(UITheme.S5, strip))
	_draw_power(Vector2(size.x - UITheme.S5 - 236.0, strip))
	_draw_attitude_block(Vector2(size.x * 0.5, strip + 86.0))
	_draw_alerts(Vector2(size.x * 0.5, size.y * 0.13))
	_draw_variometer(Vector2(size.x - 118.0, size.y * 0.5))
	_draw_hints(Vector2(size.x * 0.5, size.y - UITheme.S4))

	if _diagnostics:
		# Left side: the tuning drawer owns the right edge, and two drawers
		# fighting for the same corner is worse than either of them.
		_draw_diagnostics(Vector2(UITheme.S5, UITheme.S5 + 74.0))


## Aircraft name and what it is doing. Quiet, top left, where a title goes.
func _draw_identity(origin: Vector2) -> void:
	UITheme.draw_label(_canvas, origin + Vector2(0, 10), "aircraft")
	UITheme.draw_text(_canvas, origin + Vector2(0, 34), _sim.get_aircraft_name(),
					  UITheme.SIZE_VALUE, UITheme.TEXT)

	var state: String = "on ground"
	var colour: Color = UITheme.TEXT_DIM
	if _sim.has_crashed():
		state = "crashed"
		colour = UITheme.DANGER
	elif not _sim.is_on_ground():
		state = "airborne"
		colour = UITheme.ACCENT
	UITheme.draw_label(_canvas, origin + Vector2(0, 52), state, colour, 1.6)


## Frame and step rate. Dropped steps are the number that matters: they mean the
## machine is not sustaining the physics rate.
func _draw_performance(anchor: Vector2) -> void:
	var dropped: int = _sim.get_dropped_steps()
	var text: String = "%d fps   %d Hz" % [roundi(_fps), _sim.physics_rate_hz]
	var width: float = UITheme.text_width(text, UITheme.SIZE_LABEL)
	UITheme.draw_text(_canvas, anchor + Vector2(-width, 14), text,
					  UITheme.SIZE_LABEL, UITheme.TEXT_FAINT)
	if dropped > 0:
		var warning: String = "%d dropped" % dropped
		UITheme.draw_text(_canvas,
			anchor + Vector2(-UITheme.text_width(warning, UITheme.SIZE_LABEL), 32),
			warning, UITheme.SIZE_LABEL, UITheme.WARN)


## Airspeed. The number a trainee should be flying by.
func _draw_speed(origin: Vector2) -> void:
	var rect := Rect2(origin, Vector2(168, 104))
	UITheme.draw_panel(_canvas, rect)

	UITheme.draw_label(_canvas, origin + Vector2(UITheme.S4, 22), "airspeed")
	UITheme.draw_text(_canvas, origin + Vector2(UITheme.S4, 62),
					  "%.1f" % _airspeed, UITheme.SIZE_LARGE, UITheme.TEXT)
	UITheme.draw_text(_canvas, origin + Vector2(UITheme.S4 + 62, 62), "m/s",
					  UITheme.SIZE_LABEL, UITheme.TEXT_DIM)

	# Stall margin as a track: how much of the usable band is left below.
	var stall_speed: float = 7.9
	var fraction: float = clampf((_airspeed - stall_speed) / 12.0, 0.0, 1.0)
	var colour: Color = UITheme.ACCENT
	if _airspeed < stall_speed * 1.15:
		colour = UITheme.WARN
	if _airspeed < stall_speed:
		colour = UITheme.DANGER
	UITheme.draw_track(_canvas, Rect2(origin + Vector2(UITheme.S4, 78),
									  Vector2(136, 3)), fraction, colour)
	UITheme.draw_text(_canvas, origin + Vector2(UITheme.S4, 96),
					  "%.0f km/h" % (_airspeed * 3.6),
					  UITheme.SIZE_LABEL, UITheme.TEXT_FAINT)


func _draw_altitude(origin: Vector2) -> void:
	var rect := Rect2(origin, Vector2(168, 104))
	UITheme.draw_panel(_canvas, rect)

	UITheme.draw_label(_canvas, origin + Vector2(UITheme.S4, 22), "height")
	UITheme.draw_text(_canvas, origin + Vector2(UITheme.S4, 62),
					  "%.0f" % maxf(_altitude, 0.0), UITheme.SIZE_LARGE, UITheme.TEXT)
	UITheme.draw_text(_canvas, origin + Vector2(UITheme.S4 + 46, 62), "m",
					  UITheme.SIZE_LABEL, UITheme.TEXT_DIM)

	var climbing: bool = _climb > 0.15
	var sinking: bool = _climb < -0.15
	var arrow: String = "^" if climbing else ("v" if sinking else "-")
	var colour: Color = UITheme.GOOD if climbing else \
		(UITheme.WARN if _climb < -2.5 else UITheme.TEXT_DIM)
	UITheme.draw_text(_canvas, origin + Vector2(UITheme.S4, 96),
					  "%s %+.1f m/s" % [arrow, _climb],
					  UITheme.SIZE_LABEL, colour)


## The transmitter, mirrored. Two gates at gimbal proportions, so a glance at
## the screen answers the same question as a glance at the pilot's thumbs.
func _draw_transmitter(origin: Vector2) -> void:
	var rect := Rect2(origin, Vector2(266, 172))
	UITheme.draw_panel(_canvas, rect)

	var connected: bool = _input != null and _input.is_connected()
	UITheme.draw_label(_canvas, origin + Vector2(UITheme.S4, 22), "transmitter")
	var name_text: String = _input.get_device_name() if connected else "none connected"
	UITheme.draw_text(_canvas, origin + Vector2(UITheme.S4, 40),
					  name_text.substr(0, 30), UITheme.SIZE_LABEL,
					  UITheme.TEXT_DIM if connected else UITheme.WARN)

	var channels: PackedFloat64Array = _input.get_channels() if _input != null \
		else PackedFloat64Array([0, 0, 0, 0, 0, 0])
	var aileron: float = channels[0]
	var elevator: float = channels[1]
	var throttle: float = channels[2]
	var rudder: float = channels[3]

	var gate := Vector2(96, 96)
	var left_origin: Vector2 = origin + Vector2(UITheme.S4, 54)
	var right_origin: Vector2 = origin + Vector2(UITheme.S4 + 106, 54)

	if mode_two:
		# Left gimbal: throttle up, rudder across. Throttle is unipolar, so it
		# is mapped onto the lower half of the gate the way a real stick sits.
		UITheme.draw_stick_gate(_canvas, Rect2(left_origin, gate),
								rudder, throttle * 2.0 - 1.0)
		UITheme.draw_stick_gate(_canvas, Rect2(right_origin, gate), aileron, elevator)
		UITheme.draw_label(_canvas, left_origin + Vector2(0, 112), "thr / rud")
		UITheme.draw_label(_canvas, right_origin + Vector2(0, 112), "ele / ail")
	else:
		UITheme.draw_stick_gate(_canvas, Rect2(left_origin, gate),
								rudder, elevator)
		UITheme.draw_stick_gate(_canvas, Rect2(right_origin, gate),
								aileron, throttle * 2.0 - 1.0)
		UITheme.draw_label(_canvas, left_origin + Vector2(0, 112), "ele / rud")
		UITheme.draw_label(_canvas, right_origin + Vector2(0, 112), "thr / ail")

	if _input != null and _input.raw_mode:
		UITheme.draw_label(_canvas, origin + Vector2(228, 22), "raw", UITheme.ACCENT)


## Power, as one arc plus two supporting figures. The battery is the number a
## pilot has to plan around; a LiPo holds up and then falls off a cliff.
func _draw_power(origin: Vector2) -> void:
	var rect := Rect2(origin, Vector2(236, 172))
	UITheme.draw_panel(_canvas, rect)
	UITheme.draw_label(_canvas, origin + Vector2(UITheme.S4, 22), "power")

	var centre: Vector2 = origin + Vector2(76, 96)
	UITheme.draw_arc_gauge(_canvas, centre, 42.0, 260.0, _throttle, UITheme.ACCENT, 4.0)
	var throttle_text: String = "%d" % roundi(_throttle * 100.0)
	UITheme.draw_text(_canvas,
		centre + Vector2(-UITheme.text_width(throttle_text, UITheme.SIZE_LARGE) * 0.5, 8),
		throttle_text, UITheme.SIZE_LARGE, UITheme.TEXT)
	UITheme.draw_label(_canvas, centre + Vector2(-8, 26), "%")

	var charge: float = _sim.get_battery_charge()
	var charge_colour: Color = UITheme.GOOD
	if charge < 0.35: charge_colour = UITheme.WARN
	if charge < 0.15: charge_colour = UITheme.DANGER

	var column: Vector2 = origin + Vector2(140, 54)
	UITheme.draw_label(_canvas, column, "battery")
	UITheme.draw_track(_canvas, Rect2(column + Vector2(0, 8), Vector2(78, 4)),
					   charge, charge_colour)
	UITheme.draw_text(_canvas, column + Vector2(0, 30), "%d%%" % roundi(charge * 100.0),
					  UITheme.SIZE_VALUE, charge_colour)

	UITheme.draw_label(_canvas, column + Vector2(0, 54), "rpm")
	UITheme.draw_text(_canvas, column + Vector2(0, 74), "%d" % roundi(_sim.get_rpm()),
					  UITheme.SIZE_BODY, UITheme.TEXT_DIM)
	UITheme.draw_label(_canvas, column + Vector2(0, 92), "thrust")
	UITheme.draw_text(_canvas, column + Vector2(0, 112), "%.1f N" % _sim.get_thrust_n(),
					  UITheme.SIZE_BODY, UITheme.TEXT_DIM)


## Attitude, angle of attack and how much of the wing has let go. Centre bottom,
## because when it matters it matters more than anything else on the screen.
func _draw_attitude_block(centre: Vector2) -> void:
	var attitude: Vector3 = _sim.get_attitude_degrees()
	UITheme.draw_attitude(_canvas, centre, 46.0, attitude.x, attitude.y)

	var flying: bool = not _sim.is_on_ground() or _sim.get_airspeed_mps() > 6.0
	var stall_colour: Color = UITheme.ACCENT
	if flying and _stall > 0.06: stall_colour = UITheme.WARN
	if flying and _stall > 0.30: stall_colour = UITheme.DANGER

	var left: Vector2 = centre + Vector2(-206, -10)
	UITheme.draw_label(_canvas, left, "angle of attack",
					   UITheme.TEXT_FAINT, 1.8)
	# Parked in a breeze the relative wind comes from behind the wing, so the
	# angle of attack is near 180 degrees and technically correct but useless.
	UITheme.draw_text(_canvas, left + Vector2(0, 22),
					  ("%+.1f deg" % _alpha) if flying else "--",
					  UITheme.SIZE_VALUE, stall_colour)

	var right: Vector2 = centre + Vector2(78, -10)
	UITheme.draw_label(_canvas, right, "wing separated", UITheme.TEXT_FAINT, 1.8)
	UITheme.draw_text(_canvas, right + Vector2(0, 22),
					  ("%d%%" % roundi(_stall * 100.0)) if flying else "--",
					  UITheme.SIZE_VALUE, stall_colour)
	UITheme.draw_track(_canvas, Rect2(right + Vector2(0, 30), Vector2(96, 3)),
					   _stall if flying else 0.0, stall_colour)


## The variometer.
##
## What the AIR is doing, not what the aeroplane is doing. A pilot flying a
## glider reads this constantly: positive means the air here is going up and it
## is worth turning, negative means leave. It is drawn as a column rather than a
## number because the thing that matters is the trend - whether the needle is
## rising as you turn - and a number changing four times a second cannot show
## that.
##
## Hidden when the air is dead still, so a powered circuit is not cluttered by
## an instrument that has nothing to say.
func _draw_variometer(centre: Vector2) -> void:
	if _sim == null or not _sim.get_lift_enabled():
		return

	var air: float = _sim.get_air_vertical_speed_mps()
	var thermal: float = _sim.get_thermal_lift_mps()
	var slope: float = _sim.get_slope_lift_mps()
	if absf(air) < 0.05 and absf(_vario_shown) < 0.05:
		return

	# Smoothed, hard. A real variometer lags because the air is turbulent and an
	# instantaneous reading is unreadable; so is this one without it.
	_vario_shown = lerpf(_vario_shown, air, 0.08)

	var height: float = 150.0
	var width: float = 13.0
	var rect := Rect2(centre - Vector2(width * 0.5, height * 0.5), Vector2(width, height))
	UITheme.draw_panel(_canvas, rect.grow(7.0), UITheme.PANEL, UITheme.STROKE)

	# Zero line, and the scale it is measured against.
	var middle: float = centre.y
	UITheme.draw_rule(_canvas, Vector2(rect.position.x - 4.0, middle), width + 8.0,
			UITheme.STROKE_STRONG)

	var full_scale: float = 4.0
	var fraction: float = clampf(_vario_shown / full_scale, -1.0, 1.0)
	var bar: float = fraction * (height * 0.5)
	var colour: Color = UITheme.GOOD if _vario_shown > 0.0 else UITheme.WARN
	if _vario_shown > 0.0:
		_canvas.draw_rect(Rect2(rect.position.x, middle - bar, width, bar), colour)
	else:
		_canvas.draw_rect(Rect2(rect.position.x, middle, width, -bar), colour)

	UITheme.draw_text(_canvas, Vector2(centre.x, rect.position.y - 16.0),
			"%+.1f" % _vario_shown, UITheme.SIZE_BODY, colour,
			HORIZONTAL_ALIGNMENT_CENTER)
	UITheme.draw_label(_canvas, Vector2(centre.x - 12.0, rect.end.y + 20.0),
			"VARIO", UITheme.TEXT_FAINT, 2.0, UITheme.SIZE_MICRO)

	# Where it is coming from. A pilot who can tell a thermal from a hillside
	# knows whether to circle or to beat along the ridge.
	var source: String = ""
	if absf(thermal) > absf(slope) and absf(thermal) > 0.25:
		source = "THERMAL"
	elif absf(slope) > 0.25:
		source = "SLOPE"
	if not source.is_empty():
		UITheme.draw_label(_canvas, Vector2(centre.x - 22.0, rect.end.y + 36.0),
				source, UITheme.ACCENT, 1.8, UITheme.SIZE_MICRO)


## One banner slot, for the one thing that needs saying. Never two at once.
func _draw_alerts(centre: Vector2) -> void:
	var text: String = ""
	var colour: Color = UITheme.WARN

	# Parked in a breeze, the wing is technically separated - the relative wind
	# is coming from behind it. Shouting STALL at a stationary model on the
	# ground is noise, and noise is how a warning stops being read.
	var flying: bool = not _sim.is_on_ground() or _sim.get_airspeed_mps() > 6.0

	if _sim.has_crashed():
		text = "CRASHED   -   PRESS R TO RESET"
		colour = UITheme.DANGER
	elif flying and _stall > 0.30:
		text = "STALL"
		colour = UITheme.DANGER
	elif flying and _stall > 0.06:
		text = "APPROACHING THE STALL"
	elif _input != null and not _input.is_connected():
		text = "NO TRANSMITTER   -   PRESS F3 TO SET ONE UP"
		colour = UITheme.WARN
	elif _input != null and _input.is_connected() \
			and not _input.get_profile_problem().is_empty():
		var problem: String = _input.get_profile_problem()
		# A mis-bound throttle outranks the arming prompt: the prompt would tell
		# the pilot to close a stick that is not the throttle.
		# The silent-radio case gets its own words: sending the pilot to the
		# wizard would be sending them somewhere that cannot help.
		if problem.find("not sending anything") >= 0:
			text = "TRANSMITTER SENDING NOTHING   -   IS THE RADIO ON?"
		else:
			text = "TRANSMITTER BINDING LOOKS WRONG   -   PRESS F3"
		colour = UITheme.DANGER
	elif _input != null and _input.is_connected() and not _input.is_throttle_armed():
		# The interlock holds the motor stopped until the stick has been seen
		# closed. Without this line a pilot reads it as a dead throttle.
		text = "THROTTLE SAFE   -   CLOSE THE THROTTLE STICK TO ARM"
		colour = UITheme.WARN
	else:
		return

	# A slow pulse, so it reads as live without becoming a strobe.
	var pulse: float = 0.72 + 0.28 * sin(_alert_phase * 4.0)
	# Measured with the letterspacing the banner is actually drawn with; using
	# the unspaced width left the last words hanging outside the panel.
	var width: float = UITheme.label_width(text, 1.8, UITheme.SIZE_BODY) + UITheme.S5 * 2.0
	var rect := Rect2(centre - Vector2(width * 0.5, 18), Vector2(width, 36))
	UITheme.draw_panel(_canvas, rect, Color(colour.r * 0.22, colour.g * 0.14,
										   colour.b * 0.14, 0.88),
					   Color(colour.r, colour.g, colour.b, 0.45 * pulse), 6.0)
	UITheme.draw_label(_canvas, rect.position + Vector2(UITheme.S5, 23), text,
					   Color(colour.r, colour.g, colour.b, pulse), 1.8, UITheme.SIZE_BODY)


func _draw_hints(centre: Vector2) -> void:
	var text: String = "F1 hud    F2 sections    F3 transmitter    F4 tuning    " \
		+ "F5 reload    R reset    1/2/3 camera    Z zoom"
	var width: float = UITheme.text_width(text, UITheme.SIZE_MICRO)
	UITheme.draw_text(_canvas, centre + Vector2(-width * 0.5, 0), text,
					  UITheme.SIZE_MICRO, UITheme.TEXT_FAINT)


## The per-section drawer. This is the wall of numbers, and it is behind a key
## for exactly that reason: it is a development tool, not part of flying.
func _draw_diagnostics(origin: Vector2) -> void:
	var count: int = _sim.get_section_count()
	# Compact rows: the drawer has to fit between the aircraft name above it and
	# the airspeed card below without either having to move.
	var row_height: float = 15.0
	var height: float = 96.0 + float(count) * row_height
	UITheme.draw_panel(_canvas, Rect2(origin, Vector2(292, height)), UITheme.PANEL_SOLID)

	UITheme.draw_label(_canvas, origin + Vector2(UITheme.S4, 22), "aerodynamic sections")
	UITheme.draw_rule(_canvas, origin + Vector2(UITheme.S4, 32), 260.0)

	UITheme.draw_label(_canvas, origin + Vector2(UITheme.S4, 48), "section")
	UITheme.draw_label(_canvas, origin + Vector2(182, 48), "aoa")
	UITheme.draw_label(_canvas, origin + Vector2(238, 48), "separated")

	for i in count:
		var y: float = 62.0 + float(i) * row_height
		var separation: float = _sim.get_section_separation(i)
		var colour: Color = UITheme.TEXT_DIM
		if separation > 0.5: colour = UITheme.DANGER
		elif separation > 0.05: colour = UITheme.WARN

		UITheme.draw_text(_canvas, origin + Vector2(UITheme.S4, y),
						  _sim.get_section_name(i), UITheme.SIZE_LABEL, colour)
		UITheme.draw_text(_canvas, origin + Vector2(182, y),
						  "%+5.1f" % _sim.get_section_alpha_degrees(i),
						  UITheme.SIZE_LABEL, colour)
		UITheme.draw_track(_canvas, Rect2(origin + Vector2(238, y - 7),
										 Vector2(40, 3)), separation, colour)

	var footer: float = 68.0 + float(count) * row_height
	UITheme.draw_rule(_canvas, origin + Vector2(UITheme.S4, footer), 260.0)
	UITheme.draw_text(_canvas, origin + Vector2(UITheme.S4, footer + 20),
					  "lift %.1f N    drag %.1f N    L/D %.1f"
					  % [_sim.get_total_lift_n(), _sim.get_total_drag_n(),
						 _sim.get_total_lift_n() / maxf(_sim.get_total_drag_n(), 0.01)],
					  UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
