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
const GRASS_RADIUS: float = 120.0
const TREE_COUNT: int = 130
const TREE_RING_RADIUS: float = 125.0

## The sky, and therefore the light. CC0 from Poly Haven; fetched by
## scripts/fetch-assets.sh, which is why this is a path rather than a preload -
## the project has to open without the assets present.
const ImpostorLib := preload("res://world/Impostors.gd")
const GrassLib := preload("res://world/GrassCards.gd")
const Obstacles := preload("res://world/TreeObstacles.gd")
const HDRI_DIR: String = "Godot/assets/hdri"
const SKY_HDRI: String = "Godot/assets/hdri/kloofendal_48d_partly_cloudy_puresky.hdr"

@export var simulation_path: NodePath

var _sim: RCSimulationNode
var _grass_material: ShaderMaterial
var _foliage_material: ShaderMaterial
var _sky_material: ShaderMaterial
var _sky_panorama: PanoramaSkyMaterial
var _environment: Environment
var _sun: DirectionalLight3D
var _base_sun_energy: float = 6.5
var _rng_unused: int = 0
var _windsock: Node3D
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	# Seeded, so the field is the same every session - a pilot learns THIS
	# field, and a tree that moves between runs is a tree they cannot use as a
	# reference.
	_rng.seed = 20260101

	_sim = get_node_or_null(simulation_path) as RCSimulationNode

	_build_environment()
	# The ground itself and the hills beyond it are no longer built here. They
	# were a 520 m tile and a ring of mounds, and they occluded the streamed
	# terrain that now runs to the horizon - a pale band on the skyline was the
	# real world showing past the edge of the fake one.
	#
	# What stays is everything that belongs to the FIELD rather than to the
	# world: the grass the pilot reads the wind from, the treeline that gives
	# the circuit its edges, the pits and the windsock. All of it sits at zero,
	# which is where the terrain function puts the plateau.
	if not OS.has_environment("RC_NO_GRASS"):
		_build_grass()
	_build_trees()
	_build_structures()
	_build_cones()
	_windsock = _build_windsock()
	Obstacles.flush(_sim)


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

## Swap the sky and re-aim the sun. A scene preset is a climate, a geology and
## a sky; this is the sky half.
func apply_sky(hdri_name: String, sun_angles: Vector3, sun_energy: float) -> void:
	var panorama: Texture2D = _load_hdri("%s/%s.hdr" % [HDRI_DIR, hdri_name])
	if panorama != null and _sky_panorama != null:
		_sky_panorama.panorama = panorama
	if _sun != null:
		_sun.rotation_degrees = sun_angles
		_sun.light_energy = sun_energy
		_base_sun_energy = sun_energy


## Apply a weather state to what can be seen: fog, light level and the sky's own
## brightness. The air and the ground are the director's business, not the
## field's.
func apply_weather(state: Dictionary) -> void:
	if _environment == null:
		return
	_environment.fog_density = state["fog_density"]
	_environment.fog_aerial_perspective = state["aerial"]
	_environment.volumetric_fog_enabled = float(state["volumetric"]) > 0.0
	if _environment.volumetric_fog_enabled:
		_environment.volumetric_fog_density = state["volumetric"]
	# A grey day is a dimmer sun AND a dimmer sky, not a filter over the result.
	_environment.ambient_light_energy = float(state["sky_scale"])
	if _sun != null:
		_sun.light_energy = _base_sun_energy * float(state["light_scale"])
	if _sky_panorama != null:
		_sky_panorama.energy_multiplier = float(state["sky_scale"])


## Load an HDRI from the asset directory, or null if the assets have not been
## fetched. Everything that uses one falls back rather than failing: a checkout
## without assets must still run, because that is what the test suite does.
func _load_hdri(relative: String) -> Texture2D:
	var path: String = RCSimulationNode.new().resolve_data_path(relative) \
		if _sim == null else _sim.resolve_data_path(relative)
	if not FileAccess.file_exists(path):
		push_warning("HDRI not found at %s - run scripts/fetch-assets.sh. "
				% path + "Falling back to a procedural sky.")
		return null
	var image := Image.new()
	if image.load(path) != OK:
		push_warning("HDRI at %s could not be read." % path)
		return null
	return ImageTexture.create_from_image(image)


