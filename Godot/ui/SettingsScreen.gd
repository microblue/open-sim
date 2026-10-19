# OpenRC Simulator - settings.
#
# One card, a list of rows, nothing nested. A settings screen in a flight
# simulator is visited twice - once on the first evening and once when
# something is wrong - so everything is on the one page, with a sentence under
# the chosen row saying what it changes. Every row changes live, so the pilot
# hears the volume move and sees the HUD switch to feet while they are still
# looking at the setting that did it.
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
const CARD_TOP: float = 184.0
const ROW_H: float = 54.0
const GROUP_H: float = 46.0
## Room kept below the card for the selected row's sentence and the key line.
const BELOW_CARD: float = 128.0
## The rows never shrink below this share of their natural height; past that a
## window is too small for this screen, and the card simply runs long.
const MIN_ROW_SCALE: float = 0.72
const VOLUME_STEP: float = 0.05

## key, label, kind, choices ([value, label] for a choice row), what it does.
const ROWS: Array = [
	["group", "audio"],
	["audio/game_volume", "Game volume", "volume", [],
		"The aeroplane, the air and the ground: everything in the world."],
	["audio/menu_volume", "Menu and music", "volume", [],
		"The briefing room's music and the interface clicks."],
	["group", "display"],
	["display/window_mode", "Window", "choice",
		[["windowed", "Windowed"], ["fullscreen", "Fullscreen (borderless)"]],
		"Asks to keep a change, and goes back by itself after 15 seconds if not."],
	["display/units", "Units", "choice",
		[["metric", "Metric   km/h  ·  m"],
		 ["imperial", "Imperial   mph  ·  ft  ·  ft/min"],
		 ["si", "SI   m/s  ·  m"]],
		"Airspeed, height and climb rate on the flight overlay."],
	["group", "flying"],
	["controls/stick_mode", "Stick mode", "choice",
		[[2, "Mode 2   throttle on the left"], [1, "Mode 1   throttle on the right"]],
		"The overlay's gimbals and the keyboard. Mode 1: throttle on the up/down arrows, elevator on W/S."],
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
		"One failure, after 20 s to 2 min of proper flight, never on the ground. R starts a new flight; Shift+R flies the same one again."],
	["practice/failure_notice", "Failure notice", "choice",
		[[true, "Shown"], [false, "Hidden"]],
		"Hidden keeps every symptom and drops the words: find out what broke the way a real pilot has to."],
	["practice/radio_failures", "Radio failures", "choice",
		[[false, "Not included"], [true, "Included"]],
		"Radio loss and brownout in the pool, as well as motor and control failures."],
	["group", "interface"],
	["interface/key_hints", "Key hints", "choice",
		[[true, "Shown"], [false, "Hidden"]],
		"The line of keys along the bottom of the flight overlay."],
	["interface/reduced_motion", "Reduced motion", "choice",
		[[false, "Off"], [true, "On"]],
		"No sliding screens, no pulsing banners, no eased camera zoom."],
]

var _canvas: Control
var _sfx: AudioStreamPlayer
## Index into ROWS of the highlighted row; never a group.
var _selected: int = 1
var _appear: float = 0.0
var _nudged: float = 999.0
var _hover: int = -1
## Row rects, rebuilt each draw: [rect, row index].
var _hits: Array = []

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

	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Stops the pointer here: the menu underneath has hover states of its own.
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_screen)
	_canvas.gui_input.connect(_on_gui_input)
	add_child(_canvas)
	if Settings.reduced_motion():
		_appear = 1.0


func _exit_tree() -> void:
	# Closing the screen is not consent. A pending display change goes back.
	if _confirm_left >= 0.0:
		_revert_display()


