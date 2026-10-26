# OpenRC Simulator - the flying scene.
#
# Wires the aircraft, the transmitter, the field and the camera together, and
# owns the session-level keys. Everything it touches is exposed by the C++
# extension; no physics is computed here, by design (Docs/ARCHITECTURE.md
# section 8).
extends Node3D

const CONTROLLER_PROFILE: String = "user://controller.json"

# Radios we ship a ready-made binding for, matched on the USB product name.
# EdgeTX/OpenTX publish a fixed axis order, so a known radio needs no wizard:
# plug it in, start, fly. A profile the pilot saves themselves lands in
# user://controller.json and always wins over these.
const BUILTIN_PROFILES: Array[Dictionary] = [
	{
		"names": ["radiomaster", "opentx", "edgetx", "frsky", "taranis", "jumper"],
		"path": "Data/Input/Profiles/edgetx_aetr.json",
		"label": "EdgeTX/OpenTX AETR",
	},
]

# Joypad enumeration is not complete on the first frame - udev has not been
# polled yet - so the search for a known radio runs for a moment before giving
# up and falling back to the menu.
const AUTOBIND_TIMEOUT: float = 1.5
const FieldScript := preload("res://fields/GrassField01/GrassField01.gd")
const WorldScript := preload("res://world/TerrainStreamer.gd")
const DetailScript := preload("res://world/DetailScatter.gd")
const WizardScript := preload("res://ui/ControllerWizard.gd")
const MenuScript := preload("res://ui/MainMenu.gd")
const TuningScript := preload("res://ui/TuningPanel.gd")
const HangarScript := preload("res://ui/HangarScreen.gd")
const DirectorScript := preload("res://world/WorldDirector.gd")
const WorldScreenScript := preload("res://ui/WorldScreen.gd")
const ReplayScript := preload("res://ui/ReplayBar.gd")
const ModelScript := preload("res://aircraft/Trainer1500/AircraftModel.gd")
const LoadingScript := preload("res://ui/LoadingScreen.gd")
const ScenePresetsLib := preload("res://world/ScenePresets.gd")
const WeatherLib := preload("res://world/Weather.gd")
const AudioScript := preload("res://aircraft/Trainer1500/AircraftAudio.gd")
const Settings := preload("res://ui/Settings.gd")
const SettingsScreenScript := preload("res://ui/SettingsScreen.gd")
const CrashCardScript := preload("res://ui/CrashCard.gd")
const PauseScript := preload("res://ui/PauseOverlay.gd")
const HeightCueScript := preload("res://world/HeightCue.gd")
const HelpScript := preload("res://ui/HelpOverlay.gd")
const WelcomeScript := preload("res://ui/Welcome.gd")
const FirstFlightLib := preload("res://ui/FirstFlight.gd")
const FirstFlightCardScript := preload("res://ui/FirstFlightCard.gd")
const SoundBankLib := preload("res://audio/SoundBank.gd")

## The guided first flight always flies the same thing: the forgiving trainer
## at the first field, in still air, off the runway.
const FIRST_FLIGHT_AIRCRAFT: String = "Trainer1500"
const FIRST_FLIGHT_WEATHER: String = "clear"
## T: a fresh start in the air, high enough to recover from a mistake.
const AIR_RESTART_ALTITUDE_M: float = 40.0
## A crash this long after lift-off was not about the take-off, so the card
## offers the in-the-air retry first.
const AIRBORNE_CRASH_S: float = 6.0
const SPAWN_IDS: Array[String] = ["runway", "air", "approach"]
const HUD_PRESETS: Array[String] = ["clean", "standard", "detailed"]
## The cut on a reset, so it reads as intentional rather than as a glitch.
const RESET_FADE_S: float = 0.15

## The keys the C++ keyboard fallback flies on. Listed here only so a key still
## held from navigating a menu can be recognised - see _refresh_hud_visibility.
const FLIGHT_KEYS: Array[Key] = [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
								 KEY_W, KEY_A, KEY_S, KEY_D]

@onready var aircraft: RCSimulationNode = $Aircraft
@onready var transmitter: RCInputNode = $Transmitter
@onready var camera_rig: Node3D = $CameraRig
var director: Node

var _autobind_remaining: float = 0.0
var _autobind_pending: bool = false
var _last_profile_problem: String = ""
## True while the world is being built behind the loading screen, so a second
## Fly cannot start a second build on top of the first.
var _loading: bool = false
## True once a sortie has been built, so there is a flight to pause.
var _world_built: bool = false
## Only an application that has HAD focus can lose it. Under a bare X server
## with no window manager the first event can be a focus-out, and a scripted
## render that paused itself on frame one would photograph a pause card.
var _had_focus: bool = false
## Set while the keyboard is being withheld until the flying keys are let go.
var _keys_held_from_screen: bool = false

## The start the player chose (menu Start chip, F6). T flies one sortie from the
## air without changing it: the next plain R puts this back.
var _player_spawn: int = 0
var _air_restart: bool = false
## The scene's own in-the-air height, restored once a retry has changed it.
var _base_spawn_altitude: float = 60.0
## Where home is: the spawn point on the strip, for the HUD's home arrow and the
## guided flight's "back over the field".
var _home: Vector3 = Vector3.ZERO
var _home_valid: bool = false

## Session counters for the crash card.
var _flight_no: int = 0
var _air_time_s: float = 0.0
var _flown: bool = false
var _was_crashed: bool = false
var _crash_counts: Dictionary = {}

