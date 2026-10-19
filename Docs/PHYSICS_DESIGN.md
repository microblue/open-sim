# OpenRC Simulator — Flight Physics Design

Everything here is in SI units and in the frames defined in `ARCHITECTURE.md §3`.

---

## 1. Why an RC simulator is not a scaled-down airliner simulator

Three differences drive nearly every modelling decision:

**Low Reynolds number.** A 1.5 m trainer cruising at 15 m/s with a 0.22 m chord
runs at Re ≈ 2×10⁵. A light aircraft runs an order of magnitude higher, an
airliner three. In that regime the boundary layer separates earlier and more
abruptly, maximum lift coefficient is lower, profile drag is higher, and both
depend strongly on Re. Coefficients that are safely Re-independent for full-scale
aircraft are not for us.

**Enormous thrust-to-weight with a huge propeller relative to the airframe.** The
propeller wake washes a significant fraction of the wing root and almost the
entire tail. A powered RC trainer has usable elevator and rudder authority at
airspeeds where an unpowered one has none. Reaction torque is large enough to
roll the aircraft on takeoff.

**Very low inertia.** The aircraft responds to gusts and control inputs on a
timescale of tenths of a second. Gust response is not a background texture; it is
a thing the pilot actively flies against.

---

## 2. The aircraft is a collection of surfaces, not a set of coefficients

The rejected approach:

```
CL_aircraft = f(alpha)      ← wrong for this project
CD_aircraft = f(alpha)
Cm_aircraft = f(alpha)
```

A whole-aircraft polar cannot produce a wing dropping at the stall, cannot make a
snap roll fall out of the equations, and cannot represent a rudder working while
an aileron is stalled.

The approach used here: the airframe is decomposed into **aerodynamic sections**,
each of which is an independent lifting element.

```
Left wing        4 sections   (root → tip)
Right wing       4 sections   (root → tip)
Horizontal tail  2 sections   (left, right)
Vertical tail    1 section
Fuselage         1 body element (drag, side force, weak destabilising moment)
```

Section count is data, not code. More sections cost linearly and buy resolution
in spanwise stall progression; eight per wing is the practical ceiling before the
returns disappear.

Each section carries:

| Property | Symbol | Unit |
|---|---|---|
| position of the aerodynamic centre relative to CG, body axes | **r** | m |
| orientation (incidence, dihedral, sweep) as a body→section rotation | **q_sec** | — |
| reference area | S | m² |
| mean chord | c | m |
| span of the section | b | m |
| airfoil (a coefficient source, see §6) | — | — |
| attached control surface and its chord fraction | — | — |

---

## 3. Local airflow — the part that makes it feel like an airplane

A section must never be evaluated against the aircraft's centre-of-gravity
velocity. Its own local flow is what matters:

```
V_local(body) =  V_body                       aircraft velocity, body axes
              +  Ω × r                        rotation about the CG
              −  V_wind(body)                 steady wind + gust + turbulence
              +  V_propwash(r)                propeller-induced flow at r
```

The `Ω × r` term is not a refinement. It **is** roll damping, pitch damping and
yaw damping. A rolling aircraft sees more angle of attack on the descending wing
and less on the ascending one, which opposes the roll. Get this term right and
damping derivatives appear for free; leave it out and you have to fake them.

From the local flow, in the section's own frame:

```
V     = |V_local|
alpha = atan2(w_sec, u_sec)                 angle of attack
beta  = asin(clamp(v_sec / V, −1, 1))       sideslip
q     = ½ ρ V²                              dynamic pressure
Re    = ρ V c / μ                           Reynolds number
```

`V` below ~0.1 m/s is treated as zero force rather than divided by.

---

## 4. Forces on a section

```
L = q · S · C_L(alpha, Re, delta)          perpendicular to V_local
D = q · S · C_D(alpha, Re, delta)          along −V_local
Y = q · S · C_Y(beta)                      side force, mainly for the fin
M = q · S · c · C_m(alpha, Re, delta)      pitching moment about the section AC
```

The lift direction is perpendicular to the local flow **in the section's lift
plane** — not perpendicular to the aircraft's velocity, and not "up". For a
section whose flow has a large spanwise component this distinction matters.

Accumulation into the rigid body:

```
F_total = Σ Fᵢ
M_total = Σ (rᵢ × Fᵢ) + Σ Mᵢ
```

Both go into `ForceAccumulator` in body axes; the integrator never sees the
individual sections.

---

## 5. Stall — local, not global

Forbidden:

```cpp
if (airspeed < stallSpeed) { stalled = true; }     // never
```

Stall is a property of a **section's local angle of attack**, and different
sections reach it at different times. That single fact produces, with no extra
code:

