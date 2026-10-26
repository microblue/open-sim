# OpenRC Simulator - in-engine test suite.
#
# The C++ validation suite (Tests/, run by ctest) covers the flight model in
# detail. This covers what it cannot reach: that the GDExtension loads, that the
# aircraft definition is found and parsed from inside the engine, that the
# fixed-step loop runs inside Godot's frame loop, and that values crossing the
# frame boundary arrive correct.
#
#   godot --headless --path Godot --script res://tests/HeadlessTests.gd
#
# Exit code 0 on success, 1 on any failure.
#
# NOTE: nodes added during _initialize() are not yet inside the tree - _ready()
# has not run and the transform API is invalid. Everything that touches a node
# therefore waits for the first _process() call.
extends SceneTree

const SPAWN_ALTITUDE: float = 200.0
const RUN_SECONDS: float = 15.0
const ModelScript := preload("res://aircraft/Trainer1500/AircraftModel.gd")

var _checks: int = 0
var _failures: int = 0
var _sim: RCSimulationNode
var _input: RCInputNode
var _started: bool = false
var _surface_model: Node3D
var _surface_start_s: float = -1.0
var _dive_start_s: float = -1.0
var _deepest_below_ground: float = -1e9
var _tree_start_s: float = -1.0
var _tree_debug_step: int = -1
var _start_altitude: float = 0.0
var _min_airspeed: float = 1e30
var _max_airspeed: float = 0.0


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("      FAIL  %s" % description)


func _check_range(value: float, low: float, high: float, description: String) -> void:
	_checks += 1
	if value < low or value > high:
		_failures += 1
		print("      FAIL  %s" % description)
		print("            value %.4f is outside [%.4f, %.4f]" % [value, low, high])


func _check_near(actual: float, expected: float, tolerance: float, description: String) -> void:
	_checks += 1
	var difference: float = absf(actual - expected)
	if not (difference <= tolerance):
		_failures += 1
		print("      FAIL  %s" % description)
		print("            actual %.8f  expected %.8f  tolerance %.8f"
			% [actual, expected, tolerance])


func _initialize() -> void:
	print("OpenRC Simulator - in-engine tests\n")

	_check(ClassDB.class_exists("RCSimulationNode"), "RCSimulationNode is registered")
	_check(ClassDB.class_exists("RCInputNode"), "RCInputNode is registered")

	_sim = RCSimulationNode.new()
	_sim.name = "Aircraft"
	_sim.physics_rate_hz = 240
	_sim.spawn_mode = RCSimulationNode.SPAWN_AIR
	_sim.spawn_altitude_m = SPAWN_ALTITUDE
	root.add_child(_sim)

	_input = RCInputNode.new()
	_input.name = "Transmitter"
	root.add_child(_input)


func _start() -> void:
	_started = true

	_test_aircraft_definition()
	_test_frame_conversion()
	_test_input_without_a_device()
	_test_wind()
	_test_reset()
	_test_audio()
	_test_settings_store()
	_test_warning_chips()
	_test_keyboard_mode()
	_test_context_hints()
	_test_hint_rules()
	_test_hud_phase()

	_sim.wind_speed_mps = 0.0
	_sim.turbulence_mps = 0.0
	_sim.gust_amplitude_mps = 0.0
	_sim.reset_state()
	_start_altitude = _sim.get_altitude_m()
	print("\n  free glide, elevator neutral, still air")


## Failure practice through the real node: at 100 % a flight in the air gets
## its failure after 20 to 120 s, and not before.
func _test_failure_practice() -> void:
	print("\n  failure practice")
	# Gravity off, so the model stays well up and flying on its own: this is
	# about WHEN the failure arrives, not about flying the aeroplane.
	_sim.set_gravity_enabled(false)
	_sim.spawn_mode = RCSimulationNode.SPAWN_AIR
	_sim.spawn_altitude_m = 120.0
	_sim.set_failure_practice(1.0, false, true)
	_sim.reset_state()
	var plan: Dictionary = _sim.get_failure_practice()
	_check(bool(plan["will_fail"]), "at 100 % the flight is drawn to fail")
	_check_range(float(plan["onset_s"]), 20.0, 120.0, "the failure is due 20 to 120 s in")
	_sim.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 0.55)
	run_for(maxf(float(plan["onset_s"]) - 2.0, 0.0))
	_check(not _sim.has_failure(), "nothing breaks before it is due")
	run_for(4.0)
	var after: Dictionary = _sim.get_failure_practice()
	_check(bool(after["triggered"]), "it arrives when due (%.1f s airborne)" % after["airborne_s"])
	_check(_sim.has_failure(), "and the aircraft has it")
	var seed: int = int(after["seed"])

	# The same flight again: same seed, same moment.
	_sim.set_failure_practice_repeat(true)
	_sim.reset_state()
	_sim.set_failure_practice_repeat(false)
	_check(int(_sim.get_failure_practice()["seed"]) == seed, "Shift+R flies the same flight")
	_sim.reset_state()
	_check(int(_sim.get_failure_practice()["seed"]) != seed, "R draws a new one")
	_check(int(_sim.get_failure_practice()["flights"]) >= 1, "flights that flew are scored")

	_sim.set_gravity_enabled(true)
	_sim.set_failure_practice(0.0, false, true)
	_sim.reset_failure_practice_stats()
	_sim.clear_failures()
	_sim.clear_manual_channels()
	_sim.reset_state()
	_check(not bool(_sim.get_failure_practice()["will_fail"]), "0 % turns it off")


## The hint bar says the one thing to do next, in the words of the controls in
## use - and nothing at all on a wreck.
func _test_context_hints() -> void:
	print("  what the hint bar says")
	var hints := load("res://ui/ContextHints.gd")
	var parked := {"input": "keyboard", "mode": 2, "on_ground": true, "airspeed": 0.0,
			"throttle": 0.0, "flown": false, "air_s": 0.0}
	var first: Array = hints.evaluate(parked)
	_check(first.size() == 1 and first[0]["keys"] == ["W"],
		"parked, Mode 2 keyboard: hold W to open the throttle")
	parked["mode"] = 1
	first = hints.evaluate(parked)
	_check(first.size() == 1 and first[0]["keys"] == ["UP"],
		"parked, Mode 1 keyboard: the up arrow is the throttle")
	var rolling := parked.duplicate()
	rolling["mode"] = 2
	rolling["airspeed"] = 8.0
	rolling["throttle"] = 1.0
	var roll: Array = hints.evaluate(rolling)
	_check(roll.size() == 2 and roll[1]["keys"] == ["DOWN"],
		"rolling: keep straight, then the down arrow lifts off")
	var radio := parked.duplicate()
	radio["input"] = "radio"
	radio["mode"] = 2
	radio["armed"] = false
	var arm: Array = hints.evaluate(radio)
	_check(arm.size() == 1 and String(arm[0]["text"]).find("left stick") >= 0,
		"an unarmed Mode 2 radio is told to close the left stick")
	var crashed := parked.duplicate()
	crashed["crashed"] = true
	_check(hints.evaluate(crashed).is_empty(), "no hint on a wreck")
	var up := {"input": "keyboard", "mode": 2, "on_ground": false, "flown": true,
			"air_s": 3.0, "airspeed": 14.0, "throttle": 0.6}
	_check(hints.evaluate(up).size() == 3, "just airborne: how to turn, climb and throttle")
	up["air_s"] = 60.0
	_check(hints.evaluate(up).is_empty(), "a minute in, the hints have gone")
	var landed := {"input": "keyboard", "mode": 2, "on_ground": true, "flown": true,
			"airspeed": 0.2, "throttle": 0.0}
	var after: Array = hints.evaluate(landed)
	_check(after.size() == 2 and after[0]["keys"] == ["R"], "landed: fly again or watch")


