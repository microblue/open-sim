# OpenRC Simulator - transmitter setup.
#
# The first thing a pilot does, and the thing that decides whether the simulator
# feels like their radio or like a games console.
#
# It asks for one stick at a time and works out which axis that was, so nobody
# has to know what "axis 3" means on their particular radio. The axis bars are
# shown live throughout, because the fastest way to understand what a setup
# screen is doing is to watch it react.
#
# The throttle step also asks which thumb the throttle is on (stick mode). For
# a transmitter that only changes the pictures and hints - the radio applies
# its own mode and the sticks are bound here by function - so it is asked
# while the pilot is holding the stick, not as an abstract question up front.
#
# The review page says which way each stick should fill its bar, and marks a
# channel that looks reversed: the sweep prompts give the first direction
# ("roll left first"), so the sign of the first big movement on each axis says
# whether the binding came out the right way round.
#
# All the arithmetic lives in RCPhysics/Input, where it is tested without a
# device attached. This is only the conversation.
extends CanvasLayer

const UI := preload("res://ui/UITheme.gd")
const Diagrams := preload("res://ui/ControlDiagrams.gd")
const Settings := preload("res://ui/Settings.gd")

signal finished(saved: bool)

const PROFILE_PATH: String = "user://controller.json"
const CENTRE_SECONDS: float = 1.2
const REQUIRED_TRAVEL: float = 0.45
## Observed range (raw -1..1, so 2.0 is end to end) that fills the capture meter.
const FULL_TRAVEL: float = 1.6
## Seconds without a transmitter before the troubleshooting list opens.
const RADIO_PATIENCE: float = 10.0
## How far an axis has to move from where it started for its first direction
## to count.
const FIRST_MOVE: float = 0.5

enum Step { DETECT, CENTRE, SWEEP, REVIEW, DONE }

## `first` is the sign the channel should take on the first movement the hint
## asks for; `action` is the movement that fills the review bar to the right.
const CHANNELS: Array = [
	{"id": RCInputNode.CHANNEL_AILERON,  "name": "Aileron",
	 "hint": "Roll fully left, then fully right.", "first": -1, "action": "right"},
	{"id": RCInputNode.CHANNEL_ELEVATOR, "name": "Elevator",
	 "hint": "Pull all the way back, then push all the way forward.", "first": 1, "action": "back"},
	{"id": RCInputNode.CHANNEL_THROTTLE, "name": "Throttle",
	 "hint": "All the way up, then all the way down.", "first": 1, "action": "up"},
	{"id": RCInputNode.CHANNEL_RUDDER,   "name": "Rudder",
	 "hint": "Full left, then full right.", "first": -1, "action": "right"},
]

@export var input_path: NodePath

var _input: RCInputNode
var _canvas: Control
var _step: Step = Step.DETECT
var _channel_index: int = 0
var _timer: float = 0.0
var _bound_axis: Array[int] = []
var _message: String = ""
var _message_age: float = 0.0
var _appear: float = 0.0
var _phase: float = 0.0
## The channel row chosen on the review page, for Reverse.
var _review_index: int = 0
var _row_rects: Array[Rect2] = []
var _hover_row: int = -1
## Clickable buttons this frame: [rect, action].
var _buttons: Array = []
var _hover_action: String = ""
var _thumb_rects: Array = []
var _hover_thumb: int = -1
## Last input came from the keyboard: draw focus rings.
var _kbd: bool = true
## Seconds on the connect step with nothing plugged in.
var _detect_wait: float = 0.0
var _was_connected: bool = false
## Counts down from 0.2 s when Begin becomes available, to flash its ring.
var _flash: float = 0.0
## Raw axes when the current sweep began, and the sign of each axis's first
## big movement since then.
var _sweep_start: PackedFloat64Array = PackedFloat64Array()
var _first_sign: Dictionary = {}
## Per channel (CHANNELS order): the sign of the first movement of the axis it
## was bound to, 0 when unknown.
var _channel_first: Array[int] = [0, 0, 0, 0]
## For screenshots: devices to list instead of Input.get_connected_joypads().
var _seen_override: Array = []


func _ready() -> void:
	layer = 24
	_input = get_node_or_null(input_path) as RCInputNode

	var frost: ColorRect = UI.make_frosted(0.62, 4.0)
	frost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frost)

	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_wizard)
	_canvas.gui_input.connect(_on_gui_input)
	add_child(_canvas)

	_was_connected = _connected()
	_restart()


