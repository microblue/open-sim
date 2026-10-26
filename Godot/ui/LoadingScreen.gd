# OpenRC Simulator - what the player watches while the world is built.
#
# Pressing Fly used to hand the engine a second and a half of blocking work
# inside one frame: the window froze, then the sortie appeared. A frozen window
# is indistinguishable from a crash, and the one thing a player will not
# forgive is not knowing whether the thing is still running.
#
# So the build is pumped a piece at a time and this says where it has got to.
# The stages are named because "43%" tells a player nothing, and "planting the
# treeline" tells them what the machine is doing and roughly how much of it is
# left.
extends CanvasLayer

const UITheme := preload("res://ui/UITheme.gd")

signal finished

## Backdrop: the place being loaded, dimmed. The loading screen for a desert
## should not look like the loading screen for a coast.
@export var scene_id: String = "meadow"
## The line under the title: aeroplane, place and weather, as chosen.
@export var sortie: String = ""

var _canvas: Control
var _backdrop: TextureRect
var _progress: float = 0.0
var _shown: float = 0.0
var _stage: String = "starting up"
var _fade_out: float = -1.0


func _ready() -> void:
	layer = 60

	_backdrop = TextureRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var path: String = "res://assets/previews/scene_%s.png" % scene_id
	if ResourceLoader.exists(path):
		_backdrop.texture = load(path) as Texture2D
	# Dimmed hard. It is a backdrop, not a photograph: the type has to win.
	_backdrop.modulate = Color(0.52, 0.55, 0.60)
	add_child(_backdrop)

	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_screen)
	add_child(_canvas)


## Where the build has got to, 0..1, and what it is doing.
func report(fraction: float, stage: String) -> void:
	_progress = clampf(fraction, 0.0, 1.0)
	_stage = stage
	_canvas.queue_redraw()


## The world is up. Fades out rather than vanishing: a hard cut from a loading
## screen to a sortie reads as a glitch.
func dismiss() -> void:
	_fade_out = 0.0


func _process(delta: float) -> void:
	# The shown bar chases the real one. A progress bar that jumps in four
	# steps looks broken even when it is telling the exact truth.
	_shown = move_toward(_shown, _progress, delta * 1.6)
	if _fade_out >= 0.0:
		_fade_out += delta * 2.2
		# CanvasLayer has no modulate - it is not a CanvasItem. The two
		# children it owns are, so they carry the fade.
		var alpha: float = 1.0 - clampf(_fade_out, 0.0, 1.0)
		_canvas.modulate = Color(1, 1, 1, alpha)
		_backdrop.modulate = Color(0.52, 0.55, 0.60, alpha)
		if _fade_out >= 1.0:
			finished.emit()
			queue_free()
			return
	_canvas.queue_redraw()


func _draw_screen() -> void:
	var size: Vector2 = _canvas.size
	# A dark wash over the backdrop, heaviest at the bottom where the type is.
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(UITheme.SCRIM.r, UITheme.SCRIM.g,
			UITheme.SCRIM.b, 0.30))
	UITheme.draw_scrim(_canvas, Rect2(0.0, size.y * 0.45, size.x, size.y * 0.55), 0.0, 0.72)

	var bar_w: float = minf(size.x - 2.0 * UITheme.S8, 900.0)
	var bar_x: float = roundf((size.x - bar_w) * 0.5)
	var bar_y: float = roundf(size.y * 0.72)

	UITheme.draw_label(_canvas, Vector2(bar_x, bar_y - 84.0), "Loading", UITheme.TEXT_DIM,
			UITheme.TRACK_CAPS, UITheme.SIZE_CAPS_L, true)
	UITheme.draw_display(_canvas, Vector2(bar_x, bar_y - 30.0), sortie.replace("   -   ", "  ·  "), 40, UITheme.TEXT,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)

	# The bar: a rounded track and a solid fill. No glow - it is the only thing
	# moving on the screen, which is emphasis enough.
	var track := Rect2(bar_x, bar_y, bar_w, 6.0)
	_canvas.draw_colored_polygon(UITheme.rounded_rect(track, 3.0), Color(1, 1, 1, 0.14))
	var filled: float = roundf(_shown * bar_w)
	if filled > 6.0:
		_canvas.draw_colored_polygon(UITheme.rounded_rect(Rect2(track.position,
				Vector2(filled, track.size.y)), 3.0), UITheme.ACCENT)

	var stage: String = _stage.substr(0, 1).to_upper() + _stage.substr(1)
	UITheme.draw_text(_canvas, Vector2(bar_x, bar_y + 36.0), stage, UITheme.SIZE_BODY,
			UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, -1.0, true)
	UITheme.draw_numeral(_canvas, Vector2(bar_x + bar_w, bar_y + 36.0),
			"%d%%" % roundi(_shown * 100.0), UITheme.SIZE_BODY, UITheme.TEXT, true, true)
