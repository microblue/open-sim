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


## Terrain, textured from real scanned PBR sets.
##
## Eight materials reachable through three texture arrays, blended by what the
## ground actually is at that point - altitude, steepness and moisture - rather
## than by an index, because an index interpolated across a triangle spanning
## two biomes lands on a third one.
##
## Two things stop it looking like a texture on a hill:
##
##   Triplanar. A cliff sampled from directly above gets a metre of texture
##   smeared down a hundred metres of rock. Projecting from all three axes and
##   weighting by the normal costs three lookups instead of one and is the only
##   thing that makes steep ground look like ground.
##
##   Dual scale. One tiling repeat every few metres is obvious from the air -
##   the eye finds the grid immediately. Sampling the same material again at a
##   much larger scale and multiplying breaks the repeat without needing a
##   second texture.
##
## Falls back to flat biome colours when the assets have not been fetched.
static func terrain_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2DArray ground_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray ground_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray ground_rough : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool textured = false;

uniform float snow_line = 1250.0;
uniform float sea_level = -135.0;
uniform float beach_height = 5.0;
/** The flying field is mown, and mown grass is green whatever the surrounding
 *  climate happens to be. Without this the strip took whatever moisture the
 *  noise gave it and came out as dry steppe - which is a fine landscape and the
 *  wrong one to land a trainer on. */
uniform float field_radius = 300.0;
uniform float field_blend = 420.0;

/** Metres per tile of the detail sample, and of the macro sample that breaks
 *  its repeat. */
uniform float detail_scale = 1.7;
uniform float macro_scale = 34.0;

uniform vec3 wind_vector = vec3(0.0, 0.0, 0.0);

// Layer indices, matching WorldTextures.LAYERS.
const float L_GRASS  = 0.0;
const float L_FOREST = 1.0;
const float L_ROCK   = 2.0;
const float L_BEACH  = 3.0;
const float L_DESERT = 4.0;
const float L_SNOW   = 5.0;
const float L_DIRT   = 6.0;

varying vec3 world_position;
varying vec3 world_normal;
varying vec4 surface;
varying float moisture;

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

/** One material at one scale.
 *
 *  `flat_ground` skips two of the three projections. Most of the world is
 *  ground the aircraft can land on, and on ground the eye reads as flat the
 *  side projections contribute almost nothing while costing two thirds of the
 *  lookups. Only a real slope pays for all three.
 */
vec3 project(sampler2DArray tex, float layer, vec3 blend, vec3 position,
			 float scale, bool flat_ground) {
	if (flat_ground) {
		return texture(tex, vec3(position.xz / scale, layer)).rgb;
	}
	return texture(tex, vec3(position.zy / scale, layer)).rgb * blend.x
		 + texture(tex, vec3(position.xz / scale, layer)).rgb * blend.y
		 + texture(tex, vec3(position.xy / scale, layer)).rgb * blend.z;
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// COLOR carries the biome albedo computed per vertex in C++, used as the
	// fallback and as a tint over the textures so the two agree. UV2.x is the
	// moisture the biome rules were decided from, which is what actually says
	// whether ground is desert, pasture or woodland.
	surface = COLOR;
	moisture = UV2.x;
}

