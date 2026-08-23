#include "TestHarness.h"

#include "RCPhysics/Physics/Dynamics/ForceAccumulator.h"
#include "RCPhysics/Physics/Dynamics/RigidBodyIntegrator.h"
#include "RCPhysics/Core/Log.h"
#include "RCPhysics/Core/Units/Units.h"

using namespace rc;

namespace
{
    /** Mass properties in the ballpark of the Trainer 1500. */
    MassProperties TrainerMass()
    {
        MassProperties mass;
        mass.Mass = 1.35;
        // Roll / pitch / yaw inertia for a 1.5 m high-wing electric trainer.
        mass.Inertia = Mat3::Diagonal(0.055, 0.082, 0.128);
        mass.Finalize();
        return mass;
    }

    Vec3 AngularMomentumWorld(const RigidBodyState& state, const MassProperties& mass)
    {
        return state.Orientation.Rotate(mass.Inertia * state.AngularVelocityBody);
    }

    Real RotationalEnergy(const RigidBodyState& state, const MassProperties& mass)
    {
        return 0.5 * Dot(state.AngularVelocityBody, mass.Inertia * state.AngularVelocityBody);
    }
}

// ------------------------------------------------------- force accumulation --

RC_TEST(ForceAccumulator, ForceAtCGProducesNoMoment)
{
    ForceAccumulator forces;
    forces.AddForceAtCG(Vec3(5.0, 0.0, -2.0), ForceSource::Propulsion);

    RC_CHECK(NearlyEqual(forces.GetTotal().Force, Vec3(5.0, 0.0, -2.0), 1e-15));
    RC_CHECK(forces.GetTotal().Moment.IsNearlyZero());
}

RC_TEST(ForceAccumulator, TailLiftPitchesTheNoseDown)
{
    // The horizontal tail sits 0.10 m BEHIND the CG (body X is forward, so the
    // offset is negative). Lift is "up", which in body FRD is -Z.
    ForceAccumulator forces;
    const Vec3 tailOffset(-0.10, 0.0, 0.0);
    const Vec3 tailLift(0.0, 0.0, -10.0);
    forces.AddForceAtOffset(tailLift, tailOffset, ForceSource::Aerodynamic);

    const Vec3 moment = forces.GetTotal().Moment;
    RC_CHECK_NEAR(moment.x, 0.0, 1e-15);
    RC_CHECK_NEAR(moment.z, 0.0, 1e-15);
    // Negative pitching moment = nose down. This sign is the backbone of
    // longitudinal stability; if it flips, the aircraft is unflyable.
    RC_CHECK_NEAR(moment.y, -1.0, 1e-15);
    RC_CHECK(moment.y < 0.0);
}

RC_TEST(ForceAccumulator, RightWingLiftRollsLeft)
{
    // Extra lift on the RIGHT wing (body +Y) must roll the aircraft LEFT,
    // i.e. produce a negative roll moment.
    ForceAccumulator forces;
    forces.AddForceAtOffset(Vec3(0.0, 0.0, -20.0), Vec3(0.0, 0.35, 0.0));
    RC_CHECK(forces.GetTotal().Moment.x < 0.0);
    RC_CHECK_NEAR(forces.GetTotal().Moment.x, -7.0, 1e-14);
}

RC_TEST(ForceAccumulator, KeepsAPerSourceBreakdown)
{
    ForceAccumulator forces;
    forces.AddForceAtCG(Vec3(12.0, 0.0, 0.0), ForceSource::Propulsion);
    forces.AddForceAtCG(Vec3(-3.0, 0.0, -13.2), ForceSource::Aerodynamic);

    RC_CHECK_NEAR(forces.GetBySource(ForceSource::Propulsion).Force.x, 12.0, 1e-15);
    RC_CHECK_NEAR(forces.GetBySource(ForceSource::Aerodynamic).Force.z, -13.2, 1e-15);
    RC_CHECK(forces.GetBySource(ForceSource::Ground).Force.IsNearlyZero());
    RC_CHECK_NEAR(forces.GetTotal().Force.x, 9.0, 1e-15);

    forces.Reset();
    RC_CHECK(forces.GetTotal().Force.IsNearlyZero());
}

// ------------------------------------------------------------- integration --

