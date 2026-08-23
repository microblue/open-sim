// OpenRC Simulator - ISA standard atmosphere.
//
// Provides the three numbers the aerodynamics actually needs at a given
// altitude: density (dynamic pressure), dynamic viscosity (Reynolds number) and
// speed of sound (unused at RC speeds, but free).
//
// Viscosity is not optional here. A 1.5 m trainer runs at Re ~ 2e5, where the
// coefficients depend strongly on Reynolds number, so anything that drops mu
// silently removes the main thing that distinguishes RC aerodynamics from
// full-scale aerodynamics.
#pragma once

#include "RCPhysics/Core/Types.h"
#include "RCPhysics/Core/Units/Units.h"

namespace rc
{
struct AtmosphereSample
{
    Real Density          = units::kSeaLevelDensity;        ///< kg/m^3
    Real Pressure         = units::kSeaLevelPressure;       ///< Pa
    Real Temperature      = units::kSeaLevelTemperature;    ///< K
    Real DynamicViscosity = units::kSeaLevelDynamicViscosity; ///< Pa*s
    Real SpeedOfSound     = 340.294;                        ///< m/s
};

class Atmosphere
{
public:
    /** Field elevation above mean sea level [m]. An RC field at 600 m sits in
     *  noticeably thinner air than one at sea level - about 6 % less density,
     *  which is 3 % on stall speed and very obvious on a hot day. */
    void SetFieldElevation(Real metresAboveSeaLevel);
    Real GetFieldElevation() const { return FieldElevation; }

    /** Offset from the ISA temperature profile [K]. +15 on a hot afternoon. */
    void SetTemperatureOffset(Real kelvin);
    Real GetTemperatureOffset() const { return TemperatureOffset; }

    /** Sample at a height above the field [m]. */
    AtmosphereSample SampleAboveField(Real heightAboveField) const;

    /** Sample at a geopotential altitude above mean sea level [m]. */
    AtmosphereSample SampleAboveSeaLevel(Real altitude) const;

    /** Sea-level ISA, for tests and for coefficient reference conditions. */
    static AtmosphereSample StandardSeaLevel();

    /** Sutherland's law. Public because the validation suite checks it against
     *  published values. */
    static Real DynamicViscosityAt(Real temperatureKelvin);

    /** Reynolds number for a reference length [m] at a given speed [m/s]. */
    static Real ReynoldsNumber(const AtmosphereSample& sample, Real speed, Real referenceLength);

private:
    Real FieldElevation    = 0.0;
    Real TemperatureOffset = 0.0;
};

} // namespace rc
