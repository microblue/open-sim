# OpenRC Simulator - the card that says why it crashed.
#
# This is the one crash surface: there is no CRASHED banner over it. It says
# WHY, in one line, what to do differently, in a box of its own, and offers the
# three ways on from here as real buttons - fly again, try again from the air,
# or watch what happened - each with its key, each clickable. The reason is read
# from the last seconds of the flight recorder by the physics core
# (RCPhysics/Training/CrashAnalysis.h), so it is always something the pilot can
# go and see in the replay.
#
# It appears 0.6 s after the impact: enough to see the tumble begin, and R
# works at any point, so nobody waits for the card.
#
# Contract with Flight.gd:
#   signal action_chosen(id)  "again" (R), "air" (T) or "replay" (Tab) - from a
#                             click on a button, or Enter for the primary one.
#                             The keys themselves stay with Flight.gd.
#   var context               {"flight": int, "air_time_s": float, "repeat": int,
#                             "first_crash": bool, "primary": "again"|"air",
#                             "step_label": String}. All optional.
extends Control

const UI := preload("res://ui/UITheme.gd")
const Settings := preload("res://ui/Settings.gd")

signal action_chosen(id: String)

## Seconds after the crash before the card fades in.
const DELAY: float = 0.6
const FADE: float = 0.28
const RISE: float = 10.0
const WIDTH: float = 720.0
const PAD: float = 28.0
const ORDINALS: Array = ["", "First", "Second", "Third", "Fourth", "Fifth", "Sixth"]

## Set by Flight.gd before or while the card shows; read every draw.
var context: Dictionary = {}

var _sim: Node = null
var _report: Dictionary = {}
var _since: float = -1.0
var _alpha: float = 0.0
var _phase: float = 0.0
## [rect, id] per button, rebuilt each draw; empty while hidden.
var _buttons: Array = []
var _hover: String = ""
var _pressed: String = ""
var _marked_first: bool = false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# STOP, but _has_point only claims the button rects: a click anywhere else
	# goes on through to the world (the camera's look-around drag).
	mouse_filter = Control.MOUSE_FILTER_STOP


func bind(simulation: Node) -> void:
	_sim = simulation


## The report as a pure layout input, so a test can render a card without a
## crash. Pass an empty dictionary to hide it.
func show_report(report: Dictionary) -> void:
	_report = report
	_since = 0.0 if not report.is_empty() else -1.0
	_alpha = 0.0
	modulate.a = 0.0
	_buttons.clear()
	_hover = ""
	_pressed = ""
	_marked_first = false
	queue_redraw()


## True while the card is up (faded in far enough to be read and clicked).
func is_showing() -> bool:
	return not _report.is_empty() and _alpha > 0.5


func _has_point(point: Vector2) -> bool:
	if not is_showing():
		return false
	for b in _buttons:
		if (b[0] as Rect2).has_point(point):
			return true
	return false


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var over: String = _button_at(event.position)
		if over != _hover:
			_hover = over
			queue_redraw()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var hit: String = _button_at(event.position)
		if event.pressed:
			_pressed = hit
		elif not hit.is_empty() and hit == _pressed:
			_pressed = ""
			action_chosen.emit(hit)
		else:
			_pressed = ""
		accept_event()
		queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and not _hover.is_empty():
		_hover = ""
		_pressed = ""
		queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not is_showing() or not (event is InputEventKey and event.pressed and not event.echo):
		return
	if (event as InputEventKey).keycode in [KEY_ENTER, KEY_KP_ENTER]:
		get_viewport().set_input_as_handled()
		action_chosen.emit(_primary())


func _button_at(point: Vector2) -> String:
	for b in _buttons:
		if (b[0] as Rect2).has_point(point):
			return String(b[1])
	return ""


func _primary() -> String:
	return "air" if String(context.get("primary", "again")) == "air" else "again"


func _first_crash() -> bool:
	if context.has("first_crash"):
		return bool(context["first_crash"])
	return not bool(Settings.get_value("onboarding/first_crash_seen"))


func _process(delta: float) -> void:
	# A Control directly under a CanvasLayer has no parent rect for its anchors
	# to follow, so it sizes itself to the viewport rather than staying 0 x 0.
	var viewport_size: Vector2 = get_viewport_rect().size
	if size != viewport_size:
		size = viewport_size
		queue_redraw()
	if _sim != null:
		var crashed: bool = _sim.has_crashed() and not _sim.get_replaying()
		if crashed and _report.is_empty():
			show_report(_sim.get_crash_report())
		elif not crashed and not _report.is_empty():
			show_report({})
	if _since < 0.0:
		return
	_since += delta
	_phase += delta
	var target: float = clampf((_since - DELAY) / FADE, 0.0, 1.0)
	if Settings.reduced_motion():
		target = 1.0 if _since >= DELAY else 0.0
	if not is_equal_approx(target, _alpha):
		_alpha = target
		modulate.a = _alpha
		queue_redraw()
	elif _alpha > 0.0 and _first_crash():
		queue_redraw()                # the replay button's one-time pulse
	if _alpha >= 1.0 and _first_crash() and not _marked_first:
		# Seen once: the teaching line is never shown again.
		_marked_first = true
		Settings.set_value("onboarding/first_crash_seen", true)


