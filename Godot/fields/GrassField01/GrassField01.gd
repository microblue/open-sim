# OpenRC Simulator - GrassField01.
#
# A Southern California club field, built procedurally so the whole scene lives
# in text files rather than binary assets. The point is not that the field is
# large; it is that the view FROM THE PILOT STATION is convincing, because that
# is the only view the pilot ever has.
#
# Layout, in Godot axes (X east, Y up, Z south, so the aircraft flies towards -Z):
#
#            trees ..................................  120 m out
#                        mown strip, 70 x 9 m
#            pit  P---------------------------------
#                 ^ pilot station at the origin
#
# Everything that moves in the wind - grass, trees, windsock - reads the same
# wind vector the aircraft is flying in. If they ever disagreed, the simulator
# would be lying to the pilot about the one thing they most need to read from
# across the field.
extends Node3D

const FIELD_HALF_SIZE: float = 260.0
const TERRAIN_RESOLUTION: int = 96

const STRIP_HALF_LENGTH: float = 35.0
const STRIP_HALF_WIDTH: float = 4.5
const STRIP_CENTRE_Z: float = -30.0
## The pilot stands BESIDE the strip, not on it. This is how a real club field
## is laid out, and it is what makes the model's orientation readable: seen from
## the side, a turn towards the pilot looks different from a turn away.
const STRIP_CENTRE_X: float = -16.0

# One instance is a tuft of three blades, not a single blade. At a pilot's eye
# height a field needs several tufts per square metre before it stops reading as
# sparse weeds; 90 000 over a 60 m radius is about eight.
const GRASS_BLADES: int = 210000
const GRASS_RADIUS: float = 55.0
const TREE_COUNT: int = 130
const TREE_RING_RADIUS: float = 125.0

@export var simulation_path: NodePath

var _sim: RCSimulationNode
var _grass_material: ShaderMaterial
var _foliage_material: ShaderMaterial
var _sky_material: ShaderMaterial
var _windsock: Node3D
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	# Seeded, so the field is the same every session - a pilot learns THIS
	# field, and a tree that moves between runs is a tree they cannot use as a
	# reference.
	_rng.seed = 20260101

	_sim = get_node_or_null(simulation_path) as RCSimulationNode

	_build_environment()
	_build_terrain()
	_build_grass()
	_build_trees()
	_build_hills()
	_build_structures()
	_windsock = _build_windsock()


func _process(_delta: float) -> void:
	if _sim == null:
		return

	# One wind vector, read by everything the pilot can see.
	var wind: Vector3 = _sim.get_wind_vector()
	var gust: float = _sim.get_gust_fraction()

	if _grass_material != null:
		_grass_material.set_shader_parameter("wind_vector", wind)
		_grass_material.set_shader_parameter("gust", gust)
	if _foliage_material != null:
		_foliage_material.set_shader_parameter("wind_vector", wind)
		_foliage_material.set_shader_parameter("gust", gust)
	if _sky_material != null:
		_sky_material.set_shader_parameter("wind_vector", wind)

	if _windsock != null:
		_update_windsock(wind, gust)


# ---------------------------------------------------------------- environment