## The guided first flight: on, which item, and the memory its rules read.
var _guided: bool = false
var _ff_step: int = 1
var _ff_tracker = FirstFlightLib.Tracker.new()
var _ff_hud_dirty: bool = false
var _sfx: AudioStreamPlayer
var _fade: ColorRect
var _fade_left: float = 0.0
## Set while a guided retry or a T restart has changed the in-the-air height.
var _altitude_overridden: bool = false
## One reset or replay toggle per frame: a card button and the flight's own key
## handler can both answer the same keypress.
var _last_reset_frame: int = -1
var _last_replay_frame: int = -1
var _tick_stream: AudioStreamWAV
var _done_stream: AudioStreamWAV


func _ready() -> void:
	# Preferences first: the window mode and the mixer are in effect before the
	# first frame is drawn or the first note of menu music plays.
	Settings.ensure_loaded()
	Settings.apply_all()
	_apply_flight_settings()

	# A profile the pilot saved themselves always wins. Failing that, a radio we
	# recognise gets bound automatically a moment from now, once Godot has
	# finished enumerating joypads.
	_player_spawn = aircraft.spawn_mode
	_base_spawn_altitude = aircraft.spawn_altitude_m
	_sfx = AudioStreamPlayer.new()
	_sfx.name = "FlowSfx"
	_sfx.bus = Settings.BUS_MENU
	_sfx.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_sfx)

	if transmitter.load_profile(CONTROLLER_PROFILE):
		print("Controller profile loaded.")
	else:
		_autobind_pending = true
		_autobind_remaining = AUTOBIND_TIMEOUT

	# The world is NOT built here.
	#
	# Building the field, the terrain and the scatter takes over a second, and
	# doing it in _ready meant the player watched a black window before the
	# menu they had not asked to leave yet appeared. Worse, it built a place
	# and a weather they had not chosen - so the first thing the Fly button did
	# was throw it away and build another. See _build_world().
	#
	# One place that knows how a scene preset and a weather state reach the
	# terrain, the sky, the light, the air and the ground. Cheap, and the menu
	# reads it, so it exists from the start; it simply has nothing to talk to
	# until the field does.
	director = DirectorScript.new()
	director.name = "WorldDirector"
	director.simulation_path = NodePath("../Aircraft")
	director.field_path = NodePath("../Field")
	director.camera_path = NodePath("../CameraRig")
	add_child(director)

	var tuning := TuningScript.new()
	tuning.name = "TuningPanel"
	tuning.simulation_path = NodePath("../Aircraft")
	add_child(tuning)

	aircraft.reset_state()
	_add_crash_card()
	_print_help()

	# The briefing room opens NOW, on the first frame, whatever the radio is
	# doing.
	#
	# It used to wait for the auto-bind attempt to resolve - up to a second and
	# a half - and in the meantime the player sat looking at an empty 3D
	# viewport. Which is indistinguishable from watching a scene load, and was
	# reported as exactly that. Nothing is loading; the menu was simply being
	# withheld. The transmitter panel reads the radio every frame and says
	# "READY" the moment it binds, so there was never anything to wait for.
	_open_menu(true)
	# The first time, before anything else: how will you fly, which stick mode,
	# how do you want to watch. Not under the scripted checks, which drive the
	# menu themselves and must not depend on whose machine they run on.
	if not bool(Settings.get_value("onboarding/done")) and not _scripted():
		_open_controls(true)


## Running under a test or render script rather than as the game.
func _scripted() -> bool:
	if OS.has_environment("RC_NO_WELCOME") or DisplayServer.get_name() == "headless":
		return true
	for arg in OS.get_cmdline_args():
		if arg == "--script" or arg == "-s":
			return true
	return false


## The controls setup: the first-run flow, and the menu's CONTROLS button.
func _open_controls(first_run: bool = false) -> void:
	if has_node("Welcome"):
		return
	var welcome := WelcomeScript.new()
	welcome.name = "Welcome"
	welcome.input_path = NodePath("../Transmitter")
	welcome.first_run = first_run
	welcome.wizard_requested.connect(_open_wizard)
	welcome.finished.connect(_apply_flight_settings)
	# "Start first flight": Welcome emits finished first, then this.
	if welcome.has_signal("first_flight_requested"):
		welcome.connect("first_flight_requested", _start_first_flight, CONNECT_DEFERRED)
	welcome.tree_exited.connect(_refresh_hud_visibility, CONNECT_DEFERRED)
	add_child(welcome)
	_refresh_hud_visibility()


## The settings the simulation itself reads, rather than a screen: the keyboard
## layout and failure practice. Applied at start and whenever settings close.
func _apply_flight_settings() -> void:
	transmitter.set_keyboard_mode(int(Settings.get_value("controls/stick_mode")))
	aircraft.set_failure_practice(float(Settings.get_value("practice/failure_chance")),
		bool(Settings.get_value("practice/radio_failures")),
		bool(Settings.get_value("practice/failure_notice")))


## The crash card rides on the HUD's layer, so it shows and hides with it.
func _add_crash_card() -> void:
	var hud: Node = get_node_or_null("FlightHUD")
	if hud == null or hud.has_node("CrashCard"):
		return
	var card := CrashCardScript.new()
	card.name = "CrashCard"
	hud.add_child(card)
	card.bind(aircraft)
	if card.has_signal("action_chosen"):
		card.connect("action_chosen", _on_crash_action)


## F10: the flight recorder's last two minutes as CSV, for a spreadsheet or
## PlotJuggler - sticks against what the aeroplane did, which is how an
## instructor reads a flight. Never overwrites: every save gets its own name.
func _save_flight_log() -> void:
	var directory: String = "user://flights"
	DirAccess.make_dir_recursive_absolute(directory)
	var stamp: String = Time.get_datetime_string_from_system(false, true) \
		.replace(":", "").replace(" ", "_").replace("-", "")
	var path: String = ProjectSettings.globalize_path("%s/flight_%s.csv" % [directory, stamp])
	if aircraft.save_flight_log(path):
		print("Flight log saved: %s" % path)
		var hud: Node = get_node_or_null("FlightHUD")
		if hud != null and hud.has_method("show_notice"):
			hud.show_notice("FLIGHT LOG SAVED   -   %s" % path.get_file())
	else:
		push_warning("Could not save the flight log to %s" % path)


