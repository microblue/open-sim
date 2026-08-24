// OpenRC Simulator - stopping the airframe at the surface.
//
// The landing gear carries the aircraft while it is the right way up: three
// wheels, each a spring and damper, which is the correct model for something
// rolling. It says nothing about the rest of the airframe, and CrashModel only
// DETECTS that something else touched the ground. Nothing acted on it, so after
// a crash the body kept integrating and sank through the surface.
//
// This resolves the contact instead. It is a rigid impulse at the deepest
// penetrating point rather than a spring: a wing tip digging into grass does not
// bounce, and a penetration-depth spring stiff enough not to sink is stiff
// enough to explode at 240 Hz.
//
// Deliberately NOT a general collision system. There is one collider - the
// ground - and the airframe is a handful of points on a body that is about to
// stop being an aircraft. What it has to get right is that the wreck ends up
// lying on the surface, at a plausible attitude, and stays there.

#ifndef RCPHYSICS_PHYSICS_GROUND_GROUNDCONTACT_H
#define RCPHYSICS_PHYSICS_GROUND_GROUNDCONTACT_H

#include "RCPhysics/Physics/Dynamics/RigidBodyState.h"
#include "RCPhysics/Physics/Ground/LandingGear.h"

#include <vector>

namespace rc
{
    struct ContactResolution
    {
        /** True when at least one point was below the surface. */
        bool Contacted = false;

        /** How far the deepest point had sunk before correction [m]. A large
         *  value means the step tunnelled rather than touched. */
        Real Penetration = 0.0;

        /** Speed into the surface at that point [m/s], before the impulse. */
        Real ApproachSpeed = 0.0;

        /** Which point it was. */
        std::string PointName;
    };

    struct ContactSettings
    {
        /** Bounce. Near zero: a foam and balsa model landing in grass does not
         *  come back up, and anything springy here reads as a beach ball. */
        Real Restitution = 0.06;

        /** Sliding friction at the contact. High, because what is dragging is
         *  a wing tip or a broken cowl, not a wheel. */
        Real Friction = 0.85;

        /** Fraction of the remaining penetration removed per step. Below one so
         *  a body resting exactly at the surface does not jitter between
         *  contacting and not. */
        Real PositionCorrection = 0.8;

        /** Penetration below which no positional correction is applied at all,
         *  so a resting wreck is left alone [m]. */
        Real AllowedPenetration = 0.001;

        /** Angular damping applied while any point is in contact [1/s]. Grass
         *  and a bent airframe absorb rotation quickly; without this a wreck
         *  spins on its nose indefinitely. */
        Real AngularDamping = 3.0;
    };

    /** Push `state` out of the ground and take the energy out of the impact.
     *  Call after integrating, with the airframe's hard points. */
    ContactResolution ResolveGroundContact(RigidBodyState& state,
                                           const MassProperties& mass,
                                           const std::vector<HardPoint>& points,
                                           const GroundProvider& ground,
                                           const ContactSettings& settings,
                                           Real deltaSeconds);
}

#endif
