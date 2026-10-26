# OpenRC Simulator - the main menu: the Fly hub.
#
# The menu used to be a briefing in four steps - aircraft, location, weather,
# fly - which is the right shape for a sim with forty aircraft, fuel loads and
# times of day. Here there are five of each, the defaults are right for nine
# flights in ten, and the steps were three presses that rarely changed
# anything. So it is one screen:
#
#   HERO     the aircraft on its turntable, its name, a few plain words
#   LOADOUT  four chips - Aircraft, Location, Weather, Start - each opening a
#            picker over the hero; Esc in a picker changes nothing
#   FLY      the one primary action, focused on open: Enter flies
#   MODES    a guided first flight, and landing practice
#
# The loadout is remembered between launches (Settings last/*), so a returning
# pilot opens the game and presses Enter. Everything is drawn on one canvas;
# what is clickable and what is drawn share one layout pass, so they cannot
# disagree. The menu plays its own quiet music and the UI speaks in clicks -
# all synthesised, like everything else in this project.
extends CanvasLayer

const UITheme := preload("res://ui/UITheme.gd")
const ScenePresetsLib := preload("res://world/ScenePresets.gd")
const WeatherLib := preload("res://world/Weather.gd")
const SoundBank := preload("res://audio/SoundBank.gd")
const StageScript := preload("res://ui/AircraftStage.gd")
const Ranking := preload("res://ui/AircraftRanking.gd")
const Settings := preload("res://ui/Settings.gd")

## options = {"spawn": "runway"|"air"|"approach", "mode": "free"|"first_flight"}
signal fly_requested(aircraft_stem: String, scene_id: String, weather_id: String,
		options: Dictionary)
## The Modes column's "First flight": Flight.gd runs the guided flight.
signal first_flight_requested
signal wizard_requested
signal tuning_requested
signal settings_requested
signal help_requested

@export var input_path: NodePath
@export var simulation_path: NodePath
@export var director_path: NodePath
## True on a cold start, when closing the menu means leaving the simulator.
@export var start_screen: bool = true

## Where the aircraft starts: setting value, chip text, picker description.
const SPAWNS: Array = [
	["runway", "On the runway", "Lined up on the strip. Open the throttle and take off."],
	["air", "In the air", "Already flying, at a safe height. Good for practising turns."],
	["approach", "On approach", "Lined up with the runway and descending. Land it."],
]
const CHIP_NAMES: Array[String] = ["Aircraft", "Location", "Weather", "Start"]
const PICKER_KINDS: Array[String] = ["aircraft", "scene", "weather", "start"]
## The aircraft the guided first flight uses, and the one we recommend.
const RECOMMENDED_STEM: String = "Trainer1500"

## The brief's flown figures: label, the key the regression suite stores it
## under, and the format. An aircraft that has not been measured for one of
## these simply does not show that row.
const BRIEF_MEASURED: Array = [
	["glide ratio", "glide_ratio", "%.1f : 1"],
	["stall speed", "stall_speed_mps", "%.1f m/s"],
	["roll rate", "roll_rate_deg_per_s", "%.0f deg/s"],
	["cruise", "cruise_speed_mps", "%.1f m/s"],
	["static thrust", "static_thrust_n", "%.1f N"],
	["takeoff roll", "takeoff_ground_roll_m", "%.1f m"],
]

const G: float = 48.0                 # gutter
const HEADER_H: float = 112.0
const ROW_H: float = 96.0             # loadout chips and FLY
const COL_W: float = 452.0            # the modes column
const FOOTER_H: float = 80.0
const PAD: float = G                  # kept for older callers

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
var _spawn_index: int = 0

# ------------------------------------------------------------------- state --
## Which picker is open over the hero: "" (the hub), or one of PICKER_KINDS.
var _picker: String = ""
## The index the picker had when it opened, restored by Esc.
var _picker_before: int = 0
var _picker_t: float = 0.0
## Keyboard focus on the hub: "fly", "chip0".."chip3", "mode0", "mode1",
## "pill", "help", "settings", "quit".
var _focus: String = "fly"
var _ring := Rect2()                  # the focus ring, travelling
var _ring_radius: float = UITheme.R_MD
var _hover: Dictionary = {}
var _hover_time: float = 0.0
var _appear: float = 0.0
var _press: float = 0.0
var _press_action: String = ""
var _clock: float = 0.0

## Compatibility with the four-step menu: 0..2 opened that step, 3 was the
## review. Tests (Playthrough, ReviewShot) still drive the menu this way.
var _step: int:
	get:
		var i: int = PICKER_KINDS.find(_picker)
		return i if i >= 0 and i < 3 else 3
	set(value):
		_set_step(value)

# ------------------------------------------------------------------ layout --
var _rects: Dictionary = {}
var _hit: Array[Dictionary] = []
var _thumbs: Array[TextureRect] = []
var _thumb_cache: Dictionary = {}

## The turntable, and the rectangle it is drawn in.
var _stage: Node
var _stage_view: TextureRect
var _stage_rect := Rect2()
## Drawn above the picture cards, which are Controls and therefore paint over
## anything the canvas draws underneath them.
var _overlay: Control
## The picture behind everything: the place currently chosen.
var _backdrop: TextureRect
var _backdrop_id: String = ""
var _backdrop_tex: Texture2D

var _progress: float = 0.0
var _progress_active: bool = false
var _fade: float = -1.0

const LOCKUP_PATH: String = "res://assets/brand/lockup.png"
var _lockup: Texture2D


func _ready() -> void:
	layer = 20
	_input = get_node_or_null(input_path) as RCInputNode
	_sim = get_node_or_null(simulation_path) as RCSimulationNode
	_director = get_node_or_null(director_path)

	# The backdrop: a picture of the chosen place, not the live world - the
	# world is built when the pilot presses Fly, not before the menu opens.
	_backdrop = TextureRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)
	add_child(UITheme.make_frosted(0.50, 2.4))

	_music = AudioStreamPlayer.new()
	_music.name = "MenuMusic"
	_music.stream = SoundBank.menu_music()
	_music.volume_db = -18.0
	_music.bus = Settings.BUS_MENU
	add_child(_music)
	_music.play()

	_sfx = AudioStreamPlayer.new()
	_sfx.name = "MenuSfx"
	_sfx.bus = Settings.BUS_MENU
	add_child(_sfx)

	_stage = StageScript.new()
	_stage.name = "Stage"
	add_child(_stage)

	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.anchor_right = 1.0
	_canvas.anchor_bottom = 1.0
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_menu)
	_canvas.gui_input.connect(_on_gui_input)
	add_child(_canvas)

	_overlay = Control.new()
	_overlay.name = "Overlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	_canvas.add_child(_overlay)

	if Settings.reduced_motion():
		_appear = 1.0

	_gather()

	# What is flying now, then what was flown last: the remembered loadout
	# wins, so a menu opened after a guided first flight still shows the
	# pilot's own choice rather than the lesson's preset.
	if _sim != null:
		_select_aircraft(_sim.aircraft_definition.get_file().get_basename())
	if _director != null:
		_select_scene(String(_director.get("scene_id")))
		_select_weather(String(_director.get("weather_id")))
	_restore_loadout()

	_layout()
	_ring = _rects.get(_focus, Rect2())


func _gather() -> void:
	_scenes = ScenePresetsLib.all()
	_weathers = WeatherLib.all()

	if _sim == null:
		_aircraft = [{"stem": "Trainer1500", "name": "Trainer 1500",
					  "description": "", "span": 0.0, "mass": 0.0, "approach": 0.0,
					  "loading": 0.0, "pw": 0.0, "cells": 0, "capacity": 0.0,
					  "kv": 0.0, "cruise": 0.0, "difficulty": 0.4,
					  "performance": {}, "nose_wheel": true}]
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
			# Flown, not quoted: what the regression suite measured.
			"performance": _sim.get_performance(),
			"hand_launched": _sim.is_hand_launched(),
			"nose_wheel": _sim.has_steerable_nose_wheel(),
		})
	_sim.aircraft_definition = restore
	_sim.reload_aircraft()

	# Easiest first: the first thing in a list is a recommendation whether or
	# not it was meant as one.
	Ranking.rank(_aircraft)
	_aircraft_index = 0
	for card in _aircraft:
		card["tags"] = _plain_tags(card)
	if OS.has_environment("RC_MENU_DEBUG"):
		for card in _aircraft:
			print("   %-14s handling %.3f  order %.3f  tags %s"
				  % [card["name"], card["difficulty"], card["learn_order"], card["tags"]])


func _select_aircraft(stem: String) -> bool:
	for i in _aircraft.size():
		if _aircraft[i]["stem"] == stem:
			_aircraft_index = i
			return true
	return false


func _select_scene(id: String) -> bool:
	for i in _scenes.size():
		if _scenes[i]["id"] == id:
			_scene_index = i
			return true
	return false


