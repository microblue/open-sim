// OpenRC Simulator - the data-driven description of an aircraft.
//
// There is no `class Trainer`, no `class Warbird`, no `class Glider`. A new
// flyable aircraft is a mesh plus a JSON file:
//
//     mesh + aircraft.json = new flyable airplane
//
// Everything here is SI. The loader converts from the modeller-friendly units
// used in the file (inches, degrees, mAh, KV) exactly once, at load time.
#pragma once

#include "RCPhysics/Core/Math/Mat3.h"
#include "RCPhysics/Input/ChannelTypes.h"
#include "RCPhysics/Physics/Aero/AeroSurface.h"
#include "RCPhysics/Physics/Aero/Airfoil.h"
#include "RCPhysics/Physics/Aero/FuselageAero.h"
#include "RCPhysics/Physics/Dynamics/RigidBodyState.h"

#include <map>
#include <string>
#include <vector>

namespace rc
{
// ------------------------------------------------------------- propulsion ---

struct BatterySpec
{
    int  CellCount            = 3;
    Real NominalCellVoltage   = 3.70;
    Real FullCellVoltage      = 4.15;
    Real EmptyCellVoltage     = 3.30;
    Real CapacityCoulombs     = 7920.0;   ///< 2200 mAh
    Real InternalResistance   = 0.015;    ///< ohm

    Real NominalVoltage() const { return CellCount * NominalCellVoltage; }
    Real FullVoltage() const    { return CellCount * FullCellVoltage; }
    Real EmptyVoltage() const   { return CellCount * EmptyCellVoltage; }
};

struct EscSpec
{
    Real MaxCurrent = 40.0;   ///< A
    Real Efficiency = 0.96;
};

struct MotorSpec
{
    /** Motor constant in SI: rad/s per volt. The file gives RPM/V. */
    Real KvRadPerSecondPerVolt = 104.72;   ///< 1000 KV
    Real Resistance      = 0.085;          ///< ohm
    Real NoLoadCurrent   = 0.9;            ///< A
    Real MaxCurrent      = 30.0;           ///< A
};

struct PropellerSpec
{
    Real Diameter  = 0.2794;   ///< m (11 in)
    Real Pitch     = 0.1524;   ///< m (6 in)
    int  BladeCount = 2;
    Real MomentOfInertia = 1.5e-5;   ///< kg m^2
    /** Seen from behind, i.e. from where the pilot stands. */
    bool Clockwise = true;

    Real DiskArea() const { return kPi * Sq(0.5 * Diameter); }
    Real PitchOverDiameter() const { return SafeDivide(Pitch, Diameter, 0.5); }
};

struct MotorMountSpec
{
    Vec3 PositionBody = Vec3(0.35, 0.0, -0.01);
    Real DownThrust   = 0.0349;   ///< rad (2 deg)
    Real RightThrust  = 0.0349;   ///< rad (2 deg)

    /** Thrust axis in body coordinates, derived from the two rigging angles. */
    Vec3 ThrustAxisBody() const;
};

struct PropwashSpec
{
    bool Enabled        = true;
    Real ConeHalfAngle  = 0.1047;   ///< rad (6 deg)
    Real SwirlFactor    = 0.35;
    Real Strength       = 1.0;
};

struct PropulsionSpec
{
    BatterySpec    Battery;
    EscSpec        Esc;
    MotorSpec      Motor;
    PropellerSpec  Propeller;
    MotorMountSpec Mount;
    PropwashSpec   Propwash;
};

// ----------------------------------------------------------- landing gear ---

struct LandingGearSpec
{
    std::string Name;
    Vec3 PositionBody = Vec3::Zero();   ///< wheel centre at full extension
    Real Radius       = 0.028;
    Real SpringRate   = 2000.0;   ///< N/m
    Real DamperRate   = 50.0;     ///< N s/m
    Real MaxTravel    = 0.020;    ///< m
    Real FrictionStatic  = 0.70;
    Real FrictionDynamic = 0.55;
    Real RollingResistance = 0.12;
    bool Steerable = false;
    RCChannel SteeringChannel = RCChannel::Rudder;
    Real MaxSteering = 0.0;   ///< rad
};

// ---------------------------------------------------------------- channels --

struct ChannelDefaults
{
    Real MaxDeflection = 0.3491;   ///< rad
    Real Expo          = 0.0;
    Real DualRate      = 1.0;
    Real Differential  = 0.0;
    Real IdleFraction  = 0.0;      ///< throttle only
};

// ------------------------------------------------------------ validation ----

struct ValidationTarget
{
    Real Value     = 0.0;
    Real Tolerance = 0.10;
    /** False means the number is a first-principles seed rather than a
     *  measurement; the regression suite reports but does not fail on it. */
    bool Locked    = false;

    bool Accepts(Real measured) const
    {
        return std::fabs(measured - Value) <= std::fabs(Value) * Tolerance;
    }
};

// --------------------------------------------------------------- aircraft ---

struct AircraftDefinition
{
    int         FormatVersion = 1;
    std::string Name = "Unnamed";
    std::string Description;

    // mass
    Real Mass = 1.0;                       ///< kg
    Vec3 CgOffsetFromMeshOrigin = Vec3::Zero();
    Mat3 Inertia = Mat3::Diagonal(0.05, 0.05, 0.08);
    bool HasExplicitInertia = false;

    // reference geometry for coefficients
    Real WingArea = 0.32;
    Real WingSpan = 1.50;
    Real MeanChord = 0.2133;

    std::vector<std::string> AirfoilNames;
    std::vector<Airfoil>     Airfoils;

    std::vector<AeroSurfaceSpec> Surfaces;
    FuselageSpec                 Fuselage;
    PropulsionSpec               Propulsion;
    std::vector<LandingGearSpec> LandingGear;

    std::array<ChannelDefaults, kChannelCount> Channels;

    /** Multiplies the computed downwash at the tail. 1 uses the lifting-line
     *  value; the field exists so a measured wind-tunnel figure can scale it. */
    Real DownwashScale = 1.0;

    /** Multiplies the strength of ground effect. 1 is the textbook image-vortex
     *  model (see Aircraft::GroundEffectInducedFactor); 0 switches it off, which
     *  the validation suite uses to measure what ground effect itself adds. */
    Real GroundEffectScale = 1.0;

    Real CruiseSpeed      = 16.0;
    Real ApproachSpeed    = 11.0;
    Real AirStartAltitude = 50.0;

    std::map<std::string, ValidationTarget> ValidationTargets;

    /** Index of a named airfoil, or -1. */
    int FindAirfoil(const std::string& name) const;

    /** Mass properties for the dynamics layer. Uses the explicit inertia tensor
     *  when the file provided one, and otherwise the estimate. */
    MassProperties BuildMassProperties() const;

    /** Estimate an inertia tensor from geometry, for definitions that do not
     *  supply one. Non-dimensional radii of gyration calibrated against a
     *  component-by-component sum for the Trainer 1500. */
    static Mat3 EstimateInertia(Real mass, Real wingSpan, Real fuselageLength);
};

} // namespace rc