func _process(delta: float) -> void:
	_appear = minf(_appear + delta * 4.0, 1.0)
	_nudged += delta
	if _confirm_left >= 0.0:
		_confirm_left -= delta
		if _confirm_left <= 0.0:
			_revert_display()
	_canvas.queue_redraw()


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
		KEY_LEFT: _change(_selected, -1)
		KEY_RIGHT, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: _change(_selected, 1)
		KEY_ESCAPE, KEY_BACKSPACE, KEY_O:
			if not event.echo:
				_close()


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = _row_at((event as InputEventMouseMotion).position)
		return
	if not (event is InputEventMouseButton and event.pressed):
		return
	var press := event as InputEventMouseButton
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
	var row: Array = ROWS[index]
	var value_rect: Rect2 = _value_rect(_row_rect(index))
	if row[2] == "volume" and value_rect.grow(8.0).has_point(press.position):
		# A click on the track sets the level there, to the nearest step.
		var t: float = clampf((press.position.x - value_rect.position.x)
				/ value_rect.size.x, 0.0, 1.0)
		_apply_choice(index, snappedf(t, VOLUME_STEP))
	else:
		# Left third of the value goes back, the rest goes forward, like the
		# two chevrons drawn there.
		var back: bool = press.position.x < value_rect.position.x + 60.0
		_change(index, -1 if back else 1)


func _row_at(point: Vector2) -> int:
	for hit in _hits:
		if (hit[0] as Rect2).has_point(point):
			return int(hit[1])
	return -1


func _move(direction: int) -> void:
	var index: int = _selected
	for _i in ROWS.size():
		index = posmod(index + direction, ROWS.size())
		if ROWS[index][0] != "group":
			break
	_selected = index
	_play(SoundBank.ui_tick())


func _change(index: int, direction: int) -> void:
	var row: Array = ROWS[index]
	var key: String = row[0]
	if row[2] == "volume":
		_apply_choice(index, clampf(snappedf(float(Settings.get_value(key))
				+ VOLUME_STEP * direction, VOLUME_STEP), 0.0, 1.0))
		return
	var choices: Array = row[3]
	var current: int = _choice_index(row)
	_apply_choice(index, choices[posmod(current + direction, choices.size())][0])


func _apply_choice(index: int, value: Variant) -> void:
	var key: String = ROWS[index][0]
	if Settings.get_value(key) == value:
		return
	_nudged = 0.0
	if key == "display/window_mode":
		_confirm_previous = String(Settings.get_value(key))
		Settings.set_value(key, value, false)
		_confirm_left = REVERT_SECONDS
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


func _choice_index(row: Array) -> int:
	var value: Variant = Settings.get_value(row[0])
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

## How much the rows are squeezed to fit the window. Every row the screen
## gains costs height, and at 1080 lines the practice group pushed the last row
## under the key line; the rows give a little rather than the screen scrolling.
func _row_scale(size: Vector2) -> float:
	var natural: float = 40.0
	for row in ROWS:
		natural += GROUP_H if row[0] == "group" else ROW_H
	var room: float = size.y - CARD_TOP - BELOW_CARD
	return clampf(room / natural, MIN_ROW_SCALE, 1.0)


func _height_of(row: Array, scale: float) -> float:
	return (GROUP_H if row[0] == "group" else ROW_H) * scale


func _card_rect(size: Vector2) -> Rect2:
	var scale: float = _row_scale(size)
	var height: float = 40.0
	for row in ROWS:
		height += _height_of(row, scale)
	return Rect2((size.x - CARD_W) * 0.5, CARD_TOP, CARD_W, height)


func _row_rect(index: int) -> Rect2:
	var card: Rect2 = _card_rect(_canvas.size)
	var scale: float = _row_scale(_canvas.size)
	var y: float = card.position.y + 20.0
	for i in index:
		y += _height_of(ROWS[i], scale)
	return Rect2(card.position.x + 16.0, y, card.size.x - 32.0, _height_of(ROWS[index], scale))


## Where a row's value sits: the right half of the row.
func _value_rect(row: Rect2) -> Rect2:
	return Rect2(row.position.x + row.size.x * 0.46, row.position.y + 10.0,
				 row.size.x * 0.54 - 24.0, row.size.y - 20.0)


# ------------------------------------------------------------------ drawing --

