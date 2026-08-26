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

const BASE          := Color(0.043, 0.055, 0.075)          # near-black ground
const PANEL         := Color(0.078, 0.098, 0.125, 0.78)    # translucent card
const PANEL_SOLID   := Color(0.078, 0.098, 0.125, 0.96)
const STROKE        := Color(1.0, 1.0, 1.0, 0.09)          # 1 px hairline
const STROKE_STRONG := Color(1.0, 1.0, 1.0, 0.18)

const TEXT          := Color(0.91, 0.94, 0.98)
const TEXT_DIM      := Color(0.55, 0.61, 0.70)
const TEXT_FAINT    := Color(0.38, 0.43, 0.51)

## The live-data accent. Everything that is a current reading is this colour.
const ACCENT        := Color(0.30, 0.84, 0.90)
const ACCENT_DIM    := Color(0.30, 0.84, 0.90, 0.28)

## Reserved for states that need action. Never decorative.
const WARN          := Color(0.96, 0.68, 0.18)
const DANGER        := Color(0.90, 0.28, 0.30)
const GOOD          := Color(0.35, 0.85, 0.52)

# -------------------------------------------------------------------- type --

const SIZE_MICRO  := 11
const SIZE_LABEL  := 13
const SIZE_BODY   := 15
const SIZE_VALUE  := 19
const SIZE_LARGE  := 28
const SIZE_HERO   := 46
## The main menu's wordmark, and the biggest thing on any screen.
const SIZE_DISPLAY := 60
## Card titles on the main menu (an aircraft, a place, a weather state).
const SIZE_TITLE := 26
## Section headings on the main menu ("AIRCRAFT", "LOCATION", "WEATHER").
const SIZE_SECTION := 16

# ----------------------------------------------------------------- spacing --

const S1 := 4
const S2 := 8
const S3 := 12
const S4 := 16
const S5 := 24
const S6 := 32
const S7 := 48

const RADIUS := 10.0
const HAIRLINE := 1.0


static var _fonts: Dictionary = {}

## Fira Sans, bundled (SIL OFL - see assets/fonts/LICENSE.txt). A game UI needs
## a real typeface, not the engine's fallback: the fallback renders every glyph
## at the same weight and reads as an engineering drawing rather than a product.
static func font() -> Font:
	return _font("res://assets/fonts/FiraSans-Regular.otf")


static func font_bold() -> Font:
	return _font("res://assets/fonts/FiraSans-Bold.otf")


## Condensed heavy: the wordmark and the section headings. This is the face
## that makes a heading read as a title rather than as a label.
static func font_condensed() -> Font:
	return _font("res://assets/fonts/FiraSansCondensed-Heavy.otf")


static func font_condensed_bold() -> Font:
	return _font("res://assets/fonts/FiraSansCondensed-Bold.otf")


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

static func draw_text(ci: CanvasItem, position: Vector2, text: String,
					  size: int = SIZE_BODY, colour: Color = TEXT,
					  align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT,
					  width: float = -1.0) -> void:
	# A soft shadow under every glyph. The HUD sits over a bright sky and a
	# pale field; without the shadow the numbers fight the world behind them,
	# and the menu's text over the frosted field loses the same battle. One
	# extra pass, offset a pixel and a half down.
	ci.draw_string(font(), position + Vector2(1.0, 1.5), text, align, width, size,
				   Color(0, 0, 0, 0.45))
	ci.draw_string(font(), position, text, align, width, size, colour)


## Letterspaced small caps, for section headings. The spacing is what separates
## a heading from a value at a glance without needing a second font weight.
## Set in the condensed heavy face: a heading is a title, not a label.
static func draw_label(ci: CanvasItem, position: Vector2, text: String,
					   colour: Color = TEXT_FAINT, spacing: float = 2.2,
					   size: int = SIZE_MICRO) -> void:
	# Shadowed like draw_text. These labels are the smallest, faintest type on
	# the screen and half of them sit over sky or sunlit grass: without it
	# "VARIO", "ANGLE OF ATTACK" and "FLAP" were invisible in flight and
	# perfectly legible in the menu, which is the wrong way round.
	var f: Font = font_condensed()
	var x: float = position.x
	for i in text.length():
		var glyph: String = text[i].to_upper()
		ci.draw_string(f, Vector2(x + 1.0, position.y + 1.5), glyph,
					   HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.55))
		ci.draw_string(f, Vector2(x, position.y), glyph,
					   HORIZONTAL_ALIGNMENT_LEFT, -1, size, colour)
		x += f.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + spacing


static func text_width(text: String, size: int) -> float:
	return font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## Width of a string once draw_label's letterspacing is applied. Laying a panel
## out with the unspaced width leaves the last few characters hanging off it.
static func label_width(text: String, spacing: float = 2.2,
						size: int = SIZE_MICRO) -> float:
	var f: Font = font_condensed()
	var total: float = 0.0
	for i in text.length():
		total += f.get_string_size(text[i].to_upper(), HORIZONTAL_ALIGNMENT_LEFT,
								   -1, size).x + spacing
	return maxf(total - spacing, 0.0)



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
uniform vec3 base : source_color = vec3(0.043, 0.055, 0.075);

void fragment() {
	vec3 scene = textureLod(screen_tex, SCREEN_UV, blur).rgb;
	// Desaturate and darken just enough that text sits on it - the point of
	// the frost is that the field stays recognizable behind the panels, so
	// anything stronger than this reads as mud instead of as glass.
	float luma = dot(scene, vec3(0.2126, 0.7152, 0.0722));
	scene = mix(scene, vec3(luma), 0.18);
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
static func draw_text_shadow(ci: CanvasItem, position: Vector2, text: String,
							 size: int = SIZE_BODY, colour: Color = TEXT,
							 shadow: Color = Color(0, 0, 0, 0.55),
							 align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT,
							 width: float = -1.0) -> void:
	ci.draw_string(font(), position + Vector2(1.5, 2.0), text, align, width,
				   size, shadow)
	ci.draw_string(font(), position, text, align, width, size, colour)