func _build_environment() -> void:
	# A custom sky rather than PhysicalSkyMaterial: the physical model gives a
	# convincing clear-day gradient and no clouds at all, and an empty sky is
	# most of what made the field read as a diagram rather than a place. See
	# FieldShaders.sky_shader().
	var sky_material := ShaderMaterial.new()
	sky_material.shader = FieldShaders.sky_shader()
	sky_material.set_shader_parameter("zenith_colour", Color(0.14, 0.30, 0.62))
	sky_material.set_shader_parameter("horizon_colour", Color(0.60, 0.71, 0.86))
	sky_material.set_shader_parameter("ground_colour", Color(0.26, 0.29, 0.22))
	# Scattered fair-weather cumulus: enough to give the sky depth and a wind
	# cue, not so much that the field goes into shadow.
	sky_material.set_shader_parameter("cloud_cover", 0.44)
	sky_material.set_shader_parameter("cloud_sharpness", 2.4)

	var sky := Sky.new()
	sky.sky_material = sky_material
	_sky_material = sky_material

	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# Sky ambient at full strength washes the colour out of everything: grass
	# came out at RGB 65,71,59 - a dark, desaturated green that reads as an
	# overcast evening rather than a Californian afternoon. The sun has to
	# dominate for the scene to look sunlit.
	environment.ambient_light_sky_contribution = 0.55
	# Roughly a fifth of the sun, which is about right for a clear day. Any more
	# and the sky's near-white light desaturates the grass into grey-green.
	environment.ambient_light_energy = 1.0

	# Physically plausible outdoor exposure. ACES rather than a filmic curve so
	# a white cloud and a shaded treeline keep their relationship.
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	# A white point of 6 compresses the whole scene into the bottom of the
	# curve and flattens the contrast. Sunlit grass and a bright sky are only
	# about two stops apart; 2.6 puts them where the eye expects them.
	environment.tonemap_white = 3.0
	environment.tonemap_exposure = 1.0

	# SDFGI is deliberately OFF.
	#
	# On a flat field there is nothing for light to bounce between, so it buys
	# almost nothing - and its occlusion term darkened the whole ground inside
	# the outermost cascade. That produced a hard grey band about a hundred
	# metres out, exactly where the cascades run out, which read as a change of
	# surface rather than a change of lighting.
	#
	# Sky ambient does the job for a bright outdoor scene, and screen-space
	# ambient occlusion puts the contact shadows back where they matter - under
	# the aircraft, the canopy and the rail.
	environment.sdfgi_enabled = false
	environment.ssao_enabled = true
	environment.ssao_radius = 0.8
	environment.ssao_intensity = 1.1
	environment.ssao_power = 1.5

	# Distance haze. RC flying is done at ranges where this is most of what
	# tells you how far away the model is.
	# Enough haze to give distance a cue, and no more. The first setting of this
	# had the treeline washed out at a hundred metres and the sky grey rather
	# than blue - which reads as an overcast day whatever the sky material is
	# doing, and takes away the pilot's main range cue in the process.
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.70, 0.78, 0.90)
	environment.fog_density = 0.00035
	environment.fog_sky_affect = 0.0
	environment.fog_aerial_perspective = 0.3

	# Restrained. No lens flare, no motion blur: motion blur in particular hides
	# exactly the fast attitude changes the pilot needs to read.
	# Barely any bloom. With a bright sky filling half the frame, glow spreads
	# across the whole image and takes the colour out of the ground with it.
	environment.glow_enabled = true
	environment.glow_intensity = 0.12
	environment.glow_bloom = 0.0
	environment.glow_hdr_threshold = 1.4

	var holder := WorldEnvironment.new()
	holder.name = "WorldEnvironment"
	holder.environment = environment
	add_child(holder)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	# Mid afternoon, sun in the south-west and behind the pilot's shoulder -
	# the orientation a club sets its strip up for.
	sun.rotation_degrees = Vector3(-48.0, 128.0, 0.0)
	# Godot's Burley diffuse carries the 1/pi, so light_energy is roughly pi
	# times smaller than a naive irradiance calculation suggests. Sunlit grass
	# wants a value around ten here, not around three; at three the scene
	# renders correctly but reads as late afternoon under cloud.
	sun.light_energy = 12.0
	sun.light_color = Color(1.0, 0.97, 0.91)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	# Shadow bias, and why it is this large.
	#
	# The field is a 520 m plane lit at 48 degrees. At the default bias the
	# terrain self-shadowed across its whole area - shadow acne - and the grass
	# read as dark grey-green concrete with bright blades standing on it. The
	# only thing wrong was the depth bias.
	#
	# Pulling the shadow distance in to 120 m and raising both biases fixes it,
	# and costs nothing that matters: shadows past a hundred metres are not
	# something a pilot looking at a model aircraft is going to notice.
	# Pulled in to 55 m. The outer cascade over a large flat field is where the
	# acne survives however much bias is applied, and shadows past fifty metres
	# are not something a pilot watching a model aircraft is ever going to look
	# at. Inside that radius - the pits, the near strip - they are sharp.
	sun.directional_shadow_max_distance = 55.0
	sun.shadow_bias = 0.35
	sun.shadow_normal_bias = 3.0
	sun.directional_shadow_blend_splits = true
	add_child(sun)


