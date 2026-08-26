# OpenRC Simulator - the visible aircraft, built from the flight model's own
# geometry.
#
# The mesh is generated from the sections the physics is actually integrating:
# same positions, same spans, same chords, same dihedral and incidence. That is
# not a shortcut, it is a guarantee - what the pilot sees is what is flying, and
# a wing cannot be drawn somewhere the aerodynamics does not think it is.
#
# A modelled mesh can be dropped in later; this is what makes the aircraft
# visible without one, and it stays useful afterwards as a debug view.
extends Node3D

# Off-white with a warm cast rather than pure white: a model against a bright
# sky is hard enough to read without the airframe clipping to paper.
const TRUNK_COLOUR := Color(0.66, 0.65, 0.62)
const TRIM_COLOUR := Color(0.72, 0.20, 0.12)
const DARK_COLOUR := Color(0.20, 0.22, 0.26)
## Control surfaces are a shade darker than the panel they hinge from, and sit a
## few millimetres clear of it, so they read as separate surfaces from the
## pilot's position rather than as a painted line.
const AirframeScript := preload("res://aircraft/Trainer1500/AirframeGeometry.gd")
const SURFACE_COLOUR := Color(0.30, 0.31, 0.34)
const SURFACE_GAP: float = 0.006
## Render layer the propeller and spinner live on, so the FPV camera can leave
## them out. A tractor model's disc sits directly in front of any camera mounted
## behind it, and from inside the aircraft it fills the view - which is what a
## real FPV pilot fits the camera above or ahead of the disc to avoid.
const PROPELLER_LAYER: int = 2
const PLATE_THICKNESS: float = 0.008
## Sign relating the flight model's deflection to a rotation about the pivot's
## own X axis. Pinned by the in-engine check in tests/HeadlessTests.gd, which
## commands a roll and asserts the correct aileron rises.
const HINGE_SIGN: float = 1.0

@export var simulation_path: NodePath
## Draw the local airflow and lift vector at each section.
@export var show_debug_vectors: bool = false

var _sim: RCSimulationNode
var _built: bool = false
var _propeller: Node3D
var _debug: ImmediateMesh
var _spin: float = 0.0
var _surfaces: Array[Dictionary] = []


func _ready() -> void:
	_sim = get_node_or_null(simulation_path) as RCSimulationNode


func _process(delta: float) -> void:
	if _sim == null:
		return
	if not _built and _sim.is_aircraft_loaded() and _sim.get_section_count() > 0:
		_build()
		_built = true

	if _propeller != null:
		# Spun visually rather than physically: at 9000 rpm the disc is a blur
		# anyway, so this is scaled down to something the eye can follow and
		# read as "the motor is running".
		_spin += delta * _sim.get_rpm() * 0.012
		_propeller.rotation.z = _spin

	_update_surfaces()

	if show_debug_vectors and _debug != null:
		_draw_debug_vectors()


func _material(colour: Color, unshaded: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	# Painted film over foam: not a mirror, but not the flat matte everything
	# used to be either. A surface with no specular response at all is most of
	# why the aircraft read as paper.
	material.roughness = 0.42
	material.metallic = 0.0
	material.metallic_specular = 0.45
	if unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.roughness = 1.0
	return material


## Clear canopy: dark, smooth and slightly reflective. The one part of a model
## that catches the sun, and the thing that most makes it read as a real object.
func _canopy_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.06, 0.09, 0.13, 0.62)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 0.06
	material.metallic = 0.0
	material.metallic_specular = 0.9
	material.rim_enabled = true
	material.rim = 0.6
	return material


## Rubber. Dark, rough, no specular to speak of.
func _tyre_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.022, 0.024, 0.028)
	material.roughness = 0.92
	material.metallic_specular = 0.2
	return material


