# OpenRC Simulator - the main menu, a briefing in four steps.
#
# One screen with every option visible was a catalogue, not an interface:
# professional flight sims walk the pilot through the sortie - aeroplane,
# place, weather, then the summary - because a decision made with the previous
# one still in view is a better decision. So this menu does exactly that:
#
#   STEP 1  AIRCRAFT   four machines, the numbers that tell them apart
#   STEP 2  LOCATION   five places, each with a rendered preview
#   STEP 3  WEATHER    five states, each with a preview and its wind
#   STEP 4  REVIEW     the whole sortie on one card, and the fly button
#
# A breadcrumb across the top shows where the pilot is and lets them jump back
# to any earlier step. Every choice gives feedback: cards glow and lift on
# hover, the selected card carries a check and a bright edge, buttons sink
# when pressed, and the fly action runs a progress bar over the world rebuild
# before fading to the sortie. The menu plays its own quiet music and the UI
# speaks in clicks - all synthesised, like everything else in this project.
extends CanvasLayer

const UITheme := preload("res://ui/UITheme.gd")
const ScenePresetsLib := preload("res://world/ScenePresets.gd")
const WeatherLib := preload("res://world/Weather.gd")
const SoundBank := preload("res://audio/SoundBank.gd")

signal fly_requested(aircraft_stem: String, scene_id: String, weather_id: String)
signal wizard_requested
signal tuning_requested

@export var input_path: NodePath
@export var simulation_path: NodePath
@export var director_path: NodePath
## True on a cold start, when closing the menu means leaving the simulator.
@export var start_screen: bool = true

# Steps.
const STEP_AIRCRAFT: int = 0
const STEP_LOCATION: int = 1
const STEP_WEATHER: int = 2
const STEP_REVIEW: int = 3
const STEP_COUNT: int = 4
const STEP_NAMES: Array[String] = ["Aircraft", "Location", "Weather", "Fly"]

var _input: RCInputNode
var _sim: RCSimulationNode
var _director: Node
var _canvas: Control
var _music: AudioStreamPlayer
var _sfx: AudioStreamPlayer

# ------------------------------------------------------------------ content --
var _aircraft: Array[Dictionary] = []
var _scenes: Array[Dictionary] = []
var _weathers: Array[Dictionary] = []

var _aircraft_index: int = 0
var _scene_index: int = 0
var _weather_index: int = 0
var _step: int = STEP_AIRCRAFT

# ------------------------------------------------------------------ layout --
var _appear: float = 0.0
var _hover: Dictionary = {}           # {kind, index} or {}
var _card_pulse: Dictionary = {}      # eased 0..1 per "kind:index"
var _press: float = 0.0
var _press_rect: String = ""          # which rect is held down
var _fade: float = -1.0
## Fly progress, 0..1, filling after the fly action before the fade.
var _progress: float = 0.0
var _progress_active: bool = false
var _hit: Array[Dictionary] = []
var _thumbs: Array[TextureRect] = []
var _thumb_textures: Dictionary = {}
var _transmitter_origin := Vector2.ZERO
var _setup_rect := Rect2()
var _quit_rect := Rect2()
var _back_rect := Rect2()
var _next_rect := Rect2()

const PAD: float = 44.0


func _ready() -> void:
	layer = 20
	_input = get_node_or_null(input_path) as RCInputNode
	_sim = get_node_or_null(simulation_path) as RCSimulationNode
	_director = get_node_or_null(director_path)

	add_child(UITheme.make_frosted(0.45, 1.7))

	_music = AudioStreamPlayer.new()
	_music.name = "MenuMusic"
	_music.stream = SoundBank.menu_music()
	_music.volume_db = -18.0
	add_child(_music)
	_music.play()

	_sfx = AudioStreamPlayer.new()
	_sfx.name = "MenuSfx"
	add_child(_sfx)

	_canvas = Control.new()
	_canvas.anchor_right = 1.0
	_canvas.anchor_bottom = 1.0
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_menu)
	_canvas.gui_input.connect(_on_gui_input)
	add_child(_canvas)

	_gather()

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
					  "loading": 0.0, "pw": 0.0, "cells": 0, "capacity": 0.0,
					  "kv": 0.0, "cruise": 0.0}]
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
			"cells": _sim.get_battery_cells(),
			"capacity": _sim.get_battery_capacity_mah(),
			"kv": _sim.get_motor_kv(),
			"cruise": _sim.get_cruise_speed_mps(),
		})
	_sim.aircraft_definition = restore
	_sim.reload_aircraft()


# ------------------------------------------------------------- interaction --

