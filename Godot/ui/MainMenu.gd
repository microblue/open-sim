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
const StageScript := preload("res://ui/AircraftStage.gd")
const Ranking := preload("res://ui/AircraftRanking.gd")

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

## The brief's flown figures: label, the key the regression suite stores it
## under, and the format. An aeroplane that has not been measured for one of
## these simply does not show that row.
const BRIEF_MEASURED: Array = [
	["glide ratio", "glide_ratio", "%.1f : 1"],
	["stall speed", "stall_speed_mps", "%.1f m/s"],
	["roll rate", "roll_rate_deg_per_s", "%.0f deg/s"],
	["cruise", "cruise_speed_mps", "%.1f m/s"],
	["static thrust", "static_thrust_n", "%.1f N"],
	["takeoff roll", "takeoff_ground_roll_m", "%.1f m"],
]

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
## The turntable on the aircraft step, and the rectangle it is drawn in.
var _stage: Node
var _stage_view: TextureRect
## Drawn above the picture cards, which are Controls and therefore paint over
## anything the canvas draws underneath them. The selection frame has to be
## here or it is invisible.
var _overlay: Control
## The picture behind everything: the place currently chosen.
var _backdrop: TextureRect
var _backdrop_id: String = ""

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

	# The backdrop.
	#
	# This used to be a frosted pane over the live 3D world, which meant the
	# world had to exist before the menu could open - a second and a half of
	# black window on every cold start, spent building a place the player had
	# not chosen. The menu now stands on a picture of the place instead, which
	# also means the backdrop changes as they walk down the list.
	_backdrop = TextureRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)
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

	# The aeroplane itself, turning. A chooser that answers "which aeroplane?"
	# in wing loadings alone is a spreadsheet with a Fly button.
	_stage = StageScript.new()
	_stage.name = "Stage"
	add_child(_stage)

	_canvas = Control.new()
	_canvas.anchor_right = 1.0
	_canvas.anchor_bottom = 1.0
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_menu)
	_canvas.gui_input.connect(_on_gui_input)
	add_child(_canvas)

	# Above every thumbnail: the picture cards are Controls, so they paint over
	# anything the canvas draws underneath them, and a selection frame drawn
	# there would be invisible.
	_overlay = Control.new()
	_overlay.name = "Overlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	_canvas.add_child(_overlay)

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
			# The measured figures, as the regression suite recorded them.
			# These are flown, not quoted - and they are what actually tells a
			# pilot how an aeroplane will feel.
			"performance": _sim.get_performance(),
			# Thrown, not rolled. A player handed a glider and told to take off
			# will sit at the end of the strip with the throttle open.
			"hand_launched": _sim.is_hand_launched(),
			# A tail-dragger has no steerable wheel at the front, and will try
			# to swap ends on every take-off roll.
			"nose_wheel": _sim.has_steerable_nose_wheel(),
		})
	_sim.aircraft_definition = restore
	_sim.reload_aircraft()

	# EASIEST FIRST, and start there.
	#
	# The roster arrived in whatever order the directory listing gave, which is
	# alphabetical - so a beginner opening a TRAINING simulator was offered a
	# short-coupled tail-dragging biplane at the top of the list and had to
	# scroll past it to find the trainer. The first thing in a list is a
	# recommendation whether or not it was meant as one.
	Ranking.rank(_aircraft)
	_aircraft_index = 0
	if OS.has_environment("RC_MENU_DEBUG"):
		for card in _aircraft:
			print("   %-14s handling %.3f  order %.3f  loading %5.1f  roll %6.1f"
				  % [card["name"], card["difficulty"], card["learn_order"],
					 card["loading"],
					 float(card.get("performance", {}).get("roll_rate_deg_per_s", -1.0))])


# ------------------------------------------------------------- interaction --

func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit: Dictionary = _hit_at((event as InputEventMouseMotion).position)
		if hit.get("kind", "") != _hover.get("kind", "") \
				or hit.get("index", -1) != _hover.get("index", -1) \
				or hit.get("action", "") != _hover.get("action", ""):
			_hover = hit
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


# Hover selection used to live here: moving the mouse across the roster chose
# whatever it passed over, so the aeroplane you ended up with was the last one
# the pointer happened to cross on its way to the button. Hovering highlights;
# clicking chooses. They are drawn differently for the same reason.


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


## Hands the sortie over. The menu used to run a two-and-a-half second progress
## bar of its own, counting nothing - the world was built later, in one frame,
## with the window frozen. The bar is now on the loading screen, where it is
## measuring work that is actually happening.
func _begin_fly() -> void:
	if _progress_active:
		return
	_progress_active = true
	_play(SoundBank.ui_confirm())
	_canvas.queue_redraw()
	_complete_fly()


func _play(stream: AudioStreamWAV) -> void:
	if _sfx == null:
		return
	_sfx.stream = stream
	_sfx.play()


# ------------------------------------------------------------------- layout --

