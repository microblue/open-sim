#include "RCSimulationNode.h"

#include <algorithm>

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "../Bridge/RCDataPaths.h"
#include "../Bridge/RCGodotConversion.h"
#include "../Input/RCInputNode.h"
#include "RCPhysics/Aircraft/AircraftLoader.h"
#include "RCPhysics/Core/Log.h"
#include "RCPhysics/Core/Units/Units.h"
#include "RCPhysics/Physics/Dynamics/RigidBodyIntegrator.h"
#include "RCPhysics/Physics/Ground/GroundContact.h"

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

    // In replay the physics does not advance. The aircraft is posed from the
    // recording instead, and everything around it - the wind in the grass, the
    // scenery, the camera - carries on, so the pilot can fly the camera around
    // a moment that has already happened.
    if (Replaying)
    {
        AdvanceReplay(deltaSeconds);
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
        // No transmitter node wired up. Manual channels take over, which is how
        // the in-engine tests fly the aircraft and how a demo or a replay would
        // drive it. They default to neutral, so the absence of both an input
        // node and a manual command still means sticks centred, motor stopped.
        Channels = ManualChannels;
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

        // Stop the airframe at the surface. The landing gear holds it up while
        // it is the right way up and rolling; this catches everything else -
        // the wing tip that digs in, the wreck that would otherwise keep
        // integrating straight down through the field.
        if (AircraftLoaded)
        {
            rc::ResolveGroundContact(State, Plane.GetMassProperties(),
                                     Plane.Crash().CollisionPoints(), Ground,
                                     ContactTuning, dt);
        }

        Wind.Advance(dt);
    }

    RecordFrame();

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
    return openrc::ResolveDataPath(AircraftPath);
}

String RCSimulationNode::get_aircraft_description() const
{
    return AircraftLoaded ? String(Definition.Description.c_str()) : String();
}

double RCSimulationNode::get_mass_kg() const
{
    return AircraftLoaded ? Definition.Mass : 0.0;
}

double RCSimulationNode::get_wing_area_m2() const
{
    return AircraftLoaded ? Definition.WingArea : 0.0;
}

double RCSimulationNode::get_wing_loading_pa() const
{
    if (!AircraftLoaded || Definition.WingArea <= 0.0) { return 0.0; }
    return Definition.Mass * rc::units::kGravity / Definition.WingArea;
}

double RCSimulationNode::get_aspect_ratio() const
{
    if (!AircraftLoaded || Definition.WingArea <= 0.0) { return 0.0; }
    return Definition.WingSpan * Definition.WingSpan / Definition.WingArea;
}

double RCSimulationNode::get_battery_cells() const
{
    return AircraftLoaded ? Definition.Propulsion.Battery.CellCount : 0.0;
}

double RCSimulationNode::get_battery_capacity_mah() const
{
    // Stored in coulombs; the label on the pack is in milliamp hours.
    return AircraftLoaded
         ? Definition.Propulsion.Battery.CapacityCoulombs / 3.6 : 0.0;
}

double RCSimulationNode::get_motor_kv() const
{
    // Stored as rad/s per volt, which is what the electrical model wants;
    // the number on the motor is rpm per volt.
    return AircraftLoaded
         ? Definition.Propulsion.Motor.KvRadPerSecondPerVolt * 60.0 / (2.0 * 3.14159265358979)
         : 0.0;
}

double RCSimulationNode::get_peak_power_w() const
{
    if (!AircraftLoaded) { return 0.0; }
    const double volts = Definition.Propulsion.Battery.CellCount
                       * Definition.Propulsion.Battery.NominalCellVoltage;
    return volts * Definition.Propulsion.Motor.MaxCurrent;
}

double RCSimulationNode::get_power_to_weight_w_per_kg() const
{
    if (!AircraftLoaded || Definition.Mass <= 0.0) { return 0.0; }
    return get_peak_power_w() / Definition.Mass;
}

double RCSimulationNode::get_cruise_speed_mps() const
{
    return AircraftLoaded ? Definition.CruiseSpeed : 0.0;
}

double RCSimulationNode::get_approach_speed_mps() const
{
    return AircraftLoaded ? Definition.ApproachSpeed : 0.0;
}

