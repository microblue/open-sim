# OpenRC Simulator - the main menu, and the whole briefing room.
#
# Everything that decides a sortie is on this one screen, and nothing is hidden
# behind a key: the aeroplane, the place, the weather, the radio, and the fly
# button. It is laid out as a briefing card over the live field - the world is
# still there behind it, so the menu reads as something laid over the field
# rather than as a separate application.
#
#   left column   AIRCRAFT   four machines, with the numbers that tell them apart
#   right top     LOCATION   five places, each with a rendered preview
#   right bottom  WEATHER    five states, each with a preview and its wind
#   top right     the radio: is it ready? setup button
#   bottom        the fly button, with the current selection written above it
#
# Mouse and keyboard both work. Hovering a card selects it; clicking the fly
# button launches. Arrows move within the focused section, Tab changes section,
# Enter flies, Esc quits from the start screen or closes the menu in flight.
extends CanvasLayer

const UITheme := preload("res://ui/UITheme.gd")
const ScenePresetsLib := preload("res://world/ScenePresets.gd")
const WeatherLib := preload("res://world/Weather.gd")

signal fly_requested(aircraft_stem: String, scene_id: String, weather_id: String)
signal wizard_requested
signal tuning_requested

@export var input_path: NodePath
@export var simulation_path: NodePath
@export var director_path: NodePath
## True on a cold start, when closing the menu means leaving the simulator.
@export var start_screen: bool = true

var _input: RCInputNode
var _sim: RCSimulationNode
var _director: Node
var _canvas: Control

# ------------------------------------------------------------------ content --
var _aircraft: Array[Dictionary] = []
var _scenes: Array[Dictionary] = []
var _weathers: Array[Dictionary] = []

var _aircraft_index: int = 0
var _scene_index: int = 0
var _weather_index: int = 0
## Which section the keyboard moves: 0 aircraft, 1 location, 2 weather.
var _focus: int = 0

# ------------------------------------------------------------------ layout --
var _appear: float = 0.0
var _hover: Dictionary = {}           # {kind, index} or {}
## Eased 0..1 per "kind:index" card, so hover and selection glow rather than
## snap. A card that jumps instantly is a button; one that breathes is a UI.
var _card_pulse: Dictionary = {}
## The fly button's press animation, 1 while held down, decaying after.
var _press: float = 0.0
## Exit fade: 0 -> 1 before the fly action fires, so the menu leaves the way
## it arrived instead of vanishing.
var _fade: float = -1.0
var _fly_pressed: bool = false
var _hit: Array[Dictionary] = []      # rebuilt each layout
var _thumbs: Array[TextureRect] = []  # one per scene+weather card
var _thumb_textures: Dictionary = {}  # "scene:meadow" -> Texture2D or null
var _transmitter_origin := Vector2.ZERO
var _setup_rect := Rect2()
var _quit_rect := Rect2()
var _fly_rect := Rect2()

const PAD: float = 44.0


func _ready() -> void:
	layer = 20
	_input = get_node_or_null(input_path) as RCInputNode
	_sim = get_node_or_null(simulation_path) as RCSimulationNode
	_director = get_node_or_null(director_path)

	# Darken and blur enough that the panels sit on the field, not so much
	# that the field becomes a void - the world behind the menu is the point.
	add_child(UITheme.make_frosted(0.45, 1.7))

	_canvas = Control.new()
	_canvas.anchor_right = 1.0
	_canvas.anchor_bottom = 1.0
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_menu)
	_canvas.gui_input.connect(_on_gui_input)
	add_child(_canvas)

	_gather()

	# Pre-select whatever is actually loaded, so the briefing card describes the
	# session you are about to resume rather than the defaults.
	if _sim != null:
		for i in _aircraft.size():
			if _aircraft[i]["stem"] == _sim.aircraft_definition.get_file().get_basename():
				_aircraft_index = i
	if _director != null:
		for i in _scenes.size():
			if _scenes[i]["id"] == _director.get("scene_id"):
				_scene_index = i
		for i in _weathers.size():
			if _weathers[i]["id"] == _director.get("weather_id"):
				_weather_index = i

	_layout()


