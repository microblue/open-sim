# OpenRC Simulator - the worlds you can fly in.
#
# A preset is a climate, a geology and a sky. The biome rules never change:
# TerrainField still decides sand from grass from forest from snow by height,
# slope and moisture, exactly as it does for the flying field. What a preset
# changes is the world those rules read - shift the moisture down and the same
# code that grew a forest grows a desert, raise the ruggedness and the same
# ridges become spires.
#
# That matters more than it sounds. It means a new scene cannot produce terrain
# the collision surface disagrees with, or vegetation standing in the sea,
# because none of that logic is duplicated per preset.
#
# Every preset keeps a flat plateau at the origin. The strip has to stay level
# wherever it is: the landing gear model, the ground handling and the locked
# performance targets were all measured on flat ground.
class_name ScenePresets
extends RefCounted

const HDRI_DIR := "Godot/assets/hdri"


static func all() -> Array[Dictionary]:
	return [
		{
			"id": "meadow",
			"name": "Meadow Field",
			"description": "Temperate lowland. Mown strip in open pasture, mixed "
					+ "woodland on the ridges, a lake within gliding distance. "
					+ "The default, and the one to learn on.",
			"terrain": {
				"seed": 20260823, "mountain_height": 2100.0, "continent_scale": 7200.0,
				"sea_level": -135.0, "snow_line": 1250.0, "beach_height": 5.0,
				"moisture_bias": 0.0, "ruggedness": 1.0,
				"plateau_radius": 430.0, "plateau_blend": 1500.0,
			},
			"sky": "kloofendal_48d_partly_cloudy_puresky",
			"sun_angles": Vector3(-43.0, 155.0, 0.0),
			"sun_energy": 6.5,
			"weather": "clear",
		},
		{
			"id": "alpine",
			"name": "Alpine Valley",
			"description": "A field on the valley floor with three thousand "
					+ "metres of rock around it. Thin air, hard light, and "
					+ "nowhere flat to put down outside the strip. Ridge lift "
					+ "if you can find it.",
			"terrain": {
				"seed": 771031, "mountain_height": 3400.0, "continent_scale": 5200.0,
				"sea_level": -420.0, "snow_line": 900.0, "beach_height": 3.0,
				"moisture_bias": 0.06, "ruggedness": 1.85,
				"plateau_radius": 430.0, "plateau_blend": 1100.0,
			},
			"sky": "kloofendal_48d_partly_cloudy_puresky",
			"sun_angles": Vector3(-52.0, 118.0, 0.0),
			"sun_energy": 7.4,
			"weather": "clear",
		},
		{
			"id": "desert",
			"name": "Desert Mesa",
			"description": "Dry, open and hot. Sand and rock, almost nothing "
					+ "growing, and thermals off the pale ground that will "
					+ "carry a glider all afternoon. The air is thinner than "
					+ "it looks - everything flies faster.",
			"terrain": {
				"seed": 4417, "mountain_height": 1500.0, "continent_scale": 9600.0,
				"sea_level": -260.0, "snow_line": 2600.0, "beach_height": 2.0,
				"moisture_bias": -0.34, "ruggedness": 1.35,
				"plateau_radius": 430.0, "plateau_blend": 1900.0,
			},
			"sky": "kloofendal_43d_clear_puresky",
			"sun_angles": Vector3(-62.0, 200.0, 0.0),
			"sun_energy": 8.2,
			"weather": "clear",
		},
		{
			"id": "coast",
			"name": "Coastal Islands",
			"description": "A strip on a headland, with water on three sides. "
					+ "Sea breeze across the circuit and a long walk if you put "
					+ "one in the shallows. Slope soaring along the cliffs when "
					+ "the wind is onshore.",
			"terrain": {
				"seed": 90210, "mountain_height": 1200.0, "continent_scale": 4200.0,
				"sea_level": -55.0, "snow_line": 1800.0, "beach_height": 9.0,
				"moisture_bias": 0.16, "ruggedness": 1.15,
				"plateau_radius": 430.0, "plateau_blend": 1200.0,
			},
			"sky": "kloofendal_48d_partly_cloudy_puresky",
			"sun_angles": Vector3(-38.0, 172.0, 0.0),
			"sun_energy": 6.8,
			"weather": "clear",
		},
		{
			"id": "moor",
			"name": "Highland Moor",
			"description": "Wet, rolling and treeless, under weather that comes "
					+ "in off the hills without warning. Everything is grey and "
					+ "the horizon is close. Good practice for the days you "
					+ "would not normally fly.",
			"terrain": {
				"seed": 13579, "mountain_height": 1100.0, "continent_scale": 6400.0,
				"sea_level": -200.0, "snow_line": 1400.0, "beach_height": 4.0,
				"moisture_bias": 0.30, "ruggedness": 0.75,
				"plateau_radius": 430.0, "plateau_blend": 1700.0,
			},
			"sky": "wasteland_clouds_puresky",
			"sun_angles": Vector3(-30.0, 96.0, 0.0),
			"sun_energy": 3.6,
			"weather": "overcast",
		},
	]


static func by_id(id: String) -> Dictionary:
	for preset in all():
		if preset["id"] == id:
			return preset
	return all()[0]