func _connected() -> bool:
	return _input != null and _input.is_connected()


func _restart() -> void:
	_step = Step.DETECT
	_channel_index = 0
	_timer = 0.0
	_bound_axis.clear()
	_channel_first = [0, 0, 0, 0]
	_set_message("")
	if _input != null:
		_input.reset_capture()


func _set_message(text: String) -> void:
	_message = text
	_message_age = 0.0


func _mode() -> int:
	return int(Settings.get_value("controls/stick_mode"))


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	_kbd = true
	var handled: bool = true
	match event.keycode:
		KEY_ESCAPE:
			_do("cancel")
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			_advance()
		KEY_BACKSPACE:
			_restart()
		KEY_R:
			if _step == Step.REVIEW:
				_do("reverse")
		KEY_UP:
			if _step == Step.REVIEW:
				_review_index = posmod(_review_index - 1, CHANNELS.size())
		KEY_DOWN:
			if _step == Step.REVIEW:
				_review_index = posmod(_review_index + 1, CHANNELS.size())
		KEY_LEFT:
			if _asking_thumb():
				_set_mode(2)
		KEY_RIGHT:
			if _asking_thumb():
				_set_mode(1)
		KEY_S:
			if _step == Step.REVIEW:
				_save()
		_:
			handled = false
	if handled and is_inside_tree():
		get_viewport().set_input_as_handled()


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_kbd = false
		var p: Vector2 = event.position
		_hover_action = ""
		for entry in _buttons:
			if (entry[0] as Rect2).has_point(p):
				_hover_action = String(entry[1])
		_hover_thumb = -1
		for i in _thumb_rects.size():
			if (_thumb_rects[i] as Rect2).has_point(p):
				_hover_thumb = i
		_hover_row = -1
		for i in _row_rects.size():
			if _row_rects[i].has_point(p):
				_hover_row = i
		return
	if not (event is InputEventMouseButton and event.pressed
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	for entry in _buttons:
		if (entry[0] as Rect2).has_point(event.position):
			_do(String(entry[1]))
			return
	for i in _thumb_rects.size():
		if (_thumb_rects[i] as Rect2).has_point(event.position):
			_set_mode(2 if i == 0 else 1)
			return
	if _step == Step.REVIEW:
		for i in _row_rects.size():
			if _row_rects[i].has_point(event.position):
				_review_index = i


func _do(action: String) -> void:
	if action.begins_with("pad:"):
		if _input != null:
			_input.set_device_id(int(action.substr(4)))
		return
	match action:
		"cancel", "keyboard":
			finished.emit(false)
			queue_free()
		"advance":
			_advance()
		"restart":
			_restart()
		"reverse":
			if _step != Step.REVIEW:
				return
			var id: int = CHANNELS[_review_index]["id"]
			_input.set_channel_reversed(id, not _input.get_channel_reversed(id))


func _asking_thumb() -> bool:
	return _step == Step.SWEEP and _channel_index < CHANNELS.size() \
			and int(CHANNELS[_channel_index]["id"]) == RCInputNode.CHANNEL_THROTTLE


func _set_mode(mode: int) -> void:
	if mode == _mode():
		return
	Settings.set_value("controls/stick_mode", mode)
	if _input != null:
		_input.set_keyboard_mode(mode)


func _advance() -> void:
	match _step:
		Step.DETECT:
			if _connected():
				_step = Step.CENTRE
				_timer = 0.0
				_input.reset_capture()
				_input.begin_capture(true)
		Step.SWEEP:
			_try_bind()
		Step.REVIEW:
			_save()
		Step.DONE:
			finished.emit(true)
			queue_free()


func _try_bind() -> void:
	var axis: int = _input.identify_moved_axis()
	if axis < 0:
		_set_message("Not sure which axis that was. Sweep it again, on its own.")
		return
	if axis in _bound_axis:
		_set_message("That axis is already bound to another channel.")
		return
	if _input.get_axis_travel(axis) < REQUIRED_TRAVEL:
		_set_message("That did not move far enough. Use the full throw.")
		return

	if not _input.bind_channel(CHANNELS[_channel_index]["id"], axis):
		_set_message("That axis could not be calibrated. Try again.")
		return

	_bound_axis.append(axis)
	_channel_first[_channel_index] = int(_first_sign.get(axis, 0))
	_set_message("")
	_channel_index += 1
	_begin_sweep_watch()

	if _channel_index >= CHANNELS.size():
		_input.end_capture()
		_step = Step.REVIEW
	else:
		_input.reset_travel()


func _begin_sweep_watch() -> void:
	_sweep_start = _input.get_raw_axes() if _input != null else PackedFloat64Array()
	_first_sign.clear()


func _save() -> void:
	if _input.save_profile(PROFILE_PATH):
		_step = Step.DONE
		_set_message("")
	else:
		_set_message("Could not write the profile.")


func _process(delta: float) -> void:
	_appear = minf(_appear + delta / UI.APPEAR_S, 1.0)
	_phase += delta
	_message_age += delta
	_flash = maxf(_flash - delta, 0.0)

	var connected: bool = _connected()
	if connected and not _was_connected and _step == Step.DETECT:
		_flash = 0.2
	_was_connected = connected
	if _step == Step.DETECT and not connected:
		_detect_wait += delta
	else:
		_detect_wait = 0.0

	if _input != null and _step == Step.CENTRE:
		_timer += delta
		if _timer >= CENTRE_SECONDS:
			_input.end_capture()
			_input.reset_travel()
			_input.begin_capture(false)
			_step = Step.SWEEP
			_begin_sweep_watch()

	# The first big movement of each axis, for the review page's direction check.
	if _input != null and _step == Step.SWEEP and connected:
		var raw: PackedFloat64Array = _input.get_raw_axes()
		if _sweep_start.size() != raw.size():
			_sweep_start = raw
		for a in raw.size():
			if not _first_sign.has(a):
				var d: float = raw[a] - _sweep_start[a]
				if absf(d) > FIRST_MOVE:
					_first_sign[a] = 1 if d > 0.0 else -1

	_canvas.queue_redraw()


# ---------------------------------------------------------------- drawing ---

func _btn(rect: Rect2, label: String, style: int, action: String, opts: Dictionary = {}) -> void:
	var o: Dictionary = opts.duplicate()
	var enabled: bool = bool(o.get("enabled", true))
	o["hover"] = enabled and _hover_action == action
	if style == UI.PRIMARY and not o.has("focus"):
		o["focus"] = enabled and (_kbd or _flash > 0.0)
	if style == UI.PRIMARY and enabled and _flash > 0.0:
		# Begin just became available: one ring flash, so the change is seen.
		var t: float = 1.0 - _flash / 0.2
		var ring: PackedVector2Array = UI.rounded_rect(rect.grow(3.0 + t * 10.0), UI.R_MD + 3.0 + t * 10.0)
		ring.append(ring[0])
		_canvas.draw_polyline(ring, Color(UI.ACCENT, 1.0 - t), UI.STROKE_UI, true)
	UI.draw_button_ex(_canvas, rect, label, style, o)
	if enabled:
		_buttons.append([rect, action])


func _button_w(label: String, key: String = "", size: int = UI.SIZE_BUTTON) -> float:
	var w: float = UI.font_label().get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 64.0
	if not key.is_empty():
		w += UI.keycap_width(key, UI.SIZE_KEY) + 12.0
	return maxf(w, 160.0)


func _draw_wizard() -> void:
	if _input == null:
		return
	_buttons.clear()
	_thumb_rects = []
	_row_rects.clear()
	var size: Vector2 = _canvas.size
	var t: float = UI.ease_out(_appear)
	_canvas.modulate.a = t
	var w: float = minf(size.x - 80.0, 1360.0)
	var h: float = minf(size.y - 80.0, 860.0)
	var card := Rect2((size.x - w) * 0.5, (size.y - h) * 0.5 + (1.0 - t) * 12.0, w, h)
	UI.draw_modal(_canvas, card)

	var pad: float = UI.S7
	var x0: float = card.position.x + pad
	var y0: float = card.position.y + pad
	var inner_w: float = card.size.x - pad * 2.0

	var names: Array = ["Connect", "Centre"]
	for c in CHANNELS:
		names.append(c["name"])
	names.append("Check")
	var current: int = 0
	match _step:
		Step.DETECT: current = 0
		Step.CENTRE: current = 1
		Step.SWEEP:  current = 2 + _channel_index
		Step.REVIEW: current = names.size() - 1
		Step.DONE:   current = names.size()
	UI.draw_stepper(_canvas, Rect2(x0, y0, inner_w, 40.0), names, current)

	var row_y: float = card.end.y - pad - 56.0
	var body := Rect2(x0, y0 + 40.0, inner_w, row_y - 32.0 - (y0 + 40.0))
	var mode: int = _mode()
	match _step:
		Step.DETECT: _draw_detect(body, mode)
		Step.CENTRE: _draw_centre(body, mode)
		Step.SWEEP:  _draw_sweep(body, mode)
		Step.REVIEW: _draw_review(body, mode)
		Step.DONE:   _draw_done(body, mode)

	if _message != "":
		var pulse: float = clampf(1.0 - _message_age * 0.25, 0.55, 1.0)
		var col := Color(UI.WARN, pulse)
		UI.draw_warn_triangle(_canvas, Vector2(x0 + 10.0, row_y - 52.0), 20.0, col)
		UI.draw_text(_canvas, Vector2(x0 + 32.0, row_y - 45.0), _message, UI.SIZE_BODY, col,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold())

	# Buttons: cancel on the left, the next step on the right.
	UI.draw_rule(_canvas, Vector2(x0, row_y - 24.0), inner_w)
	var bx: float = x0
	if _step != Step.DONE:
		var cw: float = _button_w("Cancel", "ESC")
		_btn(Rect2(bx, row_y, cw, 56.0), "Cancel", UI.SECONDARY, "cancel", {"key": "ESC"})
		bx += cw + UI.S3
	if _step == Step.DETECT and not _connected():
		var kb: String = "Fly with the keyboard for now"
		_btn(Rect2(bx, row_y, _button_w(kb), 56.0), kb, UI.SECONDARY, "keyboard")
	if _step == Step.SWEEP or _step == Step.REVIEW:
		var sw: float = _button_w("Start over", "BACKSPACE")
		_btn(Rect2(bx, row_y, sw, 56.0), "Start over", UI.TERTIARY, "restart", {"key": "BACKSPACE"})
		bx += sw + UI.S3
	if _step == Step.REVIEW:
		var rw: float = _button_w("Reverse %s" % String(CHANNELS[_review_index]["name"]).to_lower(), "R")
		_btn(Rect2(bx, row_y, rw, 56.0), "Reverse %s" % String(CHANNELS[_review_index]["name"]).to_lower(),
				UI.SECONDARY, "reverse", {"key": "R"})

	var primary: String = ""
	var key: String = "SPACE"
	var enabled: bool = true
	match _step:
		Step.DETECT:
			primary = "Begin"
			enabled = _connected()
		Step.SWEEP: primary = "Confirm"
		Step.REVIEW:
			primary = "Save"
			key = "S"
		Step.DONE: primary = "Done"
	if not primary.is_empty():
		_btn(Rect2(card.end.x - pad - 260.0, row_y, 260.0, 56.0), primary, UI.PRIMARY, "advance",
				{"enabled": enabled, "key": key})


## H1 title, then either a subtitle or a status line (spinner, dot or check).
func _heading(body: Rect2, title: String, sub: String = "", status: String = "",
			  colour: Color = UI.TEXT_DIM) -> void:
	UI.draw_display(_canvas, body.position + Vector2(0, 84.0), title, UI.SIZE_H1, UI.TEXT)
	var c := Vector2(body.position.x + 9.0, body.position.y + 117.0)
	var tx: float = body.position.x
	match status:
		"spin":
			UI.draw_spinner(_canvas, c, 9.0, _phase, UI.ACCENT)
			tx += 30.0
		"dot":
			_canvas.draw_circle(c, 6.0, colour)
			tx += 30.0
		"check":
			UI.draw_check(_canvas, c, 16.0, colour)
			tx += 30.0
	if not sub.is_empty():
		UI.draw_text(_canvas, Vector2(tx, body.position.y + 124.0), sub, UI.SIZE_BODY, colour,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold() if status != "" else null)


## The picture side: a well on the right, `left_w` from the body's left edge.
func _right_well(body: Rect2, left_w: float) -> Rect2:
	var top: float = body.position.y + 168.0
	var r := Rect2(body.position.x + left_w + UI.S8, top, body.size.x - left_w - UI.S8, body.end.y - top)
	_canvas.draw_colored_polygon(UI.rounded_rect(r, UI.R_MD), Color(UI.BASE, 0.5))
	return r


func _draw_detect(body: Rect2, mode: int) -> void:
	var top: float = body.position.y + 168.0
	if _connected():
		var name: String = _input.get_device_name()
		if name.length() > 40:
			name = name.substr(0, 39) + "…"
		_heading(body, "Transmitter found", "Found: %s" % name, "dot", UI.GOOD)
		var y: float = top + 24.0
		for line in UI.wrap_text("Press Begin, then move each stick when asked. It takes about a minute.",
				520.0, UI.SIZE_BODY):
			UI.draw_text(_canvas, Vector2(body.position.x, y), line, UI.SIZE_BODY, UI.TEXT)
			y += 30.0
		UI.draw_label(_canvas, Vector2(body.position.x, y + 30.0),
				"what it is sending  ·  %d axes" % _input.get_axis_count(), UI.TEXT_DIM)
		_draw_axes(Vector2(body.position.x, y + 46.0), 8)
		var well: Rect2 = _right_well(body, 560.0)
		Diagrams.draw_transmitter(_canvas, well.grow(-UI.S5), mode, PackedFloat64Array(), [],
				_phase, true)
		return

	var late: bool = _detect_wait >= RADIO_PATIENCE
	_heading(body, "Connect your transmitter",
			"Still waiting for a transmitter…" if late else "Waiting for a transmitter…",
			"spin", UI.WARN if late else UI.TEXT_DIM)
	Diagrams.draw_steps(_canvas, Vector2(body.position.x, top), 560.0, [
		{"title": "Plug the radio into this computer.",
		 "detail": "Use a USB data cable: some cables only charge.", "state": "current"},
		{"title": "On the radio, choose USB Joystick mode.",
		 "detail": "EdgeTX and OpenTX ask when the cable goes in: pick USB Joystick (HID). Others call it Simulator or game controller mode.",
		 "state": "todo"},
		{"title": "This screen notices by itself.",
		 "detail": "Then Begin lights up, and each stick is set up in turn.", "state": "todo"},
	])
	if late:
		var r := Rect2(body.position.x + 560.0 + UI.S8, top, body.size.x - 560.0 - UI.S8,
				body.end.y - top)
		var pads: Array = _seen_override if not _seen_override.is_empty() else Diagrams.seen_joypads()
		var hover_id: int = int(_hover_action.substr(4)) if _hover_action.begins_with("pad:") else -1
		for hit in Diagrams.draw_troubleshooting(_canvas, r, pads, hover_id):
			_buttons.append([hit[0], "pad:%d" % int(hit[1])])
	else:
		var well: Rect2 = _right_well(body, 560.0)
		Diagrams.draw_transmitter(_canvas, well.grow(-UI.S5), mode, PackedFloat64Array(), [],
				_phase, true, 0.45)


func _draw_centre(body: Rect2, mode: int) -> void:
	var top: float = body.position.y + 168.0
	_heading(body, "Hands off the sticks",
			"Let every stick spring back to the middle. Leave the throttle where it is.")
	var fraction: float = clampf(_timer / CENTRE_SECONDS, 0.0, 1.0)
	UI.draw_label(_canvas, Vector2(body.position.x, top + 18.0), "measuring the centre of each axis",
			UI.TEXT_DIM)
	UI.draw_track(_canvas, Rect2(Vector2(body.position.x, top + 34.0), Vector2(520.0, 6.0)), fraction)
	_draw_axes(Vector2(body.position.x, top + 76.0), 8)
	var well: Rect2 = _right_well(body, 560.0)
	Diagrams.draw_transmitter(_canvas, well.grow(-UI.S5), mode, PackedFloat64Array(), [],
			_phase, true)


func _draw_sweep(body: Rect2, mode: int) -> void:
	var channel: Dictionary = CHANNELS[_channel_index]
	var place: Array = Diagrams.where(int(channel["id"]), mode)
	var instruction: String = "Move the %s stick fully %s" % [place[0],
			"up and down" if place[1] == "v" else "left and right"]
	UI.draw_display(_canvas, body.position + Vector2(0, 76.0), instruction, UI.SIZE_H2, UI.TEXT)
	UI.draw_text(_canvas, body.position + Vector2(0, 116.0),
			"%s Use the full travel, let go, then press Confirm." % String(channel["hint"]),
			UI.SIZE_BODY, UI.TEXT_DIM)

	var top: float = body.position.y + 168.0
	var x: float = body.position.x
	UI.draw_label(_canvas, Vector2(x, top + 18.0), "what it is sending", UI.TEXT_DIM)
	var rows: int = clampi(_input.get_axis_count(), 4, 8)
	_draw_axes(Vector2(x, top + 34.0), rows, true)
	var y: float = top + 34.0 + float(rows) * 26.0 + 30.0
	for i in _bound_axis.size():
		UI.draw_check(_canvas, Vector2(x + 7.0, y - 6.0), 14.0, UI.GOOD)
		UI.draw_text(_canvas, Vector2(x + 24.0, y), "%s  ·  axis %d" % [CHANNELS[i]["name"], _bound_axis[i]],
				UI.SIZE_BODY_S, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold())
		y += 26.0
	if _asking_thumb():
		_thumb_rects = Diagrams.draw_thumb_question(_canvas, Vector2(x, maxf(y + 4.0, top + 300.0)),
				560.0, "Which thumb is that?", mode, _hover_thumb, false)

	var well: Rect2 = _right_well(body, 560.0)
	var pic: Rect2 = Rect2(well.position + Vector2(UI.S5, UI.S5), well.size - Vector2(UI.S5 * 2.0, UI.S5 + 70.0))
	Diagrams.draw_transmitter(_canvas, pic, mode, PackedFloat64Array(), place, _phase, true)

	# Capture meter, under the lit gate: fills as the travel is captured.
	var lay: Dictionary = Diagrams.transmitter_layout(pic, true)
	var gx: float = (lay[place[0]] as Vector2).x
	var moved: int = _input.identify_moved_axis()
	var travel: float = 0.0
	if moved >= 0 and not moved in _bound_axis:
		travel = _input.get_axis_travel(moved)
	var frac: float = clampf(travel / FULL_TRAVEL, 0.0, 1.0)
	var meter := Rect2(gx - 120.0, well.end.y - 40.0, 240.0, 6.0)
	UI.draw_track(_canvas, meter, frac, UI.GOOD if frac >= 1.0 else UI.ACCENT)
	var cap: String = "travel captured" if frac >= 1.0 else "capturing travel"
	var cw: float = UI.label_width(cap)
	UI.draw_label(_canvas, Vector2(gx - cw * 0.5, meter.position.y - 12.0), cap,
			UI.GOOD if frac >= 1.0 else UI.TEXT_DIM)


## The words for the movement that should fill a channel's bar to the right.
func _action_text(index: int, mode: int) -> String:
	var place: Array = Diagrams.where(int(CHANNELS[index]["id"]), mode)
	var side: String = String(place[0]).capitalize()
	match String(CHANNELS[index]["action"]):
		"back": return "%s stick back" % side
		"up": return "%s stick up" % side
	return "%s stick right" % side


## 0 up, 1 right, 2 down (towards you) on the picture.
func _action_dir(index: int) -> int:
	match String(CHANNELS[index]["action"]):
		"back": return 2
		"up": return 0
	return 1


## "good" when the first movement in the sweep went the way the hint asked,
## "warn" when it went the other way, "" when there is nothing to go on.
func _direction_check(index: int) -> String:
	var first: int = _channel_first[index]
	if first == 0:
		return ""
	var id: int = CHANNELS[index]["id"]
	var sign: int = first * (-1 if _input.get_channel_reversed(id) else 1)
	return "good" if sign == int(CHANNELS[index]["first"]) else "warn"


func _draw_review(body: Rect2, mode: int) -> void:
	_heading(body, "Check each stick",
			"Move each stick as its row says: the bar should fill towards the arrow.")
	var top: float = body.position.y + 168.0
	var y: float = _draw_channels(Vector2(body.position.x, top), 700.0, mode, true)
	for line in UI.wrap_text("If a bar fills the wrong way, select its row and press Reverse.",
			700.0, UI.SIZE_BODY_S):
		UI.draw_text(_canvas, Vector2(body.position.x, y + 22.0), line, UI.SIZE_BODY_S, UI.TEXT_DIM)
		y += 24.0
	var well: Rect2 = _right_well(body, 700.0)
	Diagrams.draw_transmitter(_canvas, well.grow(-UI.S4), mode, _input.get_channels(), [],
			_phase, true)


func _draw_done(body: Rect2, mode: int) -> void:
	_heading(body, "Ready to fly",
			"Saved. These settings load every time this transmitter is plugged in.", "check", UI.GOOD)
	var top: float = body.position.y + 168.0
	_draw_channels(Vector2(body.position.x, top), 700.0, mode, false)
	var well: Rect2 = _right_well(body, 700.0)
	Diagrams.draw_transmitter(_canvas, well.grow(-UI.S4), mode, _input.get_channels(), [],
			_phase, true)


## Raw axes, live. `highlight` marks the one that has moved furthest, which is
## the one about to be bound.
func _draw_axes(origin: Vector2, count: int, highlight: bool = false) -> void:
	var moved: int = _input.identify_moved_axis() if highlight else -1
	for axis in mini(count, _input.get_axis_count()):
		var y: float = float(axis) * 26.0
		var active: bool = axis == moved
		var bound: bool = highlight and axis in _bound_axis
		var colour: Color = UI.ACCENT if active else (UI.TEXT_FAINT if bound else UI.TEXT_DIM)
		UI.draw_label(_canvas, origin + Vector2(0, y + 14), "axis %d" % axis,
				UI.ACCENT_HI if active else UI.TEXT_DIM)
		UI.draw_bipolar_track(_canvas, Rect2(origin + Vector2(76, y + 6), Vector2(300, 8)),
				_input.get_raw_axis(axis), colour)
		if highlight and not bound:
			var travel: float = _input.get_axis_travel(axis)
			UI.draw_numeral(_canvas, origin + Vector2(440, y + 15), "%.2f" % travel, UI.SIZE_BODY_S,
					UI.GOOD if travel > REQUIRED_TRAVEL else UI.TEXT_DIM, true, false)
		elif bound:
			UI.draw_label(_canvas, origin + Vector2(392, y + 14), "bound", UI.TEXT_FAINT)


## The bound channels: name, the movement to make, a live bar with the
## expected end marked, and the direction check. Returns the y below.
func _draw_channels(origin: Vector2, width: float, mode: int, selectable: bool) -> float:
	var channels: PackedFloat64Array = _input.get_channels()
	var pitch: float = 60.0
	for i in CHANNELS.size():
		var id: int = CHANNELS[i]["id"]
		var y: float = origin.y + float(i) * pitch
		var row := Rect2(origin.x - 14.0, y, width + 14.0, 52.0)
		_row_rects.append(row)
		if selectable and i == _review_index:
			_canvas.draw_colored_polygon(UI.rounded_rect(row, UI.R_MD), Color(UI.ACCENT_DEEP, 0.55))
			var e: PackedVector2Array = UI.rounded_rect(row, UI.R_MD)
			e.append(e[0])
			_canvas.draw_polyline(e, UI.ACCENT, UI.STROKE_UI, true)
		elif selectable and i == _hover_row:
			_canvas.draw_colored_polygon(UI.rounded_rect(row, UI.R_MD), Color(1, 1, 1, 0.05))
		var cy: float = y + 26.0
		UI.draw_text(_canvas, Vector2(origin.x, cy + 8.0), String(CHANNELS[i]["name"]), UI.SIZE_BODY,
				UI.TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold())
		# The movement, with its arrow as drawn on the picture.
		var ax: float = origin.x + 120.0
		UI.draw_arrow_glyph(_canvas, Vector2(ax + 8.0, cy), _action_dir(i), 14.0, UI.TEXT_DIM)
		UI.draw_text(_canvas, Vector2(ax + 26.0, cy + 6.0), _action_text(i, mode), UI.SIZE_BODY_S,
				UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold())
		# The bar: the expected end is the right one, marked with a chevron
		# that lights when the stick gets there.
		var bar := Rect2(origin.x + 330.0, cy - 4.0, 200.0, 8.0)
		var value: float = channels[id]
		var reached: bool
		if id == RCInputNode.CHANNEL_THROTTLE:
			UI.draw_track(_canvas, bar, clampf(value, 0.0, 1.0))
			reached = value > 0.75
		else:
			UI.draw_bipolar_track(_canvas, bar, value)
			reached = value > 0.5
		UI.draw_chevron(_canvas, Vector2(bar.end.x + 16.0, cy), 1, 14.0,
				UI.GOOD if reached else UI.TEXT_FAINT)
		# Direction check from the sweep.
		var check: String = _direction_check(i)
		var tx: float = origin.x + 566.0
		if check == "good":
			UI.draw_tag(_canvas, Vector2(tx, cy), "matches", "good")
		elif check == "warn":
			UI.draw_tag(_canvas, Vector2(tx, cy), "reversed?", "warn")
		elif _input.get_channel_reversed(id):
			UI.draw_tag(_canvas, Vector2(tx, cy), "reversed", "state")
	return origin.y + float(CHANNELS.size()) * pitch
