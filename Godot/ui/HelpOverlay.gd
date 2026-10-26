# OpenRC Simulator - the controls card (H, or F1).
#
# One screen that answers "how do I fly this, and what do the other keys do",
# with a picture rather than a table: the transmitter or the keyboard, drawn,
# each stick's job written beside it, moving live as the pilot tries it. The
# rest of the keys are grouped by what they are for, so nobody has to scan a
# list of twenty to find the replay.
#
# The key table is a grid: a fixed keycap column, right-aligned, and every
# description starting at the same x. A description that runs long wraps; the
# keys never do.
#
# Opens on whichever input is flying the aircraft; Tab shows the other one.
# With no transmitter connected, the transmitter side offers the setup instead
# of only saying so (wizard_requested).
extends CanvasLayer

const UI := preload("res://ui/UITheme.gd")
const Diagrams := preload("res://ui/ControlDiagrams.gd")
const Settings := preload("res://ui/Settings.gd")

signal closed
## "Set up a transmitter" (button or F3). The card has already closed itself
## (and emitted `closed`) when this fires.
signal wizard_requested

@export var input_path: NodePath

## [keys, description]. "–" between two keys draws a range ("4" to "8").
const GROUPS: Dictionary = {
	"flight": [
		[["R"], "Fly again (new flight)"],
		[["SHIFT", "R"], "Same flight again"],
		[["T"], "Restart in the air"],
		[["TAB"], "Replay the last two minutes"],
		[["P"], "Pause"],
	],
	"view": [
		[["C"], "Next view: follow, pilot, FPV"],
		[["Z"], "Zoom (pilot view)"],
		[["X"], "Auto-zoom on / off"],
		[["G"], "Height mark on the ground"],
		[["V"], "HUD: clean / standard / detailed"],
		[["RMB"], "Hold and drag to look around"],
	],
	"menus": [
		[["ESC"], "Pause menu"],
		[["M"], "Main menu: aircraft, place, weather"],
		[["O"], "Settings"],
		[["F3"], "Set up a transmitter"],
		[["H"], "This card"],
	],
	"practice": [
		[["4", "–", "8"], "Fail on purpose: motor, aileron, elevator, radio, power"],
		[["9"], "Clear the failure"],
	],
	"tools": [
		[["F2"], "Aerodynamic detail"],
		[["F4"], "Wind and physics drawer"],
		[["F10"], "Save the flight as CSV"],
		[["F9"], "Hide the overlay"],
	],
}
const COLUMNS: Array = [["flight", "view"], ["menus", "practice", "tools"]]
const SHELL := Vector2(1640.0, 900.0)

var _input: RCInputNode
var _canvas: Control
## The transmitter drawn dimmed when none is connected: a child of its own so
## its modulate carries the alpha the diagram code has no parameter for.
var _dim: Control
var _dim_rect := Rect2()
var _tab: int = 0          # 0 keyboard, 1 transmitter
var _tab_rects: Array = []
var _tab_hover: int = -1
var _close_rect := Rect2()
var _setup_rect := Rect2()
var _hover: String = ""
var _appear: float = 0.0
var _phase: float = 0.0


func _ready() -> void:
	layer = 42
	process_mode = Node.PROCESS_MODE_ALWAYS
	_input = get_node_or_null(input_path) as RCInputNode
	_tab = 1 if _input != null and _input.is_connected() else 0
	add_child(UI.make_frosted(0.62, 4.0))
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_screen)
	_canvas.gui_input.connect(_on_gui_input)
	add_child(_canvas)
	_dim = Control.new()
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim.modulate.a = 0.4
	_dim.draw.connect(_draw_dim)
	add_child(_dim)
	if Settings.reduced_motion():
		_appear = 1.0


