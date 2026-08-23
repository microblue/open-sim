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
# All the arithmetic lives in RCPhysics/Input, where it is tested without a
# device attached. This is only the conversation.
extends CanvasLayer

signal finished(saved: bool)

const PROFILE_PATH: String = "user://controller.json"
const CENTRE_SECONDS: float = 1.2
const REQUIRED_TRAVEL: float = 0.45

enum Step { DETECT, CENTRE, SWEEP, REVIEW, DONE }

const CHANNELS: Array = [
	{"id": RCInputNode.CHANNEL_AILERON,  "name": "Aileron",
	 "hint": "roll fully left, then fully right"},
	{"id": RCInputNode.CHANNEL_ELEVATOR, "name": "Elevator",
	 "hint": "pull all the way back, then push all the way forward"},
	{"id": RCInputNode.CHANNEL_THROTTLE, "name": "Throttle",
	 "hint": "all the way up, then all the way down"},
	{"id": RCInputNode.CHANNEL_RUDDER,   "name": "Rudder",
	 "hint": "full left, then full right"},
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


func _ready() -> void:
	layer = 24
	_input = get_node_or_null(input_path) as RCInputNode

	add_child(UITheme.make_frosted(0.80, 3.0))

	_canvas = Control.new()
	_canvas.anchor_right = 1.0
	_canvas.anchor_bottom = 1.0
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_wizard)
	add_child(_canvas)

	_restart()


func _restart() -> void:
	_step = Step.DETECT
	_channel_index = 0
	_timer = 0.0
	_bound_axis.clear()
	_set_message("")
	if _input != null:
		_input.reset_capture()


func _set_message(text: String) -> void:
	_message = text
	_message_age = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	match event.keycode:
		KEY_ESCAPE:
			finished.emit(false)
			queue_free()
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			_advance()
		KEY_BACKSPACE:
			_restart()
		KEY_R:
			if _step == Step.REVIEW or _step == Step.SWEEP:
				var index: int = mini(_channel_index, CHANNELS.size() - 1)
				var id: int = CHANNELS[index]["id"]
				_input.set_channel_reversed(id, not _input.get_channel_reversed(id))
		KEY_S:
			if _step == Step.REVIEW:
				_save()


func _advance() -> void:
	match _step:
		Step.DETECT:
			if _input != null and _input.is_connected():
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
		_set_message("Not sure which axis that was - sweep it again, on its own.")
		return
	if axis in _bound_axis:
		_set_message("That axis is already bound to another channel.")
		return
	if _input.get_axis_travel(axis) < REQUIRED_TRAVEL:
		_set_message("That did not move far enough - use the full throw.")
		return

	if not _input.bind_channel(CHANNELS[_channel_index]["id"], axis):
		_set_message("That axis could not be calibrated - try again.")
		return

	_bound_axis.append(axis)
	_set_message("")
	_channel_index += 1

	if _channel_index >= CHANNELS.size():
		_input.end_capture()
		_step = Step.REVIEW
	else:
		_input.reset_travel()


func _save() -> void:
	if _input.save_profile(PROFILE_PATH):
		_step = Step.DONE
		_set_message("")
	else:
		_set_message("Could not write the profile.")


func _process(delta: float) -> void:
	_appear = minf(_appear + delta * 3.4, 1.0)
	_message_age += delta

	if _input != null and _step == Step.CENTRE:
		_timer += delta
		if _timer >= CENTRE_SECONDS:
			_input.end_capture()
			_input.reset_travel()
			_input.begin_capture(false)
			_step = Step.SWEEP

	_canvas.queue_redraw()


# ---------------------------------------------------------------- drawing ---

