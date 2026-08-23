// OpenRC Simulator - fuselage and everything else that is not a lifting surface.
//
// The body contributes drag, side force, and the mildly DEstabilising yawing
// moment that a volume ahead of the CG always produces. That last part matters:
// the fin has to overcome it, and sizing the fin without it makes an aircraft
// that is unrealistically solid in yaw.
#pragma once

#include "RCPhysics/Physics/Aero/AeroSurface.h"

namespace rc
{
struct FuselageSpec
{
    /** Centroid relative to the CG, body FRD [m]. */
    Vec3 PositionBody = Vec3::Zero();

    Real Length      = 1.0;    ///< m
    Real FrontalArea = 0.011;  ///< m^2
    Real SideArea    = 0.055;  ///< m^2

    Real CdFrontal = 0.35;
    Real CdSide    = 0.60;

    /** Yawing moment derivative with sideslip, per rad. NEGATIVE for a real
     *  body: it wants to swap ends. */
    Real CnBetaPerRad = -0.06;

    /** Extra parasitic drag area for landing gear, servos, linkages and the
     *  general roughness of a model [m^2 of equivalent flat plate]. Folded in
     *  here so that one number carries everything the section model does not. */
    Real ParasiteArea = 0.0;
};

struct FuselageResult
{
    Vec3 ForceBody  = Vec3::Zero();
    Vec3 MomentBody = Vec3::Zero();
    Real Sideslip   = 0.0;   ///< rad
    Real Speed      = 0.0;   ///< m/s
};

class FuselageAero
{
public:
    void Configure(const FuselageSpec& spec);
    const FuselageSpec& Spec() const { return SpecData; }

    FuselageResult Evaluate(const AeroEnvironment& environment) const;

private:
    FuselageSpec SpecData;
};

} // namespace rc
