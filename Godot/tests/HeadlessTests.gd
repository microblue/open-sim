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

	_sim.wind_speed_mps = 0.0
	_sim.turbulence_mps = 0.0
	_sim.gust_amplitude_mps = 0.0
	_sim.reset_state()
	_start_altitude = _sim.get_altitude_m()
	print("\n  free glide, elevator neutral, still air")


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

	print("\n%d checks, %d failed" % [_checks, _failures])
	if _failures == 0:
		print("in-engine tests passed")
	quit(1 if _failures > 0 else 0)


func _section_index(section_name: String) -> int:
	for i in _sim.get_section_count():
		if _sim.get_section_name(i) == section_name:
			return i
	return 0