func _gather() -> void:
	_scenes = ScenePresetsLib.all()
	_weathers = WeatherLib.all()

	if _sim == null:
		_aircraft = [{"stem": "Trainer1500", "name": "Trainer 1500",
					  "description": "", "span": 0.0, "mass": 0.0, "approach": 0.0,
					  "loading": 0.0, "pw": 0.0}]
		return
	var restore: String = _sim.aircraft_definition
	var stems: PackedStringArray = _sim.list_aircraft()
	for stem in stems:
		_sim.aircraft_definition = "Data/Aircraft/%s.json" % stem
		if not _sim.reload_aircraft():
			continue
		_aircraft.append({
			"stem": stem,
			"name": _sim.get_aircraft_name(),
			"description": _sim.get_aircraft_description(),
			"span": _sim.get_wingspan_m(),
			"mass": _sim.get_mass_kg(),
			"approach": _sim.get_approach_speed_mps(),
			"loading": _sim.get_wing_loading_pa(),
			"pw": _sim.get_power_to_weight_w_per_kg(),
		})
	_sim.aircraft_definition = restore
	_sim.reload_aircraft()


# ------------------------------------------------------------- interaction --

func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = _hit_at((event as InputEventMouseMotion).position)
		# Hovering also selects: mouse users expect the card they are pointing
		# at to be the one that flies.
		_apply_hover_selection()
		_canvas.queue_redraw()
	elif event is InputEventMouseButton:
		var press := event as InputEventMouseButton
		if press.button_index != MOUSE_BUTTON_LEFT:
			if press.pressed and press.button_index == MOUSE_BUTTON_WHEEL_UP:
				_nudge(-1)
			elif press.pressed and press.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_nudge(1)
			return
		if press.pressed:
			var hit: Dictionary = _hit_at(press.position)
			if hit.get("action", "") == "fly":
				_fly_pressed = true
				_press = 1.0
			else:
				_press = 0.35
				_activate(hit)
		elif _fly_pressed:
			_fly_pressed = false
			_press = 0.8
			_fly()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_UP:    _nudge(-1)
		KEY_DOWN:  _nudge(1)
		KEY_LEFT:  _focus = posmod(_focus - 1, 3)
		KEY_RIGHT: _focus = posmod(_focus + 1, 3)
		KEY_TAB:   _focus = posmod(_focus + 1, 3)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: _fly()
		KEY_ESCAPE:
			if start_screen:
				get_tree().quit()
			else:
				queue_free()
		KEY_F3, KEY_C: _activate({"action": "setup"})
		KEY_F4: _activate({"action": "tuning"})
		_:
			return
	_canvas.queue_redraw()
	get_viewport().set_input_as_handled()


func _nudge(direction: int) -> void:
	match _focus:
		0: _aircraft_index = posmod(_aircraft_index + direction, maxi(_aircraft.size(), 1))
		1: _scene_index = posmod(_scene_index + direction, _scenes.size())
		2: _weather_index = posmod(_weather_index + direction, _weathers.size())


func _hit_at(point: Vector2) -> Dictionary:
	for entry in _hit:
		if (entry["rect"] as Rect2).has_point(point):
			return entry
	return {}


func _apply_hover_selection() -> void:
	if _hover.is_empty():
		return
	match _hover.get("kind", ""):
		"aircraft": _aircraft_index = int(_hover["index"]); _focus = 0
		"scene": _scene_index = int(_hover["index"]); _focus = 1
		"weather": _weather_index = int(_hover["index"]); _focus = 2


func _activate(entry: Dictionary) -> void:
	if entry.is_empty():
		return
	match entry.get("action", ""):
		"fly": _fly()
		"setup": wizard_requested.emit(); queue_free()
		"tuning": tuning_requested.emit(); queue_free()
		"quit": get_tree().quit()
		"aircraft": _aircraft_index = int(entry["index"]); _focus = 0
		"scene": _scene_index = int(entry["index"]); _focus = 1
		"weather": _weather_index = int(entry["index"]); _focus = 2


func _fly() -> void:
	if _aircraft.is_empty() or _fade >= 0.0:
		return
	_fade = 0.0


# ------------------------------------------------------------------- layout --

