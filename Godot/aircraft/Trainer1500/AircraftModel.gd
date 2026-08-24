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
			is_tip: bool = false) -> void:
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
			   is_tip, thickness, camber)
		return

	# Hinge line as a fraction of chord back from the leading edge.
	var moving_chord: float = chord * _sim.get_section_control_chord_fraction(index)
	var fixed_chord: float = chord - moving_chord
	var moving_span: float = span * _sim.get_section_control_span_fraction(index)

	_plate(basis, leading_edge, span, fixed_chord, colour, "sec_" + name_hint,
		   is_tip, thickness, camber)

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
	surface.mesh = AirframeScript.loft_wing([
		{"offset": -moving_span_clear * 0.5, "chord": moving_chord,
		 "thickness": thickness * 0.8, "camber": 0.0},
		{"offset":  moving_span_clear * 0.5, "chord": moving_chord,
		 "thickness": thickness * 0.8, "camber": 0.0},
	], 10, is_tip)
	surface.material_override = _material(SURFACE_COLOUR)
	surface.position = Vector3(0.0, 0.0, moving_chord * 0.5)
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
			thickness: float = 0.12, camber: float = 0.02) -> void:
	# Two stations is enough for a constant-chord panel; the rounded tip adds
	# its own. Taper would go here if the definition carried it.
	var stations: Array = [
		{"offset": -span * 0.5, "chord": chord, "thickness": thickness, "camber": camber},
		{"offset":  span * 0.5, "chord": chord, "thickness": thickness, "camber": camber},
	]

	var instance := MeshInstance3D.new()
	instance.name = name_hint
	instance.mesh = AirframeScript.loft_wing(stations, 14, outboard)
	instance.material_override = _material(colour)
	# The loft is built about its own mid-span with the chord running along +Z
	# from the leading edge, so it lands at the panel centre.
	instance.transform = Transform3D(basis, leading_edge + basis.z * (chord * 0.5))
	add_child(instance)


## Swing every control surface to the deflection the flight model is holding.
func _update_surfaces() -> void:
	for entry in _surfaces:
		var pivot: Node3D = entry["pivot"]
		var degrees: float = _sim.get_section_control_deflection_deg(entry["index"])
		# Positive is trailing edge down in the section's own frame, which is the
		# frame the pivot was built in - so the sign carries straight across.
		pivot.rotation = Vector3(deg_to_rad(degrees) * HINGE_SIGN, 0.0, 0.0)


func _build() -> void:
	var span_total: float = 0.0
	var nose_z: float = 0.0
	var tail_z: float = 0.0

	for i in _sim.get_section_count():
		# Section positions come back already in Godot axes.
		var centre: Vector3 = _sim.get_section_position(i)
		var name_hint: String = _sim.get_section_name(i)

		var is_fin: bool = name_hint.begins_with("vtail")
		var span_axis: Vector3 = Vector3.UP if is_fin else Vector3.RIGHT
		var span: float = _sim.get_section_span_m(i)
		var chord: float = _sim.get_section_chord_m(i)
		var incidence: float = deg_to_rad(_sim.get_section_incidence_deg(i))

		# Dihedral tilts each panel outward-and-up, taken from the same angle the
		# aerodynamics uses. Without it the wing draws flat while the physics
		# flies it with dihedral, and the two disagree about the aircraft.
		if not is_fin:
			var side: float = signf(centre.x) if absf(centre.x) > 1e-4 else 1.0
			var dihedral: float = deg_to_rad(_sim.get_section_dihedral_deg(i))
			span_axis = Vector3(side * cos(dihedral), sin(dihedral), 0.0)

		# The underside of the outer wing panels is the trim colour, which is what
		# a real trainer does and what makes the aircraft's attitude readable
		# from a hundred metres away.
		var outer: bool = name_hint.find("_3") >= 0 or name_hint.find("_4") >= 0
		var colour: Color = TRIM_COLOUR if (name_hint.find("tail") >= 0 or outer) \
			else TRUNK_COLOUR
		# Only the outermost panel of a surface gets a rounded tip; the inboard
		# ones butt against their neighbour.
		var is_tip: bool = name_hint.find("_4") >= 0 or name_hint.find("tail") >= 0
		_panel(i, centre, span_axis, span, chord, incidence, colour, name_hint, is_tip)

		span_total = maxf(span_total, absf(centre.x) + span * 0.5)
		nose_z = minf(nose_z, centre.z)
		tail_z = maxf(tail_z, centre.z)

	_build_fuselage(nose_z, tail_z)
	_build_gear()
	_build_propeller(nose_z)

	if show_debug_vectors:
		var debug_instance := MeshInstance3D.new()
		debug_instance.name = "DebugVectors"
		_debug = ImmediateMesh.new()
		debug_instance.mesh = _debug
		debug_instance.material_override = _material(Color(1, 1, 1), true)
		debug_instance.top_level = true
		add_child(debug_instance)