# -------------------------------------------------------------------- terrain

## Height of the ground at a point. Dead flat over the whole flying area - the
## physics uses a flat ground plane, and the two must agree - then rolling
## beyond it so the horizon is not a knife edge.
func _terrain_height(x: float, z: float) -> float:
	var distance: float = Vector2(x - STRIP_CENTRE_X * 0.5, z - STRIP_CENTRE_Z).length()
	if distance < 110.0:
		return 0.0
	var t: float = clampf((distance - 110.0) / 90.0, 0.0, 1.0)
	var undulation: float = (
		sin(x * 0.021) * cos(z * 0.017) * 4.5
		+ sin(x * 0.007 + 1.3) * 7.0
		+ cos(z * 0.009 - 0.6) * 5.5
	)
	# Godot's Y is up; the ground rises away from the field.
	return undulation * t * t


## 1 on the mown strip, falling off through the worn edges to 0 on the rough.
func _mown_fraction(x: float, z: float) -> float:
	var along: float = absf(z - STRIP_CENTRE_Z) / STRIP_HALF_LENGTH
	var across: float = absf(x - STRIP_CENTRE_X) / STRIP_HALF_WIDTH
	var edge: float = maxf(along, across)
	return 1.0 - smoothstep(0.85, 1.25, edge)


func _build_terrain() -> void:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()

	var step: float = (FIELD_HALF_SIZE * 2.0) / float(TERRAIN_RESOLUTION)

	for row in TERRAIN_RESOLUTION + 1:
		for column in TERRAIN_RESOLUTION + 1:
			var x: float = -FIELD_HALF_SIZE + float(column) * step
			var z: float = -FIELD_HALF_SIZE + float(row) * step
			vertices.append(Vector3(x, _terrain_height(x, z), z))

			# Central difference for the normal.
			var dx: float = _terrain_height(x + 1.0, z) - _terrain_height(x - 1.0, z)
			var dz: float = _terrain_height(x, z + 1.0) - _terrain_height(x, z - 1.0)
			normals.append(Vector3(-dx, 2.0, -dz).normalized())

			var mown: float = _mown_fraction(x, z)
			colours.append(Color(mown, mown, mown, 1.0))

	for row in TERRAIN_RESOLUTION:
		for column in TERRAIN_RESOLUTION:
			var a: int = row * (TERRAIN_RESOLUTION + 1) + column
			var b: int = a + 1
			var c: int = a + TERRAIN_RESOLUTION + 1
			var d: int = c + 1
			# Godot's front faces are CLOCKWISE. The obvious counter-clockwise
			# winding makes the whole terrain back-facing when seen from above,
			# so it is culled and the sky's ground_color shows through instead -
			# which looks exactly like a ground plane, right down to being a
			# plausible green, and hides the fact that the terrain is not being
			# drawn at all. Every attempt to fix the "ground colour" by editing
			# the ground shader had no effect for that reason.
			indices.append_array([a, b, c, b, d, c])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := ShaderMaterial.new()
	material.shader = FieldShaders.ground_shader()
	# Colours are LINEAR albedos and live in the shader itself; see the note at
	# the top of FieldShaders.gd about why they are not set from here.
	mesh.surface_set_material(0, material)

	var instance := MeshInstance3D.new()
	instance.name = "Terrain"
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


# ---------------------------------------------------------------------- grass