func _process(delta: float) -> void:
	_appear = minf(_appear + delta * 4.0, 1.0)
	_press = maxf(_press - delta * 5.0, 0.0)
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
	# The menu does NOT free itself here. The handler on the other end of this
	# signal is what puts the loading screen up, and it wants the menu gone at
	# a moment of its choosing - freeing from inside the emit is freeing a
	# locked object, which Godot refuses and reports.
	fly_requested.emit(_aircraft[_aircraft_index]["stem"],
					   _scenes[_scene_index]["id"],
					   _weathers[_weather_index]["id"])


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
	# The turntable belongs to the aircraft step alone; it is hidden rather
	# than freed so the aeroplane on it survives a walk to the weather page
	# and back.
	if _stage_view != null:
		_stage_view.visible = _step == STEP_AIRCRAFT
	_refresh_backdrop()

	var header_y: float = 44.0
	_transmitter_origin = Vector2(size.x - PAD - 360.0 - 12.0 - 150.0 - 12.0 - 118.0,
								  header_y)
	_setup_rect = Rect2(_transmitter_origin.x + 372.0, header_y, 150.0, 72.0)
	_quit_rect = Rect2(_transmitter_origin.x + 534.0, header_y, 118.0, 72.0)
	_hit.append({"rect": _setup_rect, "action": "setup"})
	_hit.append({"rect": _quit_rect, "action": "quit"})

	# Breadcrumb: four steps across the top, clickable, with the current step
	# drawn brighter.
	for i in STEP_COUNT:
		_hit.append({"rect": _crumb_rect(size, i), "action": "step", "index": i})

	# Step content.
	match _step:
		STEP_AIRCRAFT: _layout_aircraft(size)
		STEP_LOCATION: _layout_scenes(size)
		STEP_WEATHER: _layout_weather(size)
		STEP_REVIEW: _layout_review(size)

	# Footer: back and next. On the review step, next becomes fly.
	var foot_y: float = size.y - 104.0
	# No BACK on the first step: there is nowhere behind it. Drawing a button
	# that does nothing teaches the player that buttons here might not.
	if _step > STEP_AIRCRAFT:
		_back_rect = Rect2(PAD, foot_y, 210.0, 68.0)
		_hit.append({"rect": _back_rect, "action": "back"})
	else:
		_back_rect = Rect2()
	var next_label: String = "FLY" if _step == STEP_REVIEW else "NEXT"
	var next_w: float = 210.0 if next_label == "NEXT" else 340.0
	_next_rect = Rect2(size.x - PAD - next_w, foot_y, next_w, 68.0)
	_hit.append({"rect": _next_rect, "action": "next"})

	# Last child, so it paints over every thumbnail added this pass. Done here
	# rather than at the top of the layout, where the thumbnails have not been
	# created yet and the overlay ends up underneath them - which showed as a
	# selection frame that worked (it sits in the card's margin) and a tick
	# badge that did not (it sits on the picture).
	if _overlay != null:
		_canvas.move_child(_overlay, -1)
		_overlay.queue_redraw()

	_canvas.queue_redraw()


func _content_rect(size: Vector2) -> Rect2:
	# Below the heading's rule, not on top of it.
	#
	# The heading sits 36 px above this rectangle and draws a rule 44 px below
	# itself, which put the rule 8 px INSIDE the content - so the first
	# aircraft card covered it. The step tabs and the footer buttons both grew
	# and this number did not follow them.
	# The heading block sits entirely ABOVE this rectangle - title, subtitle
	# and rule - which is what _section_heading's -100 anchor is for. It used
	# to be -36 with the rule 44 below the title, which put the rule 8 px
	# INSIDE the content and the first aircraft card straight over the top of
	# it. Those offsets were set when the type was two thirds this size.
	# The vertical rhythm of the whole screen, in one place:
	#
	#   44..150   wordmark and radio        150  the rule that divides them
	#   176..234  the step tabs, alone
	#   280       the step heading          316  its subtitle    346  its rule
	#   370       the content starts here
	#
	# Every one of those numbers used to be a guess made against a smaller
	# type, and three separate things ended up drawn on top of each other.
	return Rect2(PAD, 370.0, size.x - PAD * 2.0, size.y - 370.0 - 160.0)


## The aircraft step is three columns: the roster to choose from, the aeroplane
## itself, and its brief. Computed in one place because the layout pass and the
## draw pass both need it and a card you can click that is not where it is
## drawn is the worst kind of bug to find.
const AIRCRAFT_LIST_W: float = 440.0
const AIRCRAFT_BRIEF_W: float = 480.0
const AIRCRAFT_GAP: float = 30.0

## The header, in two bands. The wordmark and the radio share the first; the
## step tabs have the second to themselves. They used to share one 200 px band
## between the three of them, and the wordmark's rule ran underneath the first
## tab.
const HEADER_RULE_Y: float = 150.0
const CRUMB_Y: float = 176.0
const CRUMB_H: float = 58.0

## How tall a preview is on the sortie summary. Capped: at a full 16:9 of a
## 597 px card it was 313 px, which pushed the weather figures out through the
## bottom of the panel.
const REVIEW_THUMB_H: float = 236.0


static func _review_thumb_size(card_w: float) -> Vector2:
	return Vector2(card_w - 40.0, minf((card_w - 40.0) * 9.0 / 16.0, REVIEW_THUMB_H))


func _aircraft_card_rect(rect: Rect2, index: int) -> Rect2:
	# Divided by however many aeroplanes there ARE. It was divided by four,
	# which was right for as long as there were four: adding a fifth ran the
	# list off the bottom of the screen.
	var count: int = maxi(_aircraft.size(), 1)
	var gap: float = 16.0
	var card_h: float = minf(118.0,
			(rect.size.y - gap * float(count - 1)) / float(count))
	return Rect2(rect.position.x,
				 rect.position.y + float(index) * (card_h + gap),
				 AIRCRAFT_LIST_W, card_h)


func _aircraft_stage_rect(rect: Rect2) -> Rect2:
	var x: float = rect.position.x + AIRCRAFT_LIST_W + AIRCRAFT_GAP
	var w: float = rect.size.x - AIRCRAFT_LIST_W - AIRCRAFT_BRIEF_W - AIRCRAFT_GAP * 2.0
	return Rect2(x, rect.position.y, maxf(w, 200.0), rect.size.y - 70.0)


