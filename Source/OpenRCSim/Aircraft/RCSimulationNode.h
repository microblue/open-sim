// OpenRC Simulator - the node that runs the fixed-step flight simulation.
//
// This is the seam between Godot and the flight model. Its whole job is:
//
//     render frame  ->  sample the sticks
//                   ->  SimulationClock  ->  N fixed physics steps
//                   ->  one transform write
//
// It computes no forces of its own. The aerodynamics, the propulsion and the
// ground model all live in RCPhysics, where they are tested without an engine.
// Nothing here may convert a frame by hand either - see Bridge/RCGodotConversion.h.
#pragma once

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include "RCPhysics/Aircraft/Aircraft.h"
#include "RCPhysics/Core/Clock/SimulationClock.h"
#include "RCPhysics/Input/ChannelTypes.h"
#include "RCPhysics/Physics/Ground/GroundContact.h"
#include "RCPhysics/Physics/Ground/LandingGear.h"
#include "RCPhysics/Physics/Ground/TerrainField.h"
#include "RCPhysics/Aircraft/FailureModel.h"
#include "RCPhysics/Core/FlightRecorder.h"
#include "RCPhysics/Physics/Environment/LiftField.h"
#include "RCPhysics/Physics/Ground/TerrainScatter.h"
#include "RCPhysics/Physics/Propulsion/PowerSystem.h"

namespace openrc
{
class RCSimulationNode : public godot::Node3D
{
    GDCLASS(RCSimulationNode, godot::Node3D)

public:
    /** Where the aircraft starts. */
    enum SpawnMode
    {
        SPAWN_RUNWAY = 0,   ///< on the ground, stopped
        SPAWN_AIR    = 1,   ///< at altitude, at cruise speed
        SPAWN_APPROACH = 2  ///< on final, at approach speed
    };

    RCSimulationNode();
    ~RCSimulationNode() override = default;

    void _ready() override;
    void _process(double deltaSeconds) override;

    // ---------------------------------------------------------- the aircraft --

    /** Path to the aircraft definition. A bare relative path is resolved
     *  against the repository root, one level above the Godot project, so that
     *  Data/ stays the single source of truth for both this and the offline
     *  validation suite. */
    void set_aircraft_definition(const godot::String& path);
    godot::String get_aircraft_definition() const;

    /** Re-read the definition and rebuild the flight model in place, keeping
     *  the current position and velocity. This is the tuning loop: edit the
     *  JSON, press a key, feel the difference. */
    /** Locate a file under Data/, whether running from the repository or from
     *  an installed build. See the implementation for the two layouts. */
    godot::String resolve_data_path(const godot::String& relative) const;

    // ------------------------------------------------------------ terrain --

    /** Surface height in Godot axes (metres up) at a Godot XZ position. */
    double get_terrain_height(double x, double z) const;

    /** Sea level and the flying field's elevation, both in Godot metres up. */
    double get_sea_level_y() const;
    double get_field_elevation_y() const;

    /** Build one square of terrain as a mesh, in C++ because a chunk is tens of
     *  thousands of vertices and a per-vertex call across the binding would
     *  dominate the frame. Returns geometry centred on the origin, to be placed
     *  by the caller; vertex colour carries the surface albedo so biomes blend
     *  across a triangle instead of stepping. */
    godot::Ref<godot::ArrayMesh> build_terrain_chunk(double centre_x, double centre_z,
                                                     double size, int resolution) const;

    /** Everything standing on one square of ground: what it is, where, which
     *  way round and how big. Returned as parallel arrays rather than objects
     *  so the renderer can drop them straight into MultiMesh buffers, and
     *  computed here because a cell is hundreds of points and each one needs
     *  the terrain sampled. Godot axes throughout. */
    godot::Dictionary scatter_detail(double centre_x, double centre_z,
                                     double size, int count, int seed,
                                     int layer) const;

    /** Terrain seed, so a session can be reproduced. */
    void set_terrain_seed(int seed);

