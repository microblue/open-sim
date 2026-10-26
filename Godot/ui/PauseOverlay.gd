# OpenRC Simulator - the pause menu.
#
# Esc in flight comes here, and so does losing the window's focus. Everything a
# pilot might want between flights is one choice away - fly again, start again
# in the air, go back to the main menu, read the controls, change a setting -
# and leaving the program is the last item, never a single keypress: Esc used
# to quit outright, which is the key every other program uses to back out of
# something. Even here it asks twice.
#
# The flight does NOT resume by itself when focus comes back. A pilot who
# alt-tabs comes back to a model hanging exactly where they left it, and
# resuming is a decision - a key or a click - because a model that resumed on
# focus would be in a turn the pilot did not see start.
#
# The whole tree is paused while this is up; this node alone keeps processing.
# The backdrop is frosted glass over the scene; Flight.gd hides the HUD while
# any overlay is open (FlightHUD.set_overlay_open), so nothing of the flight
# overlay shows through or round the sheet.
extends CanvasLayer

const UITheme := preload("res://ui/UITheme.gd")
const Settings := preload("res://ui/Settings.gd")

signal resumed
## One of: "restart", "restart_air", "menu", "help", "settings", "radio".
signal chosen(action: String)

## Why it paused, said on the card: "the window lost focus" or "paused".
@export var reason: String = "paused"

## id, label, key, style, note (dim text after the label). "-" is a divider.
const ITEMS: Array = [
	["resume", "Resume", "ESC", UITheme.PRIMARY, ""],
	["restart", "Fly again", "R", UITheme.SECONDARY, ""],
	["restart_air", "Restart in the air", "T", UITheme.SECONDARY, ""],
	["menu", "Main menu", "M", UITheme.SECONDARY, "aircraft, place, weather"],
	["-"],
	["help", "Controls and help", "H", UITheme.SECONDARY, ""],
	["radio", "Set up a transmitter", "F3", UITheme.SECONDARY, ""],
	["settings", "Settings", "O", UITheme.SECONDARY, ""],
	["-"],
	["quit", "Quit to desktop", "", UITheme.TERTIARY, ""],
]
const CARD_W: float = 520.0
const PAD: float = 32.0
const BUTTON_H: float = 52.0
const TERTIARY_H: float = 44.0
const GAP: float = 8.0
## Seconds the "Press again to quit" confirmation waits for the second press.
const QUIT_CONFIRM_S: float = 3.0

var _canvas: Control
var _frost: ColorRect
## Index into ITEMS of the keyboard focus; never a divider.
var _selected: int = 0
var _hover: int = -1
var _pressed: int = -1
## [rect, item index] for each button, rebuilt each draw.
var _rects: Array = []
var _appear: float = 0.0
var _quit_armed: float = -1.0


