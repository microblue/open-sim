// OpenRC Simulator - the airframe must stop at the surface.
//
// Before this existed, CrashModel detected that a wing tip had touched the
// ground and nothing acted on it, so the body carried on integrating and sank
// out of sight. These pin the behaviour that replaced it: penetration is
// removed, the impact is absorbed rather than bounced, and a wreck comes to
// rest instead of sliding or spinning forever.

#include "RCPhysics/Physics/Ground/GroundContact.h"
#include "RCPhysics/Physics/Dynamics/RigidBodyIntegrator.h"
#include "TestHarness.h"

namespace
{
    rc::MassProperties TrainerMass()
    {
        rc::MassProperties mass;
        mass.Mass = 1.35;
        mass.Inertia = rc::Mat3::Diagonal(0.045, 0.055, 0.090);
        mass.Finalize();
        return mass;
    }

    std::vector<rc::HardPoint> Airframe()
    {
        // Body axes: x forward, y right, z DOWN.
        return {
            {"wing_tip_left",  rc::Vec3(0.00, -0.75, 0.02)},
            {"wing_tip_right", rc::Vec3(0.00,  0.75, 0.02)},
            {"tail",           rc::Vec3(-0.60, 0.00, 0.00)},
            {"nose",           rc::Vec3(0.35,  0.00, 0.05)},
        };
    }

    /** Deepest penetration of any hard point, positive when below ground. */
    rc::Real DeepestBelow(const rc::RigidBodyState& state,
                          const std::vector<rc::HardPoint>& points,
                          const rc::FlatGround& ground)
    {
        rc::Real deepest = -1e9;
        for (const rc::HardPoint& point : points)
        {
            const rc::Vec3 world =
                state.PositionWorld + state.Orientation.Rotate(point.PositionBody);
            deepest = std::max(deepest, world.z - ground.Sample(world.x, world.y).SurfaceHeight);
        }
        return deepest;
    }
}

RC_TEST(GroundContact, DoesNothingWellClearOfTheGround)
{
    rc::RigidBodyState state;
    state.PositionWorld = rc::Vec3(0.0, 0.0, -50.0);   // 50 m up
    state.VelocityWorld = rc::Vec3(12.0, 0.0, 1.0);
    const rc::RigidBodyState before = state;

    const rc::FlatGround ground(0.0);
    const rc::ContactResolution result = rc::ResolveGroundContact(
        state, TrainerMass(), Airframe(), ground, rc::ContactSettings{}, 1.0 / 240.0);

    RC_CHECK(!result.Contacted);
    RC_CHECK_NEAR(state.PositionWorld.z, before.PositionWorld.z, 1e-12);
    RC_CHECK_NEAR(state.VelocityWorld.z, before.VelocityWorld.z, 1e-12);
}

RC_TEST(GroundContact, LiftsAPenetratingAirframeBackToTheSurface)
{
    rc::RigidBodyState state;
    // Half a metre under, which is what a missed step used to leave behind.
    state.PositionWorld = rc::Vec3(0.0, 0.0, 0.5);
    state.VelocityWorld = rc::Vec3(0.0, 0.0, 6.0);   // still going down

    const rc::FlatGround ground(0.0);
    const rc::MassProperties mass = TrainerMass();
    const std::vector<rc::HardPoint> points = Airframe();

    rc::ContactResolution result;
    for (int step = 0; step < 240; ++step)
    {
        result = rc::ResolveGroundContact(state, mass, points, ground,
                                          rc::ContactSettings{}, 1.0 / 240.0);
    }

    RC_CHECK(result.Contacted);
    // Back at the surface, within the sliver the solver deliberately leaves.
    const rc::Real below = DeepestBelow(state, points, ground);
    RC_CHECK(below < 0.01);
    RC_CHECK(below > -0.05);
}