# ----------------------------------------------------------------- drawing --

## The card fades as a whole through `modulate`; colours are drawn as they are.
func _fade(c: Color) -> Color:
	return c


## The numbers after "CRASHED" on the overline: onset height and impact speed,
## in the pilot's units. Mixed case, so "m/s" is not shouted as "M/S".
func _overline() -> String:
	var parts: Array = []
	var system: String = Settings.units()
	if _report.has("onset_height_m") and float(_report["onset_height_m"]) >= 1.0:
		var h: PackedStringArray = Settings.format_height(float(_report["onset_height_m"]), system)
		parts.append("%s %s" % [h[0], h[1]])
	var speed_key: String = "impact_speed_mps" if _report.has("impact_speed_mps") else "airspeed_mps"
	if _report.has(speed_key) and float(_report[speed_key]) > 0.5:
		var s: PackedStringArray = Settings.format_speed(float(_report[speed_key]), system)
		parts.append("%s %s" % [s[0], s[1]])
	return "  ·  ".join(parts)


func _meta() -> String:
	if not context.has("flight"):
		return ""
	var line: String = "Flight %d" % int(context["flight"])
	if context.has("air_time_s"):
		var t: int = int(round(float(context["air_time_s"])))
		line += "  ·  %d:%02d in the air" % [t / 60, t % 60]
	return line


func _repeat_line(title: String) -> String:
	var n: int = int(context.get("repeat", 0))
	if n < 3:
		return ""
	var word: String = ORDINALS[n] if n < ORDINALS.size() else "%dth" % n
	return "%s %s this session. Try again in the air (T) and practise it at a safe height." \
			% [word, title.to_lower()]


func _button_specs() -> Array:
	var again_label: String = String(context.get("step_label", ""))
	if again_label.is_empty():
		again_label = "Fly again"
	var primary: String = _primary()
	return [
		["again", again_label, "R", UI.PRIMARY if primary == "again" else UI.SECONDARY],
		["air", "Try again in the air", "T", UI.PRIMARY if primary == "air" else UI.SECONDARY],
		["replay", "Watch the replay", "TAB", UI.SECONDARY],
	]


func _button_width(label: String, key: String, size: int) -> float:
	return UI.font_label().get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x \
			+ 12.0 + UI.keycap_width(key, UI.SIZE_KEY) + 32.0