func _select_weather(id: String) -> bool:
	for i in _weathers.size():
		if _weathers[i]["id"] == id:
			_weather_index = i
			return true
	return false


func _restore_loadout() -> void:
	var stem: String = String(Settings.get_value("last/aircraft"))
	if stem != "":
		_select_aircraft(stem)
	var scene: String = String(Settings.get_value("last/scene"))
	if scene != "":
		_select_scene(scene)
	var weather: String = String(Settings.get_value("last/weather"))
	if weather != "":
		_select_weather(weather)
	var spawn: String = String(Settings.get_value("last/spawn"))
	for i in SPAWNS.size():
		if SPAWNS[i][0] == spawn:
			_spawn_index = i


func _save_loadout(include_spawn: bool) -> void:
	if _aircraft.is_empty():
		return
	Settings.set_value("last/aircraft", String(_aircraft[_aircraft_index]["stem"]), false)
	Settings.set_value("last/scene", String(_scenes[_scene_index]["id"]), false)
	if include_spawn:
		Settings.set_value("last/spawn", String(SPAWNS[_spawn_index][0]), false)
	Settings.set_value("last/weather", String(_weathers[_weather_index]["id"]), true)


## A few plain words about an aircraft, from what was measured, relative to the
## rest of the roster. A beginner cannot read "41 N/m2"; they can read "lands
## slow". The first word is always how it flies.
func _plain_tags(card: Dictionary) -> Array:
	var tags: Array = []
	var word: String = Ranking.word(float(card.get("difficulty", 0.5)))
	tags.append([word.capitalize(), _difficulty_kind(float(card.get("difficulty", 0.5)))])
	var perf: Dictionary = card.get("performance", {})
	if bool(card.get("hand_launched", false)):
		tags.append(["Hand launched", "state"])
	elif not bool(card.get("nose_wheel", true)):
		tags.append(["Tail-dragger", "state"])
	if perf.has("glide_ratio") and _roster_fraction("glide_ratio", float(perf["glide_ratio"])) > 0.7:
		tags.append(["Glides far", "state"])
	if _roster_fraction("approach", float(card.get("approach", 0.0))) < 0.35:
		tags.append(["Lands slow", "state"])
	elif _roster_fraction("approach", float(card.get("approach", 0.0))) > 0.75:
		tags.append(["Lands fast", "state"])
	if perf.has("roll_rate_deg_per_s") \
			and _roster_fraction("roll_rate_deg_per_s", float(perf["roll_rate_deg_per_s"])) > 0.7:
		tags.append(["Rolls quickly", "state"])
	if _roster_fraction("pw", float(card.get("pw", 0.0))) > 0.75:
		tags.append(["Lots of power", "state"])
	return tags


static func _difficulty_kind(band: float) -> String:
	if band < 0.50: return "good"
	if band < 0.72: return "info"
	return "warn"


static func _difficulty_colour(band: float) -> Color:
	if band < 0.50: return UITheme.GOOD
	if band < 0.62: return UITheme.ACCENT
	if band < 0.72: return UITheme.WARN
	return UITheme.DANGER


# ------------------------------------------------------------- interaction --

func _on_gui_input(event: InputEvent) -> void:
	if _progress_active:
		return
	if event is InputEventMouseMotion:
		var hit: Dictionary = _hit_at((event as InputEventMouseMotion).position)
		if hit.get("action", "") != _hover.get("action", "") \
				or int(hit.get("index", -1)) != int(_hover.get("index", -1)):
			_hover = hit
			_hover_time = 0.0
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
			_press = 1.0
			_press_action = String(hit.get("action", ""))
			if _picker == "" and _press_action != "":
				_set_focus(_press_action, false)
			_activate(hit)
		else:
			_press_action = ""


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if _progress_active:
		get_viewport().set_input_as_handled()
		return
	var key: int = (event as InputEventKey).keycode
	if _picker != "":
		match key:
			KEY_UP, KEY_LEFT: _nudge(-1)
			KEY_DOWN, KEY_RIGHT: _nudge(1)
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: _close_picker(true)
			KEY_ESCAPE, KEY_BACKSPACE: _close_picker(false)
			KEY_H, KEY_F1: help_requested.emit()
			_:
				return
	else:
		match key:
			KEY_LEFT: _move_focus(3)
			KEY_RIGHT: _move_focus(1)
			KEY_UP: _move_focus(0)
			KEY_DOWN: _move_focus(2)
			KEY_TAB: _cycle_focus(-1 if (event as InputEventKey).shift_pressed else 1)
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				if _focus == "fly":
					_press = 1.0
					_press_action = "fly"
				_activate({"action": _focus})
			KEY_BACKSPACE, KEY_ESCAPE: _close_or_quit()
			KEY_F3, KEY_C: _activate({"action": "pill"})
			KEY_H, KEY_F1: help_requested.emit()
			KEY_O: _activate({"action": "settings"})
			KEY_F4: _activate({"action": "tuning"})
			_:
				return
	_canvas.queue_redraw()
	get_viewport().set_input_as_handled()


## Arrow-key focus on the hub. dir: 0 up, 1 right, 2 down, 3 left. The hub is
## three regions - the header, the modes column and the loadout row - and the
## map below is the way the eye moves between them.
const _FOCUS_MAP: Dictionary = {
	"chip0": ["pill", "chip1", "", ""],
	"chip1": ["pill", "chip2", "", "chip0"],
	"chip2": ["pill", "chip3", "", "chip1"],
	"chip3": ["pill", "fly", "", "chip2"],
	"fly":   ["mode1", "", "", "chip3"],
	"mode0": ["pill", "", "mode1", "chip3"],
	"mode1": ["mode0", "", "fly", "chip3"],
	"pill":     ["", "help", "mode0", ""],
	"help":     ["", "settings", "mode0", "pill"],
	"settings": ["", "quit", "mode0", "help"],
	"quit":     ["", "", "mode0", "settings"],
}
const _FOCUS_ORDER: Array[String] = ["fly", "chip0", "chip1", "chip2", "chip3",
		"mode0", "mode1", "pill", "help", "settings", "quit"]


func _move_focus(dir: int) -> void:
	var next: String = String((_FOCUS_MAP.get(_focus, ["", "", "", ""]) as Array)[dir])
	if next != "":
		_set_focus(next)


func _cycle_focus(step: int) -> void:
	var i: int = _FOCUS_ORDER.find(_focus)
	_set_focus(_FOCUS_ORDER[posmod(i + step, _FOCUS_ORDER.size())])


func _set_focus(id: String, sound: bool = true) -> void:
	if not _FOCUS_MAP.has(id) or id == _focus:
		return
	_focus = id
	if sound:
		_play(SoundBank.ui_tick())


func _nudge(direction: int) -> void:
	if _picker == "":
		return
	var count: int = _picker_count(_picker)
	if count <= 0:
		return
	_set_picker_index(posmod(_picker_index() + direction, count))
	_play(SoundBank.ui_tick())


func _hit_at(point: Vector2) -> Dictionary:
	for entry in _hit:
		if (entry["rect"] as Rect2).has_point(point):
			return entry
	return {}


# Hovering highlights; clicking chooses. Moving the mouse across a list used to
# choose whatever it passed over, so the aircraft you ended up with was the
# last one the pointer crossed on its way to the button.

func _activate(entry: Dictionary) -> void:
	if entry.is_empty():
		return
	var action: String = String(entry.get("action", ""))
	match action:
		"pill", "setup": wizard_requested.emit()
		"help": help_requested.emit()
		"tuning": tuning_requested.emit(); queue_free()
		"settings": settings_requested.emit()
		"quit": get_tree().quit()
		"fly", "next": _begin_fly()
		"mode0": _begin_first_flight()
		"mode1": _begin_fly("approach")
		"chip0", "chip1", "chip2", "chip3":
			_open_picker(PICKER_KINDS[int(action.substr(4))])
		"pick":
			# Clicking a card chooses it and goes back to the hub, focus on
			# FLY: chip, card, Enter is the whole change-and-fly.
			_set_picker_index(int(entry["index"]))
			_close_picker(true)
		"pick_ok": _close_picker(true)
		"pick_cancel", "back": _close_picker(false)
		"step": _set_step(int(entry.get("index", 3)))


func _close_or_quit() -> void:
	if start_screen:
		get_tree().quit()
	else:
		queue_free()


# ------------------------------------------------------------------ pickers --

func _picker_count(kind: String) -> int:
	match kind:
		"aircraft": return _aircraft.size()
		"scene": return _scenes.size()
		"weather": return _weathers.size()
		"start": return SPAWNS.size()
	return 0


func _picker_index() -> int:
	match _picker:
		"aircraft": return _aircraft_index
		"scene": return _scene_index
		"weather": return _weather_index
		"start": return _spawn_index
	return 0


