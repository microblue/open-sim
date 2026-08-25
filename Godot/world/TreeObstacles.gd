# OpenRC Simulator - the trees the aircraft can hit.
#
# The physics core collides with a list of solid cylinders (x, z, radius,
# height above the terrain) fed into RCSimulationNode.set_tree_obstacles().
# This is the authoritative GDScript-side list: the field's treeline and the
# streamed scatter both register here, and a flush pushes the merged set to
# the physics.
#
# Two buckets, because they have different lifetimes. The field's trees are
# built once per session and never move; the scatter's trees are rebuilt
# whenever a scene preset changes the world. Clearing one bucket must never
# wipe the other.
class_name TreeObstacles
extends RefCounted

static var _field := PackedFloat32Array()
static var _scatter := PackedFloat32Array()


static func clear_scatter() -> void:
	_scatter = PackedFloat32Array()


static func add_field(x: float, z: float, radius: float, height: float) -> void:
	_field.append_array([x, z, radius, height])


static func add_scatter(x: float, z: float, radius: float, height: float) -> void:
	_scatter.append_array([x, z, radius, height])


## Push the merged obstacle set to the physics. Called whenever either bucket
## changes; the physics rebuilds its spatial grid on each call.
static func flush(sim: RCSimulationNode) -> void:
	if sim == null:
		return
	var merged: PackedFloat32Array = _field + _scatter
	sim.set_tree_obstacles(merged)