PackedStringArray RCSimulationNode::list_aircraft() const
{
    // Discovered rather than listed. A new aeroplane appears in the menu the
    // moment its file exists, which is the only way the two stay in step.
    PackedStringArray found;
    const String directory = openrc::ResolveDataPath("Data/Aircraft");

    Ref<DirAccess> handle = DirAccess::open(directory);
    if (handle.is_null()) { return found; }

    handle->list_dir_begin();
    for (String entry = handle->get_next(); !entry.is_empty(); entry = handle->get_next())
    {
        if (handle->current_is_dir() || !entry.ends_with(".json")) { continue; }
        found.push_back(entry.get_basename());
    }
    handle->list_dir_end();
    found.sort();
    return found;
}

String RCSimulationNode::resolve_data_path(const String& relative) const
{
    return openrc::ResolveDataPath(relative);
}

// ------------------------------------------------------------------ terrain --
//
// Godot axes from world NED: godot.x = east, godot.y = up, godot.z = -north.
// So going the other way, north = -godot.z and east = godot.x.

namespace
{
    inline double NorthFromGodot(double z) { return -z; }
    inline double EastFromGodot(double x)  { return  x; }

    /** Surface colour for a sample. Computed here rather than in the shader so
     *  that a triangle spanning two biomes blends between their colours instead
     *  of interpolating a biome index and landing on a third one.
     *
     *  Linear values: everything in this project is authored linear, because
     *  `: source_color` only converts in the editor. */
    godot::Color Mix(const godot::Color& a, const godot::Color& b, float t)
    {
        return godot::Color(a.r + (b.r - a.r) * t,
                            a.g + (b.g - a.g) * t,
                            a.b + (b.b - a.b) * t);
    }

    godot::Color BiomeAlbedo(const rc::TerrainSample& sample)
    {
        // Moisture, remapped so each biome uses the whole range of it rather
        // than the narrow slice that put it in that biome. A landscape painted
        // one colour per biome reads as plaster however good the silhouette is;
        // what makes real ground look like ground at this distance is that no
        // two square kilometres of it are quite the same green.
        const auto wet = static_cast<float>(std::min(std::max(sample.Moisture, 0.0), 1.0));

        switch (sample.Type)
        {
            case rc::Biome::Ocean:
                // Rarely seen - the water surface covers it - but it has to be
                // dark rather than black where it shows through shallows.
                return godot::Color(0.012f, 0.032f, 0.048f);
            case rc::Biome::Beach:
                // Wet sand rather than a beach towel. The first values were
                // bright enough that every shoreline read as a white rim.
                return godot::Color(0.240f, 0.196f, 0.130f);
            case rc::Biome::Desert:
                // Bare sand through to scrub at the wetter edge.
                return Mix(godot::Color(0.300f, 0.196f, 0.098f),
                           godot::Color(0.190f, 0.150f, 0.072f),
                           std::min(std::max(wet / 0.34f, 0.0f), 1.0f));
            case rc::Biome::Grassland:
                // Dry olive through to pasture.
                return Mix(godot::Color(0.088f, 0.082f, 0.030f),
                           godot::Color(0.040f, 0.098f, 0.024f),
                           std::min(std::max((wet - 0.30f) / 0.32f, 0.0f), 1.0f));
            case rc::Biome::Forest:
                // Mixed woodland through to dense conifer.
                return Mix(godot::Color(0.026f, 0.052f, 0.018f),
                           godot::Color(0.013f, 0.031f, 0.014f),
                           std::min(std::max((wet - 0.56f) / 0.36f, 0.0f), 1.0f));
            case rc::Biome::Rock:
                return godot::Color(0.068f, 0.064f, 0.058f);
            case rc::Biome::Snow:
                return godot::Color(0.640f, 0.680f, 0.760f);
            default:
                return godot::Color(0.1f, 0.1f, 0.1f);
        }
    }
}

double RCSimulationNode::get_terrain_height(double x, double z) const
{
    return Terrain.HeightAt(NorthFromGodot(z), EastFromGodot(x));
}

double RCSimulationNode::get_sea_level_y() const { return Terrain.Settings().SeaLevel; }

double RCSimulationNode::get_field_elevation_y() const
{
    return Terrain.Settings().FieldElevation;
}

