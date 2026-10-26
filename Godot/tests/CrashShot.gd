# OpenRC Simulator - what a beginner sees after they crash.
#
#   godot --path Godot --resolution 1920x1080 --script res://tests/CrashShot.gd
#
# A beginner crashes constantly - that is what learning to fly a model looks
# like - so the seconds after a crash are one of the most-visited screens in
# the product and had never been looked at.
#
# It also CHECKS the two things that were wrong when it first was: that the
# motor stops, and that the pilot can see the wreck. Exits non-zero otherwise.
extends SceneTree

var _scene: Node3D
var _sim: RCSimulationNode
var _frame: int = 0
var _shot: int = 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("res://shots/crash"))
	_scene = load("res://scenes/Flight.tscn").instantiate()
	root.add_child(_scene)


func _process(_delta: float) -> bool:
	_frame += 1
	# Through the menu's own Fly button, because that is what builds the world.
	# Skipping it left the aeroplane crashing into an empty scene, and the
	# "after the crash" screenshot was a flat blue rectangle - which looked
	# exactly like a product fault and was a fault in this file.
	if _frame == 40:
		var menu: Node = _scene.get_node_or_null("MainMenu")
		if menu != null:
			menu.call("_begin_fly")
		return false

	if _sim == null:
		if _frame < 260:
			return false
		_sim = _scene.get_node_or_null("Aircraft") as RCSimulationNode
		_sim.input_path = NodePath("")
		_sim.spawn_mode = RCSimulationNode.SPAWN_AIR
		_sim.spawn_altitude_m = 30.0
		_sim.reset_state()
		# The pilot's view: the wreck is judged from where the pilot stands.
		_scene.get_node("CameraRig").call("_set_mode", 0)
		# Straight in, which is how most of them happen.
		_sim.set_manual_channel(RCInputNode.CHANNEL_THROTTLE, 0.9)
		_sim.set_manual_channel(RCInputNode.CHANNEL_ELEVATOR, -0.85)
		return false

	if _sim.has_crashed() and _shot == 0:
		_shot = _frame
		print("  crashed: %s" % _sim.get_crash_reason())

	if _shot > 0 and _frame == _shot + 90:
		var rig: Node3D = _scene.get_node_or_null("CameraRig") as Node3D
		var cam: Camera3D = null
		for child in rig.find_children("*", "Camera3D", true, false):
			cam = child as Camera3D
			break
		if cam != null:
			var to_model: Vector3 = _sim.global_position - cam.global_position
			var forward: Vector3 = -cam.global_transform.basis.z
			print("  camera at %s pitch %.1f deg" % [cam.global_position,
				  rad_to_deg(asin(forward.y))])
			print("  model at  %s, %.1f m away, %.1f deg off centre"
				% [_sim.global_position, to_model.length(),
				   rad_to_deg(forward.angle_to(to_model.normalized()))])
		var image: Image = root.get_texture().get_image()
		image.save_png(ProjectSettings.globalize_path("res://shots/crash/after.png"))
		print("  captured res://shots/crash/after.png")

		var failed: bool = false
		# A wrecked model does not keep making thrust. It did: 90 %, eight
		# thousand rpm and eleven newtons, on an aeroplane lying in the grass.
		print("  after the crash: rpm %.0f, thrust %.2f N"
			% [_sim.get_rpm(), _sim.get_thrust_n()])
		if _sim.get_rpm() > 1.0 or _sim.get_thrust_n() > 0.05:
			printerr("a wrecked aeroplane is still making thrust")
			failed = true

		# And the pilot has to be able to see it. Measured as the fraction of
		# the frame the model subtends: the first version put a 1.5 m aeroplane
		# 28 m away in a 38 degree field, which is a white speck.
		if cam != null:
			var away: float = _sim.global_position.distance_to(cam.global_position)
			var subtend: float = rad_to_deg(2.0 * atan(_sim.get_wingspan_m()
													   * 0.5 / maxf(away, 0.1)))
			print("  the wreck is %.1f m away and subtends %.2f deg in a %.1f deg field"
				% [away, subtend, cam.fov])
			if subtend < cam.fov * 0.04:
				printerr("the wreck is too small to see")
				failed = true

		quit(1 if failed else 0)
		return true
	if _frame > 1200:
		print("  never crashed")
		quit(1)
		return true
	return false
