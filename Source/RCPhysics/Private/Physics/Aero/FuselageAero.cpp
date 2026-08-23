#include "RCPhysics/Physics/Aero/FuselageAero.h"

#include <cmath>

namespace rc
{
namespace
{
    constexpr Real kMinimumSpeed = 0.05;

    /** Signed square: drag opposes motion and grows with its square, and this
     *  keeps the sign correct when a component of the flow reverses. */
    Real SignedSquare(Real v) { return v * std::fabs(v); }
}

void FuselageAero::Configure(const FuselageSpec& spec)
{
    SpecData = spec;
}

FuselageResult FuselageAero::Evaluate(const AeroEnvironment& environment) const
{
    FuselageResult result;

    const Vec3 rotational = Cross(environment.AngularVelocityBody, SpecData.PositionBody);
    const Vec3 local = environment.AirVelocityBody + rotational;

    const Real speed = local.Length();
    result.Speed = speed;
    if (speed < kMinimumSpeed)
    {
        return result;
    }

    const Real halfRho = 0.5 * environment.Atmosphere.Density;

    // Axis-by-axis bluff-body drag. The vertical uses the side area because a
    // model fuselage is a slab: seen from below it presents roughly its plan
    // area, which is much closer to the side area than to the frontal area.
    const Real axialArea = SpecData.FrontalArea + SpecData.ParasiteArea;
    result.ForceBody = Vec3(
        -halfRho * SignedSquare(local.x) * axialArea * SpecData.CdFrontal,
        -halfRho * SignedSquare(local.y) * SpecData.SideArea * SpecData.CdSide,
        -halfRho * SignedSquare(local.z) * SpecData.SideArea * SpecData.CdSide);

    result.Sideslip = std::asin(ClampUnit(local.y / speed));

    // Destabilising yaw. Cn_beta is negative, so a right sideslip yaws the nose
    // LEFT - away from the relative wind. The fin outweighs this; the balance
    // between them is what sets directional stability.
    const Real dynamicPressure = halfRho * speed * speed;
    const Real yawMoment = dynamicPressure * SpecData.SideArea * SpecData.Length
                         * SpecData.CnBetaPerRad * result.Sideslip;
    result.MomentBody = Vec3(0.0, 0.0, yawMoment);

    return result;
}

} // namespace rc
