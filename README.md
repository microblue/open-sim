# OpenRC Simulator

A flight training simulator for radio-controlled model aircraft.

The goal is narrow and specific: **time spent here with a real RC transmitter
should make you better at flying a real RC airplane** — and it should look like a
2026 simulator while doing it, not like a 2009 open-source one.

Both of those have to be true at once. Neither is allowed to eat the other.

---

## Transmitter

Put the radio in USB Joystick (HID) mode and plug it in before starting. An
EdgeTX/OpenTX radio set up AETR is recognised and bound automatically - no
wizard. Anything else: press `F3`. Full notes, including the Godot gamepad
mapping and the throttle interlock, in [Docs/TRANSMITTER_SETUP.md](Docs/TRANSMITTER_SETUP.md).

## Status — V0.1 complete

All eight milestones are done. The aircraft taxis, takes off, climbs, turns,
stalls, recovers, approaches, flares and lands, driven by a real transmitter,
in a field that looks like a field.

**The briefing room.** On launch the main menu is the whole pre-flight: four
aircraft with the numbers that tell them apart, five places and five weather
states each with a rendered preview, and the radio's status with its setup
button - all on one screen, mouse and keyboard, nothing behind a keypress. One
Enter flies. In flight, `M` brings the same room back.

**Grass that stands on the ground.** The scanned grass cards used to float a
quarter of a metre in the air and translate whole in the wind - roots and all.
The card is now built from the bake metrics, so the clump sits on the ground at
its real size, and the sway bends from the roots up: tips travel, roots do not.

```
223 tests, 8689 checks, 0 failed      physics core, ~2 s
 68 checks, 0 failed                  in-engine
```

**Trainer 1500, measured and locked.** Every number below came out of flying the
shipped definition in the regression suite. A physics change that moves any of
them outside its tolerance fails the build.

| | measured | tolerance |
|---|---|---|
| Best glide ratio, power off | 8.02 : 1 | ±8 % |
| Speed for best glide | 8.39 m/s | ±8 % |
| Minimum sink rate | 0.99 m/s | ±10 % |
| Stall speed, 1 g | 7.89 m/s | ±5 % |
| Full-aileron roll rate | 152 °/s | ±10 % |
| Static thrust, full throttle | 13.78 N | ±5 % |
| Level speed at 60 % throttle | 12.42 m/s | ±10 % |
| Takeoff ground roll on grass | 11.57 m | ±15 % |

Derived: C_Lmax 1.077, thrust-to-weight 1.04, `pb/2V` 0.13.

**The two effects that make it feel like an RC model, both measured:**

- **Propwash.** At 4 m/s with full up elevator, the pitching moment goes from
  0.17 N·m at idle to **6.26 N·m** at full throttle. That is why a powered model
  can be held off the ground at a speed where an unpowered one falls out of the
  sky, and why chopping the throttle on short final drops the nose.
- **Left-turning tendency.** Opening the throttle in a slow climb yaws the
  unrigged aircraft left by 0.474 N·m. The 2° of right thrust in the aircraft
  file cuts that to 0.074 N·m — an 84 % cancellation, which is exactly what the
  rigging is for.

**Performance**, on the development machine:

| | |
|---|---|
| Full physics step (11 sections, propulsion, ground, turbulence) | **3.41 µs** |
| Share of the 240 Hz budget | **0.08 %** |
| 30 simulated minutes at 240 Hz | 1.44 s wall clock, 1252× real time |

## Design

| Document | What it covers |
|---|---|
| [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md) | module split, frames, units, timing, determinism |
| [`Docs/PHYSICS_DESIGN.md`](Docs/PHYSICS_DESIGN.md) | the flight model — sections, stall, Reynolds, propwash, ground |
| [`Docs/AIRCRAFT_FORMAT.md`](Docs/AIRCRAFT_FORMAT.md) | the aircraft JSON schema |
| [`Docs/MILESTONES.md`](Docs/MILESTONES.md) | plan and definition of done for each stage |
| [`Docs/UI_DESIGN.md`](Docs/UI_DESIGN.md) | the interface system — colour, type, surfaces, widgets |
| [`Docs/CODING_CONVENTIONS.md`](Docs/CODING_CONVENTIONS.md) | style, and the physics-specific rules that matter |

### The one decision everything follows from

The flight model does not know the engine exists.

```
Source/RCPhysics/    plain C++17, zero engine dependency   ← the flight model
Source/OpenRCSim/    the Godot GDExtension                 ← the engine half
```

That split is why the physics can be compiled and tested on any machine with a
compiler, why tuning a stall model does not cost a multi-minute engine rebuild,
and why the renderer cannot accidentally influence the aircraft.

It also already paid for itself once. The project was originally built against
Unreal Engine 5 and moved to Godot 4 when the 200 GB install proved not worth
it for a scene that is a grass field, some trees and one 1.5 m model aircraft.
**The flight model and every one of its tests carried over unchanged** — the
switch touched only the engine half.

### The aircraft is not one set of coefficients

It is eleven aerodynamic sections, each with its own position, area, chord,
airfoil, control surface and **its own local airflow** — including the `Ω × r`
term that makes roll, pitch and yaw damping emerge instead of being faked.

Each section stalls on its own local angle of attack. Wing drop, snap roll and
spin fall out of that; none of them is special-cased. The tests measure roll
damping *collapsing* at the stall — autorotation — rather than asserting that
someone remembered to write a spin.

Wind is sampled per section too, so a gust the size of the wingspan rolls the
aircraft rather than merely displacing it.

### What the tests caught

Not a claim that the code is correct — a record of what the discipline actually
paid for. Each of these was found by a failing assertion or by rendering a frame
and measuring the pixels, and each is described in `Docs/MILESTONES.md`:

- total drag **fell** through the stall break, which would have let a deep stall
  mush along instead of descending
- the tail had no downwash, doubling the elevator needed per degree of trim
- the propeller wake was placed in front of the aircraft instead of behind it
- the wake's swirl varied as `r` instead of `1/r` — exactly backwards
- wake immersion was point-sampled, so 2° of right thrust became a 2.7×
  left/right lift asymmetry that flipped the aircraft on takeoff
- an axis that had never been swept produced a valid-looking calibration
- the terrain was never drawn at all: Godot's front faces are clockwise, and the
  sky material's ground colour was standing in for it convincingly enough that
  editing the ground shader appeared to do nothing

---

## Building

### The physics core and its tests — no engine required

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j
ctest --test-dir build --output-on-failure
```

Run a subset by name:

```bash
./build/rcphysics_tests Quat
./build/rcphysics_tests Trainer1500
```

Requires a C++17 compiler and CMake 3.16. Nothing else — no engine, no editor,
no package manager, no network. That is deliberate: the regression suite has to
be cheap enough to run on every change.

The build treats warnings as errors under `-Wall -Wextra -Wpedantic -Wshadow
-Wconversion -Wsign-conversion -Wold-style-cast -Wdouble-promotion`. Pass
`-DRC_WARNINGS_AS_ERRORS=OFF` if a new compiler disagrees.

### The game — requires Godot 4.7

Godot is a 74 MB download with no account and no installer:
<https://godotengine.org/download/linux/>

```bash
scripts/bootstrap.sh                    # fetches godot-cpp at a pinned commit

cmake -S . -B build-godot -G Ninja \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DRC_BUILD_GODOT_EXTENSION=ON
cmake --build build-godot -j            # ~30 s on 32 cores

godot --path Godot                      # or open the Godot/ project in the editor
godot --headless --path Godot           # runs the physics smoke test above

scripts/verify.sh                       # everything above, as one gate
```

The extension is built into `Godot/bin/` and picked up by
`Godot/openrcsim.gdextension`. It is marked `reloadable`, so rebuilding while
the editor is open reloads the flight model in place — that is the tuning loop.

> If the **default** CMake build ever needs godot-cpp, an engine dependency has
> leaked into `RCPhysics`. That is the bug — not the CMake file.

**Known issue:** `godot --headless --import` exits with `SIGABRT` on Godot 4.7.2
whenever a GDExtension registers any class. It is reproducible with an empty
`Node3D` subclass, so it is an engine bug, not this project's. The import
completes and its output is valid; `scripts/verify.sh` ignores that exit code and
verifies by running the project instead. See `Docs/MILESTONES.md`.

---

## Layout

```
CMakeLists.txt              core + tests by default; add -DRC_BUILD_GODOT_EXTENSION=ON
scripts/bootstrap.sh        fetches godot-cpp
Data/
  Aircraft/Trainer1500.json the reference aircraft
  Airfoils/  Propellers/    polar and propeller data (XFoil / APC), as added
Docs/                       design documents
Source/
  RCPhysics/                the flight model. No engine dependency.
    Public/RCPhysics/{Core, Physics, Aircraft, Input, Training}
    Private/                mirrors Public
  OpenRCSim/                the Godot GDExtension
    register_types.cpp      extension entry point
    Bridge/                 RCGodotConversion.h, RCGodotLog.cpp
    {Aircraft, Input, Camera, Training, UI}/
Godot/                      the Godot project
  project.godot             renderer and physics settings
  openrcsim.gdextension     points at Godot/bin/
  scenes/ aircraft/ fields/ materials/ environment/ ui/
Tests/                      Core, Aero, Propulsion, Dynamics, Regression
ThirdParty/godot-cpp/       fetched, not vendored
```

---

## Frames and units, in one box

Get these wrong and nothing else matters.

```
World  NED   X North,  Y East,  Z DOWN        right-handed, metres
Body   FRD   X nose,   Y right wing, Z down   right-handed

positive pitch = nose up
positive roll  = right wing down
positive yaw   = nose right from North

gravity is +Z.  altitude is -Z.

Godot: Y-up, right-handed, metres. A node's forward is -Z.
    North (nose) -> -Z      East (right wing) -> +X      Down -> -Y

Conversion is a PURE ROTATION (det +1, so handedness and cross-product signs
survive) with NO unit scaling, and lives in exactly one place:
    RCPhysics/Core/Math/FrameConversion.h   (unit-tested, no engine needed)
    OpenRCSim/Bridge/RCGodotConversion.h    (component copying only)
```

The physics core speaks SI and only SI. Inches, degrees, mAh and KV exist in the
aircraft JSON and in the UI, and are converted once at the boundary.

---

## Reference reading

Studied for how they solve specific problems, not to be copied wholesale:

- **PicaSim** — RC-scale aerodynamics, wing segmentation, wind, propwash
- **CRRCSim** — RC aircraft flight models
- **JSBSim** — 6-DoF architecture, data-driven aircraft, propulsion organisation
- **FlightGear**, **ArduPilot SITL**, **PX4** — FDM structure and validation practice
- **X-Plane** — blade-element aerodynamics at scale

The target is RC training fidelity. Where one of these is more complex than that
goal requires, the complexity is not adopted.

---

## Licence

The code is released under the [MIT License](LICENSE). Bundled assets keep their
own licences: the aircraft models are CC-BY-4.0 (credits in each
`Godot/aircraft/*/AIRFRAME-LICENSE.txt`), the Fira Sans fonts are SIL OFL 1.1,
and the fetched environment assets are CC0.