- **wing drop** — the inboard section of one wing stalls first because a small
  sideslip or roll rate raised its local alpha
- **snap roll** — full elevator plus rudder stalls one wing while the other flies
- **spin** — one wing stays stalled while the other unstalls, sustaining autorotation
- **tip stall vs. root stall** — a function of the geometric washout you put in
  the aircraft definition

### Coefficient shape

```
        C_L
         │        ┌──╮  peak near alpha_stall
         │      ╱    ╲
         │    ╱       ╲___  post-stall plateau
         │  ╱
    ─────┼╱──────────────────── alpha
       ╱ │
```

Three regions, blended smoothly so there is no discontinuity in the derivative
(a kink here shows up as a buzz in the stick):

1. **Attached**, `|alpha| < alpha_stall − Δ`
   `C_L = C_L0 + a₀ · alpha`, with `a₀` corrected for finite aspect ratio.

2. **Stall break**, within `Δ` of `alpha_stall`
   Blend from the attached curve to the separated curve with a smooth-step. The
   width `Δ` is what makes a stall gentle or vicious, and is a per-airfoil tuning
   parameter. A trainer wants a wide `Δ`; a pattern ship wants a narrow one.

3. **Separated**, beyond the stall
   Flat-plate behaviour: `C_L ≈ 2 sin(alpha) cos(alpha)`,
   `C_D ≈ C_D_max · sin²(alpha)`, valid all the way to ±180° so that a tumbling
   aircraft still produces sane forces.

Drag through the same regions:

```
C_D = C_D0(Re)  +  C_L² / (π · AR · e)  +  C_D_separated(alpha)
      profile      induced                 rises sharply past the break
```

### Hysteresis

Real separation reattaches at a lower alpha than it detaches. A single state bit
per section (`separated`) with a reattachment angle a couple of degrees below the
stall angle reproduces the "have to unload properly to recover" behaviour that
matters for training. Cheap, and physically motivated.

---

## 6. Reynolds number

```
Re = ρ V c / μ            μ ≈ 1.789×10⁻⁵ Pa·s at 15 °C
```

`Re` is computed per section per step and passed into the coefficient lookup.
V0.1 seeds `C_L` and `C_D` from analytic curves with a Re correction; the
architecture takes `C(alpha, Re)` as a `Table2D` from the start, so replacing the
seed with XFoil output or wind-tunnel data is a data change, not a code change.

Approximate corrections used until real polars are in:

```
C_L_max(Re)  scales with log(Re/Re_ref)   — lower Re, lower peak lift
C_D0(Re)     ∝ Re^(−0.2)ish               — lower Re, higher profile drag
alpha_stall  shrinks slightly at low Re
```

Never assume `C(alpha)` alone. A 1.5 m trainer flying slowly on final is at a
meaningfully different Re than the same aircraft in a fast pass.

---

## 7. Control surfaces

Aileron, elevator, rudder, optional flap. A deflection changes the section's
coefficients, not just a moment:

```
ΔC_L = a_delta · delta · effectiveness(chord fraction)
ΔC_D = k · delta²                              deflected surfaces cost drag
ΔC_m = m_delta · delta
alpha_zero_lift shifts by −delta · tau         camber change
```

Effectiveness `tau` follows the standard thin-airfoil relation with the
control-to-section chord ratio, and is reduced when the section is separated — a
stalled wing's aileron does very little, which is exactly the lesson a trainee
needs to learn.

Per-channel processing, all of it in `RCPhysics/Input/`:

```
raw HID axis
  → calibration (min / centre / max, from the wizard)
  → deadzone
  → reverse
  → expo          y = (1−e)·x + e·x³        (the standard RC curve)
  → dual rate     scale
  → trim          offset
  → servo travel  ±degrees, asymmetric allowed
  → surface deflection [rad]
```

**Raw Mode** bypasses expo/rate/trim entirely for pilots who prefer their
transmitter's own mixing. Calibration and reverse always apply.

---

## 8. Propulsion

```
throttle (0–1)
   → ESC       duty cycle, current limit
   → Motor     KV, winding resistance Rm, no-load current I0
   → Propeller diameter D, pitch P
   → thrust, reaction torque, propwash
```

### Electrical

```
V_bus   = V_battery − I · R_internal
V_motor = duty · V_bus
omega   = (V_motor − I·Rm) · Kv_rad          Kv_rad = KV · 2π/60
Q_motor = (I − I0) / Kv_rad                  motor torque
```

Solved for the operating point where motor torque equals propeller torque.

### Propeller

V0.1 uses momentum theory with empirical coefficients:

```
J  = V_axial / (n · D)                       advance ratio, n in rev/s
Ct = Ct(J)                                   thrust coefficient
Cq = Cq(J)                                   torque coefficient
T  = Ct · ρ · n² · D⁴
Q  = Cq · ρ · n² · D⁵
```

`Ct(J)` and `Cq(J)` are `Table1D`, seeded analytically from diameter and pitch
and replaceable with APC/UIUC propeller data without touching code. Thrust falls
to zero near `J = P/D`, which is what makes a model stop accelerating at its
pitch speed.

### Reaction torque

`−Q` about the propeller axis is applied to the airframe. This is what produces
the left roll on a hard throttle application, and torque roll in a hover.

### Propwash

The wake is a cone of accelerated air behind the disc:

```
V_induced = ½ ( √(V² + 2T/(ρ·A_disc)) − V )      momentum theory
V_wake    = V + 2·V_induced                       fully developed, downstream
```

Any section whose position falls inside the expanding wake cone adds `V_wake`
along the propeller axis (plus a swirl component) to its local airflow. In
practice that is the wing root, both horizontal tail sections and the fin.

This is the single most important RC-specific effect in the sim. It is why:

- elevator and rudder still bite at near-zero airspeed with the throttle open
- chopping the throttle on final causes an immediate, noticeable loss of pitch authority
- the aircraft yaws on takeoff (propwash swirl over the fin, plus P-factor)

### P-factor and gyroscopic precession

P-factor: at positive alpha the descending blade meets a higher local angle of
attack than the ascending one, moving the thrust centre sideways and producing a
yawing moment. V0.1 uses a first-order approximation proportional to
`T · sin(alpha) · D`.

Gyroscopic precession: the spinning propeller resists changes in attitude,
producing `M = Ω_aircraft × H_prop`. The propeller's angular momentum is already
tracked, so this term is exact and cheap. Architecture is in place; V0.1 may
simplify.

---

## 9. Mass and inertia

Mass alone is not enough. The full tensor is supported:

```
mass, CG position, Ixx Iyy Izz Ixy Ixz Iyz
```

An aircraft definition may give the tensor directly. If it does not, it is
estimated from the geometry — wing panels, fuselage as a slender body, tail
surfaces, battery and motor as point masses — which is accurate enough to fly and
gives a sane starting point to tune from.

CG position is a first-class tuning parameter, because moving it is the single
most effective way to change how an RC model handles, and a trainee needs to feel
the difference between a nose-heavy and a tail-heavy setup.

---

## 10. Ground handling

A single capsule sliding on the terrain is not acceptable. Each wheel is:

```
suspension :  F_normal = k·compression + c·compression_rate
rolling    :  F_roll   = −Crr · F_normal · direction_of_travel
lateral    :  F_side   = −min(μ·F_normal, k_side·slip_velocity) · lateral_direction
steering   :  nose wheel heading follows the rudder channel
```

The lateral force saturating at `μ · F_normal` is what allows a **ground loop**:
once the tyre breaks away, there is nothing left to stop the yaw, and the pilot
has to catch it with rudder before it develops. That behaviour has to be
available or ground handling teaches nothing.

Godot's Jolt physics backend is used for the collision query (where is the
ground, what is its normal) and for airframe-to-terrain contact after a crash.
The wheel forces themselves are ours, computed in `Physics/Ground/` and fed
through the same `ForceAccumulator` as everything else.

### Ground effect

Within about half a span of the ground, the wing's mirror image in the surface
cancels part of its own trailing vortices. The section model already carries the
induced flow inside its aspect ratio - in the finite-wing lift slope and in the
induced drag - so ground effect is one number per section, the share of
free-air induced flow it still sees:

```
phi(h/b) = (16 h/b)^2 / (1 + (16 h/b)^2)          McCormick, image vortex
AR_effective = AR / phi
```

`h` is each section's own height, so a banked aircraft has its low wing deeper
in ground effect than its high one and gets a rolling moment towards wings level
- the one a pilot feels in a crosswind flare. The tail's downwash is scaled by
the same factor at the tail's height: less downwash means more tail lift and the
nose-down change of trim that makes a flare need more elevator in its last
few centimetres. CL max is unchanged; only the angle a given lift needs.

The ground is sampled once, under the CG, and skipped entirely above two spans,
where `phi` is 1 to four decimal places. `aerodynamics.ground_effect_scale` in
the aircraft file scales it, and 0 turns it off; the tests use that to measure
what it adds. Measured on the Trainer at a tenth of a span: the same lift for
0.43 deg less angle of attack and 5 % less drag; a high wing, a modest float.

---

## 11. Environment

**Atmosphere** — ISA: density, pressure, temperature and dynamic viscosity as a
function of altitude. Viscosity feeds Reynolds number, so it is not optional.

