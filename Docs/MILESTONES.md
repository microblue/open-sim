# OpenRC Simulator — Milestones

Each milestone opens with a short block stating **Goal / Files / Architecture
impact / Risks**, and closes only when:

1. it builds — both the CMake core build and the Godot extension build
2. the test suite passes
3. warnings are at zero
4. the regression suite runs
5. `README.md` and the relevant docs are updated

No milestone hands over code that has not been compiled.

Anything that cannot be compiled in the current environment is tagged
`UNVERIFIED` and revisited the moment it can be.

---

## Milestone 0 — Foundations ✅ complete

**Goal.** A repository that builds and runs, with the coordinate system, units,
timing and testing discipline pinned down before any physics is written.

Delivered:

- `RCPhysics` core, plain C++17, no engine dependency:
  - `Core/Types.h`, `Core/Units/Units.h` — SI everywhere, conversions at the edge
  - `Core/Math/` — `Vec3`, `Mat3`, `Quat`, `Table1D`, `Table2D`, `FrameConversion`
  - `Core/Clock/SimulationClock` — 240 Hz fixed step with hitch and spiral protection
  - `Core/Log.h` — six categories behind a sink
  - `Core/Json.h` — comment- and trailing-comma-tolerant reader with line-accurate errors
  - `Physics/Dynamics/` — `RigidBodyState`, `MassProperties`, `Wrench`,
    `ForceAccumulator`, semi-implicit Euler and RK4 integrators
- `OpenRCSim` GDExtension: `RCSimulationNode`, the Godot log sink, the frame
  conversion bridge, and the extension entry point
- A Godot 4.7 project with renderer settings, the `.gdextension` manifest and an
  end-to-end physics smoke test scene
- `Data/Aircraft/Trainer1500.json` — the complete reference aircraft definition
- One CMake project: core + tests by default in seconds,
  `-DRC_BUILD_GODOT_EXTENSION=ON` additionally builds the extension in ~30 s
- **89 tests / 375 checks**, building warning-free under
  `-Wall -Wextra -Wpedantic -Wshadow -Wconversion -Werror` — the same strict set
  applied to the extension code, with godot-cpp headers marked `SYSTEM` so its
  warnings cannot bury ours

Verified in this milestone, because getting any of them wrong invalidates
everything downstream:

- NED/FRD is right-handed; positive pitch is nose up; positive roll drops the
  right wing; a tail-up force pitches the nose down
- the Godot frame conversion is a **pure rotation** — a cross product survives it
  with the correct sign, so no moment in the simulation is mirrored
- there is no unit scaling between the physics frame and Godot's
- 30 FPS and 200 FPS produce the identical number of physics steps for the same
  wall-clock time
- attitude stays unit-norm across 30 simulated minutes at 240 Hz
- torque-free tumbling conserves angular momentum and rotational energy
- the shipped aircraft file is geometrically self-consistent and laterally symmetric
- **end to end in the engine**: a ballistic launch reproduces `½·g·t²` with an
  error matching semi-implicit Euler's analytic truncation term to five
  significant figures, and the Godot node's `Y` equals the physics altitude exactly

### Known issue: `godot --headless --import` aborts at shutdown

On Godot 4.7.2, running the headless editor import against a project whose
GDExtension registers **any** class ends in `SIGABRT` during shutdown.

Bisected to the engine, not to this project:

| Extension contents | `--import` exit |
|---|---|
| nothing registered, no log sink | 0 |
| log sink installed, nothing registered | 0 |
| one empty `Node3D` subclass registered | **SIGABRT** |
| `RCSimulationNode` registered | **SIGABRT** |

An empty subclass with no members, no overrides and an empty `_bind_methods`
reproduces it, so nothing in `RCSimulationNode` is implicated. `reloadable`,
the scene file and the script are all irrelevant - removing each in turn changes
nothing.

Impact is limited: the abort happens **after** the import has finished and its
output is valid, and running the project itself (`godot --headless --path Godot`)
exits cleanly. `scripts/verify.sh` therefore ignores the import's exit code and
verifies by running the project instead.

Revisit on the next Godot patch release. Until then, do not treat a non-zero
exit from `--import` as a build failure.

---

### Note: the engine changed during this milestone

Milestone 0 was first built against Unreal Engine 5. It moved to Godot 4 once it
was clear that a ~200 GB engine install, gated behind an account link, was a poor
trade for a scene consisting of a grass field, some trees and one 1.5 m model
aircraft.

The switch cost nothing that had been verified. `RCPhysics` and all of its tests
carried over **unchanged** — the only files replaced were the engine-side ones,
none of which had ever been compiled. The frame conversion was rewritten and
came out simpler: Godot's frame differs from NED by a pure rotation with no unit
scaling, where Unreal's differed by a reflection plus a factor of 100.

