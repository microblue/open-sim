# OpenRC Simulator - materials for the scattered detail.
#
# Two shaders between them cover everything that stands on the ground: one for
# foliage, one for rock. Both read the per-instance colour the scatter chose,
# which is what stops a hillside of one species reading as a repeated stamp, and
# both bias their shading normal towards the sky - vegetation is a canopy, lit
# from above almost regardless of which way an individual leaf faces, and
# shading it any other way turns every bush into a hard black cone.
#
# Colours are LINEAR, as everywhere in this project.
class_name DetailShaders
extends RefCounted

const Meshes := preload("res://world/DetailMeshes.gd")


static func material_for(kind: int) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	match kind:
		Meshes.BOULDER:
			material.shader = rock_shader()
		Meshes.DEAD_TREE:
			material.shader = foliage_shader()
			material.set_shader_parameter("base_colour", Color(0.062, 0.048, 0.036))
			material.set_shader_parameter("tip_colour", Color(0.098, 0.082, 0.064))
			material.set_shader_parameter("sway", 0.010)
			# A bare trunk is rigid almost to the top.
			material.set_shader_parameter("rooted_fraction", 0.70)
		Meshes.GRASS:
			material.shader = foliage_shader()
			material.set_shader_parameter("base_colour", Color(0.048, 0.086, 0.024))
			material.set_shader_parameter("tip_colour", Color(0.145, 0.235, 0.072))
			material.set_shader_parameter("sway", 0.070)
			# A blade of grass bends from very near the ground.
			material.set_shader_parameter("rooted_fraction", 0.08)
		Meshes.REED:
			material.shader = foliage_shader()
			material.set_shader_parameter("base_colour", Color(0.052, 0.070, 0.026))
			material.set_shader_parameter("tip_colour", Color(0.165, 0.190, 0.080))
			material.set_shader_parameter("sway", 0.110)
			material.set_shader_parameter("rooted_fraction", 0.10)
		Meshes.SHRUB:
			material.shader = foliage_shader()
			material.set_shader_parameter("base_colour", Color(0.026, 0.044, 0.018))
			material.set_shader_parameter("tip_colour", Color(0.062, 0.105, 0.034))
			material.set_shader_parameter("sway", 0.030)
			material.set_shader_parameter("rooted_fraction", 0.22)
		_:
			material.shader = foliage_shader()
			material.set_shader_parameter("base_colour", Color(0.048, 0.036, 0.026))
			material.set_shader_parameter("tip_colour", Color(0.032, 0.068, 0.022))
			material.set_shader_parameter("sway", 0.018)
			# Trunk still, canopy moving.
			material.set_shader_parameter("rooted_fraction", 0.45)
	return material


static func foliage_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

uniform vec3 base_colour : source_color = vec3(0.030, 0.055, 0.020);
uniform vec3 tip_colour : source_color = vec3(0.075, 0.130, 0.040);
uniform vec3 wind_vector = vec3(0.0, 0.0, 0.0);
uniform float gust = 0.0;
uniform float sway = 0.03;
/** Height of this kind's mesh, in metres. Set from the mesh's own bounds when
 *  the material is built - it used to default to one metre for everything, so
 *  on a tree eight metres tall every vertex above a metre clamped to full sway
 *  and the whole thing translated like a plank, trunk base included. */
uniform float top_height = 1.0;
/** Fraction of the height that is rooted and does not move at all. A trunk does
 *  not bend; the canopy above it does. */
uniform float rooted_fraction = 0.35;

varying float height_fraction;
varying vec3 instance_tint;

void vertex() {
	height_fraction = clamp(VERTEX.y / max(top_height, 0.001), 0.0, 1.0);
	instance_tint = COLOR.rgb;

	// What actually moves: nothing below the rooted fraction, then rising
	// cubically to the top. Cubic rather than linear because a stem bends -
	// its tip travels far further than its middle - and because anything
	// linear reads as the whole plant sliding.
	float free = clamp((height_fraction - rooted_fraction)
					   / max(1.0 - rooted_fraction, 0.001), 0.0, 1.0);
	float bend = free * free * free;

	// Only the upper part moves, and it moves further in a gust. The travelling
	// phase term is what makes a stand of trees ripple rather than lean as one
	// piece - the giveaway that scenery is animated by a single sine.
	vec3 world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float speed = length(wind_vector);
	float phase = TIME * (0.9 + speed * 0.18) + world.x * 0.23 + world.z * 0.19;
	float lean = clamp(0.30 + speed * 0.09 + gust * 0.40, 0.0, 1.5);
	vec3 direction = speed > 0.01 ? normalize(wind_vector) : vec3(1.0, 0.0, 0.0);
	VERTEX += direction * sway * bend * lean * (0.6 + 0.4 * sin(phase));
}

void fragment() {
	vec3 colour = mix(base_colour, tip_colour, height_fraction);
	// Per-instance tint. Without it a hillside of one species is a stamp.
	colour *= instance_tint;
	ALBEDO = colour;
	ROUGHNESS = 0.95;

	// Canopy shading: biased towards straight up. These meshes are
	// double-sided, and Godot flips the normal on a back face - which put a
	// hard black side on every bush and tree until this was added.
	vec3 up_view = (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	NORMAL = normalize(mix(NORMAL, up_view, 0.62));
}
"""
	return shader


static func rock_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 rock_low : source_color = vec3(0.052, 0.049, 0.045);
uniform vec3 rock_high : source_color = vec3(0.115, 0.108, 0.098);

varying vec3 world_position;
varying vec3 instance_tint;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float value_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(cell);
	float b = hash(cell + vec2(1.0, 0.0));
	float c = hash(cell + vec2(0.0, 1.0));
	float d = hash(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	instance_tint = COLOR.rgb;
}

void fragment() {
	// Mottling at two scales, in world space so neighbouring boulders are not
	// identically patterned.
	float coarse = value_noise(world_position.xz * 1.7 + world_position.y * 0.6);
	float fine = value_noise(world_position.xz * 9.0 - world_position.y * 2.0);
	vec3 colour = mix(rock_low, rock_high, coarse * 0.75 + fine * 0.25);
	colour *= instance_tint;

	// Lichen on the upward faces, which is where it grows and what makes a
	// boulder read as weathered rather than as a grey lump.
	float upward = clamp(NORMAL.y, 0.0, 1.0);
	colour = mix(colour, vec3(0.058, 0.072, 0.034), upward * fine * 0.45);

	ALBEDO = colour;
	ROUGHNESS = 0.88 - fine * 0.14;
	SPECULAR = 0.22;
}
"""
	return shader