    /** Replace the world's solid obstacles (trees): flat x, z, radius, height
     *  quads in Godot world metres. Rebuilds the physics collision grid. */
    void set_tree_obstacles(const godot::PackedFloat32Array& obstacles);

    /** Surface height (terrain plus trees) above sea level at a Godot XZ
     *  point, for verification. */
    double get_surface_height_at(double x, double z) const;
    int  get_terrain_seed() const;

    // ------------------------------------------------------------ failures --
    //
    // The part a toy does not have, and where most of the training value is.
    // Nobody needs practice at flying a model that works.

    /** Break something now. `kind` matches rc::FailureKind; `channel` matches
     *  RCInputNode's channel constants and is used only by the surface
     *  failures. */
    void induce_failure(int kind, int channel);

    /** Everything works again. Also called by reset. */
    void clear_failures();

    /** What is wrong, as a sentence a pilot can read, or empty. */
    godot::String get_failure_text() const;
    int  get_failure_kind() const;
    bool has_failure() const;

    /** Chance per minute of a random failure. Zero - the default - means
     *  failures only happen when asked for, which is how a lesson uses them. */
    void set_failure_rate_per_minute(double rate);
    double get_failure_rate_per_minute() const;

    /** What the receiver does when the link goes: 0 holds the last commands,
     *  1 centres everything. Both are configurations people fly, and they fail
     *  very differently. */
    void set_failsafe_mode(int mode);
    int  get_failsafe_mode() const;

    // -------------------------------------------------------------- replay --
    //
    // The most useful thing a simulator can give a learner is the chance to see
    // what they just did from outside. A pilot who has cartwheeled a model on
    // landing has no idea why; the same landing watched from the wingtip,
    // slowly, answers it in one pass.

    /** Seconds of flight available to scrub through, and where in it. */
    double get_replay_duration() const;
    double get_replay_earliest() const;
    double get_replay_latest() const;

    /** Enter or leave replay. While replaying the physics does not advance and
     *  the aircraft is posed from the recording, so the world around it - wind,
     *  scenery, the camera - carries on as normal and can be looked around. */
    void set_replaying(bool replaying);
    bool get_replaying() const { return Replaying; }

    /** Where in the recording to show, in simulation seconds. */
    void set_replay_time(double seconds);
    double get_replay_time() const { return ReplayTime; }

    /** Step the replay by `delta` seconds at the current rate, and pose the
     *  aircraft from it. The frame loop calls this; a tool or a test that
     *  drives the simulation itself can call it directly. */
    void advance_replay(double delta);

    /** Run the simulation forward by `delta` seconds, exactly as the frame loop
     *  does. _process calls this; a tool or a test that drives the simulation
     *  itself calls it directly rather than trying to make the scene tree run
     *  frames on demand. */
    void advance(double delta);

    /** Playback rate. Negative runs it backwards; zero holds a frame. */
    void set_replay_speed(double speed);
    double get_replay_speed() const { return ReplaySpeed; }

    /** Jump to the moment of the crash, which is what anyone wants to see. */
    void replay_to_crash();

    /** Telemetry of the frame being shown, for the overlay. */
    godot::Dictionary get_replay_frame() const;

    /** The path the aircraft took, in Godot coordinates, for drawing a trace. */
    godot::PackedVector3Array get_flight_path(int max_points) const;

    // ------------------------------------------------------------- soaring --

    /** Vertical speed of the AIR at the aircraft [m/s, positive up]. This is
     *  what a variometer measures once the aircraft's own sink is taken out,
     *  and it is what a soaring pilot flies by. */
    double get_air_vertical_speed_mps() const;

    /** The same, split into where it came from, so the pilot can tell a thermal
     *  from a hillside. */
    double get_thermal_lift_mps() const;
    double get_slope_lift_mps() const;

    /** Netto: the air's motion with the aircraft's own sink rate removed, which
     *  is the number that says whether staying here is worth it. */
    double get_netto_mps() const;