func _draw_wizard() -> void:
	if _input == null:
		return
	var size: Vector2 = _canvas.size
	var ease_in: float = 1.0 - pow(1.0 - _appear, 3.0)

	var card := Rect2(Vector2(size.x * 0.5 - 380.0,
							  size.y * 0.5 - 250.0 + (1.0 - ease_in) * 20.0),
					  Vector2(760, 500))
	UITheme.draw_panel(_canvas, card, UITheme.PANEL_SOLID, UITheme.STROKE_STRONG, 14.0)

	var origin: Vector2 = card.position + Vector2(UITheme.S6, UITheme.S6)

	UITheme.draw_label(_canvas, origin + Vector2(0, 8), "transmitter setup",
					   UITheme.ACCENT, 3.0, UITheme.SIZE_LABEL)
	_draw_progress(origin + Vector2(0, 30), card.size.x - UITheme.S6 * 2.0)

	match _step:
		Step.DETECT: _draw_detect(origin + Vector2(0, 84))
		Step.CENTRE: _draw_centre(origin + Vector2(0, 84))
		Step.SWEEP:  _draw_sweep(origin + Vector2(0, 84), card)
		Step.REVIEW: _draw_review(origin + Vector2(0, 84))
		Step.DONE:   _draw_done(origin + Vector2(0, 84))

	if _message != "":
		var pulse: float = clampf(1.0 - _message_age * 0.25, 0.35, 1.0)
		UITheme.draw_text(_canvas,
			Vector2(origin.x, card.end.y - 66.0), _message,
			UITheme.SIZE_LABEL, Color(UITheme.WARN.r, UITheme.WARN.g,
									  UITheme.WARN.b, pulse))

	UITheme.draw_rule(_canvas, Vector2(origin.x, card.end.y - 46.0),
					  card.size.x - UITheme.S6 * 2.0)
	UITheme.draw_text(_canvas, Vector2(origin.x, card.end.y - 24.0),
					  _footer(), UITheme.SIZE_LABEL, UITheme.TEXT_FAINT)


## Six segments, one per stage, filled as they are completed. A setup flow with
## no visible end is one people abandon.
func _draw_progress(origin: Vector2, width: float) -> void:
	var total: int = 2 + CHANNELS.size()
	var done: int = 0
	match _step:
		Step.DETECT: done = 0
		Step.CENTRE: done = 1
		Step.SWEEP:  done = 2 + _channel_index
		_:           done = total

	var gap: float = 6.0
	var segment: float = (width - gap * float(total - 1)) / float(total)
	for i in total:
		var rect := Rect2(origin + Vector2(float(i) * (segment + gap), 0),
						  Vector2(segment, 3))
		_canvas.draw_rect(rect, UITheme.ACCENT if i < done
						  else Color(1, 1, 1, 0.10), true)


