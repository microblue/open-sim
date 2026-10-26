# OpenRC Simulator - first-run setup, and the Controls screen.
#
# The first time the simulator starts it asks one question, then gets the
# pilot flying:
#
#   1  how will you fly - a transmitter or the keyboard
#   2a keyboard: here are the keys - press each one once (the sticks move)
#   2b transmitter: connect it; a known radio is ready at once, any other
#      goes through the calibration wizard and comes back here
#
# and the last page starts the guided first flight. Stick mode is not asked of
# keyboard pilots (the keys work in Mode 2; Settings has the row for Mode 1),
# and radio pilots are asked it as "which thumb is your throttle on?", which
# changes only the pictures and hints: the radio itself decides the flying.
# The camera is not asked about either: following is the default, and C is
# taught in flight.
#
# The same flow is the main menu's Controls button, starting at step 1, so
# changing your mind later is the same journey.
extends CanvasLayer

const UI := preload("res://ui/UITheme.gd")
const Diagrams := preload("res://ui/ControlDiagrams.gd")
const Settings := preload("res://ui/Settings.gd")
const SoundBank := preload("res://audio/SoundBank.gd")

## Emitted when the pilot wants the transmitter calibrated; the scene opens
## the wizard over this screen and this screen waits for it.
signal wizard_requested
## The setup is over (completed or skipped). Always emitted when it closes.
signal finished
## "Start first flight": emitted right after `finished`.
signal first_flight_requested

enum Page { INPUT, KEYS, RADIO }

## Seconds without a transmitter before the troubleshooting list opens.
const RADIO_PATIENCE: float = 10.0
## Used only if the scene does not publish its own list (Flight.BUILTIN_PROFILES).
const KNOWN_RADIOS: Array = [
	{"names": ["radiomaster", "opentx", "edgetx", "frsky", "taranis", "jumper"],
	 "label": "EdgeTX/OpenTX AETR"},
]

@export var input_path: NodePath
## True on the very first start: the last page then offers the guided first
## flight as the main action; from the menu's Controls button it says Done.
@export var first_run: bool = true

var _input: RCInputNode
var _canvas: Control
var _page: Page = Page.INPUT
var _history: Array[Page] = []
var _appear: float = 0.0
var _phase: float = 0.0
var _sfx: AudioStreamPlayer

# Choices, applied as they are made.
var _use_radio: bool = false
var _mode: int = 2
var _experienced: bool = false
## Focused option on the input page (0 transmitter, 1 keyboard).
var _option: int = 0
var _hover_option: int = -1
## Set once the pilot picks a card themselves: from then on a radio being
## plugged in no longer moves the selection.
var _user_chose: bool = false
var _was_connected: bool = false
## Keys pressed once on the keys page (name -> true).
var _tried: Dictionary = {}
## Seconds spent on the radio page with nothing connected.
var _radio_wait: float = 0.0
## Last input came from the keyboard: draw focus rings.
var _kbd: bool = true
## For screenshots: devices to list instead of Input.get_connected_joypads().
var _seen_override: Array = []

var _option_rects: Array[Rect2] = []
## Clickable things this frame: [rect, action].
var _buttons: Array = []
var _hover_action: String = ""
var _thumb_rects: Array = []
var _hover_thumb: int = -1


func _ready() -> void:
	layer = 30
	Settings.ensure_loaded()
	_input = get_node_or_null(input_path) as RCInputNode
	_was_connected = _connected()
	_use_radio = _was_connected
	_mode = int(Settings.get_value("controls/stick_mode"))
	_experienced = bool(Settings.get_value("onboarding/experienced"))

	_sfx = AudioStreamPlayer.new()
	_sfx.bus = Settings.BUS_MENU
	add_child(_sfx)

	var frost: ColorRect = UI.make_frosted(0.62, 4.0)
	frost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frost)
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_screen)
	_canvas.gui_input.connect(_on_gui_input)
	add_child(_canvas)
	_enter(Page.INPUT)