func _blade_mesh() -> ArrayMesh:
	# Two crossed quads. Cheap, and from a pilot's eye height that is all a
	# blade of grass needs to be.
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()

	# Three crossed quads splayed slightly apart: one instance is a tuft, which
	# is what an eye actually resolves at a few metres.
	for pass_index in 3:
		var angle: float = float(pass_index) / 3.0 * PI
		# Wider than a real blade on purpose. At one instance per tuft a
		# nine-millimetre quad renders as a needle. Wider than that and the
		# tuft reads as a solid cone instead, so this is the middle of it.
		var right := Vector3(cos(angle), 0.0, sin(angle)) * 0.011
		var top: float = 0.115
		var base: int = vertices.size()
		vertices.append_array([
			-right, right, right * 0.35 + Vector3(0.0, top, 0.0),
			-right * 0.35 + Vector3(0.0, top, 0.0)
		])
		# Face the normals upward as well as sideways: grass catches sky light
		# from above, and a purely horizontal normal makes a field look like
		# a sheet of dark cardboard.
		var normal := Vector3(-sin(angle) * 0.4, 0.9, cos(angle) * 0.4).normalized()
		normals.append_array([normal, normal, normal, normal])
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_grass() -> void:
	_grass_material = ShaderMaterial.new()
	_grass_material.shader = FieldShaders.grass_shader()

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = _blade_mesh()
	multi.instance_count = GRASS_BLADES

	for i in GRASS_BLADES:
		# Denser near the pilot, where the eye actually resolves individual
		# blades; sqrt of a uniform gives that for free.
		var angle: float = _rng.randf() * TAU
		var radius: float = sqrt(_rng.randf()) * GRASS_RADIUS
		var x: float = STRIP_CENTRE_X * 0.5 + cos(angle) * radius
		var z: float = STRIP_CENTRE_Z + sin(angle) * radius

		var mown: float = _mown_fraction(x, z)
		# Short on the strip, long on the rough. This is what makes the strip
		# read as a strip from a distance.
		var height: float = lerpf(1.0, 0.30, mown) * _rng.randf_range(0.65, 1.4)

		var basis := Basis(Vector3.UP, _rng.randf() * TAU).scaled(
			Vector3(_rng.randf_range(0.8, 1.2), height, _rng.randf_range(0.8, 1.2)))
		multi.set_instance_transform(i, Transform3D(basis,
			Vector3(x, _terrain_height(x, z), z)))

	var instance := MultiMeshInstance3D.new()
	instance.name = "Grass"
	instance.multimesh = multi
	instance.material_override = _grass_material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Grass past a hundred metres is a texture, not geometry.
	instance.visibility_range_end = 75.0
	instance.visibility_range_end_margin = 15.0
	add_child(instance)


# ---------------------------------------------------------------------- trees

func _tree_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Trunk.
	var trunk_height: float = 2.6
	var trunk_radius: float = 0.22
	var sides: int = 7
	for side in sides:
		var a0: float = float(side) / float(sides) * TAU
		var a1: float = float(side + 1) / float(sides) * TAU
		var p0 := Vector3(cos(a0) * trunk_radius, 0.0, sin(a0) * trunk_radius)
		var p1 := Vector3(cos(a1) * trunk_radius, 0.0, sin(a1) * trunk_radius)
		var q0: Vector3 = p0 * 0.7 + Vector3(0.0, trunk_height, 0.0)
		var q1: Vector3 = p1 * 0.7 + Vector3(0.0, trunk_height, 0.0)
		# Clockwise, to match Godot's front-face convention. The obvious
		# counter-clockwise order leaves every face back-facing, and with
		# culling disabled that flips the shading normal instead of hiding the
		# face - which renders every tree as a black cut-out.
		surface.set_normal(Vector3(cos(a0), 0.2, sin(a0)).normalized())
		for v in [p0, q1, q0, p0, p1, q1]:
			surface.add_vertex(v)

	# Canopy: three stacked cones, which from any real viewing distance reads
	# as a eucalypt.
	var levels := [
		{"y": 2.1, "radius": 2.5, "height": 3.4},
		{"y": 4.0, "radius": 2.0, "height": 3.0},
		{"y": 5.6, "radius": 1.3, "height": 2.4},
	]
	for level in levels:
		var y: float = level["y"]
		var radius: float = level["radius"]
		var height: float = level["height"]
		var apex := Vector3(0.0, y + height, 0.0)
		for side in 9:
			var a0: float = float(side) / 9.0 * TAU
			var a1: float = float(side + 1) / 9.0 * TAU
			var p0 := Vector3(cos(a0) * radius, y, sin(a0) * radius)
			var p1 := Vector3(cos(a1) * radius, y, sin(a1) * radius)
			surface.set_normal(Vector3(cos(a0), 0.5, sin(a0)).normalized())
			for v in [p0, p1, apex]:
				surface.add_vertex(v)

	return surface.commit()


