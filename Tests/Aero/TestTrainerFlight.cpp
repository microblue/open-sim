#include "FlightTestRig.h"

#include <cstdio>

using namespace rc;
using namespace rctest;

RC_TEST(TrainerFlight, DefinitionLoads)
{
    FlightTestRig rig;
    const std::string error = rig.LoadTrainer();
    if (!error.empty()) { RC_FAIL("Trainer1500.json: " + error); return; }

    RC_CHECK(rig.Definition.Name == "Trainer 1500");
    RC_CHECK(rig.Definition.Surfaces.size() == 11);
    RC_CHECK(rig.Definition.Airfoils.size() == 2);
    RC_CHECK(rig.Definition.LandingGear.size() == 3);
    RC_CHECK_NEAR(rig.Definition.Mass, 1.35, 1e-12);
    RC_CHECK(rig.Definition.HasExplicitInertia);

    // Units must have been converted at load: inches to metres, RPM/V to rad/s/V.
    // The exact propeller is a tuning choice; what matters here is that the
    // inch value in the file arrived as a whole number of inches in metres.
    const Real diameterInches = units::ToInches(rig.Definition.Propulsion.Propeller.Diameter);
    RC_CHECK_NEAR(diameterInches, std::round(diameterInches), 1e-9);
    RC_CHECK(diameterInches > 8.0 && diameterInches < 12.0);
    RC_CHECK_NEAR(rig.Definition.Propulsion.Motor.KvRadPerSecondPerVolt,
                  1000.0 * kTwoPi / 60.0, 1e-6);
    RC_CHECK_NEAR(rig.Definition.Propulsion.Battery.CapacityCoulombs, 7920.0, 1e-6);
    RC_CHECK_NEAR(rig.Definition.Surfaces[0].Incidence, units::Degrees(2.0), 1e-12);
}

RC_TEST(TrainerFlight, PrintsTheTrimmedGlidePolar)
{
    // Not an assertion so much as the number a flight model is judged by.
    // Printed so a physics change shows up as a visible shift, not just a
    // pass/fail flip.
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }

    std::printf("\n        alpha   elev    speed      CL      L/D    sink   stalled\n");
    for (Real deg = 0.0; deg <= 16.0; deg += 2.0)
    {
        const TrimPoint p = TrimAtAlpha(rig, units::Degrees(deg));
        std::printf("        %5.1f  %+5.2f  %6.2f  %6.3f  %7.2f  %6.2f  %6.0f%%\n",
                    deg, p.Elevator, p.Speed, p.LiftCoefficient,
                    p.GlideRatio, p.SinkRate, p.StalledFraction * 100.0);
    }
    std::printf("\n");
    RC_CHECK(true);
}

RC_TEST(TrainerFlight, GlideRatioAndBestGlideSpeed)
{
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }

    TrimPoint best;
    for (Real deg = 0.0; deg <= 14.0; deg += 0.25)
    {
        const TrimPoint p = TrimAtAlpha(rig, units::Degrees(deg));
        if (p.Converged && p.GlideRatio > best.GlideRatio) { best = p; }
    }

    RC_CHECK(best.Converged);

    const ValidationTarget& target = rig.Definition.ValidationTargets["glide_ratio"];
    const ValidationTarget& speedTarget = rig.Definition.ValidationTargets["best_glide_speed_mps"];

    if (!target.Accepts(best.GlideRatio))
    {
        std::printf("        glide ratio %.2f vs target %.2f +/- %.0f%% (seed, not locked)\n",
                    best.GlideRatio, target.Value, target.Tolerance * 100.0);
    }
    // A 1.5 m film-covered trainer with fixed tricycle gear glides between about
    // 6:1 and 11:1. Outside that the model is wrong, not merely untuned.
    RC_CHECK(best.GlideRatio > 6.0 && best.GlideRatio < 11.0);
    RC_CHECK(best.Speed > 0.7 * speedTarget.Value && best.Speed < 1.4 * speedTarget.Value);
    RC_CHECK(best.SinkRate > 0.5 && best.SinkRate < 2.0);
}

RC_TEST(TrainerFlight, StallSpeed)
{
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }

    // The slowest trimmed speed the aircraft can hold is its stall speed.
    Real slowest = 1e30;
    Real clMax = 0.0;
    for (Real deg = 0.0; deg <= 20.0; deg += 0.25)
    {
        const TrimPoint p = TrimAtAlpha(rig, units::Degrees(deg));
        if (!p.Converged || p.StalledFraction > 0.25) { continue; }
        slowest = Min(slowest, p.Speed);
        clMax = Max(clMax, p.LiftCoefficient);
    }

    const ValidationTarget& target = rig.Definition.ValidationTargets["stall_speed_mps"];
    std::printf("        stall speed %.2f m/s (target %.2f), CL max %.3f\n",
                slowest, target.Value, clMax);

    RC_CHECK(slowest < 12.0);
    RC_CHECK(slowest > 6.0);
    // The whole-aircraft maximum lift coefficient has to be physically sane for
    // a washed-out flat-bottom wing carrying a tail download.
    RC_CHECK(clMax > 0.8 && clMax < 1.3);
}

