# OpenRC Simulator - settings.
#
# One card, a list of rows, nothing nested. A settings screen in a flight
# simulator is visited twice - once on the first evening and once when
# something is wrong - so everything is on the one page, with a sentence in the
# card's help strip saying what the chosen row changes. Every row changes live,
# so the pilot hears the volume move and sees the HUD switch to feet while they
# are still looking at the setting that did it.
#
# Every value is a control: a selector with a chevron each side, clickable, on
# every row - faint on the rows without the keyboard, accent on the one with
# it. When the list is longer than the card it scrolls inside it, with the
# edges faded, and keeps the chosen row in view.
#
# Changes are saved as they are made. The one exception is the window mode: a
# display change can leave the pilot looking at nothing, so it is applied,
# then asked about, and undone by itself after REVERT_SECONDS unless kept.
extends CanvasLayer

const UITheme := preload("res://ui/UITheme.gd")
const Settings := preload("res://ui/Settings.gd")
const SoundBank := preload("res://audio/SoundBank.gd")

signal closed

const REVERT_SECONDS: float = 15.0
const CARD_W: float = 1100.0
const CARD_H: float = 860.0
const PAD: float = 32.0
const ROW_H: float = 48.0
## A group head: 24 px of air above it, then the caps line.
const GROUP_H: float = 58.0
const HEADER_H: float = 96.0
const HELP_H: float = 56.0
const FOOTER_H: float = 60.0
const SELECTOR_W: float = 300.0
const FADE_H: float = 24.0
const VOLUME_STEP: float = 0.05

## key, label, kind, choices ([value, label] for a choice row), what it does.
## kind: "volume", "choice", or "action" (a button; key names the action).
## "interface/hints" reads Settings.hint_mode(), which folds in the older
## interface/key_hints switch, so the two are one control here.
const ROWS: Array = [
	["group", "audio"],
	["audio/game_volume", "Game volume", "volume", [],
		"Everything in the world: the aircraft, the air and the ground."],
	["audio/menu_volume", "Menu and music", "volume", [],
		"The main menu's music and the interface clicks."],
	["group", "display"],
	["display/window_mode", "Window", "choice",
		[["windowed", "Windowed"], ["fullscreen", "Fullscreen"]],
		"Asks to keep a change, and goes back by itself after 15 seconds if not."],
	["display/units", "Units", "choice",
		[["metric", "Metric · km/h, m"],
		 ["imperial", "Imperial · mph, ft"],
		 ["si", "SI · m/s, m"]],
		"Airspeed, height and climb rate on the flight overlay and the crash card."],
	["group", "flying"],
	["controls/stick_mode", "Stick mode", "choice",
		[[2, "Mode 2 · throttle left"], [1, "Mode 1 · throttle right"]],
		"Which stick is the throttle. Mode 1 puts the throttle on the up/down arrows and elevator on W/S."],
	["camera/view", "Starting view", "choice",
		[["follow", "Follow"], ["pilot", "Pilot's view"], ["fpv", "FPV"]],
		"The view a flight starts in. Follow keeps the model in frame from behind; C changes view in flight."],
	["camera/auto_zoom", "Pilot-view auto-zoom", "choice",
		[[true, "On"], [false, "Off"]],
		"Narrows the pilot view just enough to keep a distant model readable. X in flight."],
	["camera/height_cue", "Height cue", "choice",
		[[true, "Vertical"], [false, "Off"]],
		"A mark on the ground straight below the model, fading out with height. G in flight."],
	["group", "practice"],
	["practice/failure_chance", "Failure practice", "choice",
		[[0.0, "Off"], [0.1, "1 flight in 10"], [0.3, "3 flights in 10"],
		 [0.5, "Every other flight"], [1.0, "Every flight"]],
		"One failure, after 20 s to 2 min of proper flight, never on the ground. Shift+R flies the same one again."],
	["practice/failure_notice", "Failure notice", "choice",
		[[true, "Shown"], [false, "Hidden"]],
		"Hidden keeps every symptom and drops the words: find out what broke the way a real pilot has to."],
	["practice/radio_failures", "Radio failures", "choice",
		[[false, "Not included"], [true, "Included"]],
		"Radio loss and brownout in the pool, as well as motor and control failures."],
	["practice/failure_keys", "Failure keys", "choice",
		[[false, "Off"], [true, "On"]],
		"Number keys 4–8 cause a failure on purpose, and 9 clears it."],
	["group", "interface"],
	["interface/hud", "HUD", "choice",
		[["clean", "Clean"], ["standard", "Standard"], ["detailed", "Detailed"]],
		"How much the flight overlay shows. Clean for the view, Detailed for tuning. V in flight."],
	["interface/stick_display", "Stick display", "choice",
		[["auto", "Auto: keyboard only"], ["on", "On"], ["off", "Off"]],
		"The two stick gates in the corner. Auto shows them when flying on the keyboard, where there are no sticks to look at."],
	["interface/hints", "Hints", "choice",
		[["always", "Always"], ["learn", "Until learned"], ["off", "Off"]],
		"What to do next, above the bottom of the flight overlay. Until learned stops offering one after you have done it three times."],
	["reset_hints", "Reset hints", "action", [],
		"Start every hint again from the beginning, as on the first flight."],
	["interface/locator", "Aircraft locator", "choice",
		[[true, "On"], [false, "Off"]],
		"Brackets round the model when it is small, and an arrow at the edge when it is out of view."],
	["interface/reduced_motion", "Reduced motion", "choice",
		[[false, "Off"], [true, "On"]],
		"No sliding screens, no pulsing banners, no eased camera zoom."],
]