RC_TEST(Integrator, RK4FreeFallIsExact)
{
    // With a constant acceleration, RK4 reproduces 0.5*g*t^2 to machine noise.
    RigidBodyState state;
    state.PositionWorld = Vec3(0.0, 0.0, -100.0);   // 100 m up
    const MassProperties mass = TrainerMass();

    const Real dt = 1.0 / 240.0;
    const int steps = 240;
    for (int i = 0; i < steps; ++i)
    {
        StepRK4(state, mass, [](const RigidBodyState&) { return Wrench{}; }, dt);
    }

    const Real t = steps * dt;
    const Real expectedDrop = 0.5 * units::kGravity * t * t;
    RC_CHECK_NEAR(-state.PositionWorld.z, 100.0 - expectedDrop, 1e-9);
    RC_CHECK_NEAR(state.VelocityWorld.z, units::kGravity * t, 1e-9);
    RC_CHECK(state.AltitudeMetres() < 100.0);
}

RC_TEST(Integrator, SemiImplicitEulerMatchesItsAnalyticTruncationError)
{
    // Symplectic Euler under constant acceleration lands at
    //     0.5*g*t^2 + 0.5*g*t*dt
    // Checking against the exact expression (rather than a loose bound) means
    // any future change to the integrator shows up immediately.
    RigidBodyState state;
    const MassProperties mass = TrainerMass();

    const Real dt = 1.0 / 240.0;
    const int steps = 240;
    for (int i = 0; i < steps; ++i)
    {
        StepSemiImplicitEuler(state, mass, Wrench{}, dt);
    }

    const Real t = steps * dt;
    const Real expected = 0.5 * units::kGravity * t * t + 0.5 * units::kGravity * t * dt;
    RC_CHECK_NEAR(state.PositionWorld.z, expected, 1e-9);

    // And the error it carries is small enough to be irrelevant for flying.
    const Real exact = 0.5 * units::kGravity * t * t;
    RC_CHECK(std::fabs(state.PositionWorld.z - exact) < 0.03);
}

RC_TEST(Integrator, ThrustAlongTheNoseAcceleratesForward)
{
    RigidBodyState state;
    MassProperties mass = TrainerMass();

    // 13.5 N on 1.35 kg = 10 m/s^2, cancel gravity to isolate the thrust axis.
    Wrench thrust;
    thrust.Force = Vec3(13.5, 0.0, 0.0);

    const Real dt = 1.0 / 240.0;
    for (int i = 0; i < 240; ++i)
    {
        StepSemiImplicitEuler(state, mass, thrust, dt, Vec3::Zero());
    }

    RC_CHECK_NEAR(state.VelocityWorld.x, 10.0, 1e-9);
    RC_CHECK(state.VelocityWorld.y == 0.0 && state.VelocityWorld.z == 0.0);
}

RC_TEST(Integrator, ConstantRollMomentGivesTheExpectedRollAcceleration)
{
    RigidBodyState state;
    const MassProperties mass = TrainerMass();

    Wrench rollMoment;
    rollMoment.Moment = Vec3(0.11, 0.0, 0.0);   // N*m about body X

    const Real dt = 1.0 / 240.0;
    for (int i = 0; i < 240; ++i)
    {
        StepSemiImplicitEuler(state, mass, rollMoment, dt, Vec3::Zero());
    }

    // p_dot = Mx / Ixx = 0.11 / 0.055 = 2 rad/s^2 -> 2 rad/s after one second.
    RC_CHECK_NEAR(state.AngularVelocityBody.x, 2.0, 1e-9);
    RC_CHECK(state.Orientation.ToEuler().roll > 0.0);
}

RC_TEST(Integrator, TorqueFreeMotionConservesAngularMomentum)
{
    // Asymmetric inertia plus a tumbling initial rate exercises the gyroscopic
    // term omega x (I*omega) in Euler's equation. World-frame angular momentum
    // and rotational energy must both be constant.
    RigidBodyState state;
    state.AngularVelocityBody = Vec3(4.0, 1.5, 0.8);
    const MassProperties mass = TrainerMass();

    const Vec3 initialMomentum = AngularMomentumWorld(state, mass);
    const Real initialEnergy   = RotationalEnergy(state, mass);

    const Real dt = 1.0 / 2400.0;
    for (int i = 0; i < 4800; ++i)   // two seconds of tumbling
    {
        StepRK4(state, mass, [](const RigidBodyState&) { return Wrench{}; }, dt, Vec3::Zero());
    }

    const Vec3 finalMomentum = AngularMomentumWorld(state, mass);
    const Real finalEnergy   = RotationalEnergy(state, mass);

    RC_CHECK_NEAR(finalMomentum.x, initialMomentum.x, 1e-6);
    RC_CHECK_NEAR(finalMomentum.y, initialMomentum.y, 1e-6);
    RC_CHECK_NEAR(finalMomentum.z, initialMomentum.z, 1e-6);
    RC_CHECK_NEAR(finalEnergy, initialEnergy, 1e-6);

    // The body rates must actually have moved around - otherwise the test is
    // trivially passing on a symmetric body.
    RC_CHECK(std::fabs(state.AngularVelocityBody.y - 1.5) > 0.01);
}

