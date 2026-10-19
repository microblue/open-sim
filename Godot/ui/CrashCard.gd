# OpenRC Simulator - the card that says why it crashed.
#
# The crash banner says THAT it crashed. This says WHY, in one line, and what
# to do differently, in another - read from the last seconds of the flight
# recorder by the physics core (RCPhysics/Training/CrashAnalysis.h), so the
# reason is always something the pilot can go and see in the replay.
#
# It waits a moment before appearing. A wreck still tumbling across the field
# is the thing to watch; the explanation is for once it has stopped.
extends Control

const UI := preload("res://ui/UITheme.gd")

## Seconds after the crash before the card fades in.
const DELAY: float = 1.2
const FADE: float = 0.35
const WIDTH: float = 660.0

var _sim: Node = null
var _report: Dictionary = {}
var _since: float = -1.0
var _alpha: float = 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func bind(simulation: Node) -> void:
	_sim = simulation


## The report as a pure layout input, so a test can render a card without a
## crash. Pass an empty dictionary to hide it.
func show_report(report: Dictionary) -> void:
	_report = report
	_since = 0.0 if not report.is_empty() else -1.0
	_alpha = 0.0
	queue_redraw()


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
	var target: float = clampf((_since - DELAY) / FADE, 0.0, 1.0)
	if not is_equal_approx(target, _alpha):
		_alpha = target
		queue_redraw()


func _draw() -> void:
	if _report.is_empty() or _alpha <= 0.0:
		return
	var title: String = String(_report.get("title", "Crashed"))
	var detail: String = String(_report.get("detail", ""))
	var advice: String = String(_report.get("advice", ""))

	var inner: float = WIDTH - 2.0 * UI.S5
	var detail_lines: PackedStringArray = UI.wrap_text(detail, inner, UI.SIZE_BODY)
	var advice_lines: PackedStringArray = UI.wrap_text(advice, inner - UI.S4, UI.SIZE_LABEL)

	var line_body: float = UI.SIZE_BODY * 1.35
	var line_label: float = UI.SIZE_LABEL * 1.4
	var height: float = UI.S5 + UI.SIZE_MICRO + UI.S2 + UI.SIZE_LARGE + UI.S3 \
		+ detail_lines.size() * line_body + UI.S4 \
		+ advice_lines.size() * line_label + UI.S5 + UI.SIZE_MICRO + UI.S5

	# Lower third, centred: clear of the aircraft the camera is zoomed onto,
	# clear of the banner at the top.
	var origin := Vector2((size.x - WIDTH) * 0.5, size.y * 0.62 - height * 0.5)
	origin.y = clampf(origin.y, UI.S6, size.y - height - UI.S6)
	var rect := Rect2(origin, Vector2(WIDTH, height))

	var fade := func(c: Color) -> Color:
		return Color(c.r, c.g, c.b, c.a * _alpha)

	UI.draw_panel(self, rect, fade.call(UI.PANEL_SOLID), fade.call(UI.STROKE_STRONG))
	# A danger-coloured edge on the left, the one place colour says "this went
	# wrong" without shouting across the whole card.
	draw_rect(Rect2(origin + Vector2(0, UI.S3), Vector2(3, height - 2 * UI.S3)),
			  fade.call(UI.DANGER))

	var x: float = origin.x + UI.S5
	var y: float = origin.y + UI.S5 + UI.SIZE_MICRO
	UI.draw_label(self, Vector2(x, y), "WHY IT CRASHED", fade.call(UI.TEXT_FAINT))
	y += UI.S2 + UI.SIZE_LARGE
	UI.draw_text(self, Vector2(x, y), title, UI.SIZE_LARGE, fade.call(UI.TEXT))
	y += UI.S3
	for line in detail_lines:
		y += line_body
		UI.draw_text(self, Vector2(x, y), line, UI.SIZE_BODY, fade.call(UI.TEXT_DIM))
	y += UI.S4
	# The advice is the part to remember, so it gets the accent rule.
	var advice_top: float = y + UI.S1
	for line in advice_lines:
		y += line_label
		UI.draw_text(self, Vector2(x + UI.S4, y), line, UI.SIZE_LABEL, fade.call(UI.TEXT))
	draw_rect(Rect2(Vector2(x, advice_top), Vector2(2, y - advice_top + UI.S1)),
			  fade.call(UI.ACCENT))
	y += UI.S5 + UI.SIZE_MICRO
	UI.draw_label(self, Vector2(x, y), "R  FLY AGAIN      TAB  WATCH THE REPLAY",
				  fade.call(UI.TEXT_FAINT))
