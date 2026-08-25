# OpenRC Simulator - weather.
#
# Not a filter over the picture. Each state changes three things at once:
#
#   what you see    sky, fog, light, and precipitation falling past the model
#   what you feel   wind speed and turbulence, which the flight model reads
#   what you land on  the ground's friction, through the terrain's surface
#
# That last one is why this lives beside the world rather than in the HUD: a wet
# strip is a real hazard, and a simulator that renders rain without changing the
# braking is teaching the wrong lesson.
#
# Precipitation is drawn as a box of particles that follows the camera. It never
# has to be more than that: rain a hundred metres away is invisible, and rain
# you can see is rain within a few metres of your eye.
class_name Weather
extends RefCounted


static func all() -> Array[Dictionary]:
	return [
		{
			"id": "clear",
			"name": "Clear",
			"description": "Light wind, good visibility.",
			"wind_mps": 3.0, "gust": 0.15, "turbulence": 0.6,
			"fog_density": 0.0000075, "aerial": 0.22,
			"light_scale": 1.0, "sky_scale": 1.0,
			"volumetric": 0.0,
			"precipitation": "", "rate": 0.0,
			"ground_grip": 1.0,
		},
		{
			"id": "breezy",
			"name": "Breezy",
			"description": "Twenty knots across the strip, and it is not steady. "
					+ "Crosswind landings, and a trainer will be working.",
			"wind_mps": 9.5, "gust": 0.45, "turbulence": 2.2,
			"fog_density": 0.000012, "aerial": 0.26,
			"light_scale": 0.96, "sky_scale": 1.0,
			"volumetric": 0.0,
			"precipitation": "", "rate": 0.0,
			"ground_grip": 1.0,
		},
		{
			"id": "overcast",
			"name": "Overcast",
			"description": "Flat grey light and a low cloudbase. Nothing wrong "
					+ "with the air; you just cannot see the model as well.",
			"wind_mps": 5.0, "gust": 0.25, "turbulence": 1.1,
			"fog_density": 0.00006, "aerial": 0.55,
			"light_scale": 0.42, "sky_scale": 0.72,
			"volumetric": 0.0,
			"precipitation": "", "rate": 0.0,
			"ground_grip": 1.0,
		},
		{
			"id": "rain",
			"name": "Rain",
			"description": "Wet and gusty. The strip has no grip, the model is "
					+ "hard to see, and water on a foam wing is weight you did "
					+ "not plan for.",
			"wind_mps": 7.5, "gust": 0.55, "turbulence": 2.6,
			"fog_density": 0.00006, "aerial": 0.35,
			"light_scale": 0.30, "sky_scale": 0.55,
			# Volumetric fog was on here (0.010) and it whitened the whole
			# view: the sun lights the medium, and over an open field there is
			# nothing to occlude it. Depth fog carries the rain's mood.
			"volumetric": 0.0,
			"precipitation": "rain", "rate": 6000.0,
			"ground_grip": 0.55,
		},
		{
			"id": "snow",
			"name": "Snow",
			"description": "Still, silent and almost no contrast. Finding the "
					+ "model against a white sky over white ground is most of "
					+ "the difficulty.",
			"wind_mps": 2.5, "gust": 0.20, "turbulence": 0.8,
			"fog_density": 0.00008, "aerial": 0.38,
			"light_scale": 0.46, "sky_scale": 0.80,
			"volumetric": 0.0,
			"precipitation": "snow", "rate": 4200.0,
			"ground_grip": 0.42,
		},
	]


static func by_id(id: String) -> Dictionary:
	for state in all():
		if state["id"] == id:
			return state
	return all()[0]


## Build the particle system for a precipitation kind, or null for none.
##
## GPUParticles3D with a box emitter that rides with the camera: what matters is
## the few metres in front of the eye, and a world-sized emitter would spend
## every particle where nobody is looking.
static func build_precipitation(kind: String, rate: float) -> GPUParticles3D:
	if kind.is_empty() or rate <= 0.0:
		return null

	var raining: bool = kind == "rain"
	var extent: float = 26.0 if raining else 22.0
	var height: float = 22.0

	# A soft sprite for the card. The first version drew a plain white quad and
	# a snowflake is exactly as square as the quad it is printed on - a field
	# of visible squares is the fastest way to read precipitation as fake. The
	# sprite is generated here, a radial falloff cut into an image, so it stays
	# round at any size and the repository stays text. Rain gets the same dot
	# stretched along its fall, which turns the streak's hard bar ends soft.
	var sprite := _soft_sprite(5.0, 3.2 if raining else 1.0)

	var material := ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	material.emission_box_extents = Vector3(extent, 1.0, extent)
	material.direction = Vector3(0.0, -1.0, 0.0)
	material.spread = 4.0 if raining else 22.0
	material.gravity = Vector3(0.0, -9.0 if raining else -1.2, 0.0)
	material.initial_velocity_min = 13.0 if raining else 0.9
	material.initial_velocity_max = 17.0 if raining else 1.6
	# Snow drifts sideways and tumbles; rain does not have time to.
	if not raining:
		material.turbulence_enabled = true
		material.turbulence_noise_strength = 0.9
		material.turbulence_noise_scale = 2.4
	material.scale_min = 0.6
	material.scale_max = 1.4

	var mesh := QuadMesh.new()
	# A long thin streak for rain, a small square for a flake (the sprite
	# makes the square read as a dot). The streak is what reads as speed; a
	# round raindrop reads as a bubble. Sized up from the first attempt, which
	# rendered as one-pixel specks at the pilot's distance.
	mesh.size = Vector2(0.016, 0.46) if raining else Vector2(0.065, 0.065)

	var surface := StandardMaterial3D.new()
	surface.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	surface.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	surface.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	surface.billboard_keep_scale = true
	surface.vertex_color_use_as_albedo = false
	surface.albedo_texture = sprite
	surface.albedo_color = Color(0.80, 0.86, 0.96, 0.90) if raining \
			else Color(1.0, 1.0, 1.0, 1.0)
	surface.disable_receive_shadows = true
	mesh.material = surface

	var particles := GPUParticles3D.new()
	particles.name = "Precipitation"
	particles.amount = int(rate)
	particles.lifetime = (height / 15.0) if raining else 14.0
	particles.preprocess = particles.lifetime
	particles.process_material = material
	particles.draw_pass_1 = mesh
	particles.local_coords = false
	particles.visibility_aabb = AABB(Vector3(-extent, -height, -extent),
									 Vector3(extent * 2.0, height * 2.0, extent * 2.0))
	particles.position = Vector3(0.0, height * 0.5, 0.0)
	return particles


## A soft dot with a smooth alpha falloff, stretched for a rain streak. The
## texture is generated once per call - it is tiny, and the particles are
## unshaded so there is no lighting to fight the falloff.
static func _soft_sprite(radius: float, stretch: float) -> ImageTexture:
	var size: int = 64
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half: float = float(size) * 0.5
	for y in size:
		for x in size:
			var dx: float = (float(x) + 0.5 - half) / half
			var dy: float = (float(y) + 0.5 - half) / half * stretch
			var d: float = sqrt(dx * dx + dy * dy)
			var a: float = clampf(1.0 - d / 1.0, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(image)
