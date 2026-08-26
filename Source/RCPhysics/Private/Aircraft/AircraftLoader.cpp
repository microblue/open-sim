#include "RCPhysics/Aircraft/AircraftLoader.h"

#include "RCPhysics/Core/Json.h"
#include "RCPhysics/Core/Log.h"
#include "RCPhysics/Core/Units/Units.h"

#include <sstream>

namespace rc
{
namespace
{
    void AddError(AircraftLoadResult& result, const std::string& message)
    {
        result.Errors.push_back(message);
    }

    void AddWarning(AircraftLoadResult& result, const std::string& message)
    {
        result.Warnings.push_back(message);
    }

    /** Read a length that the file may give in metres or inches. */
    Real ReadLength(const JsonValue& object, const char* metreKey, const char* inchKey,
                    Real fallback)
    {
        if (object.Has(metreKey)) { return object.GetNumber(metreKey, fallback); }
        if (object.Has(inchKey))  { return units::Inches(object.GetNumber(inchKey, 0.0)); }
        return fallback;
    }

    Vec3 ReadVector(const JsonValue& object, const char* key, const Vec3& fallback)
    {
        Real x = fallback.x, y = fallback.y, z = fallback.z;
        object.GetVector3(key, x, y, z);
        return Vec3(x, y, z);
    }

    RCChannel ParseChannel(const std::string& name, bool& ok)
    {
        ok = true;
        if (name == "aileron")  { return RCChannel::Aileron; }
        if (name == "elevator") { return RCChannel::Elevator; }
        if (name == "throttle") { return RCChannel::Throttle; }
        if (name == "rudder")   { return RCChannel::Rudder; }
        if (name == "flap")     { return RCChannel::Flap; }
        if (name == "aux1")     { return RCChannel::Aux1; }
        ok = false;
        return RCChannel::Aileron;
    }

    SurfaceRole ParseRole(const std::string& name, bool& ok)
    {
        ok = true;
        if (name == "wing")            { return SurfaceRole::Wing; }
        if (name == "horizontal_tail") { return SurfaceRole::HorizontalTail; }
        if (name == "vertical_tail")   { return SurfaceRole::VerticalTail; }
        ok = false;
        return SurfaceRole::Wing;
    }

    // ------------------------------------------------------------ airfoils --

    AirfoilParameters ReadAirfoilParameters(const JsonValue& entry)
    {
        AirfoilParameters p;
        p.ClZeroAlpha        = entry.GetNumber("cl_zero_alpha", p.ClZeroAlpha);
        p.ClAlphaPerRad      = entry.GetNumber("cl_alpha_per_rad", p.ClAlphaPerRad);
        p.ClMax              = entry.GetNumber("cl_max", p.ClMax);
        p.AlphaStall         = units::Degrees(entry.GetNumber("alpha_stall_deg",
                                              units::ToDegrees(p.AlphaStall)));
        p.StallBlend         = units::Degrees(entry.GetNumber("stall_blend_deg",
                                              units::ToDegrees(p.StallBlend)));
        p.ReattachHysteresis = units::Degrees(entry.GetNumber("reattach_hysteresis_deg",
                                              units::ToDegrees(p.ReattachHysteresis)));
        p.CdMin              = entry.GetNumber("cd_min", p.CdMin);
        p.CdAlphaQuadratic   = entry.GetNumber("cd_alpha_quadratic", p.CdAlphaQuadratic);
        p.CdSeparatedMax     = entry.GetNumber("cd_separated_max", p.CdSeparatedMax);
        p.CmQuarterChord     = entry.GetNumber("cm_quarter_chord", p.CmQuarterChord);
        p.OswaldEfficiency   = entry.GetNumber("oswald_efficiency", p.OswaldEfficiency);
        p.ReferenceReynolds  = entry.GetNumber("reference_reynolds", p.ReferenceReynolds);
        return p;
    }

