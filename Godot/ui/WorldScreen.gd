# OpenRC Simulator - choosing where and when to fly.
#
# Two columns: the place and the weather. They are independent - any scene can
# be flown in any weather - because that is how a flying day works, and because
# it is the combination that decides whether a given aeroplane is a pleasure or
# a handful.
#
# Each entry says what it will do to the air as well as what it looks like. Wind
# and turbulence are what the pilot actually has to fly; the colour of the sky
# is the part they notice first.
extends CanvasLayer

const UITheme := preload("res://ui/UITheme.gd")
const ScenePresetsLib := preload("res://world/ScenePresets.gd")
const WeatherLib := preload("res://world/Weather.gd")

signal chosen(scene_id: String, weather_id: String)
signal cancelled

var _canvas: Control
var _scenes: Array[Dictionary] = []
var _weathers: Array[Dictionary] = []
var _scene_index: int = 0
var _weather_index: int = 0
## Which column has the keyboard: 0 place, 1 weather.
var _column: int = 0


func _ready() -> void:
	layer = 24
	_scenes = ScenePresetsLib.all()
	_weathers = WeatherLib.all()

	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_screen)
	add_child(_canvas)


func select(scene_id: String, weather_id: String) -> void:
	for i in _scenes.size():
		if _scenes[i]["id"] == scene_id:
			_scene_index = i
	for i in _weathers.size():
		if _weathers[i]["id"] == weather_id:
			_weather_index = i
	if _canvas != null:
		_canvas.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key: int = (event as InputEventKey).keycode
	match key:
		KEY_LEFT:
			_column = 0
		KEY_RIGHT:
			_column = 1
		KEY_UP:
			if _column == 0:
				_scene_index = posmod(_scene_index - 1, _scenes.size())
			else:
				_weather_index = posmod(_weather_index - 1, _weathers.size())
		KEY_DOWN:
			if _column == 0:
				_scene_index = posmod(_scene_index + 1, _scenes.size())
			else:
				_weather_index = posmod(_weather_index + 1, _weathers.size())
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			chosen.emit(_scenes[_scene_index]["id"], _weathers[_weather_index]["id"])
			get_viewport().set_input_as_handled()
			return
		KEY_ESCAPE:
			cancelled.emit()
			get_viewport().set_input_as_handled()
			return
		_:
			return
	_canvas.queue_redraw()
	get_viewport().set_input_as_handled()


## One preview per column, reused as the selection moves.
var _previews: Dictionary = {}


func _draw_screen() -> void:
	var size: Vector2 = _canvas.size
	# Opaque. At 0.90 the menu behind - its headings, its aircraft list, its
	# brief - read straight through both columns, and the two screens' hint
	# lines collided into one unreadable row along the bottom.
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.045, 0.055, 1.0))

	var heading := "WHERE AND WHEN"
	UITheme.draw_label(_canvas,
			Vector2(size.x * 0.5 - UITheme.label_width(heading, 3.0, UITheme.SIZE_LABEL) * 0.5, 54),
			heading, UITheme.TEXT_DIM, 3.0, UITheme.SIZE_LABEL)

	# Wide columns. At 1080 across the whole screen each column was a portrait
	# hole, and a 16:9 preview dropped into it lost its sky and two thirds of
	# its horizon - the Meadow Field frame cropped down to a strip of scrub
	# that could have been anywhere.
	var width: float = minf(size.x * 0.92, 1560.0)
	var left: float = (size.x - width) * 0.5
	var column: float = width * 0.5 - 16.0

	_draw_column(Rect2(left, 96.0, column, size.y - 190.0), "PLACE",
			_scenes, _scene_index, _column == 0, "scene")
	_draw_column(Rect2(left + column + 32.0, 96.0, column, size.y - 190.0), "WEATHER",
			_weathers, _weather_index, _column == 1, "weather")

	UITheme.draw_text(_canvas, Vector2(0.0, size.y - 34),
			"left / right   column        up / down   choose        enter   fly        esc   back",
			UITheme.SIZE_LABEL, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER, size.x)