## The picker previews live: the stage, the brief and the backdrop follow the
## highlighted entry, and Esc puts the old one back.
func _set_picker_index(i: int) -> void:
	match _picker:
		"aircraft": _aircraft_index = i
		"scene": _scene_index = i
		"weather": _weather_index = i
		"start": _spawn_index = i
	_layout()


func _open_picker(kind: String) -> void:
	if _picker != "":
		_close_picker(true, false)
	if _picker_count(kind) <= 0:
		return
	_picker = kind
	_picker_before = _picker_index()
	_picker_t = 1.0 if Settings.reduced_motion() else 0.0
	_hover = {}
	_play(SoundBank.ui_confirm())
	_layout()


func _close_picker(commit: bool, sound: bool = true) -> void:
	if _picker == "":
		return
	if not commit:
		_set_picker_index(_picker_before)
	var chip: String = "chip%d" % PICKER_KINDS.find(_picker)
	_picker = ""
	_hover = {}
	# A pick sends focus to FLY, so Enter flies what was just chosen. Backing
	# out leaves it on the chip the picker came from.
	_focus = "fly" if commit else chip
	if sound:
		_play(SoundBank.ui_confirm() if commit else SoundBank.ui_back())
	_layout()


## The four-step menu's entry point, kept for the walkthrough tests: 0..2 open
## that picker, anything else closes back to the hub.
func _set_step(step: int) -> void:
	if step >= 0 and step < 3:
		_open_picker(PICKER_KINDS[step])
	else:
		_close_picker(true, false)


# --------------------------------------------------------------------- fly --

## Hands the flight over. The progress bar lives on the loading screen, where
## it measures work that is actually happening.
func _begin_fly(spawn_override: String = "") -> void:
	if _progress_active or _aircraft.is_empty():
		return
	_progress_active = true
	_play(SoundBank.ui_confirm())
	_save_loadout(spawn_override == "")
	_canvas.queue_redraw()
	_complete_fly(spawn_override)


func _begin_first_flight() -> void:
	if _progress_active:
		return
	_progress_active = true
	_play(SoundBank.ui_confirm())
	_canvas.queue_redraw()
	first_flight_requested.emit()
	# Nobody listening (an older Flight.gd): let the menu work again.
	if first_flight_requested.get_connections().is_empty():
		_progress_active = false


func _complete_fly(spawn_override: String = "") -> void:
	if _aircraft.is_empty():
		return
	var spawn: String = spawn_override if spawn_override != "" \
			else String(SPAWNS[_spawn_index][0])
	# The menu does NOT free itself here: the handler puts the loading screen
	# up and frees the menu at a moment of its choosing.
	fly_requested.emit(_aircraft[_aircraft_index]["stem"],
					   _scenes[_scene_index]["id"],
					   _weathers[_weather_index]["id"],
					   {"spawn": spawn, "mode": "free"})


func _play(stream: AudioStreamWAV) -> void:
	if _sfx == null:
		return
	_sfx.stream = stream
	_sfx.play()


# ------------------------------------------------------------------- frame --

func _process(delta: float) -> void:
	_clock += delta
	_appear = minf(_appear + delta / UITheme.APPEAR_S, 1.0)
	_picker_t = minf(_picker_t + delta / UITheme.APPEAR_S, 1.0)
	_press = maxf(_press - delta * 6.0, 0.0)
	_hover_time += delta
	if _fade >= 0.0:
		_fade = minf(_fade + delta * 3.0, 1.0)

	var size: Vector2 = _canvas.size
	if _canvas.get_meta("layout_size", Vector2.ZERO) != size:
		_canvas.set_meta("layout_size", size)
		_layout()

	# The focus ring travels to its new item (120 ms) rather than jumping.
	var target: Rect2 = _rects.get(_focus, Rect2())
	var target_r: float = 22.0 if _focus == "pill" else UITheme.R_MD
	if _ring.size == Vector2.ZERO or Settings.reduced_motion():
		_ring = target
		_ring_radius = target_r
	else:
		var k: float = 1.0 - exp(-delta * 22.0)
		_ring = Rect2(_ring.position.lerp(target.position, k), _ring.size.lerp(target.size, k))
		_ring_radius = lerpf(_ring_radius, target_r, k)

	# The aircraft picker's stage and brief follow the pointer once it has
	# rested on a card, not as it sweeps past: rebuilding an aircraft is not free.
	if _picker == "aircraft" and _stage != null and not _aircraft.is_empty():
		var shown: Dictionary = _aircraft[_preview_aircraft()]
		_stage.call("show_aircraft", String(shown["stem"]), float(shown["span"]))

	var alpha: float = UITheme.ease_out(_appear)
	_canvas.modulate.a = alpha
	_canvas.queue_redraw()
	if _overlay != null:
		_overlay.queue_redraw()


## Which aircraft the picker's brief and stage show: the one under the pointer
## once it has rested there, otherwise the highlighted one.
func _preview_aircraft() -> int:
	if _picker == "aircraft" and _hover.get("action", "") == "pick" and _hover_time > 0.18:
		return int(_hover["index"])
	return _aircraft_index


# ------------------------------------------------------------------ layout --

## Every rect for the current state, and the hit list built from them. Rebuilt
## on any state change and on resize, so what is drawn and what is clickable
## cannot disagree.
func _layout() -> void:
	if _canvas == null:
		return
	var size: Vector2 = _canvas.size
	if size.x < 10.0:
		size = Vector2(1920, 1080)
	_rects.clear()
	_hit.clear()
	for thumb in _thumbs:
		if is_instance_valid(thumb):
			thumb.queue_free()
	_thumbs.clear()
	_refresh_backdrop()

	_layout_header(size)
	_layout_hub(size)
	if _picker != "":
		# The picker owns the clicks: only its own rects are live.
		_hit.clear()
		_layout_picker(size)

	if _overlay != null:
		_canvas.move_child(_overlay, -1)
		_overlay.queue_redraw()
	_canvas.queue_redraw()


func _add(id: String, rect: Rect2, extra: Dictionary = {}) -> void:
	_rects[id] = rect
	var entry: Dictionary = {"rect": rect, "action": id}
	entry.merge(extra)
	_hit.append(entry)


func _layout_header(size: Vector2) -> void:
	var cy: float = 62.0
	var h: float = 44.0
	var x: float = size.x - G
	for id in ["quit", "settings", "help"]:
		var w: float = UITheme.label_width(_header_label(id), 2.0, UITheme.SIZE_CAPS_L) + 36.0
		x -= w
		_add(id, Rect2(x, cy - h * 0.5, w, h))
		x -= 8.0
	x -= 20.0
	var pw: float = _pill_width()
	_add("pill", Rect2(x - pw, cy - h * 0.5, pw, h))


static func _header_label(id: String) -> String:
	return {"help": "Help", "settings": "Settings", "quit": "Quit"}.get(id, id)


func _hub_geometry(size: Vector2) -> Dictionary:
	var row_y: float = size.y - FOOTER_H - ROW_H
	var col_x: float = size.x - G - COL_W
	var left_w: float = col_x - 40.0 - G
	return {"row_y": row_y, "col_x": col_x, "left_w": left_w}


func _layout_hub(size: Vector2) -> void:
	var g: Dictionary = _hub_geometry(size)
	var row_y: float = g["row_y"]
	var col_x: float = g["col_x"]
	var left_w: float = g["left_w"]

	# Loadout chips, across the bottom of the hero.
	var gap: float = 12.0
	var chip_w: float = (left_w - gap * 3.0) / 4.0
	for i in 4:
		var r := Rect2(G + float(i) * (chip_w + gap), row_y, chip_w, ROW_H)
		_add("chip%d" % i, r)
		if _picker == "" and (i == 1 or i == 2):
			var kind: String = "scene" if i == 1 else "weather"
			var id: String = String(_scenes[_scene_index]["id"]) if i == 1 \
					else String(_weathers[_weather_index]["id"])
			var thumb: TextureRect = _make_thumb(kind, id, Vector2(104, 64), 6.0)
			if thumb != null:
				thumb.position = Vector2(r.position.x + 16.0, r.position.y + 16.0)
				_canvas.add_child(thumb)
				_thumbs.append(thumb)

	# FLY, in the modes column, level with the chips.
	_add("fly", Rect2(col_x, row_y, COL_W, ROW_H))
	var mode_h: float = 92.0
	var y: float = row_y - 24.0 - mode_h
	_add("mode1", Rect2(col_x, y, COL_W, mode_h))
	y -= 12.0 + mode_h
	_add("mode0", Rect2(col_x, y, COL_W, mode_h))
	_rects["modes_top"] = y

	# The hero: everything above the name.
	var name_top: float = row_y - 150.0
	# Capped, so the aircraft reads as an object on a stand, not a wall of wing.
	var stage_w: float = minf(left_w, 1180.0)
	var stage := Rect2(G + (left_w - stage_w) * 0.5, HEADER_H + 8.0, stage_w,
			name_top - HEADER_H - 8.0)
	_rects["hero"] = stage
	if _picker == "":
		_place_stage(stage)


