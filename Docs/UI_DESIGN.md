# OpenRC Simulator — Interface Design

## What the interface is for

A pilot flying an RC model looks at the model, not at the screen furniture. The
interface therefore has one job: put the two or three things that change a
decision where they can be read without looking away, and keep everything else
out of the way until it is asked for.

That produces a short list of rules, and everything below follows from them.

- **Numbers are for decisions, not for display.** Exact figures live behind a
  key (`F2`). What stays on screen is speed, height, power, and how close the
  wing is to letting go.
- **A warning that is always on is not a warning.** Amber and red appear only
  when the pilot has to act. Parked in a breeze the wing is technically
  separated — the relative wind is behind it — and the HUD says nothing,
  because shouting STALL at a stationary model is how a stall warning stops
  being read.
- **The pilot's own thumbs are the most-watched instrument.** Hence the two
  gimbal gates, bottom left, at the proportions of the sticks on a real radio.
  That element is the reason the screen reads as an RC simulator rather than as
  a flight game, so it gets the space.
- **Always say what to do next.** At any moment the screen answers "what do I
  press now": the hint bar in flight, the key row on every screen, and three
  keys that are always shown and always work - `C` view, `H` help, `Esc` menu.
  Nothing the pilot needs is reachable only by knowing a key exists.
- **Draw the controls, don't list them.** A beginner does not know that the
  elevator is the right stick pulled back. Every screen that talks about the
  controls draws the transmitter or the keys (`ControlDiagrams.gd`), with each
  stick's job written beside it, and moves the picture live.
- **Get out of the way.** One Enter flies, and the HUD never has more than the
  three readings that change a decision.

## The system — "Flightline Glass"

Everything lives in `Godot/ui/UITheme.gd`. Nothing else hard-codes a colour or a
pixel size. The mood is a field instrument at dawn: graphite glass, one
brand-cyan live colour, white numerals sitting in the world rather than in
boxes, and warm colours only when the pilot has to act.

### Colour

| | | role |
|---|---|---|
| base | `#0B0E13` | ground, the frost tint, the ink of text outlines |
| surface / surface 2 | `#131920` 96 % / `#1A222C` | modal sheets / inset rows, selected cards, advice boxes |
| stroke / strong / hover | white at 8 / 16 / 28 % | hairlines that make a panel a surface |
| text / dim / faint | `#E8EFFA` / `#9DA9BB` / `#76839A` | three steps; faint only on solid surfaces |
| HUD label | `#C9D3E0` at 92 % | every caps label drawn over the 3D world |
| **accent** | `#4DD6E6` | live readings, focus, the one primary action |
| warn / danger / good | `#F5AD2E` / `#FF4D5A` / `#59D985` | states that need action, never decoration |

Nothing drawn over the world uses the faint or dim greys: over grass and a pale
sky they have no contrast, and that is what made the small labels look doubled.

### Type

Saira Condensed **Bold** for titles, buttons and letterspaced caps (Black is
retired: at label sizes it closes the counters of A, R, O, G); Rajdhani Medium
for body and SemiBold for numerals. Sizes: 72 stage name, 52 screen title, 34
card title, 24 button, 64 / 30 HUD numerals, 21 / 18 body, 20 / 16 caps.
Nothing below 16 ships — at 1280×720 the canvas is scaled to 0.667, and 16 is
the smallest size that stays readable there.

- Caps are tracked +2 px through a cached `FontVariation`, so a label is one
  `draw_string`: kerning kept, one subpixel phase. Lowercase is never tracked.
- Text over the world gets a 2 px dark **outline** (`over_world = true`), never
  an offset drop shadow — a shadow on a half pixel smears into a second, darker
  copy of every small letter.
- HUD numerals are drawn in fixed cells (`draw_numeral`), so "9.9" and "10.0"
  do not make the reading jitter.
- Arrows, checks, chevrons, the battery and the warning triangle are drawn as
  vectors: neither face has glyphs for them that hold up at keycap size.

### Surfaces and buttons

Modals (`draw_modal`): solid surface, 14 px radius, a three-ring soft shadow, a
one-pixel sheen on the top edge, the world frosted behind. Three button styles,
**exactly one primary per screen**: primary (solid accent, dark ink), secondary
(raised surface, hairline), tertiary (text only). Keyboard focus is a 2 px
accent ring drawn *in addition to* hover, so a resting mouse never hides where
the keyboard is. Steps are a thin track with the current one in accent and done
ones checked (`draw_stepper`) — no pills, no glow.

### Motion

Appear 220 ms ease-out with a 12 px rise, dismiss 140 ms, focus ring travels in
120 ms. Only danger pulses. Reduced motion removes every translation and pulse.

## The screens

