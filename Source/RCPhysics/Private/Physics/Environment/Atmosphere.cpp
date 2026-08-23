#include "RCPhysics/Physics/Environment/Atmosphere.h"

#include <cmath>

namespace rc
{
namespace
{
    /** ISA troposphere lapse rate [K/m]. */
    constexpr Real kLapseRate = 0.0065;

    /** Sutherland's law constants for air. */
    constexpr Real kSutherlandC1 = 1.458e-6;   // kg/(m*s*sqrt(K))
    constexpr Real kSutherlandS  = 110.4;      // K

    /** The troposphere model stops making sense above this; RC aircraft never
     *  get near it, but clamping keeps a bad altitude from producing NaN. */
    constexpr Real kMaxModelledAltitude = 11000.0;
}

void Atmosphere::SetFieldElevation(Real metresAboveSeaLevel)
{
    FieldElevation = Clamp(metresAboveSeaLevel, -500.0, kMaxModelledAltitude);
}

void Atmosphere::SetTemperatureOffset(Real kelvin)
{
    TemperatureOffset = Clamp(kelvin, -40.0, 50.0);
}

Real Atmosphere::DynamicViscosityAt(Real temperatureKelvin)
{
    const Real t = Max(temperatureKelvin, 1.0);
    return kSutherlandC1 * t * std::sqrt(t) / (t + kSutherlandS);
}

AtmosphereSample Atmosphere::SampleAboveSeaLevel(Real altitude) const
{
    const Real h = Clamp(altitude, -500.0, kMaxModelledAltitude);

    // ISA temperature profile, then the offset. The offset shifts temperature
    // and therefore density, but not the pressure profile - which is what
    // makes a hot day feel like a higher field rather than a lower one.
    const Real isaTemperature = units::kSeaLevelTemperature - kLapseRate * h;
    const Real temperature = isaTemperature + TemperatureOffset;

    const Real exponent = units::kGravity / (units::kAirGasConstant * kLapseRate);
    const Real pressure = units::kSeaLevelPressure
                        * std::pow(isaTemperature / units::kSeaLevelTemperature, exponent);

    AtmosphereSample sample;
    sample.Pressure         = pressure;
    sample.Temperature      = temperature;
    sample.Density          = pressure / (units::kAirGasConstant * temperature);
    sample.DynamicViscosity = DynamicViscosityAt(temperature);
    sample.SpeedOfSound     = std::sqrt(units::kAirGamma * units::kAirGasConstant * temperature);
    return sample;
}

AtmosphereSample Atmosphere::SampleAboveField(Real heightAboveField) const
{
    return SampleAboveSeaLevel(FieldElevation + heightAboveField);
}

AtmosphereSample Atmosphere::StandardSeaLevel()
{
    return Atmosphere().SampleAboveSeaLevel(0.0);
}

Real Atmosphere::ReynoldsNumber(const AtmosphereSample& sample, Real speed, Real referenceLength)
{
    if (referenceLength <= kEpsilon || sample.DynamicViscosity <= kEpsilon)
    {
        return 0.0;
    }
    return sample.Density * std::fabs(speed) * referenceLength / sample.DynamicViscosity;
}

} // namespace rc