var _frost: ColorRect
var _canvas: Control
## The scrolling list, clipped to the card's middle.
var _list: Control
## Over everything: the display-mode question.
var _top: Control
var _sfx: AudioStreamPlayer
## Index into ROWS of the highlighted row; never a group.
var _selected: int = 1
var _appear: float = 0.0
var _nudged: float = 999.0
var _hover: int = -1
var _hover_part: String = ""        # "prev", "next", "value", "" within the hovered row
var _scroll: float = 0.0
var _scroll_target: float = 0.0
var _reset_done: float = -1.0
## Row rects in canvas coordinates, rebuilt each draw: [rect, row index].
var _hits: Array = []
var _shift := Vector2.ZERO

# The display confirmation.
var _confirm_left: float = -1.0
var _confirm_previous: String = ""
var _keep_rect := Rect2()
var _revert_rect := Rect2()


func _ready() -> void:
	layer = 26
	Settings.ensure_loaded()

	_sfx = AudioStreamPlayer.new()
	_sfx.name = "SettingsSfx"
	_sfx.bus = Settings.BUS_MENU
	add_child(_sfx)

	_frost = UITheme.make_frosted(0.62, 4.0)
	_frost.name = "Frost"
	add_child(_frost)

	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Stops the pointer here: the menu underneath has hover states of its own.
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_screen)
	_canvas.gui_input.connect(_on_gui_input)
	add_child(_canvas)

	_list = Control.new()
	_list.name = "List"
	_list.clip_contents = true
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.draw.connect(_draw_list)
	add_child(_list)

	_top = Control.new()
	_top.name = "Top"
	_top.set_anchors_preset(Control.PRESET_FULL_RECT)
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.draw.connect(_draw_top)
	add_child(_top)
	if Settings.reduced_motion():
		_appear = 1.0


func _exit_tree() -> void:
	# Closing the screen is not consent. A pending display change goes back.
	if _confirm_left >= 0.0:
		_revert_display()


func _process(delta: float) -> void:
	_appear = minf(_appear + delta / UITheme.APPEAR_S, 1.0)
	_frost.modulate.a = UITheme.ease_out(_appear)
	_nudged += delta
	if _reset_done >= 0.0:
		_reset_done -= delta
	if _confirm_left >= 0.0:
		_confirm_left -= delta
		if _confirm_left <= 0.0:
			_revert_display()
	# Scroll eases to its target in about 120 ms.
	if Settings.reduced_motion():
		_scroll = _scroll_target
	else:
		_scroll = lerpf(_scroll, _scroll_target, 1.0 - exp(-delta * 25.0))
		if absf(_scroll - _scroll_target) < 0.5:
			_scroll = _scroll_target
	_canvas.queue_redraw()
	_list.queue_redraw()
	_top.queue_redraw()


