# OpenRC Simulator - what the take-off roll actually does.
#
#   godot --path Godot --headless --script res://tests/TakeoffRoll.gd
#
# A real model aeroplane does not go straight when you open the throttle. The
# propeller drags the nose one way through four separate effects - torque
# rolling it onto a wheel, the slipstream striking one side of the fin,
# P-factor from the disc at an angle, and gyroscopic precession as the tail
# comes up - and holding the centreline with rudder is one of the first things
# a student has to learn.
#
# So: full throttle from rest, sticks CENTRED, and measure where it ends up.
extends SceneTree

const ROLL_SECONDS: float = 6.0

var _sim: RCSimulationNode
var _stems: PackedStringArray
var _index: int = -1
var _elapsed: float = 0.0
var _drift: float = 0.0
var _yaw: float = 0.0
var _airborne_at: float = -1.0
var _rolled: float = 0.0


func _initialize() -> void:
	_sim = RCSimulationNode.new()
	_sim.aircraft_definition = "Data/Aircraft/Trainer1500.json"
	root.add_child(_sim)
	_stems = _sim.list_aircraft()
	print("  full throttle, sticks centred, from a standing start")


func _process(delta: float) -> bool:
	if _index < 0 or _elapsed > ROLL_SECONDS:
		_report()
		_index += 1
		if _index >= _stems.size():
			quit(0)
			return true
		_sim.aircraft_definition = "Data/Aircraft/%s.json" % _stems[_index]
		_sim.reload_aircraft()
		_sim.spawn_mode = RCSimulationNode.SPAWN_RUNWAY
		_sim.spawn_heading_deg = 0.0
		_sim.reset_state()
		_sim.clear_manual_channels()
		if not OS.has_environment("RC_ROLL_UNPOWERED"):
			_sim.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 1.0)
		else:
			# Rolling, but with nothing turning. If it still wanders, the
			# propeller is not what is doing it.
			_sim.set_body_velocity(Vector3(0.0, 0.0, -10.0))
		_elapsed = 0.0
		_drift = 0.0
		_yaw = 0.0
		_airborne_at = -1.0
		_rolled = 0.0
		return false

	_elapsed += delta
	# Spawn heading is north, so any sideways travel is drift off the
	# centreline. Recorded at LIFT-OFF: the question is whether it tracks the
	# runway, and once the wheels are off there is no runway to track.
	if _sim.is_on_ground():
		_drift = _sim.global_position.x
		_yaw = _sim.get_attitude_degrees().z
		_rolled = _sim.global_position.z
	elif _airborne_at < 0.0:
		_airborne_at = _elapsed
	return false


func _report() -> void:
	if _index < 0:
		return
	print("  %-14s at lift-off: %+6.2f m off the centreline, %+6.1f deg off "
		% [_stems[_index], _drift, _yaw]
		+ "heading, after %.0f m of roll" % absf(_rolled))