Dictionary RCSimulationNode::scatter_detail(double centreX, double centreZ,
                                            double size, int count, int seed,
                                            int layer) const
{
    std::vector<rc::ScatterPoint> points;
    Scatter.Fill(NorthFromGodot(centreZ), EastFromGodot(centreX), size,
                 std::max(0, std::min(count, 20000)),
                 static_cast<std::uint32_t>(seed),
                 (layer == 0) ? rc::ScatterLayer::GroundCover
                              : rc::ScatterLayer::Canopy,
                 points);

    PackedVector3Array positions;
    PackedVector3Array normals;
    PackedInt32Array   kinds;
    PackedFloat32Array yaws;
    PackedFloat32Array scales;
    PackedFloat32Array tints;

    for (const rc::ScatterPoint& point : points)
    {
        if (point.Kind == rc::ScatterKind::None) { continue; }

        // North/East back to Godot: x = east, z = -north.
        positions.push_back(Vector3(static_cast<real_t>(point.East),
                                    static_cast<real_t>(point.Height),
                                    static_cast<real_t>(-point.North)));
        normals.push_back(Vector3(static_cast<real_t>(point.Normal.y),
                                  static_cast<real_t>(-point.Normal.z),
                                  static_cast<real_t>(-point.Normal.x)));
        kinds.push_back(static_cast<int32_t>(point.Kind));
        yaws.push_back(static_cast<float>(point.Yaw));
        scales.push_back(static_cast<float>(point.Scale));
        tints.push_back(static_cast<float>(point.Tint));
    }

    Dictionary result;
    result["positions"] = positions;
    result["normals"]   = normals;
    result["kinds"]     = kinds;
    result["yaws"]      = yaws;
    result["scales"]    = scales;
    result["tints"]     = tints;
    return result;
}

void RCSimulationNode::set_terrain_seed(int seed)
{
    rc::TerrainSettings settings = Terrain.Settings();
    settings.Seed = static_cast<std::uint32_t>(seed);
    Terrain.SetSettings(settings);
}

double RCSimulationNode::get_air_vertical_speed_mps() const
{
    return Lift.SampleAt(State.PositionWorld, Wind.Time(), Wind.SteadyVector()).Total();
}

double RCSimulationNode::get_thermal_lift_mps() const
{
    return Lift.SampleAt(State.PositionWorld, Wind.Time(), Wind.SteadyVector()).Thermal;
}

double RCSimulationNode::get_slope_lift_mps() const
{
    return Lift.SampleAt(State.PositionWorld, Wind.Time(), Wind.SteadyVector()).Slope;
}

double RCSimulationNode::get_netto_mps() const
{
    // A plain variometer shows the aircraft's own climb, which includes
    // whatever the airframe is losing by flying. Netto adds that sink back, so
    // what is left is the air alone - the number that answers "is it worth
    // staying here", which is the only question in soaring.
    //
    //   climb  = air's rise  -  the aeroplane's own sink
    //   netto  = climb + own sink  =  air's rise
    //
    // Which is exactly what the lift field reports. Kept as its own accessor
    // because the two are different instruments on a real glider and a pilot
    // learning to use them needs to see both.
    return get_air_vertical_speed_mps();
}

double RCSimulationNode::get_ground_heating() const
{
    return Lift.GroundHeating(State.PositionWorld.x, State.PositionWorld.y);
}

void RCSimulationNode::set_thermal_scale(double scale)
{
    rc::LiftSettings config = Lift.Settings();
    // Relative to the reference day the defaults describe, so a preset says
    // "half as good as a good day" rather than quoting metres per second.
    config.ThermalStrength = rc::LiftSettings{}.ThermalStrength * std::max(scale, 0.0);
    Lift.SetSettings(config);
    ThermalScale = scale;
}

double RCSimulationNode::get_thermal_scale() const { return ThermalScale; }

void RCSimulationNode::set_lift_enabled(bool enabled)
{
    rc::LiftSettings config = Lift.Settings();
    config.Enabled = enabled;
    Lift.SetSettings(config);
    Wind.SetLiftField(enabled ? &Lift : nullptr);
}

bool RCSimulationNode::get_lift_enabled() const { return Lift.Settings().Enabled; }