func _process(delta: float) -> void:
	_appear = minf(_appear + delta / UI.APPEAR_S, 1.0)
	_phase += delta
	_canvas.queue_redraw()
	_dim.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	get_viewport().set_input_as_handled()
	match (event as InputEventKey).keycode:
		KEY_ESCAPE, KEY_H, KEY_F1, KEY_ENTER, KEY_KP_ENTER:
			_close()
		KEY_TAB:
			_tab = 1 - _tab
		KEY_LEFT:
			_tab = 0
		KEY_RIGHT:
			_tab = 1
		KEY_F3:
			_request_wizard()


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var p: Vector2 = event.position
		_tab_hover = -1
		for i in _tab_rects.size():
			if (_tab_rects[i] as Rect2).has_point(p):
				_tab_hover = i
		_hover = "close" if _close_rect.has_point(p) \
				else ("setup" if _setup_rect.has_point(p) else "")
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		for i in _tab_rects.size():
			if (_tab_rects[i] as Rect2).has_point(event.position):
				_tab = i
				return
		if _close_rect.has_point(event.position):
			_close()
		elif _setup_rect.has_point(event.position):
			_request_wizard()


func _close() -> void:
	closed.emit()
	queue_free()


func _request_wizard() -> void:
	closed.emit()
	wizard_requested.emit()
	queue_free()


func _connected() -> bool:
	return _input != null and _input.is_connected()


# ----------------------------------------------------------------- drawing --

func _draw_screen() -> void:
	var size: Vector2 = _canvas.size
	var eased: float = UI.ease_out(_appear)
	var card_w: float = minf(size.x - 48.0, SHELL.x)
	var card_h: float = minf(size.y - 48.0, SHELL.y)
	# Density: below 1080 the rows tighten rather than the type shrinking.
	var k: float = clampf(card_h / SHELL.y, 0.72, 1.0)
	var card := Rect2(roundf((size.x - card_w) * 0.5),
			roundf((size.y - card_h) * 0.5 + (1.0 - eased) * 12.0), card_w, card_h)
	UI.draw_modal(_canvas, card, eased)
	var pad: float = roundf(48.0 * k)
	var x0: float = card.position.x + pad
	var y0: float = card.position.y + roundf(36.0 * k)
	var inner: float = card_w - pad * 2.0

	# Header: title, the two ways to fly, and Close.
	UI.draw_display(_canvas, Vector2(x0, y0 + 36.0), "Controls", 40, UI.TEXT)
	var title_w: float = UI.font_condensed_bold().get_string_size("Controls",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 40).x
	var seg := Rect2(x0 + title_w + 40.0, y0, 320.0, 44.0)
	_tab_rects = UI.draw_segmented(_canvas, seg, ["Keyboard", "Transmitter"], _tab, _tab_hover)
	UI.draw_key_hint(_canvas, Vector2(seg.end.x + 16.0, seg.get_center().y), ["TAB"], "switch",
			UI.SIZE_KEY, UI.TEXT_FAINT)
	_close_rect = Rect2(card.end.x - pad - 150.0 + 16.0, y0, 150.0, 44.0)
	UI.draw_button_ex(_canvas, _close_rect, "Close", UI.TERTIARY,
			{"hover": _hover == "close", "key": "ESC"})
	var rule_y: float = y0 + 44.0 + roundf(20.0 * k)
	UI.draw_rule(_canvas, Vector2(card.position.x, rule_y), card_w, UI.STROKE)

	var body_y: float = rule_y + roundf(36.0 * k)
	var footer_y: float = card.end.y - roundf(48.0 * k)
	UI.draw_rule(_canvas, Vector2(card.position.x, footer_y), card_w, UI.STROKE)
	UI.draw_text(_canvas, Vector2(card.position.x, footer_y + roundf(30.0 * k)),
			"OpenRC Simulator  ·  MIT License  ·  Built with the Godot Engine",
			UI.SIZE_KEY, UI.TEXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER, card_w)

	var gutter: float = roundf(48.0 * k)
	var col_a: float = roundf(inner * 0.39)
	var col_b: float = floorf((inner - col_a - gutter * 2.0) * 0.5)
	var body := Rect2(x0, body_y, col_a, footer_y - roundf(28.0 * k) - body_y)
	if _tab == 0:
		_draw_keyboard_side(body, k)
	else:
		_draw_transmitter_side(body, k)

	# The rest of the keys, grouped, in two columns.
	var cx: float = x0 + col_a + gutter
	_canvas.draw_line(Vector2(cx - gutter * 0.5, body_y), Vector2(cx - gutter * 0.5, body.end.y),
			UI.STROKE, 1.0)
	for c in COLUMNS.size():
		_draw_key_column(Vector2(cx + float(c) * (col_b + gutter), body_y), col_b, k, COLUMNS[c])