## A rounded broadleaf, to stand among the conifers. A treeline of one species
## is the giveaway that a scene was generated rather than grown; two shapes and
## a colour spread is enough to break that up at the distances this is seen at.
func _broadleaf_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	var trunk_height: float = 3.1
	var trunk_radius: float = 0.26
	var sides: int = 7
	for side in sides:
		var a0: float = float(side) / float(sides) * TAU
		var a1: float = float(side + 1) / float(sides) * TAU
		var p0 := Vector3(cos(a0) * trunk_radius, 0.0, sin(a0) * trunk_radius)
		var p1 := Vector3(cos(a1) * trunk_radius, 0.0, sin(a1) * trunk_radius)
		var q0: Vector3 = p0 * 0.75 + Vector3(0.0, trunk_height, 0.0)
		var q1: Vector3 = p1 * 0.75 + Vector3(0.0, trunk_height, 0.0)
		# Clockwise: see the note in _tree_mesh().
		surface.set_normal(Vector3(cos(a0), 0.2, sin(a0)).normalized())
		for v in [p0, q1, q0, p0, p1, q1]:
			surface.add_vertex(v)

	# Canopy: a squashed sphere built as stacked rings, deliberately low
	# resolution and slightly irregular so it does not read as a ball.
	var rings: int = 5
	var segments: int = 9
	var centre := Vector3(0.0, trunk_height + 1.9, 0.0)
	var radius: float = 3.0
	for ring in rings:
		var t0: float = float(ring) / float(rings) * PI
		var t1: float = float(ring + 1) / float(rings) * PI
		for segment in segments:
			var a0: float = float(segment) / float(segments) * TAU
			var a1: float = float(segment + 1) / float(segments) * TAU
			var points := []
			for pair in [[t0, a0], [t0, a1], [t1, a1], [t1, a0]]:
				var t: float = pair[0]
				var a: float = pair[1]
				# Squashed vertically, and nudged per-vertex so the silhouette
				# is lumpy like foliage rather than a clean dome.
				var wobble: float = 0.86 + 0.14 * sin(a * 3.0 + t * 5.0)
				points.append(centre + Vector3(
					sin(t) * cos(a) * radius * wobble,
					cos(t) * radius * 0.78 * wobble,
					sin(t) * sin(a) * radius * wobble))
			var normal: Vector3 = (points[0] - centre).normalized()
			surface.set_normal(normal)
			for v in [points[0], points[1], points[2],
					  points[0], points[2], points[3]]:
				surface.add_vertex(v)

	return surface.commit()