    /** Optional measured polars. Present tables replace the analytic curves. */
    bool ReadAirfoilTables(const JsonValue& entry, const std::string& name,
                           Airfoil& airfoil, AircraftLoadResult& result)
    {
        std::vector<Real> alphaDegrees;
        std::vector<Real> reynolds;
        if (!entry.GetNumberArray("alpha_table_deg", alphaDegrees) ||
            !entry.GetNumberArray("reynolds_table", reynolds))
        {
            return false;
        }

        std::vector<Real> alphaRadians;
        alphaRadians.reserve(alphaDegrees.size());
        for (Real deg : alphaDegrees) { alphaRadians.push_back(units::Degrees(deg)); }

        std::vector<Real> lift, drag, moment;
        if (!entry.GetNumberArray("cl_table", lift) ||
            !entry.GetNumberArray("cd_table", drag))
        {
            AddError(result, "airfoil '" + name +
                     "': alpha_table_deg and reynolds_table were given without cl_table/cd_table");
            return false;
        }
        entry.GetNumberArray("cm_table", moment);

        Table2D liftTable, dragTable, momentTable;
        std::string error;
        if (!liftTable.Build(alphaRadians, reynolds, lift, &error) ||
            !dragTable.Build(alphaRadians, reynolds, drag, &error))
        {
            AddError(result, "airfoil '" + name + "': " + error);
            return false;
        }
        if (!moment.empty())
        {
            momentTable.Build(alphaRadians, reynolds, moment, &error);
        }

        if (!airfoil.SetTables(liftTable, dragTable, momentTable, &error))
        {
            AddError(result, "airfoil '" + name + "': " + error);
            return false;
        }
        return true;
    }

    // ------------------------------------------------------------ surfaces --

    void ReadSurfaces(const JsonValue& root, AircraftDefinition& definition,
                      AircraftLoadResult& result)
    {
        const JsonValue& list = root["aero_surfaces"];
        if (!list.IsArray() || list.Size() == 0)
        {
            AddError(result, "'aero_surfaces' is missing or empty - an aircraft "
                             "with no lifting surfaces cannot fly");
            return;
        }

        for (size_t i = 0; i < list.Size(); ++i)
        {
            const JsonValue& entry = list.At(i);
            AeroSurfaceSpec spec;
            spec.Name = entry.GetString("name", "surface_" + std::to_string(i));

            bool roleOk = false;
            spec.Role = ParseRole(entry.GetString("role", "wing"), roleOk);
            if (!roleOk)
            {
                AddError(result, spec.Name + ": unknown role '" +
                         entry.GetString("role") + "'");
                continue;
            }

            const std::string airfoilName = entry.GetString("airfoil");
            spec.AirfoilIndex = definition.FindAirfoil(airfoilName);
            if (spec.AirfoilIndex < 0)
            {
                AddError(result, spec.Name + ": references unknown airfoil '" +
                         airfoilName + "'");
                continue;
            }

            spec.PositionBody = ReadVector(entry, "position_m", Vec3::Zero());
            spec.Area  = entry.GetNumber("area_m2", 0.0);
            spec.Chord = entry.GetNumber("chord_m", 0.0);
            spec.Span  = entry.GetNumber("span_m", 0.0);

            spec.Incidence = units::Degrees(entry.GetNumber("incidence_deg", 0.0));
            spec.Dihedral  = units::Degrees(entry.GetNumber("dihedral_deg", 0.0));
            spec.Twist     = units::Degrees(entry.GetNumber("twist_deg", 0.0));
            spec.Sweep     = units::Degrees(entry.GetNumber("sweep_deg", 0.0));

            // Fall back to the surface's own geometry when no effective aspect
            // ratio is given; span^2/area is the right first guess.
            const Real derivedAspectRatio = SafeDivide(Sq(spec.Span), spec.Area, 6.0);
            spec.EffectiveAspectRatio =
                entry.GetNumber("effective_aspect_ratio", derivedAspectRatio);

            const JsonValue& control = entry["control_surface"];
            if (control.IsObject())
            {
                bool channelOk = false;
                spec.Control.Channel = ParseChannel(control.GetString("channel", "aileron"),
                                                    channelOk);
                if (!channelOk)
                {
                    AddError(result, spec.Name + ": unknown control channel '" +
                             control.GetString("channel") + "'");
                    continue;
                }
                spec.HasControl = true;
                spec.Control.ChordFraction = control.GetNumber("chord_fraction", 0.25);
                spec.Control.SpanFraction  = control.GetNumber("span_fraction", 1.0);
                spec.Control.Direction     = control.GetNumber("direction", 1.0);
                spec.Control.Differential  = control.GetNumber("differential", 0.0);
                // Travel comes from the channel defaults unless overridden here.
                spec.Control.MaxDeflection = units::Degrees(
                    control.GetNumber("max_deflection_deg",
                        units::ToDegrees(definition.Channels[
                            static_cast<size_t>(spec.Control.Channel)].MaxDeflection)));
            }

            spec.InPropwash = entry.GetBool("in_propwash", false);
            definition.Surfaces.push_back(spec);
        }
    }

