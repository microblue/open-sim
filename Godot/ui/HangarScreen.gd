# OpenRC Simulator - choosing an aeroplane.
#
# Four machines that fly genuinely differently, and the numbers that say how.
# Everything on the card is read from the aircraft the flight model has actually
# loaded, not from a table written alongside it: a specification sheet that
# disagrees with the aeroplane is worse than no sheet at all.
#
# The measured figures - glide ratio, stall speed, roll rate - come from
# Data/Aircraft/*.json, where the regression suite writes and checks them. The
# derived ones - wing loading, aspect ratio, power to weight - are computed in
# C++ from the same definition the aerodynamics uses.
extends CanvasLayer

const UITheme := preload("res://ui/UITheme.gd")
const ModelScript := preload("res://aircraft/Trainer1500/AircraftModel.gd")

signal chosen(stem: String)
signal cancelled

@export var simulation_path: NodePath

var _sim: RCSimulationNode
var _canvas: Control
var _stems: PackedStringArray = PackedStringArray()
var _index: int = 0
## Cards, one per aircraft, filled by loading each definition once.
var _cards: Array[Dictionary] = []
## The turntable: a private simulation node holding nothing but the selected
## aeroplane's geometry, and the model built from it.
var _stage: SubViewport
var _stage_sim: RCSimulationNode
var _turntable: Node3D
var _stage_view: TextureRect
var _spin: float = 0.0
## The aeroplane currently standing on it. Compared against the selection every
## frame rather than pushed on selection change: the stage and the card have to
## agree, and every path that moves the selection would otherwise have to
## remember to say so.
var _stage_stem: String = ""


func _ready() -> void:
	layer = 24
	_sim = get_node_or_null(simulation_path) as RCSimulationNode

	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_screen)
	add_child(_canvas)

	_gather()
	_build_stage()


## A hangar with no aeroplane in it is a spreadsheet. The card was two columns
## of numbers over six hundred pixels of nothing, and the one question a player
## has here - what does it look like? - went unanswered.
##
## The model is built from the flight model's own geometry, exactly as the
## in-flight one is, so what turns on the stand is the aeroplane that will fly.
## It gets its own simulation node, stepping nothing, so that inspecting an
## aeroplane cannot disturb the one on the field.
func _build_stage() -> void:
	_stage = SubViewport.new()
	_stage.name = "Stage"
	_stage.size = Vector2i(920, 430)
	_stage.transparent_bg = true
	# Its own world, or the stage renders the field: the first attempt showed
	# the grass, the mountains, the windsock and the aeroplane parked on the
	# strip, with the one on the stand somewhere among them.
	_stage.own_world_3d = true
	_stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_stage.msaa_3d = Viewport.MSAA_4X
	add_child(_stage)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_CANVAS
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.42, 0.50, 0.60)
	env.environment.ambient_light_energy = 1.5
	_stage.add_child(env)

	# Two lights: a key from high and forward to model the wing's curvature,
	# and a cool fill from behind so the trailing edge does not vanish into
	# the panel it sits on.
	var key := DirectionalLight3D.new()
	key.light_energy = 2.2
	key.rotation_degrees = Vector3(-38.0, 34.0, 0.0)
	_stage.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.7
	fill.light_color = Color(0.65, 0.78, 0.95)
	fill.rotation_degrees = Vector3(-14.0, -140.0, 0.0)
	_stage.add_child(fill)

	_turntable = Node3D.new()
	_turntable.name = "Turntable"
	_stage.add_child(_turntable)

	_stage_sim = RCSimulationNode.new()
	_stage_sim.name = "StageSim"
	# Geometry only. Nothing here is flown, and a second aeroplane quietly
	# falling out of the sky would burn a physics budget the field needs.
	_stage_sim.set_physics_process(false)
	_turntable.add_child(_stage_sim)

	var model := ModelScript.new()
	model.name = "Model"
	model.simulation_path = NodePath("../StageSim")
	_turntable.add_child(model)

	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.fov = 32.0
	# Framed on WIDTH. Godot's fov is vertical by default, and the stage is
	# twice as wide as it is tall: framing the span against the height put a
	# 1.5 m aeroplane in the middle of four metres of empty studio.
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.current = true
	_stage.add_child(camera)

	_stage_view = TextureRect.new()
	_stage_view.texture = _stage.get_texture()
	_stage_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_stage_view)

	_show_on_stage()