func _print_help() -> void:
	print("""
OpenRC Simulator
  H / F1      controls and help          Esc   pause menu
  C           next view: follow / pilot / FPV   (1 / 2 / 3 direct)
  Z           pilot-view zoom  1x -> 2x -> 4x    X  pilot-view auto-zoom on / off
  G           height cue (mark on the ground below the model) on / off
  right drag  look around
  R           reset (a new flight)   Shift+R  the same flight again (failure practice)
  T           try again in the air (the next R goes back to your own start)
  V           HUD: clean / standard / detailed
  Tab         replay the last two minutes
  M           aircraft, field, weather   L  location   O  settings   P  pause
  4 5 6 7 8   dead stick / jammed aileron / elevator linkage / radio loss / brownout
  9           clear the failure   (4-9 only with Settings > Practice > Failure keys on)
  F2          per-section detail    F3  transmitter setup    F4  tuning panel
  F5          reload the aircraft definition    F6  cycle spawn mode
  F9          hide the overlay      F10 save the last two minutes as CSV
""")


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# While a screen is up it owns the keyboard. Every one of these was live
	# behind the menu: R reset the aeroplane you were still choosing, the
	# number row induced failures at the briefing, and W - the world screen -
	# is also the throttle.
	if _modal_open():
		return

	match event.keycode:
		KEY_R when has_node("ReplayBar"):
			# The bar's own "Fly again": out of the replay and straight into a
			# new flight.
			_on_replay_action("again")
		KEY_R when event.shift_pressed:
			# The same flight again: with failure practice on, the same failure
			# at the same moment, to be flown until it is flown well.
			aircraft.set_failure_practice_repeat(true)
			_restart()
			aircraft.set_failure_practice_repeat(false)
			print("Reset: the same flight again.")
		KEY_R:
			_restart()
			print("Reset.")
		KEY_T:
			# Try again in the air: the lesson was the turn, not the take-off.
			if has_node("ReplayBar"):
				_on_replay_action("air")
			else:
				_restart_air()
		KEY_V:
			_cycle_hud()
		KEY_F10:
			_save_flight_log()
		KEY_F5:
			# Hot reload: edit the aircraft JSON, press F5, feel the difference.
			# This is the tuning loop, and it is why AircraftDefinition owns no
			# engine resources.
			if aircraft.reload_aircraft():
				aircraft.reset_state()
				_on_reset()
				print("Aircraft reloaded: %s" % aircraft.get_aircraft_name())
		KEY_F6:
			_end_air_restart()
			aircraft.spawn_mode = (aircraft.spawn_mode + 1) % 3
			_player_spawn = aircraft.spawn_mode
			aircraft.reset_state()
			_on_reset()
			print("Spawn mode: %s" % SPAWN_IDS[aircraft.spawn_mode])
		KEY_F3:
			_open_wizard()
		KEY_M:
			_open_menu(false)
		KEY_H, KEY_F1:
			_open_help()
		KEY_O:
			_open_settings()
		KEY_P:
			_pause("paused")
		KEY_G:
			var cue: Node = get_node_or_null("Field/HeightCue")
			if cue != null:
				cue.toggle()
		KEY_L:
			# L for location. It was W, which is also the keyboard throttle:
			# opening the throttle opened the world screen.
			_open_world_screen()
		KEY_TAB:
			_toggle_replay()
		# Failures, on the number row. A pilot practising dead-stick landings
		# wants one key, not a menu - the whole exercise is what you do in the
		# next four seconds. Behind a setting: a beginner mashing keys got a
		# dead stick and thought the simulator was broken.
		KEY_4 when _failure_keys():
			aircraft.induce_failure(1, 0)      # dead stick
		KEY_5 when _failure_keys():
			aircraft.induce_failure(2, 0)      # jammed aileron
		KEY_6 when _failure_keys():
			aircraft.induce_failure(3, 1)      # elevator linkage gone
		KEY_7 when _failure_keys():
			aircraft.induce_failure(4, 0)      # radio loss
		KEY_8 when _failure_keys():
			aircraft.induce_failure(5, 0)      # brownout
		KEY_9 when _failure_keys():
			aircraft.clear_failures()
		KEY_ESCAPE:
			# A replay is backed out of first; otherwise Esc is the pause menu,
			# where quitting is one of the choices - never a keypress that ends
			# the program from the middle of a flight.
			if has_node("ReplayBar"):
				get_node("ReplayBar").queue_free()
			else:
				_pause("paused")


## Watch it again. The recorder is always running, so there is nothing to start -
## and pressing R while a replay is open closes it and puts the pilot back on the
## live aircraft, because a replay is something you look at rather than somewhere
## you can fly from.
func _toggle_replay() -> void:
	if _last_replay_frame == Engine.get_process_frames():
		return
	_last_replay_frame = Engine.get_process_frames()
	if has_node("ReplayBar"):
		get_node("ReplayBar").queue_free()
		return
	var bar := ReplayScript.new()
	bar.name = "ReplayBar"
	bar.simulation_path = NodePath("../Aircraft")
	# Its "Fly again" / "Try from the air" buttons: close the replay, then do it.
	if bar.has_signal("action_chosen"):
		bar.connect("action_chosen", _on_replay_action)
	add_child(bar)