    // ---------------------------------------------------------- propulsion --

    void ReadPropulsion(const JsonValue& root, AircraftDefinition& definition)
    {
        const JsonValue& propulsion = root["propulsion"];
        if (!propulsion.IsObject()) { return; }

        PropulsionSpec& p = definition.Propulsion;

        const JsonValue& battery = propulsion["battery"];
        p.Battery.CellCount = static_cast<int>(battery.GetNumber("cell_count", 3.0));
        p.Battery.NominalCellVoltage = battery.GetNumber("nominal_cell_voltage_v", 3.70);
        p.Battery.FullCellVoltage    = battery.GetNumber("full_cell_voltage_v", 4.15);
        p.Battery.EmptyCellVoltage   = battery.GetNumber("empty_cell_voltage_v", 3.30);
        p.Battery.CapacityCoulombs   = units::MilliampHours(
            battery.GetNumber("capacity_mah", 2200.0));
        p.Battery.InternalResistance = battery.GetNumber("internal_resistance_ohm", 0.015);

        const JsonValue& esc = propulsion["esc"];
        p.Esc.MaxCurrent = esc.GetNumber("max_current_a", 40.0);
        p.Esc.Efficiency = esc.GetNumber("efficiency", 0.96);

        const JsonValue& motor = propulsion["motor"];
        p.Motor.KvRadPerSecondPerVolt = units::RPM(motor.GetNumber("kv_rpm_per_volt", 1000.0));
        p.Motor.Resistance    = motor.GetNumber("resistance_ohm", 0.085);
        p.Motor.NoLoadCurrent = motor.GetNumber("no_load_current_a", 0.9);
        p.Motor.MaxCurrent    = motor.GetNumber("max_current_a", 30.0);

        const JsonValue& propeller = propulsion["propeller"];
        p.Propeller.Diameter = ReadLength(propeller, "diameter_m", "diameter_in", 0.2794);
        p.Propeller.Pitch    = ReadLength(propeller, "pitch_m", "pitch_in", 0.1524);
        p.Propeller.BladeCount = static_cast<int>(propeller.GetNumber("blade_count", 2.0));
        p.Propeller.MomentOfInertia = propeller.GetNumber("moment_of_inertia_kg_m2", 1.5e-5);
        p.Propeller.Clockwise = propeller.GetString("rotation", "clockwise") != "counter_clockwise";

        const JsonValue& mount = propulsion["mount"];
        p.Mount.PositionBody = ReadVector(mount, "position_m", p.Mount.PositionBody);
        p.Mount.DownThrust   = units::Degrees(mount.GetNumber("down_thrust_deg", 2.0));
        p.Mount.RightThrust  = units::Degrees(mount.GetNumber("right_thrust_deg", 2.0));

        const JsonValue& propwash = propulsion["propwash"];
        p.Propwash.Enabled       = propwash.GetBool("enabled", true);
        p.Propwash.ConeHalfAngle = units::Degrees(propwash.GetNumber("cone_half_angle_deg", 6.0));
        p.Propwash.SwirlFactor   = propwash.GetNumber("swirl_factor", 0.35);
        p.Propwash.Strength      = propwash.GetNumber("strength", 1.0);
    }

    // -------------------------------------------------------- landing gear --

    void ReadLandingGear(const JsonValue& root, AircraftDefinition& definition,
                         AircraftLoadResult& result)
    {
        const JsonValue& list = root["landing_gear"];
        if (!list.IsArray()) { return; }

        for (size_t i = 0; i < list.Size(); ++i)
        {
            const JsonValue& entry = list.At(i);
            LandingGearSpec gear;
            gear.Name = entry.GetString("name", "gear_" + std::to_string(i));
            gear.PositionBody = ReadVector(entry, "position_m", Vec3::Zero());
            gear.Radius       = entry.GetNumber("radius_m", 0.028);
            gear.SpringRate   = entry.GetNumber("spring_n_per_m", 2000.0);
            gear.DamperRate   = entry.GetNumber("damper_ns_per_m", 50.0);
            gear.MaxTravel    = entry.GetNumber("max_travel_m", 0.020);
            gear.FrictionStatic    = entry.GetNumber("friction_static", 0.70);
            gear.FrictionDynamic   = entry.GetNumber("friction_dynamic", 0.55);
            gear.RollingResistance = entry.GetNumber("rolling_resistance", 0.12);
            gear.Steerable   = entry.GetBool("steerable", false);
            gear.MaxSteering = units::Degrees(entry.GetNumber("max_steering_deg", 0.0));

            if (gear.Steerable)
            {
                bool ok = false;
                gear.SteeringChannel = ParseChannel(entry.GetString("steering_channel", "rudder"), ok);
                if (!ok)
                {
                    AddWarning(result, gear.Name + ": unknown steering channel, using rudder");
                    gear.SteeringChannel = RCChannel::Rudder;
                }
            }

            definition.LandingGear.push_back(gear);
        }
    }

