#include "../Aero/FlightTestRig.h"

#include <cstdio>

using namespace rc;
using namespace rctest;

namespace
{
    FlightTestRig GroundedTrainer(rctest::TestContext& ctx, bool powered = true)
    {
        FlightTestRig rig;
        const std::string error = rig.LoadTrainer();
        if (!error.empty()) { ctx.Fail("Trainer1500.json: " + error, __FILE__, __LINE__); }
        rig.EnableGround(true);
        rig.EnablePower(powered);
        rig.PlaceOnRunway();
        return rig;
    }

    constexpr Real kTrainerWeight = 1.35 * units::kGravity;
}

// -------------------------------------------------------------- standing ----

RC_TEST(LandingGear, SupportsTheAircraftAtRest)
{
    FlightTestRig rig = GroundedTrainer(ctx, false);
    rig.StepFor(3.0);

    std::printf("\n        parked: %.2f N on the wheels (weight %.2f N), "
                "sink %.1f mm, altitude %.4f m\n",
                rig.LastForces.WeightOnWheels, kTrainerWeight,
                rig.LastForces.Wheels.empty() ? 0.0
                    : rig.LastForces.Wheels[0].Compression * 1000.0,
                rig.Altitude());

    RC_CHECK(rig.LastForces.OnGround);
    // The wheels must carry the weight, and the aircraft must settle rather
    // than sink through the ground or bounce off it.
    RC_CHECK_NEAR(rig.LastForces.WeightOnWheels, kTrainerWeight, 0.5);
    RC_CHECK(std::fabs(rig.State.VelocityWorld.z) < 0.05);

    // "Altitude" is the CG's height, and the CG of a tricycle model sits about
    // 175 mm up on its gear - so the right check is that the CG has settled to
    // the gear geometry minus a millimetre or two of tyre squash, not that it
    // is at zero.
    Real standingHeight = 0.0;
    for (const LandingGearSpec& wheel : rig.Definition.LandingGear)
    {
        standingHeight = Max(standingHeight, wheel.PositionBody.z + wheel.Radius);
    }
    RC_CHECK_NEAR(rig.Altitude(), standingHeight, 0.01);
    RC_CHECK(rig.Altitude() > 0.10);

    // The suspension must actually deflect, and only by a few millimetres.
    Real deepest = 0.0;
    for (const WheelResult& wheel : rig.LastForces.Wheels)
    {
        deepest = Max(deepest, wheel.Compression);
    }
    RC_CHECK(deepest > 0.0005 && deepest < 0.015);
    RC_CHECK(rig.State.IsFinite());
}

RC_TEST(LandingGear, TricycleLoadSplitMatchesTheGeometry)
{
    FlightTestRig rig = GroundedTrainer(ctx, false);
    rig.StepFor(3.0);

    Real noseLoad = 0.0;
    Real mainLoad = 0.0;
    for (size_t i = 0; i < rig.LastForces.Wheels.size(); ++i)
    {
        if (rig.Definition.LandingGear[i].Steerable)
        {
            noseLoad += rig.LastForces.Wheels[i].NormalForce;
        }
        else
        {
            mainLoad += rig.LastForces.Wheels[i].NormalForce;
        }
    }

    const Real noseShare = noseLoad / Max(noseLoad + mainLoad, 1e-9);
    std::printf("        nose carries %.0f%% of the weight\n", noseShare * 100.0);

    // Enough to steer with, little enough that the elevator can lift it at
    // rotation speed. The geometry test in Tests/Regression predicts 16 %.
    RC_CHECK(noseShare > 0.10 && noseShare < 0.25);
}

RC_TEST(LandingGear, DoesNotDriftWhenParked)
{
    // Static friction must actually hold. A model that creeps across the strip
    // on its own would make every ground test meaningless.
    FlightTestRig rig = GroundedTrainer(ctx, false);
    rig.StepFor(5.0);

    RC_CHECK(std::fabs(rig.State.PositionWorld.x) < 0.05);
    RC_CHECK(std::fabs(rig.State.PositionWorld.y) < 0.05);
    RC_CHECK(rig.State.VelocityWorld.Length() < 0.1);
}

RC_TEST(LandingGear, AirborneAircraftTouchesNothing)
{
    FlightTestRig rig = GroundedTrainer(ctx, false);
    rig.PlaceAtAlpha(14.0, units::Degrees(2.0), 50.0);
    rig.Evaluate();

    RC_CHECK(!rig.LastForces.OnGround);
    RC_CHECK_NEAR(rig.LastForces.WeightOnWheels, 0.0, 1e-12);
    for (const WheelResult& wheel : rig.LastForces.Wheels)
    {
        RC_CHECK(!wheel.InContact);
        RC_CHECK(wheel.ForceBody.IsNearlyZero());
    }
}

// ------------------------------------------------------------------ taxi ----