    /** How strongly the ground beneath makes thermals, 0 to 1. What an
     *  experienced pilot reads off the landscape. */
    double get_ground_heating() const;

    /** Scale the day's thermal activity. Weather drives this: a windy afternoon
     *  works better than a still one, an overcast sky barely at all, and rain
     *  not at all. */
    void set_thermal_scale(double scale);
    double get_thermal_scale() const;

    void set_lift_enabled(bool enabled);
    bool get_lift_enabled() const;

    /** Reshape the world. A scene preset is these numbers and a sky; the biome
     *  rules never change, only the climate and the geology they read. Applying
     *  any of them invalidates every terrain chunk, so the renderer rebuilds. */
    void configure_terrain(const godot::Dictionary& settings);
    godot::Dictionary get_terrain_settings() const;

    bool reload_aircraft();

    bool is_aircraft_loaded() const { return AircraftLoaded; }
    godot::String get_aircraft_name() const;
    godot::String get_aircraft_description() const;

    // ------------------------------------------------- the aircraft's card --
    //
    // What a pilot wants to know before choosing one. Derived here rather than
    // in the UI so the numbers on the card are the numbers the flight model
    // uses - a specification sheet that disagrees with the aeroplane is worse
    // than none.

    double get_mass_kg() const;
    double get_wingspan_m() const;
    double get_wing_area_m2() const;
    double get_wing_loading_pa() const;
    double get_aspect_ratio() const;
    double get_battery_cells() const;
    double get_battery_capacity_mah() const;
    double get_motor_kv() const;
    double get_peak_power_w() const;
    double get_power_to_weight_w_per_kg() const;
    double get_cruise_speed_mps() const;
    double get_approach_speed_mps() const;

    /** True when the aeroplane is thrown rather than rolled: its propeller
     *  would strike the ground on its own gear. The brief says so, because a
     *  player who is handed a glider and told to take off will sit there with
     *  the throttle open wondering what is wrong. */
    bool is_hand_launched() const;

    /** Where the fuselage runs, in Godot axes: the nose and the tail, relative
     *  to the centre of gravity.
     *
     *  The visible model used to loft its fuselage between the most forward
     *  and most aft AERODYNAMIC sections, which on the trainer meant a nose
     *  9 mm ahead of the CG when the real one is 575 mm ahead. The propeller
     *  sits where the definition says it does, so it hung in the air a third
     *  of a metre off the front of the aeroplane. Invisible at flight scale,
     *  impossible to miss the moment there is a preview.
     *
     *  Returns Vector2(nose, tail) as Godot Z, so nose is the more negative. */
    godot::Vector2 get_fuselage_extent_z() const;

    /** The aircraft's measured performance, as the regression suite recorded
     *  it: glide ratio, stall speed, roll rate and the rest.
     *
     *  These are flown, not quoted. A specification sheet that disagrees with
     *  the aeroplane is worse than none, and these are the numbers the suite
     *  holds the aeroplane to. */
    godot::Dictionary get_performance() const;

    /** File stems of every aircraft in Data/Aircraft/, sorted. */
    godot::PackedStringArray list_aircraft() const;

    // -------------------------------------------------------- configuration --

    void set_physics_rate_hz(int rateHz);
    int  get_physics_rate_hz() const;

    void set_gravity_enabled(bool enabled);
    bool get_gravity_enabled() const;

    void set_spawn_mode(int mode);
    int  get_spawn_mode() const;

    void set_spawn_altitude_m(double altitude);
    double get_spawn_altitude_m() const;

    /** Where the aircraft appears, in Godot axes. Field layout is the scene's
     *  business, not the flight model's, so the strip threshold is set here
     *  rather than hard-coded in the simulation node. */
    void set_spawn_offset(const godot::Vector3& offset);
    godot::Vector3 get_spawn_offset() const;

    /** Initial heading in degrees, clockwise from north. */
    void set_spawn_heading_deg(double degrees);
    double get_spawn_heading_deg() const;