func _draw_keyboard_side(body: Rect2, k: float) -> void:
	_setup_rect = Rect2()
	var mode: int = int(Settings.get_value("controls/stick_mode"))
	var x: float = body.position.x
	var y: float = body.position.y + 12.0
	UI.draw_label(_canvas, Vector2(x, y), "Flying on the keyboard", UI.TEXT_DIM)
	y += 32.0
	UI.draw_text(_canvas, Vector2(x, y),
			"The keys stand in for the two sticks of a transmitter (Mode %d)." % mode,
			UI.SIZE_BODY_S, UI.TEXT_DIM)
	var cap: float = roundf(64.0 * k)
	var drawn: Vector2 = Diagrams.draw_keyboard(_canvas, Vector2(x, y + 14.0), mode, true, cap)
	var tips: Array = [
		"The throttle stays where you leave it. The other keys spring back to centre.",
		"Tap rather than hold: small, short inputs fly more smoothly.",
	]
	var tip_h: float = 0.0
	for t in tips:
		tip_h += UI.wrap_text(t, body.size.x - 20.0, UI.SIZE_BODY_S).size() * 24.0 + 6.0
	# The keys moving the sticks, live, beside the keys themselves.
	var top: float = y + 14.0 + drawn.y + 16.0
	var room := Rect2(x, top, minf(body.size.x, 520.0), minf(body.end.y - tip_h - 16.0 - top, 300.0))
	if room.size.y > 120.0:
		Diagrams.draw_transmitter(_canvas, room, mode, Diagrams.channels_from_keys(mode),
				[], _phase, true)
	_draw_tips(Vector2(x, body.end.y - tip_h), body.size.x, tips)


func _draw_transmitter_side(body: Rect2, k: float) -> void:
	var mode: int = int(Settings.get_value("controls/stick_mode"))
	var x: float = body.position.x
	var y: float = body.position.y + 12.0
	UI.draw_label(_canvas, Vector2(x, y), "Flying with a transmitter", UI.TEXT_DIM)
	y += 32.0
	if _connected():
		_setup_rect = Rect2()
		_dim_rect = Rect2()
		UI.draw_text(_canvas, Vector2(x, y),
				"%s, Mode %d. Move the sticks to see them here." % [_input.get_device_name(), mode],
				UI.SIZE_BODY_S, UI.TEXT_DIM)
		var room := Rect2(x, y + 24.0, minf(body.size.x, 520.0),
				minf(body.end.y - 60.0 - (y + 24.0), 300.0))
		Diagrams.draw_transmitter(_canvas, room, mode, _input.get_channels(), [], _phase, true)
		_draw_tips(Vector2(x, room.end.y + 24.0), body.size.x,
				["Pull the elevator stick back to raise the nose; push it to lower it."])
		return

	# Nothing connected: the picture, dimmed, and the way to fix it - as one
	# block, centred in the column, rather than a sentence at the top of it.
	_setup_rect = Rect2()
	var diag_w: float = minf(body.size.x, 400.0)
	var diag_h: float = roundf(minf(diag_w / 1.75 * 1.26, 300.0) * k)
	var block_h: float = diag_h + 36.0 + 28.0 + 24.0 + 24.0 + 52.0
	var top: float = maxf(y + 8.0, y + (body.end.y - y - block_h) * 0.42)
	_dim_rect = Rect2(x, top, diag_w, diag_h)
	y = top + diag_h + 36.0
	UI.draw_warn_triangle(_canvas, Vector2(x + 9.0, y - 7.0), 18.0, UI.WARN)
	UI.draw_text(_canvas, Vector2(x + 28.0, y), "No transmitter connected.",
			UI.SIZE_BODY, UI.WARN, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold())
	y += 28.0
	UI.draw_text(_canvas, Vector2(x, y),
			"Plug it in with a USB data cable, then set it up once: about a minute.",
			UI.SIZE_BODY_S, UI.TEXT_DIM)
	y += 24.0
	_setup_rect = Rect2(x, y, 320.0, 52.0)
	UI.draw_button_ex(_canvas, _setup_rect, "Set up a transmitter", UI.SECONDARY,
			{"hover": _hover == "setup", "key": "F3", "align": "left"})