func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit: Dictionary = _hit_at((event as InputEventMouseMotion).position)
		if hit.get("kind", "") != _hover.get("kind", "") \
				or hit.get("index", -1) != _hover.get("index", -1) \
				or hit.get("action", "") != _hover.get("action", ""):
			_hover = hit
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
			_press = 1.0
			_press_rect = _hit_at(press.position).get("action", "")
			if _press_rect == "fly":
				_begin_fly()
			else:
				_activate(_hit_at(press.position))
		else:
			_press_rect = ""


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_UP:    _nudge(-1)
		KEY_DOWN:  _nudge(1)
		KEY_LEFT:  if _step == STEP_REVIEW: _set_step(_step - 1)
		KEY_RIGHT: if _step < STEP_REVIEW: _set_step(_step + 1)
		KEY_TAB:   _set_step(posmod(_step + 1, STEP_COUNT))
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if _step == STEP_REVIEW:
				_begin_fly()
			else:
				_set_step(_step + 1)
		KEY_BACKSPACE, KEY_ESCAPE:
			if _step > STEP_AIRCRAFT:
				_set_step(_step - 1)
			elif start_screen:
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
	match _step:
		STEP_AIRCRAFT:
			_aircraft_index = posmod(_aircraft_index + direction, maxi(_aircraft.size(), 1))
		STEP_LOCATION:
			_scene_index = posmod(_scene_index + direction, _scenes.size())
		STEP_WEATHER:
			_weather_index = posmod(_weather_index + direction, _weathers.size())
		_: return
	_play(SoundBank.ui_tick())
	_canvas.queue_redraw()


func _hit_at(point: Vector2) -> Dictionary:
	for entry in _hit:
		if (entry["rect"] as Rect2).has_point(point):
			return entry
	return {}


func _apply_hover_selection() -> void:
	if _hover.is_empty():
		return
	match _hover.get("action", ""):
		"step":
			# Hovering a breadcrumb highlights it; clicking moves there.
			return
		"aircraft":
			if _step == STEP_AIRCRAFT:
				_aircraft_index = int(_hover["index"])
				_play(SoundBank.ui_tick())
		"scene":
			if _step == STEP_LOCATION:
				_scene_index = int(_hover["index"])
				_play(SoundBank.ui_tick())
		"weather":
			if _step == STEP_WEATHER:
				_weather_index = int(_hover["index"])
				_play(SoundBank.ui_tick())


func _activate(entry: Dictionary) -> void:
	if entry.is_empty():
		return
	match entry.get("action", ""):
		"setup": wizard_requested.emit(); queue_free()
		"tuning": tuning_requested.emit(); queue_free()
		"quit": get_tree().quit()
		"back":
			_set_step(_step - 1) if _step > STEP_AIRCRAFT else _close_or_quit()
		"next":
			_set_step(_step + 1) if _step < STEP_REVIEW else _begin_fly()
		"step":
			_set_step(int(entry["index"]))
		"aircraft": _aircraft_index = int(entry["index"]); _play(SoundBank.ui_tick())
		"scene": _scene_index = int(entry["index"]); _play(SoundBank.ui_tick())
		"weather": _weather_index = int(entry["index"]); _play(SoundBank.ui_tick())


func _close_or_quit() -> void:
	if start_screen:
		get_tree().quit()
	else:
		queue_free()


func _set_step(step: int) -> void:
	var target: int = clampi(step, 0, STEP_COUNT - 1)
	if target == _step:
		return
	var forward: bool = target > _step
	_step = target
	_play(SoundBank.ui_confirm() if forward else SoundBank.ui_back())
	_layout()
	_canvas.queue_redraw()


func _begin_fly() -> void:
	if _progress_active:
		return
	_progress_active = true
	_progress = 0.0
	_play(SoundBank.ui_confirm())
	_canvas.queue_redraw()


func _play(stream: AudioStreamWAV) -> void:
	if _sfx == null:
		return
	_sfx.stream = stream
	_sfx.play()


# ------------------------------------------------------------------- layout --

func _process(delta: float) -> void:
	_appear = minf(_appear + delta * 4.0, 1.0)
	_press = maxf(_press - delta * 5.0, 0.0)
	if _progress_active:
		_progress += delta / 2.4
		if _progress >= 1.0:
			_progress = 1.0
			_fade = 0.0
			_progress_active = false
	if _fade >= 0.0:
		_fade = minf(_fade + delta * 3.0, 1.0)
		if _fade >= 1.0:
			_complete_fly()

	_ease_pulses(delta)

	var size: Vector2 = _canvas.size
	if _canvas.get_meta("layout_size", Vector2.ZERO) != size:
		_canvas.set_meta("layout_size", size)
		_layout()
	_canvas.queue_redraw()