    // ------------------------------------------------------------ channels --

    void ReadChannels(const JsonValue& root, AircraftDefinition& definition)
    {
        const JsonValue& channels = root["control_channels"];
        if (!channels.IsObject()) { return; }

        static const char* const kKeys[kChannelCount] = {
            "aileron", "elevator", "throttle", "rudder", "flap", "aux1"
        };

        for (size_t i = 0; i < kChannelCount; ++i)
        {
            const JsonValue& entry = channels[kKeys[i]];
            if (!entry.IsObject()) { continue; }

            ChannelDefaults& d = definition.Channels[i];
            d.MaxDeflection = units::Degrees(entry.GetNumber("max_deflection_deg",
                                             units::ToDegrees(d.MaxDeflection)));
            d.Expo         = entry.GetNumber("expo", d.Expo);
            d.DualRate     = entry.GetNumber("dual_rate", d.DualRate);
            d.Differential = entry.GetNumber("differential", d.Differential);
            d.IdleFraction = entry.GetNumber("idle_fraction", d.IdleFraction);
        }
    }

    /** The speeds the aircraft is put into the air at, and the speed a pilot
     *  is told to fly an approach at.
     *
     *  This was never read. Every aeroplane in the roster used the defaults -
     *  16 and 11 - so the hangar showed the same approach speed for a 2.4 m
     *  glider and a warbird, SPAWN_AIR launched all four at the same speed, and
     *  the test rig flew the glider's "minimum sink" runs eleven metres a
     *  second too fast. Four aircraft's worth of measured targets were taken
     *  through it. Found by looking at the menu as a player rather than by
     *  reading the loader. */
    void ReadSpawn(const JsonValue& root, AircraftDefinition& definition)
    {
        const JsonValue& spawn = root["spawn"];
        if (!spawn.IsObject()) { return; }

        definition.CruiseSpeed = spawn.GetNumber("cruise_speed_mps", definition.CruiseSpeed);
        definition.ApproachSpeed = spawn.GetNumber("approach_speed_mps", definition.ApproachSpeed);
        definition.AirStartAltitude =
            spawn.GetNumber("air_start_altitude_m", definition.AirStartAltitude);
    }

