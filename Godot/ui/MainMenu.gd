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

	add_child(UITheme.make_frosted(0.78, 3.6))

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
					  "description": "", "span": 0.0, "mass": 0.0, "approach": 0.0}]
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
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var press := event as InputEventMouseButton
		if press.button_index == MOUSE_BUTTON_LEFT:
			_activate(_hit_at(press.position))
		elif press.button_index == MOUSE_BUTTON_WHEEL_UP:
			_nudge(-1)
		elif press.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_nudge(1)


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
	if _aircraft.is_empty():
		return
	fly_requested.emit(_aircraft[_aircraft_index]["stem"],
					   _scenes[_scene_index]["id"],
					   _weathers[_weather_index]["id"])
	queue_free()


# ------------------------------------------------------------------- layout --

func _process(delta: float) -> void:
	_appear = minf(_appear + delta * 4.0, 1.0)
	var size: Vector2 = _canvas.size
	if _canvas.get_meta("layout_size", Vector2.ZERO) != size:
		_canvas.set_meta("layout_size", size)
		_layout()
	_canvas.queue_redraw()


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

	var top: float = 122.0
	var aircraft_w: float = minf(400.0, size.x * 0.32)
	var right_x: float = PAD + aircraft_w + 36.0
	var right_w: float = maxf(size.x - right_x - PAD, 200.0)

	# --- aircraft cards -----------------------------------------------------
	var card_h: float = 76.0
	var gap: float = 12.0
	for i in _aircraft.size():
		var rect := Rect2(PAD, top + 40.0 + float(i) * (card_h + gap),
						  aircraft_w, card_h)
		_hit.append({"rect": rect, "kind": "aircraft", "index": i, "action": "aircraft"})

	# --- scene cards --------------------------------------------------------
	var scene_gap: float = 14.0
	var scene_w: float = (right_w - scene_gap * float(_scenes.size() - 1)) / float(_scenes.size())
	var scene_thumb_h: float = scene_w * 9.0 / 16.0
	for i in _scenes.size():
		var rect := Rect2(right_x + float(i) * (scene_w + scene_gap),
						  top + 40.0, scene_w, scene_thumb_h)
		_hit.append({"rect": rect, "kind": "scene", "index": i, "action": "scene"})
		var thumb: TextureRect = _make_thumb("scene", _scenes[i]["id"],
				Vector2(scene_w, scene_thumb_h))
		if thumb != null:
			thumb.position = rect.position
			_canvas.add_child(thumb)
			_thumbs.append(thumb)

	# --- weather cards ------------------------------------------------------
	var weather_y: float = top + 40.0 + scene_thumb_h + 30.0
	var weather_thumb_h: float = minf(scene_thumb_h * 0.62, 84.0)
	for i in _weathers.size():
		var rect := Rect2(right_x + float(i) * (scene_w + scene_gap),
						  weather_y, scene_w, weather_thumb_h)
		_hit.append({"rect": rect, "kind": "weather", "index": i, "action": "weather"})
		var thumb: TextureRect = _make_thumb("weather", _weathers[i]["id"],
				Vector2(scene_w, weather_thumb_h))
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


## Load a preview from the shots a render test writes, or null to draw a
## placeholder instead. The shots are not committed, so a fresh checkout gets
## the placeholder - the menu has to work before the renderer has ever run.
func _make_thumb(kind: String, id: String, size: Vector2) -> TextureRect:
	var key: String = "%s:%s" % [kind, id]
	if not _thumb_textures.has(key):
		var path: String = "res://shots/%s_%s.png" % [kind, id]
		var texture: Texture2D = null
		if ResourceLoader.exists(path):
			texture = load(path) as Texture2D
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

	if _appear < 1.0:
		_canvas.queue_redraw()


func _draw_header(size: Vector2, shift: Vector2) -> void:
	var origin := Vector2(PAD, 58.0) + shift

	UITheme.draw_text_shadow(_canvas, Vector2(PAD, origin.y + 52.0), "OPENRC",
							 UITheme.SIZE_DISPLAY, UITheme.TEXT,
							 Color(0, 0, 0, 0.6))
	UITheme.draw_label(_canvas, origin + Vector2(5, 92),
					  "RC FLIGHT TRAINING SIMULATOR", UITheme.ACCENT, 3.0,
					  UITheme.SIZE_SECTION)
	UITheme.draw_rule(_canvas, origin + Vector2(0, 112), 340.0,
					  UITheme.STROKE_STRONG, 2.0)

	_draw_transmitter(_transmitter_origin + shift)