## Where and when: the place and the weather, chosen independently.
func _open_world_screen() -> void:
	if has_node("WorldScreen") or director == null:
		return
	var screen := WorldScreenScript.new()
	screen.name = "WorldScreen"
	screen.tree_exited.connect(_refresh_hud_visibility, CONNECT_DEFERRED)
	add_child(screen)
	_refresh_hud_visibility()
	screen.select(director.scene_id, director.weather_id)
	screen.chosen.connect(func(scene_id: String, weather_id: String) -> void:
		director.apply_scene(scene_id)
		director.apply_weather(weather_id)
		aircraft.reset_state()
		_on_reset()
		screen.queue_free())
	screen.cancelled.connect(func() -> void: screen.queue_free())


## The hangar: pick an aeroplane, and see what it is before you do.
func _open_hangar() -> void:
	if has_node("Hangar"):
		return
	var hangar := HangarScript.new()
	hangar.name = "Hangar"
	hangar.simulation_path = NodePath("../Aircraft")
	hangar.chosen.connect(_fly_aircraft)
	hangar.cancelled.connect(func() -> void: hangar.queue_free())
	hangar.tree_exited.connect(_refresh_hud_visibility, CONNECT_DEFERRED)
	add_child(hangar)
	_refresh_hud_visibility()


func _fly_aircraft(stem: String) -> void:
	aircraft.aircraft_definition = "Data/Aircraft/%s.json" % stem
	if not aircraft.reload_aircraft():
		push_warning("Could not load %s" % stem)
		return
	aircraft.reset_state()
	# The visible model is generated from the flight model's own geometry, so a
	# different aeroplane needs it rebuilt rather than re-posed.
	var model: Node = aircraft.get_node_or_null("Model")
	if model != null:
		model.queue_free()
	var replacement := ModelScript.new()
	replacement.name = "Model"
	replacement.simulation_path = NodePath("..")
	aircraft.add_child(replacement)
	if has_node("Hangar"):
		get_node("Hangar").queue_free()
	print("Flying %s" % aircraft.get_aircraft_name())


func _open_menu(start: bool = false) -> void:
	if has_node("MainMenu"):
		return
	var menu := MenuScript.new()
	menu.name = "MainMenu"
	menu.input_path = NodePath("../Transmitter")
	menu.simulation_path = NodePath("../Aircraft")
	menu.director_path = NodePath("../WorldDirector")
	menu.start_screen = start
	menu.wizard_requested.connect(_open_controls.bind(false))
	menu.help_requested.connect(_open_help)
	menu.tuning_requested.connect(_open_tuning)
	menu.settings_requested.connect(_open_settings)
	menu.fly_requested.connect(_fly_from_menu)
	if menu.has_signal("first_flight_requested"):
		menu.connect("first_flight_requested", _start_first_flight, CONNECT_DEFERRED)
	# The HUD has nothing to say while the aeroplane is parked behind a menu,
	# and its panels showed through in the corners - a transmitter readout
	# bottom-left and a battery gauge bottom-right, both belonging to a flight
	# that is not happening. Hidden for as long as the menu is up.
	menu.tree_exited.connect(_refresh_hud_visibility, CONNECT_DEFERRED)
	add_child(menu)
	_refresh_hud_visibility()


## Is a screen that owns the whole frame - and the keyboard - up?
##
## The tuning panel is deliberately not in this list: it slides in beside the
## HUD to tune the aeroplane in flight, and the numbers it is tuning against
## are the ones the HUD is showing.
func _modal_open() -> bool:
	return _screen_open() or has_node("PauseOverlay") or has_node("HelpOverlay") \
			or has_node("FirstFlightCard")


## The full-frame screens. The pause card owns the keyboard like they do, but
## not the frame - see _refresh_hud_visibility.
func _screen_open() -> bool:
	return has_node("MainMenu") or has_node("ControllerWizard") \
			or has_node("Hangar") or has_node("WorldScreen") \
			or has_node("LoadingScreen") or has_node("SettingsScreen") \
			or has_node("Welcome")


## Hands the frame and the keyboard to whichever screen is up, or back to the
## sortie when none is. Asked as a question rather than set as a flag: the menu
## can hand straight over to the wizard, and a pair of enable/disable calls
## would race - the menu leaving the tree after the wizard has entered it, and
## turning the aeroplane's controls back on underneath.
func _refresh_hud_visibility() -> void:
	var modal: bool = _modal_open()
	var hud: Node = get_node_or_null("FlightHUD")
	if hud != null:
		# Left up behind the pause card: frozen, it answers "where was I, and
		# how high" before the pilot takes the sticks back.
		hud.visible = not _screen_open()
		# ...but faded, with its hints withdrawn: whatever is open is the thing
		# to read.
		if hud.has_method("set_overlay_open"):
			hud.set_overlay_open(modal)
	# The keyboard fallback reads the keys directly, so nothing a screen does
	# with an event can stop it. It has to be told.
	#
	# And told twice. Closing a screen is often done with a key that was held
	# a moment before - an arrow walked down the menu, still down as Enter
	# lands - and handing the keyboard straight back turned that arrow into a
	# full elevator input on the first frame of the sortie. So a flying key
	# that is already down when a screen closes is ignored until it has been
	# let go; _process hands the keyboard back then.
	if transmitter != null:
		if modal:
			_keys_held_from_screen = false
			transmitter.set_keyboard_enabled(false)
		elif _flight_keys_down():
			_keys_held_from_screen = true
			transmitter.set_keyboard_enabled(false)
		else:
			_keys_held_from_screen = false
			transmitter.set_keyboard_enabled(true)
	# 1/2/3, Z and right-drag belong to the sortie, not to a briefing.
	if camera_rig != null:
		camera_rig.set_process_unhandled_input(not modal)


