#include "../Aero/FlightTestRig.h"

#include <cstdio>

using namespace rc;
using namespace rctest;

namespace
{
    FlightTestRig PoweredTrainer(rctest::TestContext& ctx)
    {
        FlightTestRig rig;
        const std::string error = rig.LoadTrainer();
        if (!error.empty()) { ctx.Fail("Trainer1500.json: " + error, __FILE__, __LINE__); }
        rig.EnablePower(true);
        return rig;
    }
}

RC_TEST(PoweredFlight, FullThrottleAcceleratesFromCruise)
{
    FlightTestRig rig = PoweredTrainer(ctx);
    rig.PlaceAtAlpha(12.0, units::Degrees(2.0));
    rig.Controls.Set(RCChannel::Throttle, 1.0);
    rig.Controls.Set(RCChannel::Elevator, 0.0);

    const Real start = 12.0;
    rig.StepFor(6.0);

    std::printf("\n        12 -> %.1f m/s in 6 s at full throttle, %.0f rpm, %.1f A\n",
                rig.Airspeed(), rig.Power.State().Rpm, rig.Power.State().Current);

    RC_CHECK(rig.Airspeed() > start);
    RC_CHECK(rig.Airspeed() < 40.0);
    RC_CHECK(rig.Power.State().Thrust > 0.0);
    RC_CHECK(rig.State.IsFinite());
}

RC_TEST(PoweredFlight, ThrottleAloneWillClimbTheAircraft)
{
    // Thrust-to-weight near unity means a trainee can climb out of a mistake.
    FlightTestRig rig = PoweredTrainer(ctx);
    rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, units::Degrees(2.0), 100.0);
    rig.Controls.Set(RCChannel::Throttle, 1.0);
    rig.Controls.Set(RCChannel::Elevator, 0.15);

    const Real startAltitude = rig.Altitude();
    rig.StepFor(8.0);

    std::printf("        climb: %+.1f m in 8 s (%.2f m/s), airspeed %.1f m/s\n",
                rig.Altitude() - startAltitude,
                (rig.Altitude() - startAltitude) / 8.0, rig.Airspeed());

    RC_CHECK(rig.Altitude() > startAltitude);
    RC_CHECK(rig.State.IsFinite());
}

RC_TEST(PoweredFlight, ThrottleOffDescends)
{
    FlightTestRig rig = PoweredTrainer(ctx);
    rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, units::Degrees(2.0), 100.0);
    rig.Controls.Set(RCChannel::Throttle, 0.0);

    const Real startAltitude = rig.Altitude();
    rig.StepFor(8.0);

    RC_CHECK(rig.Altitude() < startAltitude);
    RC_CHECK_NEAR(rig.Power.State().Thrust, 0.0, 0.5);
}

RC_TEST(PoweredFlight, ClockwisePropellerRollsLeftOnPower)
{
    // The reaction to the torque driving the propeller. With a clockwise
    // propeller the airframe rolls left, and a trainee learns to expect it on
    // every throttle application.
    FlightTestRig rig = PoweredTrainer(ctx);
    RC_CHECK(rig.Definition.Propulsion.Propeller.Clockwise);

    rig.PlaceAtAlpha(9.0, units::Degrees(8.0));
    rig.Controls.Set(RCChannel::Throttle, 1.0);
    for (int i = 0; i < 240; ++i) { rig.Step(); }

    rig.FreezeAtAlpha(9.0, units::Degrees(8.0));
    rig.StepPropulsion();
    const AircraftForces forces = rig.Plane.ComputeForces(
        rig.State, rig.Controls, rig.Air, rig.Wind, rig.Propulsion);
    const Wrench propulsion = forces.Accumulator.GetBySource(ForceSource::Propulsion);

    std::printf("\n        propulsion moments: roll %+.3f  pitch %+.3f  yaw %+.3f N.m\n",
                propulsion.Moment.x, propulsion.Moment.y, propulsion.Moment.z);

    RC_CHECK(propulsion.Moment.x < 0.0);   // rolls left
    RC_CHECK(propulsion.Force.x > 0.0);    // and pushes forwards

    // Reversing the rotation must reverse the roll.
    AircraftDefinition mirrored = rig.Definition;
    mirrored.Propulsion.Propeller.Clockwise = false;
    Aircraft counterRotating;
    counterRotating.Configure(mirrored);

    PropulsionOutput output = rig.Propulsion;
    output.WakeSwirl = -output.WakeSwirl;
    output.AngularMomentum = -output.AngularMomentum;

    const Wrench reversed = counterRotating.ComputeForces(
        rig.State, rig.Controls, rig.Air, rig.Wind, output)
        .Accumulator.GetBySource(ForceSource::Propulsion);
    RC_CHECK(reversed.Moment.x > 0.0);
}

