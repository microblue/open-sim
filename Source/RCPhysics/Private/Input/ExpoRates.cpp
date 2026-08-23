#include "RCPhysics/Input/ExpoRates.h"

namespace rc
{
Real ApplyExpo(Real normalized, Real expo)
{
    const Real e = Clamp(expo, 0.0, 1.0);
    const Real x = ClampUnit(normalized);
    return e * x * x * x + (1.0 - e) * x;
}

Real ExpoCentreSensitivity(Real expo)
{
    // d/dx (e x^3 + (1-e) x) at x = 0.
    return 1.0 - Clamp(expo, 0.0, 1.0);
}

Real ChannelShaping::Apply(Real normalized, bool bipolar) const
{
    if (RawMode)
    {
        return bipolar ? ClampUnit(normalized) : Clamp(normalized, 0.0, 1.0);
    }

    Real value = normalized;

    if (bipolar)
    {
        value = ApplyExpo(value, Expo);
        value *= Clamp(DualRate, 0.0, 1.0);
        value += Trim;
        return ClampUnit(value);
    }

    // Throttle: expo is applied over 0..1 rather than about a centre, and trim
    // raises the idle point rather than shifting a neutral.
    value = ApplyExpo(value, Expo);
    value *= Clamp(DualRate, 0.0, 1.0);
    value += Trim;
    return Clamp(value, 0.0, 1.0);
}

} // namespace rc