func _build_trees() -> void:
	_foliage_material = ShaderMaterial.new()
	_foliage_material.shader = FieldShaders.foliage_shader()

	# Two species, placed from one ring so they interleave rather than forming
	# two separate bands.
	var conifer_count: int = int(TREE_COUNT * 0.58)
	var broadleaf_count: int = TREE_COUNT - conifer_count
	var placements: Array[Array] = [[], []]

	for i in TREE_COUNT:
		# A ragged perimeter ring, with a gap where the pilot looks out so the
		# treeline does not swallow a low aircraft on final.
		var angle: float = float(i) / float(TREE_COUNT) * TAU + _rng.randf_range(-0.02, 0.02)
		var radius: float = TREE_RING_RADIUS + _rng.randf_range(-22.0, 34.0)
		var x: float = cos(angle) * radius
		var z: float = STRIP_CENTRE_Z + sin(angle) * radius

		var scale: float = _rng.randf_range(0.75, 1.6)
		var basis := Basis(Vector3.UP, _rng.randf() * TAU).scaled(
			Vector3(scale, scale * _rng.randf_range(0.85, 1.3), scale))
		var transform := Transform3D(basis, Vector3(x, _terrain_height(x, z), z))

		# Foliage colour spread: yellow-green through to a dark blue-green, with
		# a little brightness variation on top. Real stands vary by species, age
		# and how much sun each tree gets.
		var warmth: float = _rng.randf()
		var brightness: float = _rng.randf_range(0.78, 1.28)
		var tint := Color(
			(0.80 + warmth * 0.55) * brightness,
			(1.00 - warmth * 0.10) * brightness,
			(0.95 - warmth * 0.45) * brightness)

		var which: int = 0 if placements[0].size() < conifer_count \
			and (placements[1].size() >= broadleaf_count or _rng.randf() < 0.58) else 1
		placements[which].append([transform, tint])

	var meshes: Array[ArrayMesh] = [_tree_mesh(), _broadleaf_mesh()]
	var names: Array[String] = ["Conifers", "Broadleaves"]

	for species in 2:
		var entries: Array = placements[species]
		if entries.is_empty():
			continue

		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		# Per-instance colour, read as COLOR by the foliage shader.
		multi.use_colors = true
		multi.mesh = meshes[species]
		multi.instance_count = entries.size()

		for i in entries.size():
			multi.set_instance_transform(i, entries[i][0])
			multi.set_instance_color(i, entries[i][1])

		var instance := MultiMeshInstance3D.new()
		instance.name = names[species]
		instance.multimesh = multi
		instance.material_override = _foliage_material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(instance)


# ---------------------------------------------------------------------- hills

func _build_hills() -> void:
	# Low ridges on the horizon. They exist to give the sky an edge and to give
	# the eye something to judge distance against; they are never flown near.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	var segments: int = 160
	var ridges := [
		{"radius": 1400.0, "height": 95.0, "phase": 0.0},
		{"radius": 2300.0, "height": 165.0, "phase": 2.1},
		{"radius": 3400.0, "height": 240.0, "phase": 4.7},
	]

	for ridge in ridges:
		var radius: float = ridge["radius"]
		var height: float = ridge["height"]
		var phase: float = ridge["phase"]
		for segment in segments:
			var a0: float = float(segment) / float(segments) * TAU
			var a1: float = float(segment + 1) / float(segments) * TAU
			var h0: float = height * (0.45 + 0.55 * absf(sin(a0 * 3.0 + phase)
				* cos(a0 * 1.7 - phase)))
			var h1: float = height * (0.45 + 0.55 * absf(sin(a1 * 3.0 + phase)
				* cos(a1 * 1.7 - phase)))
			var b0 := Vector3(cos(a0) * radius, -20.0, sin(a0) * radius)
			var b1 := Vector3(cos(a1) * radius, -20.0, sin(a1) * radius)
			var t0 := Vector3(cos(a0) * radius, h0, sin(a0) * radius)
			var t1 := Vector3(cos(a1) * radius, h1, sin(a1) * radius)
			surface.set_normal(-Vector3(cos(a0), 0.0, sin(a0)))
			for v in [b0, t0, t1, b0, t1, b1]:
				surface.add_vertex(v)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.36, 0.42, 0.38)
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_FRONT

	var instance := MeshInstance3D.new()
	instance.name = "Hills"
	instance.mesh = surface.commit()
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


# ----------------------------------------------------------------- structures

func _box(size: Vector3, position: Vector3, colour: Color, name_hint: String) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.8
	var instance := MeshInstance3D.new()
	instance.name = name_hint
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	add_child(instance)
	return instance


