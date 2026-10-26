# OpenRC Simulator - the interface design system.
#
# One place for every colour, size and spacing value in the UI, plus the drawing
# primitives the custom widgets are built from. Nothing else in the interface
# hard-codes a colour or a pixel size.
#
# The look is aimed at where instrumentation UI has settled: a near-black,
# low-chroma ground; translucent panels with a one-pixel light stroke rather
# than a heavy border; a single cool accent carrying the "live" information; and
# amber/red reserved strictly for states the pilot has to act on. Type does the
# hierarchy - size and colour, not boxes and rules.
#
# The one thing that is NOT generic here is the transmitter: two stick boxes,
# drawn the size and shape of the gimbals on the radio in the pilot's hands.
# That is the piece of the HUD that says this is an RC simulator and not a
# generic flight game, so it gets the prominence.
class_name UITheme
extends RefCounted

# ----------------------------------------------------------------- palette --
#
# "Flightline Glass": graphite glass, one brand-cyan live colour, white
# numerals sitting in the world rather than in boxes, and warm colours only
# when the pilot has to act. The brand mark's three colours anchor it:
# #4DD6E6 cyan, #E8EFFA white, #0B0E13 ground.

const BASE          := Color("0b0e13")                     # near-black ground
## Solid cards and modals.
const SURFACE       := Color(0.075, 0.098, 0.125, 0.96)
## Inset rows, selected card fill, advice boxes.
const SURFACE_2     := Color("1a222c")
## Translucent sheet over the frosted world.
const GLASS         := Color(0.043, 0.055, 0.075, 0.55)
## One-pixel top inner edge on glass and solid cards: what reads as a surface.
const GLASS_SHEEN   := Color(1.0, 1.0, 1.0, 0.07)
## The ink for HUD gradients and the outline around text drawn over the world.
const SCRIM         := Color("05080c")
# Kept as aliases: older screens still name these.
const PANEL         := Color(0.078, 0.098, 0.125, 0.78)
const PANEL_SOLID   := SURFACE
const STROKE        := Color(1.0, 1.0, 1.0, 0.08)          # 1 px hairline
const STROKE_STRONG := Color(1.0, 1.0, 1.0, 0.16)
const STROKE_HOVER  := Color(1.0, 1.0, 1.0, 0.28)

const TEXT          := Color("e8effa")
const TEXT_DIM      := Color("9da9bb")
## Tertiary text on SOLID surfaces only. Never over the 3D world: it has no
## contrast against grass or a pale sky (that was the "garbled label" bug).
const TEXT_FAINT    := Color("76839a")
## Every caps label drawn over the 3D world.
const HUD_LABEL     := Color(0.788, 0.827, 0.878, 0.92)
const DISABLED      := Color(1.0, 1.0, 1.0, 0.30)

## The live-data accent. Live data, focus and the primary action - nothing else.
const ACCENT        := Color("4dd6e6")
const ACCENT_HI     := Color("8ce8f2")
const ACCENT_DEEP   := Color("0f3a42")
## Text on a solid accent fill.
const ACCENT_INK    := Color("04161a")
const ACCENT_DIM    := Color(0.30, 0.84, 0.90, 0.28)

## Reserved for states that need action. Never decorative.
const WARN          := Color("f5ad2e")
const WARN_BG       := Color(0.165, 0.110, 0.020, 0.86)
const DANGER        := Color("ff4d5a")
const DANGER_BG     := Color(0.180, 0.039, 0.055, 0.88)
const GOOD          := Color("59d985")

# -------------------------------------------------------------------- type --
#
# Letter-spacing is for ALL-CAPS only, about 0.12 em in whole pixels. Nothing
# below 16 px ships: at 1280x720 the canvas scale is 0.667, and 16 is the
# smallest size that still lands on 10.7 physical pixels.

const SIZE_MICRO  := 16
const SIZE_LABEL  := 18
const SIZE_BODY   := 21
const SIZE_VALUE  := 26
const SIZE_LARGE  := 38
const SIZE_HERO   := 58
## The stage aircraft name: the biggest thing on any screen.
const SIZE_DISPLAY := 72
## Card titles on the main menu (an aircraft, a place, a weather state).
const SIZE_TITLE := 36
## Section headings on the main menu.
const SIZE_SECTION := 22

const SIZE_H1      := 52     # screen titles
const SIZE_H2      := 34     # card titles, the crash title
const SIZE_BUTTON  := 24
const SIZE_NUM_XL  := 64     # HUD speed and height
const SIZE_NUM_M   := 30     # HUD throttle, vario, brief values
const SIZE_BODY_S  := 18     # secondary body, HUD secondary lines
const SIZE_CAPS    := 16     # overlines and labels
const SIZE_CAPS_L  := 20     # chips, settings group heads
const SIZE_BANNER  := 28
const SIZE_KEY     := 16
const TRACK_CAPS   := 2

# ----------------------------------------------------------------- spacing --

const S1 := 4
const S2 := 8
const S3 := 12
const S4 := 16
const S5 := 24
const S6 := 32
const S7 := 48
const S8 := 64

## Safe margin for everything the HUD draws.
const HUD_M := 40.0

const R_SM := 6.0
const R_MD := 10.0
const R_LG := 14.0
const RADIUS := R_MD
const HAIRLINE := 1.0
const STROKE_UI := 2.0

# ------------------------------------------------------------------ motion --

const APPEAR_S := 0.22
const DISMISS_S := 0.14


## The one appear curve: ease-out cubic.
static func ease_out(t: float) -> float:
	var c: float = clampf(t, 0.0, 1.0)
	return 1.0 - pow(1.0 - c, 3.0)


static var _fonts: Dictionary = {}

## Rajdhani (SIL OFL, bundled - see assets/fonts/OFL-Rajdhani.txt).
##
## Fira Sans was here, and Fira Sans is a fine typeface for a document. That is
## the problem: it made a flight simulator look like documentation. Rajdhani is
## squared-off and tall-waisted - a technical, instrument face - which is what
## a cockpit reads like, and its narrow figures let the HUD carry big numbers
## without eating the view.
##
## Medium rather than Regular as the base weight. Regular is a hairline at HUD
## sizes over a bright sky, and every reading here has to survive being drawn
## over sunlit grass.
static func font() -> Font:
	return _font("res://assets/fonts/Rajdhani-Medium.ttf")


static func font_bold() -> Font:
	return _font("res://assets/fonts/Rajdhani-Bold.ttf")


## HUD numerals and small body: SemiBold holds up over sunlit grass where
## Medium thins out.
static func font_semibold() -> Font:
	return _font("res://assets/fonts/Rajdhani-SemiBold.ttf")


## Caps labels, buttons and keycaps. Saira Condensed BOLD: the Black weight
## closes the counters of A, R, O and G at label sizes, which together with a
## tracked, shadowed, per-glyph draw is what made the small labels look doubled.
static func font_label() -> Font:
	return _font("res://assets/fonts/SairaCondensed-Bold.ttf")


static var _tracked: Dictionary = {}