RC_TEST(Integrator, ResultIsStepRateIndependent)
{
    // The same one-second manoeuvre at 240 Hz and 960 Hz must agree closely.
    // This is the property that makes the fixed timestep worth having.
    auto simulate = [](Real rateHz)
    {
        RigidBodyState state;
        state.SetVelocityBody(Vec3(15.0, 0.0, 0.0));
        const MassProperties mass = TrainerMass();

        Wrench wrench;
        wrench.Moment = Vec3(0.09, 0.02, 0.0);

        const Real dt = 1.0 / rateHz;
        const int steps = static_cast<int>(rateHz);
        for (int i = 0; i < steps; ++i)
        {
            StepSemiImplicitEuler(state, mass, wrench, dt, Vec3::Zero());
        }
        return state;
    };

    const RigidBodyState coarse = simulate(240.0);
    const RigidBodyState fine   = simulate(960.0);

    RC_CHECK_NEAR(coarse.AngularVelocityBody.x, fine.AngularVelocityBody.x, 1e-3);
    RC_CHECK_NEAR(coarse.Orientation.ToEuler().roll,
                  fine.Orientation.ToEuler().roll, 5e-3);
    RC_CHECK_NEAR(coarse.PositionWorld.x, fine.PositionWorld.x, 0.05);
}

RC_TEST(Integrator, AttitudeStaysNormalisedOverALongFlight)
{
    // Thirty minutes at 240 Hz is the stability target in the V0.1 criteria.
    RigidBodyState state;
    state.AngularVelocityBody = Vec3(1.2, -0.4, 0.6);
    const MassProperties mass = TrainerMass();

    const Real dt = 1.0 / 240.0;
    const int steps = 240 * 60 * 30;
    for (int i = 0; i < steps; ++i)
    {
        StepSemiImplicitEuler(state, mass, Wrench{}, dt, Vec3::Zero());
    }

    RC_CHECK(state.IsFinite());
    RC_CHECK_NEAR(state.Orientation.Norm(), 1.0, 1e-12);
}

namespace
{
    int GCapturedErrorCount = 0;

    void CountingLogSink(LogCategory, LogLevel level, const char*)
    {
        if (level == LogLevel::Error) { ++GCapturedErrorCount; }
    }
}

RC_TEST(Integrator, NonFiniteForcesAreRejectedNotPropagated)
{
    // A NaN reaching the renderer means the aircraft vanishes and the session is
    // over, so the integrator must refuse the step, keep the last good state,
    // AND say something - a silent rollback would hide a real physics bug.
    RigidBodyState state;
    state.VelocityWorld = Vec3(12.0, 0.0, 0.0);
    const RigidBodyState before = state;
    const MassProperties mass = TrainerMass();

    Wrench poisoned;
    poisoned.Force = Vec3(std::nan(""), 0.0, 0.0);

    GCapturedErrorCount = 0;
    SetLogSink(&CountingLogSink);
    const bool ok = StepSemiImplicitEuler(state, mass, poisoned, 1.0 / 240.0);
    SetLogSink(nullptr);

    RC_CHECK(!ok);
    RC_CHECK(GCapturedErrorCount == 1);
    RC_CHECK(state.IsFinite());
    RC_CHECK(NearlyEqual(state.VelocityWorld, before.VelocityWorld, 1e-15));
}

RC_TEST(RigidBodyState, BodyAndWorldVelocityAgree)
{
    RigidBodyState state;
    state.Orientation = Quat::FromEuler(0.2, -0.15, 1.0);
    state.SetVelocityBody(Vec3(16.0, 0.5, 1.2));

    const Vec3 recovered = state.VelocityBody();
    RC_CHECK(NearlyEqual(recovered, Vec3(16.0, 0.5, 1.2), 1e-12));
    RC_CHECK_NEAR(state.GroundSpeed(), std::sqrt(16.0 * 16.0 + 0.25 + 1.44), 1e-12);
}

RC_TEST(MassProperties, InverseInertiaIsConsistent)
{
    MassProperties mass = TrainerMass();
    RC_CHECK(mass.IsValid());
    RC_CHECK(NearlyEqual(mass.Inertia * mass.InverseInertia, Mat3::Identity(), 1e-12));

    MassProperties broken;
    broken.Mass = 0.0;
    RC_CHECK(!broken.IsValid());
}