## The menu's Fly button: one action, the whole sortie.
##
## The world is built here rather than at startup, a piece at a time, with a
## loading screen in front of it saying how far along it is. Building it in one
## frame froze the window for a second and a half - which is indistinguishable
## from a crash - and built a place the player had not chosen yet.
##
## `options`: {"spawn": "runway" | "air" | "approach", "mode": "free" | "first_flight"}.
## Without a spawn the aircraft keeps the start it has (the scripted checks set
## it themselves).
func _fly_from_menu(stem: String, scene_id: String, weather_id: String,
					options: Dictionary = {}) -> void:
	if _loading:
		return
	_loading = true
	_end_air_restart()
	if options.has("spawn"):
		var spawn: int = SPAWN_IDS.find(String(options["spawn"]))
		if spawn >= 0:
			aircraft.spawn_mode = spawn
	_player_spawn = aircraft.spawn_mode
	_set_guided(String(options.get("mode", "free")) == "first_flight")
	if has_node("FirstFlightCard"):
		get_node("FirstFlightCard").queue_free()
	if has_node("MainMenu"):
		# Deferred: this runs from inside the menu's own signal emit, and a
		# node cannot free itself out from under the call that is running.
		get_node("MainMenu").queue_free()

	var loader := LoadingScript.new()
	loader.name = "LoadingScreen"
	loader.scene_id = scene_id
	loader.sortie = "%s   -   %s, %s" % [
		_display_name(stem),
		ScenePresetsLib.by_id(scene_id).get("name", scene_id),
		WeatherLib.by_id(weather_id).get("name", weather_id)]
	loader.tree_exited.connect(_refresh_hud_visibility, CONNECT_DEFERRED)
	add_child(loader)
	_refresh_hud_visibility()
	await get_tree().process_frame

	await _build_world(loader, stem, scene_id, weather_id)

	loader.report(1.0, "ready")
	# Long enough for the bar to visibly reach the end. A progress bar that
	# vanishes at 80% leaves the player sure something went wrong.
	await get_tree().create_timer(0.35).timeout
	loader.dismiss()
	_loading = false
	_world_built = true
	if _guided:
		_calm_air()
	_on_reset(false)
	_refresh_hud_visibility()


## Everything that stands between an empty scene and a sortie, in the order it
## has to happen, reporting as it goes.
func _build_world(loader: Node, stem: String, scene_id: String,
				  weather_id: String) -> void:
	if not has_node("Field/GrassField01"):
		loader.report(0.04, "loading the aeroplane")
		aircraft.aircraft_definition = "Data/Aircraft/%s.json" % stem
		if not aircraft.reload_aircraft():
			push_warning("Could not load %s" % stem)
		await get_tree().process_frame

		loader.report(0.10, "mowing the strip")
		var field := FieldScript.new()
		field.name = "GrassField01"
		field.simulation_path = NodePath("../../Aircraft")
		$Field.add_child(field)
		camera_rig.field_path = camera_rig.get_path_to(field)
		# Straight down, not along the sun - see HeightCue.gd.
		var cue := HeightCueScript.new()
		cue.name = "HeightCue"
		cue.simulation_path = NodePath("../../Aircraft")
		$Field.add_child(cue)
		await get_tree().process_frame

		loader.report(0.18, "raising the terrain")
		if not OS.has_environment("RC_NO_TERRAIN"):
			var world := WorldScript.new()
			world.name = "World"
			world.simulation_path = NodePath("../../Aircraft")
			world.camera_path = NodePath("../../CameraRig")
			world.defer_build = true
			$Field.add_child(world)
			await _pump_levels(loader, world, 0.18, 0.52)

		loader.report(0.52, "planting the treeline")
		if not OS.has_environment("RC_NO_DETAIL"):
			var detail := DetailScript.new()
			detail.name = "Detail"
			detail.simulation_path = NodePath("../../Aircraft")
			detail.camera_path = NodePath("../../CameraRig")
			detail.defer_build = true
			$Field.add_child(detail)
			await _pump_cells(loader, detail, 0.52, 0.88)

		loader.report(0.88, "wiring the aeroplane")
		var audio := AudioScript.new()
		audio.name = "Audio"
		audio.simulation_path = NodePath("..")
		aircraft.add_child(audio)
		await get_tree().process_frame

	loader.report(0.92, "setting the weather")
	if director != null:
		director.rebind()
		director.apply_scene(scene_id)
		await get_tree().process_frame
		director.apply_weather(weather_id)
		await get_tree().process_frame

	loader.report(0.97, "walking out to the strip")
	_fly_aircraft(stem)
	await get_tree().process_frame


## One clipmap level per frame, so the bar moves and the window keeps painting.
func _pump_levels(loader: Node, world: Node, from: float, to: float) -> void:
	var total: int = maxi(world.call("pending_levels"), 1)
	while world.call("pending_levels") > 0:
		var left: int = world.call("build_next_level")
		loader.report(lerpf(from, to, 1.0 - float(left) / float(total)),
					  "raising the terrain")
		await get_tree().process_frame


## Scattered cells in batches. The batch is sized so a frame stays under about
## a fiftieth of a second: small enough that the window is alive, large enough
## that the circuit does not take a minute.
func _pump_cells(loader: Node, detail: Node, from: float, to: float) -> void:
	var total: int = maxi(detail.call("pending_cells"), 1)
	while detail.call("pending_cells") > 0:
		var left: int = detail.call("build_some", 4)
		loader.report(lerpf(from, to, 1.0 - float(left) / float(total)),
					  "planting the treeline")
		await get_tree().process_frame


## The aircraft's display name, without loading it: the menu already knows it,
## but the loading screen is handed only the file stem.
func _display_name(stem: String) -> String:
	return stem.capitalize()


