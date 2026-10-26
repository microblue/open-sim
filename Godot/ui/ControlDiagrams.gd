# OpenRC Simulator - pictures of the controls.
#
# A beginner does not know that "elevator" is the right stick pulled towards
# them, or that W is the throttle. So every screen that talks about the
# controls draws them: the transmitter in the pilot's hands with each stick's
# job written beside it, or the keys laid out as the two sticks they stand in
# for. The same drawing is used by the first-run setup, the help card and the
# transmitter wizard, so a pilot sees one picture everywhere.
#
# The setup screens also share a few pieces drawn here, so the first-run page
# and the wizard say the same thing the same way: the numbered connection
# steps, the "still nothing?" troubleshooting panel with the devices this
# computer can see, and the "which thumb is your throttle on?" question.
#
# Channel conventions follow RCInputNode: aileron and rudder +1 is right,
# throttle 0..1, elevator +1 is the stick pulled BACK (nose up) - which on a
# picture of a stick is down, towards the pilot.
class_name ControlDiagrams
extends RefCounted

const UI := preload("res://ui/UITheme.gd")

const AILERON := 0
const ELEVATOR := 1
const THROTTLE := 2
const RUDDER := 3

## What each stick does, for the pilot's stick mode. Each axis lists the
## channel and the words for its two ends: [channel, negative end, positive end]
## where "positive" is up on the picture for a vertical axis, right for a
## horizontal one.
static func sticks(mode: int) -> Dictionary:
	var throttle: Array = [THROTTLE, "Less power", "More power"]
	var elevator: Array = [ELEVATOR, "Nose up", "Nose down"]
	var rudder: Array = [RUDDER, "Yaw left", "Yaw right"]
	var aileron: Array = [AILERON, "Roll left", "Roll right"]
	if mode == 1:
		return {"left": {"v": elevator, "h": rudder}, "right": {"v": throttle, "h": aileron}}
	return {"left": {"v": throttle, "h": rudder}, "right": {"v": elevator, "h": aileron}}


## Which stick and axis carries a channel, as ["left"|"right", "v"|"h"].
static func where(channel: int, mode: int) -> Array:
	var layout: Dictionary = sticks(mode)
	for side in ["left", "right"]:
		for axis in ["v", "h"]:
			if int(layout[side][axis][0]) == channel:
				return [side, axis]
	return ["left", "v"]


## The keyboard keys standing in for each channel: [key for the negative end,
## key for the positive end] in the same sense as sticks() - for a vertical
## axis, [down key, up key].
static func keys(_mode: int = 2) -> Dictionary:
	# The same keys in both modes: what moves between the sticks is the job,
	# and sticks() already says which stick does which.
	return {
		"left":  {"v": ["S", "W"], "h": ["A", "D"]},
		"right": {"v": ["DOWN", "UP"], "h": ["LEFT", "RIGHT"]},
	}


## Every flying key, in reading order: W A S D, then the arrows.
static func flying_keys() -> Array:
	return ["W", "A", "S", "D", "UP", "LEFT", "DOWN", "RIGHT"]


## The keycode for a key name used above.
static func keycode(name: String) -> Key:
	match name:
		"UP": return KEY_UP
		"DOWN": return KEY_DOWN
		"LEFT": return KEY_LEFT
		"RIGHT": return KEY_RIGHT
		"W": return KEY_W
		"A": return KEY_A
		"S": return KEY_S
		"D": return KEY_D
	return KEY_NONE


## The key name for a keycode, or "" when it is not a flying key.
static func key_name(code: Key) -> String:
	for name in flying_keys():
		if keycode(String(name)) == code:
			return String(name)
	return ""