**Wind** — a steady vector, plus:

- **gusts**: a 1−cos ramp of configurable amplitude and duration, arriving at
  seeded random intervals
- **turbulence**: band-limited noise, seeded, with a length scale rather than a
  frequency so that the aircraft's response scales correctly with airspeed
- **thermals** (later): columns of rising air, for slope and glider work

Wind is sampled **per section**, so a wingspan-scale gust rolls the aircraft
rather than just displacing it. Everything stochastic takes an explicit seed:
the same seed reproduces the same air, which is what makes the regression suite
possible.

The windsock, the vegetation and the aircraft all read the same wind field. If
they ever disagree, the sim is lying to the pilot about the one thing they most
need to read from across the field.

---

## 12. Integration

```
linear    a_world  = R_wb · F_body / m + g_world
angular   ω̇_body  = I⁻¹ ( M_body − ω × (I ω) )
attitude  q̇       = ½ q ⊗ (0, ω_body)
```

**Semi-implicit (symplectic) Euler at 240 Hz is the default.** It does not pump
energy over a long flight, and it stays well behaved when the force field is
discontinuous — wheel touchdown, stall break, a gust arriving. Its truncation
error on a trainer's fastest mode is far below the uncertainty in the aero data.

**RK4 is available** and is used by the validation suite to demonstrate that
results are step-rate independent. It calls the force model four times per step,
which is affordable precisely because that model is a pure function of state. It
is not used across contact discontinuities.

Attitude integration uses the exponential map, so the quaternion is unit-norm by
construction rather than by repeated renormalisation. Verified over 30 simulated
minutes in `Tests/Dynamics/TestRigidBody.cpp`.

Any step that produces a non-finite state is rejected, the previous state is
restored, and an error is logged. A NaN reaching the renderer ends the session.

---

## 13. Validation targets — Trainer 1500

The flight model is not "done" when it feels right. It is done when it hits
measurable targets, and the regression suite fails the build when it stops
hitting them.

The targets live in the aircraft definition itself
(`Data/Aircraft/Trainer1500.json`, `validation_targets`), so the regression suite
reads them from data rather than hard-coding them.

### Status: measured and locked (Milestone 5)

Every number below was **measured** by flying the shipped definition in
`Tests/Regression/TestTrainerTargets.cpp`, and every one is locked. A physics
change that moves any of them outside its tolerance fails the build.

| Measurement | Value | Tolerance | How it is measured |
|---|---|---|---|
| Best glide ratio, power off | **8.02 : 1** | ±8 % | maximum of the trimmed glide polar |
| Speed for best glide | **8.39 m/s** | ±8 % | the polar point that achieves it |
| Minimum sink rate | **0.99 m/s** | ±10 % | minimum of the same polar |
| Stall speed, 1 g | **7.89 m/s** | ±5 % | slowest trimmed speed before 25 % of the wing separates |
| Full-aileron roll rate at cruise | **152 °/s** | ±10 % | one second of full aileron |
| Static thrust, full throttle | **13.78 N** | ±5 % | steady operating point at zero airspeed |
| Level speed at 60 % throttle | **12.42 m/s** | ±10 % | flown level until the speed settles |
| Takeoff ground roll on grass | **11.57 m** | ±15 % | brake release to wheels-off, rotating at 11.5 m/s |

Derived: maximum lift coefficient **1.077**, thrust-to-weight **1.04**,
`pb/2V` = **0.13**.

Seven of the eight first-principles seeds proved good to within their tolerance.
The one that did not was cruise speed, and the reason was a definition rather
than an error: the seed assumed a 16 m/s cruise, whereas the measurement is the
speed the aircraft holds at 60 % throttle, which is 12.4 m/s.

### Two things the calibration changed

**The propeller.** A 1000 KV motor swinging the brief's 11×6 on 3S draws 35 A
and 417 W — past the current rating of any motor in that class — and gives a
thrust-to-weight of 1.18 rather than the 0.9–1.1 the brief asks for. That is the
classic over-prop. A 10×5 on the same motor gives 13.8 N at 27.5 A and T/W 1.04,
which is what the brief actually wants and what real 1.5 m trainers use.

**The stall speed.** At 1.35 kg over 0.32 m² the wing loading is 41 N/m², and a
low-Reynolds flat-bottom section on a washed-out rectangular wing reaches
C_Lmax ≈ 1.08. That gives 7.9 m/s, the bottom of the brief's 8–10 m/s band
rather than the middle. Reaching 9.5 m/s would need C_Lmax ≈ 0.85, which is not
what this airfoil does. The number was left where the physics puts it; if a
higher stall speed is wanted for training reasons the honest lever is mass or
wing area, both one line of JSON.