func _flight_keys_down() -> bool:
	for key in FLIGHT_KEYS:
		if Input.is_key_pressed(key):
			return true
	return false


## Settings, over whatever is showing - the menu or the sortie.
func _open_settings() -> void:
	if has_node("SettingsScreen"):
		return
	var screen := SettingsScreenScript.new()
	screen.name = "SettingsScreen"
	screen.tree_exited.connect(_refresh_hud_visibility, CONNECT_DEFERRED)
	screen.tree_exited.connect(_apply_flight_settings, CONNECT_DEFERRED)
	add_child(screen)
	_refresh_hud_visibility()


## Stops the whole tree. Only the pause card keeps running, and only the pilot
## can start it again - see PauseOverlay.gd for why focus coming back does not.
func _pause(reason: String) -> void:
	if not _world_built or _loading or has_node("PauseOverlay"):
		return
	var overlay := PauseScript.new()
	overlay.name = "PauseOverlay"
	overlay.reason = reason
	overlay.resumed.connect(func() -> void: get_tree().paused = false)
	overlay.chosen.connect(_on_pause_choice, CONNECT_DEFERRED)
	overlay.tree_exited.connect(_refresh_hud_visibility, CONNECT_DEFERRED)
	add_child(overlay)
	_refresh_hud_visibility()
	get_tree().paused = true


## What the pause menu asked for, once it has unpaused and gone.
func _on_pause_choice(action: String) -> void:
	match action:
		"restart":
			_restart()
		"restart_air":
			_restart_air()
		"menu":
			_open_menu(false)
		"help":
			_open_help()
		"radio":
			_open_wizard()
		"settings":
			_open_settings()


## The controls card. In flight it stops the clock while it is read.
func _open_help() -> void:
	if has_node("HelpOverlay"):
		return
	var help := HelpScript.new()
	help.name = "HelpOverlay"
	help.input_path = NodePath("../Transmitter")
	var pausing: bool = _world_built and not _loading and not get_tree().paused
	help.closed.connect(func() -> void:
		if pausing:
			get_tree().paused = false)
	help.tree_exited.connect(_refresh_hud_visibility, CONNECT_DEFERRED)
	if help.has_signal("wizard_requested"):
		help.connect("wizard_requested", _open_wizard, CONNECT_DEFERRED)
	add_child(help)
	_refresh_hud_visibility()
	if pausing:
		get_tree().paused = true


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_IN:
			_had_focus = true
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			if _had_focus:
				_pause("the window lost focus")


func _open_tuning() -> void:
	var tuning: Node = get_node_or_null("TuningPanel")
	if tuning != null:
		tuning.visible = true


func _open_wizard() -> void:
	if has_node("ControllerWizard"):
		return
	var wizard := WizardScript.new()
	wizard.name = "ControllerWizard"
	wizard.input_path = NodePath("../Transmitter")
	wizard.finished.connect(_on_wizard_finished)
	wizard.tree_exited.connect(_refresh_hud_visibility, CONNECT_DEFERRED)
	add_child(wizard)
	_refresh_hud_visibility()


func _on_wizard_finished(saved: bool) -> void:
	print("Controller setup %s." % ("saved" if saved else "cancelled"))


func _process(delta: float) -> void:
	# The camera rig and the field drive themselves from the aircraft, and the
	# aircraft drives itself from the transmitter, so the work here is the
	# one-shot search for a radio we already know how to bind, the session's
	# flight counters and the guided first flight.
	_check_profile_problem()
	_update_fade(delta)
	if _world_built and not _loading:
		_track_flight(delta)
		_update_guided(delta)

	if _keys_held_from_screen and not _flight_keys_down() and not _modal_open():
		_keys_held_from_screen = false
		transmitter.set_keyboard_enabled(true)

	if _autobind_pending:
		_autobind_remaining -= delta
		if _try_autobind() or _autobind_remaining <= 0.0:
			_autobind_pending = false
			if not transmitter.is_connected():
				print("No transmitter detected. Plug one in and press F3 for the wizard.")
			# The menu is already up - it opened on the first frame. Its
			# transmitter panel will have changed to READY on its own.


## A binding can be well-formed and still be wrong for the radio attached, and
## the dangerous case - a throttle bound to a stick - is not something the pilot
## should discover by watching the propeller answer the rudder.
##
## Evaluated every frame and reported on the transition, rather than sampled
## once at startup: a transmitter takes a moment to report its first state, and
## a snapshot taken before then describes nothing.
func _check_profile_problem() -> void:
	var problem: String = ""
	if transmitter.is_connected():
		problem = transmitter.get_profile_problem()
	if problem == _last_profile_problem:
		return
	_last_profile_problem = problem

	if problem.is_empty():
		return
	push_warning("Transmitter: %s" % problem)
	print("WARNING  transmitter problem:")
	print("         %s" % problem)


func _try_autobind() -> bool:
	if not transmitter.is_connected():
		return false

	var device: String = transmitter.get_device_name().to_lower()
	for profile in BUILTIN_PROFILES:
		for name in profile["names"]:
			if device.find(name) < 0:
				continue
			var resolved: String = _repo_path(profile["path"])
			if not transmitter.load_profile(resolved):
				push_warning("Built-in profile for %s did not load from %s."
						% [profile["label"], resolved])
				return false
			print("Recognised %s - applied the built-in %s binding. Press F3 to recalibrate."
					% [transmitter.get_device_name(), profile["label"]])
			return true
	return false


func _repo_path(relative: String) -> String:
	# One implementation, in C++, so the repository layout and an installed
	# build are resolved the same way here as for the aircraft definition.
	return aircraft.resolve_data_path(relative)


# ------------------------------------------------------------ flow and retry

