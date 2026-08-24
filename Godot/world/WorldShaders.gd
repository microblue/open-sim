# OpenRC Simulator - shaders for the streamed world.
#
# Terrain and water. Both are written against world coordinates rather than mesh
# UVs, so detail does not swim when a chunk is rebuilt at a different origin or
# when a ring changes LOD - which is the usual giveaway that a world is being
# streamed rather than being there.
#
# As everywhere in this project, colours are LINEAR. The `: source_color` hint
# only converts in the editor, and a value pushed in from GDScript arrives raw.
class_name WorldShaders
extends RefCounted


static func terrain_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform float snow_line = 1250.0;
uniform float sea_level = 0.0;
uniform vec3 rock_colour : source_color = vec3(0.068, 0.064, 0.058);
uniform vec3 snow_colour : source_color = vec3(0.640, 0.680, 0.760);

varying vec3 world_position;
varying vec3 world_normal;
varying vec4 surface;

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

float fbm(vec2 p, int octaves) {
	float total = 0.0;
	float amplitude = 0.5;
	float norm = 0.0;
	for (int i = 0; i < octaves; i++) {
		total += value_noise(p) * amplitude;
		norm += amplitude;
		p *= 2.11;
		amplitude *= 0.5;
	}
	return total / norm;
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// COLOR carries the biome albedo, computed per vertex in C++ where the
	// biome rules live, so a triangle spanning a boundary blends between two
	// real colours instead of interpolating an index into a third biome.
	surface = COLOR;
}