## Stick positions made straight from the keys being held, for screens that
## show the keys moving the sticks while the keyboard is not flying anything.
static func channels_from_keys(mode: int) -> PackedFloat64Array:
	var ch := PackedFloat64Array([0, 0, 0, 0])
	var k: Dictionary = keys(mode)
	var layout: Dictionary = sticks(mode)
	for side in ["left", "right"]:
		for axis in ["v", "h"]:
			var channel: int = int(layout[side][axis][0])
			var neg: bool = Input.is_key_pressed(keycode(String(k[side][axis][0])))
			var pos: bool = Input.is_key_pressed(keycode(String(k[side][axis][1])))
			var value: float = (1.0 if pos else 0.0) - (1.0 if neg else 0.0)
			if channel == THROTTLE:
				ch[channel] = 0.5 + value * 0.5
			elif channel == ELEVATOR:
				ch[channel] = -value          # the up key pushes forward: nose down
			else:
				ch[channel] = value
	return ch


## A stick's position on its picture, -1..1 each way, up and right positive.
static func stick_position(side: String, mode: int, channels: PackedFloat64Array) -> Vector2:
	if channels.size() < 4:
		return Vector2.ZERO
	var layout: Dictionary = sticks(mode)
	var v: int = int(layout[side]["v"][0])
	var h: int = int(layout[side]["h"][0])
	var y: float = 0.0
	match v:
		THROTTLE: y = clampf(channels[THROTTLE], 0.0, 1.0) * 2.0 - 1.0
		ELEVATOR: y = -channels[ELEVATOR]      # back is down, towards the pilot
		_: y = channels[v]
	return Vector2(clampf(channels[h], -1.0, 1.0), clampf(y, -1.0, 1.0))


# ------------------------------------------------------------ transmitter ---

static func _fade(c: Color, alpha: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * alpha)


## Where the drawing sits inside `rect`: the body, and each gimbal's centre
## and gate diameter. Shared by the drawing and by screens that put something
## under a gate (the wizard's capture meter).
static func transmitter_layout(rect: Rect2, labels: bool = true) -> Dictionary:
	# The antenna and handle stand above the body; the drawing, all of it,
	# stays inside `rect`.
	var aspect: float = 1.75
	var above: float = 0.26
	var h: float = minf(rect.size.x / aspect, rect.size.y / (1.0 + above))
	var w: float = h * aspect
	var top: float = rect.position.y + (rect.size.y - h * (1.0 + above)) * 0.5 + h * above
	var body := Rect2(Vector2(rect.position.x + (rect.size.x - w) * 0.5, top), Vector2(w, h))
	return {
		"body": body,
		"gate": h * (0.34 if labels else 0.40),
		"left": body.position + Vector2(w * 0.25, h * 0.50),
		"right": body.position + Vector2(w * 0.75, h * 0.50),
	}