# ------------------------------------------------------------- interaction --

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	var key: int = (event as InputEventKey).keycode
	get_viewport().set_input_as_handled()

	if _confirm_left >= 0.0:
		# While the question is up it is the only thing that can be answered.
		if event.echo:
			return
		match key:
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_Y: _keep_display()
			KEY_ESCAPE, KEY_BACKSPACE, KEY_N: _revert_display()
		return

	match key:
		KEY_UP: _move(-1)
		KEY_DOWN: _move(1)
		KEY_LEFT: _change(_selected, -1, false)
		KEY_RIGHT: _change(_selected, 1, false)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if not event.echo:
				_change(_selected, 1, true)
		KEY_PAGEUP: _move(-6)
		KEY_PAGEDOWN: _move(6)
		KEY_ESCAPE, KEY_BACKSPACE, KEY_O:
			if not event.echo:
				_close()


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var p: Vector2 = (event as InputEventMouseMotion).position
		_hover = _row_at(p)
		_hover_part = _part_at(_hover, p)
		return
	if not (event is InputEventMouseButton and event.pressed):
		return
	var press := event as InputEventMouseButton
	if press.button_index == MOUSE_BUTTON_WHEEL_UP or press.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		var dir: float = -1.0 if press.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
		_scroll_target = clampf(_scroll_target + dir * ROW_H * 1.5, 0.0, _max_scroll())
		return
	if press.button_index != MOUSE_BUTTON_LEFT:
		return
	if _confirm_left >= 0.0:
		if _keep_rect.has_point(press.position):
			_keep_display()
		elif _revert_rect.has_point(press.position):
			_revert_display()
		return
	var index: int = _row_at(press.position)
	if index < 0:
		return
	_selected = index
	_scroll_to_selected()
	var row: Array = ROWS[index]
	var rect: Rect2 = _row_canvas_rect(index)
	var sel: Rect2 = _selector_rect(rect)
	if row[2] == "volume":
		var track: Rect2 = _volume_track(sel)
		if track.grow_individual(8.0, 16.0, 8.0, 16.0).has_point(press.position):
			# A click on the track sets the level there, to the nearest step.
			var t: float = clampf((press.position.x - track.position.x) / track.size.x, 0.0, 1.0)
			_apply_choice(index, snappedf(t, VOLUME_STEP))
		return
	match _part_at(index, press.position):
		"prev": _change(index, -1, false)
		"next": _change(index, 1, false)
		"value": _change(index, 1, true)


func _row_at(point: Vector2) -> int:
	for hit in _hits:
		if (hit[0] as Rect2).has_point(point):
			return int(hit[1])
	return -1


## Which part of a row's selector the point is on.
func _part_at(index: int, point: Vector2) -> String:
	if index < 0:
		return ""
	var sel: Rect2 = _selector_rect(_row_canvas_rect(index))
	if not sel.grow_individual(0.0, 8.0, 0.0, 8.0).has_point(point):
		return ""
	if ROWS[index][2] != "choice":
		return "value"
	if point.x < sel.position.x + 44.0:
		return "prev"
	if point.x > sel.end.x - 44.0:
		return "next"
	return "value"


func _move(direction: int) -> void:
	var step: int = signi(direction)
	var index: int = _selected
	for _n in absi(direction):
		var probe: int = index
		for _i in ROWS.size():
			probe = posmod(probe + step, ROWS.size())
			if ROWS[probe][0] != "group":
				break
		# Page keys stop at the ends instead of wrapping round.
		if absi(direction) > 1 and ((step > 0 and probe < index) or (step < 0 and probe > index)):
			break
		index = probe
	_selected = index
	_scroll_to_selected()
	_play(SoundBank.ui_tick())


