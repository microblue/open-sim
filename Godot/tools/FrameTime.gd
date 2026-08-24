# OpenRC Simulator - what a frame actually costs.
#
#   godot --path Godot --resolution 1920x1080 --script res://tools/FrameTime.gd
#
# Runs the flight scene, lets it settle, and reports the mean frame time over
# 180 frames. Environment variables bisect the scene, which is how the cost was
# located the one time it mattered - see Docs/PERFORMANCE.md:
#
#   RC_NO_GRASS      the field's grass
#   RC_NO_DETAIL     the scattered vegetation
#   RC_NO_WATER      the ocean
#   RC_NO_TERRAIN    the streamed terrain entirely
#   RC_NO_SHADOW     the sun's shadows
#   RC_FLAT_TERRAIN  procedural terrain colouring instead of the PBR sets
#   RC_NO_POST       SSAO, glow and fog
#   RC_NO_TAA        temporal anti-aliasing
#   RC_NO_MSAA       multisampling
#   RC_SKY_STATIC    a smaller, cheaper sky radiance map
extends SceneTree
var _n := 0
var _sum := 0.0
var _scene: Node3D
func _initialize() -> void:
	_scene = load("res://scenes/Flight.tscn").instantiate()
	root.add_child(_scene)
func _process(delta: float) -> bool:
	_n += 1
	if _n == 60:
		if OS.has_environment("RC_NO_TAA"):
			root.use_taa = false
		if OS.has_environment("RC_NO_MSAA"):
			root.msaa_3d = Viewport.MSAA_DISABLED
		if OS.has_environment("RC_SKY_STATIC"):
			var we: Node = _scene.find_child("WorldEnvironment", true, false)
			if we and we.environment and we.environment.sky:
				we.environment.sky.process_mode = Sky.PROCESS_MODE_REALTIME
				we.environment.sky.radiance_size = Sky.RADIANCE_SIZE_128
	if _n < 140: return false
	if _n < 320:
		_sum += delta
		return false
	print("FPSRESULT %.1f fps  (%.2f ms/frame)" % [180.0 / _sum, _sum / 180.0 * 1000.0])
	quit(); return true
