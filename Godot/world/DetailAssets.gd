# OpenRC Simulator - real scanned models where they exist, generated ones where
# they do not.
#
# The scatter used to place low-poly shapes built in code. They were the right
# shapes in the right places and they were unmistakably generated, because a
# cone with one flat colour is a cone with one flat colour however well it is
# lit. What actually reads as a tree is a photograph of a tree wrapped around
# geometry that came from a laser scan.
#
# The models are CC0 from Poly Haven, decimated to a few thousand triangles by
# scripts/build-assets.sh - they arrive as film assets of up to seventeen
# million. Two levels each, because a tree passed at fifty metres and a tree on
# a ridgeline two kilometres away are not the same object.
#
# Everything degrades rather than fails. A checkout without assets runs on the
# generated meshes, which is what the test suite does and what someone gets
# before they have run the fetch script.
class_name DetailAssets
extends RefCounted

const Meshes := preload("res://world/DetailMeshes.gd")

const LOD_DIR := "Godot/assets/lod"

## Which scanned models stand in for which scatter kind. Several per kind where
## the library has them: two species of conifer and two of broadleaf, so a wood
## is not one tree repeated.
## Only the kinds whose geometry survives decimation.
##
## Rock, bare wood and bark are solid surfaces: the simplifier collapses them
## freely and a boulder at a thousand triangles is indistinguishable from the
## scan at ninety thousand.
##
## FOLIAGE IS NOT HERE, and that is not an oversight. Leaves in a photogrammetry
## scan are thousands of separate alpha-cut cards. Collapsing an edge between
## two of them does not simplify a leaf, it destroys both - and a general
## simplifier has no way to know the difference. Bounding it tightly enough to
## refuse those collapses leaves island_tree_02 at 131,000 triangles; loosening
## it far enough to be instanceable turns the canopy into a cloud of loose
## triangles hanging in the air. There is no setting between the two.
##
## The answer is impostors: render each tree offline from a ring of angles and
## instance a billboard that picks the nearest view. That is how every flight
## simulator draws a forest, and it is a separate piece of work. Until it
## exists, foliage uses the generated meshes, which are honest low-poly shapes
## rather than broken high-poly ones.
const SPECIES := {
	Meshes.DEAD_TREE: ["dead_tree_trunk", "tree_stump_01"],
	Meshes.BOULDER:   ["namaqualand_boulder_02", "namaqualand_boulder_04"],
}

## Scanned models arrive at their real size in metres, which is correct and
## sometimes not what the scatter wants - a "grass" scan is a clump the size of
## a dinner plate, and the field needs it to read from thirty metres.
const SCALE := {}

static var _cache: Dictionary = {}
static var _missing: Dictionary = {}


## Mesh for one kind at one level, or null to fall back to the generated shape.
## `variant` picks between species, so neighbouring trees differ.
static func mesh_for(sim: Node, kind: int, level: int, variant: int) -> Mesh:
	if not SPECIES.has(kind):
		return null
	var names: Array = SPECIES[kind]
	var name: String = names[variant % names.size()]
	var key: String = "%s_lod%d" % [name, level]

	if _cache.has(key):
		return _cache[key]
	if _missing.has(key):
		return null

	var path: String = sim.resolve_data_path("%s/%s.glb" % [LOD_DIR, key])
	if not FileAccess.file_exists(path):
		_missing[key] = true
		return null

	# Loaded through Godot's importer when it has run, straight from the file
	# when it has not - the second path is what a headless test hits.
	var scene: PackedScene = null
	var resource_path: String = "res://assets/lod/%s.glb" % key
	if ResourceLoader.exists(resource_path):
		scene = load(resource_path) as PackedScene
	if scene == null:
		_missing[key] = true
		return null

	var root: Node = scene.instantiate()
	var found: Mesh = _first_mesh(root)
	root.queue_free()

	if found == null:
		_missing[key] = true
		return null

	_cache[key] = found
	return found


static func scale_for(kind: int) -> float:
	return SCALE.get(kind, 1.0)


## How many distinct scanned species a kind has, so the caller can spread its
## instances across them.
static func variant_count(kind: int) -> int:
	return SPECIES[kind].size() if SPECIES.has(kind) else 1


static func _first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		var instance: MeshInstance3D = node
		if instance.mesh != null:
			return instance.mesh
	for child in node.get_children():
		var found: Mesh = _first_mesh(child)
		if found != null:
			return found
	return null