func _wizard_open() -> bool:
	return get_parent() != null and get_parent().has_node("ControllerWizard")


func _process(delta: float) -> void:
	# The wizard is drawn under this layer; while it is up, this steps aside.
	var hidden: bool = _wizard_open()
	visible = not hidden
	if hidden:
		return
	_appear = minf(_appear + delta / UI.APPEAR_S, 1.0)
	_phase += delta
	var connected: bool = _connected()
	# A radio plugged in while the first page is up selects itself, unless the
	# pilot has already chosen.
	if connected and not _was_connected and _page == Page.INPUT and not _user_chose:
		_use_radio = true
		_option = 0
	_was_connected = connected
	if _page == Page.RADIO and not connected:
		_radio_wait += delta
	else:
		_radio_wait = 0.0
	_canvas.queue_redraw()


# ------------------------------------------------------------- navigation ---

func _enter(page: Page) -> void:
	_page = page
	_appear = 0.0
	match page:
		Page.INPUT: _option = 0 if _use_radio else 1
		Page.KEYS: _tried.clear()
		Page.RADIO: _radio_wait = 0.0


func _go(page: Page) -> void:
	_history.append(_page)
	_play(SoundBank.ui_confirm())
	_enter(page)


func _back() -> void:
	_play(SoundBank.ui_back())
	if _history.is_empty():
		_finish(false)
		return
	_enter(_history.pop_back())


## The primary action of the page.
func _next() -> void:
	match _page:
		Page.INPUT:
			_use_radio = _option == 0
			_go(Page.RADIO if _use_radio else Page.KEYS)
		Page.KEYS:
			_complete()
		Page.RADIO:
			if _radio_ready():
				_complete()
			elif _connected():
				wizard_requested.emit()


## The last page's main button: the guided first flight on the first run,
## Done from the menu.
func _complete() -> void:
	_finish(true, first_run)


func _finish(_completed: bool, first_flight: bool = false) -> void:
	# Seen is seen: skipping keeps the defaults, and the Controls button on the
	# main menu brings this back.
	Settings.set_value("onboarding/done", true)
	finished.emit()
	if first_flight:
		first_flight_requested.emit()
	queue_free()


func _connected() -> bool:
	return _input != null and _input.is_connected()


func _radio_ready() -> bool:
	return _connected() and _input.is_fully_bound() and _input.get_profile_problem().is_empty()


## The short name of the built-in profile this radio matches ("EdgeTX/OpenTX"),
## or "" for a radio we have no ready-made binding for.
func _recognised_as() -> String:
	if not _connected():
		return ""
	var profiles: Array = KNOWN_RADIOS
	var parent: Node = get_parent()
	if parent != null and parent.get_script() != null:
		var published = (parent.get_script() as Script).get_script_constant_map().get("BUILTIN_PROFILES")
		if published is Array:
			profiles = published
	var device: String = _input.get_device_name().to_lower()
	for profile in profiles:
		for name in profile["names"]:
			if device.find(String(name)) >= 0:
				return String(profile["label"]).split(" ")[0]
	return ""


func _device_name(limit: int = 36) -> String:
	if not _connected():
		return ""
	var name: String = _input.get_device_name()
	return name if name.length() <= limit else name.substr(0, limit - 1) + "…"


func _set_mode(mode: int) -> void:
	if mode == _mode:
		return
	_mode = mode
	Settings.set_value("controls/stick_mode", _mode)
	if _input != null:
		_input.set_keyboard_mode(_mode)
	_play(SoundBank.ui_tick())


func _toggle_experienced() -> void:
	_experienced = not _experienced
	Settings.set_value("onboarding/experienced", _experienced)
	_play(SoundBank.ui_tick())


