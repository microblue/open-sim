// OpenRC Simulator - propeller aerodynamics.
//
//     J  = V / (n D)                advance ratio, n in revolutions per second
//     T  = Ct(J) rho n^2 D^4        thrust
//     Q  = Cq(J) rho n^2 D^5        shaft torque
//
// Ct and Cq are Table1D, so replacing the analytic seed with APC or UIUC data
// is a data change and nothing else. The analytic seed is fitted to published
// APC electric data as a function of pitch-to-diameter ratio, which is the one
// parameter that actually distinguishes one propeller from another at this
// scale.
//
// Thrust falls to zero near the pitch advance ratio: that is what stops a model
// accelerating past its pitch speed, and it is why an over-pitched propeller
// gives a fast aircraft that will not climb.
#pragma once

#include "RCPhysics/Aircraft/AircraftDefinition.h"
#include "RCPhysics/Core/Math/LookupTable.h"

namespace rc
{
struct PropellerState
{
    Real Thrust      = 0.0;   ///< N
    Real Torque      = 0.0;   ///< N*m required to drive it
    Real AdvanceRatio = 0.0;
    Real ThrustCoefficient = 0.0;
    Real TorqueCoefficient = 0.0;
};

class Propeller
{
public:
    void Configure(const PropellerSpec& spec);
    const PropellerSpec& Spec() const { return SpecData; }

    /** Supply measured coefficient curves against advance ratio. */
    bool SetTables(Table1D thrustCoefficient, Table1D torqueCoefficient,
                   std::string* outError = nullptr);
    bool HasTables() const { return UseTables; }

    /** Advance ratio at a shaft rate and axial airspeed. */
    Real AdvanceRatio(Real angularRate, Real axialAirspeed) const;

    /** The advance ratio at which thrust reaches zero - the propeller's pitch
     *  speed, non-dimensionalised. */
    Real ZeroThrustAdvanceRatio() const { return ZeroThrustJ; }

    PropellerState Evaluate(Real angularRate, Real axialAirspeed, Real density) const;

    /** Induced velocity at the disc from momentum theory [m/s]. The fully
     *  developed wake carries twice this. */
    Real InducedVelocity(Real thrust, Real axialAirspeed, Real density) const;

    /** Swirl circulation in the slipstream [m^2/s].
     *
     *  Momentum theory puts the shaft torque into the angular momentum of the
     *  mass flow: Q = mdot * r * v_theta, so the tangential velocity follows a
     *  FREE VORTEX, v_theta = (Q / mdot) / r - falling with radius, not rising
     *  with it. Returning the circulation Q/mdot rather than an angular rate
     *  keeps that the caller's obvious reading.
     *
     *  Modelling the wake as rotating like a solid body instead gets the radial
     *  dependence exactly backwards, and made the slipstream asymmetry at the
     *  tail large enough to flip the aircraft during the takeoff roll. */
    Real WakeSwirlCirculation(Real torque, Real axialAirspeed, Real inducedVelocity,
                              Real density) const;

private:
    PropellerSpec SpecData;

    Real StaticThrustCoefficient = 0.115;
    Real StaticTorqueCoefficient = 0.0088;
    Real ZeroThrustJ = 0.70;

    bool    UseTables = false;
    Table1D ThrustTable;
    Table1D TorqueTable;
};

} // namespace rc