func _draw_detect(origin: Vector2) -> void:
	if _input.is_connected():
		UITheme.draw_text(_canvas, origin + Vector2(0, 20), "Controller detected",
						  UITheme.SIZE_LARGE, UITheme.TEXT)
		UITheme.draw_text(_canvas, origin + Vector2(0, 56), _input.get_device_name(),
						  UITheme.SIZE_VALUE, UITheme.ACCENT)
		UITheme.draw_text(_canvas, origin + Vector2(0, 82),
						  "%d axes" % _input.get_axis_count(),
						  UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
		_draw_axes(origin + Vector2(0, 112), 6)
	else:
		UITheme.draw_text(_canvas, origin + Vector2(0, 20), "Waiting for a transmitter",
						  UITheme.SIZE_LARGE, UITheme.TEXT)
		UITheme.draw_text(_canvas, origin + Vector2(0, 58),
						  "Plug the radio in over USB, or switch it to its",
						  UITheme.SIZE_BODY, UITheme.TEXT_DIM)
		UITheme.draw_text(_canvas, origin + Vector2(0, 80),
						  "simulator or joystick mode. This screen will notice.",
						  UITheme.SIZE_BODY, UITheme.TEXT_DIM)


func _draw_centre(origin: Vector2) -> void:
	UITheme.draw_text(_canvas, origin + Vector2(0, 20), "Let the sticks centre",
					  UITheme.SIZE_LARGE, UITheme.TEXT)
	UITheme.draw_text(_canvas, origin + Vector2(0, 58),
					  "Hands off. Capturing the neutral position of every axis.",
					  UITheme.SIZE_BODY, UITheme.TEXT_DIM)

	var fraction: float = clampf(_timer / CENTRE_SECONDS, 0.0, 1.0)
	UITheme.draw_track(_canvas, Rect2(origin + Vector2(0, 86), Vector2(320, 4)),
					   fraction)
	_draw_axes(origin + Vector2(0, 118), 8)


func _draw_sweep(origin: Vector2, card: Rect2) -> void:
	var channel: Dictionary = CHANNELS[_channel_index]

	UITheme.draw_text(_canvas, origin + Vector2(0, 20),
					  "Move %s" % channel["name"], UITheme.SIZE_LARGE, UITheme.TEXT)
	UITheme.draw_text(_canvas, origin + Vector2(0, 56), channel["hint"],
					  UITheme.SIZE_BODY, UITheme.TEXT_DIM)
	UITheme.draw_text(_canvas, origin + Vector2(0, 80),
					  "Use the FULL travel, then press SPACE.",
					  UITheme.SIZE_LABEL, UITheme.TEXT_FAINT)

	_draw_axes(origin + Vector2(0, 116), 8, true)

	# A live gate on the right, so the pilot can see the stick they are moving
	# rather than only a row of bars.
	var gate := Rect2(Vector2(card.end.x - UITheme.S6 - 150.0, origin.y + 24.0),
					  Vector2(150, 150))
	var channels: PackedFloat64Array = _input.get_channels()
	UITheme.draw_stick_gate(_canvas, gate, channels[0], channels[1])
	UITheme.draw_label(_canvas, gate.position + Vector2(0, 168), "bound so far")
	for i in _bound_axis.size():
		UITheme.draw_text(_canvas, gate.position + Vector2(0, 190.0 + float(i) * 18.0),
						  "%s  ->  axis %d" % [CHANNELS[i]["name"], _bound_axis[i]],
						  UITheme.SIZE_LABEL, UITheme.GOOD)


func _draw_review(origin: Vector2) -> void:
	UITheme.draw_text(_canvas, origin + Vector2(0, 20), "Check each channel",
					  UITheme.SIZE_LARGE, UITheme.TEXT)
	UITheme.draw_text(_canvas, origin + Vector2(0, 56),
					  "Move the sticks. If a bar goes the wrong way, select it and press R.",
					  UITheme.SIZE_BODY, UITheme.TEXT_DIM)
	_draw_channels(origin + Vector2(0, 92))


func _draw_done(origin: Vector2) -> void:
	UITheme.draw_text(_canvas, origin + Vector2(0, 20), "Ready to fly",
					  UITheme.SIZE_LARGE, UITheme.GOOD)
	UITheme.draw_text(_canvas, origin + Vector2(0, 56),
					  "Saved. This screen will be skipped from now on.",
					  UITheme.SIZE_BODY, UITheme.TEXT_DIM)
	_draw_channels(origin + Vector2(0, 92))


## Raw axes, live. `highlight` marks the one that has moved furthest, which is
## the one about to be bound.
func _draw_axes(origin: Vector2, count: int, highlight: bool = false) -> void:
	var moved: int = _input.identify_moved_axis() if highlight else -1
	for axis in mini(count, _input.get_axis_count()):
		var y: float = float(axis) * 22.0
		var active: bool = axis == moved
		var colour: Color = UITheme.ACCENT if active else UITheme.TEXT_DIM

		UITheme.draw_label(_canvas, origin + Vector2(0, y + 10), "axis %d" % axis,
						   UITheme.TEXT_FAINT if not active else UITheme.ACCENT)
		UITheme.draw_bipolar_track(_canvas,
			Rect2(origin + Vector2(56, y + 2), Vector2(220, 8)),
			_input.get_raw_axis(axis), colour)
		if highlight:
			var travel: float = _input.get_axis_travel(axis)
			UITheme.draw_text(_canvas, origin + Vector2(288, y + 11),
							  "%.2f" % travel, UITheme.SIZE_LABEL,
							  UITheme.GOOD if travel > REQUIRED_TRAVEL
							  else UITheme.TEXT_FAINT)


func _draw_channels(origin: Vector2) -> void:
	var channels: PackedFloat64Array = _input.get_channels()
	for i in CHANNELS.size():
		var id: int = CHANNELS[i]["id"]
		var y: float = float(i) * 34.0
		var reversed_flag: bool = _input.get_channel_reversed(id)

		UITheme.draw_text(_canvas, origin + Vector2(0, y + 14), CHANNELS[i]["name"],
						  UITheme.SIZE_BODY, UITheme.TEXT)
		UITheme.draw_bipolar_track(_canvas,
			Rect2(origin + Vector2(110, y + 5), Vector2(300, 9)), channels[id])
		UITheme.draw_text(_canvas, origin + Vector2(424, y + 14),
						  "%+.2f" % channels[id], UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
		if reversed_flag:
			UITheme.draw_label(_canvas, origin + Vector2(480, y + 14), "reversed",
							   UITheme.WARN)


func _footer() -> String:
	match _step:
		Step.DETECT: return "SPACE begin      ESC cancel"
		Step.CENTRE: return "hands off"
		Step.SWEEP:  return "SPACE confirm      R reverse      BACKSPACE start over      ESC cancel"
		Step.REVIEW: return "S save      R reverse      BACKSPACE start over      ESC cancel"
		_:           return "SPACE fly"
	return ""
