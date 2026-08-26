# OpenRC Simulator - an aeroplane on a turntable.
#
# A menu that asks "which aeroplane?" and answers only in numbers is a
# spreadsheet. This puts the machine itself on the screen: the model built from
# the flight model's own geometry - the same builder the in-flight one uses, so
# what turns on the stand is exactly what will fly - lit on its own stage and
# rotating slowly enough to read the shape.
#
# It carries its own simulation node, stepping nothing. Inspecting an aeroplane
# must not disturb the one on the field, and a second aeroplane quietly falling
# out of the sky would burn a physics budget the field needs.
#
# Shared by the menu's aircraft step and the hangar screen, which want the same
# thing for the same reason.
extends Node

const ModelScript := preload("res://aircraft/Trainer1500/AircraftModel.gd")

## Turns per second. Slow enough to read the planform, fast enough that the
## screen is never still.
const SPIN_RATE: float = 0.30

var _stage: SubViewport
var _sim: RCSimulationNode
var _turntable: Node3D
var _stem: String = ""
var _span: float = 1.5
var _spin: float = 0.6


func _ready() -> void:
	_stage = SubViewport.new()
	_stage.name = "Stage"
	_stage.size = Vector2i(920, 520)
	_stage.transparent_bg = true
	# Its own world, or the stage renders the field: without this it showed the
	# grass, the mountains, the windsock and the aeroplane parked on the strip,
	# with the one on the stand somewhere among them.
	_stage.own_world_3d = true
	_stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_stage.msaa_3d = Viewport.MSAA_4X
	add_child(_stage)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_CANVAS
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.42, 0.50, 0.60)
	# Toned down for real models. The generated aeroplane was flat-shaded
	# colour and wanted lifting; a photographed airframe with a white paint
	# scheme and real PBR maps blows out to a silhouette at that exposure.
	env.environment.ambient_light_energy = 0.8
	_stage.add_child(env)

	# Three lights. A key from high and forward models the wing's curvature, a
	# cool fill from behind keeps the trailing edge off the panel it sits on,
	# and a rim along the top edge separates a white fuselage from a pale
	# background - which is the shot every product photograph is.
	_light(1.15, Vector3(-38.0, 34.0, 0.0), Color(1.0, 0.97, 0.92))
	_light(0.35, Vector3(-14.0, -140.0, 0.0), Color(0.65, 0.78, 0.95))
	_light(0.45, Vector3(-72.0, 150.0, 0.0), Color(0.80, 0.90, 1.0))

	_turntable = Node3D.new()
	_turntable.name = "Turntable"
	_stage.add_child(_turntable)

	_sim = RCSimulationNode.new()
	_sim.name = "StageSim"
	# Geometry only. Nothing here is flown.
	_sim.set_physics_process(false)
	_turntable.add_child(_sim)

	var model := ModelScript.new()
	model.name = "Model"
	model.simulation_path = NodePath("../StageSim")
	_turntable.add_child(model)

	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.fov = 32.0
	# Framed on WIDTH. Godot's fov is vertical by default and the stage is
	# wider than it is tall: framing the span against the height left a 1.5 m
	# aeroplane in the middle of four metres of empty studio.
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.current = true
	_stage.add_child(camera)


func _light(energy: float, degrees: Vector3, colour: Color) -> void:
	var light := DirectionalLight3D.new()
	light.light_energy = energy
	light.light_color = colour
	light.rotation_degrees = degrees
	_stage.add_child(light)


func _process(delta: float) -> void:
	if _turntable != null:
		_spin += delta * SPIN_RATE * TAU
		_turntable.rotation.y = _spin


## The rendered stage, for a TextureRect to show.
func texture() -> Texture2D:
	return _stage.get_texture() if _stage != null else null


## Resizes the stage to the box it will be drawn in, so the aspect the camera
## frames against is the aspect the player sees.
func set_stage_size(size: Vector2i) -> void:
	var wanted := Vector2i(maxi(size.x, 64), maxi(size.y, 64))
	if _stage != null and _stage.size != wanted:
		_stage.size = wanted
		_frame()


## Puts `stem` on the stand. Idempotent, and cheap to call every frame: the
## selection and the stage have to agree, and every path that moves the
## selection would otherwise have to remember to say so.
func show_aircraft(stem: String, span_m: float) -> void:
	if _sim == null or stem.is_empty() or stem == _stem:
		return
	_stem = stem
	_span = maxf(span_m, 0.3)
	_sim.aircraft_definition = "Data/Aircraft/%s.json" % stem
	if not _sim.reload_aircraft():
		return
	var model: Node = _turntable.get_node_or_null("Model")
	if model != null:
		model.call("rebuild")
	_frame()


## Backs the camera off until the span fills four fifths of the frame, whatever
## the span is: a 2.4 m glider and a 1.1 m warbird are both sized to the stage,
## so the stand looks the same and only the aeroplane on it changes.
func _frame() -> void:
	if _stage == null:
		return
	var camera := _stage.get_node_or_null("Camera") as Camera3D
	if camera == null:
		return
	var half_fov: float = deg_to_rad(camera.fov) * 0.5
	var distance: float = (_span * 0.5 / 0.8) / tan(half_fov)
	# Twenty degrees above the wing. Level with it, the planform - the whole
	# point of a 13:1 glider next to a 7:1 trainer - is an edge-on line.
	camera.position = Vector3(0.0, distance * 0.364, distance)
	camera.look_at(Vector3.ZERO, Vector3.UP)