## The newer hint rules: far from home, lost in the pilot view, the landing
## script, too slow on the approach, the one-time view lesson, escalation and
## learning.
func _test_hint_rules() -> void:
	print("  hint rules: home, landing, escalation, learning")
	var hints := load("res://ui/ContextHints.gd")
	var ids := func(state: Dictionary) -> Array:
		return hints.evaluate(state).map(func(h: Dictionary) -> String: return h.get("id", ""))
	var cruise := {"input": "keyboard", "mode": 2, "on_ground": false, "flown": true,
			"air_s": 60.0, "airspeed": 15.0, "throttle": 0.6, "phase": "cruise",
			"view": "follow"}
	_check(hints.evaluate(cruise).is_empty(), "cruising near the field: no hint")

	# Far from home: past 150 m, and the hint names the distance and the side.
	var far := cruise.duplicate()
	far["distance_home"] = 151.0
	far["home_dir"] = "behind"
	var turn_back: Array = hints.evaluate(far)
	_check(turn_back.size() == 1 and turn_back[0]["id"] == "far"
			and turn_back[0].get("level", "") == "warn", "151 m out: turn back, in amber")
	_check(String(turn_back[0]["text"]).find("151 m behind you") >= 0,
			"the hint says how far and which way")
	far["distance_home"] = 149.0
	_check(ids.call(far).is_empty(), "149 m out: still close enough")
	far["distance_home"] = -1.0
	_check(ids.call(far).is_empty(), "no home known: no far hint")

	# Lost in the pilot view: more than 2 s out of frame.
	var lost := cruise.duplicate()
	lost["view"] = "pilot"
	lost["offscreen_s"] = 2.1
	var c: Array = hints.evaluate(lost)
	_check(c.size() == 1 and c[0]["keys"] == ["C"], "out of frame 2.1 s in the pilot view: press C")
	lost["offscreen_s"] = 1.9
	_check(ids.call(lost).is_empty(), "out of frame 1.9 s: not yet")
	lost["offscreen_s"] = 5.0
	lost["view"] = "follow"
	_check(ids.call(lost).is_empty(), "the follow view never says press C for the follow view")

	# The landing script.
	var land := cruise.duplicate()
	land["phase"] = "landing"
	land["height_m"] = 10.0
	land["air_mps"] = 12.0
	land["stall_mps"] = 7.0
	land["aligned"] = false
	_check(String(hints.evaluate(land)[0]["text"]).begins_with("Line up"),
			"landing, not lined up: line up with the runway")
	land["aligned"] = true
	var settle: Array = hints.evaluate(land)
	_check(settle.size() == 2 and settle[0]["keys"] == ["S"],
			"landing, lined up: throttle back, nose slightly down")
	land["height_m"] = 2.9
	var flare: Array = hints.evaluate(land)
	_check(flare.size() == 1 and flare[0]["keys"] == ["DOWN"]
			and String(flare[0]["text"]).find("flare") >= 0, "under 3 m: ease back to flare")
	land["height_m"] = 10.0
	land["air_mps"] = 7.0 * 1.14
	var slow: Array = hints.evaluate(land)
	_check(slow.size() == 1 and slow[0]["id"] == "slow" and slow[0].get("level", "") == "warn",
			"below 1.15 x the stall speed on the approach: too slow")
	land["air_mps"] = 7.0 * 1.16
	_check(ids.call(land) == ["land", "land"], "at 1.16 x the stall speed: not too slow")
	land["input"] = "radio"
	land["mode"] = 1
	land["height_m"] = 2.0
	_check(String(hints.evaluate(land)[0]["text"]).find("left stick") >= 0,
			"a Mode 1 radio flares with the left stick")

	# Teach C, once, when the HUD says it is due.
	var teach := cruise.duplicate()
	teach["teach_view"] = true
	var lesson: Array = hints.evaluate(teach)
	_check(lesson.size() == 1 and lesson[0]["id"] == "view" and lesson[0]["keys"] == ["C"],
			"the view lesson shows C")

	# Escalation: pulse at 6 s, the controls card line at 15 s.
	_check(hints.escalation(5.9) == 0 and hints.escalation(6.0) == 1
			and hints.escalation(15.0) == 2, "escalation steps at 6 s and 15 s")
	var parked := {"input": "keyboard", "mode": 2, "on_ground": true, "airspeed": 0.0,
			"throttle": 0.0, "flown": false}
	parked["stuck_s"] = 14.0
	_check(hints.evaluate(parked).size() == 1, "stuck 14 s: still one hint")
	parked["stuck_s"] = 15.0
	var help: Array = hints.evaluate(parked)
	_check(help.size() == 2 and help[1]["keys"] == ["H"] and int(help[1].get("line", 1)) == 2,
			"stuck 15 s: a second line offers H for all the controls")

	# Learning: a learned hint stops showing until the pilot is stuck 6 s.
	var learned := parked.duplicate()
	learned["stuck_s"] = 0.0
	learned["hint_mode"] = "learn"
	learned["learned"] = ["throttle"]
	_check(hints.evaluate(learned).is_empty(), "a learned hint is not offered up front")
	learned["stuck_s"] = 6.0
	_check(ids.call(learned) == ["throttle"], "it comes back once the pilot is stuck 6 s")
	learned["hint_mode"] = "always"
	learned["stuck_s"] = 0.0
	_check(ids.call(learned) == ["throttle"], "\"always\" ignores what has been learned")
	learned["hint_mode"] = "off"
	_check(hints.evaluate(learned).is_empty(), "\"off\" shows no lessons")
	var unarmed := learned.duplicate()
	unarmed["input"] = "radio"
	unarmed["armed"] = false
	_check(ids.call(unarmed) == ["arm"], "even off, an unarmed motor is explained")
	var far_learned := far.duplicate()
	far_learned["distance_home"] = 200.0
	far_learned["hint_mode"] = "learn"
	far_learned["learned"] = ["far", "turn", "throttle", "takeoff", "land", "view"]
	_check(ids.call(far_learned) == ["far"], "safety hints are never learned away")

	# The pure helper the HUD's learning rests on.
	var Store := preload("res://ui/Settings.gd")
	var path: String = "user://test_hint_settings.cfg"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	Store.load_from(path)
	_check(not Store.hint_learned("turn"), "a fresh pilot has learned nothing")
	for i in Store.HINT_LEARNED_AFTER:
		Store.hint_success("turn")
	_check(Store.hint_learned("turn"), "three successes and the turn hint is learned")
	Store.reset_hints()
	_check(not Store.hint_learned("turn"), "reset hints forgets it")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	Store.load_from(path)