## The one thing worth knowing before flying: is the radio ready? It carries the
## setup button, because a radio that is not ready is the only reason to leave
## this screen before flying.
func _draw_transmitter(origin: Vector2) -> void:
	var rect := Rect2(origin, Vector2(300, 64))
	var ready: bool = _input != null and _input.is_connected() and _input.is_fully_bound()
	var state_colour: Color = UITheme.GOOD if ready else UITheme.WARN

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
	UITheme.draw_label(_canvas, pos, "%s   %d" % [text, count],
					   UITheme.ACCENT if active else UITheme.TEXT_DIM, 2.6,
					   UITheme.SIZE_SECTION)
	var y: float = pos.y + 22.0
	UITheme.draw_rule(_canvas, Vector2(pos.x, y), 260.0,
					  UITheme.ACCENT if active else UITheme.STROKE)


func _draw_aircraft(size: Vector2, shift: Vector2) -> void:
	var top: float = 122.0
	_section_heading(Vector2(PAD, top) + shift, "AIRCRAFT", _aircraft.size(),
					 _focus == 0)

	var card_h: float = 76.0
	var gap: float = 12.0
	var aircraft_w: float = minf(400.0, size.x * 0.32)
	for i in _aircraft.size():
		var rect := Rect2(PAD, top + 40.0 + float(i) * (card_h + gap),
						  aircraft_w, card_h)
		var selected: bool = i == _aircraft_index
		var hovered: bool = _hover.get("kind", "") == "aircraft" \
				and int(_hover.get("index", -1)) == i
		_draw_card(rect, selected, hovered, _focus == 0)

		var card: Dictionary = _aircraft[i]
		var x: float = rect.position.x + 18.0
		var name_colour: Color = UITheme.TEXT if selected or hovered else UITheme.TEXT_DIM
		UITheme.draw_text(_canvas, Vector2(x, rect.position.y + 27.0),
						  card["name"], UITheme.SIZE_VALUE, name_colour)
		var specs: String = "%.1f m span   %.2f kg   app %.0f m/s" % [
			card["span"], card["mass"], card["approach"]]
		UITheme.draw_text(_canvas, Vector2(x, rect.position.y + 55.0),
						  specs, UITheme.SIZE_LABEL, UITheme.TEXT_DIM)


func _draw_scenes(size: Vector2, shift: Vector2) -> void:
	var aircraft_w: float = minf(400.0, size.x * 0.32)
	var right_x: float = PAD + aircraft_w + 36.0
	var right_w: float = maxf(size.x - right_x - PAD, 200.0)
	var top: float = 122.0

	_section_heading(Vector2(right_x, top) + shift, "LOCATION", _scenes.size(),
					 _focus == 1)

	var scene_gap: float = 14.0
	var scene_w: float = (right_w - scene_gap * float(_scenes.size() - 1)) / float(_scenes.size())
	var thumb_h: float = scene_w * 9.0 / 16.0

	for i in _scenes.size():
		var rect := Rect2(right_x + float(i) * (scene_w + scene_gap),
						  top + 40.0, scene_w, thumb_h)
		var selected: bool = i == _scene_index
		var hovered: bool = _hover.get("kind", "") == "scene" \
				and int(_hover.get("index", -1)) == i

		if _thumb_textures.get("scene:%s" % _scenes[i]["id"]) == null:
			_draw_placeholder(rect, _scenes[i]["name"], UITheme.ACCENT)
		_draw_card(rect, selected, hovered, _focus == 1)
		# The name hangs below the preview, so it never covers it.
		var name_y: float = rect.end.y + 21.0
		UITheme.draw_text(_canvas, Vector2(rect.position.x, name_y),
						  _scenes[i]["name"], UITheme.SIZE_TITLE,
						  UITheme.TEXT if selected else UITheme.TEXT_DIM)