void RCSimulationNode::RecordFrame()
{
    if (!AircraftLoaded) { return; }

    rc::FlightFrame frame;
    frame.Time = get_simulated_time_s();
    frame.PositionWorld = State.PositionWorld;
    frame.Orientation = State.Orientation;
    frame.VelocityWorld = State.VelocityWorld;
    frame.AngularVelocityBody = State.AngularVelocityBody;

    frame.Airspeed = LastForces.Airspeed;
    frame.Alpha = LastForces.Alpha;
    frame.StalledFraction = LastForces.StalledWingFraction;
    frame.Rpm = Power.State().Rpm;
    frame.Thrust = Power.State().Thrust;
    frame.BatteryCharge = Power.State().StateOfCharge;
    frame.VerticalAirSpeed = get_air_vertical_speed_mps();

    frame.Controls = Channels;
    frame.OnGround = LastForces.OnGround;
    frame.Crashed = Crash.Crashed;

    Recorder.Offer(frame);
}

void RCSimulationNode::advance_replay(double delta) { AdvanceReplay(delta); }

void RCSimulationNode::AdvanceReplay(double deltaSeconds)
{
    if (Recorder.Empty()) { return; }

    ReplayTime += deltaSeconds * ReplaySpeed;
    const double first = Recorder.EarliestTime();
    const double last = Recorder.LatestTime();

    // Held at the ends rather than wrapping. A replay that loops back to the
    // start without being asked makes it hard to study the last half second,
    // which is usually the half second that matters.
    ReplayTime = std::min(std::max(ReplayTime, first), last);

    const rc::FlightFrame frame = Recorder.SampleAt(ReplayTime);
    State.PositionWorld = frame.PositionWorld;
    State.Orientation = frame.Orientation;
    State.VelocityWorld = frame.VelocityWorld;
    State.AngularVelocityBody = frame.AngularVelocityBody;
    Channels = frame.Controls;

    // The control surfaces have to move with the recording too, or the replay
    // shows an aeroplane manoeuvring with its controls centred.
    if (AircraftLoaded)
    {
        // Zero thrust: the recording is being posed, not flown, and the
        // propulsion state belongs to the live aircraft that is paused.
        LastForces = Plane.ComputeForces(State, Channels, Air, Wind,
                                         rc::PropulsionOutput{}, &Ground);
    }

    PublishTransform();
}

double RCSimulationNode::get_replay_duration() const { return Recorder.Duration(); }
double RCSimulationNode::get_replay_earliest() const { return Recorder.EarliestTime(); }
double RCSimulationNode::get_replay_latest() const { return Recorder.LatestTime(); }

void RCSimulationNode::set_replaying(bool replaying)
{
    if (replaying == Replaying) { return; }
    Replaying = replaying;

    if (Replaying)
    {
        // Entering: start where the interesting part is. If the aircraft has
        // crashed that is the crash; otherwise it is the last few seconds,
        // because whatever the pilot wants to see has just happened.
        StashedState = State;
        StashedChannels = Channels;
        ReplaySpeed = 0.35;
        if (Crash.Crashed)
        {
            replay_to_crash();
        }
        else
        {
            ReplayTime = std::max(Recorder.EarliestTime(), Recorder.LatestTime() - 8.0);
        }
    }
    else
    {
        // Leaving: back to the live aircraft exactly as it was. A replay is
        // something you look at, not somewhere you can fly from - rewinding
        // and then flying on would be a different simulator.
        State = StashedState;
        Channels = StashedChannels;
        PublishTransform();
    }
}

void RCSimulationNode::set_replay_time(double seconds)
{
    ReplayTime = std::min(std::max(seconds, Recorder.EarliestTime()), Recorder.LatestTime());
}

void RCSimulationNode::set_replay_speed(double speed)
{
    ReplaySpeed = std::min(std::max(speed, -4.0), 4.0);
}

void RCSimulationNode::replay_to_crash()
{
    // Backwards from the end: the crash is the LAST transition into the
    // crashed state, not the first, and a flight can contain more than one.
    for (std::size_t i = Recorder.Size(); i-- > 0; )
    {
        if (!Recorder.At(i).Crashed) { continue; }
        // Six seconds before it, so the approach that caused it is in view.
        ReplayTime = std::max(Recorder.EarliestTime(), Recorder.At(i).Time - 6.0);
        return;
    }
    ReplayTime = Recorder.LatestTime();
}

