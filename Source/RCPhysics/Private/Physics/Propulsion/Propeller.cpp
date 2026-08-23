#include "RCPhysics/Physics/Propulsion/Propeller.h"

#include <cmath>

namespace rc
{
namespace
{
    /** Analytic seeds fitted to published APC electric data across the range of
     *  pitch-to-diameter ratios an RC model actually uses (0.4 to 1.0).
     *
     *      Ct(0) ~ 0.09 + 0.05 (P/D)      11x5.5 -> 0.115, matches APC
     *      Cp(0) ~ 0.025 + 0.055 (P/D)    and Cq = Cp / 2pi
     *      J at zero thrust ~ 1.2 (P/D) + 0.05
     *
     *  The last one is above the geometric pitch ratio because a real blade
     *  keeps producing thrust past its nominal pitch speed.
     */
    Real SeedThrustCoefficient(Real pitchOverDiameter)
    {
        return Clamp(0.09 + 0.05 * pitchOverDiameter, 0.04, 0.20);
    }

    Real SeedTorqueCoefficient(Real pitchOverDiameter)
    {
        const Real powerCoefficient = Clamp(0.025 + 0.055 * pitchOverDiameter, 0.01, 0.15);
        return powerCoefficient / kTwoPi;
    }

    Real SeedZeroThrustAdvanceRatio(Real pitchOverDiameter)
    {
        return Clamp(1.2 * pitchOverDiameter + 0.05, 0.15, 1.6);
    }
}

void Propeller::Configure(const PropellerSpec& spec)
{
    SpecData = spec;
    const Real pd = spec.PitchOverDiameter();
    StaticThrustCoefficient = SeedThrustCoefficient(pd);
    StaticTorqueCoefficient = SeedTorqueCoefficient(pd);
    ZeroThrustJ = SeedZeroThrustAdvanceRatio(pd);

    // More blades move more air for the same diameter. Roughly linear in blade
    // count over the two-to-four range models use.
    const Real bladeFactor = Clamp(static_cast<Real>(spec.BladeCount) / 2.0, 0.5, 2.5);
    StaticThrustCoefficient *= std::pow(bladeFactor, 0.9);
    StaticTorqueCoefficient *= std::pow(bladeFactor, 0.9);
}

bool Propeller::SetTables(Table1D thrustCoefficient, Table1D torqueCoefficient,
                          std::string* outError)
{
    if (thrustCoefficient.IsEmpty() || torqueCoefficient.IsEmpty())
    {
        if (outError) { *outError = "Propeller: both Ct and Cq tables are required"; }
        return false;
    }
    ThrustTable = std::move(thrustCoefficient);
    TorqueTable = std::move(torqueCoefficient);
    UseTables = true;
    return true;
}

Real Propeller::AdvanceRatio(Real angularRate, Real axialAirspeed) const
{
    const Real revolutionsPerSecond = angularRate / kTwoPi;
    const Real denominator = revolutionsPerSecond * SpecData.Diameter;
    if (std::fabs(denominator) < 1e-3)
    {
        // Below a few revolutions per second the advance ratio is meaningless;
        // report the static value rather than a number heading for infinity.
        return 0.0;
    }
    return axialAirspeed / denominator;
}

PropellerState Propeller::Evaluate(Real angularRate, Real axialAirspeed, Real density) const
{
    PropellerState state;
    if (angularRate <= 0.0 || SpecData.Diameter <= kEpsilon)
    {
        return state;
    }

    const Real revolutionsPerSecond = angularRate / kTwoPi;
    const Real j = AdvanceRatio(angularRate, axialAirspeed);
    state.AdvanceRatio = j;

    if (UseTables)
    {
        state.ThrustCoefficient = ThrustTable.Evaluate(j);
        state.TorqueCoefficient = TorqueTable.Evaluate(j);
    }
    else
    {
        // Thrust falls away as the propeller catches up with the air, reaching
        // zero at ZeroThrustJ and going negative (windmilling) beyond it. The
        // 1.5 exponent keeps the curve full near the static point and steep as
        // it approaches pitch speed, which is the shape APC data has.
        const Real ratio = SafeDivide(j, ZeroThrustJ, 0.0);
        const Real shape = (ratio <= 0.0) ? 1.0
                         : 1.0 - std::pow(ratio, 1.5);
        state.ThrustCoefficient = StaticThrustCoefficient * Max(shape, -0.35);

        // Torque falls more slowly than thrust: the blade keeps stirring the
        // air long after it has stopped pushing it. At the zero-thrust point a
        // propeller still absorbs about half its static torque.
        state.TorqueCoefficient =
            StaticTorqueCoefficient * Max(1.0 - 0.5 * Sq(Max(ratio, 0.0)), 0.15);
    }

    const Real n2 = Sq(revolutionsPerSecond);
    const Real d4 = Sq(Sq(SpecData.Diameter));
    state.Thrust = state.ThrustCoefficient * density * n2 * d4;
    state.Torque = state.TorqueCoefficient * density * n2 * d4 * SpecData.Diameter;
    return state;
}

Real Propeller::InducedVelocity(Real thrust, Real axialAirspeed, Real density) const
{
    // Momentum theory: T = 2 rho A v_i (V + v_i), solved for v_i.
    const Real area = SpecData.DiskArea();
    if (thrust <= 0.0 || area <= kEpsilon || density <= kEpsilon)
    {
        return 0.0;
    }
    const Real v = Max(axialAirspeed, 0.0);
    const Real discriminant = Sq(v) + 2.0 * thrust / (density * area);
    return 0.5 * (std::sqrt(Max(discriminant, 0.0)) - v);
}

Real Propeller::WakeSwirlCirculation(Real torque, Real axialAirspeed,
                                     Real inducedVelocity, Real density) const
{
    // The torque goes into the angular momentum of the mass flow:
    //     Q = mdot * r * v_theta
    // so v_theta = (Q / mdot) / r. This returns the Q/mdot part; the caller
    // divides by the radius it is interested in.
    const Real area = SpecData.DiskArea();
    const Real massFlow = density * area * Max(axialAirspeed + inducedVelocity, 0.5);
    if (massFlow <= kEpsilon)
    {
        return 0.0;
    }
    return torque / massFlow;
}

} // namespace rc
