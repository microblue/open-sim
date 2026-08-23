// OpenRC Simulator - wind, gusts and turbulence.
//
// Three things a pilot reads from across the field, and all three must agree
// with what the aircraft feels: the windsock, the trees, and the model.
//
// EVERYTHING here is seeded. Given the same seed and the same elapsed time the
// air is identical, which is what makes the regression suite meaningful - a
// takeoff-distance test cannot be repeatable if the gusts are not.
//
// Turbulence is frozen-field: a spatial pattern advected downwind by the mean
// wind (Taylor's hypothesis). That gets the important behaviour for free - the
// aircraft flies THROUGH the gusts, so its response scales with airspeed, and a
// pattern with a wingspan-scale wavelength rolls the aircraft rather than just
// displacing it.
#pragma once

#include "RCPhysics/Core/Math/Vec3.h"
#include "RCPhysics/Core/Types.h"

#include <array>

namespace rc
{
class WindField
{
public:
    static constexpr size_t kTurbulenceModes = 8;

    WindField();

    /** Reseed every stochastic process. Call before a validation run. */
    void SetSeed(std::uint32_t seed);
    std::uint32_t GetSeed() const { return Seed; }

    /** Steady wind. `fromDirection` is meteorological - the direction the wind
     *  blows FROM, measured clockwise from North [rad]. A "270" wind blows from
     *  the west, towards the east. */
    void SetSteady(Real speedMetresPerSecond, Real fromDirectionRadians);
    Real GetSteadySpeed() const { return SteadySpeed; }
    Real GetSteadyDirection() const { return SteadyDirection; }

    /** Peak gust speed above the steady wind, and the average interval between
     *  gusts [s]. Gusts arrive along the mean wind direction. */
    void SetGust(Real amplitudeMetresPerSecond, Real meanIntervalSeconds);

    /** RMS turbulence intensity [m/s] and the length scale of the largest eddy
     *  [m]. A length scale near the wingspan is what makes turbulence roll the
     *  aircraft; a much larger one just moves it around. */
    void SetTurbulence(Real intensityMetresPerSecond, Real lengthScaleMetres);

    /** Advance the field. Deterministic in `dt`. */
    void Advance(Real dt);

    void Reset();

    Real Time() const { return CurrentTime; }

    /** Wind velocity at a world position, NED [m/s]. This is the velocity of
     *  the AIR, so an aircraft's velocity relative to the air is its ground
     *  velocity minus this. */
    Vec3 SampleWorld(const Vec3& positionWorld) const;

    /** The steady component alone - what a windsock averages out to. */
    Vec3 SteadyVector() const;

    /** Current gust strength, 0..1 of the configured amplitude. Drives the
     *  windsock and the vegetation so they agree with what the model feels. */
    Real GustFraction() const;

private:
    struct TurbulenceMode
    {
        Vec3 Direction  = Vec3::UnitX();   ///< unit, the axis this mode shakes
        Vec3 WaveVector = Vec3::Zero();    ///< rad/m
        Real Amplitude  = 0.0;             ///< m/s
        Real Phase      = 0.0;             ///< rad
        /** Intrinsic decorrelation rate [rad/s]. Frozen-field advection alone
         *  freezes the air solid when the mean wind is zero; real eddies turn
         *  over on a timescale of their size divided by the fluctuation
         *  velocity, whether or not the air is going anywhere. */
        Real TemporalRate = 0.0;
    };

    void RebuildModes();

    std::uint32_t Seed = 1u;

    Real SteadySpeed     = 0.0;
    Real SteadyDirection = 0.0;

    Real GustAmplitude = 0.0;
    Real GustInterval  = 12.0;

    Real TurbulenceIntensity  = 0.0;
    Real TurbulenceLengthScale = 6.0;

    Real CurrentTime = 0.0;

    std::array<TurbulenceMode, kTurbulenceModes> Modes;
};

} // namespace rc