func _layout_aircraft(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	for i in _aircraft.size():
		_hit.append({"rect": _aircraft_card_rect(rect, i), "kind": "aircraft",
					 "index": i, "action": "aircraft"})


## One picture card. Layout, drawing and the selection overlay share it.
func _picture_rect(rect: Rect2, index: int, count: int, ratio: float) -> Rect2:
	var gap: float = 18.0
	var card_w: float = (rect.size.x - gap * float(count - 1)) / float(count)
	return Rect2(rect.position.x + float(index) * (card_w + gap),
				 rect.position.y + 6.0, card_w, card_w * ratio)


func _layout_scenes(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	for i in _scenes.size():
		var r: Rect2 = _picture_rect(rect, i, _scenes.size(), 9.0 / 16.0)
		var card_w: float = r.size.x
		var thumb_h: float = r.size.y
		_hit.append({"rect": r, "kind": "scene", "index": i, "action": "scene"})
		var thumb: TextureRect = _make_thumb("scene", _scenes[i]["id"],
				Vector2(card_w - 8.0, thumb_h - 8.0))
		if thumb != null:
			thumb.position = r.position + Vector2(4.0, 4.0)
			# Unchosen places are held back, so the chosen one is the only
			# thing on the row at full strength. The card's own tint could
			# never do this: the picture is a Control drawn ON TOP of it.
			thumb.modulate = _picture_tint(i == _scene_index,
										   _focus_card(i, "scene"))
			_canvas.add_child(thumb)
			_thumbs.append(thumb)


func _layout_weather(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	for i in _weathers.size():
		var r: Rect2 = _picture_rect(rect, i, _weathers.size(), 9.0 / 16.0)
		_hit.append({"rect": r, "kind": "weather", "index": i, "action": "weather"})
		var thumb: TextureRect = _make_thumb("weather", _weathers[i]["id"],
				Vector2(r.size.x - 8.0, r.size.y - 8.0))
		if thumb != null:
			thumb.position = r.position + Vector2(4.0, 4.0)
			thumb.modulate = _picture_tint(i == _weather_index,
										   _focus_card(i, "weather"))
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
					_review_thumb_size(card_w))
			if thumb1 != null:
				thumb1.position = r.position + Vector2(20, 52)
				_canvas.add_child(thumb1)
				_thumbs.append(thumb1)
		elif i == 2:
			var thumb2: TextureRect = _make_thumb("weather", _weathers[_weather_index]["id"],
					_review_thumb_size(card_w))
			if thumb2 != null:
				thumb2.position = r.position + Vector2(20, 52)
				_canvas.add_child(thumb2)
				_thumbs.append(thumb2)


## The chosen entry, written out under the row of cards.
##
## Both picture steps put five thumbnails across the top and left the bottom
## half of a 1080-line screen empty, which reads as a page that failed to
## finish loading. What goes here is the thing the thumbnail cannot say.
func _draw_detail(content: Rect2, title: String, description: String,
				  rows: Array) -> void:
	var top: float = content.position.y + content.size.x * (9.0 / 16.0) / 5.0 + 130.0
	var panel := Rect2(content.position.x, top, content.size.x,
					   maxf(content.end.y - top, 120.0))
	UITheme.draw_panel(_canvas, panel, UITheme.PANEL, UITheme.STROKE, 12.0)

	var x: float = panel.position.x + 36.0
	var y: float = panel.position.y + 56.0
	UITheme.draw_display(_canvas, Vector2(x, y), title, UITheme.SIZE_LARGE,
						 UITheme.TEXT)
	y += 46.0
	for line in UITheme.wrap_text(description, panel.size.x * 0.52,
								  UITheme.SIZE_BODY):
		UITheme.draw_text(_canvas, Vector2(x, y), line, UITheme.SIZE_BODY,
						  UITheme.TEXT_DIM)
		y += 30.0

	# The numbers sit in their own column on the right, so a long description
	# cannot push them off the panel.
	# The row pitch follows the space there is, so the last row cannot fall out
	# of the bottom of the panel - which is what "thermals 100 % of a clear
	# day" was doing, half of it below the edge.
	var col: float = panel.position.x + panel.size.x * 0.60
	var ry: float = panel.position.y + 56.0
	var pitch: float = 40.0
	if not rows.is_empty():
		pitch = minf(40.0, (panel.size.y - 86.0) / float(rows.size()))
	for row in rows:
		UITheme.draw_text(_canvas, Vector2(col, ry), String(row[0]),
						  UITheme.SIZE_BODY, UITheme.TEXT_FAINT)
		UITheme.draw_text(_canvas, Vector2(col + 200.0, ry), String(row[1]),
						  UITheme.SIZE_VALUE, UITheme.TEXT)
		ry += pitch


## The chosen and hovered frames for the picture steps, drawn over the images.
func _draw_overlay() -> void:
	var rect: Rect2 = _content_rect(_canvas.size)
	var entries: Array = []
	if _step == STEP_LOCATION:
		entries = _scenes
	elif _step == STEP_WEATHER:
		entries = _weathers
	else:
		return
	var chosen: int = _scene_index if _step == STEP_LOCATION else _weather_index
	var kind: String = "scene" if _step == STEP_LOCATION else "weather"

	for i in entries.size():
		var r: Rect2 = _picture_rect(rect, i, entries.size(), 9.0 / 16.0)
		var selected: bool = i == chosen
		var hovered: bool = _focus_card(i, kind)
		if selected:
			UITheme.draw_glow(_overlay, r, UITheme.ACCENT, 14.0, 3)
			_frame(r, UITheme.ACCENT, 4.0)
			# A badge, not a bare tick floating on the photograph.
			var badge := Rect2(r.end - Vector2(50.0, 50.0), Vector2(38.0, 38.0))
			UITheme.draw_panel(_overlay, badge, UITheme.ACCENT, UITheme.ACCENT, 10.0)
			UITheme.draw_text(_overlay, badge.position + Vector2(0.0, 28.0), "✓",
							  UITheme.SIZE_VALUE, Color(0.02, 0.07, 0.10),
							  HORIZONTAL_ALIGNMENT_CENTER, badge.size.x)
		elif hovered:
			_frame(r, Color(1, 1, 1, 0.75), 2.0)


## A hollow rectangle of `width` pixels, drawn inside `rect`.
func _frame(rect: Rect2, colour: Color, width: float) -> void:
	_overlay.draw_rect(Rect2(rect.position, Vector2(rect.size.x, width)), colour)
	_overlay.draw_rect(Rect2(Vector2(rect.position.x, rect.end.y - width),
							 Vector2(rect.size.x, width)), colour)
	_overlay.draw_rect(Rect2(rect.position, Vector2(width, rect.size.y)), colour)
	_overlay.draw_rect(Rect2(Vector2(rect.end.x - width, rect.position.y),
							 Vector2(width, rect.size.y)), colour)


## How bright a picture card is drawn. Three states that have to be told apart
## at a glance: chosen, under the pointer, and neither.
func _picture_tint(selected: bool, hovered: bool) -> Color:
	if selected:
		return Color(1.0, 1.0, 1.0)
	if hovered:
		return Color(0.86, 0.90, 0.94)
	return Color(0.50, 0.54, 0.60)


## The backdrop follows the chosen place, dimmed hard enough that the panels
## and the type keep the screen.
func _refresh_backdrop() -> void:
	if _backdrop == null or _scenes.is_empty():
		return
	var id: String = String(_scenes[_scene_index]["id"])
	if id == _backdrop_id:
		return
	_backdrop_id = id
	var path: String = "res://assets/previews/scene_%s.png" % id
	if ResourceLoader.exists(path):
		_backdrop.texture = load(path) as Texture2D
	_backdrop.modulate = Color(0.62, 0.66, 0.72)


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
	# The wordmark's rule used to run 340 px to the right and disappear under
	# the first step tab. The header is two bands now - the wordmark and the
	# radio on the top one, the step tabs alone on the second - and the rule
	# that separates them runs the WHOLE width, under the tabs rather than
	# into them.
	UITheme.draw_rule(_canvas, Vector2(PAD, HEADER_RULE_Y) + shift,
					  size.x - PAD * 2.0, UITheme.STROKE, 1.0)

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
	# Not just "none detected". A player without a radio can still fly, and the
	# briefing room is where they should learn that rather than discovering it
	# on the strip.
	var device: String = "none - keyboard will fly it"
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
	UITheme.draw_display(_canvas, _setup_rect.position + Vector2(0, 48) + shift,
						 "SETUP", UITheme.SIZE_TITLE, UITheme.ACCENT,
						 HORIZONTAL_ALIGNMENT_CENTER, _setup_rect.size.x)

	UITheme.draw_panel(_canvas, Rect2(_quit_rect.position + shift, _quit_rect.size),
					   UITheme.PANEL, UITheme.STROKE_STRONG, 10.0)
	UITheme.draw_display(_canvas, _quit_rect.position + Vector2(0, 48) + shift,
						 "QUIT", UITheme.SIZE_TITLE, UITheme.TEXT_DIM,
						 HORIZONTAL_ALIGNMENT_CENTER, _quit_rect.size.x)


## The four steps, with the current one lit and the completed ones checkmarked.
## One step's pill. Layout and drawing share it, so what is clickable is what
## is drawn.
func _crumb_rect(size: Vector2, index: int) -> Rect2:
	# Full width, on their own line. Centred in a narrow 1180 band they sat
	# beside the wordmark and the QUIT button rather than below them.
	var total: float = size.x - PAD * 2.0
	var each: float = total / float(STEP_COUNT)
	return Rect2(PAD + each * float(index) + 8.0, CRUMB_Y, each - 16.0, CRUMB_H)


func _draw_breadcrumb(size: Vector2, shift: Vector2) -> void:
	for i in STEP_COUNT:
		var rect: Rect2 = _crumb_rect(size, i)
		var current: bool = i == _step
		var done: bool = i < _step
		var hovered: bool = _hover.get("action", "") == "step" \
				and int(_hover.get("index", -1)) == i

		var fill := Color(0.05, 0.09, 0.12, 0.85)
		var stroke: Color = UITheme.STROKE
		if current:
			UITheme.draw_glow(_canvas, rect, UITheme.ACCENT, 12.0, 3)
			fill = Color(UITheme.ACCENT.r * 0.30, UITheme.ACCENT.g * 0.34,
						 UITheme.ACCENT.b * 0.38, 0.95)
			stroke = UITheme.ACCENT
		elif done:
			fill = Color(0.05, 0.11, 0.10, 0.92)
			stroke = UITheme.GOOD
		elif hovered:
			fill = Color(0.09, 0.14, 0.18, 0.95)
			stroke = UITheme.STROKE_STRONG
		UITheme.draw_panel(_canvas, rect, fill, stroke, 12.0)

		var label: String = "%d  %s" % [i + 1, STEP_NAMES[i]]
		var colour: Color = UITheme.TEXT if current \
				else (UITheme.GOOD if done else UITheme.TEXT_DIM)
		if done:
			UITheme.draw_text(_canvas, rect.position + Vector2(14.0, 39.0), "✓",
							  UITheme.SIZE_VALUE, UITheme.GOOD)
		# The pill's LEFT edge, with the pill's width: draw_string takes the
		# position as the left edge of the box it centres within, so passing
		# the centre shifts the label right by half a tab.
		UITheme.draw_display(_canvas, rect.position + Vector2(0.0, 40.0), label,
							 UITheme.SIZE_TITLE, colour,
							 HORIZONTAL_ALIGNMENT_CENTER, rect.size.x)


func _section_heading(pos: Vector2, text: String, sub: String) -> void:
	UITheme.draw_display(_canvas, pos, text, UITheme.SIZE_TITLE, UITheme.TEXT)
	if sub != "":
		# TEXT_DIM at label size, over sunlit grass, was not a colour so much
		# as a rumour - the line that explains each step was the least
		# readable thing on the screen. Lifted, and given the heavier shadow
		# the title gets, because it is competing with the same background.
		UITheme.draw_text_shadow(_canvas, pos + Vector2(0, 36), sub,
								 UITheme.SIZE_BODY, Color(0.76, 0.82, 0.90),
								 Color(0, 0, 0, 0.7))
	# Spaced for the type that is actually drawn. At +28 and +44 the subtitle
	# and the rule were 16 px apart, which is less than the subtitle is tall.
	UITheme.draw_rule(_canvas, pos + Vector2(0, 66), 320.0, UITheme.ACCENT, 2.0)


func _draw_aircraft(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	_section_heading(rect.position - Vector2(0, 90), "Choose your aeroplane",
					 "%d machines, easiest first. Each one is measured, not described."
					 % _aircraft.size())
	# The roster down the left. The selected card was a faint tint and a thin
	# rule, which at a glance said nothing: four cards, one very slightly
	# bluer. It is now unmistakable - a filled accent panel, a heavy left bar,
	# a glow, the name in white and a chevron pointing at the aeroplane the
	# stage is showing.
	for i in _aircraft.size():
		var r: Rect2 = _aircraft_card_rect(rect, i)
		var selected: bool = i == _aircraft_index
		var pulse: float = _card_pulse.get("aircraft:%d" % i, 0.0)
		_draw_card(r, selected, _focus_card(i, "aircraft"), pulse, 2.0)

		var card: Dictionary = _aircraft[i]
		var x: float = r.position.x + 26.0
		UITheme.draw_text(_canvas, Vector2(x, r.position.y + 44.0), card["name"],
						  UITheme.SIZE_TITLE,
						  UITheme.TEXT if selected else UITheme.TEXT_DIM)
		# "31 N/m2, 439 W/kg" is what an engineer wants and tells a beginner
		# nothing about whether this aeroplane will bite them. The span and
		# the weight are physical and stay; the rest is one word.
		var specs: String = "%.1f m   %.2f kg   %s%s" % [
			card["span"], card["mass"], Ranking.word(float(card["difficulty"])),
			"   hand launched" if bool(card.get("hand_launched", false)) else ""]
		UITheme.draw_text(_canvas, Vector2(x, r.position.y + 76.0), specs,
						  UITheme.SIZE_LABEL,
						  UITheme.ACCENT if selected else UITheme.TEXT_FAINT)

		# And a bar for it, so five aeroplanes can be compared at a glance
		# rather than by reading five words.
		var bar := Rect2(r.end.x - 118.0, r.position.y + 62.0, 84.0, 6.0)
		var band: float = float(card["difficulty"])
		var shade: Color = UITheme.GOOD
		if band > 0.38: shade = UITheme.ACCENT
		if band > 0.52: shade = UITheme.WARN
		if band > 0.68: shade = UITheme.DANGER
		UITheme.draw_track(_canvas, bar, band, shade)

		if selected:
			UITheme.draw_text(_canvas, Vector2(r.end.x - 40.0,
							  r.position.y + r.size.y * 0.5 + 12.0), "▶",
							  UITheme.SIZE_VALUE, UITheme.ACCENT)

	# The middle column is the aeroplane. Everything else on this screen is a
	# description of it.
	if not _aircraft.is_empty():
		var stage_rect: Rect2 = _aircraft_stage_rect(rect)
		var chosen: Dictionary = _aircraft[_aircraft_index]
		_place_stage(stage_rect, String(chosen["stem"]), float(chosen["span"]))
		UITheme.draw_display(_canvas, Vector2(stage_rect.position.x,
							 stage_rect.end.y + 50.0), String(chosen["name"]),
							 UITheme.SIZE_HERO, UITheme.TEXT,
							 HORIZONTAL_ALIGNMENT_CENTER, stage_rect.size.x)

	if not _aircraft.is_empty():
		var card: Dictionary = _aircraft[_aircraft_index]
		var brief_w: float = AIRCRAFT_BRIEF_W
		var lines: int = UITheme.wrap_text(card["description"], brief_w - 48.0,
										   UITheme.SIZE_LABEL).size()
		var perf_rows: int = 0
		for key in BRIEF_MEASURED:
			if card.get("performance", {}).has(key[1]):
				perf_rows += 1
		var brief_h: float = 132.0 + lines * 24.0 + 18.0 \
				+ 32.0 + perf_rows * 32.0 + 14.0 + 32.0 + 3 * 32.0
		var brief := Rect2(rect.end.x - brief_w, rect.position.y,
						   brief_w, minf(brief_h, rect.size.y))
		UITheme.draw_panel(_canvas, brief, UITheme.PANEL, UITheme.ACCENT, 12.0)
		UITheme.draw_label(_canvas, brief.position + Vector2(24, 46), "the brief",
						   UITheme.ACCENT, 3.0, UITheme.SIZE_SECTION)
		var by: float = brief.position.y + 92.0
		var band: float = float(card.get("difficulty", 0.5))
		var shade: Color = UITheme.GOOD
		if band > 0.38: shade = UITheme.ACCENT
		if band > 0.52: shade = UITheme.WARN
		if band > 0.68: shade = UITheme.DANGER
		UITheme.draw_text(_canvas, Vector2(brief.position.x + 24, by),
						  "To fly: %s" % Ranking.word(band),
						  UITheme.SIZE_VALUE, shade)
		by += 40.0
		for line in UITheme.wrap_text(card["description"], brief.size.x - 48.0, UITheme.SIZE_LABEL):
			UITheme.draw_text(_canvas, Vector2(brief.position.x + 24, by), line,
							  UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
			by += 24.0
		by += 18.0

		# Everything below is MEASURED - the regression suite flies each of
		# these and records what it got. Three numbers on a panel this size
		# left it four fifths empty, which read as "there is nothing more to
		# know" when in fact the interesting half of the aeroplane's
		# character was sitting unused in the file. Each row also carries a
		# bar showing where this machine sits against the rest of the
		# roster, so a glance answers "compared to what?".
		var perf: Dictionary = card.get("performance", {})
		UITheme.draw_label(_canvas, Vector2(brief.position.x + 24, by),
						   "measured in flight", UITheme.TEXT_FAINT)
		UITheme.draw_rule(_canvas, Vector2(brief.position.x + 24, by + 10.0),
						  brief.size.x - 48.0)
		by += 34.0
		for row in BRIEF_MEASURED:
			if not perf.has(row[1]):
				continue
			by = _brief_row(brief, by, row[0], row[2] % float(perf[row[1]]),
							_roster_fraction(row[1], float(perf[row[1]])))

		by += 14.0
		UITheme.draw_label(_canvas, Vector2(brief.position.x + 24, by),
						   "on the ground", UITheme.TEXT_FAINT)
		UITheme.draw_rule(_canvas, Vector2(brief.position.x + 24, by + 10.0),
						  brief.size.x - 48.0)
		by += 34.0
		for row in [["wing loading", "%.0f N/m2" % card["loading"], "loading"],
					["power / weight", "%.0f W/kg" % card["pw"], "pw"],
					["approach speed", "%.1f m/s" % card["approach"], "approach"]]:
			by = _brief_row(brief, by, row[0], row[1],
							_roster_fraction(row[2], float(card[row[2]])))

		if bool(card.get("hand_launched", false)):
			by += 8.0
			UITheme.draw_text(_canvas, Vector2(brief.position.x + 24, by),
							  "Hand launched - it has no undercarriage.",
							  UITheme.SIZE_BODY, UITheme.WARN)


## Puts the selected aeroplane on the stand and positions the stand.
##
## The TextureRect is a child of the canvas, so it draws over the panels the
## canvas paints; it is created once and moved, rather than made each frame.
func _place_stage(rect: Rect2, stem: String, span: float) -> void:
	if _stage == null:
		return
	if _stage_view == null:
		_stage_view = TextureRect.new()
		_stage_view.texture = _stage.call("texture")
		_stage_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_stage_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_canvas.add_child(_stage_view)
	_stage_view.visible = true
	_stage_view.position = rect.position
	_stage_view.size = rect.size
	_stage.call("set_stage_size", Vector2i(int(rect.size.x), int(rect.size.y)))
	_stage.call("show_aircraft", stem, span)


## One line of the brief: name, value, and a bar placing the value against the
## rest of the roster. Returns the y for the line below.
func _brief_row(brief: Rect2, y: float, label: String, value: String,
				fraction: float) -> float:
	UITheme.draw_text(_canvas, Vector2(brief.position.x + 24, y), label,
					  UITheme.SIZE_LABEL, UITheme.TEXT_FAINT)
	# Right-aligned so the digits line up in a column. draw_string takes the
	# position as the LEFT edge of the box it aligns within, so the box is
	# placed to end at x + 300, not to start there.
	UITheme.draw_text(_canvas, Vector2(brief.position.x + 150, y), value,
					  UITheme.SIZE_BODY, UITheme.TEXT,
					  HORIZONTAL_ALIGNMENT_RIGHT, 150.0)
	var track := Rect2(brief.position.x + 320.0, y - 10.0,
					   brief.size.x - 344.0, 6.0)
	UITheme.draw_track(_canvas, track, fraction)
	return y + 32.0


## Where `value` sits between the smallest and largest the roster has for the
## same figure, 0..1. With one aeroplane, or a figure they all share, the bar
## is drawn half full rather than empty - an empty bar reads as "none of it".
func _roster_fraction(key: String, value: float) -> float:
	var low: float = INF
	var high: float = -INF
	for entry in _aircraft:
		var candidate: float = 0.0
		if entry.has(key):
			candidate = float(entry[key])
		else:
			var perf: Dictionary = entry.get("performance", {})
			if not perf.has(key):
				continue
			candidate = float(perf[key])
		low = minf(low, candidate)
		high = maxf(high, candidate)
	if not is_finite(low) or high - low < 0.0001:
		return 0.5
	return clampf((value - low) / (high - low), 0.06, 1.0)


func _draw_scenes(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	_section_heading(rect.position - Vector2(0, 90), "Where do you want to fly?",
					 "Each place is its own climate and geology. The previews are real frames.")
	for i in _scenes.size():
		var r: Rect2 = _picture_rect(rect, i, _scenes.size(), 9.0 / 16.0)
		var selected: bool = i == _scene_index
		var pulse: float = _card_pulse.get("scene:%d" % i, 0.0)
		_draw_card(r, selected, _focus_card(i, "scene"), pulse, 1.0)

		# The tick and the frame are drawn by the overlay, above the picture.
		var name_y: float = r.end.y + 38.0
		UITheme.draw_display(_canvas, Vector2(r.position.x, name_y),
							 String(_scenes[i]["name"]), UITheme.SIZE_TITLE,
							 UITheme.TEXT if selected else UITheme.TEXT_DIM,
							 HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

	var place: Dictionary = _scenes[_scene_index]
	_draw_detail(rect, String(place["name"]), String(place["description"]), [])


func _draw_weather(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	_section_heading(rect.position - Vector2(0, 90), "What kind of day?",
					 "Weather is not a filter - it changes the air and the ground.")
	for i in _weathers.size():
		var r: Rect2 = _picture_rect(rect, i, _weathers.size(), 9.0 / 16.0)
		var selected: bool = i == _weather_index
		var pulse: float = _card_pulse.get("weather:%d" % i, 0.0)
		_draw_card(r, selected, _focus_card(i, "weather"), pulse, 1.0)

		# The tick and the frame are drawn by the overlay, above the picture.
		var name_y: float = r.end.y + 38.0
		UITheme.draw_display(_canvas, Vector2(r.position.x, name_y),
							 String(_weathers[i]["name"]), UITheme.SIZE_TITLE,
							 UITheme.TEXT if selected else UITheme.TEXT_DIM,
							 HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
		var wind: String = "%.1f m/s wind" % _weathers[i]["wind_mps"]
		UITheme.draw_text(_canvas, Vector2(r.position.x, name_y + 30.0), wind,
						  UITheme.SIZE_BODY,
						  UITheme.ACCENT if selected else UITheme.TEXT_DIM,
						  HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

	# What the chosen day actually does to the air and the ground. The row of
	# cards left the bottom half of the screen empty, and this is the half of
	# the weather a pilot feels rather than sees.
	var day: Dictionary = _weathers[_weather_index]
	var gust: float = float(day["wind_mps"]) * float(day["gust"])
	_draw_detail(rect, String(day["name"]), String(day["description"]), [
		["wind", "%.1f m/s" % day["wind_mps"]],
		["gusting to", "%.1f m/s" % (float(day["wind_mps"]) + gust)],
		["turbulence", "%.1f m/s" % day["turbulence"]],
		["ground grip", "%.0f %%" % (float(day["ground_grip"]) * 100.0)],
		["thermals", "%.0f %% of a clear day" % (float(day["thermal_scale"]) * 100.0)],
	])


func _draw_review(size: Vector2) -> void:
	var rect: Rect2 = _content_rect(size)
	_section_heading(rect.position - Vector2(0, 90), "The sortie",
					 "Everything below is what you are about to fly.")
	var gap: float = 20.0
	var card_w: float = (rect.size.x - gap * 2.0) / 3.0
	# Sized to the tallest of the three, not to the screen. Three panels each
	# two thirds empty read as a page that failed to finish loading; three of
	# the same height, each full, read as a summary.
	var card_h: float = minf(rect.size.y, 620.0)

	var aircraft: Dictionary = _aircraft[_aircraft_index] if not _aircraft.is_empty() else {}
	var scene: Dictionary = _scenes[_scene_index]
	var weather: Dictionary = _weathers[_weather_index]

	# ---- what you are flying ------------------------------------------------
	var r0 := Rect2(rect.position, Vector2(card_w, card_h))
	UITheme.draw_panel(_canvas, r0, UITheme.PANEL, UITheme.ACCENT, 12.0)
	UITheme.draw_label(_canvas, r0.position + Vector2(20, 32), "aircraft",
					   UITheme.ACCENT, 2.6, UITheme.SIZE_SECTION)
	UITheme.draw_display(_canvas, r0.position + Vector2(20, 76), aircraft["name"],
						 UITheme.SIZE_LARGE, UITheme.TEXT)

	var band: float = float(aircraft.get("difficulty", 0.5))
	var shade: Color = UITheme.GOOD
	if band > 0.50: shade = UITheme.ACCENT
	if band > 0.62: shade = UITheme.WARN
	if band > 0.72: shade = UITheme.DANGER
	UITheme.draw_text(_canvas, r0.position + Vector2(20, 112),
					  "To fly: %s" % Ranking.word(band), UITheme.SIZE_VALUE, shade)
	if bool(aircraft.get("hand_launched", false)):
		UITheme.draw_text(_canvas, r0.position + Vector2(20, 142),
						  "Hand launched - no undercarriage.",
						  UITheme.SIZE_BODY, UITheme.WARN)

	var ay: float = 182.0
	# The measured figures, which are the ones that say how it will fly. The
	# battery chemistry and the motor KV were here instead, and neither tells
	# a pilot anything at the moment they are about to take off.
	var performance: Dictionary = aircraft.get("performance", {})
	for row in [["span / weight", "%.1f m   %.2f kg" % [aircraft["span"], aircraft["mass"]]],
				["stall speed", "%.1f m/s" % performance.get("stall_speed_mps", 0.0)],
				["approach speed", "%.1f m/s" % aircraft["approach"]],
				["roll rate", "%.0f deg/s" % performance.get("roll_rate_deg_per_s", 0.0)],
				["glide ratio", "%.1f : 1" % performance.get("glide_ratio", 0.0)],
				["power / weight", "%.0f W/kg" % aircraft["pw"]]]:
		_review_row(r0, ay, String(row[0]), String(row[1]))
		ay += 34.0

	# ---- where ---------------------------------------------------------------
	var r1 := Rect2(rect.position + Vector2(card_w + gap, 0), Vector2(card_w, card_h))
	UITheme.draw_panel(_canvas, r1, UITheme.PANEL, UITheme.ACCENT, 12.0)
	UITheme.draw_label(_canvas, r1.position + Vector2(20, 32), "location",
					   UITheme.ACCENT, 2.6, UITheme.SIZE_SECTION)
	var thumb_h: float = _review_thumb_size(card_w).y
	var ly: float = 56.0 + thumb_h + 46.0
	UITheme.draw_display(_canvas, r1.position + Vector2(20, ly), String(scene["name"]),
						 UITheme.SIZE_LARGE, UITheme.TEXT)
	ly += 36.0
	for line in UITheme.wrap_text(String(scene["description"]), card_w - 40.0,
								  UITheme.SIZE_BODY):
		UITheme.draw_text(_canvas, r1.position + Vector2(20, ly), line,
						  UITheme.SIZE_BODY, UITheme.TEXT_DIM)
		ly += 28.0

	# ---- and in what ---------------------------------------------------------
	var r2 := Rect2(rect.position + Vector2((card_w + gap) * 2.0, 0),
					Vector2(card_w, card_h))
	UITheme.draw_panel(_canvas, r2, UITheme.PANEL, UITheme.ACCENT, 12.0)
	UITheme.draw_label(_canvas, r2.position + Vector2(20, 32), "weather",
					   UITheme.ACCENT, 2.6, UITheme.SIZE_SECTION)
	var wy: float = 56.0 + thumb_h + 46.0
	UITheme.draw_display(_canvas, r2.position + Vector2(20, wy), String(weather["name"]),
						 UITheme.SIZE_LARGE, UITheme.TEXT)
	wy += 40.0
	var gust: float = float(weather["wind_mps"]) * float(weather["gust"])
	var air: Array = [["wind", "%.1f m/s" % weather["wind_mps"]],
					  ["gusting to", "%.1f m/s" % (float(weather["wind_mps"]) + gust)],
					  ["turbulence", "%.1f m/s" % weather["turbulence"]],
					  ["ground grip", "%.0f %%" % (float(weather["ground_grip"]) * 100.0)],
					  ["thermals", "%.0f %%" % (float(weather["thermal_scale"]) * 100.0)]]
	# The pitch follows the space there is, so the last row cannot fall out of
	# the bottom of the card - which is what "thermals" was doing.
	var pitch: float = minf(34.0, (card_h - wy - 24.0) / float(air.size()))
	for row in air:
		_review_row(r2, wy, String(row[0]), String(row[1]))
		wy += pitch


## One label-and-value line on a sortie card, the value right-aligned to the
## card's own edge so the three columns line up with each other.
func _review_row(card: Rect2, y: float, label: String, value: String) -> void:
	UITheme.draw_text(_canvas, card.position + Vector2(20, y), label,
					  UITheme.SIZE_BODY, UITheme.TEXT_FAINT)
	UITheme.draw_text(_canvas,
					  Vector2(card.end.x - 24.0 - UITheme.text_width(value, UITheme.SIZE_VALUE),
							  card.position.y + y),
					  value, UITheme.SIZE_VALUE, UITheme.TEXT)


## Is THIS card under the pointer?
##
## It used to answer "is this kind of card the one this step shows", which is
## true for every card on the step at once - so the hovered state was passed to
## the drawing code as "all of them", and the drawing code, reasonably enough,
## ignored it. Hover and selection looked identical for months.
func _focus_card(index: int, kind: String) -> bool:
	return _hover.get("kind", "") == kind and int(_hover.get("index", -1)) == index


func _draw_card(rect: Rect2, selected: bool, hovered: bool, pulse: float,
				lift: float) -> void:
	var lifted := Rect2(rect.position - Vector2(0, pulse * lift), rect.size)
	var fill: Color = UITheme.PANEL
	var stroke: Color = UITheme.STROKE
	if selected:
		fill = Color(UITheme.ACCENT.r * 0.42, UITheme.ACCENT.g * 0.46,
					 UITheme.ACCENT.b * 0.50, 0.94)
		stroke = UITheme.ACCENT
		UITheme.draw_glow(_canvas, lifted, UITheme.ACCENT, 12.0, 3)
	elif hovered:
		fill = Color(0.13, 0.18, 0.23, 0.92)
		stroke = Color(1, 1, 1, 0.55)
	UITheme.draw_panel(_canvas, lifted, fill, stroke, 10.0)
	if selected:
		_canvas.draw_rect(Rect2(lifted.position, Vector2(6, lifted.size.y)),
						  UITheme.ACCENT, true)


func _draw_back() -> void:
	UITheme.draw_panel(_canvas, _back_rect,
			Color(1, 1, 1, 0.06) if _hover.get("action", "") == "back" else UITheme.PANEL,
			UITheme.STROKE_STRONG, 10.0)
	UITheme.draw_display(_canvas, _back_rect.position + Vector2(0, 46), "BACK",
						 UITheme.SIZE_TITLE, UITheme.TEXT_DIM,
						 HORIZONTAL_ALIGNMENT_CENTER, _back_rect.size.x)


func _draw_footer(size: Vector2) -> void:
	# Back button - absent on the first step, where it would go nowhere.
	if _back_rect.size.x > 0.0:
		_draw_back()

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
		UITheme.draw_display(_canvas, r.position + Vector2(0, 52), "FLY",
							 UITheme.SIZE_HERO, Color(0.02, 0.06, 0.09, 1.0),
							 HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
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
		UITheme.draw_display(_canvas, r.position + Vector2(0, 46), "NEXT",
							 UITheme.SIZE_TITLE, UITheme.ACCENT,
							 HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

	# The corner hint, readable now.
	UITheme.draw_text(_canvas, Vector2(0.0, size.y - 36.0),
					  "arrows choose   enter %s   backspace back   esc %s" %
					  ["fly" if _step == STEP_REVIEW else "next",
					   "quit" if start_screen else "close"],
					  UITheme.SIZE_BODY, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER,
					  size.x)


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
