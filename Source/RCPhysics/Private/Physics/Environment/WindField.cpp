#include "RCPhysics/Physics/Environment/WindField.h"

#include "RCPhysics/Physics/Environment/LiftField.h"

#include <cmath>

namespace rc
{
namespace
{
    /** Deterministic 32-bit hash. Used instead of any std random engine so that
     *  the same seed produces the same air on every platform and every build. */
    std::uint32_t Hash(std::uint32_t x)
    {
        x ^= x >> 16;
        x *= 0x7feb352du;
        x ^= x >> 15;
        x *= 0x846ca68bu;
        x ^= x >> 16;
        return x;
    }

    /** Uniform in [0, 1). */
    Real Uniform(std::uint32_t seed, std::uint32_t index)
    {
        return static_cast<Real>(Hash(seed ^ Hash(index))) / 4294967296.0;
    }

    /** Uniform in [lo, hi). */
    Real UniformRange(std::uint32_t seed, std::uint32_t index, Real lo, Real hi)
    {
        return lo + (hi - lo) * Uniform(seed, index);
    }

    /** A unit vector spread evenly over the sphere. */
    Vec3 UnitVector(std::uint32_t seed, std::uint32_t index)
    {
        const Real z     = UniformRange(seed, index * 3u + 0u, -1.0, 1.0);
        const Real theta = UniformRange(seed, index * 3u + 1u, 0.0, kTwoPi);
        const Real r     = std::sqrt(Max(0.0, 1.0 - z * z));
        return Vec3(r * std::cos(theta), r * std::sin(theta), z);
    }
}

WindField::WindField()
{
    RebuildModes();
}

void WindField::SetSeed(std::uint32_t seed)
{
    Seed = (seed == 0u) ? 1u : seed;
    RebuildModes();
}

void WindField::SetSteady(Real speedMetresPerSecond, Real fromDirectionRadians)
{
    SteadySpeed     = Max(speedMetresPerSecond, 0.0);
    SteadyDirection = fromDirectionRadians;
}

void WindField::SetGust(Real amplitudeMetresPerSecond, Real meanIntervalSeconds)
{
    GustAmplitude = Max(amplitudeMetresPerSecond, 0.0);
    GustInterval  = Max(meanIntervalSeconds, 1.0);
}

void WindField::SetTurbulence(Real intensityMetresPerSecond, Real lengthScaleMetres)
{
    TurbulenceIntensity   = Max(intensityMetresPerSecond, 0.0);
    TurbulenceLengthScale = Max(lengthScaleMetres, 0.25);
    RebuildModes();
}

void WindField::RebuildModes()
{
    // Spectral synthesis: a handful of sinusoidal modes with seeded directions,
    // wavelengths and phases. Amplitudes follow a Kolmogorov-like -5/3 slope,
    // so the large eddies dominate - which is what makes turbulence feel like
    // air rather than like vibration.
    Real energy = 0.0;
    for (size_t i = 0; i < kTurbulenceModes; ++i)
    {
        const std::uint32_t index = static_cast<std::uint32_t>(i) + 1u;
        TurbulenceMode& mode = Modes[i];

        const Real octave     = static_cast<Real>(i);
        const Real wavelength = TurbulenceLengthScale / std::pow(2.0, octave * 0.5);

        mode.Direction  = UnitVector(Seed, index * 7u).Normalized(Vec3::UnitX());
        mode.WaveVector = UnitVector(Seed, index * 11u).Normalized(Vec3::UnitY())
                        * (kTwoPi / Max(wavelength, 0.1));
        mode.Amplitude  = std::pow(wavelength, 1.0 / 3.0);
        mode.Phase      = UniformRange(Seed, index * 13u, 0.0, kTwoPi);

        // Eddy turnover: an eddy of size L carrying velocity fluctuations u'
        // rearranges itself in about L/u'. Without this term the turbulence is
        // a rigid pattern in space, and an aircraft holding station in zero
        // mean wind would feel nothing changing at all.
        constexpr Real kTurnoverFactor = 0.6;
        mode.TemporalRate = mode.WaveVector.Length() * TurbulenceIntensity * kTurnoverFactor;

        energy += 0.5 * Sq(mode.Amplitude);   // <sin^2> = 1/2
    }

    // Normalise so the per-axis RMS matches the requested intensity. Isotropic
    // directions spread the energy across three axes.
    const Real perAxisRms = std::sqrt(Max(energy / 3.0, kEpsilon));
    const Real scale = SafeDivide(TurbulenceIntensity, perAxisRms, 0.0);
    for (TurbulenceMode& mode : Modes)
    {
        mode.Amplitude *= scale;
    }
}

void WindField::Advance(Real dt)
{
    if (IsFinite(dt) && dt > 0.0)
    {
        CurrentTime += dt;
    }
}

void WindField::Reset()
{
    CurrentTime = 0.0;
}

Vec3 WindField::SteadyVector() const
{
    // Meteorological convention: the direction is where the wind comes FROM, so
    // the velocity vector points the opposite way. NED, so X is North.
    return Vec3(-SteadySpeed * std::cos(SteadyDirection),
                -SteadySpeed * std::sin(SteadyDirection),
                0.0);
}

Real WindField::GustFraction() const
{
    if (GustAmplitude <= 0.0)
    {
        return 0.0;
    }

    // A schedule of 1-cos gusts at seeded intervals. Each gust's arrival time,
    // duration and strength come from the index, so the whole sequence is
    // reproducible from the seed alone with no state to carry.
    const auto cycle = static_cast<std::uint32_t>(std::floor(CurrentTime / GustInterval));
    const Real cycleStart = static_cast<Real>(cycle) * GustInterval;

    const Real offset   = UniformRange(Seed, cycle * 5u + 1u, 0.0, 0.5) * GustInterval;
    const Real duration = UniformRange(Seed, cycle * 5u + 2u, 0.25, 0.6) * GustInterval;
    const Real strength = UniformRange(Seed, cycle * 5u + 3u, 0.4, 1.0);

    const Real since = CurrentTime - (cycleStart + offset);
    if (since < 0.0 || since > duration)
    {
        return 0.0;
    }

    // 1 - cos over the window: smooth arrival, smooth departure, no step.
    return strength * 0.5 * (1.0 - std::cos(kTwoPi * since / duration));
}

Vec3 WindField::SampleWindOnly(const Vec3& positionWorld) const
{
    const Vec3 steady = SteadyVector();
    Vec3 wind = steady;

    if (GustAmplitude > 0.0)
    {
        const Vec3 direction = steady.Normalized(Vec3::UnitX());
        wind += direction * (GustAmplitude * GustFraction());
    }

    if (TurbulenceIntensity > 0.0)
    {
        // Frozen field advected downwind: the aircraft flies through a spatial
        // pattern rather than sitting in a shaking box, so its response scales
        // correctly with airspeed.
        const Vec3 samplePoint = positionWorld - steady * CurrentTime;
        for (const TurbulenceMode& mode : Modes)
        {
            const Real phase = Dot(mode.WaveVector, samplePoint)
                             + mode.TemporalRate * CurrentTime
                             + mode.Phase;
            wind += mode.Direction * (mode.Amplitude * std::sin(phase));
        }
    }


    return wind;
}

Vec3 WindField::SampleWorld(const Vec3& positionWorld) const
{
    Vec3 air = SampleWindOnly(positionWorld);
    // Rising air, added here so it reaches the aerodynamics through the same
    // per-section sampling the wind does - which is what gives a wing with one
    // tip in a thermal the rolling moment a pilot turns towards.
    if (Lift != nullptr)
    {
        air += Lift->VelocityAt(positionWorld, CurrentTime, SteadyVector());
    }
    return air;
}

} // namespace rc