## A cached FontVariation carrying the letter-spacing, so a tracked label is ONE
## draw_string call: kerning kept, one subpixel phase, one draw call.
static func tracked(base: Font, spacing: int) -> Font:
	if spacing == 0:
		return base
	var key := "%d|%d" % [base.get_instance_id(), spacing]
	if not _tracked.has(key):
		var v := FontVariation.new()
		v.base_font = base
		v.spacing_glyph = spacing
		_tracked[key] = v
	return _tracked[key]


## Saira Condensed Black: the wordmark, the headings, the step tabs, and every
## letterspaced small-caps label. Condensed and very heavy, so a heading reads
## as a title from across the room rather than as one more line of text.
static func font_condensed() -> Font:
	return _font("res://assets/fonts/SairaCondensed-Black.ttf")


static func font_condensed_bold() -> Font:
	return _font("res://assets/fonts/SairaCondensed-Bold.ttf")


## The display face: big, heavy, condensed. Titles and the aircraft names.
static func font_display() -> Font:
	return _font("res://assets/fonts/SairaCondensed-Bold.ttf")


static func _font(path: String) -> Font:
	if _fonts.has(path):
		return _fonts[path]
	var f: Font = null
	if ResourceLoader.exists(path):
		f = load(path) as Font
	if f == null:
		f = ThemeDB.fallback_font
	_fonts[path] = f
	return f


# ------------------------------------------------------------------ panels --

## Points of a rounded rectangle, walking the outline clockwise.
static func rounded_rect(rect: Rect2, radius: float,
						 segments: int = 5) -> PackedVector2Array:
	var r: float = minf(radius, minf(rect.size.x, rect.size.y) * 0.5)
	var points := PackedVector2Array()
	var corners := [
		[Vector2(rect.position.x + r, rect.position.y + r), PI, PI * 1.5],
		[Vector2(rect.end.x - r, rect.position.y + r), PI * 1.5, TAU],
		[Vector2(rect.end.x - r, rect.end.y - r), 0.0, PI * 0.5],
		[Vector2(rect.position.x + r, rect.end.y - r), PI * 0.5, PI],
	]
	for corner in corners:
		for i in segments + 1:
			var angle: float = lerpf(corner[1], corner[2], float(i) / float(segments))
			points.append(corner[0] + Vector2(cos(angle), sin(angle)) * r)
	return points


## Translucent card with a hairline edge. The edge is what makes a panel read as
## a surface rather than as a hole punched in the image.
##
## Drawn as ONE polygon. Composing it from a rectangle plus corner circles - the
## obvious way, since draw_rect has no radius - overlaps the fills, and with a
## translucent panel every overlap darkens: the corners come out as blobs.
static func draw_panel(ci: CanvasItem, rect: Rect2, fill: Color = PANEL,
					   stroke: Color = STROKE, radius: float = RADIUS) -> void:
	var points: PackedVector2Array = rounded_rect(rect, radius)
	ci.draw_colored_polygon(points, fill)
	var outline: PackedVector2Array = points.duplicate()
	outline.append(points[0])
	ci.draw_polyline(outline, stroke, HAIRLINE, true)


## A thin accent rule, used to mark the active row or the top of a group.
static func draw_rule(ci: CanvasItem, from: Vector2, length: float,
					  colour: Color = STROKE, thickness: float = HAIRLINE) -> void:
	ci.draw_line(from, from + Vector2(length, 0), colour, thickness)


# ------------------------------------------------------------------- type ---

## Outline drawn under text that sits over the 3D world: a 2 px dark halo.
## An offset drop shadow on half a pixel smeared into a second, darker copy of
## every small letter; an outline frames the glyph instead of doubling it.
static func outline_size(size: int) -> int:
	return 6 if size >= 48 else 4


static func outline_colour(alpha: float = 1.0) -> Color:
	return Color(SCRIM.r, SCRIM.g, SCRIM.b, 0.70 * alpha)


static func draw_text(ci: CanvasItem, position: Vector2, text: String,
					  size: int = SIZE_BODY, colour: Color = TEXT,
					  align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT,
					  width: float = -1.0, over_world: bool = false,
					  f: Font = null) -> void:
	var face: Font = f if f != null else font()
	var p: Vector2 = position.round()
	if over_world:
		ci.draw_string_outline(face, p, text, align, width, size, outline_size(size),
				outline_colour(colour.a))
	ci.draw_string(face, p, text, align, width, size, colour)


## Letterspaced caps, for overlines and labels. Saira Condensed Bold, tracking
## carried by a FontVariation, position on whole pixels. `over_world` adds the
## halo for anything drawn on the 3D view.
static func draw_label(ci: CanvasItem, position: Vector2, text: String,
					   colour: Color = TEXT_DIM, spacing: float = TRACK_CAPS,
					   size: int = SIZE_CAPS, over_world: bool = false,
					   align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT,
					   width: float = -1.0) -> void:
	var f: Font = tracked(font_label(), int(round(spacing)))
	var p: Vector2 = position.round()
	var s: String = text.to_upper()
	if over_world:
		ci.draw_string_outline(f, p, s, align, width, size, outline_size(size),
				outline_colour(colour.a))
	ci.draw_string(f, p, s, align, width, size, colour)


## Wraps `text` to fit `width` pixels, measuring the font rather than counting
## characters.
##
## Every caller used to divide the box width by a hand-tuned "average glyph
## width" - 6.6 here, 7.4 there - which was wrong for the old face and wronger
## for a narrower one. Measuring costs nothing at these lengths and cannot go
## stale when the type changes.
static func wrap_text(text: String, width: float, size: int = SIZE_LABEL) -> PackedStringArray:
	var lines := PackedStringArray()
	var line := ""
	for word in text.split(" ", false):
		var candidate: String = word if line.is_empty() else line + " " + word
		if not line.is_empty() and text_width(candidate, size) > width:
			lines.append(line)
			line = word
		else:
			line = candidate
	if not line.is_empty():
		lines.append(line)
	return lines


static func text_width(text: String, size: int) -> float:
	return font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## Width of a string once draw_label's letterspacing is applied.
static func label_width(text: String, spacing: float = TRACK_CAPS,
						size: int = SIZE_CAPS) -> float:
	var sp: int = int(round(spacing))
	return maxf(tracked(font_label(), sp).get_string_size(text.to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, size).x - sp, 0.0)