## Arrows and chevrons stop at the ends; Enter, Space and a click on the value
## go round, so a two-way switch toggles from either.
func _change(index: int, direction: int, wrap: bool) -> void:
	var row: Array = ROWS[index]
	var key: String = row[0]
	match row[2]:
		"volume":
			_apply_choice(index, clampf(snappedf(float(Settings.get_value(key))
					+ VOLUME_STEP * direction, VOLUME_STEP), 0.0, 1.0))
		"action":
			if wrap:
				_run_action(key)
		_:
			var choices: Array = row[3]
			var current: int = _choice_index(row)
			var next: int = posmod(current + direction, choices.size()) if wrap \
					else clampi(current + direction, 0, choices.size() - 1)
			if next != current:
				_apply_choice(index, choices[next][0])


func _run_action(key: String) -> void:
	match key:
		"reset_hints":
			Settings.reset_hints()
			_reset_done = 2.5
			_nudged = 0.0
			_play(SoundBank.ui_confirm())


func _apply_choice(index: int, value: Variant) -> void:
	var key: String = ROWS[index][0]
	if _current_value(ROWS[index]) == value:
		return
	_nudged = 0.0
	if key == "display/window_mode":
		_confirm_previous = String(Settings.get_value(key))
		Settings.set_value(key, value, false)
		_confirm_left = REVERT_SECONDS
	elif key == "interface/hints":
		# One control for both keys: the older on/off switch follows it.
		Settings.set_value("interface/key_hints", value != "off", false)
		Settings.set_value(key, value)
	else:
		Settings.set_value(key, value)
	# After the change, so a volume step is heard at the level it set.
	_play(SoundBank.ui_tick())


func _keep_display() -> void:
	_confirm_left = -1.0
	Settings.save()
	_play(SoundBank.ui_confirm())


func _revert_display() -> void:
	_confirm_left = -1.0
	Settings.set_value("display/window_mode", _confirm_previous, false)
	if is_inside_tree():
		_play(SoundBank.ui_back())


func _close() -> void:
	if _confirm_left >= 0.0:
		_revert_display()
	closed.emit()
	queue_free()


func _current_value(row: Array) -> Variant:
	if row[0] == "interface/hints":
		return Settings.hint_mode()
	if row[2] == "action":
		return null
	return Settings.get_value(row[0])


func _choice_index(row: Array) -> int:
	var value: Variant = _current_value(row)
	var choices: Array = row[3]
	for i in choices.size():
		if choices[i][0] == value:
			return i
	return 0


func _play(stream: AudioStreamWAV) -> void:
	if _sfx != null and _sfx.is_inside_tree():
		_sfx.stream = stream
		_sfx.play()


# ------------------------------------------------------------------- layout --

func _card_rect() -> Rect2:
	var size: Vector2 = _canvas.size
	var h: float = minf(size.y - 48.0, CARD_H)
	var w: float = minf(size.x - 32.0, CARD_W)
	return Rect2(roundf((size.x - w) * 0.5), roundf((size.y - h) * 0.5), w, h)


## The list's window, in canvas coordinates (before the appear shift).
func _list_rect() -> Rect2:
	var card: Rect2 = _card_rect()
	var top: float = card.position.y + HEADER_H
	var bottom: float = card.end.y - FOOTER_H - HELP_H
	return Rect2(card.position.x, top, card.size.x, bottom - top)


func _content_height() -> float:
	var h: float = 8.0
	for row in ROWS:
		h += GROUP_H if row[0] == "group" else ROW_H
	return h + 16.0


func _max_scroll() -> float:
	return maxf(_content_height() - _list_rect().size.y, 0.0)


## Row rect in list-content coordinates (0 = top of the content).
func _row_content_rect(index: int) -> Rect2:
	var y: float = 8.0
	for i in index:
		y += GROUP_H if ROWS[i][0] == "group" else ROW_H
	var h: float = GROUP_H if ROWS[index][0] == "group" else ROW_H
	return Rect2(PAD - 12.0, y, _list_rect().size.x - (PAD - 12.0) * 2.0, h)