RC_TEST(GroundContact, AbsorbsAnImpactRatherThanBouncingIt)
{
    rc::RigidBodyState state;
    state.PositionWorld = rc::Vec3(0.0, 0.0, 0.03);
    state.VelocityWorld = rc::Vec3(0.0, 0.0, 9.0);   // 9 m/s straight down

    const rc::FlatGround ground(0.0);
    const rc::ContactResolution result = rc::ResolveGroundContact(
        state, TrainerMass(), Airframe(), ground, rc::ContactSettings{}, 1.0 / 240.0);

    RC_CHECK(result.Contacted);
    RC_CHECK_NEAR(result.ApproachSpeed, 9.0, 0.5);

    // What must stop is the CONTACT POINT going into the ground, not the
    // centre of gravity going up. The impulse lands at the nose, well forward
    // of the CG, so most of it becomes pitch rather than lift - which is what
    // a nose-in arrival does, and why the aircraft ends up on its back rather
    // than bouncing.
    const rc::Vec3 arm = state.Orientation.Rotate(rc::Vec3(0.35, 0.0, 0.05));
    const rc::Vec3 angularWorld = state.Orientation.Rotate(state.AngularVelocityBody);
    const rc::Vec3 pointVelocity = state.VelocityWorld + rc::Cross(angularWorld, arm);
    const rc::Real intoGround = pointVelocity.z;

    // No longer driving into the surface...
    RC_CHECK_MSG_VALUE(intoGround < 0.5, intoGround);
    // ...and not flung back out of it either.
    RC_CHECK_MSG_VALUE(-intoGround < 9.0 * 0.25, intoGround);
}

RC_TEST(GroundContact, AWreckComesToRestInsteadOfSlidingForever)
{
    rc::RigidBodyState state;
    state.PositionWorld = rc::Vec3(0.0, 0.0, 0.02);
    state.VelocityWorld = rc::Vec3(14.0, 0.0, 1.0);          // sliding fast
    state.AngularVelocityBody = rc::Vec3(6.0, 0.0, 4.0);     // and tumbling

    const rc::FlatGround ground(0.0);
    const rc::MassProperties mass = TrainerMass();
    const std::vector<rc::HardPoint> points = Airframe();
    const rc::Vec3 gravity = rc::DefaultGravityWorld();

    for (int step = 0; step < 240 * 6; ++step)
    {
        rc::Wrench none;
        rc::StepSemiImplicitEuler(state, mass, none, 1.0 / 240.0, gravity);
        rc::ResolveGroundContact(state, mass, points, ground,
                                 rc::ContactSettings{}, 1.0 / 240.0);
    }

    RC_CHECK(state.VelocityWorld.Length() < 1.0);
    RC_CHECK(state.AngularVelocityBody.Length() < 1.0);

    // And it is lying on the ground, not in it and not hovering.
    const rc::Real below = DeepestBelow(state, points, ground);
    RC_CHECK(below < 0.02);
    RC_CHECK(below > -0.10);
}

RC_TEST(GroundContact, NeverLeavesTheAirframeUnderTheSurfaceDuringADive)
{
    // The case that started this: flown into the ground at speed, with the
    // solver running every step. No step may end with the airframe buried.
    rc::RigidBodyState state;
    state.PositionWorld = rc::Vec3(0.0, 0.0, -6.0);
    state.VelocityWorld = rc::Vec3(18.0, 0.0, 14.0);   // steep and fast

    const rc::FlatGround ground(0.0);
    const rc::MassProperties mass = TrainerMass();
    const std::vector<rc::HardPoint> points = Airframe();
    const rc::Vec3 gravity = rc::DefaultGravityWorld();

    rc::Real worst = -1e9;
    for (int step = 0; step < 240 * 5; ++step)
    {
        rc::Wrench none;
        rc::StepSemiImplicitEuler(state, mass, none, 1.0 / 240.0, gravity);
        rc::ResolveGroundContact(state, mass, points, ground,
                                 rc::ContactSettings{}, 1.0 / 240.0);
        worst = std::max(worst, DeepestBelow(state, points, ground));
    }

    // One step of overshoot at 14 m/s is 58 mm; the solver must pull it back
    // immediately rather than letting it accumulate.
    RC_CHECK_MSG_VALUE(worst < 0.10, worst);
}