## The picker sheet: full height for the aircraft (list, stage and brief), sized
## to its content for the others, so no picker is a card with an empty half.
func _sheet_rect(size: Vector2) -> Rect2:
	var full := Rect2(G, HEADER_H + 8.0, size.x - G * 2.0, size.y - HEADER_H - 8.0 - FOOTER_H)
	var body: float = full.size.y
	match _picker:
		"start":
			body = 340.0
		"scene", "weather":
			var w: float = (full.size.x - 80.0 - 64.0) / 5.0
			body = w * 9.0 / 16.0 + (80.0 if _picker == "weather" else 56.0) + 24.0 \
					+ (210.0 if _picker == "weather" else 150.0)
		_:
			return full
	return Rect2(full.position, Vector2(full.size.x, minf(full.size.y, body + 236.0)))


func _picker_content(sheet: Rect2) -> Rect2:
	return Rect2(sheet.position.x + 40.0, sheet.position.y + 132.0,
			sheet.size.x - 80.0, sheet.size.y - 132.0 - 104.0)


func _layout_picker(size: Vector2) -> void:
	var sheet: Rect2 = _sheet_rect(size)
	_rects["sheet"] = sheet
	var content: Rect2 = _picker_content(sheet)
	_add("pick_ok", Rect2(sheet.end.x - 40.0 - 260.0, sheet.end.y - 40.0 - 56.0, 260.0, 56.0))
	_add("pick_cancel", Rect2(sheet.end.x - 40.0 - 260.0 - 12.0 - 170.0,
			sheet.end.y - 40.0 - 56.0, 170.0, 56.0))
	match _picker:
		"aircraft":
			for i in _aircraft.size():
				_add_pick(i, _aircraft_card_rect(content, i))
			_place_stage(_aircraft_stage_rect(content))
		"scene", "weather":
			var entries: Array = _scenes if _picker == "scene" else _weathers
			for i in entries.size():
				var r: Rect2 = _picture_rect(content, i, entries.size())
				_add_pick(i, r)
				var thumb: TextureRect = _make_thumb(_picker, String(entries[i]["id"]),
						r.size - Vector2(8.0, 8.0), 8.0)
				if thumb != null:
					thumb.position = r.position + Vector2(4.0, 4.0)
					thumb.modulate = _picture_tint(i == _picker_index(), _is_hover_pick(i))
					_canvas.add_child(thumb)
					_thumbs.append(thumb)
			_hide_stage()
		"start":
			for i in SPAWNS.size():
				_add_pick(i, _start_card_rect(content, i))
			_hide_stage()


func _add_pick(i: int, rect: Rect2) -> void:
	_hit.append({"rect": rect, "action": "pick", "index": i})
	_rects["pick%d" % i] = rect


const AIRCRAFT_LIST_W: float = 470.0
const AIRCRAFT_BRIEF_W: float = 500.0


func _aircraft_card_rect(content: Rect2, index: int) -> Rect2:
	var count: int = maxi(_aircraft.size(), 1)
	var gap: float = 12.0
	var card_h: float = minf(108.0, (content.size.y - gap * float(count - 1)) / float(count))
	return Rect2(content.position.x, content.position.y + float(index) * (card_h + gap),
			AIRCRAFT_LIST_W, card_h)


func _aircraft_stage_rect(content: Rect2) -> Rect2:
	var x: float = content.position.x + AIRCRAFT_LIST_W + 24.0
	var w: float = content.size.x - AIRCRAFT_LIST_W - AIRCRAFT_BRIEF_W - 48.0
	return Rect2(x, content.position.y, maxf(w, 200.0), content.size.y - 96.0)


func _picture_rect(content: Rect2, index: int, count: int) -> Rect2:
	var gap: float = 16.0
	var w: float = (content.size.x - gap * float(count - 1)) / float(count)
	return Rect2(content.position.x + float(index) * (w + gap), content.position.y,
			w, w * 9.0 / 16.0)


func _start_card_rect(content: Rect2, index: int) -> Rect2:
	var gap: float = 16.0
	var w: float = (content.size.x - gap * 2.0) / 3.0
	return Rect2(content.position.x + float(index) * (w + gap), content.position.y,
			w, minf(content.size.y, 380.0))


func _is_hover_pick(i: int) -> bool:
	return _hover.get("action", "") == "pick" and int(_hover.get("index", -1)) == i


## How bright a picture card is: chosen, under the pointer, or neither.
func _picture_tint(selected: bool, hovered: bool) -> Color:
	if selected:
		return Color(1.0, 1.0, 1.0)
	if hovered:
		return Color(0.88, 0.91, 0.95)
	return Color(0.58, 0.62, 0.68)


func _place_stage(rect: Rect2) -> void:
	if _stage == null or _aircraft.is_empty():
		return
	if _stage_view == null:
		_stage_view = TextureRect.new()
		_stage_view.name = "StageView"
		_stage_view.texture = _stage.call("texture")
		_stage_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_stage_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_stage_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_canvas.add_child(_stage_view)
	_stage_rect = rect
	_stage_view.visible = true
	_stage_view.position = rect.position
	_stage_view.size = rect.size
	_stage.call("set_stage_size", Vector2i(int(rect.size.x), int(rect.size.y)))
	var chosen: Dictionary = _aircraft[_aircraft_index]
	_stage.call("show_aircraft", String(chosen["stem"]), float(chosen["span"]))


func _hide_stage() -> void:
	if _stage_view != null:
		_stage_view.visible = false


## The backdrop follows the chosen place, dimmed hard enough that the type
## keeps the screen.
func _refresh_backdrop() -> void:
	if _backdrop == null or _scenes.is_empty():
		return
	var id: String = String(_scenes[_scene_index]["id"])
	if id == _backdrop_id:
		return
	_backdrop_id = id
	var path: String = "res://assets/previews/scene_%s.png" % id
	if ResourceLoader.exists(path):
		_backdrop_tex = load(path) as Texture2D
		_backdrop.texture = _backdrop_tex
	_backdrop.modulate = Color(0.70, 0.74, 0.80)


## A rounded preview, cut once per size and kept: cutting the corners is a
## per-pixel loop, and the hub asks for the same two every time it lays out.
func _make_thumb(kind: String, id: String, size: Vector2, radius: float) -> TextureRect:
	var key: String = "%s:%s:%dx%d" % [kind, id, int(size.x), int(size.y)]
	if not _thumb_cache.has(key):
		var texture: Texture2D = null
		for path in ["res://assets/previews/%s_%s.png" % [kind, id],
					 "res://shots/%s_%s.png" % [kind, id]]:
			if ResourceLoader.exists(path):
				texture = load(path) as Texture2D
				break
		if texture == null:
			_thumb_cache[key] = null
		else:
			_thumb_cache[key] = UITheme.make_thumb(texture, size, radius).texture
	var cut: Texture2D = _thumb_cache[key]
	if cut == null:
		return null
	var rect := TextureRect.new()
	rect.texture = cut
	rect.size = size
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


# ----------------------------------------------------------------- drawing --

func _draw_menu() -> void:
	var size: Vector2 = _canvas.size
	# A quiet gradient top and bottom: the header and the loadout sit on it
	# rather than fighting the picture.
	UITheme.draw_scrim(_canvas, Rect2(0, 0, size.x, 200.0), 0.62, 0.0)
	UITheme.draw_scrim(_canvas, Rect2(0, size.y - 470.0, size.x, 470.0), 0.0, 0.80)

	_draw_header(size)
	_draw_hub(size)
	if _picker != "":
		_draw_picker(size)
	_draw_footer(size)

	if _fade > 0.0:
		_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, _fade * 0.85), true)


func _hovered(id: String) -> bool:
	return _picker == "" and _hover.get("action", "") == id


func _pressed(id: String) -> bool:
	return _press > 0.05 and _press_action == id


# ---- header ------------------------------------------------------------------

func _draw_header(size: Vector2) -> void:
	if _lockup == null and ResourceLoader.exists(LOCKUP_PATH):
		_lockup = load(LOCKUP_PATH) as Texture2D
	if _lockup != null:
		var h: float = 72.0
		var w: float = h * float(_lockup.get_width()) / float(_lockup.get_height())
		_canvas.draw_texture_rect(_lockup, Rect2(Vector2(G - 6.0, 26.0), Vector2(w, h)), false)
	else:
		UITheme.draw_display(_canvas, Vector2(G, 84.0), "OPENRC", UITheme.SIZE_H1, UITheme.TEXT)

	_draw_pill(_rects.get("pill", Rect2()))
	for id in ["help", "settings", "quit"]:
		_draw_tertiary(_rects.get(id, Rect2()), _header_label(id), _hovered(id),
				_focus == id and _picker == "")


