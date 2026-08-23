// OpenRC Simulator - RC physics core
// Fundamental scalar type and small helpers shared by the whole physics core.
//
// This header (and everything else under RCPhysics/) must never include an
// Unreal Engine header. The core is plain C++17 so it can be compiled and
// unit-tested without an engine present.
#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace rc
{
/** Scalar type for the entire physics core.
 *  double, deliberately: a 240 Hz 6-DoF integrator accumulates attitude error
 *  fast in float, and the cost at ~20 aero sections is irrelevant. */
using Real = double;

inline constexpr Real kPi        = 3.14159265358979323846;
inline constexpr Real kTwoPi     = 2.0 * kPi;
inline constexpr Real kHalfPi    = 0.5 * kPi;

/** Values below this are treated as zero when guarding divisions. */
inline constexpr Real kEpsilon   = 1e-9;

inline bool IsFinite(Real v) { return std::isfinite(v); }

inline constexpr Real Sq(Real v) { return v * v; }

inline constexpr Real Min(Real a, Real b) { return a < b ? a : b; }
inline constexpr Real Max(Real a, Real b) { return a > b ? a : b; }

inline constexpr Real Clamp(Real v, Real lo, Real hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/** Clamp to [-1, 1]. Used before asin/acos to survive rounding. */
inline constexpr Real ClampUnit(Real v) { return Clamp(v, -1.0, 1.0); }

inline constexpr Real Lerp(Real a, Real b, Real t) { return a + (b - a) * t; }

inline constexpr Real Sign(Real v) { return v < 0.0 ? -1.0 : (v > 0.0 ? 1.0 : 0.0); }

/** Divide guarding against a vanishing denominator. */
inline Real SafeDivide(Real numerator, Real denominator, Real fallback = 0.0)
{
    return (std::fabs(denominator) > kEpsilon) ? (numerator / denominator) : fallback;
}

/** Wrap an angle into (-pi, pi]. */
inline Real WrapPi(Real radians)
{
    Real wrapped = std::fmod(radians + kPi, kTwoPi);
    if (wrapped <= 0.0) wrapped += kTwoPi;
    return wrapped - kPi;
}

} // namespace rc