func _build_structures() -> void:
	# Pilot station: a low rail BEHIND the camera. In front of it, at a metre
	# and a bit, it filled a third of the frame and hid the aircraft.
	_box(Vector3(7.0, 0.07, 0.07), Vector3(0.0, 1.02, 2.6),
		Color(0.46, 0.46, 0.49), "PilotRail")
	for offset in [-3.3, 0.0, 3.3]:
		_box(Vector3(0.07, 1.02, 0.07), Vector3(offset, 0.51, 2.6),
			Color(0.46, 0.46, 0.49), "PilotRailPost")

	# Shade structure over the pits, off to one side of the strip.
	var canopy_x: float = 11.0
	_box(Vector3(9.0, 0.15, 4.5), Vector3(canopy_x, 2.4, 4.0),
		Color(0.58, 0.56, 0.50), "Canopy")
	for post in [Vector3(-4.2, 0.0, -2.0), Vector3(4.2, 0.0, -2.0),
				 Vector3(-4.2, 0.0, 2.0), Vector3(4.2, 0.0, 2.0)]:
		_box(Vector3(0.12, 2.4, 0.12), Vector3(canopy_x, 1.2, 4.0) + post,
			Color(0.45, 0.44, 0.42), "CanopyPost")
	_box(Vector3(3.0, 0.75, 0.7), Vector3(canopy_x, 0.75, 4.0),
		Color(0.60, 0.45, 0.30), "WorkBench")

	# Parking, further back still.
	var colours := [Color(0.65, 0.66, 0.68), Color(0.20, 0.28, 0.42),
					Color(0.55, 0.18, 0.16)]
	for i in 3:
		_box(Vector3(1.9, 1.5, 4.4), Vector3(24.0 + float(i) * 3.2, 0.75, 12.0),
			colours[i], "ParkedCar")


# ------------------------------------------------------------------- windsock

func _build_windsock() -> Node3D:
	var root := Node3D.new()
	root.name = "Windsock"
	root.position = Vector3(STRIP_CENTRE_X + 7.0, 0.0, STRIP_CENTRE_Z + 22.0)
	add_child(root)

	var pole := _box(Vector3(0.09, 3.2, 0.09), Vector3.ZERO, Color(0.72, 0.72, 0.74), "Pole")
	remove_child(pole)
	root.add_child(pole)
	pole.position = Vector3(0.0, 1.6, 0.0)

	# The sock itself: a truncated cone, hinged at the top of the pole. Godot's
	# CylinderMesh points along +Y, so it is laid over onto -Z and then the
	# pivot yaws it into the wind.
	var sock_mesh := CylinderMesh.new()
	sock_mesh.top_radius = 0.34
	sock_mesh.bottom_radius = 0.16
	sock_mesh.height = 1.9
	sock_mesh.radial_segments = 12
	sock_mesh.cap_top = false
	sock_mesh.cap_bottom = false

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.92, 0.42, 0.10)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 0.9

	var pivot := Node3D.new()
	pivot.name = "Pivot"
	pivot.position = Vector3(0.0, 3.1, 0.0)
	root.add_child(pivot)

	var sock := MeshInstance3D.new()
	sock.name = "Sock"
	sock.mesh = sock_mesh
	sock.material_override = material
	# Lay the cone down so its axis runs along -Z, then the pivot aims it.
	sock.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	sock.position = Vector3(0.0, 0.0, -0.95)
	pivot.add_child(sock)

	return root


func _update_windsock(wind: Vector3, gust: float) -> void:
	var pivot := _windsock.get_node_or_null("Pivot") as Node3D
	if pivot == null:
		return

	var horizontal := Vector2(wind.x, wind.z)
	var speed: float = horizontal.length()
	if speed < 0.05:
		# Hanging limp, which is itself information: no wind.
		pivot.rotation = pivot.rotation.lerp(Vector3(deg_to_rad(-80.0), pivot.rotation.y, 0.0), 0.05)
		return

	# The sock streams AWAY from where the wind comes from, so it points along
	# the wind vector. Godot's -Z is the sock's own axis.
	var heading: float = atan2(horizontal.x, horizontal.y) + PI
	# It lifts towards horizontal as the wind picks up; a 5 m/s wind holds a
	# real sock most of the way out.
	var lift: float = -deg_to_rad(80.0) * clampf(1.0 - (speed + gust * 2.0) / 6.0, 0.0, 1.0)

	var target := Vector3(lift, heading, 0.0)
	pivot.rotation = pivot.rotation.lerp(target, 0.08)