## What will fly the aircraft, in words, with a live dot - and the way into
## setting it up. The whole pill is the button.
func _input_state() -> Dictionary:
	var mode: int = int(Settings.get_value("controls/stick_mode"))
	var connected: bool = _input != null and _input.is_connected()
	var ready: bool = connected and _input.is_fully_bound()
	if ready:
		var name: String = _input.get_device_name()
		if name.length() > 26:
			name = name.substr(0, 25).strip_edges() + "…"
		return {"colour": UITheme.GOOD, "text": "Transmitter · %s · Mode %d" % [name, mode],
				"action": ""}
	if connected:
		return {"colour": UITheme.WARN, "text": "Transmitter found, not set up",
				"action": "Set up"}
	return {"colour": UITheme.TEXT_FAINT, "text": "Keyboard · Mode %d" % mode, "action": ""}


func _pill_width() -> float:
	var s: Dictionary = _input_state()
	var w: float = 20.0 + 18.0 + _semibold_width(String(s["text"]), UITheme.SIZE_BODY_S + 1)
	if String(s["action"]) != "":
		w += 16.0 + _semibold_width(String(s["action"]), UITheme.SIZE_BODY_S + 1)
	return w + 40.0


func _draw_pill(rect: Rect2) -> void:
	if rect.size.x <= 0.0:
		return
	var s: Dictionary = _input_state()
	var colour: Color = s["colour"]
	var hover: bool = _hovered("pill")
	var radius: float = rect.size.y * 0.5
	var fill := Color(UITheme.SURFACE_2.r, UITheme.SURFACE_2.g, UITheme.SURFACE_2.b,
			0.92 if hover else 0.72)
	_canvas.draw_colored_polygon(UITheme.rounded_rect(rect, radius, 8), fill)
	var edge: PackedVector2Array = UITheme.rounded_rect(rect, radius, 8)
	edge.append(edge[0])
	var stroke: Color = UITheme.STROKE_HOVER if hover else Color(colour.r, colour.g, colour.b, 0.45)
	_canvas.draw_polyline(edge, stroke, UITheme.HAIRLINE, true)

	var cy: float = rect.get_center().y
	var dot := Vector2(rect.position.x + 22.0, cy)
	if colour == UITheme.GOOD:
		_canvas.draw_circle(dot, 9.0, Color(colour.r, colour.g, colour.b, 0.20))
	_canvas.draw_circle(dot, 5.0, colour)
	var x: float = rect.position.x + 38.0
	var size: int = UITheme.SIZE_BODY_S + 1
	UITheme.draw_text(_canvas, Vector2(x, cy + 7.0), String(s["text"]), size,
			UITheme.TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UITheme.font_semibold())
	x += _semibold_width(String(s["text"]), size) + 16.0
	if String(s["action"]) != "":
		UITheme.draw_text(_canvas, Vector2(x, cy + 7.0), String(s["action"]), size,
				UITheme.WARN, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UITheme.font_semibold())
	UITheme.draw_chevron(_canvas, Vector2(rect.end.x - 20.0, cy), 1, 12.0,
			UITheme.TEXT if hover else UITheme.TEXT_DIM)


static func _semibold_width(text: String, size: int) -> float:
	return UITheme.font_semibold().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## Header text button: caps 20, dim, white with a short accent underline on
## hover.
func _draw_tertiary(rect: Rect2, text: String, hover: bool, focus: bool) -> void:
	if rect.size.x <= 0.0:
		return
	if hover:
		_canvas.draw_colored_polygon(UITheme.rounded_rect(rect, UITheme.R_MD), Color(1, 1, 1, 0.05))
	var colour: Color = UITheme.TEXT if (hover or focus) else UITheme.TEXT_DIM
	UITheme.draw_label(_canvas, Vector2(rect.position.x, rect.get_center().y + 7.0), text,
			colour, 2.0, UITheme.SIZE_CAPS_L, false, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x)
	if hover:
		var cx: float = rect.get_center().x
		_canvas.draw_rect(Rect2(cx - 12.0, rect.get_center().y + 13.0, 24.0, 2.0), UITheme.ACCENT)


# ---- hub ---------------------------------------------------------------------

