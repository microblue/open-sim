# OpenRC Simulator - paused.
#
# The flight stops when the window loses focus, and it does NOT start again by
# itself when focus comes back. A pilot who alt-tabs to read something comes
# back to a model hanging exactly where they left it, with their hands not yet
# on the sticks - resuming on focus would hand them an aeroplane in a turn they
# did not see start. So coming back is a decision: a key or a click.
#
# The whole tree is paused while this is up, which stops the simulation, the
# camera, the grass and the engine sound together. This node alone keeps
# processing.
extends CanvasLayer

const UITheme := preload("res://ui/UITheme.gd")

signal resumed

## Why it paused, said on the card: "the window lost focus" or "paused".
@export var reason: String = "paused"

var _canvas: Control


func _ready() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_card)
	_canvas.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_resume())
	add_child(_canvas)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	get_viewport().set_input_as_handled()
	match (event as InputEventKey).keycode:
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_P:
			_resume()
		KEY_ESCAPE:
			get_tree().quit()


func _resume() -> void:
	resumed.emit()
	queue_free()


func _draw_card() -> void:
	var size: Vector2 = _canvas.size
	_canvas.draw_rect(Rect2(Vector2.ZERO, size),
			Color(UITheme.BASE.r, UITheme.BASE.g, UITheme.BASE.b, 0.55))
	var card := Rect2((size.x - 640.0) * 0.5, size.y * 0.5 - 100.0, 640.0, 200.0)
	UITheme.draw_panel(_canvas, card, UITheme.PANEL_SOLID, UITheme.STROKE_STRONG, 12.0)
	UITheme.draw_display(_canvas, card.position + Vector2(0, 78), "PAUSED",
			UITheme.SIZE_HERO, UITheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER, card.size.x)
	UITheme.draw_text(_canvas, card.position + Vector2(0, 118), reason,
			UITheme.SIZE_BODY, UITheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER, card.size.x)
	UITheme.draw_text(_canvas, card.position + Vector2(0, 166),
			"enter or P   resume        esc   quit",
			UITheme.SIZE_BODY, UITheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER, card.size.x)