## Which part of the flight the HUD thinks it is in, and what it shows there.
func _test_hud_phase() -> void:
	print("  HUD phase")
	var P := preload("res://ui/HudPhase.gd")
	_check(P.evaluate({}) == P.PARKED, "nothing known: parked")
	_check(P.evaluate({"on_ground": true, "ground_speed": 1.9}) == P.PARKED,
			"1.9 m/s on the wheels is parked")
	_check(P.evaluate({"on_ground": true, "ground_speed": 2.0}) == P.ROLL,
			"2.0 m/s on the wheels is the roll")
	_check(P.evaluate({"on_ground": true, "crashed": true}) == P.CRASHED, "a wreck is crashed")
	var air := {"on_ground": false, "air_s": 19.9, "height_m": 40.0, "sink_mps": 0.0,
			"throttle": 0.6, "distance_home": 50.0}
	_check(P.evaluate(air) == P.CLIMB, "19.9 s up: climb-out")
	air["air_s"] = 20.0
	_check(P.evaluate(air) == P.CRUISE, "20 s up: cruise")
	var land := {"on_ground": false, "air_s": 60.0, "height_m": 14.9, "sink_mps": 0.31,
			"throttle": 0.34, "distance_home": 119.0}
	_check(P.evaluate(land) == P.LANDING, "low, sinking, power off, near the field: landing")
	for key in ["height_m", "sink_mps", "throttle", "distance_home"]:
		var off: Dictionary = land.duplicate()
		off[key] = {"height_m": 15.0, "sink_mps": 0.3, "throttle": 0.35,
				"distance_home": 120.0}[key]
		_check(P.evaluate(off) == P.CRUISE, "landing needs %s on the right side" % key)
	var unknown: Dictionary = land.duplicate()
	unknown["distance_home"] = -1.0
	_check(P.evaluate(unknown) == P.CRUISE, "no field known: never landing")

	var parked: Dictionary = P.elements(P.PARKED, "standard", "follow", 1.0, 0.0)
	_check(not parked["speed"] and not parked["height"], "parked: no speed, no height")
	_check(parked["throttle"] and parked["battery"], "parked: throttle and battery")
	var roll: Dictionary = P.elements(P.ROLL, "standard")
	_check(roll["speed"] and not roll["height"], "rolling: speed, not height")
	var cruise: Dictionary = P.elements(P.CRUISE, "standard", "follow", 0.41, 81.0)
	_check(cruise["speed"] and cruise["height"], "cruise: speed and height")
	_check(not cruise["battery"], "airborne at 41 %: no battery")
	_check(P.elements(P.CRUISE, "standard", "follow", 0.39)["battery"],
			"airborne at 39 %: the battery shows")
	_check(not cruise["ring"], "follow view: no attitude ring in Standard")
	_check(P.elements(P.CRUISE, "standard", "pilot")["ring"], "pilot view: the ring shows")
	_check(not P.elements(P.CRUISE, "standard", "FPV")["ring"], "FPV: no ring")
	_check(cruise["home"], "81 m out in cruise: home indicator")
	_check(not P.elements(P.CRUISE, "standard", "follow", 1.0, 79.0)["home"],
			"79 m out: no home indicator")
	_check(not P.elements(P.CLIMB, "standard", "follow", 1.0, 200.0)["home"],
			"climb-out: no home indicator")
	var wreck: Dictionary = P.elements(P.CRASHED, "standard")
	_check(wreck["dim"] and not wreck["hints"] and not wreck["chips"],
			"crashed: dimmed, no hints, no chips")
	var detailed: Dictionary = P.elements(P.CRUISE, "detailed", "follow")
	_check(detailed["ring"] and detailed["engineering"] and detailed["battery"],
			"Detailed: ring always, engineering data, battery")
	var clean: Dictionary = P.elements(P.CRUISE, "clean", "pilot", 0.1, 500.0)
	_check(clean["speed"] and clean["height"], "Clean: speed and height")
	_check(not (clean["throttle"] or clean["battery"] or clean["ring"] or clean["home"]
			or clean["identity"] or clean["legend"] or clean["hints"]),
			"Clean: nothing else")


func _test_keyboard_mode() -> void:
	var input := RCInputNode.new()
	_check(input.get_keyboard_mode() == 2, "the keyboard starts in Mode 2")
	input.set_keyboard_mode(1)
	_check(input.get_keyboard_mode() == 1, "the keyboard can fly Mode 1")
	input.free()


## The preferences file. The two promises that matter are the ones a pilot
## would never notice until they were broken: an unreadable file is kept, not
## overwritten, and a file from a newer build is never downgraded.
func _test_settings_store() -> void:
	print("  settings store")
	var Store := preload("res://ui/Settings.gd")
	var path: String = "user://test_settings.cfg"
	var bad: String = path + ".bad"
	for stale in [path, bad]:
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(stale))

	# Missing file: defaults, and a save creates it.
	Store.load_from(path)
	_check(Store.get_value("controls/stick_mode") == 2, "stick mode defaults to Mode 2")
	_check(Store.get_value("display/units") == "si", "units default to what the HUD always showed")
	_check(not Store.is_read_only(), "a missing file is writable")

	# Round trip.
	Store.set_value("display/units", "imperial")
	Store.set_value("controls/stick_mode", 1)
	Store.set_value("audio/game_volume", 0.35)
	Store.set_value("interface/key_hints", false)
	_check(FileAccess.file_exists(path), "setting a value saves the file")
	Store.load_from(path)
	_check(Store.get_value("display/units") == "imperial", "units survive a reload")
	_check(Store.get_value("controls/stick_mode") == 1, "stick mode survives a reload")
	_check_near(float(Store.get_value("audio/game_volume")), 0.35, 1e-6,
			"volume survives a reload")
	_check(Store.get_value("interface/key_hints") == false, "a false bool survives a reload")
	var written := ConfigFile.new()
	written.load(path)
	_check(int(written.get_value("meta", "schema", -1)) == Store.SCHEMA_VERSION,
			"the file carries its schema version")

	# Hand-edited nonsense is coerced, not trusted.
	written.set_value("display", "units", "furlongs")
	written.set_value("audio", "menu_volume", 7.5)
	written.set_value("controls", "stick_mode", "two")
	written.save(path)
	Store.load_from(path)
	_check(Store.get_value("display/units") == "si", "an unknown unit falls back")
	_check_near(float(Store.get_value("audio/menu_volume")), 1.0, 1e-6,
			"an out-of-range volume is clamped")
	_check(Store.get_value("controls/stick_mode") == 2, "a mistyped stick mode falls back")

	# Corrupt: renamed to .bad, defaults used, and the next save is a fresh file.
	var corrupt := FileAccess.open(path, FileAccess.WRITE)
	corrupt.store_string("[display\nunits = \"imperial\n=== not a config file ===\n")
	corrupt.close()
	Store.load_from(path)
	_check(FileAccess.file_exists(bad), "an unreadable file is kept as settings.cfg.bad")
	_check(not FileAccess.file_exists(path), "the unreadable file is moved, not left in place")
	_check(Store.get_value("display/units") == "si", "an unreadable file gives defaults")
	_check(not Store.status().is_empty(), "an unreadable file is reported")
	var kept: String = FileAccess.get_file_as_string(bad)
	_check(kept.find("not a config file") >= 0, "the .bad file holds the original contents")

	# Newer schema: read what we understand, never write.
	var newer := ConfigFile.new()
	newer.set_value("meta", "schema", Store.SCHEMA_VERSION + 1)
	newer.set_value("display", "units", "metric")
	newer.set_value("future", "thing", 42)
	newer.save(path)
	var before: String = FileAccess.get_file_as_string(path)
	Store.load_from(path)
	_check(Store.is_read_only(), "a newer-schema file is opened read-only")
	_check(Store.get_value("display/units") == "metric", "a newer-schema file is still read")
	Store.set_value("display/units", "imperial")
	_check(not Store.save(), "saving over a newer-schema file is refused")
	_check(FileAccess.get_file_as_string(path) == before,
			"a newer-schema file is left byte for byte as it was")
	_check(Store.get_value("display/units") == "imperial",
			"a change still applies for the session")

	# Units, as the HUD will show them.
	_check(Store.format_speed(10.0, "metric")[0] == "36", "10 m/s is 36 km/h")
	_check(Store.format_speed(10.0, "imperial")[0] == "22", "10 m/s is 22 mph")
	_check(Store.format_speed(10.0, "si")[1] == "m/s", "SI speed is m/s")
	_check(Store.format_height(100.0, "imperial")[0] == "328", "100 m is 328 ft")
	_check(Store.format_climb(-1.0, "imperial") == "-197 ft/min", "1 m/s down is 197 ft/min")

	for stale in [path, bad]:
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(stale))
	# Back to defaults in memory, without touching the pilot's own file.
	Store.load_from(path)