func _play(stream: AudioStream) -> void:
	if stream != null and _sfx != null:
		_sfx.stream = stream
		_sfx.play()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey and event.pressed and not event.echo):
		return
	get_viewport().set_input_as_handled()
	_kbd = true
	var code: Key = (event as InputEventKey).keycode
	if _page == Page.KEYS:
		var name: String = Diagrams.key_name(code)
		if not name.is_empty():
			if not _tried.has(name):
				_play(SoundBank.ui_tick())
			_tried[name] = true
			return
	match code:
		KEY_LEFT, KEY_UP:
			if _page == Page.INPUT and _option != 0:
				_option = 0
				_user_chose = true
				_play(SoundBank.ui_tick())
			elif _page == Page.RADIO and _radio_ready():
				_set_mode(2)
		KEY_RIGHT, KEY_DOWN:
			if _page == Page.INPUT and _option != 1:
				_option = 1
				_user_chose = true
				_play(SoundBank.ui_tick())
			elif _page == Page.RADIO and _radio_ready():
				_set_mode(1)
		KEY_SPACE:
			if _page == Page.INPUT:
				_toggle_experienced()
			else:
				_next()
		KEY_ENTER, KEY_KP_ENTER:
			_next()
		KEY_ESCAPE, KEY_BACKSPACE:
			_back()
		KEY_M:
			if _is_last_page():
				_do("menu")
		KEY_F3:
			if _page == Page.RADIO and _connected():
				wizard_requested.emit()


func _is_last_page() -> bool:
	return _page == Page.KEYS or (_page == Page.RADIO and _radio_ready())


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_kbd = false
		var p: Vector2 = event.position
		_hover_option = -1
		for i in _option_rects.size():
			if _option_rects[i].has_point(p):
				_hover_option = i
		_hover_thumb = -1
		for i in _thumb_rects.size():
			if (_thumb_rects[i] as Rect2).has_point(p):
				_hover_thumb = i
		_hover_action = ""
		for entry in _buttons:
			if (entry[0] as Rect2).has_point(p):
				_hover_action = String(entry[1])
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var p: Vector2 = event.position
		for entry in _buttons:
			if (entry[0] as Rect2).has_point(p):
				_do(String(entry[1]))
				return
		for i in _thumb_rects.size():
			if (_thumb_rects[i] as Rect2).has_point(p):
				_set_mode(2 if i == 0 else 1)
				return
		for i in _option_rects.size():
			if _option_rects[i].has_point(p):
				# The first click selects; a click on the selected card goes on.
				_user_chose = true
				if _option == i:
					_next()
				else:
					_option = i
					_play(SoundBank.ui_tick())
				return


func _do(action: String) -> void:
	if action.begins_with("pad:"):
		# A device Godot sees but the transmitter node did not pick: use it.
		if _input != null:
			_input.set_device_id(int(action.substr(4)))
		_play(SoundBank.ui_confirm())
		return
	match action:
		"next":
			_next()
		"back":
			_back()
		"menu":
			_finish(true, false)
		"first_flight":
			_finish(true, true)
		"wizard":
			wizard_requested.emit()
		"keyboard":
			_use_radio = false
			_history.clear()
			_history.append(Page.INPUT)
			_play(SoundBank.ui_confirm())
			_enter(Page.KEYS)
		"experienced":
			_toggle_experienced()
		"step0":
			if _page != Page.INPUT:
				_back()


# --------------------------------------------------------------- drawing ---

func _card(size: Vector2) -> Rect2:
	var w: float = minf(size.x - 80.0, 1360.0)
	var h: float = minf(size.y - 80.0, 860.0)
	var t: float = UI.ease_out(_appear)
	return Rect2((size.x - w) * 0.5, (size.y - h) * 0.5 + (1.0 - t) * 12.0, w, h)


## A button, registered for clicks when enabled.
func _btn(rect: Rect2, label: String, style: int, action: String, opts: Dictionary = {}) -> void:
	var o: Dictionary = opts.duplicate()
	var enabled: bool = bool(o.get("enabled", true))
	o["hover"] = enabled and _hover_action == action
	if style == UI.PRIMARY and not o.has("focus"):
		o["focus"] = enabled and _kbd
	UI.draw_button_ex(_canvas, rect, label, style, o)
	if enabled:
		_buttons.append([rect, action])