This is the module split in `ARCHITECTURE.md §2` doing exactly the job it was
designed for.

---

## Milestone 1 — Input ✅ complete

Real transmitter over USB, and the channel pipeline that turns raw HID axes into
control deflections.

- `Input/` — `ChannelTypes`, `Calibration`, `ExpoRates`, `ChannelMapper`
- The pipeline in a transmitter's own order: calibration → deadzone → reverse →
  **expo → dual rate → trim** → clamp. Applying rate before expo would change
  the expo's feel every time the rate switch moved, which is not what a radio does.
- **Raw Mode** bypasses expo, rate and trim for pilots who use their own curves;
  calibration and reverse still apply, because those describe the hardware.
- `RCInputNode` reads any HID joystick through Godot, so a RadioMaster, a FlySky
  through a dongle and a plain gamepad are all the same thing.
- Telemetry HUD: framerate, physics rate, dropped steps, every channel as a bar.

Asserted, among others: full stick still reaches full travel at any expo and any
deadzone; a disconnected transmitter closes the throttle and centres the sticks
rather than holding the last value; a profile round-trips through JSON and
produces identical stick values.

**Found by the tests:** an axis that had never been swept produced a
*valid-looking* default calibration (−1/0/+1), so the wizard would happily bind
it and it would then read full deflection at rest.

---

## Milestone 2 — Aerodynamics ✅ complete

The section model. Eleven aerodynamic surfaces, each with its own local airflow,
its own Reynolds number and its own stall.

- `Aero/` — `Airfoil` (analytic or tabulated, with hysteresis), `AeroSurface`,
  `FuselageAero`; `Environment/` — ISA `Atmosphere`, seeded `WindField`
- `Aircraft/` — `AircraftDefinition`, `AircraftLoader`, and the assembled
  `Aircraft` force model, evaluated in two passes so the tail flies in the
  wing's downwash
- Wind is sampled **per section**, so a wingspan-scale gust rolls the aircraft

Emergent, not scripted, and each one tested: roll, pitch and yaw damping from
`Ω × r`; dihedral rolling the aircraft out of a sideslip; the fin weathervaning
into the relative wind; one wing stalling while the other flies; and roll
damping collapsing at the stall — **autorotation**, the mechanism of a spin.

**Found by the tests:**
- Total drag *fell* through the stall break, because the induced-drag term was
  built on the collapsing blended `C_L`. Separation must ADD pressure drag, not
  replace induced drag. A deep stall would otherwise have mushed along instead
  of descending.
- The tail was missing its downwash entirely, which doubled the elevator needed
  per degree of trim change and saturated the elevator at 8° of alpha.

---

## Milestone 3 — Propulsion ✅ complete

Battery, ESC, motor and propeller solved as one coupled system, with the shaft
speed as a state so the spool-up lag is real.

- `Propulsion/Propeller` — `Ct(J)` / `Cq(J)`, seeded from published APC data as a
  function of pitch-to-diameter, replaceable with tables
- `Propulsion/PowerSystem` — the electrical operating point, current limiting,
  battery sag and state of charge
- Propwash, reaction torque, P-factor and gyroscopic precession

Measured: **13.78 N** static, 9200 rpm, 27.5 A, T/W 1.04; spool-up to 90 % in
50 ms; the integration is rate-independent to 1 % across 120 / 240 / 480 Hz.

The two RC-defining results:

- **Propwash.** At 4 m/s with full up elevator, the pitching moment goes from
  0.17 N·m at idle to **6.26 N·m** at full throttle — 36×. That is why a powered
  model can be held off the ground at a speed where an unpowered one falls, and
  why chopping the throttle on short final drops the nose.
- **Right thrust.** Opening the throttle in a slow climb yaws the unrigged
  aircraft left by 0.474 N·m; the 2° of right thrust in the aircraft file cuts
  that to 0.074 N·m — an 84 % cancellation, which is exactly what the rigging is
  for. At cruise the same rigging over-corrects slightly to the right, as it
  does on a real model.

---

## Milestone 4 — Ground ✅ complete

- `Ground/LandingGear` — sprung wheels, rolling resistance, a steerable nose
  wheel, and lateral friction that **saturates at μN**
- `Ground/CrashModel` — hard points derived from the airframe, plus a touchdown
  rate limit

The saturation is the whole ground-handling lesson: sliding sideways at 4 m/s,
the tyres deliver 7.28 N against a 9.93 N limit and doubling the slip buys
nothing more. Once they let go there is nothing to stop the aircraft swapping
ends, and the pilot has to catch it with rudder.