    void ReadValidationTargets(const JsonValue& root, AircraftDefinition& definition)
    {
        const JsonValue& targets = root["validation_targets"];
        if (!targets.IsObject()) { return; }

        for (const auto& entry : targets.AsObject())
        {
            ValidationTarget target;
            target.Value     = entry.second.GetNumber("value", 0.0);
            target.Tolerance = entry.second.GetNumber("tolerance", 0.10);
            target.Locked    = entry.second.GetBool("locked", false);
            definition.ValidationTargets[entry.first] = target;
        }
    }
}

// ----------------------------------------------------------------- result ---

std::string AircraftLoadResult::Describe() const
{
    std::ostringstream out;
    if (Success) { out << "loaded"; } else { out << "FAILED"; }
    for (const std::string& error : Errors)   { out << "\n  error:   " << error; }
    for (const std::string& warning : Warnings) { out << "\n  warning: " << warning; }
    return out.str();
}

// ---------------------------------------------------------------- loading ---

AircraftLoadResult AircraftLoader::LoadFromString(const std::string& text,
                                                  AircraftDefinition& outDefinition,
                                                  const std::string& sourceName)
{
    AircraftLoadResult result;
    outDefinition = AircraftDefinition{};

    JsonParseResult parse;
    const JsonValue root = ParseJson(text, parse);
    if (!parse.Success)
    {
        AddError(result, sourceName + ": " + parse.Describe());
        return result;
    }
    if (!root.IsObject())
    {
        AddError(result, sourceName + ": the top level must be an object");
        return result;
    }

    outDefinition.FormatVersion = static_cast<int>(root.GetNumber("format_version", 1.0));
    if (outDefinition.FormatVersion != 1)
    {
        AddError(result, sourceName + ": unsupported format_version " +
                 std::to_string(outDefinition.FormatVersion));
        return result;
    }

    outDefinition.Name        = root.GetString("name", "Unnamed");
    outDefinition.Description = root.GetString("description");

    // ------------------------------------------------------------- mass ----
    const JsonValue& mass = root["mass"];
    outDefinition.Mass = mass.GetNumber("mass_kg", 1.0);
    outDefinition.CgOffsetFromMeshOrigin =
        ReadVector(mass, "cg_offset_from_mesh_origin_m", Vec3::Zero());

    const JsonValue& inertia = mass["inertia"];
    if (inertia.IsObject())
    {
        outDefinition.Inertia = Mat3::InertiaTensor(
            inertia.GetNumber("ixx_kg_m2", 0.05),
            inertia.GetNumber("iyy_kg_m2", 0.05),
            inertia.GetNumber("izz_kg_m2", 0.08),
            inertia.GetNumber("ixy_kg_m2", 0.0),
            inertia.GetNumber("ixz_kg_m2", 0.0),
            inertia.GetNumber("iyz_kg_m2", 0.0));
        outDefinition.HasExplicitInertia = true;
    }

    // -------------------------------------------------------- reference ----
    const JsonValue& reference = root["reference"];
    outDefinition.WingArea  = reference.GetNumber("wing_area_m2", 0.32);
    outDefinition.WingSpan  = reference.GetNumber("wingspan_m", 1.50);
    outDefinition.MeanChord = reference.GetNumber("mean_aerodynamic_chord_m",
                                SafeDivide(outDefinition.WingArea, outDefinition.WingSpan, 0.2));

    // --------------------------------------------------------- airfoils ----
    const JsonValue& airfoils = root["airfoils"];
    if (!airfoils.IsObject() || airfoils.Size() == 0)
    {
        AddError(result, sourceName + ": 'airfoils' is missing or empty");
        return result;
    }
    for (const auto& entry : airfoils.AsObject())
    {
        Airfoil airfoil(ReadAirfoilParameters(entry.second));
        ReadAirfoilTables(entry.second, entry.first, airfoil, result);
        outDefinition.AirfoilNames.push_back(entry.first);
        outDefinition.Airfoils.push_back(airfoil);
    }

    // Channels are read before surfaces: a control surface's default travel
    // comes from its channel.
    ReadChannels(root, outDefinition);
    ReadSurfaces(root, outDefinition, result);

    // -------------------------------------------------------- fuselage -----
    const JsonValue& fuselage = root["fuselage"];
    if (fuselage.IsObject())
    {
        FuselageSpec& f = outDefinition.Fuselage;
        f.PositionBody  = ReadVector(fuselage, "position_m", Vec3::Zero());
        f.Length        = fuselage.GetNumber("length_m", 1.0);
        f.FrontalArea   = fuselage.GetNumber("frontal_area_m2", 0.011);
        f.SideArea      = fuselage.GetNumber("side_area_m2", 0.055);
        f.CdFrontal     = fuselage.GetNumber("cd_frontal", 0.35);
        f.CdSide        = fuselage.GetNumber("cd_side", 0.60);
        f.CnBetaPerRad  = fuselage.GetNumber("cn_beta_per_rad", -0.06);
        f.ParasiteArea  = fuselage.GetNumber("parasite_area_m2", 0.0);
    }
    else
    {
        AddWarning(result, sourceName + ": no 'fuselage' block; using defaults");
    }

    const JsonValue& aerodynamics = root["aerodynamics"];
    if (aerodynamics.IsObject())
    {
        outDefinition.DownwashScale = aerodynamics.GetNumber("downwash_scale", 1.0);
    }

    ReadPropulsion(root, outDefinition);
    ReadLandingGear(root, outDefinition, result);
    ReadSpawn(root, outDefinition);
    ReadValidationTargets(root, outDefinition);

    const AircraftLoadResult validation = Validate(outDefinition);
    for (const std::string& error : validation.Errors)   { AddError(result, sourceName + ": " + error); }
    for (const std::string& warning : validation.Warnings) { AddWarning(result, sourceName + ": " + warning); }

    result.Success = result.Errors.empty();
    if (result.Success)
    {
        RC_LOG(Aero, Info, "Loaded aircraft '%s': %zu sections, %zu airfoils, %zu wheels.",
               outDefinition.Name.c_str(), outDefinition.Surfaces.size(),
               outDefinition.Airfoils.size(), outDefinition.LandingGear.size());
    }
    return result;
}

AircraftLoadResult AircraftLoader::LoadFromFile(const std::string& path,
                                                AircraftDefinition& outDefinition)
{
    std::string text;
    std::string error;
    if (!ReadTextFile(path, text, error))
    {
        AircraftLoadResult result;
        AddError(result, error);
        return result;
    }
    return LoadFromString(text, outDefinition, path);
}

// -------------------------------------------------------------- validation --

AircraftLoadResult AircraftLoader::Validate(const AircraftDefinition& definition)
{
    AircraftLoadResult result;

    if (!(definition.Mass > 0.0))
    {
        AddError(result, "mass must be positive");
    }
    if (!(definition.WingArea > 0.0) || !(definition.WingSpan > 0.0))
    {
        AddError(result, "reference wing area and span must be positive");
    }

    const MassProperties properties = definition.BuildMassProperties();
    if (!properties.IsValid())
    {
        AddError(result, "the inertia tensor is not invertible");
    }
    else if (definition.HasExplicitInertia)
    {
        // Principal moments of a real mass distribution obey the triangle
        // inequality. Violating it is an easy typo and produces nonsense.
        const Real ixx = definition.Inertia.m[0][0];
        const Real iyy = definition.Inertia.m[1][1];
        const Real izz = definition.Inertia.m[2][2];
        if (ixx + iyy < izz || iyy + izz < ixx || izz + ixx < iyy)
        {
            AddError(result, "the inertia tensor violates the triangle inequality "
                             "and cannot describe a real mass distribution");
        }
    }

    if (definition.Surfaces.empty())
    {
        AddError(result, "no aerodynamic surfaces");
    }

    Real totalArea = 0.0;
    for (const AeroSurfaceSpec& surface : definition.Surfaces)
    {
        if (!(surface.Area > 0.0) || !(surface.Chord > 0.0) || !(surface.Span > 0.0))
        {
            AddError(result, surface.Name + ": area, chord and span must all be positive");
        }
        if (surface.AirfoilIndex < 0 ||
            static_cast<size_t>(surface.AirfoilIndex) >= definition.Airfoils.size())
        {
            AddError(result, surface.Name + ": airfoil index out of range");
        }
        if (surface.HasControl)
        {
            const Real fraction = surface.Control.ChordFraction;
            if (!(fraction > 0.0) || !(fraction < 1.0))
            {
                AddError(result, surface.Name +
                         ": control chord_fraction must lie strictly between 0 and 1");
            }
            if (surface.Control.MaxDeflection <= 0.0)
            {
                AddError(result, surface.Name + ": control travel must be positive");
            }
        }
        if (surface.Role == SurfaceRole::Wing) { totalArea += surface.Area; }
    }

    if (totalArea > 0.0 && definition.WingArea > 0.0)
    {
        const Real ratio = totalArea / definition.WingArea;
        if (ratio < 0.9 || ratio > 1.1)
        {
            AddWarning(result, "the wing sections sum to " + std::to_string(totalArea) +
                       " m^2 but the reference area is " + std::to_string(definition.WingArea) +
                       " m^2; coefficients will not mean what they appear to");
        }
    }

    const PropulsionSpec& propulsion = definition.Propulsion;
    if (propulsion.Propeller.Diameter <= 0.0)
    {
        AddError(result, "propeller diameter must be positive");
    }
    else if (propulsion.Propeller.Pitch >= propulsion.Propeller.Diameter)
    {
        AddWarning(result, "propeller pitch is greater than its diameter, which is "
                           "very unusual outside a folding prop");
    }
    if (propulsion.Motor.KvRadPerSecondPerVolt <= 0.0)
    {
        AddError(result, "motor KV must be positive");
    }
    if (propulsion.Battery.CellCount <= 0)
    {
        AddError(result, "battery cell count must be positive");
    }

    for (const LandingGearSpec& gear : definition.LandingGear)
    {
        if (gear.SpringRate <= 0.0)
        {
            AddError(result, gear.Name + ": spring rate must be positive");
        }
        if (gear.PositionBody.z <= 0.0)
        {
            AddWarning(result, gear.Name + ": sits at or above the CG, which would put "
                               "the wheel on top of the aircraft");
        }
    }

    result.Success = result.Errors.empty();
    return result;
}

} // namespace rc