## Fixed-cell numerals, so "9.9" and "10.0" do not make a reading jitter: each
## character is centred in a cell the width of "0"; "." and ":" take 0.45 cell,
## signs 0.7. `anchor` is the baseline at the right edge (align_right) or left.
## Returns the width drawn.
static func numeral_width(text: String, size: int, f: Font = null) -> float:
	var face: Font = f if f != null else font_semibold()
	var cell: float = face.get_string_size("0", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var w: float = 0.0
	for ch in text:
		w += cell * _cell_scale(ch)
	return w


static func _cell_scale(ch: String) -> float:
	if ch == "." or ch == ":" or ch == ",":
		return 0.45
	if ch == "-" or ch == "+" or ch == "\u2212":
		return 0.7
	if ch == " ":
		return 0.5
	if ch == "%":
		return 1.5
	return 1.0


static func draw_numeral(ci: CanvasItem, anchor: Vector2, text: String,
						 size: int = SIZE_NUM_XL, colour: Color = TEXT,
						 align_right: bool = true, over_world: bool = true,
						 f: Font = null) -> float:
	var face: Font = f if f != null else font_semibold()
	var cell: float = face.get_string_size("0", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var total: float = numeral_width(text, size, face)
	var x: float = anchor.x - total if align_right else anchor.x
	var y: float = roundf(anchor.y)
	var passes: Array = [true, false] if over_world else [false]
	for outline in passes:
		var cx: float = x
		for ch in text:
			var cw: float = cell * _cell_scale(ch)
			var gw: float = face.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
			var p := Vector2(roundf(cx + (cw - gw) * 0.5), y)
			if outline:
				ci.draw_string_outline(face, p, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
						outline_size(size), outline_colour(colour.a))
			else:
				ci.draw_string(face, p, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size, colour)
			cx += cw
	return total


# ----------------------------------------------------------------- widgets --

## Horizontal track with a filled portion. `fraction` is 0..1.
static func draw_track(ci: CanvasItem, rect: Rect2, fraction: float,
					   colour: Color = ACCENT, back: Color = Color(1, 1, 1, 0.07)) -> void:
	ci.draw_rect(rect, back, true)
	var filled: float = clampf(fraction, 0.0, 1.0) * rect.size.x
	if filled > 0.5:
		ci.draw_rect(Rect2(rect.position, Vector2(filled, rect.size.y)), colour, true)


## Centre-zero track, for a control surface or a stick axis. `value` is -1..1.
static func draw_bipolar_track(ci: CanvasItem, rect: Rect2, value: float,
							   colour: Color = ACCENT) -> void:
	ci.draw_rect(rect, Color(1, 1, 1, 0.07), true)
	var centre: float = rect.position.x + rect.size.x * 0.5
	var extent: float = clampf(value, -1.0, 1.0) * rect.size.x * 0.5
	if absf(extent) > 0.5:
		ci.draw_rect(Rect2(Vector2(minf(centre, centre + extent), rect.position.y),
						   Vector2(absf(extent), rect.size.y)), colour, true)
	# The neutral tick has to stay visible through the fill: it is the reference.
	ci.draw_line(Vector2(centre, rect.position.y - 1.0),
				 Vector2(centre, rect.position.y + rect.size.y + 1.0),
				 Color(1, 1, 1, 0.35), 1.0)


## Arc gauge. Angles in degrees, clockwise from straight down.
static func draw_arc_gauge(ci: CanvasItem, centre: Vector2, radius: float,
						   sweep_degrees: float, fraction: float,
						   colour: Color = ACCENT, thickness: float = 3.0) -> void:
	var start: float = deg_to_rad(90.0 + (360.0 - sweep_degrees) * 0.5)
	var end: float = start + deg_to_rad(sweep_degrees)
	ci.draw_arc(centre, radius, start, end, 48, Color(1, 1, 1, 0.09), thickness, true)
	var filled: float = clampf(fraction, 0.0, 1.0)
	if filled > 0.001:
		ci.draw_arc(centre, radius, start, start + (end - start) * filled,
					48, colour, thickness, true)


## A transmitter gimbal: a square gate with the stick position on it.
##
## This is the HUD element that makes the simulator legible as an RC simulator.
## A pilot glances at it the way they glance at their own thumbs, so it is drawn
## at the proportions of a real gimbal gate rather than as a pair of bars.
static func draw_stick_gate(ci: CanvasItem, rect: Rect2, x: float, y: float,
							colour: Color = ACCENT) -> void:
	ci.draw_rect(rect, Color(1, 1, 1, 0.04), true)
	ci.draw_rect(rect, STROKE_STRONG, false, HAIRLINE)

	var centre: Vector2 = rect.position + rect.size * 0.5
	# Cross hairs, so the neutral point is readable without the stick on it.
	ci.draw_line(Vector2(rect.position.x + 3, centre.y),
				 Vector2(rect.end.x - 3, centre.y), Color(1, 1, 1, 0.10), 1.0)
	ci.draw_line(Vector2(centre.x, rect.position.y + 3),
				 Vector2(centre.x, rect.end.y - 3), Color(1, 1, 1, 0.10), 1.0)

	var knob: Vector2 = centre + Vector2(clampf(x, -1.0, 1.0), -clampf(y, -1.0, 1.0)) \
		* (rect.size * 0.5 - Vector2(5, 5))
	# A trail from centre to the stick reads as displacement at a glance.
	ci.draw_line(centre, knob, Color(colour.r, colour.g, colour.b, 0.35), 1.5)
	ci.draw_circle(knob, 5.0, Color(colour.r, colour.g, colour.b, 0.25))
	ci.draw_circle(knob, 3.0, colour)


## Compact attitude reference: a horizon that rolls and pitches, clipped to a
## circle. Enough to read attitude when the model is a speck in the sky.
##
## The ground half is built as the chord plus the arc below it, with the chord
## endpoints solved exactly. Drawing it as a fan and letting it overhang - the
## quick way - leaves square corners poking out of the disc, because a polygon
## is not clipped to anything.
static func draw_attitude(ci: CanvasItem, centre: Vector2, radius: float,
						  roll_degrees: float, pitch_degrees: float) -> void:
	const SKY := Color(0.13, 0.24, 0.36, 0.92)
	const GROUND := Color(0.26, 0.19, 0.12, 0.92)

	ci.draw_circle(centre, radius, SKY)

	var roll: float = deg_to_rad(roll_degrees)
	# Positive pitch is nose up, and on an attitude indicator that moves the
	# horizon DOWN the display. Godot's 2D Y axis already points down, so this
	# "up" vector is screen-down and the sign works out directly.
	var up := Vector2(-sin(roll), cos(roll))
	var along := Vector2(cos(roll), sin(roll))
	var offset: float = clampf(pitch_degrees / 45.0, -1.4, 1.4) * radius
	var horizon: Vector2 = centre + up * offset

	if offset >= radius:
		ci.draw_circle(centre, radius, GROUND)          # nose so high it is all ground
	elif offset > -radius:
		var half_chord: float = sqrt(maxf(radius * radius - offset * offset, 0.0))
		var a: Vector2 = horizon + along * half_chord
		var b: Vector2 = horizon - along * half_chord

		# Sweep from a to b the way round that passes through the extreme ground
		# point, so the arc is the ground side rather than the sky side.
		var start: float = (a - centre).angle()
		var finish: float = (b - centre).angle()
		var toward_ground: float = up.angle()
		var sweep: float = fposmod(finish - start, TAU)
		if fposmod(toward_ground - start, TAU) > sweep:
			sweep -= TAU

		var points := PackedVector2Array([a])
		var steps: int = 24
		for i in range(1, steps):
			var angle: float = start + sweep * float(i) / float(steps)
			points.append(centre + Vector2(cos(angle), sin(angle)) * radius)
		points.append(b)
		ci.draw_colored_polygon(points, GROUND)
		ci.draw_line(a, b, Color(1, 1, 1, 0.55), 1.5)

	# The aircraft reference is fixed: the world moves behind it, not the other
	# way round, which is the whole point of an attitude indicator.
	ci.draw_line(centre - Vector2(radius * 0.62, 0), centre - Vector2(radius * 0.22, 0),
				 ACCENT, 2.0)
	ci.draw_line(centre + Vector2(radius * 0.22, 0), centre + Vector2(radius * 0.62, 0),
				 ACCENT, 2.0)
	ci.draw_circle(centre, 2.0, ACCENT)
	ci.draw_arc(centre, radius, 0, TAU, 64, STROKE_STRONG, HAIRLINE, true)


# --------------------------------------------------------------- backdrop ---

## Frosted backdrop for a full-screen overlay: the scene behind, blurred and
## sunk towards the base colour. Keeping the field faintly visible behind the
## menu keeps the pilot oriented instead of cutting to a black slab.
static func frosted_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float blur = 1.6;
uniform float darken = 0.42;
uniform float desaturate = 0.35;
uniform vec3 base : source_color = vec3(0.043, 0.055, 0.075);

void fragment() {
	vec3 scene = textureLod(screen_tex, SCREEN_UV, blur).rgb;
	// Desaturate and darken just enough that text sits on it - the point of
	// the frost is that the field stays recognizable behind the panels, so
	// anything stronger than this reads as mud instead of as glass.
	float luma = dot(scene, vec3(0.2126, 0.7152, 0.0722));
	scene = mix(scene, vec3(luma), desaturate);
	COLOR = vec4(mix(scene, base, darken), 1.0);
}
"""
	return shader


static func make_frosted(darken: float = 0.72, blur: float = 3.2) -> ColorRect:
	var rect := ColorRect.new()
	var material := ShaderMaterial.new()
	material.shader = frosted_shader()
	material.set_shader_parameter("blur", blur)
	material.set_shader_parameter("darken", darken)
	material.set_shader_parameter("base", BASE)
	rect.material = material
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


# --------------------------------------------------------- game-style bits ---

## A rounded-corner thumbnail for the scene and weather previews on the main
## menu. TextureRect has no rounded clip of its own, and drawing a translucent
## panel over a rectangular photo leaves the corners showing through the fill.
##
## The corners are cut into the IMAGE rather than with a canvas_item shader.
## A shader would be marginally cheaper per frame, but it renders nothing at
## all on software rasterisers (llvmpipe cannot compile the GLSL), which makes
## the menu unverifiable and fragile in exactly the places it needs to degrade
## gracefully - and a UI thumbnail is cut once, not per frame.
static func make_thumb(texture: Texture2D, size: Vector2, radius: float = 10.0) -> TextureRect:
	var src: Image = texture.get_image()
	src.resize(maxi(int(size.x), 1), maxi(int(size.y), 1), Image.INTERPOLATE_BILINEAR)
	src.convert(Image.FORMAT_RGBA8)

	# Signed distance to the rounded rectangle, per pixel. Outside the corner
	# radius the alpha ramps down over two pixels so the edge stays clean.
	var w: int = src.get_width()
	var h: int = src.get_height()
	var half := Vector2(size.x * 0.5, size.y * 0.5)
	for y in h:
		for x in w:
			var dx: float = absf(float(x) + 0.5 - half.x) - (half.x - radius)
			var dy: float = absf(float(y) + 0.5 - half.y) - (half.y - radius)
			var dist: float = Vector2(maxf(dx, 0.0), maxf(dy, 0.0)).length() - radius
			var alpha: float = clampf(0.5 - dist, 0.0, 1.0)
			if alpha < 1.0:
				var c: Color = src.get_pixel(x, y)
				src.set_pixel(x, y, Color(c.r, c.g, c.b, c.a * alpha))

	var rect := TextureRect.new()
	rect.texture = ImageTexture.create_from_image(src)
	rect.position = Vector2.ZERO
	rect.size = size
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


## Soft glow behind a panel: a few expanding rounded rectangles at falling
## alpha. The main menu's Fly button and selected cards sit on this, which is
## what makes them read as lit rather than as flat fill.
static func draw_glow(ci: CanvasItem, rect: Rect2, colour: Color,
					  radius: float = RADIUS, rings: int = 3) -> void:
	for ring in rings:
		var t: float = float(ring) / float(rings)
		var pad: float = 4.0 + t * 10.0
		var alpha: float = 0.16 * (1.0 - t) * (1.0 - t)
		ci.draw_colored_polygon(rounded_rect(rect.grow(pad), radius + pad * 0.4),
								Color(colour.r, colour.g, colour.b, alpha))


## Text with a soft dark shadow behind it, so a label stays readable over a
## bright thumbnail. Drawn as one extra pass a couple of pixels down and right.
## Headings, in the display face. A title set in the body font is a sentence
## that happens to be large; set in the condensed heavy face it reads as a
## title from across the room, which is the whole job.
static func draw_display(ci: CanvasItem, position: Vector2, text: String,
						 size: int = SIZE_TITLE, colour: Color = TEXT,
						 align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT,
						 width: float = -1.0, over_world: bool = false) -> void:
	var f: Font = font_condensed_bold()
	var p: Vector2 = position.round()
	if over_world:
		ci.draw_string_outline(f, p, text, align, width, size, outline_size(size),
				outline_colour(colour.a))
	ci.draw_string(f, p, text, align, width, size, colour)


## Text over a bright picture (a thumbnail): the halo, not an offset shadow.
static func draw_text_shadow(ci: CanvasItem, position: Vector2, text: String,
							 size: int = SIZE_BODY, colour: Color = TEXT,
							 _shadow: Color = Color(0, 0, 0, 0.55),
							 align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT,
							 width: float = -1.0) -> void:
	draw_text(ci, position, text, size, colour, align, width, true)


# ------------------------------------------------------------ keys & buttons ---

## How a key is written on a keycap. Arrow keys are drawn as vector arrows
## (neither face has arrow glyphs that hold up at keycap size); everything else
## is the key's own name, so the cap says exactly what is printed on the key.
const KEY_GLYPHS: Dictionary = {
	"ESCAPE": "Esc", "ESC": "Esc", "ENTER": "Enter", "SPACE": "Space",
	"TAB": "Tab", "SHIFT": "Shift", "BACKSPACE": "Bksp", "RMB": "Right mouse",
	"UP": "↑", "DOWN": "↓", "LEFT": "←", "RIGHT": "→",
}
const ARROW_KEYS: Dictionary = {"UP": 0, "RIGHT": 1, "DOWN": 2, "LEFT": 3,
		"↑": 0, "→": 1, "↓": 2, "←": 3}
const KEYCAP_H: float = 30.0


static func key_text(key: String) -> String:
	return KEY_GLYPHS.get(key.to_upper(), key)


static func _keycap_h(size: int) -> float:
	return roundf(KEYCAP_H * size / SIZE_LABEL)


## Width of a keycap for `key`, at the default size.
static func keycap_width(key: String, size: int = SIZE_LABEL) -> float:
	var h: float = _keycap_h(size)
	if ARROW_KEYS.has(key.to_upper()) or ARROW_KEYS.has(key):
		return h
	var text: String = key_text(key)
	return roundf(maxf(h, font_label().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			size).x + 16.0))


## A keycap: a small raised key with its label, so a hint reads as "press this"
## rather than as one more word in a sentence. `lit` is a key being held now.
## Returns the width drawn. `position` is the top-left corner.
static func draw_keycap(ci: CanvasItem, position: Vector2, key: String,
						size: int = SIZE_LABEL, lit: bool = false,
						alpha: float = 1.0) -> float:
	var h: float = _keycap_h(size)
	var w: float = keycap_width(key, size)
	var rect := Rect2(position.round(), Vector2(w, h))
	var face: Color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.30 * alpha) if lit \
			else Color(0.10, 0.13, 0.17, 0.92 * alpha)
	# The lip: a darker strip under the face, which is what makes it a key.
	ci.draw_colored_polygon(rounded_rect(Rect2(rect.position + Vector2(0, 2), rect.size), R_SM),
			Color(0, 0, 0, 0.40 * alpha))
	ci.draw_colored_polygon(rounded_rect(rect, R_SM), face)
	var edge: PackedVector2Array = rounded_rect(rect, R_SM)
	edge.append(edge[0])
	ci.draw_polyline(edge, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.9 * alpha) if lit
			else Color(1, 1, 1, 0.26 * alpha), HAIRLINE, true)
	var ink := Color(TEXT.r, TEXT.g, TEXT.b, alpha)
	var dir = ARROW_KEYS.get(key.to_upper(), ARROW_KEYS.get(key, -1))
	if int(dir) >= 0:
		draw_arrow_glyph(ci, rect.get_center(), int(dir), h * 0.42, ink)
		return w
	var text: String = key_text(key)
	var f: Font = font_label()
	var tw: float = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	ci.draw_string(f, Vector2(roundf(rect.position.x + (w - tw) * 0.5),
			roundf(rect.position.y + h * 0.5 + size * 0.36)), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)
	return w


## Keys followed by what they do: "[W]  Open the throttle". `keys` may hold
## several caps ("A", "D") - drawn side by side. `position` is the left end of
## the row's vertical centre line. Returns the total width.
static func draw_key_hint(ci: CanvasItem, position: Vector2, keys: Array,
						  text: String, size: int = SIZE_LABEL,
						  colour: Color = TEXT, alpha: float = 1.0,
						  over_world: bool = false) -> float:
	var h: float = _keycap_h(size)
	var x: float = position.x
	for i in keys.size():
		x += draw_keycap(ci, Vector2(x, position.y - h * 0.5), String(keys[i]),
						 size, false, alpha)
		x += 4.0
	if not text.is_empty():
		x += 6.0
		var c := Color(colour.r, colour.g, colour.b, colour.a * alpha)
		draw_text(ci, Vector2(x, position.y + size * 0.36), text, size + 2, c,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, over_world, font_semibold())
		x += font_semibold().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size + 2).x
	return x - position.x


static func key_hint_width(keys: Array, text: String, size: int = SIZE_LABEL) -> float:
	var w: float = 0.0
	for k in keys:
		w += keycap_width(String(k), size) + 4.0
	if not text.is_empty():
		w += 6.0 + font_semibold().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size + 2).x
	return w


# ----------------------------------------------------------------- buttons --
#
# Three styles, one rule: exactly one PRIMARY per screen.
#   PRIMARY    solid accent, dark ink         - Fly, Next, Continue, Resume
#   SECONDARY  raised surface, hairline edge  - Back, Watch replay, list items
#   TERTIARY   text only                      - Quit, Close, header actions
# Focus (keyboard or pad) is a ring drawn IN ADDITION to hover, so a resting
# mouse never hides where the keyboard is.

enum { PRIMARY, SECONDARY, TERTIARY }


## `opts`: focus, hover, pressed, enabled (bool); key (String, keycap shown);
## align ("center" | "left"); size (int label size); sub (String, a dim second
## line under a left-aligned label).
static func draw_button_ex(ci: CanvasItem, rect: Rect2, label: String,
						   style: int = SECONDARY, opts: Dictionary = {}) -> void:
	var focus: bool = bool(opts.get("focus", false))
	var hover: bool = bool(opts.get("hover", false))
	var pressed: bool = bool(opts.get("pressed", false))
	var enabled: bool = bool(opts.get("enabled", true))
	var key: String = String(opts.get("key", ""))
	var left: bool = String(opts.get("align", "center")) == "left"
	var size: int = int(opts.get("size", SIZE_BUTTON))
	var sub: String = String(opts.get("sub", ""))
	var r: Rect2 = rect
	if pressed and enabled:
		r.position.y += 2.0

	var fill := Color(0, 0, 0, 0)
	var stroke := Color(0, 0, 0, 0)
	var ink: Color = TEXT
	match style:
		PRIMARY:
			fill = ACCENT_HI if hover else ACCENT
			ink = ACCENT_INK
		SECONDARY:
			fill = SURFACE_2.lightened(0.04) if hover else SURFACE_2
			stroke = STROKE_HOVER if hover else STROKE_STRONG
		TERTIARY:
			fill = Color(1, 1, 1, 0.05) if hover else Color(0, 0, 0, 0)
			ink = TEXT if (hover or focus) else TEXT_DIM
	if not enabled:
		fill = Color(1, 1, 1, 0.04) if style != TERTIARY else Color(0, 0, 0, 0)
		stroke = STROKE if style != TERTIARY else Color(0, 0, 0, 0)
		ink = DISABLED
	if pressed and enabled:
		fill = fill.darkened(0.08)

	if focus and enabled:
		if style == PRIMARY:
			draw_glow(ci, r, ACCENT, R_MD, 2)
		draw_focus_ring(ci, r, R_MD)
	if fill.a > 0.0:
		ci.draw_colored_polygon(rounded_rect(r, R_MD), fill)
	if stroke.a > 0.0:
		var edge: PackedVector2Array = rounded_rect(r, R_MD)
		edge.append(edge[0])
		ci.draw_polyline(edge, stroke, HAIRLINE, true)

	var f: Font = font_label()
	var lw: float = f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var kw: float = 0.0 if key.is_empty() else keycap_width(key, SIZE_KEY)
	var cy: float = r.position.y + r.size.y * 0.5
	var baseline: float = cy + size * 0.36
	if not sub.is_empty():
		baseline = cy + size * 0.36 - 10.0
	var x: float
	if left:
		x = r.position.x + 20.0
	else:
		x = r.position.x + (r.size.x - lw - (kw + 12.0 if kw > 0.0 else 0.0)) * 0.5
	ci.draw_string(f, Vector2(roundf(x), roundf(baseline)), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)
	if not sub.is_empty():
		ci.draw_string(font(), Vector2(roundf(x), roundf(baseline + 22.0)), sub,
				HORIZONTAL_ALIGNMENT_LEFT, -1, SIZE_BODY_S,
				Color(ink.r, ink.g, ink.b, 0.62) if style == PRIMARY else TEXT_DIM)
	if kw > 0.0:
		var kx: float = r.end.x - 16.0 - kw if left else x + lw + 12.0
		var a: float = 1.0 if enabled else 0.35
		if style == PRIMARY and enabled:
			_draw_ink_keycap(ci, Vector2(kx, cy - _keycap_h(SIZE_KEY) * 0.5), key)
		else:
			draw_keycap(ci, Vector2(kx, cy - _keycap_h(SIZE_KEY) * 0.5), key, SIZE_KEY, false, a)


## A keycap printed on a solid accent button: dark outline, dark legend.
static func _draw_ink_keycap(ci: CanvasItem, position: Vector2, key: String) -> void:
	var h: float = _keycap_h(SIZE_KEY)
	var w: float = keycap_width(key, SIZE_KEY)
	var rect := Rect2(position.round(), Vector2(w, h))
	ci.draw_colored_polygon(rounded_rect(rect, R_SM), Color(ACCENT_INK.r, ACCENT_INK.g, ACCENT_INK.b, 0.12))
	var edge: PackedVector2Array = rounded_rect(rect, R_SM)
	edge.append(edge[0])
	ci.draw_polyline(edge, Color(ACCENT_INK.r, ACCENT_INK.g, ACCENT_INK.b, 0.55), 1.5, true)
	var dir = ARROW_KEYS.get(key.to_upper(), -1)
	if int(dir) >= 0:
		draw_arrow_glyph(ci, rect.get_center(), int(dir), h * 0.42, ACCENT_INK)
		return
	var text: String = key_text(key)
	var tw: float = font_label().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, SIZE_KEY).x
	ci.draw_string(font_label(), Vector2(roundf(rect.position.x + (w - tw) * 0.5),
			roundf(rect.position.y + h * 0.5 + SIZE_KEY * 0.36)), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, SIZE_KEY, ACCENT_INK)


## The older signature, kept for the screens not yet moved to draw_button_ex.
static func draw_button(ci: CanvasItem, rect: Rect2, label: String,
						primary: bool = false, focus: bool = false,
						enabled: bool = true, key: String = "") -> void:
	draw_button_ex(ci, rect, label, PRIMARY if primary else SECONDARY,
			{"focus": focus, "enabled": enabled, "key": key})


## Keyboard / pad focus: a 2 px accent ring 3 px outside the rect.
static func draw_focus_ring(ci: CanvasItem, rect: Rect2, radius: float = R_MD,
							colour: Color = ACCENT) -> void:
	var ring: PackedVector2Array = rounded_rect(rect.grow(3.0), radius + 3.0)
	ring.append(ring[0])
	ci.draw_polyline(ring, colour, STROKE_UI, true)


# ------------------------------------------------------------------ shells --

## A modal sheet: soft three-ring shadow, solid surface, sheen on the top edge,
## hairline outline. Every modal (pause, setup, help, settings, wizard) uses it.
static func draw_modal(ci: CanvasItem, rect: Rect2, alpha: float = 1.0,
					   fill: Color = SURFACE) -> void:
	var grow := [6.0, 14.0, 26.0]
	var drop := [4.0, 8.0, 14.0]
	var shade := [0.28, 0.14, 0.06]
	for i in 3:
		var g: Rect2 = rect.grow(grow[i])
		g.position.y += drop[i]
		ci.draw_colored_polygon(rounded_rect(g, R_LG + grow[i]),
				Color(0, 0, 0, shade[i] * alpha))
	ci.draw_colored_polygon(rounded_rect(rect, R_LG), Color(fill.r, fill.g, fill.b, fill.a * alpha))
	ci.draw_line(Vector2(rect.position.x + R_LG, rect.position.y + 1.0),
			Vector2(rect.end.x - R_LG, rect.position.y + 1.0),
			Color(1, 1, 1, GLASS_SHEEN.a * alpha), 1.0)
	var edge: PackedVector2Array = rounded_rect(rect, R_LG)
	edge.append(edge[0])
	ci.draw_polyline(edge, Color(1, 1, 1, STROKE_STRONG.a * alpha), HAIRLINE, true)


## A step indicator: equal columns, a 2 px track each, the current one a 3 px
## accent bar, done steps a vector check. No pills, no glow. Returns the hit
## rects so the caller can make the steps clickable.
static func draw_stepper(ci: CanvasItem, rect: Rect2, names: Array, current: int,
						 hover: int = -1, done_upto: int = -1) -> Array:
	var rects: Array = []
	var n: int = maxi(names.size(), 1)
	var gap: float = 12.0
	var w: float = (rect.size.x - gap * float(n - 1)) / float(n)
	var done_limit: int = current if done_upto < 0 else done_upto
	for i in n:
		var x: float = rect.position.x + float(i) * (w + gap)
		var col := Rect2(x, rect.position.y, w, rect.size.y)
		rects.append(col)
		var track_y: float = rect.position.y + rect.size.y - 2.0
		var is_current: bool = i == current
		var is_done: bool = i < done_limit and not is_current
		if is_current:
			ci.draw_rect(Rect2(x, track_y - 1.0, w, 3.0), ACCENT)
		else:
			ci.draw_rect(Rect2(x, track_y, w, 2.0), GOOD.darkened(0.35) if is_done else STROKE_STRONG)
		var colour: Color = TEXT if is_current else (TEXT_DIM if is_done or i == hover else TEXT_FAINT)
		var lx: float = x
		var base_y: float = rect.position.y + rect.size.y - 14.0
		if is_done:
			draw_check(ci, Vector2(x + 7.0, base_y - 6.0), 14.0, GOOD)
			lx += 22.0
		draw_label(ci, Vector2(lx, base_y), "%02d  %s" % [i + 1, String(names[i])], colour,
				TRACK_CAPS, SIZE_LABEL)
	return rects


## A pill tag. kind: "info" (accent tint, no stroke), "state" (hollow dot, dim
## text, no fill - so it never reads as a button), "good", "warn", "danger".
## `position` is the left end of the vertical centre. Returns the width.
static func draw_tag(ci: CanvasItem, position: Vector2, text: String,
					 kind: String = "info", over_world: bool = false) -> float:
	var h: float = 26.0
	var tw: float = label_width(text, TRACK_CAPS, SIZE_CAPS)
	var colour: Color = ACCENT_HI
	match kind:
		"state": colour = TEXT_DIM
		"good": colour = GOOD
		"warn": colour = WARN
		"danger": colour = DANGER
	var dot: bool = kind != "info"
	var w: float = tw + (34.0 if dot else 24.0)
	var rect := Rect2(Vector2(position.x, position.y - h * 0.5).round(), Vector2(w, h))
	if kind == "info":
		ci.draw_colored_polygon(rounded_rect(rect, h * 0.5), Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.12))
	elif kind != "state":
		ci.draw_colored_polygon(rounded_rect(rect, h * 0.5), Color(colour.r, colour.g, colour.b, 0.12))
	var tx: float = rect.position.x + 12.0
	if dot:
		var c := Vector2(rect.position.x + 14.0, rect.position.y + h * 0.5)
		if kind == "state":
			ci.draw_arc(c, 4.0, 0.0, TAU, 16, TEXT_FAINT, 1.5, true)
		else:
			ci.draw_circle(c, 4.0, colour)
		tx += 12.0
	draw_label(ci, Vector2(tx, rect.position.y + h * 0.5 + 6.0), text, colour, TRACK_CAPS,
			SIZE_CAPS, over_world)
	return w


## A two-or-more-way segmented control (Keyboard | Transmitter). Returns the
## segment hit rects.
static func draw_segmented(ci: CanvasItem, rect: Rect2, names: Array, current: int,
						   hover: int = -1, focus: bool = false) -> Array:
	var rects: Array = []
	ci.draw_colored_polygon(rounded_rect(rect, R_MD), Color(0, 0, 0, 0.25))
	var edge: PackedVector2Array = rounded_rect(rect, R_MD)
	edge.append(edge[0])
	ci.draw_polyline(edge, STROKE_STRONG, HAIRLINE, true)
	var w: float = rect.size.x / float(maxi(names.size(), 1))
	for i in names.size():
		var seg := Rect2(rect.position.x + w * float(i), rect.position.y, w, rect.size.y)
		rects.append(seg)
		var inner: Rect2 = seg.grow(-3.0)
		if i == current:
			ci.draw_colored_polygon(rounded_rect(inner, R_MD - 3.0), ACCENT_DEEP)
			var e2: PackedVector2Array = rounded_rect(inner, R_MD - 3.0)
			e2.append(e2[0])
			ci.draw_polyline(e2, ACCENT, STROKE_UI, true)
		elif i == hover:
			ci.draw_colored_polygon(rounded_rect(inner, R_MD - 3.0), Color(1, 1, 1, 0.05))
		var colour: Color = TEXT if i == current else TEXT_DIM
		var f: Font = font_label()
		ci.draw_string(f, Vector2(roundf(seg.position.x), roundf(seg.get_center().y + 22.0 * 0.36)),
				String(names[i]), HORIZONTAL_ALIGNMENT_CENTER, seg.size.x, 22, colour)
	if focus:
		draw_focus_ring(ci, rect, R_MD)
	return rects


## Footer hint row: [keys] text, [keys] text ... starting at `position` (left
## end of the vertical centre). Each entry is [keys: Array, text: String].
## Returns the width.
static func draw_footer_hints(ci: CanvasItem, position: Vector2, entries: Array,
							  colour: Color = TEXT_DIM, size: int = SIZE_KEY,
							  over_world: bool = false) -> float:
	var x: float = position.x
	for i in entries.size():
		var e: Array = entries[i]
		x += draw_key_hint(ci, Vector2(x, position.y), e[0], String(e[1]), size, colour,
				1.0, over_world)
		x += 28.0
	return maxf(x - position.x - 28.0, 0.0)


static func footer_hints_width(entries: Array, size: int = SIZE_KEY) -> float:
	var w: float = 0.0
	for e in entries:
		w += key_hint_width(e[0], String(e[1]), size) + 28.0
	return maxf(w - 28.0, 0.0)


# ------------------------------------------------------------------- icons --
#
# Drawn as vectors, so no glyph-coverage question remains: Rajdhani has no
# check mark and no arrows, and Saira's arrows are hairlines at 16 px.

static func draw_check(ci: CanvasItem, centre: Vector2, size: float = 14.0,
					   colour: Color = GOOD, width: float = STROKE_UI) -> void:
	var s: float = size * 0.5
	ci.draw_polyline(PackedVector2Array([
		centre + Vector2(-s, 0.0), centre + Vector2(-s * 0.3, s * 0.7),
		centre + Vector2(s, -s * 0.75)]), colour, width, true)


## dir: 0 up, 1 right, 2 down, 3 left.
static func draw_chevron(ci: CanvasItem, centre: Vector2, dir: int, size: float = 16.0,
						 colour: Color = TEXT, width: float = STROKE_UI) -> void:
	var a: float = size * 0.32
	var b: float = size * 0.5
	var pts := PackedVector2Array([Vector2(-a, -b), Vector2(a, 0.0), Vector2(-a, b)])
	var ang: float = [-PI * 0.5, 0.0, PI * 0.5, PI][clampi(dir, 0, 3)]
	for i in pts.size():
		pts[i] = centre + pts[i].rotated(ang)
	ci.draw_polyline(pts, colour, width, true)


## An arrow with a shaft. dir: 0 up, 1 right, 2 down, 3 left.
static func draw_arrow_glyph(ci: CanvasItem, centre: Vector2, dir: int, size: float = 12.0,
							 colour: Color = TEXT, width: float = STROKE_UI) -> void:
	var ang: float = [-PI * 0.5, 0.0, PI * 0.5, PI][clampi(dir, 0, 3)]
	var h: float = size * 0.5
	var tip := Vector2(h, 0.0)
	var tail := Vector2(-h, 0.0)
	var wing: float = size * 0.38
	var p := func(v: Vector2) -> Vector2: return centre + v.rotated(ang)
	ci.draw_line(p.call(tail), p.call(tip), colour, width, true)
	ci.draw_polyline(PackedVector2Array([p.call(tip + Vector2(-wing, -wing)), p.call(tip),
			p.call(tip + Vector2(-wing, wing))]), colour, width, true)


## A filled triangle pointing along `direction`, length `length`, base `base`.
static func draw_pointer(ci: CanvasItem, tip: Vector2, direction: Vector2, length: float,
						 base: float, colour: Color, outline: Color = Color(0, 0, 0, 0)) -> void:
	var d: Vector2 = direction.normalized()
	var n := Vector2(-d.y, d.x)
	var back: Vector2 = tip - d * length
	var pts := PackedVector2Array([tip, back + n * base * 0.5, back - n * base * 0.5])
	if outline.a > 0.0:
		var o: PackedVector2Array = pts.duplicate()
		o.append(pts[0])
		ci.draw_polyline(o, outline, 4.0, true)
	ci.draw_colored_polygon(pts, colour)


## A warning triangle with an exclamation mark.
static func draw_warn_triangle(ci: CanvasItem, centre: Vector2, size: float = 20.0,
							   colour: Color = DANGER) -> void:
	var h: float = size * 0.87
	var pts := PackedVector2Array([centre + Vector2(0, -h * 0.55), centre + Vector2(size * 0.5, h * 0.45),
			centre + Vector2(-size * 0.5, h * 0.45), centre + Vector2(0, -h * 0.55)])
	ci.draw_polyline(pts, colour, STROKE_UI, true)
	ci.draw_line(centre + Vector2(0, -h * 0.18), centre + Vector2(0, h * 0.12), colour, STROKE_UI)
	ci.draw_circle(centre + Vector2(0, h * 0.28), 1.4, colour)


## Battery: rounded body, nub on the right, inner fill to `fraction`.
static func draw_battery(ci: CanvasItem, rect: Rect2, fraction: float, colour: Color,
						 outline: Color = HUD_LABEL) -> void:
	var r: Rect2 = Rect2(rect.position.round(), rect.size)
	var edge: PackedVector2Array = rounded_rect(r, 3.0)
	edge.append(edge[0])
	ci.draw_polyline(edge, Color(SCRIM.r, SCRIM.g, SCRIM.b, 0.6), 4.0, true)
	ci.draw_polyline(edge, outline, STROKE_UI, true)
	ci.draw_rect(Rect2(r.end.x + 1.0, r.position.y + r.size.y * 0.5 - 3.0, 3.0, 6.0), outline)
	var inner: Rect2 = r.grow(-3.0)
	inner.size.x *= clampf(fraction, 0.0, 1.0)
	if inner.size.x > 0.5:
		ci.draw_rect(inner, colour)


## A radio button: ring, and a dot when on.
static func draw_radio(ci: CanvasItem, centre: Vector2, on: bool, size: float = 22.0) -> void:
	ci.draw_arc(centre, size * 0.5 - 1.0, 0.0, TAU, 32, ACCENT if on else STROKE_HOVER, STROKE_UI, true)
	if on:
		ci.draw_circle(centre, size * 0.23, ACCENT)


## A numbered step circle: current is accent, done is a check.
static func draw_step_circle(ci: CanvasItem, centre: Vector2, number: int, state: String,
							 size: float = 32.0) -> void:
	var r: float = size * 0.5
	match state:
		"done":
			ci.draw_circle(centre, r, Color(GOOD.r, GOOD.g, GOOD.b, 0.16))
			ci.draw_arc(centre, r - 1.0, 0.0, TAU, 32, GOOD, STROKE_UI, true)
			draw_check(ci, centre, size * 0.42, GOOD)
		"current":
			ci.draw_circle(centre, r, ACCENT)
			ci.draw_string(font_label(), Vector2(roundf(centre.x - r), roundf(centre.y + 18.0 * 0.36)),
					str(number), HORIZONTAL_ALIGNMENT_CENTER, size, 18, ACCENT_INK)
		_:
			ci.draw_arc(centre, r - 1.0, 0.0, TAU, 32, STROKE_HOVER, STROKE_UI, true)
			ci.draw_string(font_label(), Vector2(roundf(centre.x - r), roundf(centre.y + 18.0 * 0.36)),
					str(number), HORIZONTAL_ALIGNMENT_CENTER, size, 18, TEXT)


## A spinning arc, for "waiting for..." states. `phase` is seconds.
static func draw_spinner(ci: CanvasItem, centre: Vector2, radius: float, phase: float,
						 colour: Color = ACCENT) -> void:
	var a: float = fposmod(phase, 1.0) * TAU
	ci.draw_arc(centre, radius, 0.0, TAU, 32, Color(colour.r, colour.g, colour.b, 0.18), STROKE_UI, true)
	ci.draw_arc(centre, radius, a, a + PI * 0.6, 16, colour, STROKE_UI, true)


# ---------------------------------------------------------------- HUD bits ---

## A vertical gradient rect: `top` colour alpha at the top edge, `bottom` at the
## bottom edge. The HUD's scrims, and the crash vignette's edges.
static func draw_scrim(ci: CanvasItem, rect: Rect2, top_alpha: float, bottom_alpha: float,
					   colour: Color = SCRIM, horizontal: bool = false) -> void:
	var a := Color(colour.r, colour.g, colour.b, top_alpha)
	var b := Color(colour.r, colour.g, colour.b, bottom_alpha)
	var pts := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y),
			rect.end, Vector2(rect.position.x, rect.end.y)])
	var cols := PackedColorArray([a, b, b, a]) if horizontal else PackedColorArray([a, a, b, b])
	ci.draw_polygon(pts, cols)


## The HUD attitude ring: translucent sky and ground so the world shows
## through, a bank scale, a fixed aircraft symbol, and a ring that takes the
## stall colour.
static func draw_attitude_ring(ci: CanvasItem, centre: Vector2, radius: float,
							   roll_degrees: float, pitch_degrees: float,
							   ring_colour: Color = Color(1, 1, 1, 0.45)) -> void:
	const SKY := Color(0.118, 0.227, 0.333, 0.40)
	const GROUND := Color(0.227, 0.165, 0.102, 0.50)
	ci.draw_circle(centre, radius + 3.0, Color(SCRIM.r, SCRIM.g, SCRIM.b, 0.25))
	ci.draw_circle(centre, radius, SKY)
	var roll: float = deg_to_rad(roll_degrees)
	var up := Vector2(-sin(roll), cos(roll))
	var along := Vector2(cos(roll), sin(roll))
	var offset: float = clampf(pitch_degrees / 45.0, -1.4, 1.4) * radius
	var horizon: Vector2 = centre + up * offset
	if offset >= radius:
		ci.draw_circle(centre, radius, GROUND)
	elif offset > -radius:
		var half_chord: float = sqrt(maxf(radius * radius - offset * offset, 0.0))
		var a: Vector2 = horizon + along * half_chord
		var b: Vector2 = horizon - along * half_chord
		var start: float = (a - centre).angle()
		var finish: float = (b - centre).angle()
		var toward_ground: float = up.angle()
		var sweep: float = fposmod(finish - start, TAU)
		if fposmod(toward_ground - start, TAU) > sweep:
			sweep -= TAU
		var points := PackedVector2Array([a])
		var steps: int = 24
		for i in range(1, steps):
			var angle: float = start + sweep * float(i) / float(steps)
			points.append(centre + Vector2(cos(angle), sin(angle)) * radius)
		points.append(b)
		ci.draw_colored_polygon(points, GROUND)
		ci.draw_line(a, b, Color(TEXT.r, TEXT.g, TEXT.b, 0.9), 2.0, true)
	# Bank scale on the ring, fixed to the screen, with the roll pointer moving.
	for deg in [-60, -30, 30, 60]:
		var t: float = deg_to_rad(float(deg) - 90.0)
		var dir := Vector2(cos(t), sin(t))
		ci.draw_line(centre + dir * (radius - 8.0), centre + dir * radius,
				Color(TEXT.r, TEXT.g, TEXT.b, 0.6), 2.0, true)
	var top := centre + Vector2(0, -radius)
	ci.draw_colored_polygon(PackedVector2Array([top + Vector2(0, 1), top + Vector2(-5, -8),
			top + Vector2(5, -8)]), Color(TEXT.r, TEXT.g, TEXT.b, 0.85))
	var rp: float = roll - PI * 0.5
	var rdir := Vector2(cos(rp), sin(rp))
	draw_pointer(ci, centre + rdir * (radius - 9.0), rdir, 8.0, 9.0, ACCENT)
	# Fixed aircraft symbol.
	ci.draw_line(centre - Vector2(radius * 0.62, 0), centre - Vector2(radius * 0.22, 0), ACCENT, 3.0)
	ci.draw_line(centre + Vector2(radius * 0.22, 0), centre + Vector2(radius * 0.62, 0), ACCENT, 3.0)
	ci.draw_circle(centre, 3.0, ACCENT)
	ci.draw_arc(centre, radius, 0, TAU, 64, ring_colour, STROKE_UI, true)
