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
const WizardScript := preload("res://ui/ControllerWizard.gd")
const MenuScript := preload("res://ui/MainMenu.gd")
const TuningScript := preload("res://ui/TuningPanel.gd")
const ModelScript := preload("res://aircraft/Trainer1500/AircraftModel.gd")
const AudioScript := preload("res://aircraft/Trainer1500/AircraftAudio.gd")

@onready var aircraft: RCSimulationNode = $Aircraft
@onready var transmitter: RCInputNode = $Transmitter
@onready var camera_rig: Node3D = $CameraRig

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

	# Straight to the menu on a cold start, and straight past it once a
	# controller profile exists: the brief's requirement is to be flying within
	# seconds, every time after the first. When a known radio is plugged in that
	# holds on the very first start too, so the menu decision waits for the
	# auto-bind attempt to resolve.
	if not _autobind_pending and not transmitter.is_fully_bound():
		_open_menu()


func _print_help() -> void:
	print("""
OpenRC Simulator
  1 / 2 / 3   pilot / chase / FPV camera
  Z           pilot-view zoom  1x -> 2x -> 4x
  right drag  look around
  R           reset
  F1          hide the telemetry overlay      F2  per-section detail
  F4          tuning panel (wind, weather, physics rate)
  M           menu       F3  transmitter setup wizard
  F5          reload the aircraft definition  F6  cycle spawn mode
  Esc         quit
""")


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	match event.keycode:
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
			_open_menu()
		KEY_ESCAPE:
			get_tree().quit()


func _open_menu() -> void:
	if has_node("MainMenu"):
		return
	var menu := MenuScript.new()
	menu.name = "MainMenu"
	menu.input_path = NodePath("../Transmitter")
	menu.simulation_path = NodePath("../Aircraft")
	menu.wizard_requested.connect(_open_wizard)
	add_child(menu)


func _open_wizard() -> void:
	if has_node("ControllerWizard"):
		return
	var wizard := WizardScript.new()
	wizard.name = "ControllerWizard"
	wizard.input_path = NodePath("../Transmitter")
	wizard.finished.connect(_on_wizard_finished)
	add_child(wizard)


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
			if not transmitter.is_fully_bound():
				if not transmitter.is_connected():
					print("No transmitter detected. Plug one in and press F3 for the wizard.")
				_open_menu()


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