func _process(delta: float) -> void:
	_appear = minf(_appear + delta * 4.0, 1.0)
	_press = maxf(_press - delta * 5.0, 0.0)
	if _fade >= 0.0:
		_fade = minf(_fade + delta * 3.0, 1.0)
		if _fade >= 1.0:
			_complete_fly()

	# Ease every card's pulse toward its target: hovered or selected cards
	# breathe up, everything else settles back down.
	var targets: Dictionary = {}
	for kind in ["aircraft", "scene", "weather"]:
		var count: int = _aircraft.size() if kind == "aircraft" 				else (_scenes.size() if kind == "scene" else _weathers.size())
		for i in count:
			var key: String = "%s:%d" % [kind, i]
			var wanted: float = 1.0 if (_hover.get("kind", "") == kind
					and int(_hover.get("index", -1)) == i) else 0.0
			if kind == "aircraft" and i == _aircraft_index: wanted = 1.0
			elif kind == "scene" and i == _scene_index: wanted = 1.0
			elif kind == "weather" and i == _weather_index: wanted = 1.0
			var current: float = _card_pulse.get(key, 0.0)
			_card_pulse[key] = move_toward(current, wanted, delta * 6.0)

	var size: Vector2 = _canvas.size
	if _canvas.get_meta("layout_size", Vector2.ZERO) != size:
		_canvas.set_meta("layout_size", size)
		_layout()
	_canvas.queue_redraw()


func _complete_fly() -> void:
	if _aircraft.is_empty():
		return
	fly_requested.emit(_aircraft[_aircraft_index]["stem"],
					   _scenes[_scene_index]["id"],
					   _weathers[_weather_index]["id"])
	queue_free()


## Compute every rect once and rebuild the hit list. Called on open and on any
## resize. The scene and weather previews are child TextureRects because the
## rounded clip lives in a shader; everything else is drawn by _draw_menu.
func _layout() -> void:
	var size: Vector2 = _canvas.size
	_hit.clear()
	for thumb in _thumbs:
		if is_instance_valid(thumb):
			thumb.queue_free()
	_thumbs.clear()

	var g: Dictionary = _geometry(size)
	var top: float = g["top"]
	var aircraft_w: float = g["aircraft_w"]
	var right_x: float = g["right_x"]

	# --- aircraft cards -----------------------------------------------------
	var card_h: float = g["aircraft_card_h"]
	var gap: float = g["aircraft_gap"]
	for i in _aircraft.size():
		var rect := Rect2(PAD, top + 40.0 + float(i) * (card_h + gap),
						  aircraft_w, card_h)
		_hit.append({"rect": rect, "kind": "aircraft", "index": i, "action": "aircraft"})

	# --- scene cards --------------------------------------------------------
	for i in _scenes.size():
		var rect := Rect2(right_x + float(i) * (g["scene_w"] + g["scene_gap"]),
						  g["scene_y"], g["scene_w"], g["scene_thumb_h"])
		_hit.append({"rect": rect, "kind": "scene", "index": i, "action": "scene"})
		var thumb: TextureRect = _make_thumb("scene", _scenes[i]["id"],
				Vector2(g["scene_w"], g["scene_thumb_h"]))
		if thumb != null:
			thumb.position = rect.position
			_canvas.add_child(thumb)
			_thumbs.append(thumb)

	# --- weather cards ------------------------------------------------------
	for i in _weathers.size():
		var rect := Rect2(right_x + float(i) * (g["scene_w"] + g["scene_gap"]),
						  g["weather_y"], g["scene_w"], g["weather_thumb_h"])
		_hit.append({"rect": rect, "kind": "weather", "index": i, "action": "weather"})
		var thumb: TextureRect = _make_thumb("weather", _weathers[i]["id"],
				Vector2(g["scene_w"], g["weather_thumb_h"]))
		if thumb != null:
			thumb.position = rect.position
			_canvas.add_child(thumb)
			_thumbs.append(thumb)

	# --- header and bottom bar ----------------------------------------------
	# [transmitter 300][setup 108][quit 72] flush against the right edge.
	_transmitter_origin = Vector2(size.x - PAD - 300.0 - 8.0 - 108.0 - 8.0 - 72.0, 42.0)
	_setup_rect = Rect2(_transmitter_origin.x + 308.0, 42.0, 108.0, 64.0)
	_quit_rect = Rect2(_transmitter_origin.x + 428.0, 42.0, 72.0, 64.0)
	_hit.append({"rect": _setup_rect, "action": "setup"})
	_hit.append({"rect": _quit_rect, "action": "quit"})
	var fly_w: float = minf(420.0, size.x * 0.6)
	_fly_rect = Rect2((size.x - fly_w) * 0.5, size.y - 92.0, fly_w, 60.0)
	_hit.append({"rect": _fly_rect, "action": "fly"})

	_canvas.queue_redraw()


