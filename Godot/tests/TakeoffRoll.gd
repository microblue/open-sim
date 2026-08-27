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
#
# The question is NOT whether it goes straight hands off. It should not: every
# instructor teaches you to feed the throttle in and hold rudder, and the
# thrust line on these models is deliberately set for the CLIMB - there is a
# test that says so (LandingGear.RightThrustOverCorrectsAtCruise). Trimming it
# to make the ground roll perfect was tried and it broke the climb, which is
# the trade a real model maker makes the other way round.
#
# The question is whether rudder can HOLD it. So the roll is flown twice:
# hands off, to see what the aeroplane does on its own, and then with a simple
# proportional correction of the kind a beginner learns in their first hour. An
# aeroplane that cannot be held straight by that is not one a beginner can take
# off, whatever the physics says.
#
# Exits non-zero if any aeroplane cannot be held, so verify.sh can hold the
# roster to it.
extends SceneTree

const ROLL_SECONDS: float = 6.0
## How far off the runway heading an aeroplane may be when it lifts off, hands
## off. Real models swing and you hold rudder; this is the line between "hold
## a little rudder" and "unflyable".
## How far off the runway heading an aeroplane may be at lift-off WHEN FLOWN.
## Hands off is reported but not judged.
const HEADING_LIMIT_DEG: float = 10.0
const DRIFT_LIMIT_M: float = 8.0
## What a beginner's feet do: rudder proportional to the heading error, with
## the gain of somebody who has been shown once and is trying.
const RUDDER_GAIN: float = 0.16

var _sim: RCSimulationNode
var _stems: PackedStringArray
var _index: int = -1
var _elapsed: float = 0.0
var _drift: float = 0.0
var _yaw: float = 0.0
var _airborne_at: float = -1.0
var _rolled: float = 0.0
var _failures: int = 0
## False on the hands-off run, true on the flown one.
var _flown: bool = true


func _initialize() -> void:
	_sim = RCSimulationNode.new()
	_sim.aircraft_definition = "Data/Aircraft/Trainer1500.json"
	root.add_child(_sim)
	_stems = _sim.list_aircraft()
	print("  full throttle from a standing start, hands off and then flown")


func _process(delta: float) -> bool:
	if _index < 0 or _elapsed > ROLL_SECONDS:
		_report()
		# Each aeroplane twice: once on its own, once flown.
		if _flown:
			_index += 1
		if _index >= _stems.size():
			if _failures > 0:
				printerr("%d aircraft cannot hold the runway hands off" % _failures)
				quit(1)
			else:
				print("  every aircraft tracks the runway with a touch of rudder")
				quit(0)
			return true
		_sim.aircraft_definition = "Data/Aircraft/%s.json" % _stems[_index]
		_sim.reload_aircraft()
		_sim.spawn_mode = RCSimulationNode.SPAWN_RUNWAY
		_sim.spawn_heading_deg = 0.0
		_sim.reset_state()
		_flown = not _flown
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

	# A beginner's feet: push the rudder the way that brings the nose back.
	if _flown and _sim.is_on_ground():
		_sim.set_manual_channel(RCInputNode.CHANNEL_RUDDER,
			clampf(-_sim.get_attitude_degrees().z * RUDDER_GAIN, -1.0, 1.0))

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
	# A hand-launched aeroplane has no roll to judge.
	if _rolled == 0.0 and _airborne_at <= 0.0:
		print("  [ -- ] %-14s thrown, not rolled" % _stems[_index])
		return
	if not _flown:
		# Hands off: reported, not judged. This is what the aeroplane does on
		# its own and it is SUPPOSED to wander.
		print("  [    ] %-14s hands off: %+6.2f m, %+6.1f deg"
			% [_stems[_index], _drift, _yaw])
		return
	var ok: bool = absf(_yaw) <= HEADING_LIMIT_DEG and absf(_drift) <= DRIFT_LIMIT_M
	if not ok:
		_failures += 1
	print("  %s %-14s flown:     %+6.2f m, %+6.1f deg, after %.0f m of roll"
		% ["[ ok ]" if ok else "[FAIL]", _stems[_index], _drift, _yaw, absf(_rolled)])