func _row_canvas_rect(index: int) -> Rect2:
	var r: Rect2 = _row_content_rect(index)
	var list: Rect2 = _list_rect()
	r.position += list.position + _shift - Vector2(0.0, _scroll)
	return r


## Keeps the chosen row clear of the fade masks.
func _scroll_to_selected(instant: bool = false) -> void:
	var r: Rect2 = _row_content_rect(_selected)
	var view: float = _list_rect().size.y
	var margin: float = FADE_H + 8.0
	if _selected == 1:
		_scroll_target = 0.0
	elif r.position.y - margin < _scroll_target:
		_scroll_target = r.position.y - margin
	elif r.end.y + margin > _scroll_target + view:
		_scroll_target = r.end.y + margin - view
	_scroll_target = clampf(_scroll_target, 0.0, _max_scroll())
	if instant:
		_scroll = _scroll_target


func _selector_rect(row: Rect2) -> Rect2:
	return Rect2(row.end.x - 12.0 - SELECTOR_W, row.position.y + 6.0, SELECTOR_W, row.size.y - 12.0)


func _volume_track(sel: Rect2) -> Rect2:
	return Rect2(sel.position.x + 4.0, sel.get_center().y - 2.0, sel.size.x - 92.0, 4.0)


# ------------------------------------------------------------------ drawing --

func _draw_screen() -> void:
	var eased: float = UITheme.ease_out(_appear)
	_shift = Vector2(0.0, roundf((1.0 - eased) * 12.0))
	var card: Rect2 = _card_rect()
	card.position += _shift
	UITheme.draw_modal(_canvas, card, eased)

	var x: float = card.position.x + PAD
	UITheme.draw_display(_canvas, Vector2(x, card.position.y + 58.0), "Settings", 40, UITheme.TEXT)
	var sub: String = "Saved as you change them"
	if Settings.is_read_only() or not Settings.status().is_empty():
		sub = Settings.status()
	UITheme.draw_text(_canvas, Vector2(x, card.position.y + 54.0), sub, UITheme.SIZE_BODY_S,
			UITheme.WARN if Settings.is_read_only() else UITheme.TEXT_FAINT,
			HORIZONTAL_ALIGNMENT_RIGHT, card.size.x - PAD * 2.0)
	UITheme.draw_rule(_canvas, Vector2(card.position.x, card.position.y + HEADER_H - 1.0),
			card.size.x, UITheme.STROKE)

	# The list window follows the card.
	var list: Rect2 = _list_rect()
	list.position += _shift
	_list.position = list.position
	_list.size = list.size
	# Hit rects: only the part of each row inside the window.
	_hits.clear()
	for i in ROWS.size():
		if ROWS[i][0] == "group":
			continue
		var r: Rect2 = _row_canvas_rect(i).intersection(list)
		if r.size.y > 4.0:
			_hits.append([r, i])

	# The help strip: what the chosen row does, inside the card.
	var help_top: float = card.end.y - FOOTER_H - HELP_H
	_canvas.draw_rect(Rect2(card.position.x, help_top, card.size.x, HELP_H), Color(1, 1, 1, 0.025))
	UITheme.draw_rule(_canvas, Vector2(card.position.x, help_top), card.size.x, UITheme.STROKE)
	var row: Array = ROWS[_selected]
	var cy: float = help_top + HELP_H * 0.5
	_draw_info_icon(Vector2(x + 10.0, cy))
	var lines: PackedStringArray = UITheme.wrap_text(String(row[4]),
			card.size.x - PAD * 2.0 - 32.0, 19)
	if lines.size() > 1:
		UITheme.draw_text(_canvas, Vector2(x + 32.0, cy - 4.0), lines[0], 19, UITheme.TEXT_DIM)
		UITheme.draw_text(_canvas, Vector2(x + 32.0, cy + 18.0), " ".join(lines.slice(1)), 19,
				UITheme.TEXT_DIM)
	else:
		UITheme.draw_text(_canvas, Vector2(x + 32.0, cy + 7.0), String(row[4]), 19, UITheme.TEXT_DIM)
	UITheme.draw_rule(_canvas, Vector2(card.position.x, card.end.y - FOOTER_H), card.size.x,
			UITheme.STROKE)
	UITheme.draw_footer_hints(_canvas, Vector2(x, card.end.y - FOOTER_H * 0.5),
			[[["UP", "DOWN"], "choose"], [["LEFT", "RIGHT"], "change"], [["ESC"], "close"]],
			UITheme.TEXT_DIM)


