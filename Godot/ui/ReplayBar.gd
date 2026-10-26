# OpenRC Simulator - watching it again.
#
# The recorder runs continuously, so there is nothing to start. Press the key
# and the last two minutes are there to scrub through - and if the model has
# just crashed, it opens six seconds before the impact, because that is what
# anybody wants to see.
#
# The camera is NOT taken over. The whole value of a replay in a flight
# simulator is being able to fly the camera around a moment that has already
# happened - to watch a landing from the wingtip, or a stall from behind. So the
# camera rig keeps working and this only poses the aircraft.
extends CanvasLayer

const UITheme := preload("res://ui/UITheme.gd")

## "again" (Fly again, R) or "air" (Try from the air, T): the two buttons at the
## bar's right end - the same ids as the crash card's. If nothing is connected,
## a click presses the key instead, so the bar works before it is wired.
signal action_chosen(id: String)

const SPEEDS: Array[float] = [-1.0, -0.35, 0.0, 0.15, 0.35, 1.0, 2.0]
const DEFAULT_SPEED_INDEX: int = 4
const BAR_H: float = 104.0
const PAD: float = 24.0
const ACTIONS: Array = [["again", "Fly again", "R"], ["air", "Try from the air", "T"]]

@export var simulation_path: NodePath

var _sim: RCSimulationNode
var _canvas: Control
var _speed_index: int = DEFAULT_SPEED_INDEX
var _events: Array[Dictionary] = []
## Hit areas for the two buttons: small Controls of their own, so the rest of
## the bar lets the pointer through to the camera's look-around drag.
var _hit_areas: Array[Control] = []
var _hover: int = -1
var _pressed: int = -1


func _ready() -> void:
	layer = 20
	_sim = get_node_or_null(simulation_path) as RCSimulationNode

	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_bar)
	add_child(_canvas)
	for i in ACTIONS.size():
		var area := Control.new()
		area.name = "Button_%s" % ACTIONS[i][0]
		area.mouse_filter = Control.MOUSE_FILTER_STOP
		area.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		area.gui_input.connect(_on_button_input.bind(i))
		area.mouse_entered.connect(func() -> void: _hover = i)
		area.mouse_exited.connect(func() -> void:
			if _hover == i:
				_hover = -1
			_pressed = -1)
		add_child(area)
		_hit_areas.append(area)

	if _sim != null:
		# Events first: gathering them scrubs the replay time about, so it has
		# to happen before the opening position is chosen.
		_sim.set_replaying(true)
		var opened_at: float = _sim.get_replay_time()
		_gather_events()
		_sim.set_replay_time(opened_at)
		_speed_index = DEFAULT_SPEED_INDEX
		_sim.set_replay_speed(SPEEDS[_speed_index])


func _on_button_input(event: InputEvent, index: int) -> void:
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if event.pressed:
		_pressed = index
	elif _pressed == index:
		_pressed = -1
		_choose(String(ACTIONS[index][0]))


func _choose(id: String) -> void:
	if not action_chosen.get_connections().is_empty():
		action_chosen.emit(id)
		return
	# Not wired: press the key, which Flight.gd already answers.
	var key := InputEventKey.new()
	key.keycode = KEY_R if id == "again" else KEY_T
	key.pressed = true
	Input.parse_input_event(key)


func _exit_tree() -> void:
	if _sim != null:
		_sim.set_replaying(false)


func _process(_delta: float) -> void:
	_canvas.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if _sim == null or not (event is InputEventKey and event.pressed):
		return
	var key: int = (event as InputEventKey).keycode
	var step: float = 0.25 if (event as InputEventKey).shift_pressed else 1.0

	match key:
		KEY_LEFT:
			_sim.set_replay_time(_sim.get_replay_time() - step)
		KEY_RIGHT:
			_sim.set_replay_time(_sim.get_replay_time() + step)
		KEY_DOWN:
			_speed_index = maxi(0, _speed_index - 1)
			_sim.set_replay_speed(SPEEDS[_speed_index])
		KEY_UP:
			_speed_index = mini(SPEEDS.size() - 1, _speed_index + 1)
			_sim.set_replay_speed(SPEEDS[_speed_index])
		KEY_SPACE:
			# Play/pause on the same key, remembering the rate it was running at.
			if is_equal_approx(SPEEDS[_speed_index], 0.0):
				_speed_index = DEFAULT_SPEED_INDEX
			else:
				_speed_index = SPEEDS.find(0.0)
			_sim.set_replay_speed(SPEEDS[_speed_index])
		KEY_C:
			_sim.replay_to_crash()
		KEY_HOME:
			_sim.set_replay_time(_sim.get_replay_earliest())
		KEY_END:
			_sim.set_replay_time(_sim.get_replay_latest())
		_:
			return
	get_viewport().set_input_as_handled()