RC_TEST(TrainerFlight, TrimsHandsOffAtCruise)
{
    // Static longitudinal stability: with the elevator held at its trim
    // position, a disturbance in angle of attack must produce a restoring
    // moment. This is the static margin, and without it the aircraft is
    // unflyable no matter how good everything else is.
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }

    const TrimPoint trimmed = TrimAtAlpha(rig, units::Degrees(4.0));
    RC_CHECK(trimmed.Converged);
    RC_CHECK(std::fabs(trimmed.Elevator) < 0.9);   // trims within the travel

    rig.Controls.Set(RCChannel::Elevator, trimmed.Elevator);

    rig.PlaceAtAlpha(trimmed.Speed, units::Degrees(4.0));
    const Real atTrim = rig.Evaluate().Total.Moment.y;

    rig.PlaceAtAlpha(trimmed.Speed, units::Degrees(7.0));
    const Real noseUp = rig.Evaluate().Total.Moment.y;

    rig.PlaceAtAlpha(trimmed.Speed, units::Degrees(1.0));
    const Real noseDown = rig.Evaluate().Total.Moment.y;

    RC_CHECK_NEAR(atTrim, 0.0, 0.02);
    RC_CHECK(noseUp < atTrim);      // pitched up -> nose-down restoring moment
    RC_CHECK(noseDown > atTrim);    // pitched down -> nose-up restoring moment
}

RC_TEST(TrainerFlight, RollRateAtCruise)
{
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }

    rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, units::Degrees(2.0));
    rig.Controls.Set(RCChannel::Aileron, 1.0);

    // One second is plenty for the roll rate to reach steady state on a model
    // with this little roll inertia.
    rig.StepFor(1.0);
    const Real rollRate = units::ToDegrees(rig.State.AngularVelocityBody.x);

    const ValidationTarget& target = rig.Definition.ValidationTargets["roll_rate_deg_per_s"];
    std::printf("        roll rate %.1f deg/s (target %.1f)\n", rollRate, target.Value);

    RC_CHECK(rollRate > 0.0);   // positive aileron rolls right
    // A trainer with 25 % ailerons on the outer half rolls somewhere between
    // 60 and 250 deg/s; outside that the control model is wrong.
    RC_CHECK(rollRate > 60.0 && rollRate < 250.0);

    // And it must be symmetric.
    rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, units::Degrees(2.0));
    rig.Controls.Set(RCChannel::Aileron, -1.0);
    rig.StepFor(1.0);
    RC_CHECK_NEAR(units::ToDegrees(rig.State.AngularVelocityBody.x), -rollRate,
                  0.12 * rollRate);
}

RC_TEST(TrainerFlight, GlidesStablyWhenReleased)
{
    // The dynamic counterpart of the trim test: released trimmed, the aircraft
    // must settle into a steady glide rather than diverge, tumble or blow up.
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }

    const TrimPoint trimmed = TrimAtAlpha(rig, units::Degrees(4.0));
    rig.Controls.Set(RCChannel::Elevator, trimmed.Elevator);
    rig.PlaceAtAlpha(trimmed.Speed, units::Degrees(4.0), 400.0);

    const Real startAltitude = rig.Altitude();
    rig.StepFor(20.0);

    RC_CHECK(rig.State.IsFinite());
    RC_CHECK(rig.Altitude() < startAltitude);          // it descends
    RC_CHECK(rig.Altitude() > startAltitude - 120.0);  // but not like a brick

    // Attitude must stay sane - no tumbling, no divergence.
    const EulerAngles attitude = rig.State.Attitude();
    RC_CHECK(std::fabs(units::ToDegrees(attitude.roll)) < 30.0);
    RC_CHECK(std::fabs(units::ToDegrees(attitude.pitch)) < 45.0);
    RC_CHECK(std::fabs(units::ToDegrees(attitude.yaw)) < 30.0);

    // Speed must stay in a plausible band rather than running away.
    RC_CHECK(rig.Airspeed() > 5.0 && rig.Airspeed() < 35.0);

    const Real glideRatio = (startAltitude - rig.Altitude()) > 1e-6
        ? rig.State.PositionWorld.x / (startAltitude - rig.Altitude())
        : 0.0;
    std::printf("        free glide: %.1f m forward per %.1f m down = %.2f : 1, "
                "%.1f m/s\n",
                rig.State.PositionWorld.x, startAltitude - rig.Altitude(),
                glideRatio, rig.Airspeed());
    RC_CHECK(glideRatio > 4.0);
}