## The warning chips are a pure function of a handful of numbers, so each rule
## can be stated as a number and checked on both sides of it.
func _test_warning_chips() -> void:
	print("  warning chips")
	var W := preload("res://ui/FlightWarnings.gd")
	var ids := func(state: Dictionary) -> Array:
		return W.evaluate(state).map(func(c: Dictionary) -> String: return c["id"])

	_check(ids.call({}).is_empty(), "nothing known, nothing shown")
	var cruising: Dictionary = {"airborne": true, "sink_mps": 0.5, "height_m": 40.0,
			"span_px": 80.0, "battery": 0.8, "has_battery": true}
	_check(ids.call(cruising).is_empty(), "a model in a normal circuit shows no chips")

	# LOW: sinking faster than 2 m/s AND under 2 s from the ground.
	var low: Dictionary = cruising.duplicate()
	low["sink_mps"] = 3.0
	low["height_m"] = 5.0
	_check(ids.call(low) == ["low"], "3 m/s down at 5 m is LOW (1.7 s)")
	low["height_m"] = 7.0
	_check(ids.call(low).is_empty(), "3 m/s down at 7 m is not LOW yet (2.3 s)")
	low["sink_mps"] = 1.9
	low["height_m"] = 1.0
	_check(ids.call(low).is_empty(), "a gentle 1.9 m/s flare is not LOW")
	low["sink_mps"] = 3.0
	low["airborne"] = false
	_check(ids.call(low).is_empty(), "on the wheels it is not LOW")
	var low_chip: Dictionary = W.evaluate({"airborne": true, "sink_mps": 4.0,
			"height_m": 2.0})[0]
	_check(low_chip["level"] == W.DANGER, "LOW is red")
	_check(String(low_chip["text"]).begins_with("LOW"), "LOW says LOW")

	# FAR: wingspan under 30 px at the narrowest zoom, and only when measured.
	var far: Dictionary = cruising.duplicate()
	far["span_px"] = 29.0
	_check(ids.call(far) == ["far"], "29 px of wingspan is FAR")
	far["span_px"] = -1.0
	_check(ids.call(far).is_empty(), "outside the pilot view there is no FAR")
	# 1.5 m at 300 m through 6 degrees on a 1080-line frame: about 52 px.
	_check_near(W.span_pixels(1.5, 300.0, 6.0, 1080.0), 51.6, 0.5,
			"span on screen is the subtended angle over the field")
	_check(W.span_pixels(1.5, 600.0, 6.0, 1080.0) < W.FAR_SPAN_PX,
			"a trainer at 600 m is FAR even at 6 degrees")

	# BATTERY: below a fifth, and only if there is a battery.
	var flat: Dictionary = cruising.duplicate()
	flat["battery"] = 0.19
	_check(ids.call(flat) == ["battery"], "19 % is BATTERY LOW")
	flat["battery"] = 0.21
	_check(ids.call(flat).is_empty(), "21 % is not")
	flat["battery"] = 0.0
	flat["has_battery"] = false
	_check(ids.call(flat).is_empty(), "no battery, no battery chip")

	# Several at once, in a fixed order; none on a wreck.
	var everything: Dictionary = {"airborne": true, "sink_mps": 5.0, "height_m": 3.0,
			"span_px": 10.0, "battery": 0.05, "has_battery": true}
	_check(ids.call(everything) == ["low", "far", "battery"], "chips stack in a fixed order")
	_check(W.evaluate(everything)[2]["text"] == "BATTERY CRITICAL"
			and W.evaluate(everything)[2]["level"] == W.DANGER, "5 % is BATTERY CRITICAL, red")
	var stall: Dictionary = cruising.duplicate()
	stall["stall"] = 0.10
	_check(ids.call(stall) == ["stall"], "10 % of the wing stalled is a STALL WARNING chip")
	stall["stall"] = 0.35
	_check(ids.call(stall).is_empty(), "35 % is the banner's, not a chip")
	stall["stall"] = 0.10
	stall["airborne"] = false
	stall["flying"] = false
	_check(ids.call(stall).is_empty(), "parked in a tailwind: no stall chip")
	everything["crashed"] = true
	_check(ids.call(everything).is_empty(), "a wreck shows no chips - the banner has it")


## The sound bank is generated, not shipped, so nothing catches a silent or
## clipped buffer except a check like this one. Silence in particular is easy to
## produce and impossible to notice until someone puts headphones on.
func _test_audio() -> void:
	print("  procedurally generated audio")
	var Bank := preload("res://audio/SoundBank.gd")

	var engine: AudioStreamWAV = Bank.engine()
	_check(engine.mix_rate == Bank.MIX_RATE, "engine loop mix rate")
	_check(engine.format == AudioStreamWAV.FORMAT_16_BITS, "engine loop is 16 bit")
	_check(engine.loop_mode == AudioStreamWAV.LOOP_FORWARD, "engine loop loops")
	_check(not engine.stereo, "engine loop is mono, so it can be positioned")

	# A whole number of cycles of the fundamental, or the loop clicks every time
	# it wraps - which at these lengths is several times a second.
	var frames: int = engine.data.size() / 2
	var cycles: float = float(frames) * Bank.REFERENCE_HZ / float(Bank.MIX_RATE)
	_check_near(cycles - roundf(cycles), 0.0, 1e-6,
		"engine loop is a whole number of cycles (%.4f)" % cycles)

	var engine_stats: Dictionary = _pcm_stats(engine.data)
	_check(engine_stats["peak"] > 0.25, "engine loop is not silent")
	_check(engine_stats["peak"] < 0.999, "engine loop leaves headroom")
	_check(engine_stats["rms"] > 0.05, "engine loop carries real level")

	for named in [["airflow", Bank.airflow()], ["ground roll", Bank.ground_roll()]]:
		var stream: AudioStreamWAV = named[1]
		var stats: Dictionary = _pcm_stats(stream.data)
		_check(stream.loop_mode == AudioStreamWAV.LOOP_FORWARD,
			"%s loops" % named[0])
		_check(stats["peak"] > 0.25 and stats["peak"] < 0.999,
			"%s is audible and unclipped" % named[0])

	var impact: AudioStreamWAV = Bank.impact()
	_check(impact.loop_mode == AudioStreamWAV.LOOP_DISABLED, "the crash does not loop")
	# It has to decay, or a crash leaves a tone hanging over the field.
	var impact_frames: int = impact.data.size() / 2
	var head: float = absf(impact.data.decode_s16(int(impact_frames * 0.05) * 2) / 32768.0)
	var tail: float = absf(impact.data.decode_s16(int(impact_frames * 0.95) * 2) / 32768.0)
	_check(head > tail * 4.0, "the crash decays (%.3f -> %.3f)" % [head, tail])


func _pcm_stats(data: PackedByteArray) -> Dictionary:
	var frames: int = data.size() / 2
	var peak: float = 0.0
	var sum_squares: float = 0.0
	for i in frames:
		var value: float = data.decode_s16(i * 2) / 32768.0
		peak = maxf(peak, absf(value))
		sum_squares += value * value
	return {"peak": peak, "rms": sqrt(sum_squares / maxf(float(frames), 1.0))}


func _test_aircraft_definition() -> void:
	print("  aircraft definition")
	_check(_sim.is_aircraft_loaded(), "the aircraft definition was found and parsed")
	_check(_sim.get_aircraft_name() == "Trainer 1500", "aircraft name")
	_check(_sim.get_section_count() == 0 or _sim.get_section_count() == 11,
		"eleven aerodynamic sections once forces have been evaluated")
	_check(_sim.get_section_name(0).begins_with("wing_"), "section names are exposed")


func _test_frame_conversion() -> void:
	print("  frame conversion through the engine")
	# NED -Z maps to Godot +Y with no scaling. This is the whole bridge in one
	# assertion, checked on the live node rather than in isolation.
	_check_near(_sim.global_position.y, _sim.get_altitude_m(), 1e-3,
		"node Y equals physics altitude")
	_check_near(_sim.global_position.x, 0.0, 1e-5, "node X starts at zero")
	_check_near(_sim.global_position.z, 0.0, 1e-5, "node Z starts at zero")