RC_TEST(LandingGear, TaxisForwardUnderPower)
{
    FlightTestRig rig = GroundedTrainer(ctx);
    rig.Controls.Set(RCChannel::Throttle, 0.35);
    rig.StepFor(4.0);

    std::printf("        taxi: %.2f m in 4 s at 35%% throttle, %.2f m/s\n",
                rig.State.PositionWorld.x, rig.State.VelocityWorld.x);

    RC_CHECK(rig.State.PositionWorld.x > 1.0);
    RC_CHECK(rig.State.VelocityWorld.x > 0.5);
    RC_CHECK(rig.LastForces.OnGround);
    RC_CHECK(std::fabs(rig.State.PositionWorld.y) < 2.0);   // roughly straight
}

RC_TEST(LandingGear, NoseWheelSteers)
{
    // Rudder steers the nose wheel on the ground. Positive rudder is nose right,
    // the same convention as in the air.
    //
    // The measurement is the yaw RATE, not the accumulated heading: with a
    // 0.38 m wheelbase and 25 degrees of nose wheel travel the turn radius is
    // under a metre, so full deflection pivots the model almost on the spot and
    // the heading wraps within a couple of seconds. That is realistic; it just
    // makes accumulated heading a useless thing to assert on.
    auto yawRateWithRudder = [&](Real rudder)
    {
        FlightTestRig rig = GroundedTrainer(ctx);
        rig.Controls.Set(RCChannel::Throttle, 0.35);
        rig.StepFor(2.0);                        // get rolling straight first
        rig.Controls.Set(RCChannel::Rudder, rudder);
        rig.StepFor(1.0);
        return units::ToDegrees(rig.State.AngularVelocityBody.z);
    };

    const Real right = yawRateWithRudder(1.0);
    const Real left  = yawRateWithRudder(-1.0);
    const Real straight = yawRateWithRudder(0.0);

    std::printf("        yaw rate while taxiing: right rudder %+.0f, "
                "left %+.0f, neutral %+.0f deg/s\n", right, left, straight);

    RC_CHECK(right > 20.0);
    RC_CHECK(left < -20.0);
    RC_CHECK(std::fabs(straight) < 10.0);
    RC_CHECK_NEAR(right, -left, 0.35 * right);
}

RC_TEST(LandingGear, RollingResistanceStopsTheAircraft)
{
    FlightTestRig rig = GroundedTrainer(ctx, false);
    rig.PlaceOnRunway();
    rig.State.VelocityWorld = Vec3(6.0, 0.0, 0.0);
    rig.StepFor(8.0);

    std::printf("        coast-down from 6 m/s: %.2f m/s after 8 s\n",
                rig.State.VelocityWorld.x);
    RC_CHECK(rig.State.VelocityWorld.x < 6.0);
    RC_CHECK(rig.State.VelocityWorld.x >= -0.2);   // it stops, it does not reverse
}

// --------------------------------------------------------------- takeoff ----

RC_TEST(LandingGear, TakesOffAndTheGroundRollIsPlausible)
{
    FlightTestRig rig = GroundedTrainer(ctx);
    rig.Controls.Set(RCChannel::Throttle, 1.0);

    Real rotationSpeed = 0.0;
    Real groundRoll = 0.0;
    bool airborne = false;

    for (int i = 0; i < 240 * 25 && !airborne; ++i)
    {
        // Hold the elevator nearly neutral until the aircraft has real flying
        // speed, then rotate - the way it is actually flown. Rotating at the
        // stall speed itself, which an earlier version of this test did, drags
        // the model into the air behind the drag curve and it mushes.
        rig.Controls.Set(RCChannel::Elevator,
                         rig.State.VelocityWorld.x > 11.5 ? 0.30 : 0.05);
        rig.Step();
        if (!rig.LastForces.OnGround && rig.State.VelocityWorld.x > 3.0)
        {
            airborne = true;
            rotationSpeed = rig.Airspeed();
            groundRoll = rig.State.PositionWorld.x;
        }
    }

    const ValidationTarget& target = rig.Definition.ValidationTargets["takeoff_ground_roll_m"];
    std::printf("        takeoff: %.1f m ground roll, unstuck at %.1f m/s "
                "(target %.1f m)\n", groundRoll, rotationSpeed, target.Value);

    RC_CHECK(airborne);
    // A 1.35 kg trainer with T/W near unity on grass gets off in well under a
    // runway length; outside this band something is badly wrong.
    RC_CHECK(groundRoll > 5.0 && groundRoll < 45.0);
    // It must not leave the ground below flying speed.
    RC_CHECK(rotationSpeed > 9.0);
    RC_CHECK(target.Accepts(groundRoll) || !target.Locked);
    RC_CHECK(rig.State.IsFinite());
}