## One place that decides where every column and row sits. The draw functions
## and the hit-testing both read this, so what is drawn and what is clickable
## can never disagree - which is exactly how the description row came to sit on
## top of the weather thumbnails before.
##
## The layout is height-aware: the bottom bar must never cover a card, at any
## window size. On a short window the thumbnails and the aircraft cards shrink
## first, so the FLY button always sits below the content rather than on it.
func _geometry(size: Vector2) -> Dictionary:
	var fly_top: float = size.y - 92.0
	var top: float = minf(176.0, size.y * 0.24)
	var aircraft_w: float = minf(400.0, size.x * 0.32)
	var right_x: float = PAD + aircraft_w + 36.0
	var right_w: float = maxf(size.x - right_x - PAD - 12.0, 200.0)
	var scene_gap: float = 14.0
	var scene_w: float = (right_w - scene_gap * float(maxi(_scenes.size() - 1, 1))) \
			/ float(maxi(_scenes.size(), 1))

	# Vertical budget from the section top to the bottom bar, minus what the
	# labels need: scene name, one-line tag, weather heading, weather name and
	# its wind line. Whatever is left is split between the two thumbnail rows.
	var scene_name_size: int = _fit_size(_widest_name(_scenes), scene_w)
	var fixed_text: float = 26.0 + 16.0 + 34.0 + 19.0 + 24.0
	var available_thumbs: float = fly_top - top - 40.0 - fixed_text - 10.0
	var scene_thumb_h: float = minf(scene_w * 9.0 / 16.0, available_thumbs * 0.56)
	var weather_thumb_h: float = minf(scene_thumb_h * 0.8, available_thumbs - scene_thumb_h)
	scene_thumb_h = maxf(scene_thumb_h, 30.0)
	weather_thumb_h = maxf(weather_thumb_h, 24.0)

	# Aircraft cards shrink the same way, so the last card clears the bottom bar.
	var aircraft_card_h: float = minf(76.0,
			(fly_top - top - 40.0 - 3.0 * 12.0 - 10.0) / float(maxi(_aircraft.size(), 1)))
	var aircraft_gap: float = 12.0

	var scene_block: float = scene_thumb_h + 21.0 + float(scene_name_size) \
			+ 8.0 + 15.0 + 14.0
	var weather_y: float = top + 40.0 + scene_block + 34.0

	return {
		"top": top,
		"aircraft_w": aircraft_w,
		"aircraft_card_h": aircraft_card_h,
		"aircraft_gap": aircraft_gap,
		"right_x": right_x,
		"scene_gap": scene_gap,
		"scene_w": scene_w,
		"scene_thumb_h": scene_thumb_h,
		"scene_y": top + 40.0,
		"scene_name_size": scene_name_size,
		"weather_y": weather_y,
		"weather_thumb_h": weather_thumb_h,
	}


func _widest_name(entries: Array[Dictionary]) -> String:
	var widest: String = ""
	for entry in entries:
		if UITheme.text_width(entry["name"], UITheme.SIZE_TITLE) \
				> UITheme.text_width(widest, UITheme.SIZE_TITLE):
			widest = entry["name"]
	return widest


## Load a preview for the menu, or null to draw a placeholder instead.
##
## The previews live in assets/previews/ - a directory that IS exported - so a
## packaged build shows the real places and weather states. They are generated
## by tests/SceneShots.gd (which needs a display, so they are not committed; a
## fresh checkout gets the placeholder until the renderer has run once). The
## shots/ copies are the debug output and are excluded from the export, hence
## the fallback rather than loading from there directly.
func _make_thumb(kind: String, id: String, size: Vector2) -> TextureRect:
	var key: String = "%s:%s" % [kind, id]
	if not _thumb_textures.has(key):
		var texture: Texture2D = null
		for path in ["res://assets/previews/%s_%s.png" % [kind, id],
					 "res://shots/%s_%s.png" % [kind, id]]:
			if ResourceLoader.exists(path):
				texture = load(path) as Texture2D
				break
		_thumb_textures[key] = texture
	var texture: Texture2D = _thumb_textures[key]
	if texture == null:
		return null
	return UITheme.make_thumb(texture, size, 10.0)


