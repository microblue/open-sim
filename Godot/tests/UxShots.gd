# Renders the player's journey through the interface, in order, so its
# layout can be looked at: first-run setup, the Fly hub, help, the guided first
# flight, the flight overlay in each phase, pause, a crash, the transmitter
# wizard and settings.
#
#   xvfb-run -a -s "-screen 0 1920x1080x24" \
#       godot --path Godot --resolution 1920x1080 --script res://tests/UxShots.gd
#
# Writes res://shots/ux_NN_<name>.png. Uses its own settings file, so it
# neither depends on nor changes the preferences of whoever runs it.
extends SceneTree

const Settings := preload("res://ui/Settings.gd")

var _flight: Node
var _n: int = 0
var _stage: int = 0
var _wait: int = 0
var _count: int = 0
var _aircraft: RCSimulationNode
var _rig: Node3D


func _initialize() -> void:
	var path: String = "user://ux_shots_settings.cfg"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	OS.set_environment("RC_SETTINGS_PATH", path)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	_flight = load("res://scenes/Flight.tscn").instantiate()
	root.add_child(_flight)


func _shot(name: String) -> void:
	_count += 1
	var file: String = "ux_%02d_%s" % [_count, name]
	root.get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://shots/%s.png" % file))
	print("  %s" % file)


func _after(frames: int) -> bool:
	_wait += 1
	if _wait < frames:
		return false
	_wait = 0
	_stage += 1
	return true


func _welcome() -> Node:
	return _flight.get_node_or_null("Welcome")


func _ready_to_fly() -> bool:
	return _flight._world_built and not _flight._loading \
			and _flight.get_node_or_null("LoadingScreen") == null


func _air(altitude: float, offset: Vector3 = Vector3.ZERO) -> void:
	_aircraft.input_path = NodePath("")
	_aircraft.spawn_mode = RCSimulationNode.SPAWN_AIR
	_aircraft.spawn_altitude_m = altitude
	_aircraft.spawn_offset = offset
	_aircraft.reset_state()


func _process(_d: float) -> bool:
	_n += 1
	if _n < 40:
		return false
	match _stage:
		0:
			if _flight.get_node_or_null("MainMenu") != null and _after(30):
				_flight._open_controls(true)
		1:
			if _after(20):
				_shot("setup_how_you_fly")
				_welcome()._next()                 # keyboard is preselected: no radio
		2:
			if _after(20):
				_shot("setup_try_the_keys")
				var w: Node = _welcome()
				w._use_radio = true
				w._enter(w.Page.RADIO)
		3:
			if _after(20):
				_shot("setup_radio_waiting")
				_welcome()._radio_wait = 11.0
		4:
			if _after(20):
				_shot("setup_radio_troubleshooting")
				_welcome()._finish(true, false)    # "Skip to the main menu"
		5:
			if _flight.get_node_or_null("Welcome") == null and _after(40):
				_shot("menu_hub")
				var menu: Node = _flight.get_node_or_null("MainMenu")
				if menu != null:
					menu._set_step(0)
		6:
			if _after(30):
				_shot("menu_pick_aircraft")
				var menu: Node = _flight.get_node_or_null("MainMenu")
				if menu != null:
					menu._set_step(3)
				_flight._open_help()
		7:
			if _after(20):
				_shot("help_keyboard")
				_flight.get_node("HelpOverlay")._tab = 1
		8:
			if _after(10):
				_shot("help_transmitter")
				_flight.get_node("HelpOverlay")._close()
				_flight._start_first_flight()
		9:
			if _ready_to_fly() and _after(90):
				_shot("first_flight_runway")
				_aircraft = _flight.get_node("Aircraft")
				_rig = _flight.get_node("CameraRig")
				_flight._fly_from_menu("Trainer1500", _flight.director.scene_id,
						_flight.director.weather_id, {"spawn": "runway", "mode": "free"})
		10:
			if _ready_to_fly() and _after(60):
				_aircraft = _flight.get_node("Aircraft")
				_rig = _flight.get_node("CameraRig")
				_shot("flight_parked")
				_air(30.0)
				_aircraft.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 0.6)
				_aircraft.set_manual_channel(RCInputNode.CHANNEL_AILERON, 0.04)
		11:
			if _after(90):
				_shot("flight_follow")
				print("    follow: crashed=%s %s alt=%.1f agl=%.1f" % [_aircraft.has_crashed(),
						_aircraft.get_crash_reason(), _aircraft.get_altitude_m(),
						_aircraft.get_height_above_ground_m()])
				# Far out in the pilot's view: brackets, then out of frame.
				_rig._set_mode(0)
				_air(40.0, Vector3(0, 0, -420))
				_aircraft.set_manual_channel(RCInputNode.CHANNEL_AILERON, 0.0)
		12:
			if _after(40):
				_shot("pilot_far")
				_rig.set("_look_offset", Vector2(0.9, 0.0))
		13:
			if _after(10):
				_shot("locator_arrow")
				_rig.set("_look_offset", Vector2.ZERO)
				_rig._set_mode(1)
				_flight._pause("paused")
		14:
			if _after(15):
				_shot("pause_menu")
				_flight.get_node("PauseOverlay")._resume()
		15:
			if _after(5):
				# Nose straight down from low height: a crash, and its card.
				_air(18.0)
				_aircraft.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 0.0)
				_aircraft.set_manual_channel(RCInputNode.CHANNEL_ELEVATOR, -1.0)
		16:
			if _aircraft.has_crashed() and _after(90):
				_shot("crash_card")
				_aircraft.set_manual_channel(RCInputNode.CHANNEL_ELEVATOR, 0.0)
				_flight._open_wizard()
		17:
			if _after(20):
				_shot("wizard_detect")
				_flight.get_node("ControllerWizard").queue_free()
				_flight._open_settings()
		18:
			if _after(20):
				_shot("settings")
				_flight.get_node("SettingsScreen")._close()
		19:
			print("done")
			quit(0)
			return true
	return false
