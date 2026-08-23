# Renders each interface state so the layout can be reviewed rather than assumed.
#
#   godot --path Godot --script res://tests/UiShots.gd
extends SceneTree

var _n := 0
var _stage := 0
var _flight: Node


func _initialize() -> void:
	_flight = load("res://scenes/Flight.tscn").instantiate()
	root.add_child(_flight)


func _shot(name: String) -> void:
	root.get_texture().get_image().save_png(
		ProjectSettings.globalize_path("res://shots/ui_%s.png" % name))
	print("  ui_%s" % name)


func _process(_d: float) -> bool:
	_n += 1
	if _n < 40:
		return false

	var frame: int = _n - 40
	match frame:
		0:  _shot("menu")
		4:
			var menu: Node = _flight.get_node_or_null("MainMenu")
			if menu != null: menu.queue_free()
			_flight._open_wizard()
		10: _shot("wizard_detect")
		12:
			# No radio is attached here, so the later steps are staged directly.
			# The point of the shot is the layout, and the layout is the same.
			var wizard: Node = _flight.get_node_or_null("ControllerWizard")
			if wizard != null:
				wizard._step = 3          # REVIEW
				wizard._channel_index = 4
		18: _shot("wizard_review")
		20:
			var wizard: Node = _flight.get_node_or_null("ControllerWizard")
			if wizard != null: wizard.queue_free()
			var tuning: Node = _flight.get_node_or_null("TuningPanel")
			if tuning != null:
				tuning.visible = true
				tuning._selected = 2
		34: _shot("tuning")
		36:
			var hud: Node = _flight.get_node_or_null("FlightHUD")
			if hud != null: hud._diagnostics = true
			var aircraft: RCSimulationNode = _flight.get_node("Aircraft")
			aircraft.spawn_mode = RCSimulationNode.SPAWN_AIR
			aircraft.spawn_altitude_m = 40.0
			aircraft.reset_state()
			var rig: Node3D = _flight.get_node("CameraRig")
			rig.mode = 1
		90: _shot("hud_diagnostics")
		94:
			quit(0)
			return true
	return false
