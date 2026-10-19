# OpenRC Simulator - the height cue: a mark on the ground straight below the
# aeroplane.
#
# Not a shadow. The sun's shadow already exists and is left exactly as it is;
# it falls wherever the sun puts it, which at nine in the morning is thirty
# metres to one side of the model and tells a pilot nothing about how high it
# is. This one is projected straight DOWN. The gap between the model and its
# mark is the height, read at a glance in the place the pilot is already
# looking - which is what a beginner judging a flare cannot do from a number
# in the corner of the screen.
#
# It is strongest near the ground, where height is the decision, and fades out
# by FADE_OUT_M, where it is a speck on the far side of the field and the
# altimeter is the better instrument anyway.
extends MeshInstance3D

const Settings := preload("res://ui/Settings.gd")

@export var simulation_path: NodePath

## Opacity at the ground, and what is left of it by FADE_START_M.
const NEAR_ALPHA: float = 0.6
const FAR_ALPHA: float = 0.15
const FADE_START_M: float = 50.0
const FADE_OUT_M: float = 80.0
## Lifted clear of the surface so it does not z-fight the terrain it lies on.
const LIFT_M: float = 0.04
## The silhouette's texture, square. Small: it is a blurred shape on the grass.
const TEXTURE_SIZE: int = 96

## How deep the grass is that the mark has to show through, and how far below
## the aeroplane's middle its lowest part hangs. Both are display aids, tuned
## by eye; see the depth bias below.
const GRASS_COVER_M: float = 0.3
const AIRFRAME_CLEARANCE_M: float = 0.35
## The most the mark is ever pulled towards the camera.
const MAX_DEPTH_BIAS_M: float = 12.0

## Drawn in front of the grass without moving on screen.
##
## The field is carpeted in grass cards out to 120 m, and from a standing
## pilot's eye a mark lying ON the ground is seen at a grazing angle through
## a metre or more of blades: it was simply invisible. So each vertex is
## pulled towards the camera along its own view ray. Its projection is
## unchanged - it is the same point on screen - but it now wins the depth test
## against the blades in front of it.
const SHADER_CODE: String = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled,
		skip_vertex_transform, shadows_disabled;

uniform sampler2D silhouette : source_color, filter_linear_mipmap;
uniform float opacity = 0.6;
uniform float depth_bias = 0.0;