func _button_w(label: String, key: String = "", size: int = UI.SIZE_BUTTON) -> float:
	var w: float = UI.font_label().get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 64.0
	if not key.is_empty():
		w += UI.keycap_width(key, UI.SIZE_KEY) + 12.0
	return maxf(w, 160.0)


func _draw_screen() -> void:
	var size: Vector2 = _canvas.size
	var card: Rect2 = _card(size)
	_canvas.modulate.a = UI.ease_out(_appear)
	UI.draw_modal(_canvas, card)
	_option_rects.clear()
	_buttons.clear()
	_thumb_rects = []

	var pad: float = UI.S7
	var x0: float = card.position.x + pad
	var y0: float = card.position.y + pad
	var inner_w: float = card.size.x - pad * 2.0

	# Where you are: two steps, named for the path being taken.
	var radio_path: bool = (_option == 0) if _page == Page.INPUT else _use_radio
	var names: Array = ["How you fly", "Transmitter" if radio_path else "Try the keys"]
	var steps: Array = UI.draw_stepper(_canvas, Rect2(x0, y0, inner_w, 40.0), names,
			0 if _page == Page.INPUT else 1)
	if _page != Page.INPUT:
		_buttons.append([steps[0], "step0"])

	var row_y: float = card.end.y - pad - 56.0
	var body := Rect2(x0, y0 + 40.0, inner_w, row_y - 32.0 - (y0 + 40.0))
	match _page:
		Page.INPUT:
			_title(body, "How will you fly?",
					"You can change this later from Controls on the main menu.")
			_draw_input_choice(body)
		Page.KEYS:
			_title(body, "Try the keys",
					"Press each key once. Each one moves a stick on the transmitter.")
			_draw_keys(body)
		Page.RADIO:
			_draw_radio(body)

	# The button row: back on the left, the one thing to do next on the right.
	UI.draw_rule(_canvas, Vector2(x0, row_y - 24.0), inner_w)
	var back_label: String = "Back"
	if _history.is_empty():
		back_label = "Skip" if first_run else "Close"
	_btn(Rect2(x0, row_y, _button_w(back_label, "ESC"), 56.0), back_label, UI.SECONDARY, "back",
			{"key": "ESC"})
	var right: float = card.end.x - pad
	match _page:
		Page.INPUT:
			_btn(Rect2(right - 320.0, row_y, 320.0, 56.0), "Continue", UI.PRIMARY, "next",
					{"key": "ENTER"})
		Page.KEYS:
			_draw_finish_buttons(right, row_y)
		Page.RADIO:
			var bx: float = x0 + _button_w(back_label, "ESC") + UI.S3
			if not _radio_ready():
				var kb: String = "Fly with the keyboard for now"
				_btn(Rect2(bx, row_y, _button_w(kb), 56.0), kb, UI.SECONDARY, "keyboard")
			if _radio_ready():
				_draw_finish_buttons(right, row_y)
			elif _connected():
				_btn(Rect2(right - 320.0, row_y, 320.0, 56.0), "Set up the sticks", UI.PRIMARY,
						"next", {"key": "ENTER"})
			else:
				_btn(Rect2(right - 340.0, row_y, 340.0, 56.0), "Start first flight", UI.PRIMARY,
						"next", {"enabled": false})