func _test_input_without_a_device() -> void:
	print("  input, no transmitter attached")
	_check(_input.get_channel_count() == 6, "six channels are exposed")
	_check(_input.get_channel_name(RCInputNode.CHANNEL_AILERON) == "AIL", "channel names")
	_check(not _input.is_fully_bound(), "an unconfigured device is not fully bound")

	# The safety property: with nothing connected every stick reads neutral and
	# the throttle is closed. Holding the last throttle value would teach the
	# wrong reflex.
	for i in _input.get_channels().size():
		_check_near(_input.get_channels()[i], 0.0, 1e-12,
			"channel %d is neutral with no device" % i)

	# With nothing plugged in the keyboard flies the model. Without this a
	# player who owns no radio has four dead controls and an aeroplane that
	# falls out of the sky, and the only thing the HUD offers them is a setup
	# wizard for the device they have not got. And while a menu is up it has
	# to stop, or arrowing down a list of aeroplanes feeds full up-elevator to
	# the model parked on the strip.
	# Both directions, because this suite runs on machines with a transmitter
	# plugged in and on machines without one. The first version asserted the
	# no-device case unconditionally and failed the moment a radio was
	# connected - which is the case it is meant to protect.
	_check(_input.is_using_keyboard() != _input.is_connected(),
		"the keyboard takes over exactly when no device is reporting")
	_input.set_keyboard_enabled(false)
	_check(not _input.is_using_keyboard(),
		"a menu can take the keyboard away from the model")
	_input.set_keyboard_enabled(true)
	# It takes over the CONTROLS, not the neutral position: no key held still
	# means sticks centred and the motor stopped, which is what the loop above
	# has just measured.

	_input.begin_capture(true)
	_input.end_capture()
	_check(not _input.bind_channel(RCInputNode.CHANNEL_AILERON, 0),
		"binding an unswept axis is refused")


## A downloaded airframe has to be the size the flight model thinks it is.
##
## The aerodynamics integrates lift over a wing of a declared span. A visible
## wing of any other size is lying about the aeroplane - and a downloaded model
## arrives at whatever scale its author left it, on this one about eight times
## too big, with a stray vertex in the undercarriage eleven hundred units out
## for good measure. So the fit is measured, here, against the definition.
## The roster is offered gentlest-first, and the aeroplane offered FIRST is one
## a beginner can actually learn on.
##
## The order of a list is a recommendation whether or not it was meant as one.
## Alphabetical order offered a short-coupled tail-dragging biplane at the top
## of a training simulator, and this is the check that stops that coming back
## the next time an aeroplane is added.
func _test_the_roster_is_offered_gentlest_first() -> void:
	print("  the order the roster is offered in")
	var ranking := load("res://ui/AircraftRanking.gd")
	var cards: Array = []
	var restore: String = _sim.aircraft_definition
	for stem in _sim.list_aircraft():
		_sim.aircraft_definition = "Data/Aircraft/%s.json" % stem
		if not _sim.reload_aircraft():
			continue
		cards.append({
			"name": _sim.get_aircraft_name(),
			"loading": _sim.get_wing_loading_pa(),
			"pw": _sim.get_power_to_weight_w_per_kg(),
			"performance": _sim.get_performance(),
			"hand_launched": _sim.is_hand_launched(),
			"nose_wheel": _sim.has_steerable_nose_wheel(),
		})
	_sim.aircraft_definition = restore
	_sim.reload_aircraft()

	_check(cards.size() >= 3, "there is a roster to order")
	if cards.size() < 3:
		return
	ranking.rank(cards)
	for card in cards:
		print("       %-14s %-16s %.3f" % [card["name"],
			  ranking.word(float(card["difficulty"])), card["learn_order"]])

	for i in range(1, cards.size()):
		_check(float(cards[i]["learn_order"]) >= float(cards[i - 1]["learn_order"]),
			"the roster is in order at position %d" % i)

	# The one offered first has to be flyable by someone who has never flown:
	# it must have wheels, and it must not be the twitchiest thing there.
	var first: Dictionary = cards[0]
	_check(not bool(first["hand_launched"]),
		"the aeroplane offered first can take off from the ground")
	_check(bool(first["nose_wheel"]),
		"the aeroplane offered first has a nose wheel, not a tailwheel")
	_check(float(first["difficulty"]) < 0.50,
		"the aeroplane offered first is a gentle one")


## Every downloaded airframe faces forwards.
##
## Checked across the WHOLE roster and without needing a propeller node, which
## is what let the Spitfire ship backwards twice: it names no parts, so the
## check that the propeller is at the front simply skipped it and said nothing.
##
## The wing is by a long way the widest thing on an aeroplane and it is in the
## front half of every aeroplane there has ever been. So the span, weighted
## along the length, has to land forward of centre.
func _test_every_airframe_faces_forwards() -> void:
	print("  which way the airframes face")
	var restore: String = _sim.aircraft_definition
	for stem in _sim.list_aircraft():
		_sim.aircraft_definition = "Data/Aircraft/%s.json" % stem
		if not _sim.reload_aircraft():
			continue
		var model: Node = ModelScript.new()
		model.name = "FacingModel"
		model.simulation_path = NodePath("..")
		_sim.add_child(model)
		model.call("_build")
		if model.call("is_airframe_loaded"):
			var balance: float = model.call("span_balance")
			if absf(balance - 0.5) > 0.06:
				print("       %-14s wing at %.3f along the length" % [stem, balance])
				_check(balance < 0.5,
					"%s faces forwards - its wing is in the front half" % stem)
			else:
				# Said out loud rather than quietly passed. A biplane's wing is
				# long-chorded and nearly central, so its span balance sits at
				# 0.53 whichever way round it is: this measure cannot see the
				# difference and it would be dishonest to imply it had.
				var fin: Vector2 = model.call("fin_reach")
				print("       %-14s wing at %.3f - too central to judge by;"
					% [stem, balance] + " fin reach %.2f nose / %.2f tail"
					% [fin.x, fin.y])
				_check(fin.y > fin.x * 1.2,
					"%s faces forwards - its fin is at the back" % stem)
		model.free()
	_sim.aircraft_definition = restore
	_sim.reload_aircraft()


func _test_airframe_is_fitted_to_the_definition() -> void:
	print("  downloaded airframes")
	var model: Node = ModelScript.new()
	model.name = "FitModel"
	model.simulation_path = NodePath("..")
	_sim.add_child(model)
	# The model builds on its first _process; force it now so this stays a
	# straight-line check rather than another deferred phase.
	model.call("_build")

	if not model.call("is_airframe_loaded"):
		print("       no airframe.glb for %s - generated aeroplane in use"
			% _sim.get_aircraft_name())
		model.queue_free()
		return

	var drawn: float = model.call("drawn_span_m")
	var declared: float = _sim.get_wingspan_m()
	print("       drawn %.3f m against a declared %.3f m" % [drawn, declared])
	# Ten per cent: the fit is measured from a vertex percentile, so a wingtip
	# light or a strut that reaches past the tip costs a few per cent. What it
	# must not be is the eight-times-too-big the file arrives at.
	_check(absf(drawn - declared) < declared * 0.10,
		"the downloaded airframe is drawn at the span the flight model uses")

	# And it must not be facing backwards. The span check cannot see that:
	# fitting a model along an axis and then measuring it along the same axis
	# proves the two agree, not that the axis is the span - which is how both
	# aeroplanes shipped fitted by their fuselage length, flying sideways,
	# with the check reading 1.500 m against 1.500 m throughout.
	var station: float = model.call("propeller_station_m")
	if is_finite(station):
		print("       propeller at %+.3f m along the aeroplane" % station)
		_check(station < -declared * 0.10,
			"the propeller is at the front of the aeroplane")
	else:
		# Said out loud rather than passed quietly: this aeroplane's model
		# names no propeller, so the strongest evidence about which way it
		# faces is not available and the fin rule is on its own.
		print("       this model names no propeller - nose direction rests on"
			+ " the fin rule alone")

	# The wing must be above the fuselage on a high-wing trainer, which is the
	# check that would have caught it flying inverted. Nothing else did: the
	# span was right, the propeller was at the front, and the aeroplane was
	# upside down.
	var wing: float = model.call("wing_height_m")
	print("       wing sits %+.3f m from the aeroplane's middle" % wing)
	_check(wing > 0.0, "the wing is above the fuselage, not below it")

	# And each cut aileron must be hinged to a section on ITS OWN side. Both
	# matched to the first aileron section in the file is a flaperon: it
	# deflects, it looks alive, and it teaches a student the opposite of what
	# their stick does.
	var stations: Vector2 = model.call("aileron_stations_m")
	print("       ailerons hinged at %+.3f m and %+.3f m spanwise"
		% [stations.x, stations.y])
	_check(stations.x < -0.05 and stations.y > 0.05,
		"each cut aileron is driven by a section on its own side")
	model.queue_free()


