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
	_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.045, 0.06, 0.42))

	var bar_w: float = minf(size.x * 0.52, 900.0)
	var bar_x: float = (size.x - bar_w) * 0.5
	var bar_y: float = size.y * 0.72

	UITheme.draw_label(_canvas, Vector2(bar_x, bar_y - 96.0), "loading",
					   UITheme.ACCENT, 5.0, UITheme.SIZE_SECTION)
	UITheme.draw_display(_canvas, Vector2(bar_x, bar_y - 40.0), sortie,
						 UITheme.SIZE_LARGE, UITheme.TEXT)

	# The bar. Deliberately tall - a hairline progress bar on a 4K screen is a
	# rumour, and this is the only thing on the screen that is moving.
	var track := Rect2(bar_x, bar_y, bar_w, 14.0)
	_canvas.draw_rect(track, Color(1, 1, 1, 0.10), true)
	var filled: float = _shown * bar_w
	if filled > 1.0:
		var fill := Rect2(track.position, Vector2(filled, track.size.y))
		UITheme.draw_glow(_canvas, fill, UITheme.ACCENT, 8.0, 2)
		_canvas.draw_rect(fill, UITheme.ACCENT, true)

	UITheme.draw_text(_canvas, Vector2(bar_x, bar_y + 46.0), _stage,
					  UITheme.SIZE_BODY, UITheme.TEXT_DIM)
	UITheme.draw_text(_canvas, Vector2(bar_x, bar_y + 46.0),
					  "%d%%" % roundi(_shown * 100.0),
					  UITheme.SIZE_BODY, UITheme.ACCENT,
					  HORIZONTAL_ALIGNMENT_RIGHT, bar_w)