**Brand.** The mark is a trainer in an attitude-indicator ring - horizon level,
the aeroplane banked - in the accent cyan and the text white. It is the boot
splash (`Godot/assets/brand/splash.png`, set in `project.godot`), the window and
desktop icon, and the menu's lockup. `Godot/assets/brand/build.py` regenerates
every file from one script; change the name at the top of it if the product
name changes.

**From launch to the air.** First launch, keyboard: *how will you fly* →
*try the keys* → **Start first flight** — two presses. With a radio plugged in
the transmitter card is already chosen and named; a recognised EdgeTX/OpenTX
radio goes straight to "which thumb is your throttle on", an unknown one through
the wizard. A returning pilot lands on the Fly hub with FLY focused and last
time's loadout: one press.

**First-run setup** (`Welcome.gd`; also the input pill on the menu). Keyboard:
the keys drawn, each ticked as it is tried, moving a drawn transmitter. Radio:
three numbered steps to connect it; after ten seconds without a radio, a
troubleshooting list and every device the computer does see, each with "Use
this". Stick mode is asked only of radio users, as the thumb the throttle is
on — it changes the pictures and hints, the radio decides the flying. "I
already fly RC models" starts every hint as learned.

**The Fly hub (main menu).** The aircraft turning on the stage, its name and
plain-language tags ("Recommended for first flights", "Gentle", "Lands slow").
Four loadout chips — Aircraft, Location, Weather, Start (runway / in the air /
on approach) — each opening a picker over the hub; Esc in a picker changes
nothing. FLY is the one primary and has focus. Ways to fly: **First flight**
(guided) and **Practice landings**. The header pill says live what is flying
it: transmitter and its name, a transmitter found but not set up, or the
keyboard. The loadout is remembered (`last/*`).

**Guided first flight** (`FirstFlight.gd`, pure). Six items in a checklist top
left — take off, climb to 20 m, set cruise power, turn around, fly back over
the field, land — with the hint bar saying only how to do the current one, in
keyboard or transmitter words. Calm air. A crash offers **Try again from step
N**: steps 2-4 restart in the air, 5 and 6 on approach, ticks kept. Done: "First
flight complete. You took off, turned and landed."