func _draw_bar() -> void:
	if _sim == null or _sim.get_replay_duration() <= 0.05:
		for area in _hit_areas:
			area.visible = false
		return

	var size: Vector2 = _canvas.size
	var width: float = minf(size.x - 80.0, 1100.0)
	var panel := Rect2(roundf((size.x - width) * 0.5), size.y - UITheme.HUD_M - BAR_H,
			width, BAR_H)
	UITheme.draw_modal(_canvas, panel)

	# The two ways out, at the right end: buttons, keyed and clickable.
	var bx: float = panel.end.x - PAD
	for i in range(ACTIONS.size() - 1, -1, -1):
		var a: Array = ACTIONS[i]
		var w: float = UITheme.font_label().get_string_size(String(a[1]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x + 12.0 + UITheme.keycap_width(a[2], UITheme.SIZE_KEY) + 40.0
		var r := Rect2(roundf(bx - w), panel.position.y + (BAR_H - 52.0) * 0.5, roundf(w), 52.0)
		UITheme.draw_button_ex(_canvas, r, String(a[1]),
				UITheme.PRIMARY if i == 0 else UITheme.SECONDARY,
				{"hover": _hover == i, "pressed": _pressed == i, "key": a[2], "size": 22})
		_hit_areas[i].visible = true
		_hit_areas[i].position = r.position
		_hit_areas[i].size = r.size
		bx = r.position.x - 12.0
	var left_end: float = bx - PAD

	var first: float = _sim.get_replay_earliest()
	var last: float = _sim.get_replay_latest()
	var now: float = _sim.get_replay_time()
	var span: float = maxf(last - first, 0.001)
	var x: float = panel.position.x + PAD

	UITheme.draw_label(_canvas, Vector2(x, panel.position.y + 30.0), "Replay", UITheme.TEXT_DIM)
	var speed: float = SPEEDS[_speed_index]
	var paused: bool = is_equal_approx(speed, 0.0)
	var speed_text: String = "paused" if paused else "%s×" % _speed_string(speed)
	UITheme.draw_text(_canvas, Vector2(x + UITheme.label_width("Replay") + 14.0,
			panel.position.y + 31.0), speed_text, UITheme.SIZE_BODY_S,
			UITheme.TEXT_DIM if paused else UITheme.ACCENT_HI, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			false, UITheme.font_semibold())
	# Time relative to the end, because that is how a pilot thinks about it:
	# "eight seconds ago", not "at t = 412".
	UITheme.draw_text(_canvas, Vector2(x, panel.position.y + 32.0), "%.1f s ago" % (last - now),
			UITheme.SIZE_BODY, UITheme.TEXT, HORIZONTAL_ALIGNMENT_RIGHT, left_end - x, false,
			UITheme.font_semibold())

	# The track.
	var track := Rect2(x, panel.position.y + 48.0, left_end - x, 6.0)
	_canvas.draw_colored_polygon(UITheme.rounded_rect(track, 3.0), Color(1, 1, 1, 0.12))
	# Where the aircraft was on the ground, and where it crashed. A pilot
	# scrubbing to find a landing looks for the marks, not the numbers.
	_draw_events(track, first, span)
	var head: float = track.position.x + track.size.x * ((now - first) / span)
	if head - track.position.x > 1.0:
		_canvas.draw_colored_polygon(UITheme.rounded_rect(Rect2(track.position,
				Vector2(head - track.position.x, track.size.y)), 3.0), UITheme.ACCENT_DIM)
	_canvas.draw_rect(Rect2(head - 1.5, track.position.y - 6.0, 3.0, track.size.y + 12.0),
			UITheme.ACCENT)

	UITheme.draw_footer_hints(_canvas, Vector2(x, panel.end.y - 22.0), [
		[["SPACE"], "play / pause"], [["UP", "DOWN"], "speed"], [["LEFT", "RIGHT"], "step"],
		[["C"], "crash"]], UITheme.TEXT_DIM)


static func _speed_string(speed: float) -> String:
	var s: String = "%.2f" % speed
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	return s.trim_suffix(".")


## Marks along the track for the moments worth finding: where the model was on
## the ground, and where it stopped being an aeroplane.
##
## Sampled coarsely on a timer rather than every frame - the recording only
## changes while the aircraft is flying, and this runs while it is not.
func _draw_events(track: Rect2, first: float, span: float) -> void:
	if _events.is_empty():
		return
	for event in _events:
		var x: float = track.position.x + track.size.x * ((event["time"] - first) / span)
		if event["kind"] == "crash":
			_canvas.draw_rect(Rect2(x - 1.5, track.position.y - 6.0, 3.0, track.size.y + 12.0),
					UITheme.DANGER)
		else:
			_canvas.draw_rect(Rect2(x - 1.0, track.position.y - 3.0, 2.0, track.size.y + 6.0),
					UITheme.GOOD)


## Walk the recording once and note the transitions. Cheap, and only done when
## the replay opens or the recording has grown.
func _gather_events() -> void:
	_events.clear()
	if _sim == null:
		return

	var first: float = _sim.get_replay_earliest()
	var last: float = _sim.get_replay_latest()
	if last - first < 0.05:
		return

	var was_ground: bool = true
	var was_crashed: bool = false
	var steps: int = 400
	for i in steps + 1:
		var t: float = first + (last - first) * (float(i) / float(steps))
		_sim.set_replay_time(t)
		var frame: Dictionary = _sim.get_replay_frame()
		var on_ground: bool = frame.get("on_ground", false)
		var crashed: bool = frame.get("crashed", false)
		if on_ground and not was_ground:
			_events.append({"time": t, "kind": "touchdown"})
		if crashed and not was_crashed:
			_events.append({"time": t, "kind": "crash"})
		was_ground = on_ground
		was_crashed = crashed
