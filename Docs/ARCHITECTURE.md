# OpenRC Simulator — Architecture

## 1. What this project is

A flight training simulator for radio-controlled model aircraft. Two goals hold
simultaneously, and neither may be traded away for the other:

1. **Skill transfer.** Time on a real transmitter in this simulator has to make
   you better at flying a real RC airplane. That means the flight model is judged
   against measurable targets (stall speed, glide ratio, roll rate, takeoff
   distance), not against "feels about right".
2. **Modern visual quality.** It should look like a photograph of a flying field,
   not like a 2009 open-source flight sim.

Everything below exists to serve those two, in that order of priority when they
conflict:

```
RC physics fidelity  >  input latency and feel  >  visual quality
                     >  maintainability  >  feature count
```

## 2. The one structural decision everything else follows from

**The flight model does not know the engine exists.**

The repository splits into two halves:

| Half        | Contains                                                | Depends on the engine |
|-------------|---------------------------------------------------------|-----------------------|
| `RCPhysics` | aerodynamics, propulsion, dynamics, ground, environment, aircraft definitions, RC channel processing | **no** |
| `OpenRCSim` | the Godot GDExtension - nodes, cameras, HUD, HID plumbing, rendering | yes |

`RCPhysics` is plain C++17. It includes `<cmath>` and `<vector>`, and nothing
from the engine. This is what made the move from Unreal Engine to Godot cost
nothing: the entire flight model, and all of its tests, carried over unchanged. This is not architectural purity for its own sake — it buys
three concrete things:

- **The flight model is testable without a GPU, an editor, or a licence.** The
  CMake project at the repository root builds `RCPhysics` and the validation
  suite on any machine with a compiler. `ctest` runs the whole regression suite
  in under a second. That is what makes the validation discipline in
  `PHYSICS_DESIGN.md §13` practical rather than aspirational.
- **The engine is a replaceable component.** It has already been swapped once,
  from Unreal Engine 5 to Godot 4, and the diff touched no physics and no test.
- **Physics tuning does not cost an engine rebuild.** Iterating on a stall model
  through a multi-minute engine compile is how flight models stop getting tuned.
- **The renderer cannot accidentally influence the aircraft.** There is no
  scene tree to reach for, no frame delta to sneak in, no node processing order
  to get wrong.

The layout in the design brief (`Core/`, `Physics/Aero/`, `Physics/Propulsion/`,
…) is preserved verbatim *inside* `RCPhysics`. Only the module boundary was
added.

```
Source/
├── RCPhysics/                     ← plain C++17, no engine
│   ├── Public/RCPhysics/
│   │   ├── Core/{Math, Units, Clock}, Log.h, Json.h
│   │   ├── Physics/{Aero, Propulsion, Dynamics, Ground, Environment}
│   │   ├── Aircraft/       AircraftDefinition, AircraftLoader
│   │   ├── Input/          ChannelMapper, Calibration, ExpoRates
│   │   └── Training/       ResetManager, FlightMetrics
│   └── Private/            mirrors Public/
│
└── OpenRCSim/                     ← the Godot GDExtension
    ├── register_types.cpp  extension entry point
    ├── Aircraft/           RCSimulationNode, mesh + animation binding
    ├── Input/              HID device enumeration and polling
    ├── Camera/             Pilot, Chase, FPV
    ├── Training/           spawn, reset, session flow
    ├── UI/                 menus, wizard, HUD
    └── Bridge/             RCGodotConversion.h — the only frame conversion
                            RCGodotLog.cpp      — the log sink

Godot/                             ← the Godot project
├── project.godot
├── openrcsim.gdextension
├── bin/                    the compiled extension lands here
└── scenes/ aircraft/ fields/ materials/ environment/ ui/
```

## 3. Frames and units

This is the highest-risk boundary in the project, so it is pinned down here and
verified in `Tests/Core/TestFrameConversion.cpp`.

### Physics frames

| Frame | Axes | Notes |
|-------|------|-------|
| **World (NED)** | X = North, Y = East, Z = **Down** | right-handed, metres. Gravity is `+Z`. Altitude AGL is `-Z`. |
| **Body (FRD)**  | X = nose, Y = right wing, Z = down through the belly | right-handed |

