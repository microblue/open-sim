#include "RCPhysics/Physics/Ground/GroundContact.h"

#include <algorithm>
#include <cmath>

namespace rc
{
    namespace
    {
        /** Effective mass seen by an impulse along `normal` applied at `arm`,
         *  both in world axes. Standard rigid-body contact term:
         *      1 / ( 1/m + n . ( (I^-1 (r x n)) x r ) ) */
        Real EffectiveMass(const MassProperties& mass,
                           const Quat& orientation,
                           const Vec3& arm,
                           const Vec3& normal)
        {
            const Vec3 armCrossNormal = Cross(arm, normal);
            // The inertia tensor is in body axes, so the arm term goes there
            // and comes back.
            const Vec3 inBody   = orientation.RotateInverse(armCrossNormal);
            const Vec3 angular  = mass.InverseInertia * inBody;
            const Vec3 inWorld  = orientation.Rotate(angular);
            const Real rotational = Dot(normal, Cross(inWorld, arm));
            const Real total = Real(1) / mass.Mass + rotational;
            return (total > Real(1e-9)) ? (Real(1) / total) : Real(0);
        }

        void ApplyImpulse(RigidBodyState& state,
                          const MassProperties& mass,
                          const Vec3& arm,
                          const Vec3& impulseWorld)
        {
            state.VelocityWorld += impulseWorld / mass.Mass;

            const Vec3 torqueWorld = Cross(arm, impulseWorld);
            const Vec3 torqueBody  = state.Orientation.RotateInverse(torqueWorld);
            state.AngularVelocityBody += mass.InverseInertia * torqueBody;
        }
    }

    ContactResolution ResolveGroundContact(RigidBodyState& state,
                                           const MassProperties& mass,
                                           const std::vector<HardPoint>& points,
                                           const GroundProvider& ground,
                                           const ContactSettings& settings,
                                           Real deltaSeconds)
    {
        ContactResolution result;
        if (points.empty()) { return result; }

        // Find the deepest penetrating point. Resolving only the deepest, once
        // per step, is enough here: the correction moves the whole body, so the
        // next step sees whatever is deepest after that, and a wreck settles
        // over a handful of steps rather than fighting several constraints that
        // disagree within one.
        const HardPoint* deepest = nullptr;
        Real deepestPenetration = Real(0);
        Vec3 deepestNormal = Vec3(0, 0, -1);
        Vec3 deepestArm = Vec3::Zero();

        for (const HardPoint& point : points)
        {
            const Vec3 arm   = state.Orientation.Rotate(point.PositionBody);
            const Vec3 world = state.PositionWorld + arm;
            const GroundSample sample = ground.Sample(world.x, world.y);

            // World Z points DOWN, so a point below the surface has the larger z.
            const Real penetration = world.z - sample.SurfaceHeight;
            if (penetration > deepestPenetration)
            {
                deepestPenetration = penetration;
                deepest = &point;
                deepestNormal = sample.Normal;
                deepestArm = arm;
            }
        }

        if (deepest == nullptr) { return result; }

        result.Contacted = true;
        result.Penetration = deepestPenetration;
        result.PointName = deepest->Name;

        // --- velocity, at the contact point ---------------------------------
        const Vec3 angularWorld = state.Orientation.Rotate(state.AngularVelocityBody);
        const Vec3 pointVelocity = state.VelocityWorld + Cross(angularWorld, deepestArm);

        const Real normalSpeed = Dot(pointVelocity, deepestNormal);
        result.ApproachSpeed = -normalSpeed;

        if (normalSpeed < Real(0))
        {
            // Moving into the surface. Cancel that, plus whatever bounce.
            const Real effective = EffectiveMass(mass, state.Orientation, deepestArm, deepestNormal);
            const Real magnitude = -(Real(1) + settings.Restitution) * normalSpeed * effective;
            const Vec3 normalImpulse = deepestNormal * magnitude;
            ApplyImpulse(state, mass, deepestArm, normalImpulse);

            // Friction, opposing whatever the point is doing along the surface,
            // clamped to Coulomb. This is what stops a wreck sliding away and
            // what makes it slew rather than skate.
            const Vec3 after = state.VelocityWorld + Cross(
                state.Orientation.Rotate(state.AngularVelocityBody), deepestArm);
            const Vec3 tangentVelocity = after - deepestNormal * Dot(after, deepestNormal);
            const Real tangentSpeed = tangentVelocity.Length();

            if (tangentSpeed > Real(1e-4))
            {
                const Vec3 tangent = tangentVelocity / tangentSpeed;
                const Real tangentEffective =
                    EffectiveMass(mass, state.Orientation, deepestArm, tangent);
                const Real wanted = tangentSpeed * tangentEffective;
                const Real limit = settings.Friction * magnitude;
                ApplyImpulse(state, mass, deepestArm, tangent * -std::min(wanted, limit));
            }
        }

        // --- position -------------------------------------------------------
        // Baumgarte-style: take out most of the overlap, not all of it, and
        // leave a sliver so a resting body is not pushed in and out of contact
        // every step.
        if (deepestPenetration > settings.AllowedPenetration)
        {
            const Real correction =
                (deepestPenetration - settings.AllowedPenetration) * settings.PositionCorrection;
            state.PositionWorld += deepestNormal * correction;
        }

        // --- rotation -------------------------------------------------------
        // Grass and a bent airframe take rotation out fast.
        const Real damping = std::exp(-settings.AngularDamping * deltaSeconds);
        state.AngularVelocityBody = state.AngularVelocityBody * damping;

        return result;
    }
}
