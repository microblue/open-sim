# OpenRC Simulator - the ground's surface materials.
#
# Eight CC0 PBR sets from Poly Haven, packed into texture arrays so the terrain
# shader can reach all of them through three samplers instead of twenty-four.
# Each set is albedo, normal, roughness, ambient occlusion and height at 2K -
# real scanned surfaces, which is the whole point: a hillside painted one flat
# green is a hillside painted one flat green however well it is lit.
#
# Loaded from disk rather than preloaded, because the assets are fetched rather
# than committed. Everything returns null when they are absent and the terrain
# shader falls back to its procedural colouring, which is what a bare checkout
# and the test suite run on.
class_name WorldTextures
extends RefCounted

const TEXTURE_DIR := "Godot/assets/textures"

## Layer order in the arrays. The terrain shader indexes by these, so the order
## is part of the contract between the two.
const LAYERS: Array[String] = [
	"sparse_grass",          # 0  grassland
	"forest_leaves_03",      # 1  forest floor
	"aerial_rocks_04",       # 2  rock and scree
	"aerial_beach_02",       # 3  beach
	"aerial_sand",           # 4  desert
	"snow_field_aerial",     # 5  snow
	"dry_mud_field_001",     # 6  dry ground, worn grass
	"aerial_grass_rock",     # 7  transition, sward into rock
]

## Working resolution. The sets arrive at 2K; 1K is plenty for something tiled
## every few metres and blended at two scales, and it quarters both the memory
## and the time spent building the arrays at load.
const WORKING_SIZE: int = 1024


## Albedo, normal and roughness arrays, or an empty dictionary if the assets
## have not been fetched.
##
## Three arrays rather than one packed one. Packing roughness, AO and height
## into a single RGB image is the usual thing to do and saves a sampler, but it
## means walking a million pixels per layer - eight million in GDScript, which
## takes minutes at load. The saving is not worth it here: the terrain shader
## has samplers to spare.
static func build(sim: Node) -> Dictionary:
	var albedo := _array(sim, "albedo", true)
	if albedo == null:
		return {}

	var normal := _array(sim, "normal", false)
	var roughness := _array(sim, "roughness", false)
	if normal == null or roughness == null:
		return {}

	return {
		"albedo": albedo,
		"normal": normal,
		"roughness": roughness,
		"count": LAYERS.size(),
	}


static func _load_image(sim: Node, layer: String, map: String, _is_colour: bool) -> Image:
	var path: String = sim.resolve_data_path("%s/%s/%s.jpg" % [TEXTURE_DIR, layer, map])
	if not FileAccess.file_exists(path):
		return null
	var image := Image.new()
	if image.load(path) != OK:
		return null
	if image.get_width() != WORKING_SIZE or image.get_height() != WORKING_SIZE:
		image.resize(WORKING_SIZE, WORKING_SIZE, Image.INTERPOLATE_LANCZOS)
	image.convert(Image.FORMAT_RGB8)
	# NOT converted to linear here.
	#
	# The albedo sampler carries the `source_color` hint, which makes the shader
	# convert on read. Doing it here as well applied the curve twice and the
	# whole world came out dark and desaturated - grey gravel where there should
	# have been green sward. The hint is the right place for it; this function
	# hands over exactly what was authored.
	image.generate_mipmaps()
	return image


static func _array(sim: Node, map: String, is_colour: bool) -> Texture2DArray:
	var images: Array[Image] = []
	for layer in LAYERS:
		var image: Image = _load_image(sim, layer, map, is_colour)
		if image == null:
			return null
		images.append(image)

	var array := Texture2DArray.new()
	if array.create_from_images(images) != OK:
		return null
	return array