Attitude is stored as the unit quaternion `q_wb` (body → world). Euler angles use
the aerospace 3-2-1 order: yaw about Z, then pitch about Y, then roll about X.

Sign conventions that the tests assert, because every moment in the sim depends
on them:

- positive **pitch** = nose up
- positive **roll** = right wing down
- positive **yaw** = nose right, measured from North
- a force pushing the **tail up** produces a **negative** (nose-down) pitching moment
- extra lift on the **right wing** produces a **negative** (roll-left) moment

### Godot's frame

Godot is Y-up, right-handed, metres. A node's forward is `-Z`. Mapping the
aircraft's sense of direction onto that:

```
North (nose)       →  -Z    Godot forward
East  (right wing) →  +X    Godot right
Down               →  -Y    Godot down

        ⎡  0  1  0 ⎤
    M = ⎢  0  0 -1 ⎥        det(M) = +1,  M Mᵀ = I
        ⎣ -1  0  0 ⎦

position/vector :  v_godot = M · v_ned          (no scaling — Godot is metric)
rotation        :  q_godot = m ⊗ q_ned ⊗ m*     m = (½, ½, ½, −½)
```

Two properties make this materially safer than a Z-up, left-handed,
centimetre engine frame - which is what this replaced:

- `det(M) = +1`, so **M is a pure rotation, not a reflection**. Handedness is
  preserved, which means cross products — every moment in the simulation —
  survive the conversion with the correct sign. `TestFrameConversion` asserts
  this directly by converting a cross product both ways.
- Godot is metric, so there is **no unit scaling at all**. The classic "forgot
  the factor of 100" bug cannot occur.

`m` is a 120° rotation about `(1, 1, −1)/√3`, whose quaternion components are
exactly ±½ — the conversion introduces no floating-point error of its own.

The arithmetic lives in `RCPhysics/Core/Math/FrameConversion.h` — inside the
engine-agnostic core, on purpose, so it can be unit-tested without Godot
present. The Godot side (`OpenRCSim/Bridge/RCGodotConversion.h`) only copies
components into `Vector3` and `Quaternion`, narrowing `double` to `real_t`.

**No other file may convert frames by hand.** A negated component next to a
physics value anywhere else is a bug.

### Units

`RCPhysics` speaks SI and only SI: metre, kilogram, second, newton, newton-metre,
radian, kg/m³. There is no degree, inch, pound or RPM anywhere in `Physics/`.

Config files and UI use whatever a modeller actually uses — inches of propeller
diameter, mAh of battery capacity, degrees of dihedral, KV of motor. Every one of
those is converted **once**, at load or display time, through
`RCPhysics/Core/Units/Units.h`.

## 4. Time

Physics runs on a fixed timestep, decoupled from the renderer:

```
render frame  →  SimulationClock::AddFrameTime(dt)
                 while (clock.ConsumeStep())
                     Simulate(clock.FixedDeltaSeconds());
                 render at clock.InterpolationAlpha()
```

Default rate is **240 Hz**. 120 Hz and 480 Hz are supported by
`SetRateHz()` and change nothing else.

Two protections are built in and tested:

- a single render frame longer than 250 ms has its excess discarded rather than
  triggering a catch-up burst;
- a per-frame step budget stops the spiral of death, and reports the drops so the
  HUD can say the machine is not keeping up.

Transmitter input is sampled as close to the physics rate as the device allows;
stick latency is second only to physics fidelity in the priority list.

## 5. How a step is computed

```
                 ┌────────────────────────────────────────┐
   pilot input → │ ChannelMapper → calibration → expo →    │
                 │ dual rate → trim → reverse → surfaces   │
                 └────────────────────┬───────────────────┘
                                      │
   RigidBodyState  ────────────────────┤
   WindField / gust / turbulence  ─────┤
                                      ▼
                          ┌──────────────────────┐
                          │  force model         │  pure function of state
                          │  ─────────────────   │
                          │  • per-section aero  │
                          │  • propulsion        │
                          │  • propwash          │
                          │  • ground contact    │
                          └──────────┬───────────┘
                                     │ ForceAccumulator
                                     ▼
                             Wrench (body force + moment about CG)
                                     │
                                     ▼
                          RigidBodyIntegrator  →  new RigidBodyState
                                     │
                                     ▼
                     Bridge → Vector3 / Quaternion → renderer
```