# ------------------------------------------------------------------- drawing --

func _draw_menu() -> void:
	var size: Vector2 = _canvas.size
	var ease_in: float = 1.0 - pow(1.0 - _appear, 3.0)
	var slide: float = (1.0 - ease_in) * 26.0
	var shift := Vector2(0.0, slide)

	_draw_header(size, shift)
	_draw_aircraft(size, shift)
	_draw_scenes(size, shift)
	_draw_weather(size, shift)
	_draw_footer(size)

	# Exit fade: the whole menu sinks into the dark before the fly action
	# fires, so the world does not snap in.
	if _fade > 0.0:
		_canvas.draw_rect(Rect2(Vector2.ZERO, size),
						  Color(0, 0, 0, _fade * 0.85), true)

	if _appear < 1.0 or _fade >= 0.0:
		_canvas.queue_redraw()


func _draw_header(size: Vector2, shift: Vector2) -> void:
	var origin := Vector2(PAD, 58.0) + shift

	UITheme.draw_text_shadow(_canvas, Vector2(PAD, origin.y + 52.0), "OPENRC",
							 UITheme.SIZE_DISPLAY, UITheme.TEXT,
							 Color(0, 0, 0, 0.6))
	UITheme.draw_label(_canvas, origin + Vector2(5, 88),
					  "RC FLIGHT TRAINING SIMULATOR", UITheme.ACCENT, 3.0,
					  UITheme.SIZE_SECTION)
	UITheme.draw_rule(_canvas, origin + Vector2(0, 106), 340.0,
					  UITheme.STROKE_STRONG, 2.0)

	_draw_transmitter(_transmitter_origin + shift)


## The one thing worth knowing before flying: is the radio ready? It carries the
## setup button, because a radio that is not ready is the only reason to leave
## this screen before flying.
func _draw_transmitter(origin: Vector2) -> void:
	var rect := Rect2(origin, Vector2(300, 64))
	var ready: bool = _input != null and _input.is_connected() and _input.is_fully_bound()
	var connected: bool = _input != null and _input.is_connected()
	# Amber is reserved for "needs action". A radio that is simply not plugged
	# in yet is a neutral state, not an error - paint it dim, not warning.
	var state_colour: Color = UITheme.GOOD if ready \
			else (UITheme.WARN if connected else UITheme.TEXT_DIM)

	UITheme.draw_panel(_canvas, rect,
			Color(state_colour.r, state_colour.g, state_colour.b, 0.10),
			state_colour, 10.0)

	UITheme.draw_label(_canvas, origin + Vector2(14, 18), "transmitter",
					   state_colour, 2.4)
	var device: String = "none detected"
	if _input != null and _input.is_connected():
		device = _input.get_device_name().substr(0, 26)
	var state: String = "READY" if ready else "SET UP"
	UITheme.draw_text(_canvas, origin + Vector2(14, 44), device,
					  UITheme.SIZE_LABEL, UITheme.TEXT)
	UITheme.draw_text(_canvas, origin + Vector2(300 - 74, 44), state,
					  UITheme.SIZE_LABEL, state_colour,
					  HORIZONTAL_ALIGNMENT_RIGHT, 64.0)

	var hovered: bool = _hover.get("action", "") == "setup"
	UITheme.draw_panel(_canvas, _setup_rect,
			Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, 0.16),
			UITheme.ACCENT if hovered else UITheme.STROKE_STRONG, 10.0)
	UITheme.draw_text(_canvas, _setup_rect.position + Vector2(54, 33), "SETUP",
					  UITheme.SIZE_SECTION, UITheme.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)

	UITheme.draw_panel(_canvas, _quit_rect, UITheme.PANEL,
			UITheme.STROKE_STRONG, 10.0)
	UITheme.draw_text(_canvas, _quit_rect.position + Vector2(36, 33), "QUIT",
					  UITheme.SIZE_SECTION, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)