func _build_fuselage(nose_z: float, tail_z: float) -> void:
	var length: float = maxf(tail_z - nose_z, 0.5) + 0.35
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.075, 0.105, length)

	var instance := MeshInstance3D.new()
	instance.name = "Fuselage"
	instance.mesh = mesh
	instance.material_override = _material(TRUNK_COLOUR)
	instance.position = Vector3(0.0, -0.03, (nose_z + tail_z) * 0.5)
	add_child(instance)

	var stripe := MeshInstance3D.new()
	stripe.name = "Stripe"
	var stripe_mesh := BoxMesh.new()
	stripe_mesh.size = Vector3(0.078, 0.022, length * 0.9)
	stripe.mesh = stripe_mesh
	stripe.material_override = _material(TRIM_COLOUR)
	stripe.position = instance.position + Vector3(0.0, 0.015, 0.0)
	add_child(stripe)


func _build_gear() -> void:
	for i in _sim.get_wheel_count():
		var centre: Vector3 = _sim.get_wheel_position(i)
		var radius: float = _sim.get_wheel_radius_m(i)

		var strut := MeshInstance3D.new()
		var strut_mesh := BoxMesh.new()
		strut_mesh.size = Vector3(0.012, absf(centre.y), 0.012)
		strut.mesh = strut_mesh
		strut.material_override = _material(DARK_COLOUR)
		strut.position = Vector3(centre.x, centre.y * 0.5, centre.z)
		add_child(strut)

		var wheel := MeshInstance3D.new()
		wheel.name = "Wheel%d" % i
		var wheel_mesh := CylinderMesh.new()
		wheel_mesh.top_radius = radius
		wheel_mesh.bottom_radius = radius
		wheel_mesh.height = 0.016
		wheel_mesh.radial_segments = 12
		wheel.mesh = wheel_mesh
		wheel.material_override = _material(DARK_COLOUR)
		wheel.rotation_degrees = Vector3(0, 0, 90)
		wheel.position = centre
		add_child(wheel)


func _build_propeller(nose_z: float) -> void:
	var mount: Vector3 = _sim.get_motor_position()
	var diameter: float = _sim.get_propeller_diameter_m()

	var hub := MeshInstance3D.new()
	hub.name = "Spinner"
	var hub_mesh := SphereMesh.new()
	hub_mesh.radius = 0.022
	hub_mesh.height = 0.055
	hub.mesh = hub_mesh
	hub.material_override = _metal_material(TRIM_COLOUR)
	hub.layers = PROPELLER_LAYER
	hub.position = mount
	add_child(hub)

	_propeller = Node3D.new()
	_propeller.name = "Propeller"
	_propeller.position = mount + Vector3(0, 0, -0.012)
	add_child(_propeller)

	for blade_index in 2:
		var blade := MeshInstance3D.new()
		var blade_mesh := BoxMesh.new()
		blade_mesh.size = Vector3(diameter * 0.48, 0.018, 0.004)
		blade.mesh = blade_mesh
		blade.material_override = _material(DARK_COLOUR)
		blade.layers = PROPELLER_LAYER
		blade.rotation_degrees = Vector3(0, 0, 180.0 * float(blade_index))
		blade.position = Vector3(cos(PI * float(blade_index)) * diameter * 0.24,
								 sin(PI * float(blade_index)) * diameter * 0.24, 0.0)
		_propeller.add_child(blade)
	# nose_z is unused beyond keeping the signature explicit about where the
	# front of the aircraft is.
	if nose_z > 1e9:
		push_warning("unreachable")


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