func _failure_keys() -> bool:
	return bool(Settings.get_value("practice/failure_keys"))


## V: Clean, Standard, Detailed. The HUD reads the setting every frame.
func _cycle_hud() -> void:
	var current: int = HUD_PRESETS.find(String(Settings.get_value("interface/hud")))
	if current < 0:
		current = 1
	var next: String = HUD_PRESETS[(current + 1) % HUD_PRESETS.size()]
	Settings.set_value("interface/hud", next)
	var hud: Node = get_node_or_null("FlightHUD")
	if hud != null and hud.has_method("show_notice"):
		hud.show_notice("HUD: %s" % next.capitalize(), 1.5)


## R: a new flight from the player's own start. In the guided flight it is
## "Try again from step N", with the ticks kept - a beginner who crashes on the
## turn never flies the take-off again.
func _restart() -> void:
	if _last_reset_frame == Engine.get_process_frames():
		return
	if _guided:
		_retry_guided_step()
		return
	_end_air_restart()
	aircraft.reset_state()
	_on_reset()


## T: one sortie from the air, without changing the start the player chose.
## In the guided flight too: the checklist carries on from where it was.
func _restart_air() -> void:
	if not _world_built or _loading:
		return
	if _last_reset_frame == Engine.get_process_frames():
		return
	_begin_air_restart(RCSimulationNode.SPAWN_AIR, AIR_RESTART_ALTITUDE_M)
	aircraft.reset_state()
	_on_reset()


func _begin_air_restart(mode: int, altitude: float) -> void:
	if not _air_restart:
		_player_spawn = aircraft.spawn_mode
		_air_restart = true
	aircraft.spawn_mode = mode
	if mode == RCSimulationNode.SPAWN_AIR:
		aircraft.spawn_altitude_m = altitude
		_altitude_overridden = true


## Puts back the player's own start after a T or a guided retry.
func _end_air_restart() -> void:
	if _air_restart:
		aircraft.spawn_mode = _player_spawn
		_air_restart = false
	if _altitude_overridden:
		aircraft.spawn_altitude_m = _base_spawn_altitude
		_altitude_overridden = false


## "Try again from step N": the take-off from the runway, the way home and the
## landing on approach, everything else in the air - the ticks stay.
func _retry_guided_step() -> void:
	var step: int = clampi(_ff_step, 1, FirstFlightLib.STEPS)
	var where: String = FirstFlightLib.retry_spawn(step)
	if where == "runway":
		_end_air_restart()
	else:
		_begin_air_restart(SPAWN_IDS.find(where), FirstFlightLib.retry_altitude(step))
	aircraft.reset_state()
	_on_reset()


## Every spawn passes through here: a new flight for the counters, home put
## back on the strip, and the cut.
func _on_reset(fade: bool = true) -> void:
	_last_reset_frame = Engine.get_process_frames()
	_flight_no += 1
	_air_time_s = 0.0
	_flown = false
	_was_crashed = false
	_ff_tracker.reset()
	var offset: Vector3 = aircraft.spawn_offset
	_home = Vector3(offset.x, aircraft.get_terrain_height(offset.x, offset.z), offset.z)
	_home_valid = true
	_push_home()
	if fade:
		_start_fade()


func _push_home() -> void:
	var hud: Node = get_node_or_null("FlightHUD")
	if hud == null:
		return
	hud.set("home_position", _home)
	hud.set("home_valid", _home_valid)


## The session's counters, and the moment of a crash.
func _track_flight(delta: float) -> void:
	if aircraft.get_replaying():
		return
	var crashed: bool = aircraft.has_crashed()
	if crashed and not _was_crashed:
		_on_crash()
	elif _was_crashed and not crashed:
		# Reset by something other than this script (a test, the tuning
		# panel): still a new flight.
		_flight_no += 1
		_air_time_s = 0.0
		_flown = false
	_was_crashed = crashed
	if not crashed and not aircraft.is_on_ground():
		_air_time_s += delta
		if _air_time_s > 0.6:
			_flown = true


func _on_crash() -> void:
	var report: Dictionary = aircraft.get_crash_report()
	var title: String = String(report.get("title", "Crashed"))
	_crash_counts[title] = int(_crash_counts.get(title, 0)) + 1
	# The card marks it seen once it has actually been shown: a crash reset
	# before the card appears has not taught anything yet.
	var first: bool = not bool(Settings.get_value("onboarding/first_crash_seen"))
	var airborne: bool = _flown and _air_time_s >= AIRBORNE_CRASH_S
	var context: Dictionary = {
		"flight": maxi(_flight_no, 1),
		"air_time_s": _air_time_s,
		"repeat": int(_crash_counts[title]),
		"first_crash": first,
		"primary": "air" if airborne else "again",
		"step_label": "",
	}
	if _guided:
		context["step_label"] = FirstFlightLib.retry_label(_ff_step)
		# The card puts the step label on R, and R is the guided retry.
		context["primary"] = "again"
	var card: Node = get_node_or_null("FlightHUD/CrashCard")
	if card != null:
		card.set("context", context)


func _on_replay_action(id: String) -> void:
	if has_node("ReplayBar"):
		get_node("ReplayBar").queue_free()
		# Back on the live aircraft before it is reset, not when the bar has
		# finished leaving the tree a frame later.
		aircraft.set_replaying(false)
	_on_crash_action(id)


## The crash card's buttons (and their keys, if the card handles them).
func _on_crash_action(id: String) -> void:
	match id:
		"again":
			_restart()
		"air":
			_restart_air()
		"replay":
			_toggle_replay()


# ------------------------------------------------------- guided first flight