void fragment() {
	float steepness = surface.a;
	float height = world_position.y;

	// --- how much of each material is here ------------------------------
	// Decided from the ground itself rather than from an index, so a triangle
	// spanning a boundary blends between two real materials.
	float above_water = height - sea_level;
	float variation = fbm(world_position.xz * 0.012, 3) - 0.5;

	float w_beach  = 1.0 - smoothstep(beach_height * 0.4, beach_height * 1.6, above_water);
	float w_snow   = smoothstep(snow_line - 260.0, snow_line + 120.0, height)
					 * (1.0 - smoothstep(0.42, 0.78, steepness));
	float w_rock   = smoothstep(0.34, 0.72, steepness + variation * 0.30);
	// The same thresholds TerrainField decides the biome by, so what is drawn
	// and what the scatter grows on it agree about where the wood ends.
	float wet = moisture + variation * 0.06;
	float w_forest = smoothstep(0.56, 0.70, wet);
	float w_desert = 1.0 - smoothstep(0.26, 0.38, wet);

	// Grass is whatever is left.
	float w_grass = max(0.0, 1.0 - w_beach - w_snow - w_rock - w_forest - w_desert);

	// On the field itself, it is all of it.
	float mown = 1.0 - smoothstep(field_radius, field_radius + field_blend,
								  length(world_position.xz));
	w_grass = mix(w_grass, 1.0, mown);
	w_desert = mix(w_desert, 0.0, mown);
	w_forest = mix(w_forest, 0.0, mown);
	w_rock = mix(w_rock, 0.0, mown);

	if (textured) {
		// Triplanar weights from the surface normal, sharpened so a slope is
		// mostly one projection rather than a smear of all three.
		vec3 blend = pow(abs(world_normal), vec3(4.0));
		blend /= max(blend.x + blend.y + blend.z, 1e-4);
		bool flat_ground = blend.y > 0.94;

		// Six materials, three maps, two scales and three projections is a
		// hundred and eight texture fetches a pixel, and it was costing more
		// than everything else in the frame put together. Almost all of them
		// were multiplied by a weight of zero: at any given point the ground is
		// one or two materials, not six.
		//
		// So: skip a layer whose weight cannot show, take the macro sample
		// only for albedo - it exists to break the tiling grid, which the eye
		// only finds in colour - and use one projection on ground that reads as
		// flat. Same picture, a fraction of the bandwidth.
		float weights[6] = {w_grass, w_forest, w_rock, w_beach, w_desert, w_snow};
		float layers[6] = {L_GRASS, L_FOREST, L_ROCK, L_BEACH, L_DESERT, L_SNOW};

		vec3 albedo = vec3(0.0);
		vec3 rough = vec3(0.0);
		vec3 packed = vec3(0.0);
		float total = 0.0;

		for (int i = 0; i < 6; i++) {
			float w = weights[i];
			if (w < 0.004) {
				continue;
			}
			float layer = layers[i];
			vec3 detail = project(ground_albedo, layer, blend, world_position,
								  detail_scale, flat_ground);
			vec3 macro = project(ground_albedo, layer, blend, world_position,
								 macro_scale, flat_ground);
			// Multiplied around a mid grey, so the macro sample varies the
			// detail rather than replacing it. This is what removes the grid.
			albedo += detail * (macro * 1.7 + 0.15) * w;
			rough += project(ground_rough, layer, blend, world_position,
							 detail_scale, flat_ground) * w;
			packed += project(ground_normal, layer, blend, world_position,
							  detail_scale, flat_ground) * w;
			total += w;
		}

		total = max(total, 1e-4);
		albedo /= total;
		rough /= total;
		packed /= total;

		// A tint from the vertex colour, so the texture set and the biome
		// colouring agree instead of arguing. Weak: the scan carries the
		// colour, this only nudges it.
		vec3 tint = surface.rgb / max(dot(surface.rgb, vec3(0.333)), 1e-4);
		albedo *= mix(vec3(1.0), tint, 0.28);

		// The mown field, pulled towards green.
		//
		// sparse_grass is exactly what it is called - mostly bare earth with
		// grass through it - which is right for open country and wrong for a
		// strip that is cut every week. There is no aerial lawn texture in the
		// library, so the ground under the grass geometry is tinted instead.
		// Softened, and over a long distance. A hard-edged green disc is worse
		// than no mown strip at all - it reads as a decal on the landscape.
		albedo = mix(albedo, albedo * vec3(0.70, 1.28, 0.55), mown * 0.62);
		ALBEDO = albedo;
		ROUGHNESS = clamp(rough.r * 1.15, 0.25, 1.0);
		SPECULAR = 0.30;

		// Whitened at range: relief finer than a pixel is noise, and noise in
		// the normal makes a distant hillside sparkle under a moving camera.
		float range = length(world_position - CAMERA_POSITION_WORLD);
		float relief = 1.0 - smoothstep(180.0, 2600.0, range);
		vec3 tangent_normal = normalize(packed * 2.0 - 1.0);
		NORMAL_MAP = mix(vec3(0.5, 0.5, 1.0), tangent_normal * 0.5 + 0.5, relief);
		NORMAL_MAP_DEPTH = 1.6;
	} else {
		// No assets: the procedural colouring this replaced.
		vec3 albedo = surface.rgb;
		float coarse = fbm(world_position.xz * 0.004, 4);
		float fine = fbm(world_position.xz * 0.220, 2);
		albedo *= 0.62 + coarse * 0.76;
		albedo *= 0.92 + fine * 0.16;
		ALBEDO = albedo;
		ROUGHNESS = 0.96;
		SPECULAR = 0.06;
	}

	// Cloud shadow. Large, slow, drifting downwind - the cheapest thing that
	// makes a landscape look like it is under a sky rather than under a lamp.
	vec2 drift = world_position.xz * 0.00032 + vec2(TIME * 0.0016, TIME * 0.0009);
	float cover = fbm(drift, 4);
	ALBEDO *= 1.0 - 0.38 * smoothstep(0.46, 0.72, cover);
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
