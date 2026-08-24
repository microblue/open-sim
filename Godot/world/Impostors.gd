# OpenRC Simulator - drawing a forest out of photographs.
#
# Each entry is a two-triangle quad carrying an atlas of the same tree rendered
# from eight angles by tools/BakeImpostors.gd. The quad turns to face the camera
# about the vertical - trees stay upright - and picks the view nearest to how
# the camera is actually looking at it.
#
# Two triangles instead of a hundred and thirty thousand, and it is a photograph
# of a real scanned tree rather than a cone. This is what every flight simulator
# does, and it is the only thing that makes a forest of real trees possible: a
# scanned canopy cannot be decimated, because its leaves are separate alpha
# cards and simplifying between two of them destroys both.
#
# What it costs: an impostor is flat. Fly close enough and the parallax is
# missing, which is why the near band still draws real geometry and this takes
# over past it.
class_name Impostors
extends RefCounted

const DIR := "Godot/assets/impostors"

static var _cache: Dictionary = {}
static var _quad: Mesh = null


## Material and quad for one baked model, or an empty dictionary if it has not
## been baked. The result carries the metrics the caller needs to size the
## instance transform.
static func load_for(sim: Node, name: String) -> Dictionary:
	if _cache.has(name):
		return _cache[name]

	var image_path: String = sim.resolve_data_path("%s/%s.png" % [DIR, name])
	var metrics_path: String = sim.resolve_data_path("%s/%s.json" % [DIR, name])
	if not FileAccess.file_exists(image_path) or not FileAccess.file_exists(metrics_path):
		_cache[name] = {}
		return {}

	var image := Image.new()
	if image.load(image_path) != OK:
		_cache[name] = {}
		return {}
	image.generate_mipmaps()
	var atlas: ImageTexture = ImageTexture.create_from_image(image)

	var text: String = FileAccess.get_file_as_string(metrics_path)
	var metrics: Variant = JSON.parse_string(text)
	if typeof(metrics) != TYPE_DICTIONARY:
		_cache[name] = {}
		return {}

	var material := ShaderMaterial.new()
	material.shader = shader()
	material.set_shader_parameter("atlas", atlas)
	material.set_shader_parameter("views", int(metrics["views"]))
	material.set_shader_parameter("quad_size", float(metrics["extent"]))
	material.set_shader_parameter("centre_y", float(metrics["centre_y"]))

	var result := {
		"material": material,
		"mesh": quad(),
		"extent": float(metrics["extent"]),
		"centre_y": float(metrics["centre_y"]),
		"height": float(metrics["height"]),
	}
	_cache[name] = result
	return result


## A unit quad in the XY plane, which the shader then orients and sizes. Shared
## by every impostor: the size is a shader parameter, not geometry.
static func quad() -> Mesh:
	if _quad != null:
		return _quad

	var vertices := PackedVector3Array([
		Vector3(-0.5, -0.5, 0.0), Vector3(0.5, -0.5, 0.0),
		Vector3(0.5, 0.5, 0.0), Vector3(-0.5, 0.5, 0.0),
	])
	var uvs := PackedVector2Array([
		Vector2(0.0, 1.0), Vector2(1.0, 1.0),
		Vector2(1.0, 0.0), Vector2(0.0, 0.0),
	])
	# Clockwise, Godot's front face - though the shader disables culling, since
	# a billboard is seen from whichever side it happens to present.
	var indices := PackedInt32Array([0, 2, 1, 0, 3, 2])
	var normals := PackedVector3Array([
		Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1),
	])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# A generous custom AABB: the shader moves the vertices a long way from
	# where they nominally are, and Godot culls on the mesh's own bounds.
	mesh.custom_aabb = AABB(Vector3(-40, -40, -40), Vector3(80, 80, 80))
	_quad = mesh
	return _quad