void vertex() {
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float d = length(VERTEX);
	VERTEX *= max(d - depth_bias, 0.05) / max(d, 0.0001);
}

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = texture(silhouette, UV).a * opacity;
}
"""

var _sim: RCSimulationNode
var _material: ShaderMaterial


func _ready() -> void:
	_sim = get_node_or_null(simulation_path) as RCSimulationNode
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	# Lying flat, facing up.
	quad.orientation = PlaneMesh.FACE_Y
	mesh = quad

	var shader := Shader.new()
	shader.code = SHADER_CODE
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter("silhouette", _silhouette())
	material_override = _material
	visible = false


## Cycles vertical / off, and remembers it.
func toggle() -> void:
	var on: bool = not bool(Settings.get_value("camera/height_cue"))
	Settings.set_value("camera/height_cue", on)
	print("Height cue %s." % ("vertical" if on else "off"))


## A soft plan-view silhouette: wing, fuselage, tailplane, as the union of three
## blurred ellipses. A plain round blob reads as a hole in the ground; a cross
## reads as an aeroplane, and shows which way it is pointing.
##
## Built once, in code, so there is no asset to ship.
static func _silhouette() -> ImageTexture:
	var image := Image.create(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	var n: float = float(TEXTURE_SIZE)
	# Centre, half-extents across (span) and along (length), in 0..1 of the
	# square. Forward is -V, so the wing sits a little ahead of the middle.
	var parts: Array = [
		[Vector2(0.5, 0.40), Vector2(0.48, 0.075)],    # wing
		[Vector2(0.5, 0.52), Vector2(0.055, 0.40)],    # fuselage
		[Vector2(0.5, 0.86), Vector2(0.17, 0.045)],    # tailplane
	]
	for y in TEXTURE_SIZE:
		for x in TEXTURE_SIZE:
			var p := Vector2((float(x) + 0.5) / n, (float(y) + 0.5) / n)
			var alpha: float = 0.0
			for part in parts:
				var d: Vector2 = (p - part[0]) / part[1]
				# 1 inside, a soft shoulder out to 1.6 radii.
				alpha = maxf(alpha, 1.0 - smoothstep(0.7, 1.6, d.length()))
			image.set_pixel(x, y, Color(1, 1, 1, alpha))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


## How far to pull the mark towards the camera.
##
## Enough to clear GRASS_COVER_M of blades along a ray that meets the ground at
## the camera's grazing angle - which is cover / sin(angle), and grows long as
## the angle flattens. But never more than the aeroplane's own height above
## the mark allows: a part of the airframe on that same ray is at least
## (height - clearance) / sin(angle) in front of the mark, and a bigger bias
## would paint the mark over the model. So close to the ground, where the two
## overlap on screen, the bias shrinks to nothing, and the wheels' own contact
## with the grass says the rest.
static func depth_bias(camera: Camera3D, aircraft: Vector3, ground: float,
					   height: float) -> float:
	if camera == null:
		return 0.0
	var eye: Vector3 = camera.global_position
	var mark := Vector3(aircraft.x, ground, aircraft.z)
	var distance: float = eye.distance_to(mark)
	if distance < 0.01:
		return 0.0
	var sine: float = clampf((eye.y - ground) / distance, 0.02, 1.0)
	var cover: float = clampf(height - AIRFRAME_CLEARANCE_M, 0.0, GRASS_COVER_M)
	return minf(cover / sine, MAX_DEPTH_BIAS_M)


static func opacity_at(height_m: float) -> float:
	if height_m >= FADE_OUT_M:
		return 0.0
	if height_m > FADE_START_M:
		return lerpf(FAR_ALPHA, 0.0, (height_m - FADE_START_M) / (FADE_OUT_M - FADE_START_M))
	return lerpf(NEAR_ALPHA, FAR_ALPHA, smoothstep(0.0, FADE_START_M, maxf(height_m, 0.0)))


func _process(_delta: float) -> void:
	if _sim == null or not bool(Settings.get_value("camera/height_cue")):
		visible = false
		return

	var at: Vector3 = _sim.global_position
	var ground: float = _sim.get_terrain_height(at.x, at.z)
	var height: float = at.y - ground
	var alpha: float = opacity_at(height)
	if alpha <= 0.001:
		visible = false
		return
	visible = true
	_material.set_shader_parameter("opacity", alpha)
	_material.set_shader_parameter("depth_bias", depth_bias(
			get_viewport().get_camera_3d(), at, ground, height))

	# A touch larger than the span, because the soft edge eats into it.
	var s: float = maxf(_sim.get_wingspan_m(), 0.3) * 1.05

	# Lie on the slope, not through it: a flat quad on a hillside is half
	# buried. The normal comes from two terrain samples a metre apart.
	var hx: float = _sim.get_terrain_height(at.x + 0.5, at.z) \
			- _sim.get_terrain_height(at.x - 0.5, at.z)
	var hz: float = _sim.get_terrain_height(at.x, at.z + 0.5) \
			- _sim.get_terrain_height(at.x, at.z - 0.5)
	var up: Vector3 = Vector3(-hx, 1.0, -hz).normalized()

	# Heading only. The mark is where the aeroplane is over the ground, so it
	# turns with it but does not bank or pitch.
	var forward: Vector3 = -_sim.global_transform.basis.z
	forward = (forward - up * forward.dot(up))
	if forward.length() < 0.01:
		forward = Vector3(0, 0, -1)
	forward = forward.normalized()
	var right: Vector3 = forward.cross(up).normalized()
	# The texture's -V (top) is the nose. QuadMesh facing Y maps V along +Z, so
	# the basis's +Z is "backwards" - the opposite of forward.
	global_transform = Transform3D(Basis(right * s, up * s, -forward * s),
								   Vector3(at.x, ground + LIFT_M, at.z))