func _draw_screen() -> void:
	var size: Vector2 = _canvas.size
	var eased: float = 1.0 - pow(1.0 - _appear, 3.0)
	var shift := Vector2(0.0, (1.0 - eased) * 26.0)

	# Opaque, the lesson the world screen learned: at 0.94 the menu's own hint
	# line read through and collided with this one along the bottom.
	_canvas.draw_rect(Rect2(Vector2.ZERO, size),
			Color(UITheme.BASE.r, UITheme.BASE.g, UITheme.BASE.b, eased))

	UITheme.draw_display(_canvas, Vector2(0.0, 112.0) + shift, "SETTINGS",
			UITheme.SIZE_HERO, UITheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER, size.x)
	var sub: String = "saved as you change them"
	if Settings.is_read_only() or not Settings.status().is_empty():
		sub = Settings.status()
	UITheme.draw_text(_canvas, Vector2(0.0, 150.0) + shift, sub, UITheme.SIZE_BODY,
			UITheme.WARN if Settings.is_read_only() else UITheme.TEXT_DIM,
			HORIZONTAL_ALIGNMENT_CENTER, size.x)

	var card: Rect2 = _card_rect(size)
	card.position += shift
	UITheme.draw_panel(_canvas, card, UITheme.PANEL_SOLID, UITheme.STROKE_STRONG, 12.0)

	_hits.clear()
	for i in ROWS.size():
		var rect: Rect2 = _row_rect(i)
		rect.position += shift
		if ROWS[i][0] == "group":
			_draw_group(rect, ROWS[i][1], i == 0)
		else:
			_hits.append([rect, i])
			_draw_row(rect, i)

	# What the chosen row does, under the card, always in the same place.
	var row: Array = ROWS[_selected]
	UITheme.draw_text(_canvas, Vector2(0.0, card.end.y + 40.0), row[4],
			UITheme.SIZE_BODY, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER, size.x)

	if _confirm_left >= 0.0:
		_draw_confirm(size, card)

	UITheme.draw_text(_canvas, Vector2(0.0, size.y - 36.0),
			"up / down   choose        left / right   change        esc   close",
			UITheme.SIZE_BODY, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER, size.x)


func _draw_group(rect: Rect2, title: String, first: bool) -> void:
	if not first:
		UITheme.draw_rule(_canvas, rect.position + Vector2(8.0, 8.0),
				rect.size.x - 16.0, UITheme.STROKE)
	UITheme.draw_label(_canvas, rect.position + Vector2(16.0, rect.size.y - 10.0), title,
			UITheme.TEXT_FAINT, 2.4, UITheme.SIZE_LABEL)


