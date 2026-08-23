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

var _checks: int = 0
var _failures: int = 0
var _sim: RCSimulationNode
var _input: RCInputNode
var _started: bool = false
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

	_sim.wind_speed_mps = 0.0
	_sim.turbulence_mps = 0.0
	_sim.gust_amplitude_mps = 0.0
	_sim.reset_state()
	_start_altitude = _sim.get_altitude_m()
	print("\n  free glide, elevator neutral, still air")


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

	_input.begin_capture(true)
	_input.end_capture()
	_check(not _input.bind_channel(RCInputNode.CHANNEL_AILERON, 0),
		"binding an unswept axis is refused")


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

	if _sim.get_simulated_time_s() < RUN_SECONDS:
		return false

	_finish()
	return true


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
	print("\n%d checks, %d failed" % [_checks, _failures])
	if _failures == 0:
		print("in-engine tests passed")
	quit(1 if _failures > 0 else 0)
