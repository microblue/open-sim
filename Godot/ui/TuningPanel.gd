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

const Settings := preload("res://ui/Settings.gd")

@export var simulation_path: NodePath

const WIDTH: float = 360.0
const PAD: float = 20.0
const ROW_H: float = 40.0

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
	_slide = target if Settings.reduced_motion() \
			else move_toward(_slide, target, delta * 5.0)
	_nudged += delta
	if visible or _slide > 0.001:
		_canvas.queue_redraw()


func _draw_panel() -> void:
	if _sim == null or _slide <= 0.001:
		return

	var eased: float = UITheme.ease_out(_slide)
	var size: Vector2 = _canvas.size
	var height: float = 64.0 + float(_rows.size()) * ROW_H + 92.0
	var origin := Vector2(roundf(size.x - UITheme.HUD_M - WIDTH + (1.0 - eased) * (WIDTH + 60.0)),
			UITheme.HUD_M + 96.0)
	var card := Rect2(origin, Vector2(WIDTH, height))
	UITheme.draw_modal(_canvas, card)

	UITheme.draw_label(_canvas, origin + Vector2(PAD, 38.0), "Session tuning", UITheme.TEXT_DIM)
	UITheme.draw_keycap(_canvas, origin + Vector2(WIDTH - PAD - UITheme.keycap_width("F4",
			UITheme.SIZE_KEY), 18.0), "F4", UITheme.SIZE_KEY)
	UITheme.draw_rule(_canvas, origin + Vector2(0, 60.0), WIDTH, UITheme.STROKE)

	for i in _rows.size():
		var row: Array = _rows[i]
		var top: float = origin.y + 66.0 + float(i) * ROW_H
		var active: bool = i == _selected
		var value: float = float(_sim.get(row[1]))
		var r := Rect2(origin.x + 8.0, top, WIDTH - 16.0, ROW_H - 4.0)

		if active:
			_canvas.draw_colored_polygon(UITheme.rounded_rect(r, UITheme.R_SM), UITheme.SURFACE_2)
			_canvas.draw_rect(Rect2(r.position + Vector2(0, 8), Vector2(3, r.size.y - 16)),
					UITheme.ACCENT)

		var label: String = String(row[0])
		label = label.substr(0, 1).to_upper() + label.substr(1)
		UITheme.draw_text(_canvas, Vector2(origin.x + PAD, top + 22.0), label, UITheme.SIZE_BODY_S,
				UITheme.TEXT if active else UITheme.TEXT_DIM)

		var number: String = "%.0f" % value if absf(float(row[2])) >= 1.0 else "%.1f" % value
		# A brief flash on the value that just changed, so a keypress is visibly
		# connected to a number.
		var flash: float = clampf(1.0 - _nudged * 3.0, 0.0, 1.0) if active else 0.0
		var colour: Color = (UITheme.TEXT if active else UITheme.TEXT_DIM) \
				.lerp(UITheme.ACCENT_HI, flash * 0.7)
		var unit: String = String(row[3])
		var unit_w: float = 0.0 if unit.is_empty() else UITheme.text_width(unit, UITheme.SIZE_KEY) + 6.0
		var right: float = origin.x + WIDTH - PAD
		UITheme.draw_numeral(_canvas, Vector2(right - unit_w, top + 22.0), number,
				UITheme.SIZE_BODY, colour, true, false)
		if not unit.is_empty():
			UITheme.draw_text(_canvas, Vector2(right - unit_w + 6.0, top + 22.0), unit,
					UITheme.SIZE_KEY, UITheme.TEXT_FAINT)

		var span: float = maxf(float(row[5]) - float(row[4]), 0.001)
		var track := Rect2(origin.x + PAD, top + 30.0, WIDTH - PAD * 2.0, 2.0)
		_canvas.draw_rect(track, Color(1, 1, 1, 0.10))
		_canvas.draw_rect(Rect2(track.position, Vector2(track.size.x
				* clampf((value - float(row[4])) / span, 0.0, 1.0), 2.0)),
				UITheme.ACCENT if active else Color(UITheme.ACCENT.r, UITheme.ACCENT.g,
				UITheme.ACCENT.b, 0.35))

	var footer: float = origin.y + height - 92.0
	UITheme.draw_rule(_canvas, Vector2(origin.x, footer), WIDTH, UITheme.STROKE)
	UITheme.draw_footer_hints(_canvas, Vector2(origin.x + PAD, footer + 28.0),
			[[["LEFT", "RIGHT"], "adjust"], [["F5"], "reload"], [["R"], "reset"]],
			UITheme.TEXT_DIM, UITheme.SIZE_KEY)
	UITheme.draw_text(_canvas, Vector2(origin.x + PAD, footer + 70.0),
			"Aircraft parameters live in the JSON.", UITheme.SIZE_BODY_S, UITheme.TEXT_FAINT)