The force model being a **pure function of state** is a load-bearing property,
not a style preference. It is what allows RK4, what allows the validation suite
to sweep angle of attack offline, and what allows a physics bug to be reproduced
from a recorded state without the engine running.

## 6. What each layer owns

**`Core/`** — `Real` (double), `Vec3`, `Mat3`, `Quat`, lookup tables, units,
the simulation clock, the log sink, the JSON reader. No physics.

**`Physics/Aero/`** — the wing is *not* one set of coefficients. It is a set of
sections, each with its own position, area, chord, airfoil, control surface and
**its own local airflow**. Each computes its own angle of attack and can stall
independently of its neighbours. That is what produces wing drop, snap roll and
asymmetric stall without any of those being special-cased. See
`PHYSICS_DESIGN.md`.

**`Physics/Propulsion/`** — battery → ESC → motor → propeller, producing thrust,
reaction torque, and a propwash velocity field that the tail and wing root sample
as part of their local airflow. Propwash is not cosmetic: it is why a powered RC
trainer still has elevator and rudder authority at almost zero airspeed.

**`Physics/Dynamics/`** — `RigidBodyState`, `MassProperties`, `ForceAccumulator`,
the integrators. Nothing here knows what an aircraft is.

**`Physics/Ground/`** — sprung wheels with friction, a steerable nose wheel, and
enough lateral grip modelling to ground-loop the aircraft if it is mishandled.
Godot's Jolt backend handles the collision query; the wheel forces are ours.

**`Physics/Environment/`** — atmosphere (density, viscosity → Reynolds number),
steady wind, gusts, turbulence, thermals. All randomness is **seeded**.

**`Input/`** — a generic HID abstraction first, vendor quirks second. Calibration,
channel mapping, expo, dual rate, trim, reverse — plus a **Raw Mode** that
bypasses all of it for pilots who prefer to use their transmitter's own curves.

## 7. Determinism

Given the same initial state, the same input sequence, the same weather seed and
the same `dt`, the simulation reproduces the same trajectory. This is what makes
the regression suite meaningful.

Consequences that are enforced rather than hoped for:

- no wall-clock time inside the physics core
- no `rand()`; every stochastic process (gust, turbulence) takes an explicit seed
- no float/double mixing — the core is `double` throughout
- no reliance on the engine's node processing order

## 8. GDScript policy

GDScript is allowed for UI hookup, scene construction, effects, content wiring
and quick prototyping.

GDScript is **not** allowed for anything that computes a force, a moment, a
coefficient, an integration step, or a control-surface deflection. Those live in
`RCPhysics`, in C++, where they are tested.

## 9. Platform

Linux is the primary development platform; Windows is a first-class build
target. No platform-specific API may be used outside a clearly isolated
backend. The HID layer in particular is written against an abstraction with
per-platform implementations behind it.

## 10. Build

Two build systems, on purpose:

One build system, two scopes.

```bash
# The physics core and its validation suite. Requires only a C++17 compiler.
# Seconds. This is the loop to work in.
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j
ctest --test-dir build --output-on-failure

# Additionally build the Godot GDExtension into Godot/bin/. Pulls in godot-cpp,
# so this takes minutes rather than seconds - hence off by default.
scripts/bootstrap.sh                       # fetches godot-cpp at a pinned commit
cmake -S . -B build-godot -DRC_BUILD_GODOT_EXTENSION=ON
cmake --build build-godot -j
```

```bash
# Everything above as one gate: core, invariants, extension, in-engine tests,
# and a rendered frame of the field.
scripts/verify.sh
```

If the **default** build ever needs godot-cpp, an engine dependency has leaked
into `RCPhysics`, and that is the bug — not the CMake file.

The rendering step matters more than it looks. Four of the bugs in Milestone 6
were invisible to any assertion and were found by rendering a frame and reading
the pixel values back — including a terrain that was never drawn at all, with
the sky material's ground colour standing in for it convincingly enough to
absorb several rounds of "fixing" the ground shader.
