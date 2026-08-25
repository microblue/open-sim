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
## Sky. A physical-looking gradient with a drifting cloud deck on top.
##
## Godot's PhysicalSkyMaterial gives a good clear-day gradient and nothing else,
## and a cloudless sky is most of why a rendered field reads as a diagram. It
## also costs the pilot something real: clouds are a depth cue and a wind cue,
## and on a hazy day they are the only thing that makes the top half of the
## frame anything other than flat colour.
##
## The deck is a flat plane at CLOUD_HEIGHT intersected with the view ray, which
## is enough at these viewing angles - the pilot is looking up at a shallow
## slant, never straight down through the layer. It drifts with the wind, so the
## sky agrees with the grass and the windsock about which way the air is moving.
static func sky_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type sky;

uniform vec3 zenith_colour : source_color = vec3(0.16, 0.33, 0.66);
uniform vec3 horizon_colour : source_color = vec3(0.62, 0.72, 0.86);
uniform vec3 ground_colour : source_color = vec3(0.26, 0.29, 0.22);
uniform vec3 cloud_lit : source_color = vec3(1.0, 0.98, 0.95);
uniform vec3 cloud_shadow : source_color = vec3(0.52, 0.56, 0.64);

uniform float cloud_cover = 0.42;
uniform float cloud_sharpness = 2.6;
uniform vec3 wind_vector = vec3(0.0, 0.0, 0.0);
uniform float cloud_height = 900.0;
uniform float cloud_scale = 0.00042;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float value_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	// Smoothstep interpolation: linear interpolation leaves visible cell edges
	// across a sky, which read as creases rather than cloud.
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(cell);
	float b = hash(cell + vec2(1.0, 0.0));
	float c = hash(cell + vec2(0.0, 1.0));
	float d = hash(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p, int octaves) {
	float total = 0.0;
	float amplitude = 0.5;
	float normalisation = 0.0;
	for (int i = 0; i < octaves; i++) {
		total += value_noise(p) * amplitude;
		normalisation += amplitude;
		p *= 2.03;
		amplitude *= 0.5;
	}
	return total / normalisation;
}

