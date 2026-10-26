# OpenRC Simulator - the end of the guided first flight.
#
# One card, over the model sitting on the strip it has just landed on: what was
# achieved, and the two things worth doing next. Enter flies on from here, M
# goes back to the menu. The scene is left unblurred on purpose - the model on
# the grass is the point.
extends CanvasLayer

const UI := preload("res://ui/UITheme.gd")
const Settings := preload("res://ui/Settings.gd")
const FirstFlightLib := preload("res://ui/FirstFlight.gd")

## "free" (fly on from here) or "menu".
signal chosen(id: String)

const CARD_W: float = 720.0
const PAD: float = 32.0
const BUTTON_H: float = 56.0
const BUTTONS := [
	["free", "Fly freely", "ENTER", UI.PRIMARY],
	["menu", "Main menu", "M", UI.SECONDARY],
]

var _canvas: Control
var _appear: float = 0.0
var _selected: int = 0
var _hover: int = -1
var _pressed: int = -1
var _rects: Array = []
var _done: bool = false


func _ready() -> void:
	layer = 30
	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_card)
	_canvas.gui_input.connect(_on_gui_input)
	add_child(_canvas)
	if Settings.reduced_motion():
		_appear = 1.0


func _process(delta: float) -> void:
	_appear = minf(_appear + delta / UI.APPEAR_S, 1.0)
	_canvas.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	get_viewport().set_input_as_handled()
	match (event as InputEventKey).keycode:
		KEY_LEFT, KEY_UP:
			_selected = maxi(_selected - 1, 0)
		KEY_RIGHT, KEY_DOWN, KEY_TAB:
			_selected = mini(_selected + 1, BUTTONS.size() - 1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_choose(_selected)
		KEY_M:
			_choose(1)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = _hit(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var hit: int = _hit(event.position)
		if event.pressed:
			_pressed = hit
		else:
			if hit >= 0 and hit == _pressed:
				_choose(hit)
			_pressed = -1


func _hit(point: Vector2) -> int:
	for entry in _rects:
		if (entry[0] as Rect2).has_point(point):
			return int(entry[1])
	return -1


func _choose(index: int) -> void:
	if _done or index < 0 or index >= BUTTONS.size():
		return
	_done = true
	chosen.emit(String(BUTTONS[index][0]))
	queue_free()


func _draw_card() -> void:
	var size: Vector2 = _canvas.size
	var eased: float = UI.ease_out(_appear)
	# A light shade, so the card holds over a bright sky without blurring the
	# field away.
	_canvas.draw_rect(Rect2(0.0, 0.0, size.x, size.y), Color(UI.SCRIM.r, UI.SCRIM.g,
			UI.SCRIM.b, 0.28 * eased))

	var height: float = PAD + 26.0 + 16.0 + 52.0 + 12.0 + 30.0 + 28.0 + BUTTON_H + PAD
	var card := Rect2(roundf((size.x - CARD_W) * 0.5),
			roundf(size.y * 0.36 - height * 0.5 + (1.0 - eased) * 12.0), CARD_W, height)
	UI.draw_modal(_canvas, card, eased)
	# A good-coloured edge along the top, the counterpart of the crash card's.
	_canvas.draw_rect(Rect2(card.position.x + UI.R_LG, card.position.y, CARD_W - UI.R_LG * 2.0, 3.0),
			Color(UI.GOOD.r, UI.GOOD.g, UI.GOOD.b, eased))

	var x: float = card.position.x + PAD
	var y: float = card.position.y + PAD
	var good := Color(UI.GOOD.r, UI.GOOD.g, UI.GOOD.b, eased)
	UI.draw_check(_canvas, Vector2(x + 8.0, y + 10.0), 16.0, good, 2.5)
	UI.draw_label(_canvas, Vector2(x + 26.0, y + 16.0), "First flight · 6 of 6", good,
			UI.TRACK_CAPS, UI.SIZE_CAPS)
	y += 26.0 + 16.0 + 40.0
	UI.draw_display(_canvas, Vector2(x, y), FirstFlightLib.COMPLETE_TITLE, UI.SIZE_H2 + 6,
			Color(UI.TEXT.r, UI.TEXT.g, UI.TEXT.b, eased))
	y += 12.0 + 30.0
	UI.draw_text(_canvas, Vector2(x, y), FirstFlightLib.COMPLETE_BODY, UI.SIZE_BODY,
			Color(UI.TEXT_DIM.r, UI.TEXT_DIM.g, UI.TEXT_DIM.b, eased))
	y += 28.0

	_rects.clear()
	var bx: float = x
	var widths := [260.0, 240.0]
	for i in BUTTONS.size():
		var b: Array = BUTTONS[i]
		var rect := Rect2(bx, roundf(y), widths[i], BUTTON_H)
		_rects.append([rect, i])
		UI.draw_button_ex(_canvas, rect, String(b[1]), int(b[3]), {
			"focus": i == _selected, "hover": i == _hover,
			"pressed": i == _pressed and i == _hover, "key": String(b[2]),
		})
		bx += widths[i] + 12.0