func _draw_hub(size: Vector2) -> void:
	if _aircraft.is_empty():
		return
	var g: Dictionary = _hub_geometry(size)
	var row_y: float = g["row_y"]
	var card: Dictionary = _aircraft[_aircraft_index]

	# The name is the only large thing on the screen. Under it, a few words.
	var name_base: float = row_y - 78.0
	UITheme.draw_display(_canvas, Vector2(G - 2.0, name_base), String(card["name"]),
			UITheme.SIZE_DISPLAY, UITheme.TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
	var tx: float = G
	var ty: float = row_y - 40.0
	if String(card["stem"]) == RECOMMENDED_STEM:
		tx += UITheme.draw_tag(_canvas, Vector2(tx, ty), "Recommended for first flights", "info") + 10.0
	for tag in (card.get("tags", []) as Array).slice(0, 3):
		tx += UITheme.draw_tag(_canvas, Vector2(tx, ty), String(tag[0]), String(tag[1])) + 10.0

	for i in 4:
		_draw_chip(i)
	_draw_modes(size)
	_draw_fly(_rects.get("fly", Rect2()))

	# Focus ring, drawn once and travelling between items.
	if _picker == "" and _ring.size.x > 0.0:
		UITheme.draw_focus_ring(_canvas, _ring, _ring_radius)


func _chip_value(i: int) -> String:
	match i:
		0: return String(_aircraft[_aircraft_index]["name"])
		1: return String(_scenes[_scene_index]["name"])
		2:
			var w: Dictionary = _weathers[_weather_index]
			return "%s · %s" % [w["name"], _wind_text(float(w["wind_mps"]))]
		3: return String(SPAWNS[_spawn_index][1])
	return ""


func _wind_text(mps: float) -> String:
	return "%.0f m/s" % mps


func _draw_chip(i: int) -> void:
	var id: String = "chip%d" % i
	var rect: Rect2 = _rects.get(id, Rect2())
	if rect.size.x <= 0.0:
		return
	var hover: bool = _hovered(id)
	var r: Rect2 = rect
	if _pressed(id):
		r.position.y += 2.0
	var fill := Color(UITheme.BASE.r, UITheme.BASE.g, UITheme.BASE.b, 0.72)
	if hover:
		fill = Color(UITheme.SURFACE_2.r, UITheme.SURFACE_2.g, UITheme.SURFACE_2.b, 0.94)
	_canvas.draw_colored_polygon(UITheme.rounded_rect(r, UITheme.R_MD), fill)
	_canvas.draw_line(Vector2(r.position.x + UITheme.R_MD, r.position.y + 1.0),
			Vector2(r.end.x - UITheme.R_MD, r.position.y + 1.0), UITheme.GLASS_SHEEN, 1.0)
	var edge: PackedVector2Array = UITheme.rounded_rect(r, UITheme.R_MD)
	edge.append(edge[0])
	_canvas.draw_polyline(edge, UITheme.STROKE_HOVER if hover else UITheme.STROKE_STRONG,
			UITheme.HAIRLINE, true)

	var x: float = r.position.x + 20.0
	if i == 1 or i == 2:
		x = r.position.x + 16.0 + 104.0 + 16.0
	elif i == 3:
		_draw_spawn_icon(Rect2(r.position.x + 16.0, r.position.y + 16.0, 64.0, 64.0),
				String(SPAWNS[_spawn_index][0]), UITheme.TEXT_DIM)
		x = r.position.x + 16.0 + 64.0 + 16.0
	var text_w: float = r.end.x - 40.0 - x
	UITheme.draw_label(_canvas, Vector2(x, r.position.y + 38.0), CHIP_NAMES[i],
			UITheme.TEXT_DIM, 2.0, UITheme.SIZE_CAPS)
	var value: String = _clip_semibold(_chip_value(i), text_w, 24)
	UITheme.draw_text(_canvas, Vector2(x, r.position.y + 72.0), value, 24,
			UITheme.TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UITheme.font_semibold())
	UITheme.draw_chevron(_canvas, Vector2(r.end.x - 22.0, r.get_center().y), 1, 14.0,
			UITheme.TEXT if hover or _focus == id else UITheme.TEXT_FAINT)


func _clip_semibold(text: String, width: float, size: int) -> String:
	if _semibold_width(text, size) <= width:
		return text
	var out: String = text
	while out.length() > 1 and _semibold_width(out + "…", size) > width:
		out = out.substr(0, out.length() - 1).strip_edges()
	return out + "…"


func _draw_modes(size: Vector2) -> void:
	var g: Dictionary = _hub_geometry(size)
	var col_x: float = g["col_x"]
	var top: float = float(_rects.get("modes_top", 0.0))
	UITheme.draw_label(_canvas, Vector2(col_x + 2.0, top - 18.0), "Ways to fly",
			UITheme.HUD_LABEL, 2.0, UITheme.SIZE_CAPS, true)

	var done: bool = bool(Settings.get_value("onboarding/first_flight_done"))
	_draw_mode_row("mode0", "First flight", "Guided, about 3 minutes. Take off, turn, land.",
			"done" if done else "new")
	_draw_mode_row("mode1", "Practice landings",
			"Start on approach to %s." % String(_scenes[_scene_index]["name"]), "")


func _draw_mode_row(id: String, title: String, sub: String, badge: String) -> void:
	var rect: Rect2 = _rects.get(id, Rect2())
	if rect.size.x <= 0.0:
		return
	var hover: bool = _hovered(id)
	var r: Rect2 = rect
	if _pressed(id):
		r.position.y += 2.0
	var fill := Color(UITheme.BASE.r, UITheme.BASE.g, UITheme.BASE.b, 0.72)
	if hover:
		fill = Color(UITheme.SURFACE_2.r, UITheme.SURFACE_2.g, UITheme.SURFACE_2.b, 0.94)
	_canvas.draw_colored_polygon(UITheme.rounded_rect(r, UITheme.R_MD), fill)
	var edge: PackedVector2Array = UITheme.rounded_rect(r, UITheme.R_MD)
	edge.append(edge[0])
	_canvas.draw_polyline(edge, UITheme.STROKE_HOVER if hover else UITheme.STROKE_STRONG,
			UITheme.HAIRLINE, true)

	var x: float = r.position.x + 22.0
	UITheme.draw_display(_canvas, Vector2(x, r.position.y + 40.0), title, 28, UITheme.TEXT)
	UITheme.draw_text(_canvas, Vector2(x, r.position.y + 70.0),
			_clip_semibold(sub, r.size.x - 64.0, UITheme.SIZE_BODY_S), UITheme.SIZE_BODY_S,
			UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UITheme.font_semibold())

	var title_w: float = UITheme.font_condensed_bold().get_string_size(title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 28).x
	var bx: float = x + title_w + 14.0
	var by: float = r.position.y + 31.0
	if badge == "done":
		# A vector check: Rajdhani has no check glyph.
		UITheme.draw_check(_canvas, Vector2(bx + 8.0, by), 13.0, UITheme.GOOD)
		UITheme.draw_label(_canvas, Vector2(bx + 22.0, by + 6.0), "Done", UITheme.GOOD,
				2.0, UITheme.SIZE_CAPS)
	elif badge == "new":
		UITheme.draw_tag(_canvas, Vector2(bx, by), "Start here", "info")
	UITheme.draw_chevron(_canvas, Vector2(r.end.x - 22.0, r.get_center().y), 1, 14.0,
			UITheme.TEXT if hover or _focus == id else UITheme.TEXT_FAINT)


## FLY: the one primary on the screen. Solid accent, dark ink, the Enter key
## printed on it, and the glow when it has focus - which it does on open.
func _draw_fly(rect: Rect2) -> void:
	if rect.size.x <= 0.0:
		return
	var hover: bool = _hovered("fly")
	var r: Rect2 = rect
	if _pressed("fly"):
		r.position.y += 2.0
	if _focus == "fly" and _picker == "":
		UITheme.draw_glow(_canvas, r, UITheme.ACCENT, UITheme.R_MD, 3)
	var fill: Color = UITheme.ACCENT_HI if hover else UITheme.ACCENT
	if _pressed("fly"):
		fill = fill.darkened(0.08)
	_canvas.draw_colored_polygon(UITheme.rounded_rect(r, UITheme.R_MD), fill)

	var ink: Color = UITheme.ACCENT_INK
	UITheme.draw_label(_canvas, Vector2(r.position.x + 30.0, r.position.y + 34.0),
			"Free flight", Color(ink.r, ink.g, ink.b, 0.66), 2.0, UITheme.SIZE_CAPS)
	UITheme.draw_display(_canvas, Vector2(r.position.x + 28.0, r.position.y + 78.0), "FLY",
			46, ink)
	var cy: float = r.get_center().y
	if _progress_active:
		UITheme.draw_spinner(_canvas, Vector2(r.end.x - 44.0, cy), 14.0, _clock, ink)
	else:
		UITheme.draw_arrow_glyph(_canvas, Vector2(r.end.x - 42.0, cy), 1, 26.0, ink, 3.0)
		var kw: float = UITheme.keycap_width("ENTER", UITheme.SIZE_KEY)
		_draw_ink_keycap(Vector2(r.end.x - 78.0 - kw, cy - 13.0), "Enter")


## A keycap printed on the accent fill: dark outline, dark legend.
func _draw_ink_keycap(pos: Vector2, text: String) -> void:
	var size: int = UITheme.SIZE_KEY
	var h: float = 26.0
	var tw: float = UITheme.font_label().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var rect := Rect2(pos.round(), Vector2(roundf(tw + 18.0), h))
	var ink: Color = UITheme.ACCENT_INK
	_canvas.draw_colored_polygon(UITheme.rounded_rect(rect, UITheme.R_SM), Color(ink.r, ink.g, ink.b, 0.10))
	var edge: PackedVector2Array = UITheme.rounded_rect(rect, UITheme.R_SM)
	edge.append(edge[0])
	_canvas.draw_polyline(edge, Color(ink.r, ink.g, ink.b, 0.55), 1.5, true)
	_canvas.draw_string(UITheme.font_label(), Vector2(rect.position.x + 9.0,
			roundf(rect.position.y + h * 0.5 + size * 0.36)), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)


## A small side view of where the aircraft starts: the strip, and the aircraft
## on it, above it, or coming down to it.
func _draw_spawn_icon(rect: Rect2, spawn: String, colour: Color) -> void:
	var w: float = rect.size.x
	var h: float = rect.size.y
	var ground_y: float = rect.position.y + h * 0.80
	var strip_x0: float = rect.position.x + w * 0.42
	var strip_x1: float = rect.end.x
	_canvas.draw_line(Vector2(rect.position.x, ground_y), Vector2(rect.end.x, ground_y),
			Color(colour.r, colour.g, colour.b, 0.45), 2.0)
	_canvas.draw_line(Vector2(strip_x0, ground_y), Vector2(strip_x1, ground_y),
			UITheme.ACCENT, 4.0)
	var plane := Vector2.ZERO
	var heading := Vector2(1, 0)
	match spawn:
		"runway":
			plane = Vector2(strip_x0 + w * 0.10, ground_y - 6.0)
		"air":
			plane = Vector2(rect.position.x + w * 0.55, rect.position.y + h * 0.22)
			var dash_y: float = plane.y + 0.0
			for k in 4:
				var x0: float = rect.position.x + float(k) * w * 0.11
				_canvas.draw_line(Vector2(x0, dash_y), Vector2(x0 + w * 0.06, dash_y),
						Color(colour.r, colour.g, colour.b, 0.6), 2.0)
		"approach":
			var start := Vector2(rect.position.x + w * 0.04, rect.position.y + h * 0.18)
			var touch := Vector2(strip_x0 + w * 0.06, ground_y - 2.0)
			for k in 5:
				var a: Vector2 = start.lerp(touch, float(k) / 5.0)
				var b: Vector2 = start.lerp(touch, (float(k) + 0.55) / 5.0)
				_canvas.draw_line(a, b, Color(colour.r, colour.g, colour.b, 0.6), 2.0)
			plane = start.lerp(touch, 0.38)
			heading = (touch - start).normalized()
	_draw_plane_glyph(plane, heading, clampf(w * 0.30, 18.0, 84.0), UITheme.TEXT)


## A tiny side-on aircraft silhouette: fuselage with a fin, and the wing.
func _draw_plane_glyph(centre: Vector2, heading: Vector2, length: float, colour: Color) -> void:
	var f: Vector2 = heading.normalized()
	var up := Vector2(f.y, -f.x)
	if up.y > 0.0:
		up = -up
	# Local outline, x forward and y up, in units of the length.
	var outline: Array = [
		Vector2(0.50, 0.00), Vector2(0.42, 0.07), Vector2(0.18, 0.10), Vector2(-0.30, 0.05),
		Vector2(-0.42, 0.30), Vector2(-0.52, 0.30), Vector2(-0.50, -0.02), Vector2(-0.30, -0.04),
		Vector2(0.40, -0.07)]
	var pts := PackedVector2Array()
	for v in outline:
		pts.append(centre + f * (v.x * length) + up * (v.y * length))
	_canvas.draw_colored_polygon(pts, colour)
	# The wing, seen edge-on: a dark-edged bar across the fuselage.
	var w0: Vector2 = centre + f * (0.20 * length) + up * (0.06 * length)
	var w1: Vector2 = centre - f * (0.08 * length) + up * (0.06 * length)
	_canvas.draw_line(w0, w1, colour.darkened(0.45), maxf(length * 0.06, 1.5), true)


# ---- picker ------------------------------------------------------------------

func _draw_picker(size: Vector2) -> void:
	var t: float = UITheme.ease_out(_picker_t)
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(UITheme.BASE.r, UITheme.BASE.g,
			UITheme.BASE.b, 0.62 * t), true)
	var sheet: Rect2 = _rects.get("sheet", _sheet_rect(size))
	var shift: float = 0.0 if Settings.reduced_motion() else (1.0 - t) * 12.0
	var s := Rect2(sheet.position + Vector2(0, shift), sheet.size)
	UITheme.draw_modal(_canvas, s, t, Color(UITheme.SURFACE.r, UITheme.SURFACE.g,
			UITheme.SURFACE.b, 1.0))

	var titles: Dictionary = {
		"aircraft": ["Aircraft", "%d aircraft, easiest first. Click one, or use the arrow keys and Enter." % _aircraft.size()],
		"scene": ["Location", "Each place has its own ground, light and air."],
		"weather": ["Weather", "Weather changes the air and the ground, not just the picture."],
		"start": ["Start", "Where the aircraft is when the flight begins."],
	}
	var entry: Array = titles.get(_picker, ["", ""])
	UITheme.draw_label(_canvas, s.position + Vector2(40.0, 48.0), "Choose", UITheme.TEXT_DIM,
			2.0, UITheme.SIZE_CAPS)
	UITheme.draw_display(_canvas, s.position + Vector2(40.0, 90.0), String(entry[0]),
			UITheme.SIZE_H2 + 4, UITheme.TEXT)
	UITheme.draw_text(_canvas, s.position + Vector2(44.0 + UITheme.font_condensed_bold()
			.get_string_size(String(entry[0]), HORIZONTAL_ALIGNMENT_LEFT, -1,
			UITheme.SIZE_H2 + 4).x + 20.0, 89.0), String(entry[1]), UITheme.SIZE_BODY,
			UITheme.TEXT_DIM)

	match _picker:
		"aircraft": _draw_aircraft_picker(s)
		"scene": _draw_picture_picker(s, _scenes, "scene")
		"weather": _draw_picture_picker(s, _weathers, "weather")
		"start": _draw_start_picker(s)

	var ok: Rect2 = _rects.get("pick_ok", Rect2())
	var cancel: Rect2 = _rects.get("pick_cancel", Rect2())
	ok.position.y += shift
	cancel.position.y += shift
	UITheme.draw_button_ex(_canvas, cancel, "Cancel", UITheme.TERTIARY,
			{"hover": _hover.get("action", "") == "pick_cancel", "key": "Esc"})
	UITheme.draw_button_ex(_canvas, ok, "Use this", UITheme.PRIMARY,
			{"hover": _hover.get("action", "") == "pick_ok", "key": "Enter", "focus": true})


