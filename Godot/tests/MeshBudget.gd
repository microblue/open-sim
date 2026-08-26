# How much per-vertex work an airframe can afford at load time.
#
#   godot --headless --path Godot --script res://tests/MeshBudget.gd
#
# Splitting control surfaces off a downloaded airframe means clipping triangles
# against planes, and that is per-vertex work in GDScript. Whether it belongs
# at load time or in an offline bake is a question about how many triangles
# there are and how fast the loop is, so: measure both.
extends SceneTree


func _initialize() -> void:
	for stem in ["Trainer1500", "Sport1200", "Warbird1100", "Glider2400"]:
		var path: String = "res://aircraft/%s/airframe.glb" % stem
		if not ResourceLoader.exists(path):
			continue
		var scene: Node3D = (load(path) as PackedScene).instantiate() as Node3D
		root.add_child(scene)

		var triangles: int = 0
		var started: int = Time.get_ticks_usec()
		var touched: float = 0.0
		for child in scene.find_children("*", "MeshInstance3D", true, false):
			var mesh := child as MeshInstance3D
			if mesh.mesh == null:
				continue
			var faces: PackedVector3Array = mesh.mesh.get_faces()
			triangles += faces.size() / 3
			# A stand-in for the clip: one plane distance per vertex.
			for point in faces:
				touched += point.z
		var elapsed: float = float(Time.get_ticks_usec() - started) / 1000.0
		print("  %-14s %7d triangles   one pass %.1f ms   (%.3f)"
			% [stem, triangles, elapsed, touched])
		scene.queue_free()
	quit(0)
