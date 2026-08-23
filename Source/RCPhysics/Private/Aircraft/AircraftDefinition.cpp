#include "RCPhysics/Aircraft/AircraftDefinition.h"

#include <cmath>

namespace rc
{
Vec3 MotorMountSpec::ThrustAxisBody() const
{
    // Start along the nose, tilt down, then tilt right. Down thrust points the
    // axis below the body X axis, which in FRD is +Z.
    const Real cd = std::cos(DownThrust);
    const Real sd = std::sin(DownThrust);
    const Real cr = std::cos(RightThrust);
    const Real sr = std::sin(RightThrust);
    return Vec3(cd * cr, cd * sr, sd).Normalized(Vec3::UnitX());
}

int AircraftDefinition::FindAirfoil(const std::string& name) const
{
    for (size_t i = 0; i < AirfoilNames.size(); ++i)
    {
        if (AirfoilNames[i] == name) { return static_cast<int>(i); }
    }
    return -1;
}

Mat3 AircraftDefinition::EstimateInertia(Real mass, Real wingSpan, Real fuselageLength)
{
    // Radii of gyration as fractions of the relevant length. Full-scale figures
    // (0.25 / 0.35 / 0.39) are far too high for a model: a foam wing carries a
    // small fraction of the mass, and there are no engines out on the span.
    // These are calibrated against a component sum for the Trainer 1500.
    constexpr Real kRollRadiusFraction  = 0.16;
    constexpr Real kPitchRadiusFraction = 0.24;
    constexpr Real kYawRadiusFraction   = 0.25;

    const Real m = Max(mass, kEpsilon);
    const Real b = Max(wingSpan, 0.05);
    const Real l = Max(fuselageLength, 0.05);
    const Real yawLength = 0.5 * (b + l);

    return Mat3::Diagonal(m * Sq(b * kRollRadiusFraction),
                          m * Sq(l * kPitchRadiusFraction),
                          m * Sq(yawLength * kYawRadiusFraction));
}

MassProperties AircraftDefinition::BuildMassProperties() const
{
    MassProperties properties;
    properties.Mass = Max(Mass, kEpsilon);
    properties.Inertia = HasExplicitInertia
                       ? Inertia
                       : EstimateInertia(Mass, WingSpan, Fuselage.Length);
    properties.Finalize();
    return properties;
}

} // namespace rc
