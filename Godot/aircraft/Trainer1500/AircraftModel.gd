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

@export var simulation_path: NodePath
## Draw the local airflow and lift vector at each section.
@export var show_debug_vectors: bool = false

var _sim: RCSimulationNode
var _built: bool = false
var _propeller: Node3D
var _debug: ImmediateMesh
var _spin: float = 0.0


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

	if show_debug_vectors and _debug != null:
		_draw_debug_vectors()


func _material(colour: Color, unshaded: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.55
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


## A flat panel for one aerodynamic section, in Godot axes.
## `position` is the quarter chord relative to the CG; the panel runs a quarter
## chord forward and three quarters aft, and `span` wide along its own axis.
func _panel(centre: Vector3, span_axis: Vector3, span: float, chord: float,
			pitch: float, colour: Color, name_hint: String) -> void:
	var mesh := BoxMesh.new()
	# Thin in the lift direction: a model wing is essentially a plate.
	mesh.size = Vector3(span, 0.008, chord)

	var instance := MeshInstance3D.new()
	instance.name = name_hint
	instance.mesh = mesh
	instance.material_override = _material(colour)

	# Build a basis whose X runs along the span and whose Z runs along the chord.
	var x_axis: Vector3 = span_axis.normalized()
	var z_axis: Vector3 = Vector3(0, 0, 1)
	var y_axis: Vector3 = z_axis.cross(x_axis).normalized()
	z_axis = x_axis.cross(y_axis).normalized()
	var basis := Basis(x_axis, y_axis, z_axis)
	# Rigging angle: leading edge up is a nose-up rotation about the span axis.
	basis = basis.rotated(x_axis, -pitch)

	# The quarter chord sits a quarter of the way back from the leading edge, so
	# the panel's centre is a quarter chord behind it.
	instance.transform = Transform3D(basis, centre + basis.z * (chord * 0.25))
	add_child(instance)


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
		_panel(centre, span_axis, span, chord, incidence, colour, "sec_" + name_hint)

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
	hub.material_override = _material(TRIM_COLOUR)
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