func _build_environment() -> void:
	# A captured sky, not a computed one.
	#
	# The procedural sky was a good gradient with procedural clouds on it, and it
	# was still obviously a gradient with clouds on it. A real HDRI is a
	# photograph of an actual sky, and - more importantly - it is the light
	# source for everything below it. Image-based lighting from a real sky is
	# most of what separates a rendered scene from a lit one: the shadow side of
	# an object picks up the blue of the sky above and the green of the ground
	# beneath it, which no ambient colour reproduces.
	#
	# CC0, from Poly Haven. See Data/Assets/manifest.json.
	var sky_material := PanoramaSkyMaterial.new()
	var panorama: Texture2D = _load_hdri(SKY_HDRI)
	if panorama != null:
		sky_material.panorama = panorama
		sky_material.energy_multiplier = 1.0
		# Filtered: an unfiltered 4K panorama aliases badly along the horizon,
		# which is exactly where a low-flying model is silhouetted against it.
		sky_material.filter = true
	_sky_material = null
	_sky_panorama = sky_material

	var sky := Sky.new()
	sky.sky_material = sky_material
	# The radiance map is what lights the scene, so it is worth the quality: it
	# is computed once and decides the colour of every shaded surface below it.
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_QUALITY

	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# Entirely from the sky now. With a real HDRI there is nothing an ambient
	# colour can add that the capture does not already have, and mixing one in
	# only flattens it.
	environment.ambient_light_sky_contribution = 1.0
	environment.ambient_light_energy = 1.0

	# Physically plausible outdoor exposure. ACES rather than a filmic curve so
	# a white cloud and a shaded treeline keep their relationship.
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	# A white point of 6 compresses the whole scene into the bottom of the
	# curve and flattens the contrast. Sunlit grass and a bright sky are only
	# about two stops apart; 2.6 puts them where the eye expects them.
	# More highlight headroom. At 3.0 a sunlit hillside sat near the top of the
	# curve and everything above it - snow, sand, the water glitter - flattened
	# into the same white.
	environment.tonemap_white = 5.0
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
	# SSAO on, at half resolution. Contact shadows under the aircraft and in the
	# grass are worth having; the full-resolution pass was not, on a scene where
	# almost every pixel is foliage.
	environment.ssao_enabled = not OS.has_environment("RC_NO_POST")
	environment.ssao_radius = 1.1
	environment.ssao_intensity = 1.35
	environment.ssao_power = 1.8

	# Distance haze. RC flying is done at ranges where this is most of what
	# tells you how far away the model is.
	# Enough haze to give distance a cue, and no more. The first setting of this
	# had the treeline washed out at a hundred metres and the sky grey rather
	# than blue - which reads as an overcast day whatever the sky material is
	# doing, and takes away the pilot's main range cue in the process.
	environment.fog_enabled = not OS.has_environment("RC_NO_POST")
	environment.fog_light_color = Color(0.62, 0.74, 0.92)
	# Thinner than before. At 0.00035 the haze was total by three kilometres,
	# which was fine when the world ended at 260 m and hides an entire mountain
	# range now.
	# Thin. Three separate things were hazing the view at once - this, the
	# aerial perspective term and the volumetric fog - and together they turned
	# a clear afternoon into a permanent overcast. Aerial perspective on its own
	# is enough to give distance a cue.
	environment.fog_density = 0.00007
	environment.fog_sky_affect = 0.0
	environment.fog_aerial_perspective = 0.45

	# Volumetric fog, on top of the depth fog.
	#
	# Depth fog tints distance; volumetric fog is actually there, so the sun
	# lights it - haze thickens in a valley, and a low sun throws shafts through
	# the treeline. It is the single most expensive thing in this environment
	# and the one that most makes air look like air, and there is room for it:
	# the scene runs at 160 fps on the target GPU. See Docs/PERFORMANCE.md.
	# Volumetric fog OFF.
	#
	# It puts the sun into the air, which is lovely on a misty morning and is
	# not what this is: a clear afternoon with cumulus. At any density where the
	# shafts showed, the whole scene went milky - the haze is lit by the same
	# sun and there is nothing to occlude it over an open field. Depth fog with
	# aerial perspective gives distance its cue for none of the cost and none of
	# the wash. Left configured, so it is one line to turn on for a weather
	# preset that wants it.
	environment.volumetric_fog_enabled = false
	# Light. Volumetric fog earns its cost by putting the sun into the air -
	# shafts through a treeline, haze thickening in a valley - not by washing
	# the whole scene out, which is what the first value did.
	environment.volumetric_fog_density = 0.0016
	environment.volumetric_fog_albedo = Color(0.84, 0.89, 0.98)
	# Forward scattering, so the haze brightens towards the sun the way real
	# air does rather than glowing evenly.
	environment.volumetric_fog_anisotropy = 0.35
	environment.volumetric_fog_length = 1400.0
	environment.volumetric_fog_detail_spread = 2.0
	environment.volumetric_fog_gi_inject = 0.6
	# A shallow height falloff: haze collects near the ground, which is what
	# separates a ridgeline from the one behind it.
	environment.volumetric_fog_ambient_inject = 0.15

	# Restrained. No lens flare, no motion blur: motion blur in particular hides
	# exactly the fast attitude changes the pilot needs to read.
	# A modest bloom. With a bright sky filling half the frame, heavy glow
	# spreads across the whole image and takes the colour out of the ground -
	# but none at all leaves sunlit highlights hard-edged, which is most of what
	# separates a rendered frame from a photographed one. Low threshold, low
	# intensity: the sky and the sunlit grass pick up a soft halo, and the rest
	# of the scene does not.
	environment.glow_enabled = not OS.has_environment("RC_NO_POST")
	environment.glow_intensity = 0.32
	environment.glow_bloom = 0.05
	environment.glow_hdr_threshold = 1.25

	_environment = environment

	var holder := WorldEnvironment.new()
	holder.name = "WorldEnvironment"
	holder.environment = environment
	add_child(holder)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	# Mid afternoon, sun in the south-west and behind the pilot's shoulder -
	# the orientation a club sets its strip up for.
	# Matched to where the sun actually is in the HDRI. A directional light that
	# disagrees with the sky it is lit under is immediately readable: the
	# shadows fall one way and every specular highlight points another.
	sun.rotation_degrees = Vector3(-43.0, 155.0, 0.0)
	# Godot's Burley diffuse carries the 1/pi, so light_energy is roughly pi
	# times smaller than a naive irradiance calculation suggests. Sunlit grass
	# wants a value around ten here, not around three; at three the scene
	# renders correctly but reads as late afternoon under cloud.
	# Re-balanced from 12.0.
	#
	# That value was chosen when the world was one mown field and the only thing
	# it had to light was the grass shader. Now every surface carries a real
	# reflectance, and at 12 a whole landscape of correctly-dark albedos came out
	# a pale mint green - the light was doing the work the albedo should have.
	# The HDRI supplies the sky's own light; this is the sun on top of it.
	# Real surface albedos are dark - scanned grass is around 0.08 - so the key
	# light has to be strong enough to lift them without the ambient flattening
	# the shading, which is why this went back up after the textures went in.
	sun.light_energy = 6.5
	sun.light_color = Color(1.0, 0.97, 0.91)
	sun.shadow_enabled = not OS.has_environment("RC_NO_SHADOW")
	# The sun has to be in the volumetric fog for it to throw shafts through
	# the trees; without this the haze is lit only by ambient and reads as a
	# flat wash.
	sun.light_volumetric_fog_energy = 1.35
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
	# Extended to 300 m. Shadows past fifty metres were indeed not noticed by a
	# pilot watching the model - but they ARE noticed by anyone looking at the
	# landscape, where the ground beyond the strip was lit by an unshadowed sun
	# and every ridge read as if it were noon with no clouds. With an 8192 map
	# and four blended splits, 300 m of shadow costs nothing visible in the
	# frame time (see Docs/PERFORMANCE.md) and the world stops looking like a
	# pool of light around the strip.
	sun.directional_shadow_max_distance = 300.0
	sun.shadow_bias = 0.5
	sun.shadow_normal_bias = 3.5
	sun.directional_shadow_blend_splits = true
	_sun = sun
	_base_sun_energy = sun.light_energy
	add_child(sun)


