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

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include "RCPhysics/Aircraft/Aircraft.h"
#include "RCPhysics/Core/Clock/SimulationClock.h"
#include "RCPhysics/Input/ChannelTypes.h"
#include "RCPhysics/Physics/Ground/LandingGear.h"
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
    bool reload_aircraft();

    bool is_aircraft_loaded() const { return AircraftLoaded; }
    godot::String get_aircraft_name() const;

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
    double get_section_chord_m(int index) const;
    double get_section_incidence_deg(int index) const;
    double get_section_dihedral_deg(int index) const;

    godot::Vector3 get_wheel_position(int index) const;
    double get_wheel_radius_m(int index) const;

    godot::Vector3 get_motor_position() const;
    double get_propeller_diameter_m() const;
    double get_wingspan_m() const;

    // --------------------------------------------------------------- reset ---

    void reset_state();

protected:
    static void _bind_methods();

private:
    void ResetPhysicsState();
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
    rc::FlatGround      Ground{0.0};
    rc::CrashResult     Crash;
    rc::ChannelValues   Channels;
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