Dictionary RCSimulationNode::get_replay_frame() const
{
    const rc::FlightFrame frame = Recorder.SampleAt(ReplayTime);
    Dictionary out;
    out["time"] = frame.Time;
    out["airspeed"] = frame.Airspeed;
    out["alpha_deg"] = rc::units::ToDegrees(frame.Alpha);
    out["stalled"] = frame.StalledFraction;
    out["rpm"] = frame.Rpm;
    out["thrust"] = frame.Thrust;
    out["battery"] = frame.BatteryCharge;
    out["vario"] = frame.VerticalAirSpeed;
    out["altitude"] = -frame.PositionWorld.z;
    out["on_ground"] = frame.OnGround;
    out["crashed"] = frame.Crashed;
    out["aileron"] = frame.Controls.Aileron();
    out["elevator"] = frame.Controls.Elevator();
    out["rudder"] = frame.Controls.Rudder();
    out["throttle"] = frame.Controls.Throttle();
    return out;
}

PackedVector3Array RCSimulationNode::get_flight_path(int maxPoints) const
{
    PackedVector3Array path;
    const std::size_t count = Recorder.Size();
    if (count == 0) { return path; }

    const auto wanted = static_cast<std::size_t>(std::max(maxPoints, 2));
    const std::size_t stride = std::max<std::size_t>(1, count / wanted);
    for (std::size_t i = 0; i < count; i += stride)
    {
        path.push_back(ToGodotPosition(Recorder.At(i).PositionWorld));
    }
    return path;
}

void RCSimulationNode::configure_terrain(const Dictionary& settings)
{
    rc::TerrainSettings config = Terrain.Settings();

    if (settings.has("seed"))            { config.Seed = static_cast<std::uint32_t>(int(settings["seed"])); }
    if (settings.has("mountain_height")) { config.MountainHeight = double(settings["mountain_height"]); }
    if (settings.has("continent_scale")) { config.ContinentScale = double(settings["continent_scale"]); }
    if (settings.has("sea_level"))       { config.SeaLevel = double(settings["sea_level"]); }
    if (settings.has("snow_line"))       { config.SnowLine = double(settings["snow_line"]); }
    if (settings.has("beach_height"))    { config.BeachHeight = double(settings["beach_height"]); }
    if (settings.has("moisture_bias"))   { config.MoistureBias = double(settings["moisture_bias"]); }
    if (settings.has("ruggedness"))      { config.Ruggedness = double(settings["ruggedness"]); }
    if (settings.has("plateau_radius"))  { config.PlateauRadius = double(settings["plateau_radius"]); }
    if (settings.has("plateau_blend"))   { config.PlateauBlend = double(settings["plateau_blend"]); }

    Terrain.SetSettings(config);
    RC_LOG(Physics, Info,
           "Terrain reconfigured: seed %u, mountains %.0f m, scale %.0f m, "
           "sea %.0f m, snow %.0f m, moisture %+.2f, ruggedness %.2f",
           config.Seed, config.MountainHeight, config.ContinentScale,
           config.SeaLevel, config.SnowLine, config.MoistureBias, config.Ruggedness);
}

Dictionary RCSimulationNode::get_terrain_settings() const
{
    const rc::TerrainSettings& config = Terrain.Settings();
    Dictionary out;
    out["seed"]            = static_cast<int>(config.Seed);
    out["mountain_height"] = config.MountainHeight;
    out["continent_scale"] = config.ContinentScale;
    out["sea_level"]       = config.SeaLevel;
    out["snow_line"]       = config.SnowLine;
    out["beach_height"]    = config.BeachHeight;
    out["moisture_bias"]   = config.MoistureBias;
    out["ruggedness"]      = config.Ruggedness;
    out["plateau_radius"]  = config.PlateauRadius;
    out["plateau_blend"]   = config.PlateauBlend;
    return out;
}

int RCSimulationNode::get_terrain_seed() const
{
    return static_cast<int>(Terrain.Settings().Seed);
}