func _test_wind() -> void:
	print("  wind")
	# "Wind 270" blows from the west towards the east: +X in Godot, which is
	# the aircraft's right when it is heading north.
	_sim.wind_speed_mps = 5.0
	_sim.wind_direction_deg = 270.0
	_sim.turbulence_mps = 0.0
	_sim.gust_amplitude_mps = 0.0
	var wind: Vector3 = _sim.get_wind_vector()
	_check_near(wind.x, 5.0, 1e-6, "a westerly blows towards +X in Godot")
	_check_near(wind.y, 0.0, 1e-6, "steady wind has no vertical component")

	_sim.wind_direction_deg = 0.0
	_check_near(_sim.get_wind_vector().z, 5.0, 1e-6, "a northerly blows towards +Z")

	_sim.wind_speed_mps = 0.0


func _test_reset() -> void:
	print("  reset")
	_sim.reset_state()
	_check_near(_sim.get_simulated_time_s(), 0.0, 1e-12, "reset clears the clock")
	_check(_sim.get_total_steps() == 0, "reset clears the step count")
	_check_near(_sim.get_altitude_m(), SPAWN_ALTITUDE, 1e-6, "reset restores altitude")
	_check_near(_sim.get_ground_speed_mps(), 16.0, 0.5, "air start is at cruise speed")


func _process(_delta: float) -> bool:
	if not _started:
		_start()
		return false

	var airspeed: float = _sim.get_airspeed_mps()
	if airspeed > 0.0:
		_min_airspeed = minf(_min_airspeed, airspeed)
		_max_airspeed = maxf(_max_airspeed, airspeed)

	if _dive_start_s >= 0.0:
		_deepest_below_ground = maxf(_deepest_below_ground, _deepest_point_below_ground())
		# Long enough to dive from 40 m, hit, and settle.
		if _sim.get_simulated_time_s() - _dive_start_s < 12.0:
			return false
		_finish_dive()
		# Not `true`: returning true quits the tree, and the tree phase that
		# _finish_dive starts needs frames to run in.
		return false

	if _tree_start_s >= 0.0:
		var elapsed: float = _sim.get_simulated_time_s() - _tree_start_s
		# Let the aircraft reach steady level flight, then drop the tree under
		# it: the model is now inside the trunk, and the physics has to call
		# the crash before it can fly on. Placing the tree at the model's own
		# position is deliberate - the flight path of a trainer at throttle is
		# a curve, and this test is about the collision, not about hitting a
		# target with a static obstacle.
		if elapsed < 3.0:
			return false
		if _tree_debug_step == -1:
			_tree_debug_step = 0
			# The trunk, placed in front of the model at its own altitude: the
			# wing tip meets it edge-on, a centimetre a step, which is how a
			# real tree is hit. (Dropping a tree under the whole airframe
			# buried it 45 m deep and the contact solver, asked to push a
			# wreck out from that depth, launched it at 10^170 m/s.)
			var forward: Vector3 = -_sim.global_transform.basis.z.normalized()
			_sim.set_tree_obstacles(PackedFloat32Array([
				_sim.global_position.x + forward.x * 6.0,
				_sim.global_position.z + forward.z * 6.0,
				1.5, 40.0]))
		if elapsed < 9.0:
			return false
		_finish_tree()
		return true

	if _surface_start_s >= 0.0:
		# Half a second of held aileron: long enough for the roll to establish,
		# short enough that the aircraft has not rolled past ninety degrees.
		if _sim.get_simulated_time_s() - _surface_start_s < 0.5:
			return false
		_finish_control_surfaces()
		# Not `true`: returning true quits the tree, and the dive phase that
		# _finish_control_surfaces starts needs frames to run in.
		return false

	if _sim.get_simulated_time_s() < RUN_SECONDS:
		return false

	_finish()
	return false


func _finish() -> void:
	var dropped: float = _start_altitude - _sim.get_altitude_m()
	var forward: float = -_sim.global_position.z
	var glide: float = forward / maxf(dropped, 1e-6)
	var attitude: Vector3 = _sim.get_attitude_degrees()

	print("       forward %.1f m, down %.1f m  ->  %.2f : 1" % [forward, dropped, glide])
	print("       airspeed %.2f m/s   alpha %.2f deg   stalled %.0f%%"
		% [_sim.get_airspeed_mps(), _sim.get_alpha_degrees(),
		   _sim.get_stalled_fraction() * 100.0])
	print("       attitude  roll %.2f  pitch %.2f  yaw %.2f deg"
		% [attitude.x, attitude.y, attitude.z])
	print("       lift %.2f N   drag %.2f N   weight %.2f N"
		% [_sim.get_total_lift_n(), _sim.get_total_drag_n(), 1.35 * 9.80665])
	print("")

	_check(_sim.is_aircraft_loaded(), "the aircraft is still loaded")
	_check(_sim.get_section_count() == 11, "eleven sections were evaluated")

	# It must GLIDE, not fall. A ballistic trajectory over 15 s from 200 m would
	# be long gone; a working flight model trades height for distance.
	_check(dropped > 0.0, "it descends")
	_check_range(glide, 3.0, 12.0, "free glide ratio")
	_check_range(_sim.get_airspeed_mps(), 6.0, 30.0, "airspeed stays plausible")
	_check_range(_min_airspeed, 5.0, 30.0, "airspeed never collapsed")
	_check_range(_max_airspeed, 6.0, 40.0, "airspeed never ran away")

	# Lift must be within reach of the weight in a steady glide.
	_check_range(_sim.get_total_lift_n(), 8.0, 20.0, "lift is of the order of the weight")
	_check(_sim.get_total_drag_n() > 0.0, "drag is positive")

	# A stable trainer released hands-off phugoids but does not tumble.
	_check_range(attitude.x, -25.0, 25.0, "roll stays bounded")
	_check_range(attitude.y, -45.0, 45.0, "pitch stays bounded")
	_check_range(attitude.z, -25.0, 25.0, "yaw stays bounded")
	_check(absf(_sim.get_alpha_degrees()) < 25.0, "angle of attack stays bounded")

	# Per-section telemetry, which the debug view depends on.
	var any_named: bool = false
	for i in _sim.get_section_count():
		var alpha: float = _sim.get_section_alpha_degrees(i)
		_check(absf(alpha) < 90.0, "section %d angle of attack is sane" % i)
		var separation: float = _sim.get_section_separation(i)
		_check(separation >= 0.0 and separation <= 1.0,
			"section %d separation fraction is a fraction" % i)
		if _sim.get_section_name(i).length() > 0:
			any_named = true
	_check(any_named, "sections are named")

	# Propulsion telemetry must be live and physical even with the throttle shut.
	_check_near(_sim.get_rpm(), 0.0, 1.0, "the propeller is stopped with no throttle")
	_check_near(_sim.get_thrust_n(), 0.0, 0.1, "no thrust with no throttle")
	_check_range(_sim.get_battery_charge(), 0.99, 1.0, "the battery is still full")
	_check_range(_sim.get_bus_voltage_v(), 10.0, 13.0, "3S bus voltage")

	_check(_sim.get_dropped_steps() == 0, "no physics steps were dropped")
	_check(_sim.get_total_steps() >= int(RUN_SECONDS * 240.0), "240 Hz was sustained")

	print("  steps: %d  dropped: %d  sim time: %.3f s"
		% [_sim.get_total_steps(), _sim.get_dropped_steps(), _sim.get_simulated_time_s()])

	_begin_control_surface_phase()


