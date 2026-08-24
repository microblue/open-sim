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

signal chosen(stem: String)
signal cancelled

@export var simulation_path: NodePath

var _sim: RCSimulationNode
var _canvas: Control
var _stems: PackedStringArray = PackedStringArray()
var _index: int = 0
## Cards, one per aircraft, filled by loading each definition once.
var _cards: Array[Dictionary] = []


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
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.04, 0.05, 0.90))

	var heading := "HANGAR"
	UITheme.draw_label(_canvas,
			Vector2(size.x * 0.5 - UITheme.label_width(heading, 3.0, UITheme.SIZE_LABEL) * 0.5, 54),
			heading, UITheme.TEXT_DIM, 3.0, UITheme.SIZE_LABEL)

	if _cards.is_empty():
		UITheme.draw_text(_canvas, Vector2(size.x * 0.5, size.y * 0.5),
				"No aircraft found in Data/Aircraft/",
				UITheme.SIZE_BODY, UITheme.WARN, HORIZONTAL_ALIGNMENT_CENTER)
		return

	_draw_selector(size)
	_draw_card(size, _cards[_index])

	UITheme.draw_text(_canvas, Vector2(size.x * 0.5, size.y - 34),
			"left / right   choose        enter   fly it        esc   back",
			UITheme.SIZE_LABEL, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)


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
		UITheme.draw_text(_canvas,
				rect.position + Vector2(rect.size.x * 0.5, 29.0),
				_cards[i]["name"], UITheme.SIZE_BODY,
				UITheme.TEXT if selected else UITheme.TEXT_DIM,
				HORIZONTAL_ALIGNMENT_CENTER)


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