Ref<ArrayMesh> RCSimulationNode::build_terrain_chunk(double centreX, double centreZ,
                                                     double size, int resolution) const
{
    Ref<ArrayMesh> mesh;
    mesh.instantiate();

    resolution = std::max(2, std::min(resolution, 512));
    const int side = resolution + 1;
    const double step = size / static_cast<double>(resolution);
    const double half = size * 0.5;

    PackedVector3Array vertices;
    PackedVector3Array normals;
    PackedColorArray   colours;
    PackedVector2Array uvs;
    PackedVector2Array uv2s;
    PackedInt32Array   indices;

    vertices.resize(side * side);
    normals.resize(side * side);
    colours.resize(side * side);
    uvs.resize(side * side);
    uv2s.resize(side * side);

    for (int row = 0; row < side; ++row)
    {
        for (int column = 0; column < side; ++column)
        {
            const double localX = -half + column * step;
            const double localZ = -half + row * step;
            const double worldX = centreX + localX;
            const double worldZ = centreZ + localZ;

            const rc::TerrainSample sample =
                Terrain.SampleAt(NorthFromGodot(worldZ), EastFromGodot(worldX));

            const int index = row * side + column;
            // Local coordinates: the caller places the chunk, which keeps the
            // vertex values small and the mesh reusable.
            vertices[index] = Vector3(static_cast<real_t>(localX),
                                      static_cast<real_t>(sample.Height),
                                      static_cast<real_t>(localZ));

            // NED normal to Godot: (n.y, -n.z, -n.x).
            normals[index] = Vector3(static_cast<real_t>(sample.Normal.y),
                                     static_cast<real_t>(-sample.Normal.z),
                                     static_cast<real_t>(-sample.Normal.x));

            godot::Color albedo = BiomeAlbedo(sample);
            // Alpha carries steepness, which the shader uses to blend rock onto
            // anything too steep to hold soil and to keep snow off cliffs.
            albedo.a = static_cast<float>(std::min(sample.Slope, 1.0));
            colours[index] = albedo;

            // World-space UV so detail does not swim between chunks or LODs.
            uvs[index] = Vector2(static_cast<real_t>(worldX),
                                 static_cast<real_t>(worldZ));

            // Moisture and height, for the shader to blend surface materials
            // by. It used to infer how vegetated the ground was from the ratio
            // of green in the vertex colour, which put leaf litter all over the
            // pasture: two biomes can share a colour and mean different things.
            uv2s[index] = Vector2(static_cast<real_t>(sample.Moisture),
                                  static_cast<real_t>(sample.Height));
        }
    }

    indices.resize(resolution * resolution * 6);
    int cursor = 0;
    for (int row = 0; row < resolution; ++row)
    {
        for (int column = 0; column < resolution; ++column)
        {
            const int a = row * side + column;
            const int b = a + 1;
            const int c = a + side;
            const int d = c + 1;
            // Clockwise: Godot's front face. The obvious order leaves the whole
            // surface back-facing, which is how the field went invisible once
            // already.
            indices[cursor++] = a; indices[cursor++] = b; indices[cursor++] = c;
            indices[cursor++] = b; indices[cursor++] = d; indices[cursor++] = c;
        }
    }

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = vertices;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_COLOR]  = colours;
    arrays[Mesh::ARRAY_TEX_UV] = uvs;
    arrays[Mesh::ARRAY_TEX_UV2] = uv2s;
    arrays[Mesh::ARRAY_INDEX]  = indices;

    mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
    return mesh;
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
            // Relative to the ground under the spawn point, not to sea level.
            // The flying field sits on a plateau above the water line, and
            // spawning at z = -standingHeight put the aircraft a hundred metres
            // underground - which compressed the gear to nothing and produced a
            // non-finite state on the first step.
            State.PositionWorld = rc::Vec3(
                SpawnOffset.x, SpawnOffset.y,
                Ground.Sample(SpawnOffset.x, SpawnOffset.y).SurfaceHeight - standingHeight);
            State.VelocityWorld = rc::Vec3::Zero();
            break;
        }

        case SPAWN_APPROACH:
        {
            // On final: low, slow, descending gently towards the strip.
            const rc::Real x = SpawnOffset.x - 120.0;
            State.PositionWorld = rc::Vec3(
                x, SpawnOffset.y, Ground.Sample(x, SpawnOffset.y).SurfaceHeight - 18.0);
            State.SetVelocityBody(rc::Vec3(
                AircraftLoaded ? Definition.ApproachSpeed : 11.0, 0.0, 0.9));
            break;
        }

        case SPAWN_AIR:
        default:
            State.PositionWorld = rc::Vec3(
                SpawnOffset.x, SpawnOffset.y,
                Ground.Sample(SpawnOffset.x, SpawnOffset.y).SurfaceHeight - SpawnAltitude);
            State.SetVelocityBody(rc::Vec3(
                AircraftLoaded ? Definition.CruiseSpeed : 16.0, 0.0, 0.0));
            break;
    }

    Clock.Reset();
    Wind.Reset();
    Plane.ResetAeroState();
    Power.Reset();
    Crash = rc::CrashResult{};
    // The lift field lives on the wind, so rising air reaches the aerodynamics
    // through the same per-section sampling the wind does.
    Wind.SetLiftField(Lift.Settings().Enabled ? &Lift : nullptr);
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