    void set_input_path(const godot::NodePath& path);
    godot::NodePath get_input_path() const;

    // ------------------------------------------------------------ the air ----

    void set_field_elevation_m(double metres);
    double get_field_elevation_m() const;

    void set_temperature_offset_c(double kelvin);
    double get_temperature_offset_c() const;

    /** Wind speed [m/s] and the direction it blows FROM [deg from North]. */
    void set_wind_speed_mps(double speed);
    double get_wind_speed_mps() const;

    void set_wind_direction_deg(double degrees);
    double get_wind_direction_deg() const;

    void set_gust_amplitude_mps(double amplitude);
    double get_gust_amplitude_mps() const;

    void set_turbulence_mps(double intensity);
    double get_turbulence_mps() const;

    /** Reseeding makes a run reproducible. */
    void set_wind_seed(int seed);
    int  get_wind_seed() const;

    /** 0..1. Drives the windsock and the vegetation so they agree with what the
     *  aircraft is feeling. */
    double get_gust_fraction() const;

    /** Wind velocity at the aircraft, in Godot axes [m/s]. */
    godot::Vector3 get_wind_vector() const;

    // ----------------------------------------------------------- telemetry ---

    double get_altitude_m() const;
    double get_ground_speed_mps() const;
    double get_airspeed_mps() const;
    double get_alpha_degrees() const;
    double get_beta_degrees() const;
    godot::Vector3 get_velocity_world() const;
    godot::Vector3 get_attitude_degrees() const;
    godot::Vector3 get_angular_velocity_degrees() const;

    double get_total_lift_n() const;
    double get_total_drag_n() const;
    /** Fraction of wing area whose flow has separated, 0..1. */
    double get_stalled_fraction() const;

    // --------------------------------------------------------- propulsion ---

    double get_rpm() const;
    double get_thrust_n() const;
    double get_motor_current_a() const;
    double get_bus_voltage_v() const;
    double get_electrical_power_w() const;
    /** 0..1. A LiPo holds up and then falls off a cliff, so this is what the
     *  pilot should be watching rather than voltage. */
    double get_battery_charge() const;
    /** Induced velocity at the propeller disc [m/s]; the wake carries twice
     *  this and it is what keeps the tail working at a standstill. */
    double get_induced_velocity_mps() const;

    // ------------------------------------------------------------- ground ---

    bool is_on_ground() const;
    double get_weight_on_wheels_n() const;
    int get_wheel_count() const;
    double get_wheel_compression_m(int index) const;
    bool is_wheel_skidding(int index) const;

    /** Non-empty once the aircraft has been broken. Reset clears it. */
    bool has_crashed() const;
    godot::String get_crash_reason() const;

    double get_simulated_time_s() const;
    int64_t get_total_steps() const;
    int64_t get_dropped_steps() const;

    godot::PackedFloat64Array get_channels() const;

    // ------------------------------------------------- per-section debug -----

    int get_section_count() const;
    godot::String get_section_name(int index) const;
    double get_section_alpha_degrees(int index) const;
    double get_section_separation(int index) const;
    double get_section_lift_n(int index) const;
    /** Section position relative to the CG, Godot axes [m]. */
    godot::Vector3 get_section_position(int index) const;
    /** Lift direction at the section, Godot axes, unit length. */
    godot::Vector3 get_section_lift_direction(int index) const;

    // ------------------------------------------------- geometry, for the mesh
    //
    // Exposed so the visible aircraft can be built from the same numbers the
    // physics integrates. A wing then cannot be drawn somewhere the
    // aerodynamics does not think it is.

    double get_section_span_m(int index) const;

    /** Control surface geometry and live deflection, so the visible model can
     *  hinge exactly what the flight model deflected. */
    /** Drive the controls directly when no transmitter node is wired up - the
     *  in-engine tests, a demo, a replay. Ignored while an input node is set. */
    void set_manual_channel(int channel, double value);
    void clear_manual_channels();