func _draw_column(rect: Rect2, heading: String, entries: Array[Dictionary],
				  index: int, active: bool, kind: String) -> void:
	UITheme.draw_panel(_canvas, rect, UITheme.PANEL_SOLID,
			UITheme.ACCENT if active else UITheme.STROKE)

	var x: float = rect.position.x + 24.0
	var y: float = rect.position.y + 34.0
	UITheme.draw_label(_canvas, Vector2(x, y), heading,
			UITheme.ACCENT if active else UITheme.TEXT_DIM, 2.4, UITheme.SIZE_LABEL)
	y += 26.0

	for i in entries.size():
		var entry: Dictionary = entries[i]
		var selected: bool = i == index
		var row := Rect2(x - 10.0, y - 2.0, rect.size.x - 28.0, 34.0)
		if selected:
			UITheme.draw_panel(_canvas, row,
					UITheme.ACCENT_DIM if active else Color(1, 1, 1, 0.06),
					Color(0, 0, 0, 0))
		UITheme.draw_text(_canvas, Vector2(x, y + 21.0), entry["name"],
				UITheme.SIZE_VALUE,
				UITheme.TEXT if selected else UITheme.TEXT_DIM)
		y += 38.0

	# The detail for whatever is selected, under the list. Deliberately the same
	# space whichever column is active, so the eye does not have to move.
	y += 12.0
	UITheme.draw_rule(_canvas, Vector2(x, y), rect.size.x - 48.0)
	y += 24.0

	var chosen_entry: Dictionary = entries[index]
	for line in UITheme.wrap_text(chosen_entry["description"], rect.size.x - 48.0, UITheme.SIZE_LABEL):
		UITheme.draw_text(_canvas, Vector2(x, y), line, UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
		y += 17.0

	# What it does to the air, for the weather column: this is the half a pilot
	# feels rather than sees, and it is the half that decides the sortie.
	if chosen_entry.has("wind_mps"):
		y += 16.0
		var gust: float = float(chosen_entry["wind_mps"]) * float(chosen_entry["gust"])
		for row in [["wind", "%.1f m/s" % chosen_entry["wind_mps"]],
					["gusting to", "%.1f m/s" % (float(chosen_entry["wind_mps"]) + gust)],
					["turbulence", "%.1f m/s" % chosen_entry["turbulence"]],
					["ground grip", "%.0f %%" % (float(chosen_entry["ground_grip"]) * 100.0)]]:
			UITheme.draw_text(_canvas, Vector2(x, y), row[0], UITheme.SIZE_LABEL, UITheme.TEXT_DIM)
			UITheme.draw_text(_canvas, Vector2(x + 150.0, y), row[1],
					UITheme.SIZE_BODY, UITheme.TEXT)
			y += 24.0

	# The picture, filling the rest of the column. A place chooser made of
	# nothing but nouns asks the player to pick a landscape they have never
	# seen; these are real frames from the place itself, the same ones the
	# menu shows.
	_place_preview(kind, String(entries[index]["id"]),
				   Rect2(rect.position.x + 24.0, y + 18.0, rect.size.x - 48.0,
						 rect.position.y + rect.size.y - y - 42.0))


## Shows the preview for `id` at `rect`, keeping one TextureRect per column so
## changing the selection swaps the texture rather than leaking a node a frame.
func _place_preview(kind: String, id: String, rect: Rect2) -> void:
	if rect.size.y < 60.0:
		return
	var path: String = "res://assets/previews/%s_%s.png" % [kind, id]
	if not ResourceLoader.exists(path):
		return
	var view: TextureRect = _previews.get(kind)
	if view == null:
		view = TextureRect.new()
		view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		view.clip_contents = true
		_previews[kind] = view
		_canvas.add_child(view)
	view.texture = load(path) as Texture2D
	view.position = rect.position
	view.size = rect.size


static func _wrap(text: String, columns: int) -> PackedStringArray:
	var lines := PackedStringArray()
	var current := ""
	for word in text.split(" ", false):
		if current.is_empty():
			current = word
		elif current.length() + 1 + word.length() <= columns:
			current += " " + word
		else:
			lines.append(current)
			current = word
	if not current.is_empty():
		lines.append(current)
	return lines