## The last page's pair: the first flight (or Done), and the way out to the menu.
func _draw_finish_buttons(right: float, row_y: float) -> void:
	var main_w: float = 340.0
	if first_run:
		_btn(Rect2(right - main_w, row_y, main_w, 56.0), "Start first flight", UI.PRIMARY,
				"next", {"key": "ENTER"})
		var skip: String = "Skip to the main menu"
		var sw: float = _button_w(skip, "M")
		_btn(Rect2(right - main_w - UI.S3 - sw, row_y, sw, 56.0), skip, UI.TERTIARY, "menu",
				{"key": "M"})
	else:
		_btn(Rect2(right - 260.0, row_y, 260.0, 56.0), "Done", UI.PRIMARY, "next",
				{"key": "ENTER"})
		var ff: String = "Start first flight"
		var fw: float = _button_w(ff)
		_btn(Rect2(right - 260.0 - UI.S3 - fw, row_y, fw, 56.0), ff, UI.SECONDARY, "first_flight")


## H1 title and a one-line subtitle; the body starts 124 px below the top.
func _title(body: Rect2, title: String, sub: String) -> void:
	UI.draw_display(_canvas, body.position + Vector2(0, 84.0), title, UI.SIZE_H1, UI.TEXT)
	if not sub.is_empty():
		UI.draw_text(_canvas, body.position + Vector2(0, 124.0), sub, UI.SIZE_BODY, UI.TEXT_DIM)


## A status line in place of the subtitle: spinner, dot or check, then text.
func _status(body: Rect2, kind: String, text: String, colour: Color) -> void:
	var c := Vector2(body.position.x + 9.0, body.position.y + 117.0)
	match kind:
		"spin": UI.draw_spinner(_canvas, c, 9.0, _phase, UI.ACCENT)
		"dot": _canvas.draw_circle(c, 6.0, colour)
		"check": UI.draw_check(_canvas, c, 16.0, colour)
		"warn": UI.draw_warn_triangle(_canvas, c, 20.0, colour)
	UI.draw_text(_canvas, body.position + Vector2(30.0, 124.0), text, UI.SIZE_BODY, colour,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold())


## A picture well: BASE at half alpha, inset, rounded.
func _well(r: Rect2) -> void:
	_canvas.draw_colored_polygon(UI.rounded_rect(r, UI.R_MD), Color(UI.BASE, 0.5))


# --- input page ---

func _choice_card(r: Rect2, index: int) -> void:
	var selected: bool = index == _option
	var hover: bool = index == _hover_option and not selected
	if selected:
		_canvas.draw_colored_polygon(UI.rounded_rect(r, UI.R_MD), Color(UI.ACCENT_DEEP, 0.55))
	else:
		_canvas.draw_colored_polygon(UI.rounded_rect(r, UI.R_MD), Color(UI.SURFACE_2, 0.6))
	var edge: PackedVector2Array = UI.rounded_rect(r, UI.R_MD)
	edge.append(edge[0])
	if selected:
		_canvas.draw_polyline(edge, UI.ACCENT, UI.STROKE_UI, true)
	else:
		_canvas.draw_polyline(edge, UI.STROKE_HOVER if hover else UI.STROKE_STRONG, UI.HAIRLINE, true)
	if selected and _kbd:
		UI.draw_focus_ring(_canvas, r, UI.R_MD)
	UI.draw_radio(_canvas, Vector2(r.end.x - 20.0 - 11.0, r.position.y + 20.0 + 11.0), selected)


## Card text block at the bottom of a card: H2 title with an optional tag at
## the right, then lines. Each line is a String or [text, colour, icon].
func _card_text(r: Rect2, title: String, lines: Array, tag: String = "",
				tag_kind: String = "state") -> void:
	var x: float = r.position.x + UI.S5
	var y: float = r.end.y - UI.S5 - 28.0 * float(lines.size()) - 8.0
	UI.draw_display(_canvas, Vector2(x, y), title, UI.SIZE_H2, UI.TEXT)
	if not tag.is_empty():
		var tw: float = UI.label_width(tag) + (34.0 if tag_kind != "info" else 24.0)
		UI.draw_tag(_canvas, Vector2(r.end.x - UI.S5 - tw, y - 11.0), tag, tag_kind)
	y += 38.0
	for line in lines:
		var text: String = String(line[0]) if line is Array else String(line)
		var colour: Color = line[1] if line is Array else UI.TEXT_DIM
		var icon: String = String(line[2]) if line is Array and line.size() > 2 else ""
		var tx: float = x
		if icon == "dot":
			_canvas.draw_circle(Vector2(x + 5.0, y - 7.0), 5.0, colour)
			tx += 20.0
		elif icon == "check":
			UI.draw_check(_canvas, Vector2(x + 7.0, y - 7.0), 14.0, colour)
			tx += 24.0
		UI.draw_text(_canvas, Vector2(tx, y), text, UI.SIZE_BODY - 1, colour,
				HORIZONTAL_ALIGNMENT_LEFT, r.end.x - UI.S5 - tx, false,
				UI.font_semibold() if icon != "" else null)
		y += 28.0