func _draw_aircraft_picker(sheet: Rect2) -> void:
	var content: Rect2 = _picker_content(sheet)
	for i in _aircraft.size():
		_draw_aircraft_card(_aircraft_card_rect(content, i), i)

	var shown: int = _preview_aircraft()
	var card: Dictionary = _aircraft[shown]
	var stage: Rect2 = _aircraft_stage_rect(content)
	# Under the turntable: the name, and in what way it is the one to pick.
	UITheme.draw_display(_canvas, Vector2(stage.position.x, stage.end.y + 54.0),
			String(card["name"]), UITheme.SIZE_H1, UITheme.TEXT,
			HORIZONTAL_ALIGNMENT_CENTER, stage.size.x)
	if String(card["stem"]) == RECOMMENDED_STEM:
		var tw: float = UITheme.label_width("Recommended for first flights") + 24.0
		UITheme.draw_tag(_canvas, Vector2(stage.get_center().x - tw * 0.5, stage.end.y + 84.0),
				"Recommended for first flights", "info")
	_draw_brief(Rect2(content.end.x - AIRCRAFT_BRIEF_W, content.position.y,
			AIRCRAFT_BRIEF_W, content.size.y), card)


func _draw_aircraft_card(r: Rect2, i: int) -> void:
	var card: Dictionary = _aircraft[i]
	var selected: bool = i == _aircraft_index
	var hover: bool = _is_hover_pick(i)
	var fill := Color(UITheme.SURFACE.r, UITheme.SURFACE.g, UITheme.SURFACE.b, 0.80)
	if selected:
		fill = UITheme.SURFACE_2
	elif hover:
		fill = UITheme.SURFACE_2.lerp(UITheme.SURFACE, 0.4)
	_canvas.draw_colored_polygon(UITheme.rounded_rect(r, UITheme.R_MD), fill)
	var edge: PackedVector2Array = UITheme.rounded_rect(r, UITheme.R_MD)
	edge.append(edge[0])
	if selected:
		_canvas.draw_polyline(edge, Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, 0.7),
				UITheme.STROKE_UI, true)
		_canvas.draw_rect(Rect2(r.position.x + 1.0, r.position.y + 12.0, 4.0, r.size.y - 24.0),
				UITheme.ACCENT)
	else:
		_canvas.draw_polyline(edge, UITheme.STROKE_HOVER if hover else UITheme.STROKE,
				UITheme.HAIRLINE, true)

	var x: float = r.position.x + 24.0
	UITheme.draw_display(_canvas, Vector2(x, r.position.y + 42.0), String(card["name"]), 30,
			UITheme.TEXT if selected or hover else UITheme.TEXT_DIM)
	# Plain words first; the numbers are in the brief.
	var tx: float = x - 2.0
	var tags: Array = []
	if String(card["stem"]) == RECOMMENDED_STEM:
		tags.append(["Recommended", "info"])
	tags.append_array((card.get("tags", []) as Array).slice(0, 3))
	for tag in tags:
		var w: float = UITheme.label_width(String(tag[0])) + (24.0 if String(tag[1]) == "info" else 34.0)
		if tx + w > r.end.x - 16.0:
			break
		tx += UITheme.draw_tag(_canvas, Vector2(tx, r.position.y + r.size.y - 30.0),
				String(tag[0]), String(tag[1])) + 8.0

	# Difficulty: a 4-segment meter in the level colour.
	var band: float = float(card.get("difficulty", 0.5))
	var lit: int = 1 if band < 0.50 else (2 if band < 0.62 else (3 if band < 0.72 else 4))
	var colour: Color = _difficulty_colour(band)
	for k in 4:
		var seg := Rect2(r.end.x - 24.0 - float(4 - k) * 21.0, r.position.y + 30.0, 18.0, 4.0)
		_canvas.draw_rect(seg, colour if k < lit else Color(1, 1, 1, 0.12))


## The brief: how it flies in words first, then what was measured.
func _draw_brief(panel: Rect2, card: Dictionary) -> void:
	_canvas.draw_colored_polygon(UITheme.rounded_rect(panel, UITheme.R_LG),
			Color(UITheme.BASE.r, UITheme.BASE.g, UITheme.BASE.b, 0.45))
	var edge: PackedVector2Array = UITheme.rounded_rect(panel, UITheme.R_LG)
	edge.append(edge[0])
	_canvas.draw_polyline(edge, UITheme.STROKE, UITheme.HAIRLINE, true)

	var x: float = panel.position.x + 28.0
	var w: float = panel.size.x - 56.0
	var y: float = panel.position.y + 40.0
	var band: float = float(card.get("difficulty", 0.5))
	UITheme.draw_label(_canvas, Vector2(x, y), "To fly", UITheme.TEXT_DIM, 2.0, UITheme.SIZE_CAPS)
	y += 36.0
	UITheme.draw_display(_canvas, Vector2(x, y), Ranking.word(band).capitalize(),
			UITheme.SIZE_NUM_M + 2, _difficulty_colour(band))
	y += 34.0
	for line in UITheme.wrap_text(String(card["description"]), w, UITheme.SIZE_BODY_S + 1):
		UITheme.draw_text(_canvas, Vector2(x, y), line, UITheme.SIZE_BODY_S + 1, UITheme.TEXT_DIM)
		y += 26.0
	if bool(card.get("hand_launched", false)):
		y += 4.0
		UITheme.draw_text(_canvas, Vector2(x, y), "Thrown, not rolled: it has no wheels.",
				UITheme.SIZE_BODY_S + 1, UITheme.WARN)
		y += 26.0
	y += 18.0

	var perf: Dictionary = card.get("performance", {})
	var rows: Array = []
	for row in BRIEF_MEASURED:
		if perf.has(row[1]):
			rows.append([row[0], row[2] % float(perf[row[1]]),
					_roster_fraction(row[1], float(perf[row[1]]))])
	for row in [["wing loading", "%.0f N/m2" % card["loading"], "loading"],
				["power / weight", "%.0f W/kg" % card["pw"], "pw"],
				["approach speed", "%.1f m/s" % card["approach"], "approach"]]:
		rows.append([row[0], row[1], _roster_fraction(row[2], float(card[row[2]]))])

	UITheme.draw_label(_canvas, Vector2(x, y), "Measured", UITheme.TEXT_DIM, 2.0, UITheme.SIZE_CAPS)
	UITheme.draw_rule(_canvas, Vector2(x, y + 12.0), w)
	y += 40.0
	var pitch: float = minf(30.0, (panel.end.y - 20.0 - y) / float(maxi(rows.size(), 1)))
	for row in rows:
		UITheme.draw_text(_canvas, Vector2(x, y), String(row[0]), UITheme.SIZE_BODY_S,
				UITheme.TEXT_FAINT)
		UITheme.draw_text(_canvas, Vector2(x + 150.0, y), String(row[1]), UITheme.SIZE_BODY_S + 1,
				UITheme.TEXT, HORIZONTAL_ALIGNMENT_RIGHT, 140.0, false, UITheme.font_semibold())
		var track := Rect2(x + 316.0, y - 8.0, w - 316.0, 4.0)
		UITheme.draw_track(_canvas, track, float(row[2]))
		y += pitch


