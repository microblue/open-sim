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
- **Get out of the way.** The briefing room opens on every cold start, one
  Enter flies, and in flight the overlay is a keypress away. The HUD itself
  never has more than the three readings that change a decision.

## The system

Everything lives in `Godot/ui/UITheme.gd`. Nothing else hard-codes a colour or a
pixel size.

### Colour

| | | role |
|---|---|---|
| base | `#0B0E13` | ground, and what overlays sink towards |
| panel | `#141A20` at 78 % | translucent card |
| stroke | white at 9 % | the hairline that makes a panel a surface |
| text / dim / faint | `#E8EFFA` / `#8C9CB3` / `#616E82` | three steps, no more |
| **accent** | `#4DD6E6` | every live reading, and only those |
| warn / danger / good | `#F5AE2E` / `#E5474D` | states that need action, never decoration |

One accent, three greys, three states. A reading is cyan; a heading is faint; a
problem is amber or red. There is no fourth meaning available, which is what
keeps the screen legible at a glance.

### Type

Six sizes — 10 / 12 / 14 / 17 / 26 / 44 — and the hierarchy is carried by size,
colour and letterspacing rather than by boxes and rules. Headings are
letterspaced small caps; values are large and plain. A `44 m/s` and a `SESSION`
never look like the same kind of thing.

### Surfaces

Rounded cards, one polygon each, with a one-pixel light stroke. Full-screen
overlays put a blurred, desaturated copy of the scene behind them rather than a
black slab: the field stays faintly visible, which keeps the pilot oriented and
makes the menu read as something laid over the world.

### Motion

Short and functional. Overlays ease in over about 300 ms with a small slide; the
tuning drawer slides from the edge it belongs to; readouts are eased towards
their targets so a 240 Hz simulation does not produce a flickering number. A
value that changes when a key is pressed flashes briefly, so the keypress is
visibly connected to the number.

Nothing loops, nothing bounces, nothing draws attention to itself.

## The screens

**Flight HUD.** Corners and edges, centre left clear. Aircraft identity top
left; frame and step rate top right; speed and height on the edges at eye level;
transmitter gates bottom left; power bottom right; attitude, angle of attack and
wing separation across the bottom centre. One banner slot at the top for the one
thing that needs saying — never two at once.

**Briefing room (the main menu).** Everything that decides a sortie on one
screen, over the live field: four aircraft with the numbers that tell them
apart, five places and five weather states each with a rendered preview, and the
radio status with its setup button. A fly button across the bottom carries the
current selection written above it. Mouse and keyboard both work; hovering a
card selects it, and the fly button is one Enter away. Nothing that matters is
behind a keypress.

**Transmitter setup.** A card with a six-segment progress bar, one instruction
at a time, and the raw axes shown live throughout — the fastest way to
understand what a setup screen is doing is to watch it react. The axis about to
be bound highlights itself.

**Tuning drawer.** Slides from the right. Rows with a label, a value and a
position track. It adjusts the *session* — the air, the physics rate, the spawn —
and deliberately has no slider for a lift-curve slope: those live in
`Data/Aircraft/*.json` and reload with `F5`, so there is only ever one answer to
"what did I actually fly?"

## Custom widgets

Every gauge is drawn rather than assembled from controls, because each one is an
instrument rather than a form field. `UITheme` provides the primitives:

- `draw_stick_gate` — a gimbal gate with cross hairs and a trail to the stick
- `draw_attitude` — a rolling, pitching horizon clipped to a circle, with the
  chord endpoints solved exactly so nothing overhangs the disc
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

writes each interface state to `Godot/shots/`. That is also how the rendering
bugs in `MILESTONES.md` were found — four of them were invisible to any test and
turned up only by looking at a frame and reading the pixel values back.
