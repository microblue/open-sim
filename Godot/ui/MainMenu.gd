# OpenRC Simulator - the start screen.
#
# The V0.1 requirement is to be flying within seconds of launching, so this is
# built to be left rather than explored: four entries, keyboard driven, and it
# is skipped entirely once a controller profile exists.
#
# The field stays visible behind it, blurred and sunk towards the base colour,
# rather than cutting to a black slab. That is not decoration - it keeps the
# pilot oriented, and it means the menu reads as something laid over the world
# instead of a separate application.
extends CanvasLayer

signal fly_requested
signal wizard_requested

@export var input_path: NodePath
@export var simulation_path: NodePath

const ENTRIES: Array = [
	{"key": "ENTER", "title": "Fly",               "note": "GrassField01, Trainer 1500"},
	{"key": "C",     "title": "Transmitter setup", "note": "calibrate the radio"},
	{"key": "W",     "title": "Weather",           "note": "wind, gusts, turbulence"},
	{"key": "ESC",   "title": "Quit",              "note": ""},
]

var _input: RCInputNode
var _sim: RCSimulationNode
var _canvas: Control
var _selected: int = 0
var _appear: float = 0.0


func _ready() -> void:
	layer = 20
	_input = get_node_or_null(input_path) as RCInputNode
	_sim = get_node_or_null(simulation_path) as RCSimulationNode

	add_child(UITheme.make_frosted(0.74, 3.4))

	_canvas = Control.new()
	_canvas.anchor_right = 1.0
	_canvas.anchor_bottom = 1.0
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_menu)
	add_child(_canvas)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	match event.keycode:
		KEY_UP:    _selected = posmod(_selected - 1, ENTRIES.size())
		KEY_DOWN:  _selected = posmod(_selected + 1, ENTRIES.size())
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: _activate(_selected)
		KEY_C:     _activate(1)
		KEY_W:     _activate(2)
		KEY_ESCAPE: _activate(3)


func _activate(index: int) -> void:
	match index:
		0:
			fly_requested.emit()
			queue_free()
		1:
			wizard_requested.emit()
			queue_free()
		2:
			# Weather lives on the tuning panel, which is where it can be
			# adjusted while watching the windsock respond. Sending the pilot
			# there beats duplicating the controls.
			fly_requested.emit()
			queue_free()
			get_viewport().push_input(_synth_key(KEY_F4))
		3:
			get_tree().quit()


func _synth_key(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	return event


func _process(delta: float) -> void:
	_appear = minf(_appear + delta * 3.2, 1.0)
	_canvas.queue_redraw()


func _draw_menu() -> void:
	var size: Vector2 = _canvas.size
	# A short slide-and-fade in. Motion is what separates a screen that appeared
	# from a screen that was always there.
	var ease_in: float = 1.0 - pow(1.0 - _appear, 3.0)
	var slide: float = (1.0 - ease_in) * 24.0
	var origin := Vector2(size.x * 0.10, size.y * 0.24) + Vector2(0, slide)

	UITheme.draw_label(_canvas, origin, "openrc", UITheme.ACCENT, 9.0, UITheme.SIZE_HERO)
	UITheme.draw_text(_canvas, origin + Vector2(4, 34),
					  "RC flight training simulator",
					  UITheme.SIZE_BODY, UITheme.TEXT_DIM)
	UITheme.draw_rule(_canvas, origin + Vector2(0, 58), 340.0, UITheme.STROKE_STRONG)

	for i in ENTRIES.size():
		var y: float = origin.y + 100.0 + float(i) * 54.0
		var active: bool = i == _selected

		if active:
			UITheme.draw_panel(_canvas, Rect2(Vector2(origin.x - 18, y - 26),
											  Vector2(420, 44)),
							   Color(UITheme.ACCENT.r, UITheme.ACCENT.g,
									 UITheme.ACCENT.b, 0.10),
							   Color(0, 0, 0, 0), 8.0)
			_canvas.draw_rect(Rect2(Vector2(origin.x - 18, y - 26), Vector2(3, 44)),
							  UITheme.ACCENT, true)

		UITheme.draw_label(_canvas, Vector2(origin.x, y - 4), ENTRIES[i]["key"],
						   UITheme.ACCENT if active else UITheme.TEXT_FAINT, 2.0)
		UITheme.draw_text(_canvas, Vector2(origin.x + 86, y),
						  ENTRIES[i]["title"], UITheme.SIZE_VALUE,
						  UITheme.TEXT if active else UITheme.TEXT_DIM)
		if ENTRIES[i]["note"] != "":
			UITheme.draw_text(_canvas, Vector2(origin.x + 86, y + 17),
							  ENTRIES[i]["note"], UITheme.SIZE_LABEL,
							  UITheme.TEXT_DIM if active else UITheme.TEXT_FAINT)

	_draw_status(Vector2(size.x * 0.58, size.y * 0.24 + slide))

	var hint: String = "up / down to move    enter to choose"
	UITheme.draw_text(_canvas,
		Vector2(size.x * 0.5 - UITheme.text_width(hint, UITheme.SIZE_LABEL) * 0.5,
				size.y - 48.0),
		hint, UITheme.SIZE_LABEL, UITheme.TEXT_FAINT)


## The one thing worth knowing before flying: is the radio ready?
func _draw_status(origin: Vector2) -> void:
	var rect := Rect2(origin, Vector2(330, 214))
	UITheme.draw_panel(_canvas, rect, UITheme.PANEL_SOLID)

	UITheme.draw_label(_canvas, origin + Vector2(UITheme.S5, 28), "session")
	UITheme.draw_rule(_canvas, origin + Vector2(UITheme.S5, 40), 282.0)

	var rows: Array = []
	if _input != null and _input.is_connected():
		rows.append(["transmitter", _input.get_device_name().substr(0, 24),
					 UITheme.TEXT])
		if _input.is_fully_bound():
			rows.append(["calibration", "ready", UITheme.GOOD])
		else:
			rows.append(["calibration", "not set up - press C", UITheme.WARN])
	else:
		rows.append(["transmitter", "none detected", UITheme.WARN])
		rows.append(["", "plug the radio in over USB", UITheme.TEXT_FAINT])

	if _sim != null:
		rows.append(["aircraft", _sim.get_aircraft_name(), UITheme.TEXT])
		rows.append(["field", "GrassField01", UITheme.TEXT])
		rows.append(["wind", "%.1f m/s from %03d" % [_sim.wind_speed_mps,
						roundi(_sim.wind_direction_deg)], UITheme.TEXT_DIM])

	for i in rows.size():
		var y: float = 70.0 + float(i) * 28.0
		UITheme.draw_label(_canvas, origin + Vector2(UITheme.S5, y), rows[i][0])
		UITheme.draw_text(_canvas, origin + Vector2(UITheme.S5 + 110, y + 4),
						  rows[i][1], UITheme.SIZE_LABEL, rows[i][2])