## Where `value` sits between the smallest and largest the roster has for the
## same figure, 0..1.
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


func _draw_picture_picker(sheet: Rect2, entries: Array, kind: String) -> void:
	var content: Rect2 = _picker_content(sheet)
	var chosen: int = _picker_index()
	var bottom: float = 0.0
	for i in entries.size():
		var r: Rect2 = _picture_rect(content, i, entries.size())
		var selected: bool = i == chosen
		var hover: bool = _is_hover_pick(i)
		_canvas.draw_colored_polygon(UITheme.rounded_rect(r, UITheme.R_MD),
				UITheme.SURFACE_2 if selected else Color(0, 0, 0, 0.35))
		var name_y: float = r.end.y + 38.0
		UITheme.draw_display(_canvas, Vector2(r.position.x + 4.0, name_y),
				String(entries[i]["name"]), 28,
				UITheme.TEXT if selected or hover else UITheme.TEXT_DIM)
		if kind == "weather":
			UITheme.draw_text(_canvas, Vector2(r.position.x + 4.0, name_y + 28.0),
					"%s wind" % _wind_text(float(entries[i]["wind_mps"])), UITheme.SIZE_BODY_S,
					UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UITheme.font_semibold())
		bottom = name_y + (40.0 if kind == "weather" else 14.0)

	# The highlighted entry, written out: what the picture cannot say.
	var e: Dictionary = entries[chosen if not _is_hover_any() else int(_hover["index"])]
	var panel := Rect2(content.position.x, bottom + 24.0, content.size.x,
			content.end.y - bottom - 24.0)
	if panel.size.y < 80.0:
		return
	_canvas.draw_colored_polygon(UITheme.rounded_rect(panel, UITheme.R_LG),
			Color(UITheme.BASE.r, UITheme.BASE.g, UITheme.BASE.b, 0.45))
	var x: float = panel.position.x + 32.0
	var y: float = panel.position.y + 52.0
	UITheme.draw_display(_canvas, Vector2(x, y), String(e["name"]), UITheme.SIZE_H2, UITheme.TEXT)
	y += 36.0
	for line in UITheme.wrap_text(String(e["description"]), panel.size.x * 0.50, UITheme.SIZE_BODY):
		UITheme.draw_text(_canvas, Vector2(x, y), line, UITheme.SIZE_BODY, UITheme.TEXT_DIM)
		y += 30.0
	if kind == "weather":
		var gust: float = float(e["wind_mps"]) * float(e["gust"])
		var rows: Array = [
			["wind", "%.1f m/s" % e["wind_mps"]],
			["gusting to", "%.1f m/s" % (float(e["wind_mps"]) + gust)],
			["turbulence", "%.1f m/s" % e["turbulence"]],
			["ground grip", "%.0f %%" % (float(e["ground_grip"]) * 100.0)],
			["thermals", "%.0f %% of a clear day" % (float(e["thermal_scale"]) * 100.0)],
		]
		var col: float = panel.position.x + panel.size.x * 0.60
		var ry: float = panel.position.y + 48.0
		var pitch: float = minf(34.0, (panel.size.y - 64.0) / float(rows.size()))
		for row in rows:
			UITheme.draw_text(_canvas, Vector2(col, ry), String(row[0]), UITheme.SIZE_BODY,
					UITheme.TEXT_FAINT)
			UITheme.draw_text(_canvas, Vector2(col + 190.0, ry), String(row[1]), UITheme.SIZE_BODY,
					UITheme.TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UITheme.font_semibold())
			ry += pitch


func _is_hover_any() -> bool:
	return _hover.get("action", "") == "pick"


func _draw_start_picker(sheet: Rect2) -> void:
	var content: Rect2 = _picker_content(sheet)
	for i in SPAWNS.size():
		var r: Rect2 = _start_card_rect(content, i)
		var selected: bool = i == _spawn_index
		var hover: bool = _is_hover_pick(i)
		var fill: Color = UITheme.SURFACE_2 if selected else Color(UITheme.SURFACE.r,
				UITheme.SURFACE.g, UITheme.SURFACE.b, 0.80)
		_canvas.draw_colored_polygon(UITheme.rounded_rect(r, UITheme.R_MD), fill)
		var edge: PackedVector2Array = UITheme.rounded_rect(r, UITheme.R_MD)
		edge.append(edge[0])
		if selected:
			_canvas.draw_polyline(edge, Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, 0.7),
					UITheme.STROKE_UI, true)
		else:
			_canvas.draw_polyline(edge, UITheme.STROKE_HOVER if hover else UITheme.STROKE,
					UITheme.HAIRLINE, true)
		var art := Rect2(r.position.x + 40.0, r.position.y + 36.0, r.size.x - 80.0, 170.0)
		_draw_spawn_icon(art, String(SPAWNS[i][0]), UITheme.TEXT_DIM)
		UITheme.draw_display(_canvas, Vector2(r.position.x + 32.0, r.position.y + 262.0),
				String(SPAWNS[i][1]), UITheme.SIZE_H2,
				UITheme.TEXT if selected or hover else UITheme.TEXT_DIM)
		var y: float = r.position.y + 298.0
		for line in UITheme.wrap_text(String(SPAWNS[i][2]), r.size.x - 64.0, UITheme.SIZE_BODY):
			UITheme.draw_text(_canvas, Vector2(r.position.x + 32.0, y), line, UITheme.SIZE_BODY,
					UITheme.TEXT_DIM)
			y += 28.0
		if selected:
			var c := Vector2(r.end.x - 34.0, r.position.y + 34.0)
			_canvas.draw_circle(c, 14.0, UITheme.ACCENT)
			UITheme.draw_check(_canvas, c, 13.0, UITheme.ACCENT_INK, 2.5)


## Frames and the chosen badge for the picture cards, drawn above the images
## (which are Controls, and paint over anything the canvas draws).
func _draw_overlay() -> void:
	if _picker != "scene" and _picker != "weather":
		return
	var content: Rect2 = _picker_content(_rects.get("sheet", _sheet_rect(_canvas.size)))
	var entries: Array = _scenes if _picker == "scene" else _weathers
	var chosen: int = _picker_index()
	for i in entries.size():
		var r: Rect2 = _picture_rect(content, i, entries.size())
		var edge: PackedVector2Array = UITheme.rounded_rect(r, UITheme.R_MD)
		edge.append(edge[0])
		if i == chosen:
			_overlay.draw_polyline(edge, UITheme.ACCENT, UITheme.STROKE_UI + 1.0, true)
			var c := Vector2(r.end.x - 26.0, r.position.y + 26.0)
			_overlay.draw_circle(c, 15.0, UITheme.ACCENT)
			UITheme.draw_check(_overlay, c, 14.0, UITheme.ACCENT_INK, 2.5)
		elif _is_hover_pick(i):
			_overlay.draw_polyline(edge, Color(1, 1, 1, 0.55), UITheme.STROKE_UI, true)


# ---- footer ------------------------------------------------------------------

func _draw_footer(size: Vector2) -> void:
	var hints: Array
	if _picker != "":
		hints = [
			[["LEFT", "RIGHT"] if _picker != "aircraft" else ["UP", "DOWN"], "choose"],
			[["ENTER"], "use this"],
			[["ESC"], "cancel"],
		]
	else:
		var enter_text: String = "fly" if _focus == "fly" else "select"
		hints = [
			[["ENTER"], enter_text],
			[["LEFT", "RIGHT"], "move"],
			[["H"], "help"],
			[["ESC"], "quit" if start_screen else "close"],
		]
	UITheme.draw_footer_hints(_canvas, Vector2(G, size.y - FOOTER_H * 0.5), hints,
			UITheme.TEXT_DIM, UITheme.SIZE_KEY)