func _ready() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	# The frost is the first child, under the sheet: the scene behind blurred
	# and sunk, so the flight overlay cannot bleed round the card.
	_frost = UITheme.make_frosted(0.62, 4.0)
	_frost.name = "Frost"
	add_child(_frost)
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
	_appear = minf(_appear + delta / UITheme.APPEAR_S, 1.0)
	_frost.modulate.a = UITheme.ease_out(_appear)
	if _quit_armed >= 0.0:
		_quit_armed -= delta
		if _quit_armed < 0.0:
			_quit_armed = -1.0
	_canvas.queue_redraw()


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = _hit(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var hit: int = _hit(event.position)
		if event.pressed:
			_pressed = hit
		else:
			if hit >= 0 and hit == _pressed:
				_selected = hit
				_choose(hit)
			_pressed = -1


func _hit(point: Vector2) -> int:
	for entry in _rects:
		if (entry[0] as Rect2).has_point(point):
			return int(entry[1])
	return -1


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	get_viewport().set_input_as_handled()
	match (event as InputEventKey).keycode:
		KEY_UP:
			_move(-1)
		KEY_DOWN:
			_move(1)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			_choose(_selected)
		KEY_ESCAPE, KEY_P:
			_resume()
		KEY_R: _choose_id("restart")
		KEY_T: _choose_id("restart_air")
		KEY_M: _choose_id("menu")
		KEY_H, KEY_F1: _choose_id("help")
		KEY_F3: _choose_id("radio")
		KEY_O: _choose_id("settings")


func _move(direction: int) -> void:
	var index: int = _selected
	for _i in ITEMS.size():
		index = posmod(index + direction, ITEMS.size())
		if ITEMS[index][0] != "-":
			break
	_selected = index


func _choose_id(id: String) -> void:
	for i in ITEMS.size():
		if ITEMS[i][0] == id:
			_selected = i
			_choose(i)
			return


func _choose(index: int) -> void:
	var id: String = ITEMS[index][0]
	match id:
		"-":
			return
		"resume":
			_resume()
		"quit":
			# Twice: the first press arms it, the second within three seconds
			# quits. A stray Enter on the last row must not end the session.
			if _quit_armed >= 0.0:
				get_tree().quit()
			else:
				_quit_armed = QUIT_CONFIRM_S
		_:
			# Unpause first: the screen this opens runs in the normal tree.
			_resume()
			chosen.emit(id)


func _resume() -> void:
	resumed.emit()
	queue_free()


# ------------------------------------------------------------------ layout --

func _item_height(item: Array) -> float:
	if item[0] == "-":
		return 25.0                       # 12 margin, hairline, 12 margin
	return TERTIARY_H if item[3] == UITheme.TERTIARY else BUTTON_H


func _card_height() -> float:
	var h: float = PAD + 112.0            # title and the line under it
	for i in ITEMS.size():
		h += _item_height(ITEMS[i])
		if i == 0:
			h += 16.0                     # Resume stands apart from the rest
		elif ITEMS[i][0] != "-" and i + 1 < ITEMS.size() and ITEMS[i + 1][0] != "-":
			h += GAP
	return h + 28.0 + 30.0 + PAD          # footer keys


func _draw_card() -> void:
	var size: Vector2 = _canvas.size
	var eased: float = UITheme.ease_out(_appear)
	var height: float = _card_height()
	var card := Rect2(roundf((size.x - CARD_W) * 0.5),
			roundf((size.y - height) * 0.5 + (1.0 - eased) * 12.0), CARD_W, height)
	UITheme.draw_modal(_canvas, card, eased)

	var x: float = card.position.x + PAD
	var inner: float = CARD_W - PAD * 2.0
	UITheme.draw_display(_canvas, Vector2(x, card.position.y + PAD + 40.0), "Paused",
			40, UITheme.TEXT)
	UITheme.draw_text(_canvas, Vector2(x, card.position.y + PAD + 78.0),
			"Nothing moves until you resume." if reason == "paused" \
			else "Paused because %s." % reason,
			UITheme.SIZE_BODY_S, UITheme.TEXT_DIM)

	_rects.clear()
	var y: float = card.position.y + PAD + 112.0
	for i in ITEMS.size():
		var item: Array = ITEMS[i]
		var h: float = _item_height(item)
		if item[0] == "-":
			UITheme.draw_rule(_canvas, Vector2(x, roundf(y + 12.0)), inner, UITheme.STROKE)
			y += h
			continue
		var rect := Rect2(x, y, inner, h)
		_rects.append([rect, i])
		var label: String = item[1]
		var armed: bool = item[0] == "quit" and _quit_armed >= 0.0
		if armed:
			label = "Press again to quit"
		var opts: Dictionary = {
			"focus": i == _selected, "hover": i == _hover,
			"pressed": i == _pressed and i == _hover,
			"key": item[2], "align": "left",
		}
		if armed:
			# The danger state replaces the label's colour, so draw it here.
			UITheme.draw_button_ex(_canvas, rect, "", item[3], opts)
			UITheme.draw_display(_canvas, Vector2(rect.position.x + 20.0,
					rect.get_center().y + UITheme.SIZE_BUTTON * 0.36), label,
					UITheme.SIZE_BUTTON, UITheme.DANGER)
		else:
			UITheme.draw_button_ex(_canvas, rect, label, item[3], opts)
		if not String(item[4]).is_empty():
			var lw: float = UITheme.font_label().get_string_size(label,
					HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.SIZE_BUTTON).x
			UITheme.draw_text(_canvas, Vector2(rect.position.x + 20.0 + lw + 12.0,
					rect.get_center().y + 6.0), String(item[4]), UITheme.SIZE_BODY_S,
					UITheme.TEXT_FAINT)
		y += h
		if i == 0:
			y += 16.0
		elif i + 1 < ITEMS.size() and ITEMS[i + 1][0] != "-":
			y += GAP

	var hints: Array = [[["UP", "DOWN"], "choose"], [["ENTER"], "select"], [["ESC"], "resume"]]
	var fw: float = UITheme.footer_hints_width(hints)
	UITheme.draw_footer_hints(_canvas, Vector2(roundf(card.position.x + (CARD_W - fw) * 0.5),
			card.end.y - PAD - 12.0), hints, UITheme.TEXT_DIM)