func _ease_pulses(delta: float) -> void:
	var targets: Dictionary = {}
	for kind in ["aircraft", "scene", "weather"]:
		var count: int = _aircraft.size() if kind == "aircraft" \
				else (_scenes.size() if kind == "scene" else _weathers.size())
		for i in count:
			var key: String = "%s:%d" % [kind, i]
			var wanted: float = 1.0 if (_hover.get("kind", "") == kind
					and int(_hover.get("index", -1)) == i) else 0.0
			var selected: bool = (kind == "aircraft" and i == _aircraft_index) \
					or (kind == "scene" and i == _scene_index) \
					or (kind == "weather" and i == _weather_index)
			if selected:
				wanted = 1.0
			var current: float = _card_pulse.get(key, 0.0)
			_card_pulse[key] = move_toward(current, wanted, delta * 6.0)


func _complete_fly() -> void:
	if _aircraft.is_empty():
		return
	fly_requested.emit(_aircraft[_aircraft_index]["stem"],
					   _scenes[_scene_index]["id"],
					   _weathers[_weather_index]["id"])
	queue_free()


## The layout depends on which step is showing: each step owns its content
## rects, and the header/footer are shared. Rebuilt on step changes and on
## resize, so what is drawn and what is clickable can never disagree.
func _layout() -> void:
	var size: Vector2 = _canvas.size
	_hit.clear()
	for thumb in _thumbs:
		if is_instance_valid(thumb):
			thumb.queue_free()
	_thumbs.clear()

	var header_y: float = 44.0
	_transmitter_origin = Vector2(size.x - PAD - 300.0 - 8.0 - 108.0 - 8.0 - 72.0, header_y)
	_setup_rect = Rect2(_transmitter_origin.x + 308.0, header_y, 108.0, 64.0)
	_quit_rect = Rect2(_transmitter_origin.x + 428.0, header_y, 72.0, 64.0)
	_hit.append({"rect": _setup_rect, "action": "setup"})
	_hit.append({"rect": _quit_rect, "action": "quit"})

	# Breadcrumb: four steps across the top, clickable, with the current step
	# drawn brighter. Short pills, so the step headings below them never have
	# to squeeze against the row.
	var crumb_y: float = 152.0
	var crumb_total: float = minf(size.x - PAD * 2.0, 760.0)
	var crumb_x: float = (size.x - crumb_total) * 0.5
	var crumb_w: float = crumb_total / float(STEP_COUNT)
	for i in STEP_COUNT:
		_hit.append({"rect": Rect2(crumb_x + crumb_w * float(i), crumb_y - 8.0,
								   crumb_w, 40.0), "action": "step", "index": i})

	# Step content.
	match _step:
		STEP_AIRCRAFT: _layout_aircraft(size)
		STEP_LOCATION: _layout_scenes(size)
		STEP_WEATHER: _layout_weather(size)
		STEP_REVIEW: _layout_review(size)

	# Footer: back and next. On the review step, next becomes fly.
	var foot_y: float = size.y - 88.0
	_back_rect = Rect2(PAD, foot_y, 150.0, 52.0)
	_hit.append({"rect": _back_rect, "action": "back"})
	var next_label: String = "FLY" if _step == STEP_REVIEW else "NEXT"
	var next_w: float = 150.0 if next_label == "NEXT" else 260.0
	_next_rect = Rect2(size.x - PAD - next_w, foot_y, next_w, 52.0)
	_hit.append({"rect": _next_rect, "action": "next"})

	_canvas.queue_redraw()


func _content_rect(size: Vector2) -> Rect2:
	return Rect2(PAD, 248.0, size.x - PAD * 2.0, size.y - 248.0 - 132.0)