void fragment() {
	vec3 albedo = surface.rgb;
	float steepness = surface.a;

	// Detail at three scales. Terrain lit by a single directional light and
	// painted one flat colour per biome reads as plastic however good the
	// silhouette is; this is most of what makes a hillside look like ground.
	float coarse = fbm(world_position.xz * 0.004, 4);
	float medium = fbm(world_position.xz * 0.031, 3);
	float fine   = fbm(world_position.xz * 0.220, 2);

	// Centred on 1.0 rather than biased above it: the old weights multiplied
	// the whole world by up to 1.66 and lifted every surface towards white.
	albedo *= 0.62 + coarse * 0.76;
	albedo *= 0.84 + medium * 0.32;
	albedo *= 0.92 + fine * 0.16;

	// Rock through anything too steep to hold soil. Slope comes from the
	// terrain function rather than the interpolated normal, so it does not
	// change with LOD.
	float rockiness = smoothstep(0.40, 0.85, steepness + medium * 0.18 - 0.09);
	albedo = mix(albedo, rock_colour * (0.72 + fine * 0.55), rockiness);

	// Snow above the line, but not on cliffs - it does not stick to them, and
	// letting it turns every mountain into a white cone.
	float altitude = smoothstep(snow_line - 220.0, snow_line + 140.0, world_position.y);
	float lying = altitude * (1.0 - smoothstep(0.45, 0.80, steepness));
	albedo = mix(albedo, snow_colour * (0.90 + fine * 0.18), lying);

	// Cloud shadow. Large, slow, and drifting downwind - the single cheapest
	// thing that makes a landscape look like it is under a sky rather than
	// under a lamp, and the thing whose absence reads as "rendered".
	vec2 drift = world_position.xz * 0.00032 + vec2(TIME * 0.0016, TIME * 0.0009);
	float cover = fbm(drift, 4);
	float shade = 1.0 - 0.42 * smoothstep(0.46, 0.72, cover);
	albedo *= shade;

	ALBEDO = albedo;

	// Wet sand near the water line, and snow is smoother than rock.
	float shoreline = 1.0 - smoothstep(0.0, 6.0, world_position.y - sea_level);
	ROUGHNESS = mix(mix(0.96, 0.72, lying), 0.55, shoreline);
	// Soil, grass and rock have almost no specular response. At 0.28 the whole
	// landscape carried a broad sheen from the sky that washed the colour out
	// of it - a mint-green world under a white haze.
	SPECULAR = mix(0.06, 0.30, shoreline);

	// Surface relief.
	//
	// The mesh carries the shape of the land and nothing smaller; without this
	// a hillside is a smooth sheet whatever colour it is painted, which is what
	// made the whole landscape read as plaster. Perturbing the normal from the
	// same noise the albedo uses puts the texture of ground back without
	// needing any geometry for it.
	//
	// The strength falls off with distance, because relief finer than a pixel
	// is just noise - and noise in the normal is what makes a distant hillside
	// sparkle under a moving camera.
	float range = length(world_position - CAMERA_POSITION_WORLD);
	float relief = 1.0 - smoothstep(120.0, 2200.0, range);

	vec2 d = vec2(0.75, 0.0);
	float scale = 0.20;
	float hx = fbm((world_position.xz + d.xy) * scale, 3)
			 - fbm((world_position.xz - d.xy) * scale, 3);
	float hz = fbm((world_position.xz + d.yx) * scale, 3)
			 - fbm((world_position.xz - d.yx) * scale, 3);

	// Rock is coarse, grass is fine, snow is nearly smooth.
	float strength = mix(1.0, 2.6, rockiness) * (1.0 - lying * 0.75) * relief;
	vec3 perturbed = normalize(world_normal + vec3(-hx, 0.0, -hz) * strength * 1.6);
	NORMAL = normalize((VIEW_MATRIX * vec4(perturbed, 0.0)).xyz);
}
"""
	return shader


## Water. Gerstner-ish swell in the vertex stage for the near field, a moving
## normal field for the rest, and a Fresnel-weighted sky reflection - the sun
## glinting off water is most of what makes an ocean read as wet.
static func water_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_disabled;

uniform vec3 shallow_colour : source_color = vec3(0.020, 0.115, 0.135);
uniform vec3 deep_colour : source_color = vec3(0.004, 0.020, 0.045);
uniform vec3 foam_colour : source_color = vec3(0.55, 0.62, 0.66);
uniform float wave_height = 0.55;
uniform float wave_scale = 0.020;

varying vec3 world_position;
varying float crest;

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

/** Three crossing swells. Real water is never one wave train, and one is
 *  immediately readable as a corrugated sheet. */
float swell(vec2 p, float t) {
	float h = 0.0;
	h += sin(dot(p, vec2(0.94, 0.34)) * 0.85 + t * 1.05) * 0.55;
	h += sin(dot(p, vec2(-0.42, 0.91)) * 1.35 + t * 1.37) * 0.30;
	h += sin(dot(p, vec2(0.61, -0.79)) * 2.20 + t * 1.90) * 0.15;
	return h;
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 p = world_position.xz * wave_scale;
	float t = TIME;

	float h = swell(p, t);
	// Chop, so the surface is not a smooth undulation at every scale.
	h += (value_noise(p * 7.0 + vec2(t * 0.35, -t * 0.22)) - 0.5) * 0.55;

	VERTEX.y += h * wave_height;
	crest = h;

	// Normal from the analytic derivative of the swell, so it is right even
	// where the mesh is too coarse to carry the wave.
	float e = 0.35;
	float hx = swell(p + vec2(e, 0.0), t) - swell(p - vec2(e, 0.0), t);
	float hz = swell(p + vec2(0.0, e), t) - swell(p - vec2(0.0, e), t);
	NORMAL = normalize(vec3(-hx * wave_height * 0.6, 1.0, -hz * wave_height * 0.6));
}

void fragment() {
	vec3 view = normalize(world_position - CAMERA_POSITION_WORLD);

	// Fine ripple on top of the vertex wave, which is what carries the sun
	// glitter at distance where the geometry has long since stopped.
	vec2 p = world_position.xz;
	float t = TIME;
	float r1 = value_noise(p * 0.55 + vec2(t * 0.9, t * 0.4));
	float r2 = value_noise(p * 1.70 - vec2(t * 1.3, t * 0.7));
	vec3 ripple = normalize(vec3((r1 - 0.5) * 0.55, 1.0, (r2 - 0.5) * 0.55));
	vec3 normal = normalize(mix(NORMAL, ripple, 0.45));
	NORMAL = normal;

	// Fresnel: water is nearly black looking straight down and a mirror at a
	// grazing angle. Getting this wrong is what makes CG water look like paint.
	float facing = clamp(dot(-view, normal), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, 4.0);

	vec3 body = mix(deep_colour, shallow_colour, clamp(crest * 0.6 + 0.5, 0.0, 1.0));
	ALBEDO = body;

	// Foam on the crests.
	float foam = smoothstep(0.62, 0.95, crest + (r1 - 0.5) * 0.5);
	ALBEDO = mix(ALBEDO, foam_colour, foam * 0.7);

	ROUGHNESS = mix(0.035, 0.32, foam);
	SPECULAR = mix(0.62, 1.0, fresnel);
	METALLIC = 0.0;
	// A little emission on the glitter so the sun path survives tone mapping.
	EMISSION = vec3(fresnel * 0.03);
}
"""
	return shader