func _draw_dim() -> void:
	if _tab != 1 or _connected() or _dim_rect.size.y <= 0.0:
		return
	_dim.modulate.a = 0.4 * UI.ease_out(_appear)
	Diagrams.draw_transmitter(_dim, _dim_rect, int(Settings.get_value("controls/stick_mode")),
			PackedFloat64Array(), [], _phase, true)


func _draw_tips(at: Vector2, width: float, tips: Array) -> void:
	var y: float = at.y - 6.0
	for t in tips:
		var lines: PackedStringArray = UI.wrap_text(String(t), width - 20.0, UI.SIZE_BODY_S)
		for i in lines.size():
			y += 24.0
			if i == 0:
				_canvas.draw_circle(Vector2(at.x + 5.0, y - 6.0), 2.5, UI.TEXT_FAINT)
			UI.draw_text(_canvas, Vector2(at.x + 20.0, y), lines[i], UI.SIZE_BODY_S, UI.TEXT_DIM)
		y += 6.0


func _draw_key_column(origin: Vector2, width: float, k: float, groups: Array) -> void:
	var pitch: float = roundf(38.0 * k)
	var key_col: float = roundf(120.0 * maxf(k, 0.85))
	var desc_x: float = origin.x + key_col + 16.0
	var desc_w: float = width - key_col - 16.0
	var desc_size: int = 19 if k > 0.9 else 18
	var y: float = origin.y + 12.0
	var first: bool = true
	for g in groups:
		if not first:
			y += roundf(34.0 * k)
		first = false
		UI.draw_label(_canvas, Vector2(origin.x, y), String(g), UI.TEXT_DIM)
		UI.draw_rule(_canvas, Vector2(origin.x, y + 9.0), 24.0, UI.STROKE_STRONG, 2.0)
		y += roundf(18.0 * k)
		if g == "practice" and not bool(Settings.get_value("practice/failure_keys")):
			_draw_practice_off(Vector2(origin.x, y + pitch * 0.5 + 6.0))
			y += pitch
			continue
		for entry in GROUPS[g]:
			var lines: PackedStringArray = UI.wrap_text(String(entry[1]), desc_w, desc_size)
			var cy: float = y + pitch * 0.5
			_draw_keys_right(Vector2(origin.x + key_col, cy), entry[0])
			for i in lines.size():
				UI.draw_text(_canvas, Vector2(desc_x, cy + 6.0 + float(i) * 22.0), lines[i],
						desc_size, UI.TEXT)
			y += pitch + float(lines.size() - 1) * 22.0


## Keycaps right-aligned to `right_mid` (right edge, vertical centre).
func _draw_keys_right(right_mid: Vector2, keys: Array) -> void:
	var widths: Array = []
	var total: float = 0.0
	for key in keys:
		var w: float = 14.0 if key == "–" else UI.keycap_width(String(key), UI.SIZE_KEY)
		widths.append(w)
		total += w + 4.0
	total -= 4.0
	var x: float = right_mid.x - total
	var h: float = UI.keycap_width("W", UI.SIZE_KEY)     # a one-letter cap is square
	for i in keys.size():
		if keys[i] == "–":
			_canvas.draw_line(Vector2(x + 3.0, right_mid.y), Vector2(x + 11.0, right_mid.y),
					UI.TEXT_DIM, 2.0)
		else:
			UI.draw_keycap(_canvas, Vector2(x, right_mid.y - h * 0.5), String(keys[i]), UI.SIZE_KEY)
		x += float(widths[i]) + 4.0


## "Turn on in Settings > Practice", with a vector arrow: neither face has one.
func _draw_practice_off(at: Vector2) -> void:
	var size: int = UI.SIZE_BODY_S
	var parts: Array = ["Off. Turn on in Settings", "Practice"]
	var x: float = at.x
	UI.draw_text(_canvas, Vector2(x, at.y), parts[0], size, UI.TEXT_FAINT)
	x += UI.text_width(parts[0], size) + 8.0
	UI.draw_arrow_glyph(_canvas, Vector2(x + 7.0, at.y - 6.0), 1, 12.0, UI.TEXT_FAINT)
	x += 22.0
	UI.draw_text(_canvas, Vector2(x, at.y), parts[1], size, UI.TEXT_FAINT)