# -------------------------------------------------------------------- terrain

## Height of the ground at a point. Dead flat over the whole flying area - the
## physics uses a flat ground plane, and the two must agree - then rolling
## beyond it so the horizon is not a knife edge.
## Public form of _terrain_height, for anything that needs to stay above the
## ground - the camera rig, principally.
func height_at(x: float, z: float) -> float:
	return _terrain_height(x, z)


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
	# Real scanned grass where the impostors have been baked, generated blades
	# where they have not. The card carries five clumps, so three crossed quads
	# are fifteen clumps of real grass and the instance count comes down by the
	# same factor.
	var card: Dictionary = GrassLib.load_card(_sim) if _sim != null else {}

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true

	var count: int = GRASS_BLADES
	if card.is_empty():
		_grass_material = ShaderMaterial.new()
		_grass_material.shader = FieldShaders.grass_shader()
		multi.mesh = _blade_mesh()
	else:
		_grass_material = GrassLib.material(card)
		# The card is built from the bake metrics so the scanned clump stands
		# on the ground at its real size - see the note at the top of
		# GrassCards.gd. The buried part of the card is transparent.
		multi.mesh = GrassLib.tuft_mesh(card)
		# Dense enough that the ground under it barely shows. A card carries
		# five clumps, so this is roughly six hundred thousand clumps of grass
		# over the circuit - which is what a field looks like.
		# Density restored, and then some. It had been cut chasing a frame time
		# that turned out to be the Xvfb present path; on the real display the
		# scene runs at 160 fps, which is several times the headroom a trainer
		# needs. See Docs/PERFORMANCE.md.
		count = int(GRASS_BLADES * 0.70)

	multi.instance_count = count
	for i in count:
		var angle: float = _rng.randf() * TAU
		var radius: float = sqrt(_rng.randf()) * GRASS_RADIUS
		var x: float = cos(angle) * radius
		var z: float = sin(angle) * radius
		# The mown strip is mown: no tufts on it. Grass on a runway is not only
		# wrong to look at, it hides the painted markings and the wheels sink
		# into it. Skipping the strip area only removes a fraction of a percent
		# of the field's tufts, and the edge between bare strip and rough comes
		# out of the mown mask in the ground shader, so it is not a hard line.
		var along: float = absf(z - STRIP_CENTRE_Z) / (STRIP_HALF_LENGTH + 4.0)
		var across: float = absf(x - STRIP_CENTRE_X) / (STRIP_HALF_WIDTH + 1.2)
		if maxf(along, across) < 1.0 and _rng.randf() < 0.97:
			continue
		# The scan is a 0.4 m clump - the size of rough, not of a mown field.
		# Scaled to ~0.13-0.21 m, which is what a club strip actually is.
		var scale: float = _rng.randf_range(0.32, 0.52)
		var basis := Basis(Vector3.UP, _rng.randf() * TAU) \
			.scaled(Vector3(scale, scale * _rng.randf_range(0.85, 1.2), scale))
		multi.set_instance_transform(i, Transform3D(basis,
			Vector3(x, _terrain_height(x, z), z)))
		# Pulled towards green. The scan is a dry ornamental grass, which is
		# lovely and is not what a mown flying field looks like.
		var tint: float = _rng.randf()
		multi.set_instance_color(i, Color(0.52 + tint * 0.16,
										  0.92 + tint * 0.18,
										  0.34 + tint * 0.14))

	var instance := MultiMeshInstance3D.new()
	instance.name = "Grass"
	instance.multimesh = multi
	instance.material_override = _grass_material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Grass past this is a shimmer, not detail, and it is where the overdraw is.
	# The cutoff used to sit at 135 m with no fade, which read as a hard band
	# across the field where the crops stopped being crops. Pushed out to where
	# the distance haze hides the edge. (Fade modes need a dithered material;
	# this one is alpha-cut, so the cutoff stays hard but far away.)
	instance.visibility_range_end = 240.0
	instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	add_child(instance)


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

	# The treeline the pilot learns the circuit against. Impostors where they
	# have been baked - two triangles carrying a photograph of a real scanned
	# tree - and the generated shapes where they have not, so a checkout without
	# assets still has a treeline to fly around.
	var species: Array[String] = ["fir_tree_01", "island_tree_02"]
	var meshes: Array[ArrayMesh] = [_tree_mesh(), _broadleaf_mesh()]
	var names: Array[String] = ["Conifers", "Broadleaves"]

	for kind in 2:
		var entries: Array = placements[kind]
		if entries.is_empty():
			continue

		var impostor: Dictionary = ImpostorLib.load_for(_sim, species[kind]) \
			if _sim != null else {}

		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.use_colors = true
		multi.mesh = impostor["mesh"] if not impostor.is_empty() else meshes[kind]
		multi.instance_count = entries.size()

		for i in entries.size():
			var transform: Transform3D = entries[i][0]
			if not impostor.is_empty():
				# The impostor is sized in metres by its own bake metrics, so
				# the placement's scale only varies it rather than setting it.
				var scale: float = transform.basis.get_scale().y * 0.42
				transform = Transform3D(
					Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(scale, scale, scale)),
					transform.origin)
			multi.set_instance_transform(i, transform)
			multi.set_instance_color(i, entries[i][1] if impostor.is_empty()
					else Color(0.94, 0.96, 0.94))

		var instance := MultiMeshInstance3D.new()
		instance.name = names[kind]
		instance.multimesh = multi
		instance.material_override = impostor["material"] if not impostor.is_empty() \
			else _foliage_material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(instance)

		# The treeline is solid: a wing tip into a trunk is a crash, not a
		# pass-through. Each tree gets a collision cylinder at its position.
		for i in entries.size():
			var transform: Transform3D = entries[i][0]
			var tree_scale: float = transform.basis.get_scale().y
			Obstacles.add_field(transform.origin.x, transform.origin.z,
								tree_scale * 0.9, tree_scale * 7.0)


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


