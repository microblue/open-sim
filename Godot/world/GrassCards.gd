# OpenRC Simulator - the grass the aircraft lands in.
#
# The field's grass was crossed quads painted a flat green. It read as a sward
# from a distance and as coloured card from the ground, which is where a model
# spends the seconds that matter most.
#
# This textures the same crossed quads with a photograph of real scanned grass -
# one view out of the impostor atlas, which is a row of five clumps. Three
# crossed quads therefore carry fifteen clumps of real grass, so the instance
# count comes down by a factor of five while the result goes up.
#
# Not impostored in the billboarding sense: these do not turn to face the
# camera. Grass is under the aircraft on every landing and a card that rotates
# as you taxi past is worse than one that does not.
class_name GrassCards
extends RefCounted

const ATLAS := "Godot/assets/impostors/grass_medium_02.png"
const METRICS := "Godot/assets/impostors/grass_medium_02.json"

static var _cache: Dictionary = {}


## Texture and physical size for the grass card, or an empty dictionary if the
## impostors have not been baked.
static func load_card(sim: Node) -> Dictionary:
	if not _cache.is_empty():
		return _cache

	var atlas_path: String = sim.resolve_data_path(ATLAS)
	var metrics_path: String = sim.resolve_data_path(METRICS)
	if not FileAccess.file_exists(atlas_path) or not FileAccess.file_exists(metrics_path):
		_cache = {"missing": true}
		return {}

	var metrics: Variant = JSON.parse_string(FileAccess.get_file_as_string(metrics_path))
	if typeof(metrics) != TYPE_DICTIONARY:
		_cache = {"missing": true}
		return {}

	var whole := Image.new()
	if whole.load(atlas_path) != OK:
		_cache = {"missing": true}
		return {}

	# The first view. The atlas is one row, so the front view is the leftmost
	# tile; the others are the same grass turned, which a card does not need.
	var tile: int = int(metrics["tile"])
	var face := Image.create(tile, tile, false, Image.FORMAT_RGBA8)
	face.blit_rect(whole, Rect2i(0, 0, tile, tile), Vector2i.ZERO)
	face.generate_mipmaps()

	_cache = {
		"texture": ImageTexture.create_from_image(face),
		# The bake framed the model square on its largest dimension, so the tile
		# is this many metres across and the grass occupies the lower part of it.
		"size": float(metrics["extent"]),
	}
	return _cache


## Three crossed quads, standing on the ground. The card's grass sits in the
## lower part of its tile, so the quad is placed to put that at ground level.
static func tuft_mesh(size: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	for blade in 3:
		var angle: float = float(blade) / 3.0 * PI
		var right := Vector3(cos(angle), 0.0, sin(angle)) * size * 0.5
		var up := Vector3(0.0, size, 0.0)
		var normal := Vector3(-sin(angle) * 0.35, 0.94, cos(angle) * 0.35).normalized()

		var corners := [-right, right, right + up, -right + up]
		var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
		# Clockwise, Godot's front face - though the material disables culling,
		# since a grass card is seen from both sides.
		for i in [0, 2, 1, 0, 3, 2]:
			surface.set_normal(normal)
			surface.set_uv(uvs[i])
			surface.add_vertex(corners[i])

	return surface.commit()


static func material(texture: Texture2D) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
// depth_prepass_alpha: alpha-cut geometry sorts correctly, at the cost of a
// depth pass over it first. It was removed while chasing a frame time that
// turned out to be the Xvfb present path, and is back because it was not the
// problem and because without it cards at the same depth flicker against each
// other as the camera moves.
render_mode cull_disabled, diffuse_burley, specular_disabled, depth_prepass_alpha;

uniform sampler2D card : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec3 wind_vector = vec3(0.0, 0.0, 0.0);
uniform float gust = 0.0;
uniform float alpha_cut = 0.4;
uniform float bake_gain = 0.62;
/** Where the grass in the card starts, measured up from the foot. The bake
 *  framed the model square, so the grass occupies only the lower part of the
 *  tile - and the sway has to be keyed to the grass rather than to the card, or
 *  the blades barely move while the empty space above them does. */
uniform float grass_top = 0.34;
uniform float rooted_fraction = 0.06;

varying vec3 instance_tint;
varying vec2 card_uv;

void vertex() {
	instance_tint = COLOR.rgb;
	card_uv = UV;

	// Only the top of the card moves, and further in a gust. The travelling
	// phase is what makes a field ripple rather than lean as one piece.
	vec3 world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float speed = length(wind_vector);
	float phase = TIME * (1.2 + speed * 0.35) + world.x * 0.55 + world.z * 0.41;
	float lean = clamp(0.25 + speed * 0.10 + gust * 0.35, 0.0, 1.4);
	// UV.y is 1 at the foot of the card. Height up the grass, not up the card.
	float up_blade = clamp((1.0 - UV.y) / max(grass_top, 0.001), 0.0, 1.0);
	float free = clamp((up_blade - rooted_fraction)
					   / max(1.0 - rooted_fraction, 0.001), 0.0, 1.0);
	// Cubic: a blade's tip travels much further than its middle, and the roots
	// do not move at all.
	vec3 direction = speed > 0.01 ? normalize(wind_vector) : vec3(1.0, 0.0, 0.0);
	VERTEX += direction * 0.14 * (free * free * free) * lean
			* (0.65 + 0.35 * sin(phase));
}

void fragment() {
	vec4 sampled = texture(card, card_uv);
	// Alpha-cut, not blended: a field of grass cannot be depth-sorted.
	if (sampled.a < alpha_cut) {
		discard;
	}
	// The bake carried its own flat white light, so the card is albedo times
	// that. Scale it back or the scene lights an already-lit texture.
	ALBEDO = sampled.rgb * instance_tint * bake_gain;
	ALPHA = 1.0;
	ROUGHNESS = 0.95;

	// Canopy shading. These are double-sided and Godot flips the normal on a
	// back face, which put a hard black side on every tuft.
	vec3 up_view = (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	NORMAL = normalize(mix(NORMAL, up_view, 0.72));
}
"""
	var material_object := ShaderMaterial.new()
	material_object.shader = shader
	material_object.set_shader_parameter("card", texture)
	return material_object