func _draw_info_icon(centre: Vector2) -> void:
	_canvas.draw_arc(centre, 9.0, 0.0, TAU, 32, UITheme.TEXT_DIM, 1.5, true)
	_canvas.draw_line(centre + Vector2(0, -1.0), centre + Vector2(0, 4.5), UITheme.TEXT_DIM, 2.0)
	_canvas.draw_circle(centre + Vector2(0, -4.5), 1.3, UITheme.TEXT_DIM)


## Drawn in the list's own coordinates; the control clips it to the window.
func _draw_list() -> void:
	var offset := Vector2(0.0, -_scroll)
	for i in ROWS.size():
		var r: Rect2 = _row_content_rect(i)
		r.position += offset
		if r.end.y < -4.0 or r.position.y > _list.size.y + 4.0:
			continue
		if ROWS[i][0] == "group":
			UITheme.draw_label(_list, Vector2(PAD, r.end.y - 12.0), ROWS[i][1], UITheme.TEXT_DIM,
					UITheme.TRACK_CAPS, UITheme.SIZE_CAPS_L)
		else:
			_draw_row(r, i)
	# Fade masks where the content runs on past the window.
	var fill: Color = UITheme.SURFACE
	if _scroll > 0.5:
		UITheme.draw_scrim(_list, Rect2(0, 0, _list.size.x, FADE_H), fill.a, 0.0, fill)
	if _scroll < _max_scroll() - 0.5:
		UITheme.draw_scrim(_list, Rect2(0, _list.size.y - FADE_H, _list.size.x, FADE_H),
				0.0, fill.a, fill)


