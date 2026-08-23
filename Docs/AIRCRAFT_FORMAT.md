# OpenRC Simulator — Aircraft Definition Format

An aircraft is **data**. There is no `class Trainer`, no `class Warbird`, no
`class Glider`. A new flyable model is a 3D mesh plus a JSON file:

```
mesh  +  aircraft.json  =  new flyable airplane
```

Definitions live in `Data/Aircraft/*.json`. They are loaded by
`RCPhysics/Aircraft/AircraftLoader`, converted to SI immediately, validated, and
turned into an `AircraftDefinition`. Nothing downstream ever sees an inch.

## Conventions

- **Positions** are metres in body FRD axes (X nose, Y right wing, Z down),
  relative to the **centre of gravity**, unless a field name says otherwise.
- **Angles** in the file are degrees, because that is how a modeller thinks. They
  become radians at load time.
- **Unit suffixes are mandatory** on every numeric field: `_m`, `_m2`, `_kg`,
  `_deg`, `_in`, `_mah`, `_a`, `_v`, `_ohm`, `_rpm_per_volt`, `_mps`, `_n_per_m`.
  A field without a suffix is a bug in the definition, and the loader says so.
- `//` line comments, `/* */` block comments and trailing commas are accepted.
  These files are edited by hand during tuning; that matters more than strict
  JSON conformance.
- Any field may be omitted. The loader supplies a documented default and logs at
  Verbose which defaults it used. A partially specified aircraft still flies.

## Top-level shape

```jsonc
{
  "format_version": 1,
  "name": "Trainer 1500",
  "description": "...",

  "mass":            { ... },   // mass, CG, inertia
  "reference":       { ... },   // wing area / span / MAC used for coefficients
  "airfoils":        { ... },   // named 2D coefficient sets
  "aero_surfaces":   [ ... ],   // the lifting sections
  "fuselage":        { ... },   // non-lifting body drag
  "propulsion":      { ... },   // battery, ESC, motor, propeller, mount, propwash
  "landing_gear":    [ ... ],
  "control_channels":{ ... },   // travel, expo, dual rate defaults
  "spawn":           { ... },   // speeds for the air / approach start modes
  "validation_targets": { ... } // consumed by the regression suite
}
```

---

## `mass`

```jsonc
"mass": {
  "mass_kg": 1.35,

  // Where the CG sits relative to the mesh origin. Physics uses the CG as the
  // body-frame origin, so this exists only to place the mesh correctly.
  "cg_offset_from_mesh_origin_m": [0.0, 0.0, 0.0],

  // Optional. Omit and the loader estimates the tensor from the geometry:
  // wing panels as thin plates, fuselage as a slender body, motor and battery
  // as point masses. The estimate is good enough to fly and to tune from.
  "inertia": {
    "ixx_kg_m2": 0.055,   // roll
    "iyy_kg_m2": 0.082,   // pitch
    "izz_kg_m2": 0.128,   // yaw
    "ixz_kg_m2": 0.004    // the only product of inertia a symmetric airframe has
  }
}
```

## `reference`

The areas and lengths that non-dimensional coefficients are referred to. They do
**not** have to equal the sum of the section areas, but for a sane definition they
will.

```jsonc
"reference": {
  "wing_area_m2": 0.32,
  "wingspan_m": 1.50,
  "mean_aerodynamic_chord_m": 0.213
}
```

## `airfoils`

Named **2D** section data. The loader applies the finite-wing correction using
each surface's own aspect ratio, so these are pure airfoil numbers.

```jsonc
"airfoils": {
  "trainer_flat_bottom": {
    "cl_zero_alpha": 0.30,          // C_L at alpha = 0 (camber)
    "cl_alpha_per_rad": 5.70,       // 2D lift-curve slope
    "cl_max": 1.20,
    "alpha_stall_deg": 13.0,
    "stall_blend_deg": 5.0,         // width of the break. Wide = gentle.
    "reattach_hysteresis_deg": 2.5, // separation reattaches this much lower
    "cd_min": 0.012,                // profile drag at the drag bucket
    "cd_alpha_quadratic": 0.012,    // profile drag growth with alpha
    "cd_separated_max": 1.30,       // flat-plate drag deep in the stall
    "cm_quarter_chord": -0.075,
    "oswald_efficiency": 0.85,
    "reference_reynolds": 200000    // the Re the numbers above were taken at
  }
}
```