RC_TEST(PoweredFlight, RightThrustCancelsTheLeftTurningTendency)
{
    // Slipstream swirl over the fin and P-factor both yaw a clockwise-propeller
    // model to the LEFT under power. Real trainers are rigged with a couple of
    // degrees of right thrust precisely to cancel that at climb power.
    //
    // This test measures both: that the tendency exists at all when the rigging
    // is removed, and that the rigging as specified actually cancels it.
    FlightTestRig rig = PoweredTrainer(ctx);

    // Spool up in a slow climb, which is where the tendency is strongest.
    rig.PlaceAtAlpha(9.0, units::Degrees(8.0));
    rig.Controls.Set(RCChannel::Throttle, 1.0);
    for (int i = 0; i < 240; ++i) { rig.Step(); }
    rig.FreezeAtAlpha(9.0, units::Degrees(8.0));
    rig.StepPropulsion();

    auto totalYawWith = [&](Real rightThrustDegrees, const PropulsionOutput& output)
    {
        AircraftDefinition definition = rig.Definition;
        definition.Propulsion.Mount.RightThrust = units::Degrees(rightThrustDegrees);
        Aircraft plane;
        plane.Configure(definition);
        return plane.ComputeForces(rig.State, rig.Controls, rig.Air, rig.Wind, output)
                    .Total.Moment.z;
    };

    const PropulsionOutput running = rig.Propulsion;
    const PropulsionOutput stopped = PropulsionOutput{};

    const Real unriggedPower = totalYawWith(0.0, running);
    const Real unriggedGlide = totalYawWith(0.0, stopped);
    const Real riggedPower   = totalYawWith(2.0, running);

    std::printf("        yaw moment, no right thrust:  glide %+.4f  power %+.4f N.m\n",
                unriggedGlide, unriggedPower);
    std::printf("        yaw moment, 2 deg right thrust: power %+.4f N.m\n", riggedPower);

    // Without the rigging, opening the throttle yaws the aircraft left.
    RC_CHECK(unriggedPower < unriggedGlide);
    RC_CHECK(unriggedPower < 0.0);

    // With the rigging it is much closer to neutral - that is what the rigging
    // is for, and it is why the number in the aircraft file is 2 degrees.
    RC_CHECK(riggedPower > unriggedPower);
    RC_CHECK(std::fabs(riggedPower) < std::fabs(unriggedPower));
}

RC_TEST(PoweredFlight, PropwashGivesElevatorAuthorityAtWalkingPace)
{
    // The single most important RC-specific effect. At 4 m/s the tail has
    // almost no airspeed of its own, but with the throttle open the slipstream
    // gives it real authority - which is why a powered model can be held off
    // the ground at a speed where an unpowered one simply falls out of the sky,
    // and why chopping the throttle on short final drops the nose.
    FlightTestRig rig = PoweredTrainer(ctx);

    auto pitchMomentAt = [&](Real throttle)
    {
        rig.PlaceAtAlpha(4.0, units::Degrees(2.0));
        rig.Controls.Set(RCChannel::Throttle, throttle);
        rig.Controls.Set(RCChannel::Elevator, 1.0);
        // Let the propeller reach its speed, then freeze the flight condition
        // WITHOUT resetting the power system, so the wake is fully developed.
        for (int i = 0; i < 240; ++i) { rig.Step(); }
        rig.FreezeAtAlpha(4.0, units::Degrees(2.0));
        rig.StepPropulsion();
        return rig.Plane.ComputeForces(rig.State, rig.Controls, rig.Air, rig.Wind,
                                       rig.Propulsion).Total.Moment.y;
    };

    const Real idle = pitchMomentAt(0.0);
    const Real power = pitchMomentAt(1.0);

    std::printf("        pitch moment at 4 m/s, full up elevator: "
                "idle %+.3f, full throttle %+.3f N.m\n", idle, power);

    RC_CHECK(power > idle);
    RC_CHECK(power > 3.0 * std::fabs(idle));

    // And the effect must be the wake, not the thrust line: with propwash
    // disabled the same throttle does almost nothing for the elevator.
    AircraftDefinition noWash = rig.Definition;
    noWash.Propulsion.Propwash.Enabled = false;
    Aircraft plane;
    plane.Configure(noWash);
    const Real withoutWash = plane.ComputeForces(rig.State, rig.Controls, rig.Air,
                                                 rig.Wind, rig.Propulsion).Total.Moment.y;
    RC_CHECK(withoutWash < 0.5 * power);
}

