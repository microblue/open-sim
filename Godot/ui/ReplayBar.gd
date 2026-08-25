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

const SPEEDS: Array[float] = [-1.0, -0.35, 0.0, 0.15, 0.35, 1.0, 2.0]
const DEFAULT_SPEED_INDEX: int = 4

@export var simulation_path: NodePath

var _sim: RCSimulationNode
var _canvas: Control
var _speed_index: int = DEFAULT_SPEED_INDEX
var _events: Array[Dictionary] = []


func _ready() -> void:
	layer = 20
	_sim = get_node_or_null(simulation_path) as RCSimulationNode

	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_bar)
	add_child(_canvas)

	if _sim != null:
		# Events first: gathering them scrubs the replay time about, so it has
		# to happen before the opening position is chosen.
		_sim.set_replaying(true)
		var opened_at: float = _sim.get_replay_time()
		_gather_events()
		_sim.set_replay_time(opened_at)
		_speed_index = DEFAULT_SPEED_INDEX
		_sim.set_replay_speed(SPEEDS[_speed_index])


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
		return

	var size: Vector2 = _canvas.size
	var width: float = minf(size.x * 0.68, 900.0)
	var panel := Rect2((size.x - width) * 0.5, size.y - 118.0, width, 84.0)
	UITheme.draw_panel(_canvas, panel, UITheme.PANEL_SOLID, UITheme.ACCENT)

	var first: float = _sim.get_replay_earliest()
	var last: float = _sim.get_replay_latest()
	var now: float = _sim.get_replay_time()
	var span: float = maxf(last - first, 0.001)

	UITheme.draw_label(_canvas, panel.position + Vector2(22.0, 24.0), "REPLAY",
			UITheme.ACCENT, 2.6, UITheme.SIZE_LABEL)

	# Time relative to the end, because that is how a pilot thinks about it:
	# "eight seconds ago", not "at t = 412".
	UITheme.draw_text(_canvas, panel.position + Vector2(panel.size.x - 22.0, 26.0),
			"%.1f s ago" % (last - now), UITheme.SIZE_BODY, UITheme.TEXT,
			HORIZONTAL_ALIGNMENT_RIGHT)

	# The track.
	var track := Rect2(panel.position.x + 22.0, panel.position.y + 40.0,
					   panel.size.x - 44.0, 8.0)
	_canvas.draw_rect(track, Color(1, 1, 1, 0.10))

	# Where the aircraft was on the ground, and where it crashed. A pilot
	# scrubbing to find a landing looks for the marks, not the numbers.
	_draw_events(track, first, span)

	var head: float = track.position.x + track.size.x * ((now - first) / span)
	_canvas.draw_rect(Rect2(track.position, Vector2(head - track.position.x, track.size.y)),
			UITheme.ACCENT_DIM)
	_canvas.draw_rect(Rect2(head - 1.5, track.position.y - 5.0, 3.0, track.size.y + 10.0),
			UITheme.ACCENT)

	var speed: float = SPEEDS[_speed_index]
	var speed_text: String = "paused" if is_equal_approx(speed, 0.0) else "%.2fx" % speed
	UITheme.draw_text(_canvas, panel.position + Vector2(22.0, panel.size.y - 14.0),
			"space  play / pause      up / down  %s      left / right  step      c  crash      r  fly again"
					% speed_text,
			UITheme.SIZE_LABEL, UITheme.TEXT_DIM)


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
		var colour: Color = UITheme.DANGER if event["kind"] == "crash" else UITheme.GOOD
		_canvas.draw_rect(Rect2(x - 1.0, track.position.y - 3.0, 2.0, track.size.y + 6.0),
				colour)


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
