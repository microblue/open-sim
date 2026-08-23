// OpenRC Simulator - unit handling.
//
// HARD RULE: the physics core speaks SI and nothing else.
//   length  metre       [m]
//   mass    kilogram    [kg]
//   time    second      [s]
//   force   newton      [N]
//   moment  newton-metre[N*m]
//   angle   radian      [rad]
//   density kg/m^3
//   speed   m/s
//
// Config files and UI may use degrees, inches, grams, mAh, RPM, km/h ...
// They are converted here, once, at load/display time. No mixed units ever
// cross into Physics/.
#pragma once

#include "RCPhysics/Core/Types.h"

namespace rc::units
{
// ---------------------------------------------------------------- angle -----
inline constexpr Real kDegToRad = kPi / 180.0;
inline constexpr Real kRadToDeg = 180.0 / kPi;

inline constexpr Real Degrees(Real deg)      { return deg * kDegToRad; }   // -> rad
inline constexpr Real ToDegrees(Real rad)    { return rad * kRadToDeg; }   // rad ->

// --------------------------------------------------------------- length -----
inline constexpr Real kInchToMetre = 0.0254;
inline constexpr Real kFootToMetre = 0.3048;

inline constexpr Real Millimetres(Real mm)   { return mm * 1e-3; }
inline constexpr Real Centimetres(Real cm)   { return cm * 1e-2; }
inline constexpr Real Inches(Real in)        { return in * kInchToMetre; }
inline constexpr Real Feet(Real ft)          { return ft * kFootToMetre; }

inline constexpr Real ToMillimetres(Real m)  { return m * 1e3; }
inline constexpr Real ToCentimetres(Real m)  { return m * 1e2; }
inline constexpr Real ToInches(Real m)       { return m / kInchToMetre; }
inline constexpr Real ToFeet(Real m)         { return m / kFootToMetre; }

// ----------------------------------------------------------------- mass -----
inline constexpr Real kPoundToKilogram = 0.45359237;
inline constexpr Real kOunceToKilogram = 0.028349523125;

inline constexpr Real Grams(Real g)          { return g * 1e-3; }
inline constexpr Real Pounds(Real lb)        { return lb * kPoundToKilogram; }
inline constexpr Real Ounces(Real oz)        { return oz * kOunceToKilogram; }

inline constexpr Real ToGrams(Real kg)       { return kg * 1e3; }
inline constexpr Real ToPounds(Real kg)      { return kg / kPoundToKilogram; }
inline constexpr Real ToOunces(Real kg)      { return kg / kOunceToKilogram; }

// ---------------------------------------------------------------- speed -----
inline constexpr Real kKnotToMps = 0.514444444444;

inline constexpr Real KilometresPerHour(Real kph) { return kph / 3.6; }
inline constexpr Real MilesPerHour(Real mph)      { return mph * 0.44704; }
inline constexpr Real Knots(Real kt)              { return kt * kKnotToMps; }
inline constexpr Real FeetPerMinute(Real fpm)     { return fpm * kFootToMetre / 60.0; }

inline constexpr Real ToKilometresPerHour(Real mps) { return mps * 3.6; }
inline constexpr Real ToMilesPerHour(Real mps)      { return mps / 0.44704; }
inline constexpr Real ToKnots(Real mps)             { return mps / kKnotToMps; }
inline constexpr Real ToFeetPerMinute(Real mps)     { return mps * 60.0 / kFootToMetre; }

// --------------------------------------------------- rotational velocity ----
// RPM is how motor/prop data is always published, so it is a first-class
// conversion even though the core integrates in rad/s.
inline constexpr Real RPM(Real rpm)          { return rpm * kTwoPi / 60.0; }   // -> rad/s
inline constexpr Real ToRPM(Real radPerSec)  { return radPerSec * 60.0 / kTwoPi; }

// ------------------------------------------------------------- electrical ---
inline constexpr Real MilliampHours(Real mah) { return mah * 3.6; }            // -> coulomb
inline constexpr Real ToMilliampHours(Real c) { return c / 3.6; }

// --------------------------------------------------------------- physical ---
/** Standard gravity [m/s^2]. */
inline constexpr Real kGravity = 9.80665;
/** ISA sea-level air density [kg/m^3]. */
inline constexpr Real kSeaLevelDensity = 1.225;
/** ISA sea-level pressure [Pa]. */
inline constexpr Real kSeaLevelPressure = 101325.0;
/** ISA sea-level temperature [K]. */
inline constexpr Real kSeaLevelTemperature = 288.15;
/** Dynamic viscosity of air at 15 C [Pa*s]. Drives Reynolds number. */
inline constexpr Real kSeaLevelDynamicViscosity = 1.789e-5;
/** Specific gas constant for dry air [J/(kg*K)]. */
inline constexpr Real kAirGasConstant = 287.05287;
/** Ratio of specific heats for air. */
inline constexpr Real kAirGamma = 1.4;

} // namespace rc::units