## Marker cones along both edges of the strip. They are what a club field
## actually has - and they give the pilot a continuous depth cue down the
## runway, which is most of what makes an approach readable. One mesh, instanced
## with slight size and lean variation so the row does not read as a stamp.
func _build_cones() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = 0.13
	mesh.height = 0.36
	mesh.radial_segments = 10

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.85, 0.24, 0.10)
	material.roughness = 0.6

	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh

	var placements: Array[Transform3D] = []
	for side in [-1.0, 1.0]:
		for slot in 9:
			var z: float = -STRIP_CENTRE_Z + float(slot) * 7.2 - 26.0
			z = clampf(z, -STRIP_HALF_LENGTH + 2.0, STRIP_HALF_LENGTH - 2.0)
			var x: float = STRIP_CENTRE_X + side * (STRIP_HALF_WIDTH + 1.0) \
					+ _rng.randf_range(-0.25, 0.25)
			var scale: float = _rng.randf_range(0.85, 1.15)
			var lean := Basis(Vector3.UP, _rng.randf() * TAU).scaled(
					Vector3(scale, scale, scale))
			# A little lean, so they are cones on grass, not chess pieces.
			lean = lean.rotated(Vector3(1, 0, 0), _rng.randf_range(-0.06, 0.06))
			placements.append(Transform3D(lean, Vector3(x, 0.0, z)))

	multi.instance_count = placements.size()
	for i in placements.size():
		multi.set_instance_transform(i, placements[i])

	var instance := MultiMeshInstance3D.new()
	instance.name = "Cones"
	instance.multimesh = multi
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(instance)


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
