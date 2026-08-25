# OpenRC Simulator - applying a scene and a weather state to the live world.
#
# One place that knows how a preset reaches the terrain, the sky, the light, the
# air and the ground. Everything else asks this rather than reaching into the
# environment itself, so there is exactly one answer to "what is the world doing
# right now" and switching scenes cannot leave half of it behind.
extends Node

const ScenePresetsLib := preload("res://world/ScenePresets.gd")
const WeatherLib := preload("res://world/Weather.gd")

signal world_changed(scene_id: String, weather_id: String)

@export var simulation_path: NodePath
@export var field_path: NodePath
@export var camera_path: NodePath

var _sim: RCSimulationNode
var _field: Node3D
var _field_script: Node
var _camera: Node3D
var _precipitation: GPUParticles3D

var scene_id: String = "meadow"
var weather_id: String = "clear"


func _ready() -> void:
	_sim = get_node_or_null(simulation_path) as RCSimulationNode
	_field = get_node_or_null(field_path) as Node3D
	# Flight adds the field script as a CHILD of the Field container (which
	# also holds World and Detail). The script node is the one that owns the
	# sky, the grass and the trees - the container is just a staging node -
	# and pointing the weather at the container made every field-side weather
	# change dead code: fog, light, the sky swap, the grass hiding under snow.
	if _field != null:
		_field_script = _field.get_node_or_null("GrassField01")
		if _field_script == null:
			_field_script = _field


func current_scene() -> Dictionary:
	return ScenePresetsLib.by_id(scene_id)


func current_weather() -> Dictionary:
	return WeatherLib.by_id(weather_id)


## Switch scene. The terrain function changes underneath everything, so the
## streamed world and the scenery on it have to be discarded and rebuilt - a
## chunk generated from the old settings is a piece of a different planet.
func apply_scene(id: String) -> void:
	var preset: Dictionary = ScenePresetsLib.by_id(id)
	scene_id = preset["id"]

	if _sim != null:
		_sim.configure_terrain(preset["terrain"])

	if _field_script != null and _field_script.has_method("apply_sky"):
		_field_script.apply_sky(preset["sky"], preset["sun_angles"], preset["sun_energy"])

	_rebuild_world()
	apply_weather(preset.get("weather", weather_id))
	world_changed.emit(scene_id, weather_id)


func apply_weather(id: String) -> void:
	var state: Dictionary = WeatherLib.by_id(id)
	weather_id = state["id"]

	# The air first. This is the half a pilot feels rather than sees, and the
	# flight model reads it directly.
	if _sim != null:
		_sim.wind_speed_mps = state["wind_mps"]
		_sim.gust_amplitude_mps = state["wind_mps"] * float(state["gust"])
		_sim.turbulence_mps = state["turbulence"]

	if _field_script != null and _field_script.has_method("apply_weather"):
		_field_script.apply_weather(state)

	# The ground reads the weather too - snow is a white field to land on,
	# rain is a wet one - so a weather state is what the pilot sees, feels and
	# lands on at once.
	var snow: float = 1.0 if state.get("precipitation", "") == "snow" else 0.0
	var wet: float = 1.0 if state.get("precipitation", "") == "rain" else 0.0
	var ground: Node = _field.get_node_or_null("World") if _field != null else null
	if ground != null and ground.has_method("apply_weather_ground"):
		ground.apply_weather_ground(snow, wet)
	var detail: Node = _field.get_node_or_null("Detail") if _field != null else null
	if detail != null and detail.has_method("apply_weather_ground"):
		detail.apply_weather_ground(snow, wet)

	_rebuild_precipitation(state)
	world_changed.emit(scene_id, weather_id)


## Rain and snow ride with the camera. What matters is the few metres in front
## of the eye; a world-sized emitter would spend every particle out of sight.
func _rebuild_precipitation(state: Dictionary) -> void:
	if _precipitation != null:
		_precipitation.queue_free()
		_precipitation = null

	var built: GPUParticles3D = WeatherLib.build_precipitation(
			state.get("precipitation", ""), float(state.get("rate", 0.0)))
	if built == null:
		return
	_precipitation = built
	add_child(_precipitation)


func _process(_delta: float) -> void:
	if _precipitation == null:
		return
	if _camera == null:
		_camera = get_node_or_null(camera_path) as Node3D
	var camera: Camera3D = get_viewport().get_camera_3d()
	var here: Vector3 = camera.global_position if camera != null \
			else (_camera.global_position if _camera != null else Vector3.ZERO)
	_precipitation.global_position = here + Vector3(0.0, 11.0, 0.0)


## Discard everything generated from the old terrain function and let it build
## again. Cheaper than it sounds - the circuit is pre-generated in one go - and
## the only correct answer, since a chunk made under the old settings is a piece
## of a different planet.
func _rebuild_world() -> void:
	if _field == null:
		return
	for child in _field.get_children():
		if child.has_method("rebuild"):
			child.rebuild()