Taxi, steering, takeoff, climb-out and landing all fly. Nose load 16 % of weight.

**Found by the tests:** three separate errors, each of which flipped the
aircraft onto its back during the takeoff roll.
- The propeller wake was placed in FRONT of the aircraft: the axial test used
  `Dot(offset, axis) > 0`, but the thrust axis points forward and the wake goes
  aft.
- Wake immersion was sampled at each section's centroid. Two degrees of right
  thrust displaces the wake axis by 12 mm at the wing, and point sampling turned
  that into a 2.7× left/right difference in slipstream. It now integrates along
  the span.
- The slipstream swirl was modelled as solid-body rotation (`v ∝ r`). Momentum
  theory gives a free vortex (`v ∝ 1/r`) — the radial dependence was exactly
  backwards. It is now a Rankine profile, zero on the axis and 1/r outside.

---

## Milestone 5 — Calibration ✅ complete

Every performance number measured on the flying model and locked. See
`PHYSICS_DESIGN.md §13` for the table and the two design changes it forced (the
propeller, and the stall speed).

Seven of eight first-principles seeds proved good. All eight targets are now
`"locked": true`, so a physics change that moves any of them outside its
tolerance fails the build.

---

## Milestone 6 — GrassField01 and the look ✅ complete

Built procedurally in GDScript, so the whole scene lives in text files: terrain,
120 000 grass tufts on a wind shader, a perimeter treeline, distant ridges,
physical sky, a windsock, the pits and the pilot station.

The aircraft is generated from the **flight model's own geometry** — same
section positions, spans, chords, dihedral and incidence — so what the pilot
sees is what is flying, and a wing cannot be drawn where the aerodynamics does
not think it is.

Three camera modes. The pilot camera stands still and tracks loosely with a
deadzone, because pinning the model to the centre of the screen at a constant
size would remove the orientation challenge the simulator exists to teach.

**Found by looking at it:** four rendering bugs that no unit test would have
caught, which is why this milestone was verified by rendering frames and
measuring pixels rather than by assertion.
- **The terrain was never drawn.** Godot's front faces are CLOCKWISE; the
  obvious counter-clockwise winding made the whole ground back-facing. What
  looked like a ground plane was the sky material's `ground_color` showing
  through — a plausible green, which is why every attempt to fix the "ground
  colour" in the ground shader had no effect whatsoever.
- **The trees were black cut-outs**, for the same reason plus `cull_disabled`:
  Godot flips the shading normal on back faces, which undid the upward bias
  meant to make a canopy catch the sky.
- **`: source_color` only converts sRGB in the EDITOR.** Colours passed from
  GDScript arrive in the shader as-is, and shaders work in linear. An sRGB green
  used as a linear albedo is a mid grey-olive.
- **Shadow acne** across a 520 m flat field at the default bias, which darkened
  the entire ground.

---

## Milestone 7 — Wizard, UI, session flow ✅ complete

- Controller wizard: detect, capture neutral, then one stick at a time —
  identified automatically, so nobody needs to know what "axis 3" means on
  their radio. Live bars, per-channel reverse, saved profile.
- Minimal menu. The V0.1 requirement is to be flying within seconds, so it has
  four keys and gets out of the way; a saved profile skips it entirely.
- Reset (`R`), spawn modes (`F6`), aircraft hot reload (`F5`).

---

## Milestone 8 — Validation, regression, profiling ✅ complete

- **223 tests, 8689 checks** in the core suite, plus 68 in-engine checks
- Every locked target gated on every build
- A tuning panel for the session (`F4`) — the air, the physics rate, the spawn.
  Aircraft parameters deliberately stay in the JSON with hot reload, so there is
  only ever one answer to "what did I actually fly?"

Measured on the development machine:

| | |
|---|---|
| Full physics step, 11 sections + propulsion + ground + turbulence | **3.41 µs** |
| Share of the 240 Hz budget | **0.08 %** |
| Per aerodynamic section | 0.10 µs |
| 44 sections vs 11 | 3.65× — linear |
| 30 simulated minutes at 240 Hz | 1.44 s wall clock, **1252× real time** |

The 30-minute run is the V0.1 stability criterion, flown through seeded gusts
and turbulence with the ground underneath: the state stays finite, the
quaternion stays unit-norm to 1e-9, and the aircraft is still flying at the end.

---

## Out of scope for V0.1

Multiplayer, helicopters, drones, combat, career mode, a large aircraft library,
a marketplace, structural FEA, CFD, battery thermal modelling, weather beyond
wind and gusts, photoreal damage modelling, VR.

The architecture leaves room for several of these. None of them is built now.