    bool   get_section_has_control(int index) const;
    /** Which transmitter channel moves this section's control surface:
     *  "aileron", "elevator", "rudder", "throttle", "flap" or "gear".
     *
     *  A downloaded airframe has no per-section geometry to hang a hinge off,
     *  so its control surfaces are cut out of the mesh and matched to the
     *  flight model BY CHANNEL. Without this the match would have to be made
     *  on section names, which is a coincidence of how the four definitions
     *  happen to be written rather than anything the format guarantees. */
    godot::String get_section_control_channel(int index) const;
    double get_section_control_chord_fraction(int index) const;
    double get_section_control_span_fraction(int index) const;
    double get_section_control_deflection_deg(int index) const;
    double get_section_chord_m(int index) const;
    double get_section_incidence_deg(int index) const;
    double get_section_dihedral_deg(int index) const;

    godot::Vector3 get_wheel_position(int index) const;
    double get_wheel_radius_m(int index) const;

    godot::Vector3 get_motor_position() const;
    double get_propeller_diameter_m() const;

    // --------------------------------------------------------------- reset ---

    void reset_state();

protected:
    static void _bind_methods();

private:
    void ResetPhysicsState();
    double StandingHeight() const;
    bool   CanTakeOffFromGround() const;
    void PublishTransform();
    void ApplyEnvironment();
    godot::String ResolveAircraftPath() const;
    class RCInputNode* ResolveInput();
    bool IsValidSection(int index) const;

    rc::SimulationClock Clock;
    rc::RigidBodyState  State;
    rc::Aircraft        Plane;
    rc::AircraftDefinition Definition;
    rc::Atmosphere      Air;
    rc::WindField       Wind;
    rc::PowerSystem     Power;
    // The world's shape, and the collision surface derived from it. One
    // function, so what the pilot flies into is what was drawn.
    rc::TerrainField    Terrain;
    rc::TerrainGround   Ground{Terrain};
    rc::TerrainScatter  Scatter{Terrain};
    rc::LiftField       Lift{Terrain};

    /** Always running. By the time a pilot knows they want the last thirty
     *  seconds, those seconds have happened. */
    rc::FailureModel    Failures;
    rc::FlightRecorder  Recorder;
    bool                Replaying = false;
    double              ReplayTime = 0.0;
    double              ReplaySpeed = 1.0;
    rc::RigidBodyState  StashedState;
    rc::ChannelValues   StashedChannels;

    void RecordFrame();
    void AdvanceReplay(double deltaSeconds);
    double              ThermalScale = 1.0;
    rc::CrashResult     Crash;
    rc::ContactSettings ContactTuning;
    rc::ChannelValues   Channels;
    rc::ChannelValues   ManualChannels;
    /** What the pilot asked for, before any failure was applied. The telemetry
     *  and the replay show this - a jammed servo should not make the stick
     *  display lie about where the stick is. */
    rc::ChannelValues   CommandedChannels;
    rc::AircraftForces  LastForces;

    godot::String AircraftPath = "Data/Aircraft/Trainer1500.json";
    bool AircraftLoaded = false;

    bool   GravityEnabled = true;
    int    SpawnModeValue = SPAWN_AIR;
    double SpawnAltitude  = 50.0;
    rc::Vec3 SpawnOffset  = rc::Vec3::Zero();   ///< NED
    double SpawnHeading   = 0.0;                ///< rad

    double FieldElevation    = 0.0;
    double TemperatureOffset = 0.0;
    double WindSpeed         = 0.0;
    double WindDirection     = 270.0;
    double GustAmplitude     = 0.0;
    double TurbulenceIntensity = 0.0;
    int    WindSeed          = 1;

    /** Advance the power system one step and publish it for the force model. */
    rc::PropulsionOutput StepPropulsion(rc::Real dt);

    bool WarnedAboutDrops = false;

    godot::NodePath InputPath;
    class RCInputNode* CachedInput = nullptr;
};

} // namespace openrc

VARIANT_ENUM_CAST(openrc::RCSimulationNode::SpawnMode);