func _draw() -> void:
	_buttons.clear()
	if _report.is_empty() or _alpha <= 0.0:
		return
	var title: String = String(_report.get("title", "Crashed"))
	var detail: String = String(_report.get("detail", ""))
	var advice: String = String(_report.get("advice", ""))
	var repeat: String = _repeat_line(title)
	var teach: bool = _first_crash()

	var inner: float = WIDTH - 2.0 * PAD
	var body_size: int = 20
	var body_pitch: float = 27.0
	var detail_lines: PackedStringArray = UI.wrap_text(detail, inner, body_size)
	if detail_lines.size() > 3:
		detail_lines = detail_lines.slice(0, 3)
	var advice_size: int = 19
	var advice_pitch: float = 25.0
	var box_inner: float = inner - 16.0 * 2.0 - 3.0
	var advice_lines: PackedStringArray = UI.wrap_text(advice, box_inner, advice_size)
	var repeat_lines: PackedStringArray = UI.wrap_text(repeat, box_inner, UI.SIZE_BODY_S) \
			if not repeat.is_empty() else PackedStringArray()

	var box_h: float = 16.0 + 16.0 + 8.0 + advice_lines.size() * advice_pitch + 12.0
	if not repeat_lines.is_empty():
		box_h += 6.0 + repeat_lines.size() * 24.0
	var height: float = PAD + 16.0 + 18.0 + 40.0 + 6.0 \
			+ detail_lines.size() * body_pitch + 18.0 + box_h + 20.0 + 52.0 + PAD
	if teach:
		height += 34.0

	var rise: float = (1.0 - UI.ease_out(_alpha)) * RISE
	var origin := Vector2(roundf((size.x - WIDTH) * 0.5),
			roundf(size.y * 0.60 - height * 0.5 + rise))
	origin.y = clampf(origin.y, UI.S6, maxf(UI.S6, size.y - height - UI.S6))
	var rect := Rect2(origin, Vector2(WIDTH, height))
	UI.draw_modal(self, rect)
	# The danger edge along the top, inside the radius.
	draw_rect(Rect2(origin.x + UI.R_LG, origin.y, WIDTH - UI.R_LG * 2.0, 3.0),
			_fade(UI.DANGER))

	var x: float = origin.x + PAD
	var y: float = origin.y + PAD + 16.0
	# Overline: what happened and how hard, and on the right, which flight.
	UI.draw_warn_triangle(self, Vector2(x + 9.0, y - 6.0), 17.0, _fade(UI.DANGER))
	UI.draw_label(self, Vector2(x + 26.0, y), "Crashed", _fade(UI.DANGER), UI.TRACK_CAPS,
			UI.SIZE_CAPS)
	var numbers: String = _overline()
	if not numbers.is_empty():
		UI.draw_text(self, Vector2(x + 26.0 + UI.label_width("Crashed") + 4.0, y + 1.0),
				"  ·  " + numbers, UI.SIZE_BODY_S, _fade(UI.DANGER), HORIZONTAL_ALIGNMENT_LEFT,
				-1.0, false, UI.font_semibold())
	var meta: String = _meta()
	if not meta.is_empty():
		UI.draw_text(self, Vector2(x, y), meta, UI.SIZE_BODY_S, _fade(UI.TEXT_FAINT),
				HORIZONTAL_ALIGNMENT_RIGHT, inner)
	y += 18.0 + 40.0
	UI.draw_display(self, Vector2(x, y), title, 40, _fade(UI.TEXT))
	y += 6.0
	for line in detail_lines:
		y += body_pitch
		UI.draw_text(self, Vector2(x, y), line, body_size, _fade(UI.TEXT_DIM))
	y += 18.0

	# The advice: the part to remember, in a box of its own.
	var box := Rect2(x, y, inner, box_h)
	draw_colored_polygon(UI.rounded_rect(box, UI.R_MD), _fade(UI.SURFACE_2))
	draw_rect(Rect2(box.position.x, box.position.y + 10.0, 3.0, box_h - 20.0), _fade(UI.ACCENT))
	var bx: float = box.position.x + 3.0 + 16.0
	var by: float = box.position.y + 16.0 + 14.0
	UI.draw_label(self, Vector2(bx, by), "Try this", _fade(UI.ACCENT), UI.TRACK_CAPS, UI.SIZE_CAPS)
	by += 8.0
	for line in advice_lines:
		by += advice_pitch
		UI.draw_text(self, Vector2(bx, by), line, advice_size, _fade(UI.TEXT),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold())
	if not repeat_lines.is_empty():
		by += 6.0
		for line in repeat_lines:
			by += 24.0
			UI.draw_text(self, Vector2(bx, by), line, UI.SIZE_BODY_S, _fade(UI.ACCENT_HI))
	y += box_h + 20.0

	# The three ways on. Natural widths, shrunk together if they overflow.
	var specs: Array = _button_specs()
	var label_size: int = UI.SIZE_BUTTON
	var widths: Array = []
	var total: float = 0.0
	for attempt in 4:
		widths.clear()
		total = 0.0
		for s in specs:
			var w: float = _button_width(String(s[1]), String(s[2]), label_size)
			widths.append(w)
			total += w
		total += 12.0 * float(specs.size() - 1)
		if total <= inner:
			break
		if label_size > 20:
			label_size -= 2
		else:
			# Still too long at the smallest size (a guided-flight step
			# label): the air button says it in fewer words.
			specs[1][1] = "From the air"
	# Spread any room left over evenly, so the row spans the card.
	var spare: float = maxf(inner - total, 0.0) / float(specs.size())
	var bxx: float = x
	for i in specs.size():
		var s: Array = specs[i]
		var w: float = roundf(float(widths[i]) + spare)
		var r := Rect2(bxx, y, w, 52.0)
		var id: String = String(s[0])
		_buttons.append([r, id])
		if teach and id == "replay" and not Settings.reduced_motion():
			# One-time pulse on the replay button: the flight recorder is the
			# feature nobody finds by themselves.
			var p: float = 0.5 + 0.5 * sin(_phase * 4.0)
			UI.draw_focus_ring(self, r, UI.R_MD, _fade(Color(UI.ACCENT.r, UI.ACCENT.g,
					UI.ACCENT.b, 0.25 + 0.6 * p)))
		_draw_button(r, String(s[1]), int(s[3]), String(s[2]), id, label_size)
		bxx += w + 12.0
	if teach:
		UI.draw_text(self, Vector2(x, y + 52.0 + 30.0),
				"The flight recorder saw everything. Watch the last few seconds with Tab.",
				UI.SIZE_BODY_S, _fade(UI.TEXT_DIM))


func _draw_button(r: Rect2, label: String, style: int, key: String, id: String,
		label_size: int) -> void:
	UI.draw_button_ex(self, r, label, style, {
		"hover": _hover == id, "pressed": _pressed == id and _hover == id,
		"key": key, "size": label_size,
	})