## The transmitter, seen from the pilot: a body with two gimbals and each
## stick's job written round it.
##
## `rect` is the area to fill (the drawing keeps its own proportions inside it).
## `channels` moves the sticks live; pass an empty array for centred sticks.
## `highlight` is [side, axis] to pick out one movement - the setup wizard's
## "move this one" - drawn as a lit gate and a ghost stick sweeping the axis;
## `phase` animates the ghost. `labels` writes the actions round the gimbals.
## `alpha` fades the whole drawing (a radio that is not connected yet).
static func draw_transmitter(ci: CanvasItem, rect: Rect2, mode: int,
							 channels: PackedFloat64Array = PackedFloat64Array(),
							 highlight: Array = [], phase: float = 0.0,
							 labels: bool = true, alpha: float = 1.0) -> void:
	var lay: Dictionary = transmitter_layout(rect, labels)
	var body: Rect2 = lay["body"]
	var w: float = body.size.x
	var h: float = body.size.y

	# Antenna and handle: enough to read as a radio, not a gamepad.
	var top_mid := Vector2(body.position.x + w * 0.5, body.position.y)
	ci.draw_line(top_mid + Vector2(w * 0.30, 0), top_mid + Vector2(w * 0.36, -h * 0.22),
			_fade(UI.STROKE_HOVER, alpha), 6.0, true)
	ci.draw_circle(top_mid + Vector2(w * 0.36, -h * 0.22), 4.0, _fade(UI.STROKE_HOVER, alpha))
	UI.draw_panel(ci, Rect2(top_mid + Vector2(-w * 0.16, -h * 0.07), Vector2(w * 0.32, h * 0.1)),
			_fade(UI.SURFACE_2, alpha), _fade(UI.STROKE_STRONG, alpha), UI.R_SM)
	UI.draw_panel(ci, body, _fade(UI.SURFACE_2, alpha), _fade(UI.STROKE_STRONG, alpha), h * 0.16)
	# A faint sheen along the top edge, as on the modal shells.
	ci.draw_line(body.position + Vector2(h * 0.16, 1.0), Vector2(body.end.x - h * 0.16,
			body.position.y + 1.0), _fade(UI.GLASS_SHEEN, alpha), 1.0)
	# The screen in the middle.
	var screen := Rect2(body.position + Vector2(w * 0.42, h * 0.12), Vector2(w * 0.16, h * 0.14))
	UI.draw_panel(ci, screen, _fade(UI.BASE, alpha), _fade(Color(UI.ACCENT, 0.35), alpha), 4.0)

	var gate: float = lay["gate"]
	var layout: Dictionary = sticks(mode)
	for side in ["left", "right"]:
		var c: Vector2 = lay[side]
		var lit: bool = not highlight.is_empty() and highlight[0] == side
		ci.draw_circle(c, gate * 0.5, _fade(Color(UI.ACCENT, 0.10) if lit
				else Color(UI.BASE, 0.7), alpha))
		ci.draw_arc(c, gate * 0.5 - 1.0, 0, TAU, 64,
				_fade(UI.ACCENT if lit else UI.STROKE_HOVER, alpha), UI.STROKE_UI, true)
		ci.draw_line(c - Vector2(gate * 0.42, 0), c + Vector2(gate * 0.42, 0), _fade(UI.STROKE, alpha))
		ci.draw_line(c - Vector2(0, gate * 0.42), c + Vector2(0, gate * 0.42), _fade(UI.STROKE, alpha))

		var reach: float = gate * 0.36
		if lit:
			# The movement asked for, as a ghost stick sweeping end to end and
			# arrowheads at both ends of its travel.
			var along: Vector2 = Vector2(0, -1) if highlight[1] == "v" else Vector2(1, 0)
			var sweep: float = sin(phase * 2.2)
			_arrow(ci, c + along * reach * 1.12, along, _fade(UI.ACCENT, alpha))
			_arrow(ci, c - along * reach * 1.12, -along, _fade(UI.ACCENT, alpha))
			ci.draw_line(c - along * reach, c + along * reach, _fade(Color(UI.ACCENT, 0.35), alpha), 2.0)
			ci.draw_circle(c + along * reach * sweep, gate * 0.09, _fade(Color(UI.ACCENT, 0.30), alpha))

		var at: Vector2 = stick_position(side, mode, channels)
		var knob: Vector2 = c + Vector2(at.x, -at.y) * reach
		ci.draw_line(c, knob, _fade(Color(UI.TEXT, 0.55), alpha), 3.0, true)
		ci.draw_circle(knob, gate * 0.085, _fade(UI.TEXT, alpha))
		ci.draw_circle(knob, gate * 0.045, _fade(UI.ACCENT if lit else UI.TEXT_FAINT, alpha))

		if labels:
			var size: int = UI.SIZE_BODY_S if w > 560.0 else UI.SIZE_CAPS
			var f: Font = UI.font_semibold()
			var v: Array = layout[side]["v"]
			var hz: Array = layout[side]["h"]
			var dim: Color = _fade(UI.TEXT_DIM, alpha)
			var on: Color = _fade(UI.ACCENT_HI, alpha)
			var v_lit: bool = lit and highlight[1] == "v"
			var h_lit: bool = lit and highlight[1] == "h"
			_centred(ci, c + Vector2(0, -gate * 0.5 - 12.0), String(v[2]), size, on if v_lit else dim)
			_centred(ci, c + Vector2(0, gate * 0.5 + float(size) + 6.0), String(v[1]), size,
					on if v_lit else dim)
			# The two horizontal ends as one line under the gimbal, with
			# arrows: beside it, the inner labels of the two sticks ran into
			# each other in the middle of the radio.
			var hy: float = c.y + gate * 0.5 + float(size) * 2.0 + 14.0
			var col: Color = on if h_lit else dim
			var left_text: String = String(hz[1])
			var right_text: String = String(hz[2])
			var lw: float = _semibold_width(left_text, size)
			var rw: float = _semibold_width(right_text, size)
			UI.draw_text(ci, Vector2(c.x - 10.0 - lw, hy), left_text, size, col,
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, f)
			UI.draw_text(ci, Vector2(c.x + 10.0, hy), right_text, size, col,
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, f)
			var ay: float = hy - float(size) * 0.32
			UI.draw_arrow_glyph(ci, Vector2(c.x - 22.0 - lw, ay), 3, 12.0, col)
			UI.draw_arrow_glyph(ci, Vector2(c.x + 22.0 + rw, ay), 1, 12.0, col)
			ci.draw_line(Vector2(c.x, hy - float(size) * 0.75), Vector2(c.x, hy + 2.0),
					_fade(UI.STROKE_STRONG, alpha), 1.0)