## Puts the selected aeroplane on the stand and frames the camera to its span,
## so a 2.4 m glider and a 1.1 m warbird both fill the stage.
func _show_on_stage() -> void:
	if _stage_sim == null or _index >= _cards.size():
		return
	if _cards[_index]["stem"] == _stage_stem:
		return
	_stage_stem = _cards[_index]["stem"]
	_stage_sim.aircraft_definition = "Data/Aircraft/%s.json" % _cards[_index]["stem"]
	if not _stage_sim.reload_aircraft():
		return
	var model: Node = _turntable.get_node_or_null("Model")
	if model != null:
		model.call("rebuild")

	var span: float = maxf(float(_cards[_index]["span"]), 0.3)
	var camera := _stage.get_node("Camera") as Camera3D
	# Far enough back that the span fills four fifths of the frame, whatever
	# the span is: the glider and the warbird are sized to the stage, not to
	# each other, so the stand always looks the same and only the aeroplane
	# on it changes.
	var half_fov: float = deg_to_rad(camera.fov) * 0.5
	var distance: float = (span * 0.5 / 0.8) / tan(half_fov)
	# Twenty degrees above the wing. Level with it, the planform - the whole
	# point of a 13:1 glider next to a 7:1 trainer - is an edge-on line.
	camera.position = Vector3(0.0, distance * 0.364, distance)
	camera.look_at(Vector3.ZERO, Vector3.UP)


func _process(delta: float) -> void:
	if _turntable == null:
		return
	_show_on_stage()
	# Slow enough to read the shape, fast enough that the screen is not still.
	_spin += delta * 0.35
	_turntable.rotation.y = _spin


## Load every aircraft in turn and keep what its card needs. Done once, on the
## real simulation node, because that is the only thing that knows how to parse
## a definition - and it means the numbers cannot drift from the aeroplane.
func _gather() -> void:
	if _sim == null:
		return
	var restore: String = _sim.aircraft_definition
	_stems = _sim.list_aircraft()

	for stem in _stems:
		_sim.aircraft_definition = "Data/Aircraft/%s.json" % stem
		if not _sim.reload_aircraft():
			continue
		_cards.append({
			"stem": stem,
			"name": _sim.get_aircraft_name(),
			"description": _sim.get_aircraft_description(),
			"mass": _sim.get_mass_kg(),
			"span": _sim.get_wingspan_m(),
			"area": _sim.get_wing_area_m2(),
			"loading": _sim.get_wing_loading_pa(),
			"aspect": _sim.get_aspect_ratio(),
			"cells": _sim.get_battery_cells(),
			"capacity": _sim.get_battery_capacity_mah(),
			"kv": _sim.get_motor_kv(),
			"power": _sim.get_peak_power_w(),
			"specific_power": _sim.get_power_to_weight_w_per_kg(),
			"cruise": _sim.get_cruise_speed_mps(),
			"approach": _sim.get_approach_speed_mps(),
		})
		if stem == restore.get_file().get_basename():
			_index = _cards.size() - 1

	_sim.aircraft_definition = restore
	_sim.reload_aircraft()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match (event as InputEventKey).keycode:
		KEY_LEFT, KEY_UP:
			_index = posmod(_index - 1, maxi(_cards.size(), 1))
			_canvas.queue_redraw()
		KEY_RIGHT, KEY_DOWN:
			_index = posmod(_index + 1, maxi(_cards.size(), 1))
			_canvas.queue_redraw()
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			if _index < _cards.size():
				chosen.emit(_cards[_index]["stem"])
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			cancelled.emit()
			get_viewport().set_input_as_handled()


func _draw_screen() -> void:
	var size: Vector2 = _canvas.size
	# Nearly opaque. At 0.90 the menu underneath - its headings, its list, its
	# brief - read straight through the hangar, and the two screens' hint
	# lines overlapped at the bottom into one unreadable row.
	# Opaque. Any transparency at all and the menu underneath - its headings,
	# its list, its brief - reads straight through, which looks like a
	# rendering fault rather than depth.
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.045, 0.055, 1.0))

	var heading := "HANGAR"
	UITheme.draw_label(_canvas,
			Vector2(size.x * 0.5 - UITheme.label_width(heading, 3.0, UITheme.SIZE_LABEL) * 0.5, 54),
			heading, UITheme.TEXT_DIM, 3.0, UITheme.SIZE_LABEL)

	if _cards.is_empty():
		UITheme.draw_text(_canvas, Vector2(0.0, size.y * 0.5),
				"No aircraft found in Data/Aircraft/",
				UITheme.SIZE_BODY, UITheme.WARN, HORIZONTAL_ALIGNMENT_CENTER, size.x)
		return

	_draw_selector(size)
	_draw_card(size, _cards[_index])

	UITheme.draw_text(_canvas, Vector2(0.0, size.y - 34),
			"left / right   choose        enter   fly it        esc   back",
			UITheme.SIZE_LABEL, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER, size.x)


