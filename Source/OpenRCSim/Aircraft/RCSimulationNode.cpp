#include "RCSimulationNode.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "../Bridge/RCGodotConversion.h"
#include "../Input/RCInputNode.h"
#include "RCPhysics/Aircraft/AircraftLoader.h"
#include "RCPhysics/Core/Log.h"
#include "RCPhysics/Core/Units/Units.h"
#include "RCPhysics/Physics/Dynamics/RigidBodyIntegrator.h"

using namespace godot;

namespace openrc
{
RCSimulationNode::RCSimulationNode()
{
    Clock.SetRateHz(rc::SimulationClock::kDefaultRateHz);
    // Deliberately no tree access here: Godot constructs a throwaway instance of
    // every registered class to read its default property values, and that
    // instance is not in the scene tree.
    ResetPhysicsState();
}

void RCSimulationNode::_ready()
{
    if (Engine::get_singleton()->is_editor_hint())
    {
        set_process(false);
        return;
    }

    reload_aircraft();
    ApplyEnvironment();
    reset_state();
}

void RCSimulationNode::_process(double deltaSeconds)
{
    if (Engine::get_singleton()->is_editor_hint())
    {
        return;
    }

    // Sample the sticks once per frame, as late as possible relative to the
    // steps that consume them: input latency is second only to physics fidelity
    // in this project's priorities.
    if (RCInputNode* input = ResolveInput())
    {
        Channels = input->Channels();
    }
    else
    {
        Channels = rc::ChannelValues::Neutral();
    }

    Clock.AddFrameTime(deltaSeconds);

    const rc::Vec3 gravity = GravityEnabled ? rc::DefaultGravityWorld() : rc::Vec3::Zero();
    const rc::Real dt = Clock.FixedDeltaSeconds();

    while (Clock.ConsumeStep())
    {
        if (AircraftLoaded)
        {
            const rc::PropulsionOutput propulsion = StepPropulsion(dt);
            LastForces = Plane.ComputeForces(State, Channels, Air, Wind, propulsion, &Ground);
            if (!Crash.Crashed)
            {
                Crash = Plane.Crash().Check(State, Ground, LastForces.Wheels);
                if (Crash.Crashed)
                {
                    RC_LOG(Physics, Warning, "Aircraft crashed: %s (%.1f m/s). Press R to reset.",
                           Crash.Reason.c_str(), Crash.ImpactSpeed);
                }
            }
        }
        else
        {
            LastForces = rc::AircraftForces{};
        }

        if (!rc::StepSemiImplicitEuler(State, Plane.GetMassProperties(),
                                       LastForces.Total, dt, gravity))
        {
            // The integrator already logged and restored the last good state.
            break;
        }
        Wind.Advance(dt);
    }

    if (!WarnedAboutDrops && Clock.DroppedSteps() > 0)
    {
        WarnedAboutDrops = true;
        RC_LOG(Physics, Warning,
               "Dropped %lld physics steps - this machine is not sustaining %.0f Hz.",
               static_cast<long long>(Clock.DroppedSteps()), Clock.RateHz());
    }

    PublishTransform();
}

rc::PropulsionOutput RCSimulationNode::StepPropulsion(rc::Real dt)
{
    const rc::AtmosphereSample sample = Air.SampleAboveField(State.AltitudeMetres());
    const rc::Vec3 axis = Definition.Propulsion.Mount.ThrustAxisBody();
    const rc::Vec3 airVelocityBody = State.Orientation.RotateInverse(
        State.VelocityWorld - Wind.SampleWorld(State.PositionWorld));

    Power.Step(Channels.Throttle(), rc::Dot(airVelocityBody, axis), sample.Density, dt);

    const rc::PowerSystemState& state = Power.State();
    rc::PropulsionOutput output;
    output.Thrust          = state.Thrust;
    output.ShaftTorque     = state.ShaftTorque;
    output.InducedVelocity = state.InducedVelocity;
    output.WakeSwirl = state.WakeSwirl;
    output.PropellerRate   = state.PropellerRate;
    output.Current         = state.Current;
    output.Voltage         = state.BusVoltage;
    output.AngularMomentum = Power.AngularMomentum();
    return output;
}

// ------------------------------------------------------------- the aircraft --

String RCSimulationNode::ResolveAircraftPath() const
{
    if (AircraftPath.begins_with("res://") || AircraftPath.begins_with("user://") ||
        AircraftPath.begins_with("/"))
    {
        return AircraftPath;
    }
    // A bare relative path lives in the repository, one level above the Godot
    // project, so that Data/ is the single source of truth shared with the
    // offline validation suite.
    ProjectSettings* settings = ProjectSettings::get_singleton();
    const String projectRoot = (settings != nullptr)
                             ? settings->globalize_path("res://")
                             : String("./");
    return projectRoot + String("../") + AircraftPath;
}

bool RCSimulationNode::reload_aircraft()
{
    const String resolved = ResolveAircraftPath();
    const std::string path(resolved.utf8().get_data());

    rc::AircraftDefinition definition;
    const rc::AircraftLoadResult result = rc::AircraftLoader::LoadFromFile(path, definition);

    for (const std::string& warning : result.Warnings)
    {
        RC_LOG(Aero, Warning, "%s", warning.c_str());
    }
    if (!result.Success)
    {
        for (const std::string& error : result.Errors)
        {
            RC_LOG(Aero, Error, "%s", error.c_str());
        }
        AircraftLoaded = false;
        return false;
    }

    if (!Plane.Configure(definition))
    {
        RC_LOG(Aero, Error, "Aircraft '%s' loaded but could not be configured.",
               definition.Name.c_str());
        AircraftLoaded = false;
        return false;
    }

    Definition = definition;
    Power.Configure(definition.Propulsion);
    AircraftLoaded = true;
    RC_LOG(Aero, Info, "Aircraft ready: %s (%.3f kg, %zu sections).",
           Definition.Name.c_str(), Definition.Mass, Definition.Surfaces.size());
    return true;
}

void RCSimulationNode::set_aircraft_definition(const String& path)
{
    AircraftPath = path;
    if (is_inside_tree() && !Engine::get_singleton()->is_editor_hint())
    {
        reload_aircraft();
    }
}

String RCSimulationNode::get_aircraft_definition() const { return AircraftPath; }

String RCSimulationNode::get_aircraft_name() const
{
    return AircraftLoaded ? String(Definition.Name.c_str()) : String("<none>");
}

// ------------------------------------------------------------------- state --

void RCSimulationNode::ResetPhysicsState()
{
    State = rc::RigidBodyState{};
    State.Orientation = rc::Quat::FromEuler(0.0, 0.0, SpawnHeading);

    switch (SpawnModeValue)
    {
        case SPAWN_RUNWAY:
        {
            // Sit the CG at the height its own gear holds it, not at ground
            // level - otherwise the propeller and the wheels start underground
            // and the aircraft is "crashed" before it has moved.
            rc::Real standingHeight = 0.0;
            for (const rc::LandingGearSpec& wheel : Definition.LandingGear)
            {
                standingHeight = rc::Max(standingHeight, wheel.PositionBody.z + wheel.Radius);
            }
            State.PositionWorld = rc::Vec3(SpawnOffset.x, SpawnOffset.y, -standingHeight);
            State.VelocityWorld = rc::Vec3::Zero();
            break;
        }

        case SPAWN_APPROACH:
            // On final: low, slow, descending gently towards the strip.
            State.PositionWorld = rc::Vec3(SpawnOffset.x - 120.0, SpawnOffset.y, -18.0);
            State.SetVelocityBody(rc::Vec3(
                AircraftLoaded ? Definition.ApproachSpeed : 11.0, 0.0, 0.9));
            break;

        case SPAWN_AIR:
        default:
            State.PositionWorld = rc::Vec3(SpawnOffset.x, SpawnOffset.y, -SpawnAltitude);
            State.SetVelocityBody(rc::Vec3(
                AircraftLoaded ? Definition.CruiseSpeed : 16.0, 0.0, 0.0));
            break;
    }

    Clock.Reset();
    Wind.Reset();
    Plane.ResetAeroState();
    Power.Reset();
    Crash = rc::CrashResult{};
    LastForces = rc::AircraftForces{};
    WarnedAboutDrops = false;
}

void RCSimulationNode::reset_state()
{
    ResetPhysicsState();
    PublishTransform();
}

void RCSimulationNode::PublishTransform()
{
    if (!is_inside_tree())
    {
        return;
    }
    set_global_position(ToGodotPosition(State.PositionWorld));
    set_quaternion(ToGodotRotation(State.Orientation));
}

void RCSimulationNode::ApplyEnvironment()
{
    Air.SetFieldElevation(FieldElevation);
    Air.SetTemperatureOffset(TemperatureOffset);
    Wind.SetSeed(static_cast<std::uint32_t>(WindSeed <= 0 ? 1 : WindSeed));
    Wind.SetSteady(WindSpeed, rc::units::Degrees(WindDirection));
    Wind.SetGust(GustAmplitude, 9.0);
    // A length scale near the wingspan is what makes turbulence roll the
    // aircraft rather than merely displace it.
    Wind.SetTurbulence(TurbulenceIntensity,
                       AircraftLoaded ? rc::Max(Definition.WingSpan * 3.0, 2.0) : 5.0);
}

RCInputNode* RCSimulationNode::ResolveInput()
{
    if (CachedInput != nullptr) { return CachedInput; }
    if (InputPath.is_empty() || !is_inside_tree()) { return nullptr; }
    CachedInput = Object::cast_to<RCInputNode>(get_node_or_null(InputPath));
    return CachedInput;
}

// --------------------------------------------------------------- properties --

void RCSimulationNode::set_physics_rate_hz(int rateHz) { Clock.SetRateHz(static_cast<rc::Real>(rateHz)); }
int RCSimulationNode::get_physics_rate_hz() const { return static_cast<int>(Clock.RateHz() + 0.5); }

void RCSimulationNode::set_gravity_enabled(bool enabled) { GravityEnabled = enabled; }
bool RCSimulationNode::get_gravity_enabled() const { return GravityEnabled; }

void RCSimulationNode::set_spawn_mode(int mode) { SpawnModeValue = mode; }
int RCSimulationNode::get_spawn_mode() const { return SpawnModeValue; }

void RCSimulationNode::set_spawn_altitude_m(double altitude) { SpawnAltitude = altitude; }
double RCSimulationNode::get_spawn_altitude_m() const { return SpawnAltitude; }

void RCSimulationNode::set_spawn_offset(const Vector3& offset)
{
    SpawnOffset = FromGodotPosition(offset);
}

Vector3 RCSimulationNode::get_spawn_offset() const { return ToGodotPosition(SpawnOffset); }

void RCSimulationNode::set_spawn_heading_deg(double degrees)
{
    SpawnHeading = rc::units::Degrees(degrees);
}

double RCSimulationNode::get_spawn_heading_deg() const
{
    return rc::units::ToDegrees(SpawnHeading);
}

void RCSimulationNode::set_input_path(const NodePath& path) { InputPath = path; CachedInput = nullptr; }
NodePath RCSimulationNode::get_input_path() const { return InputPath; }

void RCSimulationNode::set_field_elevation_m(double metres) { FieldElevation = metres; ApplyEnvironment(); }
double RCSimulationNode::get_field_elevation_m() const { return FieldElevation; }

void RCSimulationNode::set_temperature_offset_c(double kelvin) { TemperatureOffset = kelvin; ApplyEnvironment(); }
double RCSimulationNode::get_temperature_offset_c() const { return TemperatureOffset; }

void RCSimulationNode::set_wind_speed_mps(double speed) { WindSpeed = speed; ApplyEnvironment(); }
double RCSimulationNode::get_wind_speed_mps() const { return WindSpeed; }

void RCSimulationNode::set_wind_direction_deg(double degrees) { WindDirection = degrees; ApplyEnvironment(); }
double RCSimulationNode::get_wind_direction_deg() const { return WindDirection; }

void RCSimulationNode::set_gust_amplitude_mps(double amplitude) { GustAmplitude = amplitude; ApplyEnvironment(); }
double RCSimulationNode::get_gust_amplitude_mps() const { return GustAmplitude; }

void RCSimulationNode::set_turbulence_mps(double intensity) { TurbulenceIntensity = intensity; ApplyEnvironment(); }
double RCSimulationNode::get_turbulence_mps() const { return TurbulenceIntensity; }

void RCSimulationNode::set_wind_seed(int seed) { WindSeed = seed; ApplyEnvironment(); }
int RCSimulationNode::get_wind_seed() const { return WindSeed; }

double RCSimulationNode::get_gust_fraction() const { return Wind.GustFraction(); }

Vector3 RCSimulationNode::get_wind_vector() const
{
    return ToGodotVector(Wind.SampleWorld(State.PositionWorld));
}

// ---------------------------------------------------------------- telemetry --

double RCSimulationNode::get_altitude_m() const { return State.AltitudeMetres(); }
double RCSimulationNode::get_ground_speed_mps() const { return State.GroundSpeed(); }
double RCSimulationNode::get_airspeed_mps() const { return LastForces.Airspeed; }
double RCSimulationNode::get_alpha_degrees() const { return rc::units::ToDegrees(LastForces.Alpha); }
double RCSimulationNode::get_beta_degrees() const { return rc::units::ToDegrees(LastForces.Beta); }
double RCSimulationNode::get_total_lift_n() const { return LastForces.TotalLift; }
double RCSimulationNode::get_total_drag_n() const { return LastForces.TotalDrag; }
double RCSimulationNode::get_stalled_fraction() const { return LastForces.StalledWingFraction; }

Vector3 RCSimulationNode::get_velocity_world() const { return ToGodotVector(State.VelocityWorld); }

Vector3 RCSimulationNode::get_attitude_degrees() const
{
    const rc::frame::AttitudeDegrees a = rc::frame::ToAttitudeDegrees(State.Orientation);
    return Vector3(static_cast<real_t>(a.Roll), static_cast<real_t>(a.Pitch),
                   static_cast<real_t>(a.Yaw));
}

Vector3 RCSimulationNode::get_angular_velocity_degrees() const
{
    const rc::Vec3& w = State.AngularVelocityBody;
    return Vector3(static_cast<real_t>(rc::units::ToDegrees(w.x)),
                   static_cast<real_t>(rc::units::ToDegrees(w.y)),
                   static_cast<real_t>(rc::units::ToDegrees(w.z)));
}

double RCSimulationNode::get_rpm() const { return Power.State().Rpm; }
double RCSimulationNode::get_thrust_n() const { return Power.State().Thrust; }
double RCSimulationNode::get_motor_current_a() const { return Power.State().Current; }
double RCSimulationNode::get_bus_voltage_v() const { return Power.State().BusVoltage; }
double RCSimulationNode::get_electrical_power_w() const { return Power.State().ElectricalPower; }
double RCSimulationNode::get_battery_charge() const { return Power.State().StateOfCharge; }
double RCSimulationNode::get_induced_velocity_mps() const { return Power.State().InducedVelocity; }

bool RCSimulationNode::is_on_ground() const { return LastForces.OnGround; }
double RCSimulationNode::get_weight_on_wheels_n() const { return LastForces.WeightOnWheels; }
int RCSimulationNode::get_wheel_count() const { return static_cast<int>(LastForces.Wheels.size()); }

double RCSimulationNode::get_wheel_compression_m(int index) const
{
    if (index < 0 || static_cast<size_t>(index) >= LastForces.Wheels.size()) { return 0.0; }
    return LastForces.Wheels[static_cast<size_t>(index)].Compression;
}

bool RCSimulationNode::is_wheel_skidding(int index) const
{
    if (index < 0 || static_cast<size_t>(index) >= LastForces.Wheels.size()) { return false; }
    return LastForces.Wheels[static_cast<size_t>(index)].Skidding;
}

bool RCSimulationNode::has_crashed() const { return Crash.Crashed; }

String RCSimulationNode::get_crash_reason() const
{
    return Crash.Crashed ? String(Crash.Reason.c_str()) : String();
}

double RCSimulationNode::get_simulated_time_s() const { return Clock.SimulatedTimeSeconds(); }
int64_t RCSimulationNode::get_total_steps() const { return static_cast<int64_t>(Clock.TotalStepCount()); }
int64_t RCSimulationNode::get_dropped_steps() const { return static_cast<int64_t>(Clock.DroppedSteps()); }

PackedFloat64Array RCSimulationNode::get_channels() const
{
    PackedFloat64Array out;
    out.resize(static_cast<int64_t>(rc::kChannelCount));
    for (size_t i = 0; i < rc::kChannelCount; ++i)
    {
        out[static_cast<int64_t>(i)] = Channels.Values[i];
    }
    return out;
}

// ---------------------------------------------------------- section debug ---

bool RCSimulationNode::IsValidSection(int index) const
{
    return index >= 0 && static_cast<size_t>(index) < LastForces.Sections.size();
}

int RCSimulationNode::get_section_count() const
{
    return static_cast<int>(LastForces.Sections.size());
}

String RCSimulationNode::get_section_name(int index) const
{
    if (!AircraftLoaded || index < 0 ||
        static_cast<size_t>(index) >= Definition.Surfaces.size())
    {
        return String("<none>");
    }
    return String(Definition.Surfaces[static_cast<size_t>(index)].Name.c_str());
}

double RCSimulationNode::get_section_alpha_degrees(int index) const
{
    return IsValidSection(index)
         ? rc::units::ToDegrees(LastForces.Sections[static_cast<size_t>(index)].Alpha)
         : 0.0;
}

double RCSimulationNode::get_section_separation(int index) const
{
    return IsValidSection(index)
         ? LastForces.Sections[static_cast<size_t>(index)].Coefficients.SeparationFraction
         : 0.0;
}

double RCSimulationNode::get_section_lift_n(int index) const
{
    return IsValidSection(index) ? LastForces.Sections[static_cast<size_t>(index)].Lift : 0.0;
}

Vector3 RCSimulationNode::get_section_position(int index) const
{
    if (!AircraftLoaded || index < 0 ||
        static_cast<size_t>(index) >= Definition.Surfaces.size())
    {
        return Vector3();
    }
    return ToGodotVector(Definition.Surfaces[static_cast<size_t>(index)].PositionBody);
}

Vector3 RCSimulationNode::get_section_lift_direction(int index) const
{
    if (!IsValidSection(index)) { return Vector3(); }
    return ToGodotDirection(LastForces.Sections[static_cast<size_t>(index)].LiftDirectionBody);
}

// ------------------------------------------------------- geometry accessors --

namespace
{
    bool HasSurface(const rc::AircraftDefinition& definition, int index)
    {
        return index >= 0 && static_cast<size_t>(index) < definition.Surfaces.size();
    }
}

double RCSimulationNode::get_section_span_m(int index) const
{
    if (!AircraftLoaded || !HasSurface(Definition, index)) { return 0.0; }
    return Definition.Surfaces[static_cast<size_t>(index)].Span;
}

double RCSimulationNode::get_section_chord_m(int index) const
{
    if (!AircraftLoaded || !HasSurface(Definition, index)) { return 0.0; }
    return Definition.Surfaces[static_cast<size_t>(index)].Chord;
}

double RCSimulationNode::get_section_incidence_deg(int index) const
{
    if (!AircraftLoaded || !HasSurface(Definition, index)) { return 0.0; }
    const rc::AeroSurfaceSpec& spec = Definition.Surfaces[static_cast<size_t>(index)];
    return rc::units::ToDegrees(spec.Incidence + spec.Twist);
}

double RCSimulationNode::get_section_dihedral_deg(int index) const
{
    if (!AircraftLoaded || !HasSurface(Definition, index)) { return 0.0; }
    return rc::units::ToDegrees(Definition.Surfaces[static_cast<size_t>(index)].Dihedral);
}

Vector3 RCSimulationNode::get_wheel_position(int index) const
{
    if (!AircraftLoaded || index < 0 ||
        static_cast<size_t>(index) >= Definition.LandingGear.size())
    {
        return Vector3();
    }
    return ToGodotVector(Definition.LandingGear[static_cast<size_t>(index)].PositionBody);
}

double RCSimulationNode::get_wheel_radius_m(int index) const
{
    if (!AircraftLoaded || index < 0 ||
        static_cast<size_t>(index) >= Definition.LandingGear.size())
    {
        return 0.0;
    }
    return Definition.LandingGear[static_cast<size_t>(index)].Radius;
}

Vector3 RCSimulationNode::get_motor_position() const
{
    if (!AircraftLoaded) { return Vector3(); }
    return ToGodotVector(Definition.Propulsion.Mount.PositionBody);
}

double RCSimulationNode::get_propeller_diameter_m() const
{
    return AircraftLoaded ? Definition.Propulsion.Propeller.Diameter : 0.0;
}

double RCSimulationNode::get_wingspan_m() const
{
    return AircraftLoaded ? Definition.WingSpan : 0.0;
}

// ---------------------------------------------------------------- bindings --

void RCSimulationNode::_bind_methods()
{
    #define OPENRC_BIND(Name) ClassDB::bind_method(D_METHOD(#Name), &RCSimulationNode::Name)
    #define OPENRC_BIND1(Name, Arg) ClassDB::bind_method(D_METHOD(#Name, Arg), &RCSimulationNode::Name)

    OPENRC_BIND1(set_aircraft_definition, "path");
    OPENRC_BIND(get_aircraft_definition);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "aircraft_definition"),
                 "set_aircraft_definition", "get_aircraft_definition");
    OPENRC_BIND(reload_aircraft);
    OPENRC_BIND(is_aircraft_loaded);
    OPENRC_BIND(get_aircraft_name);

    OPENRC_BIND1(set_physics_rate_hz, "rate_hz");
    OPENRC_BIND(get_physics_rate_hz);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "physics_rate_hz", PROPERTY_HINT_RANGE, "60,960,60"),
                 "set_physics_rate_hz", "get_physics_rate_hz");

    OPENRC_BIND1(set_gravity_enabled, "enabled");
    OPENRC_BIND(get_gravity_enabled);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "gravity_enabled"),
                 "set_gravity_enabled", "get_gravity_enabled");

    OPENRC_BIND1(set_spawn_mode, "mode");
    OPENRC_BIND(get_spawn_mode);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "spawn_mode", PROPERTY_HINT_ENUM,
                              "Runway,Air,Approach"), "set_spawn_mode", "get_spawn_mode");

    OPENRC_BIND1(set_spawn_altitude_m, "altitude");
    OPENRC_BIND(get_spawn_altitude_m);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spawn_altitude_m"),
                 "set_spawn_altitude_m", "get_spawn_altitude_m");

    OPENRC_BIND1(set_spawn_offset, "offset");
    OPENRC_BIND(get_spawn_offset);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "spawn_offset"),
                 "set_spawn_offset", "get_spawn_offset");

    OPENRC_BIND1(set_spawn_heading_deg, "degrees");
    OPENRC_BIND(get_spawn_heading_deg);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spawn_heading_deg", PROPERTY_HINT_RANGE,
                              "0,360,1"), "set_spawn_heading_deg", "get_spawn_heading_deg");

    OPENRC_BIND1(set_input_path, "path");
    OPENRC_BIND(get_input_path);
    ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "input_path",
                              PROPERTY_HINT_NODE_PATH_VALID_TYPES, "RCInputNode"),
                 "set_input_path", "get_input_path");

    OPENRC_BIND1(set_field_elevation_m, "metres");
    OPENRC_BIND(get_field_elevation_m);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "field_elevation_m"),
                 "set_field_elevation_m", "get_field_elevation_m");

    OPENRC_BIND1(set_temperature_offset_c, "kelvin");
    OPENRC_BIND(get_temperature_offset_c);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "temperature_offset_c"),
                 "set_temperature_offset_c", "get_temperature_offset_c");

    OPENRC_BIND1(set_wind_speed_mps, "speed");
    OPENRC_BIND(get_wind_speed_mps);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "wind_speed_mps"),
                 "set_wind_speed_mps", "get_wind_speed_mps");

    OPENRC_BIND1(set_wind_direction_deg, "degrees");
    OPENRC_BIND(get_wind_direction_deg);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "wind_direction_deg", PROPERTY_HINT_RANGE,
                              "0,360,1"), "set_wind_direction_deg", "get_wind_direction_deg");

    OPENRC_BIND1(set_gust_amplitude_mps, "amplitude");
    OPENRC_BIND(get_gust_amplitude_mps);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "gust_amplitude_mps"),
                 "set_gust_amplitude_mps", "get_gust_amplitude_mps");

    OPENRC_BIND1(set_turbulence_mps, "intensity");
    OPENRC_BIND(get_turbulence_mps);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "turbulence_mps"),
                 "set_turbulence_mps", "get_turbulence_mps");

    OPENRC_BIND1(set_wind_seed, "seed");
    OPENRC_BIND(get_wind_seed);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "wind_seed"), "set_wind_seed", "get_wind_seed");

    OPENRC_BIND(get_gust_fraction);
    OPENRC_BIND(get_wind_vector);

    OPENRC_BIND(get_altitude_m);
    OPENRC_BIND(get_ground_speed_mps);
    OPENRC_BIND(get_airspeed_mps);
    OPENRC_BIND(get_alpha_degrees);
    OPENRC_BIND(get_beta_degrees);
    OPENRC_BIND(get_velocity_world);
    OPENRC_BIND(get_attitude_degrees);
    OPENRC_BIND(get_angular_velocity_degrees);
    OPENRC_BIND(get_total_lift_n);
    OPENRC_BIND(get_total_drag_n);
    OPENRC_BIND(get_stalled_fraction);
    OPENRC_BIND(get_rpm);
    OPENRC_BIND(get_thrust_n);
    OPENRC_BIND(get_motor_current_a);
    OPENRC_BIND(get_bus_voltage_v);
    OPENRC_BIND(get_electrical_power_w);
    OPENRC_BIND(get_battery_charge);
    OPENRC_BIND(get_induced_velocity_mps);

    OPENRC_BIND(is_on_ground);
    OPENRC_BIND(get_weight_on_wheels_n);
    OPENRC_BIND(get_wheel_count);
    OPENRC_BIND1(get_wheel_compression_m, "index");
    OPENRC_BIND1(is_wheel_skidding, "index");
    OPENRC_BIND(has_crashed);
    OPENRC_BIND(get_crash_reason);

    OPENRC_BIND(get_simulated_time_s);
    OPENRC_BIND(get_total_steps);
    OPENRC_BIND(get_dropped_steps);
    OPENRC_BIND(get_channels);

    OPENRC_BIND(get_section_count);
    OPENRC_BIND1(get_section_name, "index");
    OPENRC_BIND1(get_section_alpha_degrees, "index");
    OPENRC_BIND1(get_section_separation, "index");
    OPENRC_BIND1(get_section_lift_n, "index");
    OPENRC_BIND1(get_section_position, "index");
    OPENRC_BIND1(get_section_lift_direction, "index");
    OPENRC_BIND1(get_section_span_m, "index");
    OPENRC_BIND1(get_section_chord_m, "index");
    OPENRC_BIND1(get_section_incidence_deg, "index");
    OPENRC_BIND1(get_section_dihedral_deg, "index");
    OPENRC_BIND1(get_wheel_position, "index");
    OPENRC_BIND1(get_wheel_radius_m, "index");
    OPENRC_BIND(get_motor_position);
    OPENRC_BIND(get_propeller_diameter_m);
    OPENRC_BIND(get_wingspan_m);

    OPENRC_BIND(reset_state);

    BIND_ENUM_CONSTANT(SPAWN_RUNWAY);
    BIND_ENUM_CONSTANT(SPAWN_AIR);
    BIND_ENUM_CONSTANT(SPAWN_APPROACH);

    #undef OPENRC_BIND
    #undef OPENRC_BIND1
}

} // namespace openrc