## The visible control surfaces must move the way the flight model deflected
## them. A wrong hinge sign is invisible to every physics test - the aircraft
## still flies correctly, it just shows the pilot the opposite of what it is
## doing - so the two are pinned together: command a right roll, then assert
## both that the aircraft rolls right and that the right aileron came up.
##
## It runs as a second phase rather than inline because the simulation is
## stepped by the scene tree, so the aircraft needs real frames to respond.
func _begin_control_surface_phase() -> void:
	print("\n  control surfaces follow the flight model")

	_surface_model = ModelScript.new()
	_surface_model.name = "SurfaceModel"
	# The GENERATED aeroplane, explicitly. It is the only one with hinged
	# control surfaces - a downloaded airframe is one mesh - and this test is
	# about the hinges, not about which aircraft happen to have models today.
	_surface_model.prefer_generated = true
	_surface_model.simulation_path = NodePath("..")
	_sim.add_child(_surface_model)

	_sim.reset_state()
	_sim.set_manual_channel(RCInputNode.CHANNEL_AILERON, 1.0)
	_surface_start_s = _sim.get_simulated_time_s()


func _finish_control_surfaces() -> void:
	var right: Node3D = _surface_model.get_node_or_null("hinge_wing_right_4_tip")
	var left: Node3D = _surface_model.get_node_or_null("hinge_wing_left_4_tip")
	_check(right != null and left != null, "aileron hinges exist as separate nodes")

	if right != null and left != null:
		_check(absf(right.rotation.x) > deg_to_rad(2.0),
			"the aileron deflected (%.1f deg)" % rad_to_deg(right.rotation.x))
		_check(signf(right.rotation.x) != signf(left.rotation.x),
			"the ailerons deflect in opposite directions")

		# Trailing edge of each surface in world space. A right roll puts the
		# right aileron up and the left one down.
		var index: int = _section_index("wing_right_4_tip")
		var chord: float = _sim.get_section_chord_m(index) \
			* _sim.get_section_control_chord_fraction(index)
		# Measured in the aircraft's own frame, not the world's. By this point it
		# is rolling, and a rolled attitude moves the wing tips far more than an
		# aileron ever does - in world space the attitude would swamp the very
		# thing being measured.
		var right_edge: Vector3 = right.transform * Vector3(0.0, 0.0, chord)
		var left_edge: Vector3 = left.transform * Vector3(0.0, 0.0, chord)
		print("       trailing edge above hinge, body frame:  right %+.4f m   left %+.4f m"
			% [right_edge.y - right.position.y, left_edge.y - left.position.y])
		_check(right_edge.y > left_edge.y,
			"right aileron up, left aileron down for a right roll command")

	# And the aircraft must be rolling the way the surfaces say it is.
	# get_attitude_degrees().x is roll, the same component the glide test reports.
	var roll: float = _sim.get_attitude_degrees().x
	var rates: Vector3 = _sim.get_angular_velocity_degrees()
	print("       roll %+.1f deg   body rates %+.1f %+.1f %+.1f deg/s"
		% [roll, rates.x, rates.y, rates.z])
	_check(roll > 5.0, "the aircraft has rolled right")

	# Every surface the definition declares must exist in the model, or a pilot
	# would be watching an aircraft with a missing control.
	var hinges: int = 0
	for child in _surface_model.get_children():
		if str(child.name).begins_with("hinge_"):
			hinges += 1
	# Four aileron panels (the ailerons span the outer two sections of each
	# wing), two elevator halves and the rudder.
	_check(hinges == 7, "seven hinged surfaces are built from the definition")

	_sim.clear_manual_channels()
	_surface_model.queue_free()
	_surface_model = null
	_begin_dive_phase()


## Fly it into the ground and make sure it stays on top of it.
##
## The landing gear holds the aircraft up while it is the right way up and
## rolling, and CrashModel noticed when something else touched - but nothing
## acted on that, so the body carried on integrating and sank out of sight. A
## check that only looks at altitude would not catch it either: the CG can be
## above ground while a wing is metres under.
func _begin_dive_phase() -> void:
	print("\n  flying it into the ground")
	_sim.reset_state()
	_sim.spawn_mode = RCSimulationNode.SPAWN_AIR
	_sim.spawn_altitude_m = 40.0
	_sim.reset_state()
	# Full down elevator and power: the steepest arrival the model can make.
	_sim.set_manual_channel(RCInputNode.CHANNEL_ELEVATOR, -1.0)
	_sim.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 1.0)
	_dive_start_s = _sim.get_simulated_time_s()
	_deepest_below_ground = -1e9


## Lowest point of the airframe, relative to the ground, in metres. Positive
## means buried.
func _deepest_point_below_ground() -> float:
	var deepest: float = -1e9
	for i in _sim.get_section_count():
		var world: Vector3 = _sim.to_global(_sim.get_section_position(i))
		deepest = maxf(deepest, -world.y)
	return deepest


func _finish_dive() -> void:
	print("       deepest any part of the airframe went below ground: %+.3f m"
		% _deepest_below_ground)
	print("       resting altitude %.3f m, speed %.2f m/s, crashed=%s"
		% [_sim.get_altitude_m(), _sim.get_airspeed_mps(), _sim.has_crashed()])

	_check(_sim.has_crashed(), "flying it into the ground counts as a crash")

	# And it says why. A full-power dive is not a stall and not a landing.
	var report: Dictionary = _sim.get_crash_report()
	print("       why: %s - %s" % [report.get("title", "?"), report.get("detail", "")])
	_check(not String(report.get("title", "")).is_empty(), "a crash comes with a reason")
	_check(not String(report.get("advice", "")).is_empty(), "and with advice")
	_check(["spiral_dive", "flew_into_ground"].has(String(report.get("cause", ""))),
		"a powered dive into the ground is called a dive, not a stall (%s)"
		% report.get("cause", ""))

	# The recording that explained it can be saved for a spreadsheet.
	var log_path: String = ProjectSettings.globalize_path("user://headless_flight_log.csv")
	_check(_sim.save_flight_log(log_path), "the flight log is written")
	var csv: String = FileAccess.get_file_as_string(log_path)
	_check(csv.begins_with("time_s,north_m,"), "the flight log has its header")
	_check(csv.count("\n") > 100, "the flight log holds the flight")
	DirAccess.remove_absolute(log_path)

	# The number that matters. A section centre a few centimetres under is the
	# solver leaving its deliberate sliver plus half a wing thickness; metres
	# under is the aircraft falling through the world.
	_check(_deepest_below_ground < 0.25,
		"no part of the airframe ends up buried (%.3f m)" % _deepest_below_ground)

	# And it comes to rest rather than sliding away or sinking slowly.
	_check(_sim.get_airspeed_mps() < 3.0, "the wreck comes to rest")
	_check(_sim.get_altitude_m() > -1.0, "the wreck is not underground")

	_sim.clear_manual_channels()

	# ------------------------------------------------------------------ trees --
	# A tree is solid: fly the model into one and it has to crash, with the
	# crash naming the tree rather than the ground. The obstacle is placed a
	# fixed distance ahead of the spawn point, tall and wide enough that the
	# model cannot pass over or around it.
	print("\n  flying it into a tree")
	var spawn := _sim.global_position
	# Tall and wide enough that climbing or drifting cannot clear it: a full
	# throttle trainer balloons to 50 m in the time it takes to reach the tree,
	# and it drifts a few degrees off the line.
	_sim.spawn_mode = RCSimulationNode.SPAWN_AIR
	_sim.spawn_altitude_m = 10.0
	_sim.reset_state()
	_sim.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 0.5)
	_dive_start_s = -1.0
	_tree_start_s = _sim.get_simulated_time_s()