func _draw_row(rect: Rect2, index: int) -> void:
	var row: Array = ROWS[index]
	var active: bool = index == _selected
	var hovered: bool = index == _hover and not active
	var ci: CanvasItem = _list

	if active:
		ci.draw_colored_polygon(UITheme.rounded_rect(rect, UITheme.R_MD), UITheme.SURFACE_2)
		ci.draw_rect(Rect2(rect.position + Vector2(0, 10), Vector2(3, rect.size.y - 20)),
				UITheme.ACCENT)
	elif hovered:
		ci.draw_colored_polygon(UITheme.rounded_rect(rect, UITheme.R_MD), Color(1, 1, 1, 0.04))

	var mid: float = rect.position.y + rect.size.y * 0.5
	UITheme.draw_text(ci, Vector2(rect.position.x + 20.0, mid + 7.0), row[1],
			UITheme.SIZE_BODY, UITheme.TEXT if active else UITheme.TEXT_DIM)

	var sel: Rect2 = _selector_rect(rect)
	var flash: float = clampf(1.0 - _nudged * 3.0, 0.0, 1.0) if active else 0.0
	var value_colour: Color = (UITheme.TEXT if active else UITheme.TEXT_DIM) \
			.lerp(UITheme.ACCENT_HI, flash * 0.6)

	match row[2]:
		"volume":
			var level: float = float(Settings.get_value(row[0]))
			var track: Rect2 = _volume_track(sel)
			ci.draw_rect(track, Color(1, 1, 1, 0.12))
			ci.draw_rect(Rect2(track.position, Vector2(track.size.x * level, track.size.y)),
					UITheme.ACCENT if active else Color(UITheme.ACCENT.r, UITheme.ACCENT.g,
					UITheme.ACCENT.b, 0.5))
			var knob := Vector2(track.position.x + track.size.x * level, track.get_center().y)
			ci.draw_circle(knob, 6.0, UITheme.TEXT)
			if active:
				ci.draw_arc(knob, 8.0, 0.0, TAU, 24, UITheme.ACCENT, 2.0, true)
			var text: String = "%d %%" % roundi(level * 100.0)
			UITheme.draw_text(ci, Vector2(sel.end.x - 70.0, mid + 7.0), text, UITheme.SIZE_BODY,
					value_colour, HORIZONTAL_ALIGNMENT_RIGHT, 70.0, false, UITheme.font_semibold())
		"action":
			var done: bool = _reset_done >= 0.0
			var b := Rect2(sel.end.x - 140.0, rect.position.y + 4.0, 140.0, rect.size.y - 8.0)
			if done:
				UITheme.draw_check(ci, Vector2(b.position.x + 22.0, mid), 14.0, UITheme.GOOD)
				UITheme.draw_text(ci, Vector2(b.position.x + 38.0, mid + 7.0), "Done",
						UITheme.SIZE_BODY, UITheme.GOOD, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false,
						UITheme.font_semibold())
			else:
				UITheme.draw_button_ex(ci, b, "Reset", UITheme.SECONDARY,
						{"hover": index == _hover and _hover_part != "", "key": "ENTER" if active else "",
						 "size": 20})
		_:
			var choices: Array = row[3]
			var at: int = _choice_index(row)
			var label: String = String(choices[at][1])
			var base: Color = UITheme.ACCENT if active else UITheme.TEXT
			var alpha: float = 1.0 if active else 0.35
			var hover_row: bool = index == _hover
			var prev_a: float = 0.12 if at == 0 else \
					(1.0 if hover_row and _hover_part == "prev" else alpha)
			var next_a: float = 0.12 if at == choices.size() - 1 else \
					(1.0 if hover_row and _hover_part == "next" else alpha)
			UITheme.draw_chevron(ci, Vector2(sel.position.x + 12.0, mid), 3, 16.0,
					Color(base.r, base.g, base.b, prev_a))
			UITheme.draw_chevron(ci, Vector2(sel.end.x - 12.0, mid), 1, 16.0,
					Color(base.r, base.g, base.b, next_a))
			UITheme.draw_text(ci, Vector2(sel.position.x + 28.0, mid + 7.0), label,
					UITheme.SIZE_BODY, value_colour, HORIZONTAL_ALIGNMENT_CENTER,
					sel.size.x - 56.0, false, UITheme.font_semibold())


## Over the card, not instead of it: the pilot can still see what they changed.
func _draw_top() -> void:
	if _confirm_left < 0.0:
		return
	var size: Vector2 = _top.size
	_top.draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.45))
	var panel := Rect2(roundf((size.x - 640.0) * 0.5), roundf(size.y * 0.5 - 120.0), 640.0, 240.0)
	UITheme.draw_modal(_top, panel)
	_top.draw_rect(Rect2(panel.position.x + UITheme.R_LG, panel.position.y, panel.size.x
			- UITheme.R_LG * 2.0, 3.0), UITheme.WARN)
	UITheme.draw_display(_top, panel.position + Vector2(PAD, 62.0),
			"Keep this display mode?", UITheme.SIZE_H2, UITheme.TEXT)
	UITheme.draw_text(_top, panel.position + Vector2(PAD, 100.0),
			"Going back in %d s" % ceili(maxf(_confirm_left, 0.0)),
			UITheme.SIZE_BODY, UITheme.WARN)
	_top.draw_rect(Rect2(panel.position + Vector2(PAD, 118.0),
			Vector2((panel.size.x - PAD * 2.0) * clampf(_confirm_left / REVERT_SECONDS, 0.0, 1.0),
			3.0)), UITheme.WARN)

	_keep_rect = Rect2(panel.end - Vector2(PAD + 180.0, PAD + 52.0), Vector2(180.0, 52.0))
	_revert_rect = Rect2(_keep_rect.position - Vector2(192.0, 0.0), Vector2(180.0, 52.0))
	UITheme.draw_button_ex(_top, _keep_rect, "Keep", UITheme.PRIMARY, {"key": "ENTER", "focus": true})
	UITheme.draw_button_ex(_top, _revert_rect, "Go back", UITheme.SECONDARY, {"key": "ESC"})