func _draw_input_choice(body: Rect2) -> void:
	var top: float = body.position.y + 160.0
	var check_h: float = 56.0
	var gap: float = UI.S6
	var w: float = (body.size.x - gap) * 0.5
	var h: float = body.end.y - check_h - top
	var cards: Array[Rect2] = [Rect2(body.position.x, top, w, h),
			Rect2(body.position.x + w + gap, top, w, h)]
	_option_rects = cards
	for i in 2:
		_choice_card(cards[i], i)

	var text_h: float = 150.0
	var connected: bool = _connected()

	# The transmitter: live if one is plugged in, faded while it is not.
	var well0 := Rect2(cards[0].position + Vector2(UI.S5, UI.S5),
			Vector2(cards[0].size.x - UI.S5 * 2.0, cards[0].size.y - UI.S5 - text_h))
	_well(well0)
	var pic0: Rect2 = _fit(well0.grow(-UI.S4), Vector2(420.0, 220.0))
	var channels: PackedFloat64Array = _input.get_channels() if connected and _radio_ready() \
			else PackedFloat64Array()
	Diagrams.draw_transmitter(_canvas, pic0, _mode, channels, [], _phase, false,
			1.0 if connected else 0.45)
	var known: String = _recognised_as()
	if not connected:
		_card_text(cards[0], "RC transmitter",
				["Plug it in now with a USB data cable, and we'll detect it.",
				"The best way to learn: it is what you fly with."], "not connected", "state")
	elif _radio_ready() and not known.is_empty():
		_card_text(cards[0], "RC transmitter",
				[["Recognised: %s. Ready to fly." % known, UI.GOOD, "check"],
				_device_name(48)], "ready", "good")
	else:
		_card_text(cards[0], "RC transmitter",
				[["Found: %s" % _device_name(40), UI.GOOD, "dot"],
				"Ready to fly." if _radio_ready() else "Next, a one-minute stick setup."],
				"connected", "good")

	# The keyboard: the eight flying keys.
	var well1 := Rect2(cards[1].position + Vector2(UI.S5, UI.S5),
			Vector2(cards[1].size.x - UI.S5 * 2.0, cards[1].size.y - UI.S5 - text_h))
	_well(well1)
	var cap: float = clampf((well1.size.x - 80.0) / 9.6, 34.0, 48.0)
	var kb_w: float = cap * 3.0 * 2.0 + 16.0 * 2.0 + cap * 2.4
	var kb_h: float = 30.0 + cap * 2.0 + 8.0
	Diagrams.draw_keyboard(_canvas, Vector2(well1.get_center().x - kb_w * 0.5,
			well1.get_center().y - kb_h * 0.5 - 6.0), 2, false, cap, {}, false)
	_card_text(cards[1], "Keyboard",
			["Fine for a first try, nothing to plug in.",
			"Keys are on or off, so it flies less smoothly."])

	# "I already fly RC models".
	var cy: float = body.end.y - check_h * 0.5 + 6.0
	var box := Rect2(body.position.x + 2.0, cy - 12.0, 24.0, 24.0)
	var label: String = "I already fly RC models"
	var f: Font = UI.font_semibold()
	var lw: float = f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, UI.SIZE_BODY).x
	var hit := Rect2(box.position - Vector2(8, 10), Vector2(lw + 60.0, 44.0))
	var hover: bool = _hover_action == "experienced"
	_buttons.append([hit, "experienced"])
	if _experienced:
		_canvas.draw_colored_polygon(UI.rounded_rect(box, 5.0), UI.ACCENT)
		UI.draw_check(_canvas, box.get_center(), 14.0, UI.ACCENT_INK, 2.5)
	else:
		var e: PackedVector2Array = UI.rounded_rect(box, 5.0)
		e.append(e[0])
		_canvas.draw_polyline(e, UI.TEXT_DIM if hover else UI.STROKE_HOVER, UI.STROKE_UI, true)
	UI.draw_text(_canvas, Vector2(box.end.x + 14.0, cy + 7.0), label, UI.SIZE_BODY, UI.TEXT,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, f)
	var kx: float = box.end.x + 14.0 + lw + 12.0
	var kw: float = UI.draw_keycap(_canvas, Vector2(kx, cy - 13.0), "SPACE", UI.SIZE_KEY)
	UI.draw_text(_canvas, Vector2(kx + kw + 16.0, cy + 7.0),
			"Fewer tips in flight, and the guided first flight becomes optional.",
			UI.SIZE_BODY_S, UI.TEXT_DIM)