func _draw_weather(size: Vector2, shift: Vector2) -> void:
	var aircraft_w: float = minf(400.0, size.x * 0.32)
	var right_x: float = PAD + aircraft_w + 36.0
	var right_w: float = maxf(size.x - right_x - PAD, 200.0)
	var scene_gap: float = 14.0
	var scene_w: float = (right_w - scene_gap * float(_scenes.size() - 1)) / float(_scenes.size())
	var scene_thumb_h: float = scene_w * 9.0 / 16.0
	var weather_y: float = 122.0 + 40.0 + scene_thumb_h + 30.0

	_section_heading(Vector2(right_x, weather_y - 40.0) + shift, "WEATHER",
					 _weathers.size(), _focus == 2)

	var thumb_h: float = minf(scene_thumb_h * 0.62, 84.0)
	for i in _weathers.size():
		var rect := Rect2(right_x + float(i) * (scene_w + scene_gap),
						  weather_y, scene_w, thumb_h)
		var selected: bool = i == _weather_index
		var hovered: bool = _hover.get("kind", "") == "weather" \
				and int(_hover.get("index", -1)) == i

		if _thumb_textures.get("weather:%s" % _weathers[i]["id"]) == null:
			_draw_placeholder(rect, _weathers[i]["name"], UITheme.ACCENT_DIM)
		_draw_card(rect, selected, hovered, _focus == 2)

		var x: float = rect.position.x
		var name_y: float = rect.end.y + 19.0
		UITheme.draw_text(_canvas, Vector2(x, name_y), _weathers[i]["name"],
						  UITheme.SIZE_VALUE,
						  UITheme.TEXT if selected else UITheme.TEXT_DIM)
		var wind: String = "%.1f m/s" % _weathers[i]["wind_mps"]
		UITheme.draw_text(_canvas, Vector2(x, name_y + 21.0), wind,
						  UITheme.SIZE_LABEL, UITheme.ACCENT if selected else UITheme.TEXT_FAINT)


## One card: a translucent panel, an accent edge when selected, a brightened
## edge on hover, and a left rule on the focus section's selection.
func _draw_card(rect: Rect2, selected: bool, hovered: bool, focused: bool) -> void:
	var fill: Color = UITheme.PANEL
	var stroke: Color = UITheme.STROKE
	if selected:
		fill = Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, 0.14)
		stroke = UITheme.ACCENT
	if hovered and not selected:
		stroke = UITheme.STROKE_STRONG
	if selected and hovered:
		UITheme.draw_glow(_canvas, rect, UITheme.ACCENT, 10.0, 2)
	UITheme.draw_panel(_canvas, rect, fill, stroke, 10.0)
	if selected and focused:
		_canvas.draw_rect(Rect2(rect.position, Vector2(3, rect.size.y)),
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

	UITheme.draw_glow(_canvas, fly_rect, UITheme.ACCENT, 12.0, 3)
	UITheme.draw_panel(_canvas, fly_rect,
			Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b,
				  0.92 if hovered else 0.78),
			Color(1, 1, 1, 0.5 if hovered else 0.25), 12.0)
	_canvas.draw_line(fly_rect.position + Vector2(14, 5),
					  fly_rect.position + Vector2(fly_w - 14, 5),
					  Color(1, 1, 1, 0.35), 1.0)
	UITheme.draw_text_shadow(_canvas,
			fly_rect.position + Vector2(fly_w * 0.5, 38.0), "FLY",
			UITheme.SIZE_LARGE, Color(0.02, 0.06, 0.09, 1.0),
			Color(0, 0, 0, 0.4))

	# The briefing line: what exactly you are about to fly.
	var summary: String = "%s   %s   %s   wind %.1f m/s" % [
		_aircraft[_aircraft_index]["name"] if not _aircraft.is_empty() else "",
		_scenes[_scene_index]["name"],
		_weathers[_weather_index]["name"],
		_weathers[_weather_index]["wind_mps"]]
	UITheme.draw_text(_canvas, Vector2(size.x * 0.5, size.y - 106.0), summary,
					  UITheme.SIZE_SECTION, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)

	UITheme.draw_text(_canvas, Vector2(size.x - PAD, size.y - 20.0),
					  "arrows choose   tab section   enter fly   esc %s" %
					  ("quit" if start_screen else "back"),
					  UITheme.SIZE_MICRO, UITheme.TEXT_FAINT, HORIZONTAL_ALIGNMENT_RIGHT)