func _draw_row(rect: Rect2, index: int) -> void:
	var row: Array = ROWS[index]
	var active: bool = index == _selected
	var hovered: bool = index == _hover and not active

	if active:
		UITheme.draw_panel(_canvas, rect,
				Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, 0.10),
				Color(0, 0, 0, 0), 8.0)
		_canvas.draw_rect(Rect2(rect.position + Vector2(0, 8), Vector2(3, rect.size.y - 16)),
				UITheme.ACCENT, true)
	elif hovered:
		UITheme.draw_panel(_canvas, rect, Color(1, 1, 1, 0.04), Color(0, 0, 0, 0), 8.0)

	UITheme.draw_text(_canvas, rect.position + Vector2(24.0, rect.size.y * 0.5 + 8.0), row[1],
			UITheme.SIZE_VALUE, UITheme.TEXT if active else UITheme.TEXT_DIM)

	var value: Rect2 = _value_rect(rect)
	var flash: float = clampf(1.0 - _nudged * 3.0, 0.0, 1.0) if active else 0.0
	var colour: Color = (UITheme.ACCENT if active else UITheme.TEXT_DIM) \
			.lerp(Color.WHITE, flash * 0.5)

	if row[2] == "volume":
		var level: float = float(Settings.get_value(row[0]))
		var text: String = "%d %%" % roundi(level * 100.0)
		var text_w: float = 76.0
		var track := Rect2(value.position + Vector2(0, value.size.y * 0.5 - 3.0),
				Vector2(value.size.x - text_w - 16.0, 6.0))
		UITheme.draw_track(_canvas, track, level,
				Color(colour.r, colour.g, colour.b, 0.9 if active else 0.45))
		UITheme.draw_text(_canvas, Vector2(value.end.x - text_w, rect.position.y + rect.size.y * 0.5 + 8.0),
				text, UITheme.SIZE_VALUE, colour, HORIZONTAL_ALIGNMENT_RIGHT, text_w)
		return

	var choice: Array = row[3][_choice_index(row)]
	var label: String = String(choice[1])
	# Chevrons only on the row that has the keyboard: on every row they are a
	# column of noise.
	if active:
		UITheme.draw_text(_canvas, Vector2(value.position.x, rect.position.y + rect.size.y * 0.5 + 8.0),
				"<", UITheme.SIZE_VALUE, UITheme.ACCENT)
		UITheme.draw_text(_canvas, Vector2(value.end.x - 14.0, rect.position.y + rect.size.y * 0.5 + 8.0),
				">", UITheme.SIZE_VALUE, UITheme.ACCENT)
	UITheme.draw_text(_canvas, Vector2(value.position.x + 36.0, rect.position.y + rect.size.y * 0.5 + 8.0),
			label, UITheme.SIZE_VALUE, colour)


## Over the card, not instead of it: the pilot can still see what they changed.
func _draw_confirm(size: Vector2, card: Rect2) -> void:
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.45))
	var panel := Rect2(Vector2((size.x - 760.0) * 0.5, card.position.y + card.size.y * 0.5 - 110.0),
			Vector2(760.0, 220.0))
	UITheme.draw_glow(_canvas, panel, UITheme.WARN, 12.0, 2)
	UITheme.draw_panel(_canvas, panel, UITheme.PANEL_SOLID,
			Color(UITheme.WARN.r, UITheme.WARN.g, UITheme.WARN.b, 0.6), 12.0)
	UITheme.draw_label(_canvas, panel.position + Vector2(36.0, 50.0),
			"keep this display mode?", UITheme.WARN, 2.4, UITheme.SIZE_VALUE)
	UITheme.draw_text(_canvas, panel.position + Vector2(36.0, 92.0),
			"Reverting in %d s" % ceili(maxf(_confirm_left, 0.0)),
			UITheme.SIZE_VALUE, UITheme.TEXT)
	UITheme.draw_track(_canvas, Rect2(panel.position + Vector2(36.0, 108.0),
			Vector2(panel.size.x - 72.0, 4.0)), _confirm_left / REVERT_SECONDS,
			UITheme.WARN)

	_keep_rect = Rect2(panel.end - Vector2(36.0 + 200.0, 82.0), Vector2(200.0, 56.0))
	_revert_rect = Rect2(_keep_rect.position - Vector2(216.0, 0.0), Vector2(200.0, 56.0))
	UITheme.draw_panel(_canvas, _keep_rect,
			Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, 0.22),
			UITheme.ACCENT, 10.0)
	UITheme.draw_display(_canvas, _keep_rect.position + Vector2(0, 40), "KEEP",
			UITheme.SIZE_TITLE, UITheme.ACCENT, HORIZONTAL_ALIGNMENT_CENTER, _keep_rect.size.x)
	UITheme.draw_panel(_canvas, _revert_rect, UITheme.PANEL, UITheme.STROKE_STRONG, 10.0)
	UITheme.draw_display(_canvas, _revert_rect.position + Vector2(0, 40), "REVERT",
			UITheme.SIZE_TITLE, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER,
			_revert_rect.size.x)
	UITheme.draw_text(_canvas, panel.position + Vector2(36.0, panel.size.y - 40.0),
			"enter keep     esc revert", UITheme.SIZE_LABEL, UITheme.TEXT_FAINT)
