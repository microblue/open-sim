// OpenRC Simulator - the regression gate for the Trainer 1500.
//
// Every number a flight model is judged by, measured the way a pilot would
// measure it, and compared against the targets stored in the aircraft file.
//
// A target marked "locked" is a measurement: failing it fails the build. A
// target marked otherwise is a first-principles seed, and a deviation is
// reported but tolerated. Milestone 5 is the act of turning the seeds into
// measurements.
//
// The measurements deliberately do NOT share state with each other, so that a
// change which breaks one shows up as one failure rather than a cascade.
#include "../Aero/FlightTestRig.h"

#include <cstdio>
#include <map>

using namespace rc;
using namespace rctest;

namespace
{
struct Measurement
{
    Real Value = 0.0;
    const char* Units = "";
};

/** Trimmed, power-off polar: best glide ratio, the speed it happens at, the
 *  minimum sink rate, and the slowest speed the aircraft can hold. */
struct GlidePolar
{
    Real BestGlideRatio = 0.0;
    Real BestGlideSpeed = 0.0;
    Real MinimumSink    = 1e30;
    Real StallSpeed     = 1e30;
    Real MaximumLiftCoefficient = 0.0;
};

GlidePolar MeasureGlidePolar(FlightTestRig& rig)
{
    GlidePolar polar;
    for (Real degrees = 0.0; degrees <= 18.0; degrees += 0.25)
    {
        const TrimPoint point = TrimAtAlpha(rig, units::Degrees(degrees));
        if (!point.Converged) { continue; }

        if (point.GlideRatio > polar.BestGlideRatio)
        {
            polar.BestGlideRatio = point.GlideRatio;
            polar.BestGlideSpeed = point.Speed;
        }
        if (point.StalledFraction <= 0.25)
        {
            polar.MinimumSink = Min(polar.MinimumSink, point.SinkRate);
            polar.StallSpeed  = Min(polar.StallSpeed, point.Speed);
            polar.MaximumLiftCoefficient =
                Max(polar.MaximumLiftCoefficient, point.LiftCoefficient);
        }
    }
    return polar;
}

Real MeasureStaticThrust(FlightTestRig& rig)
{
    return rig.Power.SolveSteady(1.0, 0.0, units::kSeaLevelDensity).Thrust;
}

Real MeasureRollRate(FlightTestRig& rig)
{
    rig.EnablePower(false);
    rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, units::Degrees(2.0));
    rig.Controls = ChannelValues::Neutral();
    rig.Controls.Set(RCChannel::Aileron, 1.0);
    rig.StepFor(1.0);
    return units::ToDegrees(rig.State.AngularVelocityBody.x);
}

/** Speed held in level flight at a given throttle, found by flying it. */
Real MeasureLevelSpeed(FlightTestRig& rig, Real throttle)
{
    rig.EnablePower(true);
    rig.EnableGround(false);
    rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, units::Degrees(2.0), 300.0);
    rig.Controls = ChannelValues::Neutral();
    rig.Controls.Set(RCChannel::Throttle, throttle);

    // Hold altitude with the elevator and let the speed settle wherever it
    // wants to; that speed is the answer.
    Real altitudeTarget = rig.Altitude();
    Real speedSum = 0.0;
    int  speedSamples = 0;

    for (int i = 0; i < 240 * 40; ++i)
    {
        const Real altitudeError = rig.Altitude() - altitudeTarget;
        const Real climbRate = -rig.State.VelocityWorld.z;
        rig.Controls.Set(RCChannel::Elevator,
                         ClampUnit(-0.10 * altitudeError - 0.25 * climbRate
                                   - 0.4 * rig.State.AngularVelocityBody.y));
        rig.HoldWingsLevel();
        rig.Step();

        if (i > 240 * 25) { speedSum += rig.Airspeed(); ++speedSamples; }
    }
    return (speedSamples > 0) ? speedSum / speedSamples : 0.0;
}

Real MeasureTakeoffRoll(FlightTestRig& rig)
{
    rig.EnablePower(true);
    rig.EnableGround(true);
    rig.PlaceOnRunway();
    rig.Controls = ChannelValues::Neutral();
    rig.Controls.Set(RCChannel::Throttle, 1.0);

    for (int i = 0; i < 240 * 25; ++i)
    {
        rig.Controls.Set(RCChannel::Elevator,
                         rig.State.VelocityWorld.x > 11.5 ? 0.30 : 0.05);
        rig.Step();
        if (!rig.LastForces.OnGround && rig.State.VelocityWorld.x > 3.0)
        {
            return rig.State.PositionWorld.x;
        }
    }
    return -1.0;
}