RC_TEST(LandingGear, ClimbsAwayAfterTakeoff)
{
    FlightTestRig rig = GroundedTrainer(ctx);
    rig.Controls.Set(RCChannel::Throttle, 1.0);

    for (int i = 0; i < 240 * 20; ++i)
    {
        // Rotate at 1.45 times the stall speed, then hold a climb attitude.
        // A powered single at full throttle turns left unless someone holds
        // rudder, so the test flies it rather than letting go of it - that is
        // what a pilot does, and the aircraft is what is under test here.
        rig.HoldWingsLevel(rig.Airspeed() > 11.5 ? 0.22 : 0.05);
        rig.Step();
    }

    std::printf("        20 s after brake release: %.1f m up, %.1f m out, %.1f m/s\n",
                rig.Altitude(), rig.State.PositionWorld.x, rig.Airspeed());

    RC_CHECK(rig.Altitude() > 5.0);
    RC_CHECK(!rig.LastForces.OnGround);
    RC_CHECK(rig.State.IsFinite());
    RC_CHECK(std::fabs(units::ToDegrees(rig.State.Attitude().roll)) < 25.0);
}

RC_TEST(LandingGear, WillNotHoldHeadingHandsOffAtClimbPower)
{
    // The training-relevant claim, and the one that is robust: at climb power
    // this aircraft needs continuous attention. It will not sit there and fly
    // straight on its own.
    //
    // Which WAY it wanders is a balance of several real effects that pull in
    // opposite directions - the torque reaction rolls it left, while the
    // slipstream's asymmetric lift on the wing roots rolls it right, and the
    // swirl over the fin yaws it left. The net depends on `swirl_factor` in the
    // aircraft file, which Milestone 5 calibrates. The YAWING half of it is
    // pinned down precisely by PoweredFlight.RightThrustCancelsTheLeftTurningTendency;
    // this test only asserts that the aircraft is not self-flying.
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }
    rig.EnablePower(true);
    rig.PlaceAtAlpha(10.0, units::Degrees(6.0), 100.0);
    rig.Controls.Set(RCChannel::Throttle, 1.0);

    for (int i = 0; i < 240 * 6; ++i)
    {
        rig.HoldPitch(12.0);   // a climb attitude, so this measures yaw and roll
        rig.Step();
    }

    const Real heading = units::ToDegrees(rig.State.Attitude().yaw);
    const Real bank = units::ToDegrees(rig.State.Attitude().roll);
    std::printf("        climb power, hands off: %+.1f deg of heading and "
                "%+.1f deg of bank in 6 s\n", heading, bank);

    RC_CHECK(std::fabs(heading) > 5.0);    // it wanders
    RC_CHECK(std::fabs(heading) < 120.0);  // but it does not depart
    RC_CHECK(std::fabs(bank) < 45.0);
    RC_CHECK(rig.State.IsFinite());
}

RC_TEST(LandingGear, RightThrustOverCorrectsAtCruise)
{
    // The other half of the rigging story, and a real characteristic of the
    // aircraft rather than a modelling artefact: right thrust is set for the
    // climb, where the slipstream swirl is strongest. At cruise the swirl has
    // been diluted by the higher airspeed but the right thrust is still there
    // in proportion to thrust, so the aircraft turns slightly RIGHT at full
    // power. Real models behave the same way, which is why rigging is always a
    // compromise between the climb and the cruise.
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }
    rig.EnablePower(true);
    rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, units::Degrees(2.0), 100.0);
    rig.Controls.Set(RCChannel::Throttle, 1.0);

    for (int i = 0; i < 240 * 6; ++i)
    {
        rig.HoldPitch(3.0);
        rig.Step();
    }

    const Real heading = units::ToDegrees(rig.State.Attitude().yaw);
    std::printf("        full power at cruise, no rudder: heading %+.1f deg after 6 s\n",
                heading);

    RC_CHECK(heading > 0.0);
    RC_CHECK(heading < 45.0);   // a drift, not a spiral
    RC_CHECK(rig.State.IsFinite());
}

RC_TEST(LandingGear, RightRudderHoldsItStraight)
{
    // And the correction works: a little right rudder cancels it, which is the
    // habit the simulator is meant to build.
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }
    rig.EnablePower(true);
    rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, units::Degrees(2.0), 100.0);
    rig.Controls.Set(RCChannel::Throttle, 1.0);

    for (int i = 0; i < 240 * 6; ++i)
    {
        rig.HoldPitch(3.0);
        rig.HoldWingsLevel();
        rig.Step();
    }

    const Real heading = units::ToDegrees(rig.State.Attitude().yaw);
    std::printf("        full power, flown: heading %+.1f deg after 6 s, "
                "rudder %+.2f\n", heading, rig.Controls.Rudder());

    RC_CHECK(std::fabs(heading) < 20.0);
    RC_CHECK(std::fabs(units::ToDegrees(rig.State.Attitude().roll)) < 20.0);
    RC_CHECK(rig.State.IsFinite());
}