static func _semibold_width(text: String, size: int) -> float:
	return UI.font_semibold().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


static func _centred(ci: CanvasItem, at: Vector2, text: String, size: int, colour: Color) -> void:
	var tw: float = _semibold_width(text, size)
	UI.draw_text(ci, at - Vector2(tw * 0.5, 0), text, size, colour,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold())


static func _arrow(ci: CanvasItem, tip: Vector2, direction: Vector2, colour: Color) -> void:
	var d: Vector2 = direction.normalized()
	var n := Vector2(-d.y, d.x)
	ci.draw_colored_polygon(PackedVector2Array([tip, tip - d * 10.0 + n * 6.0,
			tip - d * 10.0 - n * 6.0]), colour)


# --------------------------------------------------------------- keyboard ---

## The flying keys, laid out as the two sticks they stand in for: W A S D on
## the left, the arrows on the right, each with what it does beneath. Keys being
## held light up. Returns the size drawn; `origin` is the top-left corner.
## `tried` (key name -> true) ticks keys already pressed once, for the
## first-run "press each key once" goal. `with_actions` false draws the keys
## alone, without the list of what each one does.
static func draw_keyboard(ci: CanvasItem, origin: Vector2, mode: int,
						  live: bool = true, cap: float = 64.0,
						  tried: Dictionary = {}, with_actions: bool = true) -> Vector2:
	var layout: Dictionary = sticks(mode)
	var keymap: Dictionary = keys(mode)
	var gap: float = 8.0
	var block: float = cap * 3.0 + gap * 2.0
	var between: float = cap * 2.4
	var row_h: float = 30.0
	var text_size: int = UI.SIZE_CAPS if cap < 56.0 else UI.SIZE_BODY_S
	for i in 2:
		var side: String = ["left", "right"][i]
		var x0: float = origin.x + float(i) * (block + between)
		var y0: float = origin.y + 30.0
		UI.draw_label(ci, Vector2(x0, origin.y + 14.0),
				"left stick" if side == "left" else "right stick", UI.TEXT_DIM)
		var v: Array = keymap[side]["v"]
		var hz: Array = keymap[side]["h"]
		var places := {
			String(v[1]): Vector2(x0 + cap + gap, y0),
			String(hz[0]): Vector2(x0, y0 + cap + gap),
			String(v[0]): Vector2(x0 + cap + gap, y0 + cap + gap),
			String(hz[1]): Vector2(x0 + (cap + gap) * 2.0, y0 + cap + gap),
		}
		var actions := {
			String(v[1]): String(layout[side]["v"][2]),
			String(v[0]): String(layout[side]["v"][1]),
			String(hz[0]): String(layout[side]["h"][1]),
			String(hz[1]): String(layout[side]["h"][2]),
		}
		for key in places:
			var lit: bool = live and Input.is_key_pressed(keycode(key))
			_big_key(ci, Rect2(places[key], Vector2(cap, cap)), key, lit, tried.has(key))
		if not with_actions:
			continue
		# Actions under the block, in reading order: up, left, down, right.
		var ty: float = y0 + cap * 2.0 + gap + 20.0
		for key in [String(v[1]), String(hz[0]), String(v[0]), String(hz[1])]:
			var held: bool = live and Input.is_key_pressed(keycode(key))
			var kw: float = UI.draw_keycap(ci, Vector2(x0, ty), key, UI.SIZE_KEY, held)
			var colour: Color = UI.ACCENT_HI if held else (UI.TEXT if tried.has(key) else UI.TEXT_DIM)
			UI.draw_text(ci, Vector2(x0 + maxf(kw, 28.0) + 12.0, ty + 14.0 + float(text_size) * 0.36),
					actions[key], text_size, colour, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false,
					UI.font_semibold())
			if tried.has(key):
				UI.draw_check(ci, Vector2(x0 + block - 8.0, ty + 14.0), 14.0, UI.GOOD)
			ty += row_h
	if not with_actions:
		return Vector2(block * 2.0 + between, 30.0 + cap * 2.0 + gap)
	return Vector2(block * 2.0 + between, 30.0 + cap * 2.0 + gap + 20.0 + row_h * 4.0)