void RCSimulationNode::set_manual_channel(int channel, double value)
{
    if (channel < 0 || channel >= static_cast<int>(rc::kChannelCount)) { return; }
    const rc::RCChannel which = static_cast<rc::RCChannel>(channel);
    // Clamped to each channel's own range so a test cannot command a deflection
    // the flight model would never see from a transmitter.
    const double low = rc::IsBipolar(which) ? -1.0 : 0.0;
    ManualChannels.Set(which, std::min(std::max(value, low), 1.0));
}

void RCSimulationNode::clear_manual_channels()
{
    ManualChannels = rc::ChannelValues::Neutral();
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

void RCSimulationNode::set_tree_obstacles(const PackedFloat32Array& data)
{
    std::vector<rc::TerrainGround::Obstacle> obstacles;
    const std::int64_t quads = data.size() / 4;
    obstacles.reserve(static_cast<std::size_t>(quads));
    for (std::int64_t i = 0; i < quads; ++i)
    {
        // The caller hands over Godot world metres (x, z, radius, height).
        // The physics works in NED (north, east, down): the same frame change
        // PositionFromGodot applies, so north = -z and east = x. Getting this
        // wrong puts every tree somewhere it is not, and the aircraft flies
        // through the one it can see.
        const std::int64_t base = i * 4;
        const rc::Real godotX = static_cast<rc::Real>(data[static_cast<std::int64_t>(base)]);
        const rc::Real godotZ = static_cast<rc::Real>(data[base + 1]);
        obstacles.push_back(rc::TerrainGround::Obstacle{
            -godotZ,
            godotX,
            static_cast<rc::Real>(data[base + 2]),
            static_cast<rc::Real>(data[base + 3]),
        });
    }
    Ground.SetObstacles(std::move(obstacles));
}

double RCSimulationNode::get_surface_height_at(double x, double z) const
{
    return -Ground.Sample(-static_cast<rc::Real>(z), static_cast<rc::Real>(x))
               .SurfaceHeight;
}

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
    // Wind, not air. The windsock and the HUD show what is blowing across the
    // field; rising air is reported separately by the variometer.
    return ToGodotVector(Wind.SampleWindOnly(State.PositionWorld));
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

// ------------------------------------------------------- control surfaces --
// The visible model hinges its surfaces from these, so what the pilot watches
// move is the same deflection the flight model integrated - not an animation
// driven separately off the stick.

bool RCSimulationNode::get_section_has_control(int index) const
{
    if (!AircraftLoaded || !HasSurface(Definition, index)) { return false; }
    return Definition.Surfaces[static_cast<size_t>(index)].HasControl;
}

double RCSimulationNode::get_section_control_chord_fraction(int index) const
{
    if (!get_section_has_control(index)) { return 0.0; }
    return Definition.Surfaces[static_cast<size_t>(index)].Control.ChordFraction;
}

double RCSimulationNode::get_section_control_span_fraction(int index) const
{
    if (!get_section_has_control(index)) { return 0.0; }
    return Definition.Surfaces[static_cast<size_t>(index)].Control.SpanFraction;
}

double RCSimulationNode::get_section_control_deflection_deg(int index) const
{
    if (!IsValidSection(index)) { return 0.0; }
    // Positive is trailing edge down, matching the flight model's convention.
    return rc::units::ToDegrees(LastForces.Sections[static_cast<size_t>(index)].Deflection);
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
    OPENRC_BIND1(set_tree_obstacles, "obstacles");
    ClassDB::bind_method(D_METHOD("get_surface_height_at", "x", "z"),
                          &RCSimulationNode::get_surface_height_at);
    OPENRC_BIND(get_aircraft_definition);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "aircraft_definition"),
                 "set_aircraft_definition", "get_aircraft_definition");
    OPENRC_BIND1(resolve_data_path, "relative");

    ClassDB::bind_method(D_METHOD("get_terrain_height", "x", "z"),
                         &RCSimulationNode::get_terrain_height);
    OPENRC_BIND(get_sea_level_y);
    OPENRC_BIND(get_field_elevation_y);
    ClassDB::bind_method(D_METHOD("build_terrain_chunk", "centre_x", "centre_z",
                                  "size", "resolution"),
                         &RCSimulationNode::build_terrain_chunk);
    ClassDB::bind_method(D_METHOD("scatter_detail", "centre_x", "centre_z",
                                  "size", "count", "seed", "layer"),
                         &RCSimulationNode::scatter_detail);
    OPENRC_BIND1(set_terrain_seed, "seed");
    OPENRC_BIND(get_terrain_seed);
    OPENRC_BIND1(configure_terrain, "settings");
    OPENRC_BIND(get_terrain_settings);
    OPENRC_BIND(get_replay_duration);
    OPENRC_BIND(get_replay_earliest);
    OPENRC_BIND(get_replay_latest);
    OPENRC_BIND1(set_replaying, "replaying");
    OPENRC_BIND(get_replaying);
    OPENRC_BIND1(advance_replay, "delta");
    OPENRC_BIND1(set_replay_time, "seconds");
    OPENRC_BIND(get_replay_time);
    OPENRC_BIND1(set_replay_speed, "speed");
    OPENRC_BIND(get_replay_speed);
    OPENRC_BIND(replay_to_crash);
    OPENRC_BIND(get_replay_frame);
    OPENRC_BIND1(get_flight_path, "max_points");
    OPENRC_BIND(get_air_vertical_speed_mps);
    OPENRC_BIND(get_thermal_lift_mps);
    OPENRC_BIND(get_slope_lift_mps);
    OPENRC_BIND(get_netto_mps);
    OPENRC_BIND(get_ground_heating);
    OPENRC_BIND1(set_thermal_scale, "scale");
    OPENRC_BIND(get_thermal_scale);
    OPENRC_BIND1(set_lift_enabled, "enabled");
    OPENRC_BIND(get_lift_enabled);
    OPENRC_BIND(reload_aircraft);
    OPENRC_BIND(is_aircraft_loaded);
    OPENRC_BIND(get_aircraft_name);
    OPENRC_BIND(get_aircraft_description);
    OPENRC_BIND(get_mass_kg);
    OPENRC_BIND(get_wingspan_m);
    OPENRC_BIND(get_wing_area_m2);
    OPENRC_BIND(get_wing_loading_pa);
    OPENRC_BIND(get_aspect_ratio);
    OPENRC_BIND(get_battery_cells);
    OPENRC_BIND(get_battery_capacity_mah);
    OPENRC_BIND(get_motor_kv);
    OPENRC_BIND(get_peak_power_w);
    OPENRC_BIND(get_power_to_weight_w_per_kg);
    OPENRC_BIND(get_cruise_speed_mps);
    OPENRC_BIND(get_approach_speed_mps);
    OPENRC_BIND(list_aircraft);

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
    ClassDB::bind_method(D_METHOD("set_manual_channel", "channel", "value"),
                         &RCSimulationNode::set_manual_channel);
    OPENRC_BIND(clear_manual_channels);

    OPENRC_BIND(get_section_count);
    OPENRC_BIND1(get_section_name, "index");
    OPENRC_BIND1(get_section_alpha_degrees, "index");
    OPENRC_BIND1(get_section_separation, "index");
    OPENRC_BIND1(get_section_lift_n, "index");
    OPENRC_BIND1(get_section_position, "index");
    OPENRC_BIND1(get_section_lift_direction, "index");
    OPENRC_BIND1(get_section_span_m, "index");
    OPENRC_BIND1(get_section_has_control, "index");
    OPENRC_BIND1(get_section_control_chord_fraction, "index");
    OPENRC_BIND1(get_section_control_span_fraction, "index");
    OPENRC_BIND1(get_section_control_deflection_deg, "index");
    OPENRC_BIND1(get_section_chord_m, "index");
    OPENRC_BIND1(get_section_incidence_deg, "index");
    OPENRC_BIND1(get_section_dihedral_deg, "index");
    OPENRC_BIND1(get_wheel_position, "index");
    OPENRC_BIND1(get_wheel_radius_m, "index");
    OPENRC_BIND(get_motor_position);
    OPENRC_BIND(get_propeller_diameter_m);

    OPENRC_BIND(reset_state);

    BIND_ENUM_CONSTANT(SPAWN_RUNWAY);
    BIND_ENUM_CONSTANT(SPAWN_AIR);
    BIND_ENUM_CONSTANT(SPAWN_APPROACH);

    #undef OPENRC_BIND
    #undef OPENRC_BIND1
}

} // namespace openrc