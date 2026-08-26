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
const AudioScript := preload("res://aircraft/Trainer1500/AircraftAudio.gd")

@onready var aircraft: RCSimulationNode = $Aircraft
@onready var transmitter: RCInputNode = $Transmitter
@onready var camera_rig: Node3D = $CameraRig
var director: Node

var _autobind_remaining: float = 0.0
var _autobind_pending: bool = false
var _last_profile_problem: String = ""


func _ready() -> void:
	# A profile the pilot saved themselves always wins. Failing that, a radio we
	# recognise gets bound automatically a moment from now, once Godot has
	# finished enumerating joypads.
	if transmitter.load_profile(CONTROLLER_PROFILE):
		print("Controller profile loaded.")
	else:
		_autobind_pending = true
		_autobind_remaining = AUTOBIND_TIMEOUT

	# The field is built in code so the whole scene stays in text files. It
	# reads the aircraft's wind, so the grass, the trees and the windsock all
	# agree with what the model is flying in.
	var field := FieldScript.new()
	field.name = "GrassField01"
	field.simulation_path = NodePath("../../Aircraft")
	$Field.add_child(field)

	# The world beyond the flying field: streamed terrain, generated from the
	# same height function the aircraft collides with, out to the horizon.
	var world := WorldScript.new()
	world.name = "World"
	world.simulation_path = NodePath("../../Aircraft")
	world.camera_path = NodePath("../../CameraRig")
	if not OS.has_environment("RC_NO_TERRAIN"):
		$Field.add_child(world)

	# What stands on that terrain: grass, scrub, trees, boulders. The circuit is
	# generated in full before the first frame; beyond it, cells stream.
	var detail := DetailScript.new()
	detail.name = "Detail"
	detail.simulation_path = NodePath("../../Aircraft")
	detail.camera_path = NodePath("../../CameraRig")
	if not OS.has_environment("RC_NO_DETAIL"):
		$Field.add_child(detail)

	# One place that knows how a scene preset and a weather state reach the
	# terrain, the sky, the light, the air and the ground.
	director = DirectorScript.new()
	director.name = "WorldDirector"
	director.simulation_path = NodePath("../Aircraft")
	director.field_path = NodePath("../Field")
	director.camera_path = NodePath("../CameraRig")
	add_child(director)
	# The camera rig asks the field how high the ground is, so it can refuse to
	# go under it.
	camera_rig.field_path = camera_rig.get_path_to(field)

	# The visible aircraft is generated from the flight model's own geometry, so
	# what the pilot sees is what is flying.
	var model := ModelScript.new()
	model.name = "Model"
	model.simulation_path = NodePath("..")
	aircraft.add_child(model)

	# Parented to the aircraft so distance, stereo placement and Doppler all
	# come out of how it is actually flying.
	var audio := AudioScript.new()
	audio.name = "Audio"
	audio.simulation_path = NodePath("..")
	aircraft.add_child(audio)

	var tuning := TuningScript.new()
	tuning.name = "TuningPanel"
	tuning.simulation_path = NodePath("../Aircraft")
	add_child(tuning)

	aircraft.reset_state()
	_print_help()

	# The main menu is the briefing room: the aeroplane, the place, the weather
	# and the radio are all chosen there before the first flight. It opens on
	# every cold start once the auto-bind attempt has resolved, bound or not -
	# one Enter flies, which keeps the "flying within seconds" promise while
	# making sure the choices are never invisible.
	if not _autobind_pending:
		_open_menu(true)


func _print_help() -> void:
	print("""
OpenRC Simulator
  1 / 2 / 3   pilot / chase / FPV camera
  Z           pilot-view zoom  1x -> 2x -> 4x
  right drag  look around
  R           reset
  F1          hide the telemetry overlay      F2  per-section detail
  F4          tuning panel (wind, weather, physics rate)
  M           menu       H   hangar (aircraft)   W  world (place, weather)
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

	match event.keycode:
		KEY_R when has_node("ReplayBar"):
			get_node("ReplayBar").queue_free()
		KEY_R:
			aircraft.reset_state()
			print("Reset.")
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
		KEY_W:
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
	add_child(screen)
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
	add_child(hangar)


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
	menu.fly_requested.connect(_fly_from_menu)
	# The HUD has nothing to say while the aeroplane is parked behind a menu,
	# and its panels showed through in the corners - a transmitter readout
	# bottom-left and a battery gauge bottom-right, both belonging to a flight
	# that is not happening. Hidden for as long as the menu is up.
	menu.tree_exited.connect(_refresh_hud_visibility, CONNECT_DEFERRED)
	add_child(menu)
	_refresh_hud_visibility()


## The HUD is visible only when no modal screen is. Asked as a question rather
## than set as a flag: the menu can hand straight over to the wizard, and a
## pair of show/hide calls would race - the menu leaving the tree after the
## wizard has entered it, and turning the HUD back on underneath.
func _refresh_hud_visibility() -> void:
	var hud: Node = get_node_or_null("FlightHUD")
	if hud == null:
		return
	# The tuning panel is deliberately not in this list: it slides in beside
	# the HUD to tune the aeroplane in flight, and the numbers it is tuning
	# against are the ones the HUD is showing.
	hud.visible = not (has_node("MainMenu") or has_node("ControllerWizard"))


## The menu's Fly button: one action, the whole sortie. The aircraft, the place
## and the weather are applied together, then the state is reset so the model
## starts on the ground in the world that was just chosen.
func _fly_from_menu(stem: String, scene_id: String, weather_id: String) -> void:
	if director != null:
		director.apply_scene(scene_id)
		director.apply_weather(weather_id)
	_fly_aircraft(stem)


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

	if _autobind_pending:
		_autobind_remaining -= delta
		if _try_autobind() or _autobind_remaining <= 0.0:
			_autobind_pending = false
			if not transmitter.is_connected():
				print("No transmitter detected. Plug one in and press F3 for the wizard.")
			# The briefing room opens whatever the radio situation is: the
			# choice of aeroplane, place and weather is never skipped.
			_open_menu(true)


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