static func _big_key(ci: CanvasItem, rect: Rect2, key: String, lit: bool, done: bool = false) -> void:
	var r := UI.R_SM
	ci.draw_colored_polygon(UI.rounded_rect(Rect2(rect.position + Vector2(0, 4), rect.size), r),
			Color(0, 0, 0, 0.45))
	ci.draw_colored_polygon(UI.rounded_rect(rect, r), UI.ACCENT_DEEP if lit else UI.SURFACE_2)
	var edge: PackedVector2Array = UI.rounded_rect(rect, r)
	edge.append(edge[0])
	ci.draw_polyline(edge, UI.ACCENT if lit else UI.STROKE_HOVER,
			UI.STROKE_UI if lit else UI.HAIRLINE, true)
	var ink: Color = UI.ACCENT_HI if lit else UI.TEXT
	var dir = UI.ARROW_KEYS.get(key, -1)
	if int(dir) >= 0:
		UI.draw_arrow_glyph(ci, rect.get_center(), int(dir), rect.size.y * 0.34, ink, 2.5)
	else:
		var text: String = UI.key_text(key)
		var f: Font = UI.font_label()
		var size: int = int(rect.size.y * 0.40)
		var tw: float = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		ci.draw_string(f, Vector2(roundf(rect.position.x + (rect.size.x - tw) * 0.5),
				roundf(rect.position.y + rect.size.y * 0.5 + size * 0.36)), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)
	if done:
		# A small tick badge in the corner: this key has been tried.
		var c := Vector2(rect.end.x - 2.0, rect.position.y + 2.0)
		ci.draw_circle(c, 10.0, UI.BASE)
		ci.draw_circle(c, 9.0, Color(UI.GOOD, 0.22))
		ci.draw_arc(c, 9.0, 0.0, TAU, 24, UI.GOOD, 1.5, true)
		UI.draw_check(ci, c, 9.0, UI.GOOD, 2.0)


# ------------------------------------------------------- setup: shared bits ---

## Numbered steps with circles: each entry is {title, detail, state} where
## state is "done", "current" or "todo". Returns the y below the last step.
static func draw_steps(ci: CanvasItem, origin: Vector2, width: float, steps: Array) -> float:
	var y: float = origin.y
	for i in steps.size():
		var s: Dictionary = steps[i]
		var state: String = String(s.get("state", "todo"))
		UI.draw_step_circle(ci, Vector2(origin.x + 16.0, y + 16.0), i + 1, state)
		var tx: float = origin.x + 52.0
		UI.draw_text(ci, Vector2(tx, y + 24.0), String(s["title"]), UI.SIZE_BODY + 1,
				UI.TEXT if state != "done" else UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, -1.0, false,
				UI.font_semibold())
		var ly: float = y + 52.0
		for line in UI.wrap_text(String(s.get("detail", "")), width - 52.0, UI.SIZE_BODY_S):
			UI.draw_text(ci, Vector2(tx, ly), line, UI.SIZE_BODY_S, UI.TEXT_DIM)
			ly += 25.0
		y = ly + 14.0
	return y


## The joypads Godot can see right now, as [{id, name}].
static func seen_joypads() -> Array:
	var out: Array = []
	for id in Input.get_connected_joypads():
		out.append({"id": int(id), "name": Input.get_joy_name(int(id))})
	return out