## The largest rect of `cap`'s proportions that fits in `r`, centred.
func _fit(r: Rect2, cap: Vector2) -> Rect2:
	var s: float = minf(minf(r.size.x / cap.x, r.size.y / cap.y), 1.25)
	var size: Vector2 = cap * s
	return Rect2(r.get_center() - size * 0.5, size)


# --- keys page ---

func _draw_keys(body: Rect2) -> void:
	var top: float = body.position.y + 160.0
	var cap: float = 64.0
	var drawn: Vector2 = Diagrams.draw_keyboard(_canvas, Vector2(body.position.x, top), 2, true,
			cap, _tried)
	# The sticks, driven straight from the keys: the keyboard is not flying
	# anything while a screen is up, so this screen moves them itself.
	var right_x: float = body.position.x + drawn.x + UI.S8
	var well := Rect2(right_x, top, body.end.x - right_x, body.end.y - top)
	_well(well)
	Diagrams.draw_transmitter(_canvas, well.grow(-UI.S5), 2, Diagrams.channels_from_keys(2), [],
			_phase, true)

	# The goal, counted: never a gate, Start is always available.
	var n: int = _tried.size()
	var total: int = Diagrams.flying_keys().size()
	var gy: float = top + drawn.y + UI.S6
	var bar := Rect2(body.position.x, gy, drawn.x, 6.0)
	UI.draw_track(_canvas, bar, float(n) / float(total), UI.GOOD if n >= total else UI.ACCENT)
	if n >= total:
		UI.draw_check(_canvas, Vector2(body.position.x + 8.0, gy + 34.0), 16.0, UI.GOOD)
		UI.draw_text(_canvas, Vector2(body.position.x + 28.0, gy + 41.0),
				"All eight. You're ready for your first flight.", UI.SIZE_BODY, UI.GOOD,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold())
	else:
		UI.draw_text(_canvas, Vector2(body.position.x, gy + 41.0),
				"%d of %d keys tried" % [n, total], UI.SIZE_BODY, UI.TEXT,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold())
	for line in UI.wrap_text("In flight the throttle stays where you leave it. The other keys spring back to centre.",
			drawn.x, UI.SIZE_BODY_S):
		UI.draw_text(_canvas, Vector2(body.position.x, gy + 76.0), line, UI.SIZE_BODY_S, UI.TEXT_DIM)
		gy += 24.0


# --- transmitter page ---