func _finish_tree() -> void:
	_check(_sim.has_crashed(), "flying into a tree counts as a crash")
	_check(_sim.get_crash_reason().find("tree") >= 0,
		   "the crash names the tree, not the ground")
	# The impact speed is the number that says the collision was real: a sane
	# arrival speed, not a solver artefact. (The first version of this test
	# dropped the tree under the whole airframe, buried it 45 m deep, and the
	# contact solver reported 10^170 m/s.)
	var impact: float = _sim.get_airspeed_mps()
	print("       crashed=%s  reason='%s'  impact %.2f m/s"
		% [_sim.has_crashed(), _sim.get_crash_reason(), impact])
	_check(impact < 30.0, "the impact speed is sane (%.2f m/s)" % impact)

	_sim.clear_manual_channels()
	_sim.set_tree_obstacles(PackedFloat32Array())

	_test_failures()

	# Last, because by now the recorder holds a whole flight with a crash in it,
	# which is exactly what a replay has to be able to show.
	_test_replay()
	# Last: building an aeroplane out of a 3.5 MB glb costs frames, and the
	# section above asserts that no physics step was dropped.
	_test_the_roster_is_offered_gentlest_first()
	_test_every_airframe_faces_forwards()
	_test_airframe_is_fitted_to_the_definition()
	# After everything: it resets the aircraft, which clears the recording the
	# replay check reads, and flies a minute synchronously.
	_test_failure_practice()

	print("\n%d checks, %d failed" % [_checks, _failures])
	if _failures == 0:
		print("in-engine tests passed")
	quit(1 if _failures > 0 else 0)


## Failures, through the whole stack rather than in isolation: the unit tests
## say the model breaks the right channel, this says the aeroplane behaves
## accordingly - that a dead stick leaves a controllable glider, and that a
## jammed aileron actually keeps rolling it.
func _test_failures() -> void:
	print("\n  failures")

	_sim.clear_failures()
	_sim.spawn_mode = RCSimulationNode.SPAWN_AIR
	_sim.spawn_altitude_m = 120.0
	_sim.reset_state()
	_sim.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 0.85)

	# Under power it climbs or holds height.
	run_for(1.5)
	var powered_rpm: float = _sim.get_rpm()
	_check(powered_rpm > 1000.0, "the motor is running (%.0f rpm)" % powered_rpm)

	# Dead stick.
	_sim.induce_failure(1, 0)
	_check(_sim.has_failure(), "the failure takes")
	_check(_sim.get_failure_text().find("DEAD STICK") >= 0,
		"the pilot is told what went wrong")

	run_for(0.6)
	_check(_sim.get_rpm() < powered_rpm * 0.5,
		"the motor stops (%.0f rpm)" % _sim.get_rpm())
	_check(_sim.get_thrust_n() < 0.5, "and the thrust with it (%.2f N)" % _sim.get_thrust_n())

	# But the controls still work, which is the whole point of a dead stick.
	_sim.set_manual_channel(RCInputNode.CHANNEL_AILERON, 1.0)
	var roll_before: float = _sim.get_attitude_degrees().x
	run_for(0.8)
	var rolled: float = _sim.get_attitude_degrees().x - roll_before
	_check(absf(rolled) > 3.0,
		"the controls still answer with the motor dead (%.1f deg)" % rolled)

	# Jammed aileron: centring the stick does nothing and it keeps rolling.
	_sim.clear_failures()
	_sim.reset_state()
	_sim.set_manual_channel(RCInputNode.CHANNEL_AILERON, 0.8)
	run_for(0.5)
	_sim.induce_failure(2, 0)          # jam the aileron where it is
	_sim.set_manual_channel(RCInputNode.CHANNEL_AILERON, 0.0)   # pilot centres it
	var jam_before: float = _sim.get_attitude_degrees().x
	run_for(0.8)
	var still_rolling: float = _sim.get_attitude_degrees().x - jam_before
	_check(absf(still_rolling) > 3.0,
		"a jammed aileron keeps rolling with the stick centred (%.1f deg)" % still_rolling)

	_sim.clear_failures()
	_sim.clear_manual_channels()
	_sim.reset_state()

	# Leave a flight in the recorder for the replay test that follows. The
	# resets above cleared it, deliberately - a replay must not run across one.
	_sim.spawn_mode = RCSimulationNode.SPAWN_AIR
	_sim.spawn_altitude_m = 200.0
	_sim.reset_state()
	run_for(14.0)


## Run the simulation forward, synchronously.
##
## These tests are called from _process, so they cannot yield to let the scene
## tree step the physics. RCSimulationNode.advance() is what _process itself
## calls, so this is the same code path at the same fixed rate.
func run_for(seconds: float) -> void:
	var step: float = 1.0 / 60.0
	var steps: int = int(seconds / step)
	for i in steps:
		_sim.advance(step)


## The recorder has been running through every phase above, so by now it holds
## a real flight with a real crash in it. This checks the thing a replay has to
## get right: that scrubbing to a time shows what the aircraft was doing then,
## and that leaving the replay puts the live aircraft back exactly as it was.
func _test_replay() -> void:
	print("\n  replay")

	var duration: float = _sim.get_replay_duration()
	_check(duration > 5.0, "the recorder holds a flight (%.1f s)" % duration)
	if duration <= 5.0:
		return

	var live_position: Vector3 = _sim.global_position
	var live_altitude: float = _sim.get_altitude_m()

	_sim.set_replaying(true)
	_check(_sim.get_replaying(), "replay engages")

	# Scrub to three points and check the aircraft is somewhere different at
	# each - a replay that shows one frame whatever you ask for is worse than
	# none, because it looks like it is working.
	var first: float = _sim.get_replay_earliest()
	var last: float = _sim.get_replay_latest()
	var seen: Array[Vector3] = []
	for fraction in [0.1, 0.5, 0.9]:
		_sim.set_replay_time(first + (last - first) * fraction)
		# One frame for the pose to be applied.
		_sim.advance_replay(1.0 / 60.0)
		seen.append(_sim.global_position)

	_check(seen[0].distance_to(seen[1]) > 1.0, "scrubbing moves the aircraft")
	_check(seen[1].distance_to(seen[2]) > 1.0, "and keeps moving it")

	# The telemetry of the frame being shown has to be the telemetry of that
	# moment, not of the live aircraft.
	_sim.set_replay_time(first + (last - first) * 0.5)
	var frame: Dictionary = _sim.get_replay_frame()
	_check(frame.has("airspeed") and frame.has("altitude"),
		"the replay reports the telemetry of the frame")
	_check(frame["airspeed"] >= 0.0 and frame["airspeed"] < 60.0,
		"replayed airspeed is plausible (%.1f m/s)" % frame["airspeed"])

	# Time runs when it is playing.
	_sim.set_replay_speed(1.0)
	var before: float = _sim.get_replay_time()
	for i in 12:
		_sim.advance_replay(1.0 / 60.0)
	_check(_sim.get_replay_time() > before, "playback advances")

	# And the path is available to draw.
	var path: PackedVector3Array = _sim.get_flight_path(64)
	_check(path.size() > 8, "the flight path can be drawn (%d points)" % path.size())

	# Leaving must restore the live aircraft exactly. A replay is something you
	# look at, not somewhere you can fly from.
	_sim.set_replaying(false)
	_check(not _sim.get_replaying(), "replay disengages")
	_check(_sim.global_position.distance_to(live_position) < 0.01,
		"the live aircraft is put back where it was")
	_check(absf(_sim.get_altitude_m() - live_altitude) < 0.01,
		"at the altitude it was at")


func _section_index(section_name: String) -> int:
	for i in _sim.get_section_count():
		if _sim.get_section_name(i) == section_name:
			return i
	return 0