/** Compare one measurement against its stored target and report. */
void Report(rctest::TestContext& ctx, const AircraftDefinition& definition,
            const char* key, Real measured, const char* units)
{
    const auto entry = definition.ValidationTargets.find(key);
    if (entry == definition.ValidationTargets.end())
    {
        std::printf("        %-26s %9.2f %-7s  (no target in the aircraft file)\n",
                    key, measured, units);
        ctx.Fail(std::string(key) + ": no target in the aircraft file", __FILE__, 0);
        return;
    }

    const ValidationTarget& target = entry->second;
    const Real deviation = (std::fabs(target.Value) > kEpsilon)
                         ? (measured - target.Value) / target.Value
                         : 0.0;
    const bool accepted = target.Accepts(measured);

    std::printf("        %-26s %9.2f %-7s target %7.2f +/-%3.0f%%  %+6.1f%%  %s%s\n",
                key, measured, units, target.Value, target.Tolerance * 100.0,
                deviation * 100.0,
                accepted ? "ok" : "OUT",
                target.Locked ? "" : "   (seed)");

    if (target.Locked)
    {
        // A locked target is a measurement. Missing it is a regression.
        static std::string message;
        message = std::string(key) + " is outside its locked tolerance";
        ctx.Check(accepted, message.c_str(), __FILE__, 0);
    }
}
}

RC_TEST(TrainerTargets, EveryPerformanceNumberMatchesTheAircraftFile)
{
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }
    const AircraftDefinition definition = rig.Definition;

    std::printf("\n        %-26s %9s %-7s %-20s %7s\n",
                "measurement", "measured", "", "target", "delta");

    // --- power off ------------------------------------------------------
    rig.EnablePower(false);
    rig.EnableGround(false);
    const GlidePolar polar = MeasureGlidePolar(rig);

    Report(ctx, definition, "glide_ratio", polar.BestGlideRatio, ": 1");
    Report(ctx, definition, "best_glide_speed_mps", polar.BestGlideSpeed, "m/s");
    Report(ctx, definition, "min_sink_rate_mps", polar.MinimumSink, "m/s");
    Report(ctx, definition, "stall_speed_mps", polar.StallSpeed, "m/s");
    Report(ctx, definition, "roll_rate_deg_per_s", MeasureRollRate(rig), "deg/s");

    // --- power on -------------------------------------------------------
    Report(ctx, definition, "static_thrust_n", MeasureStaticThrust(rig), "N");
    Report(ctx, definition, "cruise_speed_mps", MeasureLevelSpeed(rig, 0.60), "m/s");
    Report(ctx, definition, "takeoff_ground_roll_m", MeasureTakeoffRoll(rig), "m");

    std::printf("\n        maximum lift coefficient %.3f, thrust-to-weight %.2f\n\n",
                polar.MaximumLiftCoefficient,
                MeasureStaticThrust(rig) / (definition.Mass * units::kGravity));

    RC_CHECK(polar.BestGlideRatio > 0.0);
}

RC_TEST(TrainerTargets, TheAircraftFileDeclaresEveryTargetTheSuiteMeasures)
{
    // Keeps the file and this suite from drifting apart: adding a measurement
    // without a target, or removing a target that is still measured, both fail.
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }

    static const char* const kRequired[] = {
        "glide_ratio", "best_glide_speed_mps", "min_sink_rate_mps", "stall_speed_mps",
        "roll_rate_deg_per_s", "static_thrust_n", "cruise_speed_mps",
        "takeoff_ground_roll_m"
    };

    for (const char* key : kRequired)
    {
        if (rig.Definition.ValidationTargets.find(key) == rig.Definition.ValidationTargets.end())
        {
            RC_FAIL(std::string("Trainer1500.json is missing the target '") + key + "'");
        }
    }
    RC_CHECK(rig.Definition.ValidationTargets.size() == 8);
}

RC_TEST(TrainerTargets, MeasurementsAreRepeatable)
{
    // Determinism, end to end. Two identical runs must give bit-identical
    // results, or none of the numbers above mean anything.
    auto run = []()
    {
        FlightTestRig rig;
        rig.LoadTrainer();
        rig.EnablePower(true);
        rig.EnableGround(true);
        rig.Wind.SetSeed(4242u);
        rig.Wind.SetSteady(3.0, units::Degrees(250.0));
        rig.Wind.SetGust(2.0, 7.0);
        rig.Wind.SetTurbulence(0.8, 5.0);
        rig.PlaceOnRunway();
        rig.Controls.Set(RCChannel::Throttle, 1.0);
        for (int i = 0; i < 240 * 6; ++i)
        {
            rig.Controls.Set(RCChannel::Elevator,
                             rig.State.VelocityWorld.x > 11.5 ? 0.30 : 0.05);
            rig.Step();
        }
        return rig.State;
    };

    const RigidBodyState first = run();
    const RigidBodyState second = run();

    RC_CHECK(NearlyEqual(first.PositionWorld, second.PositionWorld, 1e-12));
    RC_CHECK(NearlyEqual(first.VelocityWorld, second.VelocityWorld, 1e-12));
    RC_CHECK(NearlySameRotation(first.Orientation, second.Orientation, 1e-12));
    RC_CHECK(first.IsFinite());
    // And it must have actually flown, not sat still.
    RC_CHECK(first.PositionWorld.x > 10.0);
}