func _draw_radio(body: Rect2) -> void:
	var connected: bool = _connected()
	var ready: bool = _radio_ready()
	var left_w: float = 560.0
	var top: float = body.position.y + 168.0
	var right := Rect2(body.position.x + left_w + UI.S8, top,
			body.size.x - left_w - UI.S8, body.end.y - top)

	if ready:
		var known: String = _recognised_as()
		_title(body, "Your transmitter is ready", "")
		_status(body, "check", ("Recognised: %s. Ready to fly." % known) if not known.is_empty()
				else "Set up: %s" % _device_name(), UI.GOOD)
		UI.draw_text(_canvas, Vector2(body.position.x, top + 24.0),
				"Move the sticks: the picture moves the same way.", UI.SIZE_BODY, UI.TEXT_DIM)
		_thumb_rects = Diagrams.draw_thumb_question(_canvas, Vector2(body.position.x, top + 64.0),
				left_w, "Which thumb is your throttle on?", _mode, _hover_thumb, false)
		var again: String = "Set up the sticks again"
		_btn(Rect2(body.position.x - 12.0, top + 252.0, _button_w(again, "F3", 22), 44.0), again,
				UI.TERTIARY, "wizard", {"key": "F3", "size": 22})
		_well(right)
		Diagrams.draw_transmitter(_canvas, right.grow(-UI.S5), _mode, _input.get_channels(), [],
				_phase, true)
		return

	if connected:
		_title(body, "Transmitter found", "")
		_status(body, "dot", "Found: %s" % _device_name(), UI.GOOD)
		var y: float = Diagrams.draw_steps(_canvas, Vector2(body.position.x, top), left_w, [
			{"title": "Plugged in with a USB cable.", "detail": "", "state": "done"},
			{"title": "USB Joystick mode is on.", "detail": "", "state": "done"},
			{"title": "Set up the sticks once.",
			 "detail": "Move each stick when asked, so the simulator learns your radio. About a minute.",
			 "state": "current"},
		])
		var problem: String = _input.get_profile_problem()
		if not problem.is_empty():
			UI.draw_warn_triangle(_canvas, Vector2(body.position.x + 10.0, y + 10.0), 20.0, UI.WARN)
			var ly: float = y + 16.0
			for line in UI.wrap_text(problem, left_w - 36.0, UI.SIZE_BODY_S):
				UI.draw_text(_canvas, Vector2(body.position.x + 32.0, ly), line, UI.SIZE_BODY_S, UI.WARN)
				ly += 24.0
		_well(right)
		Diagrams.draw_transmitter(_canvas, right.grow(-UI.S5), _mode, PackedFloat64Array(), [],
				_phase, true)
		return

	var late: bool = _radio_wait >= RADIO_PATIENCE
	_title(body, "Connect your transmitter", "")
	if late:
		_status(body, "spin", "Still waiting for a transmitter…", UI.WARN)
	else:
		_status(body, "spin", "Waiting for a transmitter…", UI.TEXT_DIM)
	Diagrams.draw_steps(_canvas, Vector2(body.position.x, top), left_w, [
		{"title": "Plug the radio into this computer.",
		 "detail": "Use a USB data cable: some cables only charge.", "state": "current"},
		{"title": "On the radio, choose USB Joystick mode.",
		 "detail": "EdgeTX and OpenTX ask when the cable goes in: pick USB Joystick (HID). Others call it Simulator or game controller mode.",
		 "state": "todo"},
		{"title": "This screen notices by itself.",
		 "detail": "Known radios are ready at once. Any other gets a one-minute stick setup.",
		 "state": "todo"},
	])
	if late:
		var pads: Array = _seen_override if not _seen_override.is_empty() else Diagrams.seen_joypads()
		var hover_id: int = int(_hover_action.substr(4)) if _hover_action.begins_with("pad:") else -1
		for hit in Diagrams.draw_troubleshooting(_canvas, right, pads, hover_id):
			_buttons.append([hit[0], "pad:%d" % int(hit[1])])
	else:
		_well(right)
		Diagrams.draw_transmitter(_canvas, right.grow(-UI.S5), _mode, PackedFloat64Array(), [],
				_phase, true, 0.45)