static func shader() -> Shader:
	var shader_object := Shader.new()
	shader_object.code = """
shader_type spatial;
// world_vertex_coords so the billboard can be built directly in world space -
// inverting the model matrix per vertex to get back to local would cost more
// than the quad itself.
render_mode world_vertex_coords, cull_disabled, depth_prepass_alpha,
			diffuse_burley, specular_disabled;

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform int views = 8;
uniform float quad_size = 20.0;
uniform float centre_y = 10.0;
uniform float alpha_cut = 0.35;
/** The bake was lit by a flat white ambient so the atlas would hold the plant's
 *  own colour. That is not quite albedo - it is albedo times the bake's own
 *  lighting - so the scene would otherwise light an already-lit texture and
 *  every tree came out bleached. One number, tunable without re-baking. */
uniform float bake_gain = 0.58;
uniform vec3 wind_vector = vec3(0.0, 0.0, 0.0);

varying vec2 atlas_uv;
varying vec3 tint;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	// Uniform scale, taken from the instance transform the scatter built.
	float scale = length(MODEL_MATRIX[0].xyz);

	// Which way the instance was planted, so two trees side by side do not
	// present the same face.
	vec3 forward = MODEL_MATRIX[2].xyz;
	float instance_yaw = atan(forward.x, forward.z);

	vec3 to_camera = CAMERA_POSITION_WORLD - origin;
	float camera_yaw = atan(to_camera.x, to_camera.z);

	// Nearest of the baked views, in the instance's own frame.
	float turns = fract((camera_yaw - instance_yaw) / TAU + 1.0);
	float view = mod(floor(turns * float(views) + 0.5), float(views));

	// A billboard about the vertical only: a tree leaning to face the camera
	// is worse than one that is slightly the wrong way round.
	vec3 flat_to_camera = normalize(vec3(to_camera.x, 0.0, to_camera.z));
	vec3 right = vec3(flat_to_camera.z, 0.0, -flat_to_camera.x);
	vec3 up = vec3(0.0, 1.0, 0.0);

	// The corner comes from UV, not from VERTEX.
	//
	// Under world_vertex_coords the incoming VERTEX has already been through
	// the model matrix, so it is a world position rather than the unit quad
	// this needs. Reading it as local put every card somewhere else entirely
	// and the whole forest vanished. UV is untouched by the transform.
	vec2 corner = vec2(UV.x - 0.5, 0.5 - UV.y);
	float size = quad_size * scale;
	vec3 offset = right * corner.x * size + up * corner.y * size;

	// Sway, applied at the top of the quad only, from the same wind vector
	// everything else in the world reads.
	float speed = length(wind_vector);
	if (speed > 0.01) {
		float phase = TIME * (0.7 + speed * 0.12) + origin.x * 0.11 + origin.z * 0.09;
		offset += normalize(wind_vector) * max(0.0, 0.5 - UV.y) * 2.0
				* size * 0.012 * (0.4 + speed * 0.06) * sin(phase);
	}

	VERTEX = origin + vec3(0.0, centre_y * scale, 0.0) + offset;

	// Facing the camera, tilted up: a flat card lit face-on has no shading at
	// all, and a canopy lit from above is what the eye expects.
	NORMAL = normalize(flat_to_camera * 0.55 + up * 0.85);

	atlas_uv = vec2((UV.x + view) / float(views), UV.y);
	tint = COLOR.rgb;
}

void fragment() {
	vec4 sampled = texture(atlas, atlas_uv);
	// Alpha-cut rather than blended. Blended foliage has to be sorted, and a
	// forest cannot be; the cut costs a hard edge at this range and nothing
	// else.
	if (sampled.a < alpha_cut) {
		discard;
	}
	ALBEDO = sampled.rgb * tint * bake_gain;
	ALPHA = 1.0;
	ROUGHNESS = 0.95;
	// The bake carried its own weak key light. Cancel most of it back out so
	// the scene's sun does the shading rather than fighting a frozen one.
	AO = 0.85;
	AO_LIGHT_AFFECT = 0.6;
}
"""
	return shader_object
