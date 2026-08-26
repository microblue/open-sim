# OpenRC Simulator - can each aeroplane in the roster actually leave the ground?
#
#   godot --path Godot --headless --script res://tests/SpawnCheck.gd
#
# Not a screenshot and not a unit test: the question is what a player gets in
# the first ten seconds after pressing Fly, which is a question about the whole
# stack - spawn placement, ground contact, the crash model and the power system
# together - and nothing else asks it.
#
# It was written because the 2.4 m glider was reported crashed before the
# player had touched a stick, every single time, and none of the 313 unit tests
# noticed: each of them was right about its own piece.
#
# Exits non-zero if any aeroplane crashes or fails to fly, so verify.sh can
# hold the roster to it.
extends SceneTree

const HOLD_SECONDS: float = 8.0

var _sim: RCSimulationNode
var _stems: PackedStringArray
var _index: int = -1
var _elapsed: float = 0.0
var _crashed_at: float = -1.0
var _airborne_at: float = -1.0
var _max_speed: float = 0.0
var _reason: String = ""
var _reason_agl: float = 0.0
var _failures: int = 0


func _initialize() -> void:
	_sim = RCSimulationNode.new()
	_sim.aircraft_definition = "Data/Aircraft/Trainer1500.json"
	root.add_child(_sim)
	_stems = _sim.list_aircraft()
	print("  first ten seconds after Fly, every aircraft in the roster")


func _process(delta: float) -> bool:
	if _index < 0 or _elapsed > HOLD_SECONDS:
		_report()
		_index += 1
		if _index >= _stems.size():
			if _failures > 0:
				printerr("%d of %d aircraft cannot fly from their own spawn"
					% [_failures, _stems.size()])
				quit(1)
			else:
				print("every aircraft flies from its own spawn")
				quit(0)
			return true
		_sim.aircraft_definition = "Data/Aircraft/%s.json" % _stems[_index]
		_sim.reload_aircraft()
		_sim.spawn_mode = RCSimulationNode.SPAWN_RUNWAY
		_sim.reset_state()
		_sim.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 1.0)
		_sim.set_manual_channel(RCInputNode.CHANNEL_ELEVATOR, 0.0)
		_elapsed = 0.0
		_crashed_at = -1.0
		_airborne_at = -1.0
		_max_speed = 0.0
		_reason = ""
		return false

	_elapsed += delta
	_max_speed = maxf(_max_speed, _sim.get_airspeed_mps())
	if _crashed_at < 0.0 and _sim.has_crashed():
		_crashed_at = _elapsed
		_reason = _sim.get_crash_reason()
		_reason_agl = _sim.get_altitude_agl_m()
	if _airborne_at < 0.0 and not _sim.is_on_ground():
		_airborne_at = _elapsed
	return false


func _report() -> void:
	if _index < 0:
		return
	var launch: String = "hand" if _sim.is_hand_launched() else "runway"
	var ok: bool = _crashed_at < 0.0 and _airborne_at >= 0.0
	if not ok:
		_failures += 1
	print("  %s %-16s  %-7s  crash %-7s  airborne %-8s  %.1f m/s  %s" % [
		"[ ok ]" if ok else "[FAIL]",
		_stems[_index], launch,
		("%.1f s" % _crashed_at) if _crashed_at >= 0.0 else "no",
		("%.1f s" % _airborne_at) if _airborne_at >= 0.0 else "NEVER",
		_max_speed, _reason])
