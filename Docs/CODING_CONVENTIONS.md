# OpenRC Simulator — Coding Conventions

Short, and mostly about the things that actually cause bugs in a physics
simulator.

## Two dialects, one repository

`RCPhysics` is plain C++17 in `namespace rc`. `OpenRCSim` is the GDExtension in
`namespace openrc`; it uses Godot's types and, where Godot's API dictates the
shape (bound method names, `_bind_methods`), Godot's naming - fighting the
engine's conventions at its own boundary costs more than it saves.

|  | `RCPhysics` | `OpenRCSim` |
|---|---|---|
| namespace | `rc`, `rc::units`, `rc::frame` | `openrc` |
| types | `Vec3`, `Table1D` | `RCSimulationNode` |
| members | `PascalCase` | `PascalCase` |
| locals | `camelCase` | `camelCase` |
| bound methods | — | `snake_case` (Godot requires it) |
| strings | `std::string` | `godot::String` |
| containers | `std::vector`, `std::map` | `godot::TypedArray`, `godot::Dictionary` |
| scalars | `rc::Real` (double) | `real_t`, narrowed at the bridge |
| indentation | 4 spaces | 4 spaces |

Braces on their own line in both.

Godot's `real_t` is `float`. Every crossing between `rc::Real` and `real_t` goes
through `Bridge/RCGodotConversion.h` with an explicit `static_cast`, so the
narrowing is visible and confined to one file.

## Physics-specific rules

**Every physical quantity is SI inside `Physics/`.** No degree, inch, pound or
RPM. Conversions happen once, at load or display, through `Core/Units/Units.h`.

**Name the frame when it is not obvious.** `positionWorld`, `velocityBody`,
`momentBody`, `offsetFromCGBody`. A bare `position` in physics code is a review
comment.

**No magic numbers.** A number in a physics expression is either a named constant
in `Units.h`, a field on an `AircraftDefinition`, or it does not belong there. If
a value was tuned by feel, the comment says so and says what it changes.

**Guard every division.** Airspeed goes to zero on the runway; chord and area can
be zero in a malformed definition. Use `SafeDivide` or an explicit early-out, and
never rely on infinity propagating harmlessly.

**The force model is a pure function of state.** No member mutation during
evaluation, no reading wall-clock time, no `rand()`. This is what makes RK4, the
validation sweeps and deterministic replay possible; it is a hard constraint, not
a preference.

**No wall-clock time and no unseeded randomness in the core.** `SimulationClock`
provides simulated time. Every stochastic process takes a seed.

## `const` and ownership

`const` correctness throughout. Pass by `const&`, return by value for small
structs like `Vec3`. RAII everywhere; no raw owning pointers in the core. If
ownership is not obvious from the type, restructure rather than document it.

## Logging

`RC_LOG(Category, Level, "...")` in the core; `UE_LOG(LogRC..., ...)` in the
engine module. Never `printf`, never `UE_LOG(LogTemp, ...)`, never `PrintString`.

Categories: `Core` / `Physics` / `Aero` / `Propulsion` / `Input` / `Test`, which
map onto `LogOpenRC` / `LogRCPhysics` / `LogRCAero` / `LogRCPropulsion` /
`LogRCInput` / `LogRCTest`.

Log at `Error` only for something that breaks the simulation. A per-step log at
240 Hz is a bug regardless of level.

## Abstraction

Prefer a small concrete class over an interface with one implementation. Add the
interface when the second implementation exists, not in anticipation of it. The
exceptions, where the second implementation is certain, are the HID backend, the
coefficient source (analytic vs. tabulated) and the log sink.

## Tests

Every physics behaviour worth naming gets a test that states the expected value
and where it came from. `RC_CHECK_NEAR(actual, expected, tolerance)` — not a
loose bound when an analytic value is available. A test with zero checks on the
happy path is a test that can pass vacuously; assert that it examined something.

Sign conventions get their own tests. They are cheap and they are the failures
that cost days.

## Comments

Comment the *why*. The what is in the code, and the how is in `Docs/`.

Worth a comment: a coefficient's provenance, why an approximation is acceptable
here, a sign convention, a unit at a boundary, a tuning value and what it changes.

Not worth a comment: restating an assignment.
