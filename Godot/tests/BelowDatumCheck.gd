# Flying below the field's own height must be flying, not crashing.
#
# The terrain rolls away from the flying field, and the valleys around it lie
# below the field. A model flown out over one is below "zero" - the field - and
# still well clear of the ground under it, and it must stay airborne until it
# actually touches something.
#
#   godot --headless --path Godot --script res://tests/BelowDatumCheck.gd
extends SceneTree

var _sim: RCSimulationNode
var _frame: int = 0
var _failures: int = 0
var _spot := Vector3.ZERO
var _min_altitude: float = INF
var _min_agl: float = INF


func _initialize() -> void:
	_sim = RCSimulationNode.new()
	_sim.name = "Aircraft"
	_sim.physics_rate_hz = 240
	root.add_child(_sim)


func _check(ok: bool, what: String) -> void:
	print("  [%s] %s" % ["ok" if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 2:
		# The lowest dry ground within a couple of kilometres, with room
		# around it: a valley floor, well below the field.
		var config: Dictionary = _sim.get_terrain_settings() if _sim.has_method("get_terrain_settings") else {}
		var sea: float = _sim.get_sea_level_y()
		var best: float = INF
		for i in range(-40, 41):
			for j in range(-40, 41):
				var x: float = float(i) * 50.0
				var z: float = float(j) * 50.0
				var h: float = _sim.get_terrain_height(x, z)
				if h > sea + 2.0 and h < best:
					best = h
					_spot = Vector3(x, h, z)
		print("  field elevation %.1f m, sea level %.1f m, valley floor %.1f m at (%.0f, %.0f)"
				% [_sim.get_field_elevation() if _sim.has_method("get_field_elevation") else 0.0,
				   sea, best, _spot.x, _spot.z])
		_check(best < -5.0, "there is ground below the field to fly over")
		_sim.input_path = NodePath("")
		_sim.spawn_mode = RCSimulationNode.SPAWN_AIR
		_sim.spawn_altitude_m = 25.0
		_sim.spawn_offset = Vector3(_spot.x, 0.0, _spot.z)
		_sim.reset_state()
		_sim.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 0.55)
		_sim.set_manual_channel(RCInputNode.CHANNEL_ELEVATOR, 0.05)
		return false
	if _frame < 3:
		return false

	var at: Vector3 = _sim.global_position
	var agl: float = at.y - _sim.get_terrain_height(at.x, at.z)
	_min_altitude = minf(_min_altitude, _sim.get_altitude_m())
	_min_agl = minf(_min_agl, agl)
	if _frame % 60 == 0:
		print("    t=%4.1fs  altitude %7.1f m  above ground %6.1f m  crashed %s"
				% [_frame / 60.0, _sim.get_altitude_m(), agl, _sim.has_crashed()])
	if _frame >= 3 + 60 * 5 or _sim.has_crashed():
		_check(_min_altitude < 0.0, "the model flew below the field's height (min %.1f m)" % _min_altitude)
		if _sim.has_crashed():
			print("    crash: %s" % _sim.get_crash_reason())
		_check(not _sim.has_crashed() or _min_agl < 1.0,
				"no crash while clear of the ground (min %.1f m above it)" % _min_agl)
		print("BELOW DATUM: %s" % ("PASS" if _failures == 0 else "FAIL"))
		quit(0 if _failures == 0 else 1)
		return true
	return false