func _section_heading(pos: Vector2, text: String, count: int, active: bool) -> void:
	UITheme.draw_label(_canvas, pos, text,
					   UITheme.ACCENT if active else UITheme.TEXT_DIM, 2.6,
					   UITheme.SIZE_SECTION)
	var y: float = pos.y + 22.0
	UITheme.draw_rule(_canvas, Vector2(pos.x, y), 260.0,
					  UITheme.ACCENT if active else UITheme.STROKE)


func _draw_aircraft(size: Vector2, shift: Vector2) -> void:
	var g: Dictionary = _geometry(size)
	var top: float = g["top"]
	_section_heading(Vector2(PAD, top) + shift, "AIRCRAFT", _aircraft.size(),
					 _focus == 0)

	var card_h: float = g["aircraft_card_h"]
	var gap: float = g["aircraft_gap"]
	var aircraft_w: float = g["aircraft_w"]
	for i in _aircraft.size():
		var rect := Rect2(PAD, top + 40.0 + float(i) * (card_h + gap),
						  aircraft_w, card_h)
		var selected: bool = i == _aircraft_index
		var hovered: bool = _hover.get("kind", "") == "aircraft" \
				and int(_hover.get("index", -1)) == i
		_draw_card(rect, selected, hovered, _focus == 0,
				   _card_pulse.get("aircraft:%d" % i, 0.0))

		var card: Dictionary = _aircraft[i]
		var x: float = rect.position.x + 18.0
		var name_colour: Color = UITheme.TEXT if selected or hovered else UITheme.TEXT_DIM
		UITheme.draw_text(_canvas, Vector2(x, rect.position.y + 27.0),
						  card["name"], UITheme.SIZE_VALUE, name_colour)
		var specs: String = "%.1f m span   %.2f kg   app %.0f m/s" % [
			card["span"], card["mass"], card["approach"]]
		UITheme.draw_text(_canvas, Vector2(x, rect.position.y + 55.0),
						  specs, UITheme.SIZE_LABEL, UITheme.TEXT_DIM)

	# The space below the roster belongs to the aeroplane that is actually
	# selected: what it is, and the two numbers that say how it flies. This is
	# the brief. It is drawn only when it fits above the bottom bar - on a
	# short window the roster shrinks and the brief yields rather than sliding
	# under the FLY button - and its text is clipped to the column so it can
	# never reach across into the button's space.
	if not _aircraft.is_empty():
		var card: Dictionary = _aircraft[_aircraft_index]
		var y: float = top + 40.0 + float(_aircraft.size()) * (card_h + gap) + 10.0
		var max_y: float = size.y - 104.0
		var text_w: float = aircraft_w - 24.0
		if y + 96.0 < max_y:
			UITheme.draw_label(_canvas, Vector2(PAD, y), "briefing",
							   UITheme.ACCENT, 2.6, UITheme.SIZE_SECTION)
			y += 26.0
			var detail: String = "%.0f N/m2 loading   %.0f W/kg   app %.0f m/s" % [
				card["loading"], card["pw"], card["approach"]]
			UITheme.draw_text(_canvas, Vector2(PAD, y),
							  _clip(detail, text_w, UITheme.SIZE_LABEL),
							  UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
			y += 22.0
			for line in _wrap(_clip(card["description"], text_w, UITheme.SIZE_LABEL), 40):
				if y + 18.0 > max_y:
					break
				UITheme.draw_text(_canvas, Vector2(PAD, y), line,
								  UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
				y += 18.0


func _draw_scenes(size: Vector2, shift: Vector2) -> void:
	var g: Dictionary = _geometry(size)
	var right_x: float = g["right_x"]

	_section_heading(Vector2(right_x, g["top"]) + shift, "LOCATION", _scenes.size(),
					 _focus == 1)

	for i in _scenes.size():
		var rect := Rect2(right_x + float(i) * (g["scene_w"] + g["scene_gap"]),
						  g["scene_y"], g["scene_w"], g["scene_thumb_h"])
		var selected: bool = i == _scene_index
		var hovered: bool = _hover.get("kind", "") == "scene" \
				and int(_hover.get("index", -1)) == i

		if _thumb_textures.get("scene:%s" % _scenes[i]["id"]) == null:
			_draw_placeholder(rect, _scenes[i]["name"], UITheme.ACCENT)
		_draw_card(rect, selected, hovered, _focus == 1,
				   _card_pulse.get("scene:%d" % i, 0.0))
		# One size for every name in the row, chosen for the widest - a row
		# where one card's label silently shrinks reads as a rendering bug.
		# The name is all the card carries: a description line truncated to fit
		# a narrow card reads as broken text, so the description lives on the
		# selected card only (the aircraft column's brief) and in the world.
		var name_y: float = rect.end.y + 21.0
		UITheme.draw_text(_canvas, Vector2(rect.position.x, name_y),
						  _scenes[i]["name"], g["scene_name_size"],
						  UITheme.TEXT if selected else UITheme.TEXT_DIM)


func _draw_weather(size: Vector2, shift: Vector2) -> void:
	var g: Dictionary = _geometry(size)
	var right_x: float = g["right_x"]

	_section_heading(Vector2(right_x, g["weather_y"] - 40.0) + shift, "WEATHER",
					 _weathers.size(), _focus == 2)

	for i in _weathers.size():
		var rect := Rect2(right_x + float(i) * (g["scene_w"] + g["scene_gap"]),
						  g["weather_y"], g["scene_w"], g["weather_thumb_h"])
		var selected: bool = i == _weather_index
		var hovered: bool = _hover.get("kind", "") == "weather" \
				and int(_hover.get("index", -1)) == i

		if _thumb_textures.get("weather:%s" % _weathers[i]["id"]) == null:
			_draw_placeholder(rect, _weathers[i]["name"], UITheme.ACCENT_DIM)
		_draw_card(rect, selected, hovered, _focus == 2,
				   _card_pulse.get("weather:%d" % i, 0.0))

		var x: float = rect.position.x
		var name_y: float = rect.end.y + 19.0
		UITheme.draw_text(_canvas, Vector2(x, name_y), _weathers[i]["name"],
						  UITheme.SIZE_VALUE,
						  UITheme.TEXT if selected else UITheme.TEXT_DIM)
		var wind: String = "%.1f m/s" % _weathers[i]["wind_mps"]
		UITheme.draw_text(_canvas, Vector2(x, name_y + 25.0), wind,
						  UITheme.SIZE_LABEL, UITheme.ACCENT if selected else UITheme.TEXT_DIM)


## The largest of the card title sizes that fits `text` in `width` pixels.
func _fit_size(text: String, width: float) -> int:
	for size in [UITheme.SIZE_TITLE, UITheme.SIZE_VALUE, UITheme.SIZE_LABEL]:
		if UITheme.text_width(text, size) <= width:
			return size
	return UITheme.SIZE_LABEL


func _clip(text: String, width: float, size: int) -> String:
	if UITheme.text_width(text, size) <= width:
		return text
	var out: String = text.strip_edges()
	while not out.is_empty() and UITheme.text_width(out + "…", size) > width:
		out = out.substr(0, out.length() - 1).strip_edges()
	return out + "…"


## One card: a translucent panel, an accent edge when selected, a brightened
## edge on hover, and a left rule on the focus section's selection.
func _draw_card(rect: Rect2, selected: bool, hovered: bool, focused: bool,
				pulse: float = 0.0) -> void:
	# The pulse is eased in _process, so the glow and the lift grow smoothly
	# instead of appearing. A slight lift - the card body moves up a couple of
	# pixels with its glow - is what reads as "this one is alive".
	var lifted := Rect2(rect.position - Vector2(0, pulse * 2.0), rect.size)
	var fill: Color = UITheme.PANEL
	var stroke: Color = UITheme.STROKE
	if selected:
		fill = Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b,
					 0.10 + 0.10 * pulse)
		stroke = UITheme.ACCENT
	if hovered and not selected:
		stroke = UITheme.STROKE_STRONG
	if pulse > 0.01:
		UITheme.draw_glow(_canvas, lifted, UITheme.ACCENT, 10.0,
						  int(1.0 + pulse * 2.0))
	UITheme.draw_panel(_canvas, lifted, fill, stroke, 10.0)
	if selected and focused:
		_canvas.draw_rect(Rect2(lifted.position, Vector2(3, lifted.size.y)),
						  UITheme.ACCENT, true)


func _draw_placeholder(rect: Rect2, name: String, colour: Color) -> void:
	var points: PackedVector2Array = UITheme.rounded_rect(rect, 10.0)
	_canvas.draw_colored_polygon(points, Color(0.10, 0.13, 0.17, 0.9))
	_canvas.draw_line(rect.position, rect.end, Color(colour.r, colour.g, colour.b, 0.18), 2.0)
	_canvas.draw_line(Vector2(rect.end.x, rect.position.y),
					  Vector2(rect.position.x, rect.end.y),
					  Color(colour.r, colour.g, colour.b, 0.10), 2.0)
	UITheme.draw_text(_canvas, rect.position + rect.size * 0.5 + Vector2(0, 6),
					  name.substr(0, 1), UITheme.SIZE_LARGE, colour,
					  HORIZONTAL_ALIGNMENT_CENTER, rect.size.x)


func _draw_footer(size: Vector2) -> void:
	var fly_rect: Rect2 = _fly_rect
	var hovered: bool = _hover.get("action", "") == "fly"
	var fly_w: float = fly_rect.size.x
	# Pressed: the button sinks a couple of pixels and loses its glow, so a
	# press is felt as well as seen.
	var sink: float = _press * 2.0
	var pressed_rect := Rect2(fly_rect.position + Vector2(0, sink), fly_rect.size)
	var fill_alpha: float = 0.92 if hovered else 0.78

	UITheme.draw_glow(_canvas, pressed_rect, UITheme.ACCENT, 12.0,
					  3 if _press < 0.1 else 1)
	UITheme.draw_panel(_canvas, pressed_rect,
			Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b,
				  fill_alpha * (1.0 - _press * 0.35)),
			Color(1, 1, 1, 0.5 if hovered else 0.25), 12.0)
	_canvas.draw_line(pressed_rect.position + Vector2(14, 5),
					  pressed_rect.position + Vector2(fly_w - 14, 5),
					  Color(1, 1, 1, 0.35), 1.0)
	UITheme.draw_text_shadow(_canvas,
			pressed_rect.position + Vector2(fly_w * 0.5, 38.0), "FLY",
			UITheme.SIZE_LARGE, Color(0.02, 0.06, 0.09, 1.0),
			Color(0, 0, 0, 0.4))

	# The briefing line: what exactly you are about to fly, on a panel so it
	# reads as a status chip rather than a floating string.
	var summary: String = "%s   %s   %s   wind %.1f m/s" % [
		_aircraft[_aircraft_index]["name"] if not _aircraft.is_empty() else "",
		_scenes[_scene_index]["name"],
		_weathers[_weather_index]["name"],
		_weathers[_weather_index]["wind_mps"]]
	var sum_w: float = minf(UITheme.text_width(summary, UITheme.SIZE_SECTION) + 48.0,
							size.x - 80.0)
	var sum_rect := Rect2((size.x - sum_w) * 0.5, size.y - 112.0, sum_w, 30.0)
	UITheme.draw_panel(_canvas, sum_rect, Color(0, 0, 0, 0.35), UITheme.STROKE, 8.0)
	UITheme.draw_text(_canvas, Vector2(size.x * 0.5, size.y - 93.0), summary,
					  UITheme.SIZE_SECTION, UITheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER,
					  sum_w - 20.0)

	UITheme.draw_text(_canvas, Vector2(size.x - PAD, size.y - 24.0),
					  "arrows choose   tab section   enter fly   esc %s" %
					  ("quit" if start_screen else "back"),
					  UITheme.SIZE_LABEL, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_RIGHT)


static func _wrap(text: String, columns: int) -> PackedStringArray:
	var lines := PackedStringArray()
	var current := ""
	for word in text.split(" ", false):
		if current.is_empty():
			current = word
		elif current.length() + 1 + word.length() <= columns:
			current += " " + word
		else:
			lines.append(current)
			current = word
	if not current.is_empty():
		lines.append(current)
	return lines