func _layout_aircraft(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	var card_h: float = minf(104.0, (rect.size.y - 3.0 * 14.0) / 4.0)
	for i in _aircraft.size():
		var r := Rect2(rect.position.x + 40.0,
					   rect.position.y + float(i) * (card_h + 14.0),
					   rect.size.x * 0.62, card_h)
		_hit.append({"rect": r, "kind": "aircraft", "index": i, "action": "aircraft"})


func _layout_scenes(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	var gap: float = 16.0
	var card_w: float = (rect.size.x - gap * 4.0) / 5.0
	var thumb_h: float = card_w * 9.0 / 16.0
	for i in _scenes.size():
		var r := Rect2(rect.position.x + float(i) * (card_w + gap),
					   rect.position.y + 6.0, card_w, thumb_h)
		_hit.append({"rect": r, "kind": "scene", "index": i, "action": "scene"})
		var thumb: TextureRect = _make_thumb("scene", _scenes[i]["id"],
				Vector2(card_w, thumb_h))
		if thumb != null:
			thumb.position = r.position
			_canvas.add_child(thumb)
			_thumbs.append(thumb)


func _layout_weather(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	var gap: float = 16.0
	var card_w: float = (rect.size.x - gap * 4.0) / 5.0
	var thumb_h: float = minf(card_w * 0.62, 150.0)
	for i in _weathers.size():
		var r := Rect2(rect.position.x + float(i) * (card_w + gap),
					   rect.position.y + 6.0, card_w, thumb_h)
		_hit.append({"rect": r, "kind": "weather", "index": i, "action": "weather"})
		var thumb: TextureRect = _make_thumb("weather", _weathers[i]["id"],
				Vector2(card_w - 6.0, thumb_h - 6.0))
		if thumb != null:
			# Inset so the card's selection frame shows around the image.
			thumb.position = r.position + Vector2(3.0, 3.0)
			_canvas.add_child(thumb)
			_thumbs.append(thumb)


func _layout_review(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	var gap: float = 20.0
	var card_w: float = (rect.size.x - gap * 2.0) / 3.0
	for i in 3:
		var r := Rect2(rect.position.x + float(i) * (card_w + gap),
					   rect.position.y, card_w, rect.size.y)
		_hit.append({"rect": r, "action": "review%d" % i})
		# Preview thumbnails live on the location and weather cards.
		if i == 1:
			var thumb1: TextureRect = _make_thumb("scene", _scenes[_scene_index]["id"],
					Vector2(card_w - 40.0, (card_w - 40.0) * 9.0 / 16.0))
			if thumb1 != null:
				thumb1.position = r.position + Vector2(20, 52)
				_canvas.add_child(thumb1)
				_thumbs.append(thumb1)
		elif i == 2:
			var thumb2: TextureRect = _make_thumb("weather", _weathers[_weather_index]["id"],
					Vector2(card_w - 40.0, minf((card_w - 40.0) * 0.62, 120.0)))
			if thumb2 != null:
				thumb2.position = r.position + Vector2(20, 52)
				_canvas.add_child(thumb2)
				_thumbs.append(thumb2)


## Load a preview for the menu, or null to draw a placeholder instead.
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
	return UITheme.make_thumb(texture, size, 12.0)


# ------------------------------------------------------------------- drawing --

func _draw_menu() -> void:
	var size: Vector2 = _canvas.size
	var ease_in: float = 1.0 - pow(1.0 - _appear, 3.0)
	var slide: float = (1.0 - ease_in) * 26.0
	var shift := Vector2(0.0, slide)

	# A soft scrim across the top of the menu. The frosted backdrop shows the
	# field by design, and the field's treeline reads as a dark band exactly
	# where the header and the breadcrumb sit - so the top of the menu sinks
	# into a quiet gradient instead of fighting the scene.
	var scrim_steps: int = 14
	var scrim_height: float = 214.0
	for step in scrim_steps:
		var t0: float = float(step) / float(scrim_steps)
		var t1: float = float(step + 1) / float(scrim_steps)
		var alpha: float = 0.55 * (1.0 - t0) * (1.0 - t0)
		_canvas.draw_rect(Rect2(0.0, scrim_height * t0, size.x,
								scrim_height * (t1 - t0) + 1.0),
						  Color(0.02, 0.03, 0.04, alpha), true)

	_draw_header(size, shift)
	_draw_breadcrumb(size, shift)
	match _step:
		STEP_AIRCRAFT: _draw_aircraft(size)
		STEP_LOCATION: _draw_scenes(size)
		STEP_WEATHER: _draw_weather(size)
		STEP_REVIEW: _draw_review(size)
	_draw_footer(size)

	if _fade > 0.0:
		_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, _fade * 0.85), true)
	if _appear < 1.0 or _fade >= 0.0 or _progress_active:
		_canvas.queue_redraw()


func _draw_header(size: Vector2, shift: Vector2) -> void:
	var origin := Vector2(PAD, 44.0) + shift

	UITheme.draw_text_shadow(_canvas, Vector2(PAD, origin.y + 50.0), "OPENRC",
							 UITheme.SIZE_DISPLAY, UITheme.TEXT,
							 Color(0, 0, 0, 0.6))
	UITheme.draw_label(_canvas, origin + Vector2(5, 84),
					  "RC FLIGHT TRAINING SIMULATOR", UITheme.ACCENT, 3.0,
					  UITheme.SIZE_SECTION)
	UITheme.draw_rule(_canvas, origin + Vector2(0, 102), 340.0,
					  UITheme.STROKE_STRONG, 2.0)

	var rect := Rect2(_transmitter_origin + shift, Vector2(300, 64))
	var ready: bool = _input != null and _input.is_connected() and _input.is_fully_bound()
	var connected: bool = _input != null and _input.is_connected()
	var state_colour: Color = UITheme.GOOD if ready \
			else (UITheme.WARN if connected else UITheme.TEXT_DIM)

	UITheme.draw_panel(_canvas, rect,
			Color(state_colour.r, state_colour.g, state_colour.b, 0.10),
			state_colour, 10.0)
	UITheme.draw_label(_canvas, rect.position + Vector2(14, 18), "transmitter",
					   state_colour, 2.4)
	var device: String = "none detected"
	if _input != null and _input.is_connected():
		device = _input.get_device_name().substr(0, 26)
	var state: String = "READY" if ready else ""
	UITheme.draw_text(_canvas, rect.position + Vector2(14, 44), device,
					  UITheme.SIZE_LABEL, UITheme.TEXT)
	if state != "":
		UITheme.draw_text(_canvas, rect.position + Vector2(300 - 74, 44), state,
						  UITheme.SIZE_LABEL, state_colour, HORIZONTAL_ALIGNMENT_RIGHT, 64.0)

	UITheme.draw_panel(_canvas, Rect2(_setup_rect.position + shift, _setup_rect.size),
			Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, 0.16),
			UITheme.ACCENT if _hover.get("action", "") == "setup" else UITheme.STROKE_STRONG,
			10.0)
	UITheme.draw_text(_canvas, _setup_rect.position + Vector2(54, 33) + shift, "SETUP",
					  UITheme.SIZE_SECTION, UITheme.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)

	UITheme.draw_panel(_canvas, Rect2(_quit_rect.position + shift, _quit_rect.size),
					   UITheme.PANEL, UITheme.STROKE_STRONG, 10.0)
	UITheme.draw_text(_canvas, _quit_rect.position + Vector2(36, 33) + shift, "QUIT",
					  UITheme.SIZE_SECTION, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)


## The four steps, with the current one lit and the completed ones checkmarked.
func _draw_breadcrumb(size: Vector2, shift: Vector2) -> void:
	var crumb_y: float = 152.0
	var crumb_total: float = minf(size.x - PAD * 2.0, 760.0)
	var crumb_x: float = (size.x - crumb_total) * 0.5
	var crumb_w: float = crumb_total / float(STEP_COUNT)

	for i in STEP_COUNT:
		var x: float = crumb_x + crumb_w * float(i)
		var current: bool = i == _step
		var done: bool = i < _step
		var hovered: bool = _hover.get("action", "") == "step" \
				and int(_hover.get("index", -1)) == i
		var centre: float = x + crumb_w * 0.5

		if current:
			UITheme.draw_glow(_canvas, Rect2(x + 6.0, crumb_y, crumb_w - 12.0, 32.0),
							  UITheme.ACCENT, 10.0, 2)
			UITheme.draw_panel(_canvas, Rect2(x + 6.0, crumb_y, crumb_w - 12.0, 32.0),
					Color(0.05, 0.09, 0.12, 0.92),
					UITheme.ACCENT, 10.0)
		elif done:
			UITheme.draw_panel(_canvas, Rect2(x + 6.0, crumb_y, crumb_w - 12.0, 32.0),
					Color(0.05, 0.09, 0.12, 0.92),
					UITheme.GOOD, 10.0)
		elif hovered:
			UITheme.draw_panel(_canvas, Rect2(x + 6.0, crumb_y, crumb_w - 12.0, 32.0),
					Color(0.05, 0.09, 0.12, 0.92), UITheme.STROKE_STRONG, 10.0)
		else:
			UITheme.draw_panel(_canvas, Rect2(x + 6.0, crumb_y, crumb_w - 12.0, 32.0),
					Color(0.05, 0.09, 0.12, 0.85), UITheme.STROKE, 10.0)

		var label: String = "%d  %s" % [i + 1, STEP_NAMES[i]]
		var colour: Color = UITheme.ACCENT if current \
				else (UITheme.GOOD if done else UITheme.TEXT_DIM)
		if done:
			UITheme.draw_text(_canvas, Vector2(x + 14.0, crumb_y + 21.0), "✓",
							  UITheme.SIZE_VALUE, UITheme.GOOD)
			label = "  %s" % STEP_NAMES[i]
			colour = UITheme.TEXT_DIM
		UITheme.draw_text(_canvas, Vector2(centre, crumb_y + 21.0), label,
						  UITheme.SIZE_SECTION, colour, HORIZONTAL_ALIGNMENT_CENTER,
						  crumb_w - 12.0)


func _section_heading(pos: Vector2, text: String, sub: String) -> void:
	UITheme.draw_text_shadow(_canvas, pos, text, UITheme.SIZE_TITLE, UITheme.TEXT,
							 Color(0, 0, 0, 0.5))
	if sub != "":
		UITheme.draw_text(_canvas, pos + Vector2(0, 28), sub,
						  UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
	UITheme.draw_rule(_canvas, pos + Vector2(0, 44), 320.0, UITheme.ACCENT, 2.0)


func _draw_aircraft(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	_section_heading(rect.position - Vector2(0, 36), "Choose your aeroplane",
					 "Four machines, each with its own character - pick one and see the brief.")
	var card_h: float = minf(104.0, (rect.size.y - 3.0 * 14.0) / 4.0)

	for i in _aircraft.size():
		var r := Rect2(rect.position.x + 40.0,
					   rect.position.y + float(i) * (card_h + 14.0),
					   rect.size.x * 0.62, card_h)
		var selected: bool = i == _aircraft_index
		var pulse: float = _card_pulse.get("aircraft:%d" % i, 0.0)
		_draw_card(r, selected, _focus_card(i, "aircraft"), pulse, 2.0)

		var card: Dictionary = _aircraft[i]
		var x: float = r.position.x + 22.0
		UITheme.draw_text(_canvas, Vector2(x, r.position.y + 32.0), card["name"],
						  UITheme.SIZE_TITLE, UITheme.TEXT if selected else UITheme.TEXT_DIM)
		var specs: String = "%.1f m span   %.2f kg   app %.0f m/s   %.0f N/m2   %.0f W/kg" % [
			card["span"], card["mass"], card["approach"], card["loading"], card["pw"]]
		UITheme.draw_text(_canvas, Vector2(x, r.position.y + 60.0), specs,
						  UITheme.SIZE_LABEL,
						  UITheme.TEXT if selected else UITheme.TEXT_DIM)

		if selected:
			UITheme.draw_text(_canvas, Vector2(r.end.x - 34.0,
							  r.position.y + r.size.y * 0.5), "✓",
							  UITheme.SIZE_LARGE, UITheme.ACCENT)

	# The right half is the brief of the aeroplane that is selected: what it
	# is, and why it flies the way it does. Fills the dead space with the one
	# thing the pilot actually needs to read before choosing.
	if not _aircraft.is_empty():
		var card: Dictionary = _aircraft[_aircraft_index]
		var brief := Rect2(rect.position.x + rect.size.x * 0.62 + 60.0,
						   rect.position.y + 6.0,
						   rect.size.x * 0.38 - 60.0, rect.size.y - 12.0)
		UITheme.draw_panel(_canvas, brief, UITheme.PANEL, UITheme.ACCENT, 12.0)
		UITheme.draw_label(_canvas, brief.position + Vector2(24, 30), "the brief",
						   UITheme.ACCENT, 2.6, UITheme.SIZE_SECTION)
		var by: float = brief.position.y + 60.0
		for line in _wrap(card["description"], 40):
			UITheme.draw_text(_canvas, Vector2(brief.position.x + 24, by), line,
							  UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
			by += 19.0
		by += 10.0
		for row in [["wing loading", "%.0f N/m2" % card["loading"]],
					["power / weight", "%.0f W/kg" % card["pw"]],
					["approach speed", "%.0f m/s" % card["approach"]]]:
			UITheme.draw_text(_canvas, Vector2(brief.position.x + 24, by), row[0],
							  UITheme.SIZE_LABEL, UITheme.TEXT_FAINT)
			UITheme.draw_text(_canvas, Vector2(brief.position.x + 190, by), row[1],
							  UITheme.SIZE_BODY, UITheme.TEXT)
			by += 26.0


func _draw_scenes(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	_section_heading(rect.position - Vector2(0, 36), "Where do you want to fly?",
					 "Each place is its own climate and geology. The previews are real frames.")
	var gap: float = 16.0
	var card_w: float = (rect.size.x - gap * 4.0) / 5.0
	var thumb_h: float = card_w * 9.0 / 16.0

	for i in _scenes.size():
		var r := Rect2(rect.position.x + float(i) * (card_w + gap),
					   rect.position.y + 6.0, card_w, thumb_h)
		var selected: bool = i == _scene_index
		var pulse: float = _card_pulse.get("scene:%d" % i, 0.0)
		_draw_card(r, selected, _focus_card(i, "scene"), pulse, 1.0)

		var name_y: float = r.end.y + 26.0
		var name_size: int = _fit_size(_scenes[i]["name"], card_w)
		UITheme.draw_text(_canvas, Vector2(r.position.x, name_y), _scenes[i]["name"],
						  name_size, UITheme.TEXT if selected else UITheme.TEXT_DIM)
		if selected:
			UITheme.draw_text(_canvas, r.position + r.size - Vector2(24, 22), "✓",
							  UITheme.SIZE_VALUE, UITheme.ACCENT)


func _draw_weather(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	_section_heading(rect.position - Vector2(0, 36), "What kind of day?",
					 "Weather is not a filter - it changes the air and the ground.")
	var gap: float = 16.0
	var card_w: float = (rect.size.x - gap * 4.0) / 5.0
	var thumb_h: float = minf(card_w * 0.62, 150.0)

	for i in _weathers.size():
		var r := Rect2(rect.position.x + float(i) * (card_w + gap),
					   rect.position.y + 6.0, card_w, thumb_h)
		var selected: bool = i == _weather_index
		var pulse: float = _card_pulse.get("weather:%d" % i, 0.0)
		_draw_card(r, selected, _focus_card(i, "weather"), pulse, 1.0)

		var name_y: float = r.end.y + 26.0
		UITheme.draw_text(_canvas, Vector2(r.position.x, name_y), _weathers[i]["name"],
						  UITheme.SIZE_VALUE,
						  UITheme.TEXT if selected else UITheme.TEXT_DIM)
		var wind: String = "%.1f m/s wind" % _weathers[i]["wind_mps"]
		UITheme.draw_text(_canvas, Vector2(r.position.x, name_y + 24.0), wind,
						  UITheme.SIZE_LABEL, UITheme.ACCENT if selected else UITheme.TEXT_DIM)
		if selected:
			UITheme.draw_text(_canvas, r.position + r.size - Vector2(24, 22), "✓",
							  UITheme.SIZE_VALUE, UITheme.ACCENT)


func _draw_review(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	_section_heading(rect.position - Vector2(0, 36), "The sortie",
					 "Everything below is what you are about to fly.")
	var gap: float = 20.0
	var card_w: float = (rect.size.x - gap * 2.0) / 3.0

	var aircraft: Dictionary = _aircraft[_aircraft_index] if not _aircraft.is_empty() else {}
	var scene: Dictionary = _scenes[_scene_index]
	var weather: Dictionary = _weathers[_weather_index]

	# Aircraft card.
	var r0 := Rect2(rect.position, Vector2(card_w, rect.size.y))
	UITheme.draw_panel(_canvas, r0, UITheme.PANEL, UITheme.ACCENT, 12.0)
	UITheme.draw_label(_canvas, r0.position + Vector2(20, 28), "aircraft", UITheme.ACCENT, 2.6)
	UITheme.draw_text(_canvas, r0.position + Vector2(20, 62), aircraft["name"],
					  UITheme.SIZE_LARGE, UITheme.TEXT)
	UITheme.draw_text(_canvas, r0.position + Vector2(20, 100),
					  "%.1f m span   %.2f kg" % [aircraft["span"], aircraft["mass"]],
					  UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
	var ay: float = 132.0
	for line in _wrap(aircraft["description"], 40):
		if ay > r0.end.y - 30.0:
			break
		UITheme.draw_text(_canvas, r0.position + Vector2(20, ay), line,
						  UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
		ay += 18.0
	ay += 6.0
	for row in [["wing loading", "%.0f N/m2" % aircraft["loading"]],
				["power / weight", "%.0f W/kg" % aircraft["pw"]],
				["battery", "%dS %.0f mAh" % [aircraft["cells"], aircraft["capacity"]]],
				["motor", "%.0f KV" % aircraft["kv"]],
				["cruise / approach", "%.0f / %.0f m/s" % [aircraft["cruise"], aircraft["approach"]]]]:
		if ay > r0.end.y - 26.0:
			break
		UITheme.draw_text(_canvas, r0.position + Vector2(20, ay), row[0],
						  UITheme.SIZE_LABEL, UITheme.TEXT_FAINT)
		var value: String = row[1]
		# ay is an offset from the card top; the values must sit on the same
		# row as their labels, which the labels get from r0.position.y + ay.
		UITheme.draw_text(_canvas, Vector2(r0.end.x - 24.0 - UITheme.text_width(value, UITheme.SIZE_BODY),
										  r0.position.y + ay),
						  value, UITheme.SIZE_BODY, UITheme.TEXT)
		ay += 26.0

	# Location card with its preview (the thumbnail is a child laid out in
	# _layout_review; only the caption is drawn here).
	var r1 := Rect2(rect.position + Vector2(card_w + gap, 0), Vector2(card_w, rect.size.y))
	UITheme.draw_panel(_canvas, r1, UITheme.PANEL, UITheme.ACCENT, 12.0)
	UITheme.draw_label(_canvas, r1.position + Vector2(20, 28), "location", UITheme.ACCENT, 2.6)
	UITheme.draw_text(_canvas, r1.position + Vector2(20, 52 + (card_w - 40.0) * 9.0 / 16.0 + 22.0),
					  scene["name"], UITheme.SIZE_VALUE, UITheme.TEXT)

	# Weather card with its preview.
	var r2 := Rect2(rect.position + Vector2((card_w + gap) * 2.0, 0), Vector2(card_w, rect.size.y))
	UITheme.draw_panel(_canvas, r2, UITheme.PANEL, UITheme.ACCENT, 12.0)
	UITheme.draw_label(_canvas, r2.position + Vector2(20, 28), "weather", UITheme.ACCENT, 2.6)
	UITheme.draw_text(_canvas, r2.position + Vector2(20, 52 + minf((card_w - 40.0) * 0.62, 120.0) + 22.0),
					  weather["name"], UITheme.SIZE_VALUE, UITheme.TEXT)
	UITheme.draw_text(_canvas, r2.position + Vector2(20, 52 + minf((card_w - 40.0) * 0.62, 120.0) + 46.0),
					  "%.1f m/s wind   grip %.0f%%" % [weather["wind_mps"],
					  float(weather["ground_grip"]) * 100.0],
					  UITheme.SIZE_LABEL, UITheme.TEXT_DIM)


func _focus_card(index: int, kind: String) -> bool:
	match _step:
		STEP_AIRCRAFT: return kind == "aircraft"
		STEP_LOCATION: return kind == "scene"
		STEP_WEATHER: return kind == "weather"
	return false


## One card: a translucent panel, an accent edge when selected, a brightened
## edge on hover, and a left rule on the focus step's selection. The pulse is
## eased in _process, so the glow and the lift grow smoothly - a card that
## jumps is a button; one that breathes is a UI.
func _draw_card(rect: Rect2, selected: bool, focused: bool, pulse: float,
				lift: float) -> void:
	var lifted := Rect2(rect.position - Vector2(0, pulse * lift), rect.size)
	var fill: Color = UITheme.PANEL
	var stroke: Color = UITheme.STROKE
	if selected:
		fill = Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b,
					 0.12 + 0.14 * pulse)
		stroke = UITheme.ACCENT
	if pulse > 0.01:
		UITheme.draw_glow(_canvas, lifted, UITheme.ACCENT, 10.0, int(1.0 + pulse * 2.0))
	UITheme.draw_panel(_canvas, lifted, fill, stroke, 10.0)
	if selected:
		_canvas.draw_rect(Rect2(lifted.position, Vector2(4, lifted.size.y)),
						  UITheme.ACCENT, true)


func _draw_footer(size: Vector2) -> void:
	# Back button.
	UITheme.draw_panel(_canvas, _back_rect,
			Color(1, 1, 1, 0.06) if _hover.get("action", "") == "back" else UITheme.PANEL,
			UITheme.STROKE_STRONG, 10.0)
	UITheme.draw_text(_canvas, _back_rect.position + Vector2(75, 34), "BACK",
					  UITheme.SIZE_SECTION, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)

	# Next / Fly button.
	var is_fly: bool = _step == STEP_REVIEW
	var hovered: bool = _hover.get("action", "") == "next"
	var sink: float = _press * 2.0
	var r := Rect2(_next_rect.position + Vector2(0, sink), _next_rect.size)

	if is_fly:
		UITheme.draw_glow(_canvas, r, UITheme.ACCENT, 12.0, 3 if _press < 0.1 else 1)
		UITheme.draw_panel(_canvas, r,
				Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b,
					  0.92 if hovered else 0.78),
				Color(1, 1, 1, 0.5 if hovered else 0.25), 12.0)
		UITheme.draw_text_shadow(_canvas, r.position + Vector2(130, 34), "FLY",
								 UITheme.SIZE_LARGE, Color(0.02, 0.06, 0.09, 1.0),
								 Color(0, 0, 0, 0.4))
		if _progress_active:
			var bar := Rect2(r.position + Vector2(30, r.size.y - 10.0),
							 Vector2(r.size.x - 60.0, 4.0))
			UITheme.draw_track(_canvas, bar, _progress, UITheme.ACCENT,
							   Color(1, 1, 1, 0.25))
	else:
		UITheme.draw_panel(_canvas, r,
				Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b,
					  0.22 if hovered else 0.14),
				UITheme.ACCENT if hovered else UITheme.STROKE_STRONG, 12.0)
		UITheme.draw_text(_canvas, r.position + Vector2(75, 34), "NEXT",
						  UITheme.SIZE_SECTION, UITheme.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)

	# The corner hint, readable now.
	UITheme.draw_text(_canvas, Vector2(size.x * 0.5, size.y - 36.0),
					  "arrows choose   enter next   backspace back   esc %s" %
					  ("quit" if start_screen else "close"),
					  UITheme.SIZE_LABEL, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)


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


func _clip(text: String, width: float, size: int) -> String:
	if UITheme.text_width(text, size) <= width:
		return text
	var out: String = text.strip_edges()
	while not out.is_empty() and UITheme.text_width(out + "…", size) > width:
		out = out.substr(0, out.length() - 1).strip_edges()
	return out + "…"


func _fit_size(text: String, width: float) -> int:
	for size in [UITheme.SIZE_TITLE, UITheme.SIZE_VALUE, UITheme.SIZE_LABEL]:
		if UITheme.text_width(text, size) <= width:
			return size
	return UITheme.SIZE_LABEL