## The roster across the top: every aeroplane at once, so the choice is a
## comparison rather than a list you page through blind.
func _draw_selector(size: Vector2) -> void:
	var count: int = _cards.size()
	var width: float = minf(size.x * 0.82, 240.0 * count)
	var each: float = width / float(count)
	var left: float = (size.x - width) * 0.5
	var top: float = 96.0

	for i in count:
		var rect := Rect2(left + each * i + 6.0, top, each - 12.0, 46.0)
		var selected: bool = i == _index
		UITheme.draw_panel(_canvas, rect,
				UITheme.ACCENT_DIM if selected else UITheme.PANEL,
				UITheme.ACCENT if selected else UITheme.STROKE)
		UITheme.draw_text(_canvas, rect.position + Vector2(0.0, 29.0),
				_cards[i]["name"], UITheme.SIZE_BODY,
				UITheme.TEXT if selected else UITheme.TEXT_DIM,
				HORIZONTAL_ALIGNMENT_CENTER, rect.size.x)


func _draw_card(size: Vector2, card: Dictionary) -> void:
	var width: float = minf(size.x * 0.82, 980.0)
	var rect := Rect2((size.x - width) * 0.5, 168.0, width, size.y - 250.0)
	UITheme.draw_panel(_canvas, rect, UITheme.PANEL_SOLID, UITheme.STROKE)

	var x: float = rect.position.x + 34.0
	var y: float = rect.position.y + 46.0

	UITheme.draw_text(_canvas, Vector2(x, y), card["name"], UITheme.SIZE_LARGE, UITheme.TEXT)
	y += 30.0

	# The description, wrapped by hand: the point of it is the character of the
	# aeroplane, which is the thing a specification sheet cannot say.
	for line in _wrap(card["description"], int((width - 68.0) / 7.4)):
		UITheme.draw_text(_canvas, Vector2(x, y), line, UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
		y += 17.0

	y += 22.0
	UITheme.draw_rule(_canvas, Vector2(x, y), width - 68.0)
	y += 26.0

	# Two columns: what it is, and what it does.
	var column: float = (width - 68.0) * 0.5
	var top: float = y

	_group(x, y, "AIRFRAME", [
		["mass", "%.2f kg" % card["mass"]],
		["wingspan", "%.2f m" % card["span"]],
		["wing area", "%.3f m2" % card["area"]],
		["aspect ratio", "%.1f" % card["aspect"]],
		["wing loading", "%.0f N/m2" % card["loading"]],
	])

	# The stage: the aeroplane itself, filling the space the numbers left. Laid
	# out here rather than in _ready because it belongs to the card, and the
	# card's rectangle is what it has to fit inside.
	if _stage_view != null:
		var stage_top: float = top + 5 * 26.0 + 40.0
		var stage_rect := Rect2(rect.position.x + 20.0, stage_top,
								width - 40.0,
								maxf(rect.position.y + rect.size.y - stage_top - 24.0, 80.0))
		# A lighter well behind the aeroplane, so it stands in something
		# rather than floating in the panel.
		UITheme.draw_panel(_canvas, stage_rect, Color(0.07, 0.085, 0.10, 1.0),
						   UITheme.STROKE, 10.0)
		_stage_view.position = stage_rect.position
		_stage_view.size = stage_rect.size
		_stage_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_stage.size = Vector2i(int(stage_rect.size.x), int(stage_rect.size.y))

	_group(x + column, top, "POWER", [
		["battery", "%dS  %.0f mAh" % [int(card["cells"]), card["capacity"]]],
		["motor", "%.0f KV" % card["kv"]],
		["peak power", "%.0f W" % card["power"]],
		["power / weight", "%.0f W/kg" % card["specific_power"]],
		["cruise / approach", "%.0f / %.0f m/s" % [card["cruise"], card["approach"]]],
	])


func _group(x: float, y: float, heading: String, rows: Array) -> void:
	UITheme.draw_label(_canvas, Vector2(x, y), heading, UITheme.TEXT_DIM, 2.4, UITheme.SIZE_LABEL)
	y += 24.0
	for row in rows:
		UITheme.draw_text(_canvas, Vector2(x, y), row[0], UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
		UITheme.draw_text(_canvas, Vector2(x + 210.0, y), row[1], UITheme.SIZE_VALUE, UITheme.TEXT)
		y += 26.0


static func _wrap(text: String, columns: int) -> PackedStringArray:
	var lines := PackedStringArray()
	var current := ""
	for word in text.split(" ", false):
		if current.is_empty():
			current = word
		elif current.length() + 1 + word.length() <= columns:
			current += " " + word
		else:
			lines.append(current)
			current = word
	if not current.is_empty():
		lines.append(current)
	return lines