Instead of the analytic parameters, an airfoil may supply tables. When present
they win, and the analytic fields are ignored:

```jsonc
"naca0009_measured": {
  "alpha_table_deg": [-180, -20, -12, 0, 12, 20, 180],
  "reynolds_table":  [50000, 100000, 200000],
  // row-major: one row per alpha, one column per Reynolds entry
  "cl_table": [ /* 7 x 3 values */ ],
  "cd_table": [ /* 7 x 3 values */ ],
  "cm_table": [ /* 7 x 3 values */ ]
}
```

This is the hook for XFoil output and wind-tunnel data. The interpolation is
`Table2D`; nothing in the aero code changes.

## `aero_surfaces`

The heart of the format. One entry per **section**, not per wing.

```jsonc
{
  "name": "wing_right_outer",
  "role": "wing",                 // wing | horizontal_tail | vertical_tail
  "airfoil": "trainer_flat_bottom",

  // Aerodynamic centre (quarter chord) relative to the CG, body FRD.
  "position_m": [0.009, 0.656, -0.125],

  "area_m2": 0.040,
  "chord_m": 0.213,
  "span_m":  0.1875,

  "incidence_deg": 2.0,           // rigging angle relative to the body X axis
  "dihedral_deg": 3.5,            // positive raises the tip
  "twist_deg": -1.5,              // washout. Negative = tip at lower alpha.
  "sweep_deg": 0.0,

  // Aspect ratio used for the finite-wing correction and induced drag. Omit and
  // the loader derives it from the parent surface's total span and area.
  "effective_aspect_ratio": 7.03,

  "control_surface": {
    "channel": "aileron",         // aileron | elevator | rudder | flap
    "chord_fraction": 0.25,       // hinge line as a fraction of section chord
    "span_fraction": 1.0,         // how much of the section it covers
    "direction": 1.0              // +1 / -1; the left wing's aileron is -1
  },

  // Does the propeller wake reach this section? The loader can compute this
  // from the wake cone, but an explicit value overrides it.
  "in_propwash": false
}
```

`role` selects a small amount of behaviour: `vertical_tail` sections generate
their force from sideslip rather than angle of attack, and are excluded from the
symmetric-stall bookkeeping.

## `fuselage`

Not a lifting surface. Contributes drag, side force, and the mildly
destabilising yawing moment a body ahead of the CG produces.

```jsonc
"fuselage": {
  "position_m": [0.05, 0.0, 0.0],
  "length_m": 1.05,
  "frontal_area_m2": 0.011,
  "side_area_m2": 0.055,
  "cd_frontal": 0.35,
  "cd_side": 0.60,
  "cn_beta_per_rad": -0.06     // negative = destabilising, as a real body is
}
```

## `propulsion`

```jsonc
"propulsion": {
  "battery": {
    "cell_count": 3,
    "nominal_cell_voltage_v": 3.70,
    "full_cell_voltage_v": 4.15,
    "empty_cell_voltage_v": 3.30,
    "capacity_mah": 2200,
    "internal_resistance_ohm": 0.015
  },
  "esc": { "max_current_a": 40.0, "efficiency": 0.96 },
  "motor": {
    "kv_rpm_per_volt": 1000,
    "resistance_ohm": 0.085,
    "no_load_current_a": 0.9,
    "max_current_a": 30.0
  },
  "propeller": {
    "diameter_in": 11.0,
    "pitch_in": 6.0,
    "blade_count": 2,
    "moment_of_inertia_kg_m2": 1.5e-5,
    "rotation": "clockwise"        // seen from behind, i.e. from the pilot
    // optional: "advance_ratio_table", "ct_table", "cq_table" for APC/UIUC data
  },
  "mount": {
    "position_m": [0.35, 0.0, -0.01],
    "down_thrust_deg": 2.0,        // nose-down tilt of the thrust line
    "right_thrust_deg": 2.0        // offsets the torque roll and P-factor yaw
  },
  "propwash": {
    "enabled": true,
    "cone_half_angle_deg": 6.0,    // wake expansion behind the disc
    "swirl_factor": 0.35,          // fraction of the swirl that reaches the fin
    "strength": 1.0                // global scale, for tuning only
  }
}
```

