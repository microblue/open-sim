# OpenRC Simulator - shaders for the flying field, built in code.
#
# Written as GDScript rather than .tres so the whole field stays in text files
# and can be reviewed in a diff. Nothing here computes physics; it is content.
#
# A NOTE ON COLOUR SPACE, because it cost an afternoon.
#
# The `: source_color` hint on a uniform only makes the EDITOR convert from
# sRGB when you pick a colour. A Color passed from GDScript through
# set_shader_parameter() arrives in the shader exactly as written, and shaders
# work in LINEAR space. Writing an sRGB value like (0.24, 0.31, 0.13) - a dark
# green - and having it used as linear gives a mid grey-olive, which is why the
# field first rendered as washed-out concrete no matter how the lighting was
# adjusted.
#
# Every colour below is therefore a LINEAR albedo. Real grass is around
# (0.04, 0.07, 0.02) linear; anything that looks "about right" typed as sRGB
# will be far too bright and far too desaturated here.
class_name FieldShaders
extends RefCounted


## Grass. Vertex displacement driven by a wind vector and world position, so
## the whole field ripples in the same direction the aircraft is being pushed.
static func grass_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

uniform vec3 wind_vector = vec3(0.0, 0.0, 0.0);
uniform float gust = 0.0;
uniform vec3 blade_base : source_color = vec3(0.042, 0.082, 0.023);
uniform vec3 blade_tip : source_color = vec3(0.115, 0.205, 0.058);
uniform float sway_scale = 0.045;

varying float height_fraction;

void vertex() {
	height_fraction = clamp(VERTEX.y / 0.115, 0.0, 1.0);

	// Only the top of the blade moves, and it moves further in a gust. The
	// travelling phase term is what makes the field ripple rather than sway
	// as one piece.
	vec3 world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float speed = length(wind_vector);
	float phase = TIME * (1.2 + speed * 0.35) + world.x * 0.55 + world.z * 0.41;
	// Bounded: an unbounded wind term laid the whole field flat at five metres
	// a second, which looks like a storm rather than a breeze.
	float lean = clamp(0.25 + speed * 0.10 + gust * 0.35, 0.0, 1.4);
	float amplitude = sway_scale * height_fraction * lean;

	vec3 direction = speed > 0.01 ? normalize(wind_vector) : vec3(1.0, 0.0, 0.0);
	VERTEX += direction * amplitude * (0.65 + 0.35 * sin(phase));
	VERTEX.x += 0.35 * amplitude * sin(phase * 1.7);
}

void fragment() {
	// Darker at the root, where light does not reach.
	ALBEDO = mix(blade_base, blade_tip, height_fraction);
	ROUGHNESS = 1.0;
}
"""
	return shader


## Ground. Two grass tones blended by a vertex-colour mask so the mown strip
## reads differently from the rough, plus enough noise to break up the plane.
static func ground_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
// Specular disabled outright. Grass is not a mirror, and at the grazing angles
// a pilot looks along, Fresnel turned the whole field into a reflection of the
// sky - which is what made the ground read as grey concrete beyond forty metres.
render_mode diffuse_burley, specular_disabled;

uniform vec3 rough_grass : source_color = vec3(0.058, 0.118, 0.032);
uniform vec3 mown_grass : source_color = vec3(0.090, 0.170, 0.045);
uniform vec3 dirt : source_color = vec3(0.150, 0.112, 0.068);

varying vec3 world_position;
varying float mown;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
	           mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	mown = COLOR.r;
}

void fragment() {
	float fine = noise(world_position.xz * 1.7) * 0.5 + noise(world_position.xz * 6.3) * 0.5;
	vec3 base = mix(rough_grass, mown_grass, mown);
	base = mix(base * 0.82, base * 1.12, fine);
	// A little bare earth where the strip is worn.
	base = mix(base, dirt, mown * smoothstep(0.55, 0.85, fine) * 0.35);
	ALBEDO = base;
	ROUGHNESS = 1.0;
}
"""
	return shader


## Foliage. Same wind idea as the grass but slower and with more mass, so the
## trees and the grass agree about which way the wind is blowing.
static func foliage_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
// Back-face culling ON. With it disabled, Godot flips the shading normal on
// back faces, which undid the upward bias below and turned every tree black.
render_mode diffuse_burley, specular_disabled;

uniform vec3 wind_vector = vec3(0.0, 0.0, 0.0);
uniform float gust = 0.0;
uniform vec3 leaf_colour : source_color = vec3(0.050, 0.098, 0.030);
uniform vec3 trunk_colour : source_color = vec3(0.085, 0.062, 0.042);

varying float canopy;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float speed = length(wind_vector);
	float phase = TIME * (0.7 + speed * 0.12) + world.x * 0.21 + world.z * 0.17;
	// Only the canopy moves; the trunk stays put.
	float amplitude = 0.05 * max(VERTEX.y - 1.0, 0.0) * (0.3 + speed * 0.1 + gust * 0.4);
	vec3 direction = speed > 0.01 ? normalize(wind_vector) : vec3(1.0, 0.0, 0.0);
	VERTEX += direction * amplitude * sin(phase);
	canopy = smoothstep(1.6, 2.6, VERTEX.y);

	// Derive the normal from the geometry rather than trusting a cone this
	// coarse: outward from the trunk axis, biased upward so the canopy catches
	// the sky. One side of the tree then lights and the other falls into
	// shade, which is what actually reads as a tree from a hundred metres.
	vec3 outward = vec3(VERTEX.x, 0.0, VERTEX.z);
	outward = length(outward) > 0.001 ? normalize(outward) : vec3(0.0, 0.0, 1.0);
	NORMAL = normalize(outward * 0.55 + vec3(0.0, 1.0, 0.0));
}

void fragment() {
	// Trunk below the canopy, leaves above. Both need to be light enough to
	// read as green rather than as a black silhouette against a bright sky.
	ALBEDO = mix(trunk_colour, leaf_colour, canopy);
	ROUGHNESS = 1.0;
}
"""
	return shader
