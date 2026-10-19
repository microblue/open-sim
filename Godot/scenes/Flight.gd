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


func _ready() -> void:
	# Preferences first: the window mode and the mixer are in effect before the
	# first frame is drawn or the first note of menu music plays.
	Settings.ensure_loaded()
	Settings.apply_all()
	_apply_flight_settings()

	# A profile the pilot saved themselves always wins. Failing that, a radio we
	# recognise gets bound automatically a moment from now, once Godot has
	# finished enumerating joypads.
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
  1 / 2 / 3   pilot / chase / FPV camera
  Z           pilot-view zoom  1x -> 2x -> 4x    X  pilot-view auto-zoom on / off
  G           height cue (mark on the ground below the model) on / off
  right drag  look around
  R           reset (a new flight)   Shift+R  the same flight again (failure practice)
  F10         save the last two minutes as a CSV flight log
  F1          hide the telemetry overlay      F2  per-section detail
  F4          tuning panel (wind, weather, physics rate)
  M           menu       H   hangar (aircraft)   L  location (place, weather)
  O           settings   P   pause (also on losing window focus)
  Tab         replay the last two minutes
  4 5 6 7 8   dead stick / jammed aileron / elevator linkage / radio loss / brownout
  9           clear the failure
  F3          transmitter setup wizard
  F5          reload the aircraft definition  F6  cycle spawn mode
  Esc         quit
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
			get_node("ReplayBar").queue_free()
		KEY_R when event.shift_pressed:
			# The same flight again: with failure practice on, the same failure
			# at the same moment, to be flown until it is flown well.
			aircraft.set_failure_practice_repeat(true)
			aircraft.reset_state()
			aircraft.set_failure_practice_repeat(false)
			print("Reset: the same flight again.")
		KEY_R:
			aircraft.reset_state()
			print("Reset.")
		KEY_F10:
			_save_flight_log()
		KEY_F5:
			# Hot reload: edit the aircraft JSON, press F5, feel the difference.
			# This is the tuning loop, and it is why AircraftDefinition owns no
			# engine resources.
			if aircraft.reload_aircraft():
				aircraft.reset_state()
				print("Aircraft reloaded: %s" % aircraft.get_aircraft_name())
		KEY_F6:
			aircraft.spawn_mode = (aircraft.spawn_mode + 1) % 3
			aircraft.reset_state()
			print("Spawn mode: %s" % ["runway", "air", "approach"][aircraft.spawn_mode])
		KEY_F3:
			_open_wizard()
		KEY_M:
			_open_menu(false)
		KEY_H:
			_open_hangar()
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
		# next four seconds.
		KEY_4:
			aircraft.induce_failure(1, 0)      # dead stick
		KEY_5:
			aircraft.induce_failure(2, 0)      # jammed aileron
		KEY_6:
			aircraft.induce_failure(3, 1)      # elevator linkage gone
		KEY_7:
			aircraft.induce_failure(4, 0)      # radio loss
		KEY_8:
			aircraft.induce_failure(5, 0)      # brownout
		KEY_9:
			aircraft.clear_failures()
		KEY_ESCAPE:
			get_tree().quit()


## Watch it again. The recorder is always running, so there is nothing to start -
## and pressing R while a replay is open closes it and puts the pilot back on the
## live aircraft, because a replay is something you look at rather than somewhere
## you can fly from.
func _toggle_replay() -> void:
	if has_node("ReplayBar"):
		get_node("ReplayBar").queue_free()
		return
	var bar := ReplayScript.new()
	bar.name = "ReplayBar"
	bar.simulation_path = NodePath("../Aircraft")
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
	menu.wizard_requested.connect(_open_wizard)
	menu.tuning_requested.connect(_open_tuning)
	menu.settings_requested.connect(_open_settings)
	menu.fly_requested.connect(_fly_from_menu)
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
	return _screen_open() or has_node("PauseOverlay")


## The full-frame screens. The pause card owns the keyboard like they do, but
## not the frame - see _refresh_hud_visibility.
func _screen_open() -> bool:
	return has_node("MainMenu") or has_node("ControllerWizard") \
			or has_node("Hangar") or has_node("WorldScreen") \
			or has_node("LoadingScreen") or has_node("SettingsScreen")


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
func _fly_from_menu(stem: String, scene_id: String, weather_id: String) -> void:
	if _loading:
		return
	_loading = true
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
	overlay.tree_exited.connect(_refresh_hud_visibility, CONNECT_DEFERRED)
	add_child(overlay)
	_refresh_hud_visibility()
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
	# aircraft drives itself from the transmitter, so the only work here is the
	# one-shot search for a radio we already know how to bind.
	_check_profile_problem()

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