## `landing_gear`

```jsonc
{
  "name": "main_right",
  "position_m": [-0.06, 0.16, 0.148],   // wheel centre at full extension
  "radius_m": 0.028,
  "spring_n_per_m": 2000.0,
  "damper_ns_per_m": 50.0,
  "max_travel_m": 0.020,
  "friction_static": 0.70,              // grass
  "friction_dynamic": 0.55,
  "rolling_resistance": 0.12,           // grass is high; it dominates takeoff roll
  "steerable": false,
  "steering_channel": "rudder",
  "max_steering_deg": 0.0,
  "brake_channel": null
}
```

## `control_channels`

Defaults for this airframe. The pilot's own transmitter settings and the
simulator's per-channel UI override them.

```jsonc
"control_channels": {
  "aileron":  { "max_deflection_deg": 20.0, "expo": 0.25, "dual_rate": 1.0, "differential": 0.30 },
  "elevator": { "max_deflection_deg": 22.0, "expo": 0.30, "dual_rate": 1.0 },
  "rudder":   { "max_deflection_deg": 25.0, "expo": 0.20, "dual_rate": 1.0 },
  "throttle": { "idle_fraction": 0.0, "expo": 0.0 }
}
```

`differential` reduces the down-going aileron's travel, which is how a real
trainer avoids adverse yaw.

## `spawn`

```jsonc
"spawn": {
  "cruise_speed_mps": 16.0,
  "approach_speed_mps": 11.0,
  "air_start_altitude_m": 50.0
}
```

## `validation_targets`

Read directly by the regression suite (`Tests/Regression/`). Keeping them beside
the aircraft rather than in test code means a new aircraft brings its own
acceptance criteria.

```jsonc
"validation_targets": {
  "static_thrust_n":        { "value": 13.78, "tolerance": 0.05, "locked": true },
  "stall_speed_mps":        { "value": 7.89,  "tolerance": 0.05, "locked": true },
  "glide_ratio":            { "value": 8.02,  "tolerance": 0.08, "locked": true },
  "best_glide_speed_mps":   { "value": 8.39,  "tolerance": 0.08, "locked": true },
  "min_sink_rate_mps":      { "value": 0.99,  "tolerance": 0.10, "locked": true },
  "roll_rate_deg_per_s":    { "value": 152.3, "tolerance": 0.10, "locked": true },
  "cruise_speed_mps":       { "value": 12.42, "tolerance": 0.10, "locked": true },
  "takeoff_ground_roll_m":  { "value": 11.57, "tolerance": 0.15, "locked": true }
}
```

`locked: false` means the value is a first-principles seed, not a measurement:
the suite reports a deviation but does not fail the build. `locked: true` means
it was measured on the flying model, and a regression fails the build. The
Trainer 1500's targets were all measured and locked at Milestone 5.

Adding a target that nothing measures, or measuring something with no target,
both fail - `TrainerTargets.TheAircraftFileDeclaresEveryTargetTheSuiteMeasures`
keeps the file and the suite from drifting apart.

---

## Hot reload

The loader is designed to be re-run at runtime. Edit the JSON, press the reload
key, and the aircraft rebuilds in place with the current position and velocity
preserved. This is the main tool for tuning a flight model, so it is not an
afterthought — the constraint it imposes is that `AircraftDefinition` owns no
engine resources and can be rebuilt without touching the actor.

## Validation on load

The loader rejects, rather than silently accepting:

- a section with non-positive area, chord or span
- an `airfoil` name with no matching entry
- a control surface with `chord_fraction` outside (0, 1)
- an inertia tensor that is not positive definite
- a battery, motor or propeller with a non-physical value
- an unknown `format_version`

Every rejection names the file, the section and the field. Tuning a flight model
means editing this file dozens of times a session; a vague error message costs
more than the check does.
