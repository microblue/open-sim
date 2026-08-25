# Soaring

The world has air that goes up in it. This is what a glider is for, and without
it the Glider 2400 in the hangar — 13 : 1, stalling at 5.1 m/s — is a very
elaborate way of coming down slowly.

## Two kinds of lift

**Thermals** are columns of rising air over ground that has warmed. They drift
downwind, they have a life — they build, they work, they die — and each is
surrounded by the sink that has to balance it. A pilot finds one by the way the
model lifts a wing, centres by turning towards the lift, and loses it by flying
out the far side into the sink.

**Slope lift** is wind pushed up a hillside. Steady, predictable, and tied to a
place — which is why slope soaring is a different sport. It exists only where
the wind has a hill to climb and dies away above the ridge. Downwind of the same
ridge the calculation gives sink, and that is deliberate: flying into the lee
and finding the air going down is one of the ways models are lost, and it should
be possible to learn it somewhere safe.

## The ground decides where thermals are

| ground | heating |
|---|---|
| desert | 1.00 |
| rock | 0.90 |
| beach | 0.85 |
| grassland | 0.62 |
| forest | 0.30 |
| snow | 0.10 |
| water | 0.00 |

This is the tie between the terrain, the biomes and the air. Bare sand in sun is
the engine of a soaring day; forest is damp and shaded; water makes none at all.
Without it the sky would be the same everywhere and the landscape would mean
nothing to a soaring pilot.

The weather scales the whole day — a breezy afternoon works better than a still
one, an overcast sky barely at all, and rain not at all.

## Lift is sampled per section, and that is the whole point

A wing with one tip in a thermal and the other outside it gets a rolling moment.
That roll is exactly how a pilot feels a thermal and knows which way to turn.

Adding lift at the centre of gravity instead would give the aircraft the climb
and take away the only cue that lets anyone find it. So the lift field is
attached to the `WindField`, and arrives through the same per-section sampling
the wind already used. The regression suite measures the moment: **0.336 N·m**
with the aircraft at the edge of a column.

## The variometer

The HUD grows a column on the right when the air is doing anything. It shows
what the **air** is doing, not what the aeroplane is doing — positive means it
is worth turning, negative means leave — and it names the source, so a pilot can
tell whether to circle or to beat along a ridge. It is heavily smoothed, because
a real one lags and an instantaneous reading of turbulent air is unreadable.

The windsock and the wind readout show wind only. A thermal is not wind, and no
windsock has ever reported a vertical component.

## Measured

```
glider over a working thermal   +1.7 m in 45 s
glider in dead air            -75.9 m in 45 s
trainer in the same thermal   -11.5 m in 45 s
```

The trainer sinks faster, so the same air is not enough for it. That is what
makes the roster mean something in the air as well as on paper.
