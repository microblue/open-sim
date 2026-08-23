# OpenRC Simulator - the session tuning drawer.
#
# Scope, deliberately: this adjusts the SESSION - the air, the physics rate,
# where the aircraft starts. It has no slider for lift-curve slope or stall
# angle.
#
# The reason is that the aircraft's parameters live in Data/Aircraft/*.json and
# reload in place with a keypress. Editing a number in the file and pressing F5
# is a better loop than a slider: the value is written down, it is diffable, it
# survives the session, and the validation suite reads the same file. A second
# UI-only path to the same numbers would let the two drift apart, and then "what
# did I actually fly?" stops having an answer.
#
# So the air lives here; the aircraft lives in the file.
extends CanvasLayer

@export var simulation_path: NodePath

const WIDTH: float = 340.0

var _sim: RCSimulationNode
var _canvas: Control
var _selected: int = 0
var _rows: Array = []
var _slide: float = 0.0
var _nudged: float = 999.0


func _ready() -> void:
	layer = 9
	visible = false
	_sim = get_node_or_null(simulation_path) as RCSimulationNode

	_canvas = Control.new()
	_canvas.anchor_right = 1.0
	_canvas.anchor_bottom = 1.0
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_panel)
	add_child(_canvas)

	#     label            property               step   unit    min     max
	_rows = [
		["wind speed",      "wind_speed_mps",       0.5, "m/s",    0.0,   20.0],
		["wind from",       "wind_direction_deg",   5.0, "deg",    0.0,  355.0],
		["gust",            "gust_amplitude_mps",   0.5, "m/s",    0.0,   15.0],
		["turbulence",      "turbulence_mps",       0.2, "m/s",    0.0,    6.0],
		["wind seed",       "wind_seed",            1.0, "",       1.0,  999.0],
		["field elevation", "field_elevation_m",   50.0, "m",      0.0, 3000.0],
		["temperature",     "temperature_offset_c", 2.0, "K",    -30.0,   45.0],
		["physics rate",    "physics_rate_hz",     60.0, "Hz",    60.0,  960.0],
		["spawn height",    "spawn_altitude_m",    10.0, "m",      5.0,  400.0],
	]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	if event.keycode == KEY_F4:
		visible = not visible
		return
	if not visible or _sim == null:
		return

	match event.keycode:
		KEY_UP:    _selected = posmod(_selected - 1, _rows.size())
		KEY_DOWN:  _selected = posmod(_selected + 1, _rows.size())
		KEY_LEFT:  _nudge(-1.0)
		KEY_RIGHT: _nudge(1.0)
		KEY_F5:
			if _sim.reload_aircraft():
				_sim.reset_state()
		KEY_R:
			_sim.reset_state()


func _nudge(direction: float) -> void:
	var row: Array = _rows[_selected]
	var property: String = row[1]
	var current: float = float(_sim.get(property))
	var value: float = current + direction * float(row[2])
	# A compass has no ends, so the wind direction wraps instead of clamping.
	if property == "wind_direction_deg":
		value = fposmod(value, 360.0)
	else:
		value = clampf(value, float(row[4]), float(row[5]))
	_sim.set(property, value)
	_nudged = 0.0


func _process(delta: float) -> void:
	# Slide in and out rather than appearing: the movement is what tells the eye
	# the drawer belongs to the edge of the screen.
	var target: float = 1.0 if visible else 0.0
	_slide = move_toward(_slide, target, delta * 5.0)
	_nudged += delta
	if visible or _slide > 0.001:
		_canvas.queue_redraw()


func _draw_panel() -> void:
	if _sim == null or _slide <= 0.001:
		return

	var eased: float = 1.0 - pow(1.0 - _slide, 3.0)
	var size: Vector2 = _canvas.size
	var height: float = 128.0 + float(_rows.size()) * 30.0
	var origin := Vector2(size.x - UITheme.S5 - WIDTH + (1.0 - eased) * (WIDTH + 40.0),
						  UITheme.S5 + 78.0)

	UITheme.draw_panel(_canvas, Rect2(origin, Vector2(WIDTH, height)),
					   UITheme.PANEL_SOLID, UITheme.STROKE_STRONG, 12.0)

	UITheme.draw_label(_canvas, origin + Vector2(UITheme.S4, 26), "session tuning",
					   UITheme.ACCENT, 2.6)
	UITheme.draw_rule(_canvas, origin + Vector2(UITheme.S4, 38), WIDTH - UITheme.S4 * 2.0)

	for i in _rows.size():
		var row: Array = _rows[i]
		var y: float = 58.0 + float(i) * 30.0
		var active: bool = i == _selected
		var value: float = float(_sim.get(row[1]))

		if active:
			UITheme.draw_panel(_canvas,
				Rect2(origin + Vector2(UITheme.S2, y - 4), Vector2(WIDTH - UITheme.S2 * 2, 28)),
				Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, 0.10),
				Color(0, 0, 0, 0), 6.0)
			_canvas.draw_rect(Rect2(origin + Vector2(UITheme.S2, y - 4), Vector2(2, 28)),
							  UITheme.ACCENT, true)

		UITheme.draw_text(_canvas, origin + Vector2(UITheme.S4, y + 13), row[0],
						  UITheme.SIZE_LABEL,
						  UITheme.TEXT if active else UITheme.TEXT_DIM)

		var text: String = "%.0f %s" % [value, row[3]] if absf(float(row[2])) >= 1.0 \
			else "%.1f %s" % [value, row[3]]
		var width: float = UITheme.text_width(text, UITheme.SIZE_LABEL)
		# A brief flash on the value that just changed, so a keypress is visibly
		# connected to a number.
		var flash: float = clampf(1.0 - _nudged * 3.0, 0.0, 1.0) if active else 0.0
		UITheme.draw_text(_canvas, origin + Vector2(WIDTH - UITheme.S4 - width, y + 13),
						  text, UITheme.SIZE_LABEL,
						  UITheme.ACCENT if active else UITheme.TEXT_DIM)

		var span: float = maxf(float(row[5]) - float(row[4]), 0.001)
		UITheme.draw_track(_canvas,
			Rect2(origin + Vector2(UITheme.S4, y + 19), Vector2(WIDTH - UITheme.S4 * 2, 2)),
			(value - float(row[4])) / span,
			Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b,
				  0.9 if active else 0.35).lerp(Color.WHITE, flash * 0.5))

	var footer: float = height - 52.0
	UITheme.draw_rule(_canvas, origin + Vector2(UITheme.S4, footer),
					  WIDTH - UITheme.S4 * 2.0)
	UITheme.draw_text(_canvas, origin + Vector2(UITheme.S4, footer + 20),
					  "left / right adjust     F5 reload     R reset",
					  UITheme.SIZE_MICRO, UITheme.TEXT_FAINT)
	UITheme.draw_text(_canvas, origin + Vector2(UITheme.S4, footer + 36),
					  "aircraft parameters live in the JSON",
					  UITheme.SIZE_MICRO, UITheme.TEXT_FAINT)
