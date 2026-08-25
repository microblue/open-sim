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
#
# HOW THE CARD IS BUILT, AND WHY IT USES THE BAKE METRICS:
#
# The bake (tools/BakeImpostors.gd) frames the model square about its CENTRE -
# the tile is `extent` metres across and the plant sits in the middle of it,
# its roots at `centre_y - height/2` above the tile bottom and its tips at
# `centre_y + height/2`. The quad therefore has to be placed from the same two
# numbers, exactly as the tree impostors are: bottom edge at
# `centre_y - extent/2` (UV.y 1), top edge at `centre_y + extent/2` (UV.y 0),
# so that the plant's roots land on the ground and its tips at their real
# height.
#
# The first version of this did not do that. It guessed the grass occupied the
# bottom third of the tile, built a card a third the size, and sat it on the
# ground - which put the visible clump about a quarter of a metre in the air,
# and keyed the wind sway to "the bottom third of the card", a region the real
# grass does not live in. Every vertex of the real grass clamped to full
# displacement, so the whole tuft, roots included, translated sideways with the
# wind: 草根在动, not 草在动. The band below keys the sway to the actual rows
# the bake put grass on.
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
		# The tile is this many metres across, and the plant sits centred in it.
		"size": float(metrics["extent"]),
		"centre_y": float(metrics["centre_y"]),
		"height": float(metrics["height"]),
	}
	return _cache


## Three crossed blades, each a vertically segmented strip spanning the whole
## tile, positioned from the bake metrics so the plant's roots land exactly on
## the ground.
##
## The quad's bottom edge is BELOW ground level by the empty margin the bake
## left under the model. That margin is transparent in the atlas, so the buried
## part is invisible - and keeping it means the UVs keep their identity: UV.y 1
## is still the bottom of the tile, which is what the sway shader keys to.
##
## The strip is segmented rather than one flat quad. The sway is cubic in
## height - tips travel far, roots not at all - and a flat quad can only carry
## a displacement field that is linear in UV, which left the roots sliding by
## about a third of the tip travel no matter what the shader did. Segments make
## the bend real: the roots sit on a row whose displacement is zero.
static func tuft_mesh(card: Dictionary) -> ArrayMesh:
	var extent: float = card["size"]
	var centre_y: float = card["centre_y"]
	var bottom: float = centre_y - extent * 0.5
	var top: float = centre_y + extent * 0.5

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Five is enough for the cubic bend to read; eight tripled the grass
	# vertex budget for a bend nobody can count the steps of.
	var segments: int = 5
	for blade in 3:
		var angle: float = float(blade) / 3.0 * PI
		var right_dir := Vector3(cos(angle), 0.0, sin(angle))
		var normal := Vector3(-sin(angle) * 0.35, 0.94, cos(angle) * 0.35).normalized()

		for segment in segments:
			var y0: float = bottom + (top - bottom) * float(segment) / float(segments)
			var y1: float = bottom + (top - bottom) * float(segment + 1) / float(segments)
			var uv0: float = float(segment) / float(segments)
			var uv1: float = float(segment + 1) / float(segments)
			var half: float = extent * 0.5

			var corners := [
				-right_dir * half + Vector3(0.0, y0, 0.0),
				right_dir * half + Vector3(0.0, y0, 0.0),
				right_dir * half + Vector3(0.0, y1, 0.0),
				-right_dir * half + Vector3(0.0, y1, 0.0),
			]
			var uvs := [Vector2(0, uv1), Vector2(1, uv1), Vector2(1, uv0), Vector2(0, uv0)]
			# Clockwise, Godot's front face - though the material disables
			# culling, since a grass card is seen from both sides.
			for i in [0, 2, 1, 0, 3, 2]:
				surface.set_normal(normal)
				surface.set_uv(uvs[i])
				surface.add_vertex(corners[i])

	return surface.commit()


static func material(card: Dictionary) -> ShaderMaterial:
	var extent: float = card["size"]
	var height: float = card["height"]
	# The rows the bake actually put grass on, in UV space. Everything outside
	# this band is transparent and the sway must not key to it.
	var grass_top_uv: float = 0.5 - height / (2.0 * extent)
	var grass_bottom_uv: float = 0.5 + height / (2.0 * extent)

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
/** UV.y of the top of the grass and of the roots, in the card's own texture.
 *  The bake centred the plant in the tile, so these are not 0 and 1 - the
 *  sway has to be keyed to the rows that have grass on them, or the whole
 *  tuft (roots included) translates as one rigid card. */
uniform float grass_top_uv = 0.36;
uniform float grass_bottom_uv = 0.64;
/** Fraction of the grass height that is rooted and does not move at all. */
uniform float rooted_fraction = 0.06;

varying vec3 instance_tint;
varying vec2 card_uv;

void vertex() {
	instance_tint = COLOR.rgb;
	card_uv = UV;

	// Only the grass moves, and further in a gust. The travelling phase is what
	// makes a field ripple rather than lean as one piece. A small per-vertex
	// term twists the three quads of one tuft against each other instead of
	// rocking the whole card rigidly, which is how a real tuft moves.
	vec3 world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float speed = length(wind_vector);
	float phase = TIME * (1.2 + speed * 0.35) + world.x * 0.55 + world.z * 0.41
				+ UV.x * 1.4 + UV.y * 0.8;
	float lean = clamp(0.25 + speed * 0.10 + gust * 0.35, 0.0, 1.4);
	// Height up the grass, not up the card: 1 at the tips, 0 at the roots,
	// measured within the band that actually has grass on it. The band height
	// has to be the positive difference (bottom minus top), or max() collapses
	// it to epsilon and the whole field either freezes or translates as one.
	float band = max(grass_bottom_uv - grass_top_uv, 0.001);
	float up_blade = clamp((grass_bottom_uv - UV.y) / band, 0.0, 1.0);
	float free = clamp((up_blade - rooted_fraction)
					   / max(1.0 - rooted_fraction, 0.001), 0.0, 1.0);
	// Cubic: a blade's tip travels much further than its middle, and the roots
	// do not move at all. The displacement is metres, so it has to scale with
	// the instance: a card cut to a third of the scan's size is a third of
	// the height, and a third of the height bending the same distance would
	// look like a storm.
	float inst_scale = length(MODEL_MATRIX[0].xyz);
	vec3 direction = speed > 0.01 ? normalize(wind_vector) : vec3(1.0, 0.0, 0.0);
	VERTEX += direction * 0.14 * inst_scale * (free * free * free) * lean
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
	material_object.set_shader_parameter("card", card["texture"])
	material_object.set_shader_parameter("grass_top_uv", grass_top_uv)
	material_object.set_shader_parameter("grass_bottom_uv", grass_bottom_uv)
	return material_object