## The menu's "First flight", and the setup's "Start first flight".
func _start_first_flight() -> void:
	if _loading:
		return
	var scenes: Array[Dictionary] = ScenePresetsLib.all()
	var scene_id: String = String(scenes[0]["id"]) if not scenes.is_empty() else "meadow"
	_fly_from_menu(FIRST_FLIGHT_AIRCRAFT, scene_id, FIRST_FLIGHT_WEATHER,
			{"spawn": "runway", "mode": "first_flight"})


func _set_guided(on: bool) -> void:
	_guided = on
	_ff_step = 1
	_ff_tracker.reset()
	if not on:
		_clear_guided_hud()


func _clear_guided_hud() -> void:
	var hud: Node = get_node_or_null("FlightHUD")
	if hud != null:
		hud.set("checklist", [])
		hud.set("hint_override", [])
	_ff_hud_dirty = false


## Still air for the first flight: the lesson is the controls, not a crosswind.
## The next Fly from the menu applies the chosen weather again.
func _calm_air() -> void:
	aircraft.wind_speed_mps = 0.0
	aircraft.gust_amplitude_mps = 0.0
	aircraft.turbulence_mps = 0.0
	if aircraft.has_method("set_thermal_scale"):
		aircraft.set_thermal_scale(0.0)


func _guided_state() -> Dictionary:
	var velocity: Vector3 = aircraft.get_velocity_world()
	var flat := Vector2(velocity.x, velocity.z)
	var heading: float = NAN
	if flat.length() > 3.0:
		heading = rad_to_deg(atan2(flat.x, -flat.y))
	var height: float = aircraft.get_height_above_ground_m()
	if height < 0.0:
		var at: Vector3 = aircraft.global_position
		height = at.y - aircraft.get_terrain_height(at.x, at.z)
	return {
		"input": "radio" if transmitter.is_connected() else "keyboard",
		"mode": 1 if int(Settings.get_value("controls/stick_mode")) == 1 else 2,
		"units": Settings.units(),
		"crashed": aircraft.has_crashed(),
		"on_ground": aircraft.is_on_ground(),
		"flown": _ff_tracker.flown,
		"air_s": _ff_tracker.air_s,
		"height": height,
		"throttle": float(aircraft.get_channels()[2]),
		"band_s": _ff_tracker.band_s,
		"turned_deg": _ff_tracker.turned_deg,
		"been_away": _ff_tracker.been_away,
		"position": aircraft.global_position,
		"home": _home,
		"heading_deg": 0.0 if is_nan(heading) else heading,
		"_heading_raw": heading,
		"speed": aircraft.get_ground_speed_mps(),
		"airspeed": aircraft.get_airspeed_mps(),
		"slow_mps": aircraft.get_approach_speed_mps() * 0.85,
	}


func _update_guided(delta: float) -> void:
	if not _guided:
		if _ff_hud_dirty:
			_clear_guided_hud()
		return
	var hud: Node = get_node_or_null("FlightHUD")
	if hud == null or _modal_open() or aircraft.get_replaying():
		return
	var state: Dictionary = _guided_state()
	_ff_tracker.update(delta, _ff_step, bool(state["on_ground"]), bool(state["crashed"]),
			float(state["throttle"]), float(state["_heading_raw"]),
			FirstFlightLib.home_distance(state))
	state["been_away"] = _ff_tracker.been_away
	state["air_s"] = _ff_tracker.air_s
	state["band_s"] = _ff_tracker.band_s
	state["turned_deg"] = _ff_tracker.turned_deg
	state["flown"] = _ff_tracker.flown
	var result: Dictionary = FirstFlightLib.evaluate(state, _ff_step)
	var step: int = int(result["step"])
	if step != _ff_step:
		_ff_step = step
		_play_tick()
	hud.set("checklist", FirstFlightLib.items(_ff_step, Settings.units()))
	hud.set("hint_override", result["hints"])
	_ff_hud_dirty = true
	if bool(result["done"]):
		_complete_first_flight()


func _complete_first_flight() -> void:
	Settings.set_value("onboarding/first_flight_done", true)
	if has_node("FirstFlightCard"):
		return
	var card := FirstFlightCardScript.new()
	card.name = "FirstFlightCard"
	card.chosen.connect(_on_first_flight_card, CONNECT_DEFERRED)
	card.tree_exited.connect(_refresh_hud_visibility, CONNECT_DEFERRED)
	add_child(card)
	_refresh_hud_visibility()
	if _done_stream == null:
		_done_stream = SoundBankLib.ui_confirm()
	_play(_done_stream)


func _on_first_flight_card(id: String) -> void:
	_set_guided(false)
	_end_air_restart()
	if id == "menu":
		_open_menu(false)


func _play_tick() -> void:
	if _tick_stream == null:
		_tick_stream = SoundBankLib.ui_tick()
	_play(_tick_stream)


func _play(stream: AudioStreamWAV) -> void:
	if _sfx == null:
		return
	_sfx.stream = stream
	_sfx.play()


# ------------------------------------------------------------------ the cut

## A 150 ms fade up from black on a reset, so the jump reads as a cut rather
## than a glitch. None under reduced motion.
func _start_fade() -> void:
	if Settings.reduced_motion() or DisplayServer.get_name() == "headless":
		return
	if _fade == null:
		var layer := CanvasLayer.new()
		layer.name = "ResetFade"
		layer.layer = 35
		add_child(layer)
		_fade = ColorRect.new()
		_fade.color = Color(0, 0, 0, 0)
		_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
		layer.add_child(_fade)
	_fade_left = RESET_FADE_S


func _update_fade(delta: float) -> void:
	if _fade == null:
		return
	_fade_left = maxf(_fade_left - delta, 0.0)
	_fade.color.a = _fade_left / RESET_FADE_S