void sky() {
	vec3 dir = EYEDIR;

	// --- the gradient ---------------------------------------------------
	float up = clamp(dir.y, -1.0, 1.0);
	vec3 base = mix(horizon_colour, zenith_colour, pow(clamp(up, 0.0, 1.0), 0.55));
	// Below the horizon the sky still lights the scene, so it fades to ground
	// rather than going black - which would suck the light out of the ambient.
	base = mix(base, ground_colour, clamp(-up * 6.0, 0.0, 1.0));

	// --- the sun --------------------------------------------------------
	float sun_dot = clamp(dot(dir, LIGHT0_DIRECTION), -1.0, 1.0);
	// A broad forward-scattering halo, then the disc itself.
	base += LIGHT0_COLOR * pow(max(sun_dot, 0.0), 8.0) * 0.28;
	base += LIGHT0_COLOR * smoothstep(0.9994, 0.9997, sun_dot) * LIGHT0_ENERGY * 4.0;

	// --- the cloud deck --------------------------------------------------
	if (up > 0.012) {
		float distance_to_deck = cloud_height / up;
		vec2 sample_point = dir.xz * distance_to_deck * cloud_scale;
		// The deck drifts downwind. Scaled well down from the true wind speed:
		// cloud a kilometre up moving at the speed of the grass would tear
		// across the frame.
		sample_point += vec2(wind_vector.x, wind_vector.z) * TIME * cloud_scale * 9.0;

		// The radiance cubemap only needs the shape, not the detail, and it is
		// regenerated often enough that the octaves show up in the frame time.
		int octaves = AT_CUBEMAP_PASS ? 3 : 5;
		float density = fbm(sample_point, octaves);
		// Cover raises the whole field; sharpness decides whether it is a soft
		// overcast or separate cumulus with clear sky between.
		density = clamp((density - (1.0 - cloud_cover)) * cloud_sharpness, 0.0, 1.0);

		// Lit from the sun side. Sampling the field again a short way towards
		// the sun approximates self-shadowing for the cost of one more fbm.
		vec2 towards_sun = normalize(LIGHT0_DIRECTION.xz + vec2(1e-4)) * 0.25;
		float lit = fbm(sample_point + towards_sun, 3);
		vec3 cloud = mix(cloud_shadow, cloud_lit, clamp(lit * 1.5, 0.0, 1.0));

		// Fade the deck out towards the horizon: at a grazing angle the ray
		// travels far enough through haze that the cloud is lost in it, and
		// without this the deck ends in a hard line across the treeline.
		float horizon_fade = smoothstep(0.012, 0.16, up);
		base = mix(base, cloud, density * horizon_fade * 0.95);
	}

	COLOR = base;
}
"""
	return shader


static func grass_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

uniform vec3 wind_vector = vec3(0.0, 0.0, 0.0);
uniform float gust = 0.0;
// These sit at and just above the ground shader's own grass tone. The first
// version had the blades DARKER than the sward they stand in, which turned a
// field into a scatter of dark spikes on flat green - the single thing that
// most made the ground read as a diagram.
uniform vec3 blade_base : source_color = vec3(0.070, 0.132, 0.038);
uniform vec3 blade_tip : source_color = vec3(0.165, 0.275, 0.088);
uniform float sway_scale = 0.045;
uniform float blade_height = 0.115;
// Radius the tufts are scattered over. Blades shrink into the ground over the
// last stretch of it, so the field does not end in a visible ring.
uniform float scatter_radius = 55.0;
uniform float fade_fraction = 0.28;

varying float height_fraction;
varying float tint;

float tuft_hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	height_fraction = clamp(VERTEX.y / blade_height, 0.0, 1.0);

	vec3 world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;

	// Per-tuft colour and height variation. A field of identical blades reads
	// as a texture swatch; real grass is patchy, and the patchiness is most of
	// what the eye uses to judge that it is looking at ground.
	tint = tuft_hash(floor(world.xz * 3.7));
	VERTEX.y *= 0.72 + tint * 0.62;

	// Shrink towards nothing at the edge of the scattered area so the boundary
	// is a gradient rather than the hard ring it was.
	float edge = length(world.xz) / scatter_radius;
	float keep = 1.0 - smoothstep(1.0 - fade_fraction, 1.0, edge);
	VERTEX.xz *= keep;
	VERTEX.y *= keep;

	// Only the top of the blade moves, and it moves further in a gust. The
	// travelling phase term is what makes the field ripple rather than sway
	// as one piece.
	float speed = length(wind_vector);
	float phase = TIME * (1.2 + speed * 0.35) + world.x * 0.55 + world.z * 0.41;
	// Bounded: an unbounded wind term laid the whole field flat at five metres
	// a second, which looks like a storm rather than a breeze.
	float lean = clamp(0.25 + speed * 0.10 + gust * 0.35, 0.0, 1.4);
	// Cubic in height: the roots do not move and the tip does.
	float amplitude = sway_scale * height_fraction * height_fraction
					* height_fraction * lean;

	vec3 direction = speed > 0.01 ? normalize(wind_vector) : vec3(1.0, 0.0, 0.0);
	VERTEX += direction * amplitude * (0.65 + 0.35 * sin(phase));
	VERTEX.x += 0.35 * amplitude * sin(phase * 1.7);
}

void fragment() {
	// Darker at the root, where light does not reach, and varied tuft to tuft.
	vec3 colour = mix(blade_base, blade_tip, height_fraction);
	colour *= 0.82 + tint * 0.40;
	ALBEDO = colour;
	ROUGHNESS = 1.0;

	// Bias the shading normal towards straight up.
	//
	// The quads are double-sided, and Godot flips the normal on a back face -
	// so every tuft had a lit side and a side facing directly away from the
	// sky, which rendered each one as a hard black cone. Grass is a canopy: it
	// is lit from above almost regardless of which way an individual blade
	// happens to face, and shading it that way is both what it looks like and
	// what removes the cones.
	vec3 up_view = (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	NORMAL = normalize(mix(NORMAL, up_view, 0.80));
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

	// Painted markings on the strip: a dashed centreline and threshold bars at
	// each end. A real club strip is marked - a bare green runway is one of the
	// tells that a scene was generated rather than visited. The paint is worn
	// by the same noise that mottles the grass, so it reads as painted on over
	// the years rather than as a decal pasted over a clean surface.
	vec2 strip_centre = vec2(-16.0, -30.0);
	vec2 half_size = vec2(4.5, 35.0);
	vec2 p = world_position.xz - strip_centre;
	float in_strip = 1.0 - smoothstep(0.90, 1.02,
		max(abs(p.x) / half_size.x, abs(p.y) / half_size.y));
	float dash = step(fract(abs(p.y) / 6.0), 0.42);
	float centre = 1.0 - smoothstep(0.14, 0.24, abs(p.x));
	float line = centre * dash * in_strip;
	float bar = (1.0 - smoothstep(0.35, 0.55, abs(abs(p.y) - half_size.y)))
				* (1.0 - smoothstep(half_size.x - 0.6, half_size.x - 0.25, abs(p.x)))
				* in_strip;
	float paint = clamp(line + bar, 0.0, 1.0);
	vec3 paint_colour = vec3(0.72, 0.72, 0.70);
	paint *= 0.50 + 0.50 * fine;
	base = mix(base, paint_colour, paint * 0.85);

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
varying vec3 instance_tint;

void vertex() {
	// Per-tree colour, set on the MultiMesh. A treeline where every tree is the
	// same green reads as a repeated stamp however much the sizes vary, and it
	// is the one thing the eye picks up immediately.
	instance_tint = COLOR.rgb;

	vec3 world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float speed = length(wind_vector);
	float phase = TIME * (0.7 + speed * 0.12) + world.x * 0.21 + world.z * 0.17;
	// Only the canopy moves; the trunk stays put.
	// Nothing below a metre moves - that is trunk - and above it the bend rises
	// with the square of height, because a branch tip travels far further than
	// the fork it grows from.
	float above_trunk = max(VERTEX.y - 1.0, 0.0);
	float amplitude = 0.016 * above_trunk * above_trunk
					* (0.3 + speed * 0.1 + gust * 0.4);
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
	ALBEDO = mix(trunk_colour, leaf_colour * instance_tint, canopy);
	ROUGHNESS = 1.0;
}
"""
	return shader