## Bare aluminium and the spinner: the only genuinely metallic parts.
func _metal_material(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.22
	material.metallic = 0.85
	return material


## A flat panel for one aerodynamic section, in Godot axes.
## `position` is the quarter chord relative to the CG; the panel runs a quarter
## chord forward and three quarters aft, and `span` wide along its own axis.
##
## A section carrying a control surface is built as two pieces - the fixed part
## ahead of the hinge line and the moving part behind it, parented to a pivot at
## the hinge. The pivot is driven every frame from the deflection the flight
## model integrated, so what the pilot watches move is the same number the
## aerodynamics used, not a separate animation off the stick.
func _panel(index: int, centre: Vector3, span_axis: Vector3, span: float,
			chord: float, pitch: float, colour: Color, name_hint: String,
			is_tip: bool = false, is_root: bool = false) -> void:
	# Build a basis whose X runs along the span and whose Z runs along the chord.
	var x_axis: Vector3 = span_axis.normalized()
	var z_axis: Vector3 = Vector3(0, 0, 1)
	var y_axis: Vector3 = z_axis.cross(x_axis).normalized()
	z_axis = x_axis.cross(y_axis).normalized()
	var basis := Basis(x_axis, y_axis, z_axis)
	# Rigging angle: leading edge up is a nose-up rotation about the span axis.
	basis = basis.rotated(x_axis, -pitch)

	var leading_edge: Vector3 = centre - basis.z * (chord * 0.25)

	# A fin is thinner and uncambered; a wing carries the flat-bottomed trainer
	# section it actually flies.
	var is_fin: bool = name_hint.begins_with("vtail")
	var thickness: float = 0.09 if name_hint.find("tail") >= 0 else 0.13
	var camber: float = 0.0 if name_hint.find("tail") >= 0 else 0.025

	if not _sim.get_section_has_control(index):
		_plate(basis, leading_edge, span, chord, colour, "sec_" + name_hint,
			   is_tip, thickness, camber, 1.0, is_root)
		return

	# Hinge line as a fraction of chord back from the leading edge.
	var moving_chord: float = chord * _sim.get_section_control_chord_fraction(index)
	var fixed_chord: float = chord - moving_chord
	var moving_span: float = span * _sim.get_section_control_span_fraction(index)

	# The full-chord section, truncated at the hinge - not a whole aerofoil
	# squashed into three quarters of the chord, which is what left a sharp
	# edge where the wing should still have been 8 % thick.
	var hinge_fraction: float = fixed_chord / chord
	_plate(basis, leading_edge, span, chord, colour, "sec_" + name_hint,
		   is_tip, thickness, camber, hinge_fraction, is_root)

	# Where the control surface does not span the whole section, the rest of
	# the chord has to be wing. Without this the aileron's span was drawn and
	# the remainder was a hole - a deep scoop bitten out of the trailing edge
	# just inboard of every aileron, which the turntable made impossible to
	# miss and flight scale had always hidden.
	var filler_span: float = span - moving_span
	if filler_span > 0.004:
		var filler_centre: Vector3 = leading_edge \
				+ basis.z * fixed_chord \
				- basis.x * (span - filler_span) * 0.5
		_plate(basis, filler_centre, filler_span, moving_chord, colour,
			   "fill_" + name_hint, false, thickness * 0.8, 0.0)

	var pivot := Node3D.new()
	pivot.name = "hinge_" + name_hint
	pivot.transform = Transform3D(basis, leading_edge + basis.z * fixed_chord)
	add_child(pivot)

	# The moving surface hangs off the pivot in the pivot's own frame, so
	# rotating the pivot about its X axis swings the trailing edge.
	var surface := MeshInstance3D.new()
	surface.name = "surface_" + name_hint
	# A tapering wedge, thick at the hinge and thin at the trailing edge, which
	# is what a control surface is. A slab of constant thickness is visible as
	# a step every time it deflects.
	var moving_span_clear: float = moving_span - SURFACE_GAP
	# Thickness matched to the wing AT THE HINGE, so the two meet flush. The
	# aerofoil's own thickness at 75 % chord is about half its maximum.
	var hinge_thickness: float = thickness * 0.55
	surface.mesh = AirframeScript.loft_wing([
		{"offset": -moving_span_clear * 0.5, "chord": moving_chord,
		 "thickness": hinge_thickness, "camber": 0.0},
		{"offset":  moving_span_clear * 0.5, "chord": moving_chord,
		 "thickness": hinge_thickness, "camber": 0.0},
	], 10, is_tip)
	surface.material_override = _material(SURFACE_COLOUR)
	# Same quarter-chord origin, so the aileron's leading edge lands on the
	# hinge line rather than a quarter of its own chord behind it.
	surface.position = Vector3(0.0, 0.0, moving_chord * 0.25)
	pivot.add_child(surface)

	_surfaces.append({"pivot": pivot, "index": index})


## One aerodynamic surface, lofted from its actual airfoil rather than drawn as
## a plate, and positioned from its leading edge so a split section's two halves
## meet exactly at the hinge.
##
## `outboard` closes the far end with a rounded tip instead of a flat cap; only
## the outermost panel of a wing or tailplane wants that.
func _plate(basis: Basis, leading_edge: Vector3, span: float, chord: float,
			colour: Color, name_hint: String, outboard: bool = false,
			thickness: float = 0.12, camber: float = 0.02,
			cut: float = 1.0, cap_root: bool = true) -> void:
	# Two stations is enough for a constant-chord panel; the rounded tip adds
	# its own. Taper would go here if the definition carried it.
	var stations: Array = [
		{"offset": -span * 0.5, "chord": chord, "thickness": thickness,
		 "camber": camber, "cut": cut},
		{"offset":  span * 0.5, "chord": chord, "thickness": thickness,
		 "camber": camber, "cut": cut},
	]

	var instance := MeshInstance3D.new()
	instance.name = name_hint
	instance.mesh = AirframeScript.loft_wing(stations, 14, outboard, cap_root)
	instance.material_override = _material(colour)
	# The loft's ORIGIN is its quarter chord, not its leading edge: _ring pivots
	# the profile about 0.25c so a twisted tip stays where it is rigged from.
	# Placing it as though the origin were the leading edge slid every panel a
	# quarter of a chord aft - which put the wing's trailing edge a quarter
	# chord BEHIND the aileron hinge, so every control surface was buried
	# inside the wing in front of it and the overlap read as a scoop bitten out
	# of the trailing edge.
	instance.transform = Transform3D(basis, leading_edge + basis.z * (chord * 0.25))
	add_child(instance)


## Swing every control surface to the deflection the flight model is holding.
func _update_surfaces() -> void:
	for entry in _surfaces:
		var pivot: Node3D = entry["pivot"]
		var degrees: float = _sim.get_section_control_deflection_deg(entry["index"])
		# Positive is trailing edge down in the section's own frame, which is the
		# frame the pivot was built in - so the sign carries straight across.
		pivot.rotation = Vector3(deg_to_rad(degrees) * HINGE_SIGN, 0.0, 0.0)


## Throws away the built aeroplane and builds the one the simulation node is
## now holding. Used by the hangar, where changing the selection changes the
## aeroplane on the stand; in flight the model is freed and made again instead.
func rebuild() -> void:
	for child in get_children():
		child.queue_free()
	_surfaces.clear()
	_propeller = null
	_debug = null
	_built = false


func _build() -> void:
	var span_total: float = 0.0
	var nose_z: float = 0.0
	var tail_z: float = 0.0

	# Sections, gathered and grouped by the surface they belong to.
	#
	# They used to be drawn one at a time, each a closed body at its own angle
	# and its own height. A wing of four such panels is a staircase: the
	# dihedral steps, the washout steps, and eleven flat end caps sit buried
	# inside their neighbours shading against them. It read as a stack of
	# plates because that is what it was. A wing is one surface, so it is
	# lofted as one - through a station at every section boundary, twisting as
	# it goes - and only breaks where the colour scheme breaks.
	var groups: Dictionary = {}
	for i in _sim.get_section_count():
		var centre: Vector3 = _sim.get_section_position(i)
		var name_hint: String = _sim.get_section_name(i)
		var is_fin: bool = name_hint.begins_with("vtail")

		var axis: Vector3 = Vector3.UP
		if not is_fin:
			var side: float = signf(centre.x) if absf(centre.x) > 1e-4 else 1.0
			var dihedral: float = deg_to_rad(_sim.get_section_dihedral_deg(i))
			axis = Vector3(side * cos(dihedral), sin(dihedral), 0.0)

		# The underside of the outer wing panels is the trim colour, which is
		# what a real trainer does and what makes the aircraft's attitude
		# readable from a hundred metres away.
		var outer: bool = name_hint.find("_3") >= 0 or name_hint.find("_4") >= 0
		var section := {
			"index": i,
			"centre": centre,
			"name": name_hint,
			"axis": axis,
			"span": _sim.get_section_span_m(i),
			"chord": _sim.get_section_chord_m(i),
			"twist": deg_to_rad(_sim.get_section_incidence_deg(i)),
			"colour": TRIM_COLOUR if (name_hint.find("tail") >= 0 or outer) \
					else TRUNK_COLOUR,
			"thickness": 0.09 if name_hint.find("tail") >= 0 else 0.13,
			"camber": 0.0 if name_hint.find("tail") >= 0 else 0.025,
			"control": _sim.get_section_has_control(i),
		}
		var key: String = _group_key(name_hint)
		if not groups.has(key):
			groups[key] = []
		groups[key].append(section)

		span_total = maxf(span_total, absf(centre.x) + section["span"] * 0.5)
		nose_z = minf(nose_z, centre.z)
		tail_z = maxf(tail_z, centre.z)

	for key in groups:
		var list: Array = groups[key]
		var axis: Vector3 = list[0]["axis"]
		# Root first. Sorted by how far along the span each section sits, so a
		# left wing and a right wing both run inboard to outboard.
		list.sort_custom(func(a, b) -> bool:
			return (a["centre"] as Vector3).dot(axis) < (b["centre"] as Vector3).dot(axis))
		_build_surface(list)
		for section in list:
			if section["control"]:
				_control_surface(section)

	# Where the body actually runs.
	#
	# Lofted between the outermost AERODYNAMIC sections it started 9 mm ahead
	# of the CG, so the propeller - placed from the definition - hung a third
	# of a metre off the front of nothing. The definition's body is the only
	# thing that knows where the nose is; the sections are the only thing that
	# knows where the fin is. The union of the two is the whole aeroplane.
	var extent: Vector2 = _sim.get_fuselage_extent_z()
	if extent.y > extent.x:
		nose_z = minf(nose_z, extent.x)
		tail_z = maxf(tail_z, extent.y)
	_build_fuselage(nose_z, tail_z)
	_build_gear()
	_build_propeller()

	if show_debug_vectors:
		var debug_instance := MeshInstance3D.new()
		debug_instance.name = "DebugVectors"
		_debug = ImmediateMesh.new()
		debug_instance.mesh = _debug
		debug_instance.material_override = _material(Color(1, 1, 1), true)
		debug_instance.top_level = true
		add_child(debug_instance)


## Which surface a section belongs to: "wing_right_1_root" and "wing_right_4_tip"
## are both the right wing, and have to be lofted as one piece.
static func _group_key(section_name: String) -> String:
	var parts: PackedStringArray = section_name.split("_", false)
	var kept := PackedStringArray()
	for part in parts:
		if part.is_valid_int() or part == "root" or part == "tip":
			continue
		kept.append(part)
	return "_".join(kept)


## One surface, lofted through every section in it.
##
## Broken only where the colour scheme breaks, because one mesh carries one
## material - and a colour change is a seam that is SUPPOSED to be visible.
func _build_surface(sections: Array) -> void:
	var axis: Vector3 = sections[0]["axis"]
	var root: Vector3 = (sections[0]["centre"] as Vector3) \
			- axis * float(sections[0]["span"]) * 0.5

	# Where each section starts and ends along the span, from the root.
	var edges := PackedFloat64Array([0.0])
	for section in sections:
		edges.append(edges[edges.size() - 1] + float(section["span"]))

	var run_start: int = 0
	while run_start < sections.size():
		var run_end: int = run_start
		var colour: Color = sections[run_start]["colour"]
		while run_end + 1 < sections.size() \
				and (sections[run_end + 1]["colour"] as Color) == colour:
			run_end += 1

		# The cut is uniform across the run and takes the deepest hinge in it,
		# so the wing never grows out over a control surface behind it.
		var cut: float = 1.0
		for k in range(run_start, run_end + 1):
			if sections[k]["control"]:
				cut = minf(cut, 1.0 - _sim.get_section_control_chord_fraction(
						int(sections[k]["index"])))

		# A station at every boundary in the run, each blending the sections
		# that meet there: that is what makes the surface continuous instead of
		# a staircase.
		var stations: Array = []
		for k in range(run_start, run_end + 2):
			var inner: Dictionary = sections[maxi(k - 1, run_start)]
			var outer: Dictionary = sections[mini(k, run_end)]
			stations.append({
				"offset": edges[k] - edges[run_start],
				"chord": (float(inner["chord"]) + float(outer["chord"])) * 0.5,
				"thickness": (float(inner["thickness"]) + float(outer["thickness"])) * 0.5,
				"camber": (float(inner["camber"]) + float(outer["camber"])) * 0.5,
				"twist": (float(inner["twist"]) + float(outer["twist"])) * 0.5,
				"cut": cut,
			})

		var instance := MeshInstance3D.new()
		instance.name = "surface_%s_%d" % [_group_key(sections[run_start]["name"]), run_start]
		instance.mesh = AirframeScript.loft_wing(stations, 14,
				run_end == sections.size() - 1, run_start == 0)
		instance.material_override = _material(colour)
		instance.transform = Transform3D(_span_basis(axis),
										 root + axis * float(edges[run_start]))
		add_child(instance)

		run_start = run_end + 1


## A frame whose X runs along the span and whose Z runs along the chord.
##
## No pitch rotation: incidence and washout are per-station twist inside the
## loft, which is the only way a wing that twists along its span can also be
## continuous along it.
static func _span_basis(axis: Vector3) -> Basis:
	var x_axis: Vector3 = axis.normalized()
	var z_axis := Vector3(0, 0, 1)
	var y_axis: Vector3 = z_axis.cross(x_axis).normalized()
	z_axis = x_axis.cross(y_axis).normalized()
	return Basis(x_axis, y_axis, z_axis)


## The moving part of a section: an aileron, an elevator, a rudder.
func _control_surface(section: Dictionary) -> void:
	var index: int = int(section["index"])
	var centre: Vector3 = section["centre"]
	var axis: Vector3 = section["axis"]
	var chord: float = float(section["chord"])
	var basis: Basis = _span_basis(axis).rotated(axis.normalized(), -float(section["twist"]))
	var leading_edge: Vector3 = centre - basis.z * (chord * 0.25)

	var moving_chord: float = chord * _sim.get_section_control_chord_fraction(index)
	var fixed_chord: float = chord - moving_chord
	var moving_span: float = float(section["span"]) \
			* _sim.get_section_control_span_fraction(index)

	var pivot := Node3D.new()
	pivot.name = "hinge_%s" % section["name"]
	pivot.transform = Transform3D(basis, leading_edge + basis.z * fixed_chord)
	add_child(pivot)

	var surface := MeshInstance3D.new()
	surface.name = "surface_%s" % section["name"]
	# A tapering wedge, thick at the hinge and thin at the trailing edge, which
	# is what a control surface is. Its thickness matches the wing AT THE HINGE
	# - about half the section's maximum - so the two meet flush.
	var moving_span_clear: float = moving_span - SURFACE_GAP
	var hinge_thickness: float = float(section["thickness"]) * 0.55
	surface.mesh = AirframeScript.loft_wing([
		{"offset": -moving_span_clear * 0.5, "chord": moving_chord,
		 "thickness": hinge_thickness, "camber": 0.0},
		{"offset":  moving_span_clear * 0.5, "chord": moving_chord,
		 "thickness": hinge_thickness, "camber": 0.0},
	], 10, section["name"].find("_4") >= 0 or section["name"].find("tail") >= 0)
	surface.material_override = _material(SURFACE_COLOUR)
	# The loft's origin is its quarter chord, so the leading edge lands on the
	# hinge line rather than a quarter of its own chord behind it.
	surface.position = Vector3(0.0, 0.0, moving_chord * 0.25)
	pivot.add_child(surface)

	_surfaces.append({"pivot": pivot, "index": index})


func _build_fuselage(nose_z: float, tail_z: float) -> void:
	# A real trainer's pod: round at the nose, full through the cockpit, slab
	# and tapering at the tail. The old fuselage was a box, and a box is the
	# thing that read as a paper model from the pilot's seat.
	# One continuous loft from the nose to the tail: the fuselage must not read
	# as a bulb stuck onto a box, which is what the first loft did. More
	# stations, a softer mid-section, and the tail tapers all the way.
	var stations := [
		{"z": nose_z - 0.10, "width": 0.015, "height": 0.022, "offset_y": 0.0, "corner": 0.0},
		{"z": nose_z + 0.0, "width": 0.062, "height": 0.072, "offset_y": 0.0, "corner": 0.2},
		{"z": nose_z + 0.12, "width": 0.092, "height": 0.100, "offset_y": 0.0, "corner": 0.3},
		{"z": nose_z + 0.28, "width": 0.108, "height": 0.116, "offset_y": 0.0, "corner": 0.4},
		{"z": 0.0, "width": 0.112, "height": 0.122, "offset_y": -0.006, "corner": 0.45},
		{"z": tail_z * 0.22, "width": 0.100, "height": 0.110, "offset_y": -0.006, "corner": 0.55},
		{"z": tail_z * 0.45, "width": 0.082, "height": 0.094, "offset_y": -0.004, "corner": 0.62},
		{"z": tail_z * 0.68, "width": 0.060, "height": 0.072, "offset_y": 0.0, "corner": 0.72},
		{"z": tail_z * 0.90, "width": 0.038, "height": 0.050, "offset_y": 0.006, "corner": 0.8},
		{"z": tail_z + 0.04, "width": 0.024, "height": 0.034, "offset_y": 0.010, "corner": 0.85},
	]
	var instance := MeshInstance3D.new()
	instance.name = "Fuselage"
	instance.mesh = AirframeScript.loft_body(stations, 18)
	instance.material_override = _material(TRUNK_COLOUR)
	add_child(instance)

	# The trim band: a second loft a few millimetres proud of the mid-fuselage,
	# so the paint scheme is painted on rather than a box bolted to the side.
	var band_stations: Array = []
	for station in stations:
		if station["z"] < nose_z + 0.15 or station["z"] > tail_z * 0.85:
			continue
		band_stations.append({
			"z": station["z"],
			"width": station["width"] + 0.009,
			"height": station["height"] + 0.009,
			"offset_y": station["offset_y"],
			"corner": station["corner"],
		})
	if band_stations.size() >= 2:
		var band := MeshInstance3D.new()
		band.name = "TrimBand"
		band.mesh = AirframeScript.loft_body(band_stations, 18)
		band.material_override = _material(TRIM_COLOUR)
		add_child(band)

	_build_canopy(nose_z)


## The canopy: a glassy pod over the cockpit, and the pilot inside it. A
## model without a pilot reads as a shell; one with a head in the canopy is an
## aeroplane with someone in it, and at the distances a trainer is flown the
## head is what the eye finds first.
func _build_canopy(nose_z: float) -> void:
	var stations := [
		{"z": nose_z + 0.34, "width": 0.02, "height": 0.018, "offset_y": 0.052, "corner": 0.2},
		{"z": nose_z + 0.44, "width": 0.078, "height": 0.050, "offset_y": 0.062, "corner": 0.25},
		{"z": nose_z + 0.56, "width": 0.080, "height": 0.052, "offset_y": 0.064, "corner": 0.25},
		{"z": nose_z + 0.70, "width": 0.042, "height": 0.030, "offset_y": 0.052, "corner": 0.25},
	]
	var canopy := MeshInstance3D.new()
	canopy.name = "Canopy"
	canopy.mesh = AirframeScript.loft_body(stations, 14)
	canopy.material_override = _canopy_material()
	add_child(canopy)

	# The pilot: head, shoulders, and a hand that might be on the stick.
	var pilot := Node3D.new()
	pilot.name = "Pilot"
	var head := MeshInstance3D.new()
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.021
	head_mesh.height = 0.042
	head.mesh = head_mesh
	head.material_override = _material(Color(0.85, 0.72, 0.58))
	head.position = Vector3(0.0, 0.055, nose_z + 0.56)
	pilot.add_child(head)

	var helmet := MeshInstance3D.new()
	var helmet_mesh := SphereMesh.new()
	helmet_mesh.radius = 0.021
	helmet_mesh.height = 0.042
	helmet.mesh = helmet_mesh
	helmet.material_override = _material(DARK_COLOUR)
	# Sits on the head; the face shows forward under the visor.
	helmet.rotation_degrees = Vector3(35.0, 0.0, 0.0)
	helmet.position = head.position
	pilot.add_child(helmet)

	var shoulders := MeshInstance3D.new()
	var shoulder_mesh := SphereMesh.new()
	shoulder_mesh.radius = 0.030
	shoulder_mesh.height = 0.05
	shoulder_mesh.radial_segments = 10
	shoulder_mesh.rings = 6
	shoulders.mesh = shoulder_mesh
	shoulders.material_override = _material(TRIM_COLOUR)
	shoulders.position = Vector3(0.0, 0.028, nose_z + 0.55)
	shoulders.scale = Vector3(1.0, 0.7, 0.85)
	pilot.add_child(shoulders)
	add_child(pilot)


func _build_gear() -> void:
	for i in _sim.get_wheel_count():
		var hub: Vector3 = _sim.get_wheel_position(i)
		var radius: float = _sim.get_wheel_radius_m(i)
		# A wheel with no lateral offset is the one under the nose; the ones
		# out on the axles are the mains. Told apart by where they ARE, not by
		# their index - the old code spatted wheels 0 and 1, which on every
		# aeroplane in the roster is the nose wheel and the left main.
		var is_nose: bool = absf(hub.x) < 0.02

		# The leg. A trainer's main gear is a single wire splayed out from the
		# belly, so the strut leans; a nose leg drops straight down.
		var top := Vector3(hub.x * (0.18 if not is_nose else 1.0),
						   hub.y + radius * 0.6 + (0.10 if not is_nose else 0.11),
						   hub.z)
		_strut(top, hub + Vector3(0.0, 0.0, 0.0), 0.0075 if is_nose else 0.006)

		# The tyre, and a hub inside it. One dark cylinder reads as a puck;
		# it is the light hub against dark rubber that reads as a wheel.
		var tyre := MeshInstance3D.new()
		tyre.name = "Wheel%d" % i
		var tyre_mesh := CylinderMesh.new()
		tyre_mesh.top_radius = radius
		tyre_mesh.bottom_radius = radius
		tyre_mesh.height = radius * 0.62
		tyre_mesh.radial_segments = 20
		tyre.mesh = tyre_mesh
		tyre.material_override = _tyre_material()
		tyre.rotation_degrees = Vector3(0, 0, 90)
		tyre.position = hub
		add_child(tyre)

		for side in 2:
			var face := MeshInstance3D.new()
			face.name = "Hub%d_%d" % [i, side]
			var face_mesh := CylinderMesh.new()
			face_mesh.top_radius = radius * 0.52
			face_mesh.bottom_radius = radius * 0.52
			face_mesh.height = radius * 0.10
			face_mesh.radial_segments = 16
			face.mesh = face_mesh
			face.material_override = _metal_material(Color(0.72, 0.74, 0.78))
			face.rotation_degrees = Vector3(0, 0, 90)
			face.position = hub + Vector3(
				(radius * 0.34) * (1.0 if side == 0 else -1.0), 0.0, 0.0)
			add_child(face)


## One landing gear leg, as a cylinder running from `top` to `bottom`.
##
## The old strut was an axis-aligned box from the centreline down to the hub,
## which for a splayed main leg is not where the leg is.
func _strut(top: Vector3, bottom: Vector3, radius: float) -> void:
	var span: Vector3 = bottom - top
	var length: float = span.length()
	if length < 0.005:
		return
	var leg := MeshInstance3D.new()
	leg.name = "Strut"
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius * 0.85
	mesh.height = length
	mesh.radial_segments = 10
	leg.mesh = mesh
	leg.material_override = _metal_material(Color(0.30, 0.32, 0.36))
	leg.position = top + span * 0.5
	# A cylinder stands along its own Y, so the leg is rotated to lie along the
	# line it has to cover.
	var axis: Vector3 = Vector3.UP.cross(span.normalized())
	if axis.length() > 1e-4:
		leg.rotate(axis.normalized(), Vector3.UP.angle_to(span.normalized()))
	add_child(leg)


## The propeller and its spinner, at the motor mount the definition gives.
func _build_propeller() -> void:
	var mount: Vector3 = _sim.get_motor_position()
	var diameter: float = _sim.get_propeller_diameter_m()

	var hub := MeshInstance3D.new()
	hub.name = "Spinner"
	# A tapered spinner, not a ball: the cone is what reads as a nose at rest,
	# and it is what the eye checks for a propeller in front of it.
	var hub_mesh := CylinderMesh.new()
	hub_mesh.top_radius = 0.007
	hub_mesh.bottom_radius = 0.028
	hub_mesh.height = 0.060
	hub_mesh.radial_segments = 14
	hub.mesh = hub_mesh
	hub.material_override = _metal_material(TRIM_COLOUR)
	hub.layers = PROPELLER_LAYER
	hub.rotation_degrees = Vector3(90, 0, 0)
	hub.position = mount - Vector3(0, 0, 0.045)
	add_child(hub)

	_propeller = Node3D.new()
	_propeller.name = "Propeller"
	_propeller.position = mount + Vector3(0, 0, -0.012)
	add_child(_propeller)

	# Blades that are blades: tapered from a wide root to a narrow tip, and
	# twisted so the pitch goes from steep at the hub to flat at the tip - the
	# same distribution a real prop has. The old blades were flat boxes, and a
	# flat box spinning reads as a ruler.
	# Blade chords are set so the prop reads at rest: a thin blade at the
	# scales a 1.5 m trainer draws at is invisible, and an invisible propeller
	# makes a parked model look like a sculpture with a spinner on it.
	# Generous chords: the first attempt was airfoil-thin, and a blade that is
	# a hairline against the sky is a propeller that does not exist at rest.
	# Blade chords as a fraction of the diameter, near what a 10x5 sport
	# propeller actually is. They were 23 % of the diameter at the root, which
	# is a paddle: broadside on, the pair read as a brown ellipse bolted to the
	# nose rather than as two blades.
	var blade_mesh: ArrayMesh = AirframeScript.loft_wing([
		{"offset": 0.012, "chord": diameter * 0.135, "thickness": 0.14, "twist": 0.40},
		{"offset": diameter * 0.28, "chord": diameter * 0.105, "thickness": 0.12,
		 "twist": 0.20},
		{"offset": diameter * 0.48, "chord": diameter * 0.055, "thickness": 0.10,
		 "twist": 0.05},
	], 8, true)
	for blade_index in 2:
		var blade := MeshInstance3D.new()
		blade.name = "Blade%d" % blade_index
		blade.mesh = blade_mesh
		# A warm dark rather than near-black: a dark blade against dark ground
		# is invisible, and an invisible blade is an antenna with a spinner.
		blade.material_override = _material(Color(0.30, 0.26, 0.22))
		blade.layers = PROPELLER_LAYER
		# The loft already runs from the hub outward along its own X, so the
		# rotation is the whole placement. It used to also be translated a
		# quarter of a diameter sideways - along X, while the blade pointed
		# along Y - so each blade grew out of thin air beside the spinner and
		# the propeller read as a shark fin bolted to the nose.
		blade.rotation_degrees = Vector3(0.0, 0.0, 90.0 + 180.0 * float(blade_index))
		_propeller.add_child(blade)


func _draw_debug_vectors() -> void:
	_debug.clear_surfaces()
	_debug.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in _sim.get_section_count():
		var origin: Vector3 = global_transform * _sim.get_section_position(i)
		var lift: Vector3 = global_transform.basis * _sim.get_section_lift_direction(i)
		var magnitude: float = clampf(_sim.get_section_lift_n(i) * 0.05, -1.0, 1.0)
		var separation: float = _sim.get_section_separation(i)
		_debug.surface_set_color(Color(separation, 1.0 - separation, 0.2))
		_debug.surface_add_vertex(origin)
		_debug.surface_add_vertex(origin + lift * magnitude)
	_debug.surface_end()