RC_TEST(PoweredFlight, GyroscopicPrecessionActsAcrossAxes)
{
    // A spinning propeller turns a pitch input into a yaw output. With a
    // clockwise propeller, pitching the nose DOWN yaws it left - the reason a
    // taildragger swings when the tail comes up.
    FlightTestRig rig = PoweredTrainer(ctx);
    rig.PlaceAtAlpha(14.0, units::Degrees(2.0));
    rig.Controls.Set(RCChannel::Throttle, 1.0);
    for (int i = 0; i < 240; ++i) { rig.Step(); }

    RC_CHECK(rig.Propulsion.AngularMomentum > 0.0);

    auto yawFromPitchRate = [&](Real pitchRate)
    {
        rig.State.AngularVelocityBody = Vec3(0.0, pitchRate, 0.0);
        rig.StepPropulsion();
        const AircraftForces forces = rig.Plane.ComputeForces(
            rig.State, rig.Controls, rig.Air, rig.Wind, rig.Propulsion);
        return forces.Accumulator.GetBySource(ForceSource::Propulsion).Moment.z;
    };

    const Real noseDown = yawFromPitchRate(-3.0);
    const Real noseUp   = yawFromPitchRate(3.0);

    RC_CHECK(noseDown < noseUp);
    // The gyroscopic term is antisymmetric in the rate, so the difference is
    // twice the term itself.
    RC_CHECK(std::fabs(noseUp - noseDown) > 0.01);
}

RC_TEST(PoweredFlight, LevelFlightNeedsPartThrottle)
{
    // Find the throttle that holds altitude at cruise. A trainer should cruise
    // comfortably at somewhere between a third and three quarters of power; if
    // it needs everything, it has no reserve to climb with.
    FlightTestRig rig = PoweredTrainer(ctx);

    Real low = 0.0, high = 1.0, throttle = 0.5;
    for (int iteration = 0; iteration < 12; ++iteration)
    {
        throttle = 0.5 * (low + high);
        rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, units::Degrees(2.0), 200.0);
        rig.Controls.Set(RCChannel::Throttle, throttle);
        rig.Controls.Set(RCChannel::Elevator, 0.09);

        const Real startAltitude = rig.Altitude();
        rig.StepFor(6.0);
        if (rig.Altitude() > startAltitude) { high = throttle; } else { low = throttle; }
    }

    std::printf("        level flight needs about %.0f%% throttle at %.1f m/s\n",
                throttle * 100.0, rig.Airspeed());

    RC_CHECK(throttle > 0.15 && throttle < 0.85);
    RC_CHECK(rig.State.IsFinite());
}

RC_TEST(PoweredFlight, PropwashSwirlDependsOnDistanceFromTheAxis)
{
    // Sections inside the wake feel it; sections outside do not. The wing tips
    // are well clear of a 10 inch propeller.
    FlightTestRig rig = PoweredTrainer(ctx);
    rig.PlaceAtAlpha(8.0, units::Degrees(2.0));
    rig.Controls.Set(RCChannel::Throttle, 1.0);
    for (int i = 0; i < 240; ++i) { rig.Step(); }

    const Vec3 onAxis = rig.Plane.PropwashAt(Vec3(-0.62, 0.0, -0.02), rig.Propulsion);
    const Vec3 atTip  = rig.Plane.PropwashAt(Vec3(0.009, 0.656, -0.125), rig.Propulsion);
    const Vec3 ahead  = rig.Plane.PropwashAt(Vec3(0.60, 0.0, 0.0), rig.Propulsion);

    RC_CHECK(onAxis.Length() > 5.0);      // the tail is well inside the wake
    RC_CHECK(atTip.IsNearlyZero());       // the tip is well outside it
    RC_CHECK(ahead.IsNearlyZero());       // and nothing happens ahead of the disc
}