## The "still nothing?" panel shown after ten seconds without a transmitter:
## what to check, then every device this computer does see, each with a
## "Use this" button. Returns the buttons as [[Rect2, joypad id], ...].
static func draw_troubleshooting(ci: CanvasItem, rect: Rect2, pads: Array,
								 hover_id: int = -1) -> Array:
	var hits: Array = []
	UI.draw_panel(ci, rect, Color(UI.SURFACE_2, 0.8), UI.STROKE_STRONG, UI.R_MD)
	var pad: float = UI.S5
	var x: float = rect.position.x + pad
	var w: float = rect.size.x - pad * 2.0
	var y: float = rect.position.y + pad + 14.0
	UI.draw_warn_triangle(ci, Vector2(x + 9.0, y - 6.0), 18.0, UI.WARN)
	UI.draw_label(ci, Vector2(x + 28.0, y), "still nothing? check these", UI.WARN)
	y += 34.0
	var tips: Array = [
		"Is the radio switched on?",
		"Try another USB port, or a different cable. Many cables only charge.",
		"EdgeTX/OpenTX: when you plug in, pick USB Joystick (HID). If it didn't ask, go to SYS, then USB, and set the mode to Ask or Joystick.",
		"Other radios: look for Simulator, Trainer or USB game controller mode in the radio's menu.",
	]
	for tip in tips:
		ci.draw_circle(Vector2(x + 4.0, y - 6.0), 2.5, UI.TEXT_DIM)
		for line in UI.wrap_text(String(tip), w - 20.0, UI.SIZE_BODY_S):
			UI.draw_text(ci, Vector2(x + 18.0, y), line, UI.SIZE_BODY_S, UI.TEXT)
			y += 24.0
		y += 8.0
	y += 6.0
	UI.draw_rule(ci, Vector2(x, y - 8.0), w, UI.STROKE)
	y += 18.0
	UI.draw_label(ci, Vector2(x, y), "devices this computer sees", UI.TEXT_DIM)
	y += 14.0
	if pads.is_empty():
		UI.draw_text(ci, Vector2(x, y + 24.0), "None yet. Nothing is plugged in that works as a controller.",
				UI.SIZE_BODY_S, UI.TEXT_DIM)
		return hits
	for p in pads:
		if y + 48.0 > rect.end.y - 8.0:
			break
		var row := Rect2(x, y + 6.0, w, 44.0)
		var name: String = String(p["name"])
		if name.length() > 34:
			name = name.substr(0, 33) + "…"
		UI.draw_text(ci, Vector2(x, row.get_center().y + 7.0), name, UI.SIZE_BODY, UI.TEXT,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold())
		var b := Rect2(row.end.x - 150.0, row.position.y, 150.0, 40.0)
		UI.draw_button_ex(ci, b, "Use this", UI.SECONDARY,
				{"hover": int(p["id"]) == hover_id, "size": 20})
		hits.append([b, int(p["id"])])
		y += 50.0
	return hits


## "Which thumb is your throttle on?" with two segments, Mode 2 first. The
## answer only changes pictures and hints: the radio itself decides the
## flying. Returns the segment rects, index 0 = Mode 2, 1 = Mode 1.
static func draw_thumb_question(ci: CanvasItem, origin: Vector2, width: float, question: String,
								mode: int, hover: int = -1, focus: bool = false) -> Array:
	UI.draw_text(ci, Vector2(origin.x, origin.y + 22.0), question, UI.SIZE_BODY + 1, UI.TEXT,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, false, UI.font_semibold())
	var seg := Rect2(origin.x, origin.y + 40.0, minf(width, 520.0), 52.0)
	var rects: Array = UI.draw_segmented(ci, seg, ["Left thumb: Mode 2", "Right thumb: Mode 1"],
			0 if mode != 1 else 1, hover, focus)
	UI.draw_text(ci, Vector2(origin.x, seg.end.y + 30.0),
			"Changes only the pictures and hints. Your radio decides the flying.",
			UI.SIZE_BODY_S, UI.TEXT_DIM)
	return rects