**Hints** (`ContextHints.gd`, pure). One instruction at a time, from the flight
state: parked, rolling, just airborne, far from the field ("Turn back. The
field is 193 m behind you"), out of frame in the pilot's view (press `C`),
landing (line up → throttle back → flare), too slow on approach. Stuck for 6 s
the hint pulses; for 15 s it adds "Press H to see all the controls". In "Until
learned" mode a hint stops offering itself after the pilot has done it three
times (`hints/learned`), and comes back only if they get stuck.

**Help** (`H` or `F1`, pauses in flight). The flying controls drawn for the
keyboard or the transmitter (a segmented switch, `Tab`), moving live, and every
other key in a fixed keycap column grouped by what it is for. No transmitter:
a dimmed picture and a "Set up a transmitter" button.

**Locator.** When the model is under 46 px across, four corner brackets and its
distance; out of frame, a vector chevron on the edge, kept clear of the bottom
cluster and the key legend. Not in FPV. Settings: Aircraft locator.

**Views** (`C` cycles, `1` `2` `3` direct). Follow is the default: behind and
above the model at a fixed distance in wingspans, horizon always level,
swinging round behind a turn with a 0.45 s half-life. Pilot's view stands on
the field (the windsock is off the pilot's line to the runway). FPV is bolted to
the airframe.

**Flight HUD** (`FlightHUD.gd`, phase from `HudPhase.gd`). No panels: outlined
type over two soft scrims. One cluster at the bottom centre so one glance reads
it — speed with a ribbon banded by the aircraft's *own* stall speed (red below
it, amber to 1.15×), the attitude ring (pilot's view; always in Detailed), height
with a climb-rate arrow and ribbon — power and battery to its left, the
keyboard's stick gates bottom left. Name and state top left (or the first-flight
checklist), key legend top right (collapses to "H Help" after 20 s airborne),
"Field 180 m" with an arrow when more than 80 m out. What shows follows the
phase: parked shows only throttle and the next step; the battery appears in the
air only below 40 %. `V` cycles **Clean / Standard / Detailed**; Detailed adds
the engineering readouts (angle of attack, separation, rpm, thrust, height over
the field, frame and step rate). Any menu or overlay fades the HUD out.

Warnings come in two tiers, never saying the same thing twice. **Chips** at the
top centre, from `FlightWarnings.gd` (pure, tested):

| chip | shows when | colour |
|---|---|---|
| `STALL WARNING` | separation 6-30 % | warn |
| `LOW · SINKING` | airborne, sinking faster than 2 m/s, under 2 s from the ground at that rate | danger |
| `FAR · COME CLOSER` | pilot view, wingspan under 30 px at the narrowest zoom | warn |
| `BATTERY LOW` / `CRITICAL` | under 20 % / 15 % | warn / danger |

One **banner** for what needs action now: deep stall ("STALL — LOWER THE NOSE"),
a failure, a radio problem. Notices are a toast. A crash shows no banner: the
cluster dims, the edges flash red, and after 0.6 s the crash card says why.

**Crash card.** "CRASHED · 26 m · 12.6 m/s" and "Flight 3 · 0:48 in the air";
the reason as the title, what happened, a TRY THIS box, and three real buttons —
**Fly again** `R`, **Try again in the air** `T` (primary when the crash came well
after take-off), **Watch the replay** `Tab`. The third crash for the same reason
suggests practising it from the air; the first crash ever points at the replay.

**Paused** (`Esc`, `P`, or losing window focus). Resume (primary) · Fly again ·
Restart in the air · Main menu — then controls and help, transmitter setup,
settings — then Quit to desktop, which asks for a second press. Esc never quits
outright. It never resumes by itself. A flying key still held when any screen
closes is ignored until it has been released.

**Keys that cost a flight.** `4`-`8` cause a failure on purpose and `9` clears
it, only when Settings → Practice → Failure keys is on; a beginner mashing keys
must not get a dead servo.

**Height.** The altimeter reads height above the ground directly below - the
ground a crash is judged against. Height relative to the field, negative over a
valley, is in Detailed.

**Pilot-view auto-zoom** (`X`). Narrows the pilot camera just enough that the
wingspan stays at least 30 px tall, between 6° and the 38° base field, blended
in log space with a 0.15 s half-life. The eye never moves, so apparent size still
falls with distance until the floor is reached. `Z` is a multiplier on top of it.
The tracking deadzone is measured in fractions of the field, so framing behaves
the same at any zoom.

**Height cue** (`G`). A soft plan-view silhouette on the ground *straight below*
the model — not along the sun, whose real shadow is left alone. 0.6 opacity near
the ground, 0.15 by 50 m, gone by 80 m. Each vertex is pulled towards the camera
along its own view ray so it draws over the grass cards without moving on screen,
by no more than the model's own height allows, so it never paints over the model.

**Settings** (`O`). One frosted card, rows that change live with clickable
chevrons, a line under the list explaining the selected row, saved to
`user://settings.cfg` as they change: game and menu volume, window mode (with a
15 s keep-or-revert), units, stick mode, starting view, auto-zoom, height cue,
failure practice and failure keys, HUD (Clean / Standard / Detailed), stick
display, hints (Always / Until learned / Off) and Reset hints, the locator and
reduced motion. An unreadable file is renamed `settings.cfg.bad`; a file from a
newer schema is read but never overwritten.

**Transmitter setup** (`F3`). The same shell as the first-run setup: seven
steps (connect, centre, aileron, elevator, throttle, rudder, check). The radio
drawn with the stick to move lit and a ghost stick sweeping the travel asked
for, a meter filling as the travel is captured, and the throttle step asks
which thumb it is on. The check page shows each channel's expected direction
and a live MATCHES / REVERSED? badge from the first big movement of the sweep,
with Reverse one key away.

**Tuning drawer.** Slides from the right. Rows with a label, a value and a
position track. It adjusts the *session* — the air, the physics rate, the spawn —
and deliberately has no slider for a lift-curve slope: those live in
`Data/Aircraft/*.json` and reload with `F5`, so there is only ever one answer to
"what did I actually fly?"

## Custom widgets

Every gauge is drawn rather than assembled from controls, because each one is an
instrument rather than a form field. `UITheme` provides the primitives:

- `draw_stick_gate` — a gimbal gate with cross hairs and a trail to the stick
- `draw_attitude_ring` — a rolling, pitching horizon clipped to a circle, with
  the chord endpoints solved exactly so nothing overhangs the disc, a bank
  scale and a ring that takes the stall colour
- `draw_arc_gauge` — the throttle ring
- `draw_track` / `draw_bipolar_track` — filled and centre-zero bars
- `draw_panel` — a rounded card as one polygon

That last one is worth a note. Composing a rounded rectangle from a rectangle
plus four corner circles — the obvious way, since `draw_rect` has no radius —
overlaps the fills, and with a translucent panel every overlap darkens: the
corners come out as visible blobs. It has to be one polygon.

## Verifying it

Layout is checked by rendering it, not by assertion:

```bash
godot --path Godot --script res://tests/UiShots.gd
```

writes each interface state to `Godot/shots/`, and `res://tests/UxShots.gd`
walks the player's journey in order — setup, the hub, a picker, help, the
guided first flight, each phase of flight, the locator, pause, a crash card,
the wizard and settings — into `ux_NN_*.png`. The settings screen, the warning
chips, the height cue and the pause card have their own pass,
`res://tests/FeatureShots.gd`, which also checks that a held key is ignored after
a screen closes and that a pause does not resume by itself. That is also how the rendering
bugs in `MILESTONES.md` were found — four of them were invisible to any test and
turned up only by looking at a frame and reading the pixel values back.
