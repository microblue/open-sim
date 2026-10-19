# Renders the settings screen, the warning chips and the height cue, so their
# layout can be looked at rather than assumed.
#
#   xvfb-run -a -s "-screen 0 1920x1080x24" \
#       godot --path Godot --resolution 1920x1080 --script res://tests/FeatureShots.gd
#
# Uses its own settings file, so it neither depends on nor changes the
# preferences of whoever runs it.
extends SceneTree

const Settings := preload("res://ui/Settings.gd")

var _flight: Node
var _n: int = 0
var _stage: int = 0
var _wait: int = 0
var _aircraft: RCSimulationNode
var _rig: Node3D


func _initialize() -> void:
	var path: String = "user://feature_shots_settings.cfg"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	OS.set_environment("RC_SETTINGS_PATH", path)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	_flight = load("res://scenes/Flight.tscn").instantiate()
	root.add_child(_flight)


func _shot(name: String) -> void:
	root.get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://shots/feature_%s.png" % name))
	print("  feature_%s" % name)


## Waits `frames` frames, then moves on to the next stage.
func _after(frames: int) -> bool:
	_wait += 1
	if _wait < frames:
		return false
	_wait = 0
	_stage += 1
	return true


func _process(_d: float) -> bool:
	_n += 1
	if _n < 40:
		return false
	match _stage:
		0:
			if _flight.get_node_or_null("MainMenu") != null and _after(40):
				_shot("menu_header")
				_flight._open_settings()
		1:
			if _after(30):
				_shot("settings")
				var screen: Node = _flight.get_node("SettingsScreen")
				screen._selected = 4
				screen._apply_choice(4, "fullscreen")
		2:
			if _after(20):
				_shot("settings_confirm")
				_flight.get_node("SettingsScreen")._close()
				Settings.set_value("display/units", "imperial")
				Settings.set_value("controls/stick_mode", 1)
				_flight._fly_from_menu("Trainer1500", _flight.director.scene_id,
						_flight.director.weather_id)
		3:
			if _flight._world_built and _after(30):
				_aircraft = _flight.get_node("Aircraft")
				_rig = _flight.get_node("CameraRig")
				# Low and close to the pilot: the height cue under the model.
				_aircraft.spawn_mode = RCSimulationNode.SPAWN_AIR
				_aircraft.spawn_altitude_m = 4.0
				_aircraft.spawn_offset = Vector3(-4, 0, -2)
				_aircraft.spawn_heading_deg = 270.0
				_aircraft.reset_state()
				_rig._set_mode(0)
		4:
			if _after(12):
				# A spotter's view from above and to one side, so the mark and
				# the model are both in frame; the pilot's own view follows.
				var model: Vector3 = _aircraft.global_position
				_rig.set_process(false)
				_rig.global_position = model + Vector3(9.0, 6.0, 9.0)
				_rig.look_at(Vector3(model.x, model.y * 0.5, model.z), Vector3.UP)
				(_rig.get_child(0) as Camera3D).fov = 50.0
		5:
			if _after(3):
				_shot("height_cue_spotter")
				_rig.set_process(true)
				_rig._set_mode(0)
		6:
			if _after(30):
				_shot("height_cue_near")
				# Far out and diving: FAR and LOW together, imperial, Mode 1.
				_aircraft.input_path = NodePath("")
				_aircraft.spawn_heading_deg = 0.0
				_aircraft.spawn_altitude_m = 16.0
				_aircraft.spawn_offset = Vector3(0, 0, -620)
				_aircraft.reset_state()
				_aircraft.set_manual_channel(RCInputNode.CHANNEL_ELEVATOR, -0.7)
				_aircraft.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 0.0)
		7:
			var hud: Node = _flight.get_node("FlightHUD")
			if hud._chips.has("low") and hud._chips.has("far") \
					and float(hud._chips["low"]["alpha"]) > 0.95:
				_shot("chips")
				_stage += 1
			elif _after(240):
				_shot("chips_timeout")
		8:
			# A key held while a screen closes must not fly the aeroplane.
			var down := InputEventKey.new()
			down.keycode = KEY_UP
			down.pressed = true
			Input.parse_input_event(down)
			_flight._open_settings()
			_stage += 1
		9:
			if _after(3):
				_flight.get_node("SettingsScreen")._close()
		10:
			if _after(3):
				var tx: RCInputNode = _flight.get_node("Transmitter")
				print("  held key after closing: keyboard enabled = %s (want false)"
						% tx.is_keyboard_enabled())
				var up := InputEventKey.new()
				up.keycode = KEY_UP
				up.pressed = false
				Input.parse_input_event(up)
		11:
			if _after(3):
				var tx: RCInputNode = _flight.get_node("Transmitter")
				print("  after release: keyboard enabled = %s (want true)"
						% tx.is_keyboard_enabled())
				_flight._pause("the window lost focus")
		12:
			if _after(5):
				_shot("paused")
				print("  paused = %s (want true)" % paused)
				_flight.get_node("PauseOverlay")._resume()
		13:
			if _after(3):
				print("  after resume: paused = %s (want false)" % paused)
				# Spun in from 25 m on purpose: the crash card has to explain it.
				_aircraft.spawn_offset = Vector3(-40, 0, -60)
				_aircraft.spawn_altitude_m = 25.0
				_aircraft.reset_state()
				_aircraft.set_manual_channel(RCInputNode.CHANNEL_ELEVATOR, 1.0)
				_aircraft.set_manual_channel(RCInputNode.CHANNEL_RUDDER, -1.0)
				_aircraft.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 0.0)
		14:
			var card: Node = _flight.get_node_or_null("FlightHUD/CrashCard")
			if card != null and float(card._alpha) >= 1.0:
				_shot("crash_card")
				print("  crash card: %s" % card._report.get("title", "?"))
				_stage += 1
			elif _after(900):
				_shot("crash_card_timeout")
		15:
			print("done")
			quit(0)
			return true
	return false
