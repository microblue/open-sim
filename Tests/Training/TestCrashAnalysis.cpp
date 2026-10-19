// The crash analysis: does each kind of crash get the sentence an instructor
// would have said?
//
// Most of these build a recording by hand, because the point is the ordering
// of the rules - a stall after an engine failure is an engine failure - and a
// hand-built recording states the situation exactly. The last one flies the
// real trainer into the ground and checks the analysis agrees with physics.
#include "../Aero/FlightTestRig.h"

#include "RCPhysics/Aircraft/FailureModel.h"
#include "RCPhysics/Training/CrashAnalysis.h"

#include <cstdio>
#include <cstdlib>

using namespace rc;
using namespace rctest;

namespace
{
/** A straight, level, healthy frame at a height. Tests then bend it. */
FlightFrame Cruise(Real time, Real height, Real speed = 12.0)
{
    FlightFrame f;
    f.Time = time;
    f.PositionWorld = Vec3(speed * time, 0.0, -height);
    f.VelocityWorld = Vec3(speed, 0.0, 0.0);
    f.Airspeed = speed;
    f.HeightAboveGround = height;
    f.Controls.Set(RCChannel::Throttle, 0.5);
    return f;
}

/** Five seconds of something ending in a crash frame. */
template <typename Shape>
FlightRecorder Record(Shape shape)
{
    FlightRecorder recorder(30.0, 60.0);
    for (int i = 0; i <= 300; ++i)
    {
        const Real t = i / 60.0;
        FlightFrame f = shape(t, i == 300);
        f.Time = t;
        f.Crashed = (i == 300);
        recorder.Offer(f);
    }
    return recorder;
}

CrashResult Hit(const char* part, bool tree = false, bool gear = false)
{
    CrashResult c;
    c.Crashed = true;
    c.PointName = part;
    c.StruckObstacle = tree;
    c.GearCollapsed = gear;
    return c;
}
} // namespace

RC_TEST(CrashAnalysis, NoCrashMeansNoReport)
{
    const FlightRecorder r = Record([](Real t, bool) { return Cruise(t, 20.0); });
    CrashResult none;
    RC_CHECK(AnalyzeCrash(r, none).Cause == CrashCause::None);
    FlightRecorder empty;
    RC_CHECK(AnalyzeCrash(empty, Hit("nose")).Cause == CrashCause::None);
}

RC_TEST(CrashAnalysis, AFailureOutranksTheStallItCaused)
{
    // The motor stops at 2 s, 30 m up; the pilot lets the speed decay and
    // stalls on the way down. The lesson is the dead stick, not the stall.
    const FlightRecorder r = Record([](Real t, bool) {
        FlightFrame f = Cruise(t, Max(30.0 - 8.0 * Max(t - 2.0, 0.0), 0.0));
        if (t >= 2.0) { f.Failure = static_cast<int>(FailureKind::DeadStick); }
        if (t >= 4.0) { f.StalledFraction = 0.9; f.AngularVelocityBody.z = 2.5; }
        return f;
    });
    const CrashReport report = AnalyzeCrash(r, Hit("nose"));
    RC_CHECK(report.Cause == CrashCause::Failure);
    RC_CHECK(report.Failure == static_cast<int>(FailureKind::DeadStick));
    RC_CHECK(report.Title == "Engine failure");
    RC_CHECK_NEAR(report.OnsetToImpact, 3.0, 0.05);
    RC_CHECK_NEAR(report.OnsetHeight, 30.0, 0.5);
}

RC_TEST(CrashAnalysis, ATreeIsATree)
{
    const FlightRecorder r = Record([](Real t, bool) { return Cruise(t, 8.0); });
    RC_CHECK(AnalyzeCrash(r, Hit("wing_tip_left", true)).Cause == CrashCause::Obstacle);
}

RC_TEST(CrashAnalysis, AWingtipOnTheTakeoffRollIsGroundHandling)
{
    const FlightRecorder r = Record([](Real t, bool) {
        FlightFrame f = Cruise(t, 0.2, 2.0 * t);
        f.OnGround = true;
        f.Orientation = Quat::FromEuler(units::Degrees(25.0), 0.0, 0.0);
        return f;
    });
    const CrashReport report = AnalyzeCrash(r, Hit("wing_tip_right"));
    RC_CHECK(report.Cause == CrashCause::GroundHandling);
    RC_CHECK(report.Title == "Caught a wingtip");

    const FlightRecorder n = Record([](Real t, bool) {
        FlightFrame f = Cruise(t, 0.2, 3.0);
        f.OnGround = true;
        return f;
    });
    RC_CHECK(AnalyzeCrash(n, Hit("propeller")).Title == "Nosed over");
}

RC_TEST(CrashAnalysis, SpinTipStallAndStallAreToldApart)
{
    // Stalled and yawing fast: a spin.
    const FlightRecorder spin = Record([](Real t, bool) {
        FlightFrame f = Cruise(t, Max(40.0 - 9.0 * t, 0.0), 9.0);
        if (t > 1.0) { f.StalledFraction = 0.95; f.AngularVelocityBody = Vec3(3.0, 0.0, 3.5); }
        return f;
    });
    const CrashReport s = AnalyzeCrash(spin, Hit("wing_tip_left"));
    RC_CHECK(s.Cause == CrashCause::Spin);
    RC_CHECK(s.PeakYawRateDegrees > 190.0);
    RC_CHECK(s.OnsetHeight > 25.0);

    // Part of the wing gone and a hard roll, little yaw: a tip stall.
    const FlightRecorder tip = Record([](Real t, bool) {
        FlightFrame f = Cruise(t, Max(10.0 - 3.0 * t, 0.0), 8.0);
        if (t > 3.0) { f.StalledFraction = 0.35; f.AngularVelocityBody = Vec3(3.2, 0.0, 0.3); }
        return f;
    });
    RC_CHECK(AnalyzeCrash(tip, Hit("wing_tip_right")).Cause == CrashCause::TipStall);

    // Stalled, nothing rotating: a plain stall.
    const FlightRecorder stall = Record([](Real t, bool) {
        FlightFrame f = Cruise(t, Max(6.0 - 1.5 * t, 0.0), 7.0);
        if (t > 2.0) { f.StalledFraction = 0.8; }
        return f;
    });
    const CrashReport plain = AnalyzeCrash(stall, Hit("nose"));
    RC_CHECK(plain.Cause == CrashCause::Stall);
    RC_CHECK_NEAR(plain.OnsetHeight, 3.0, 0.1);
}

RC_TEST(CrashAnalysis, AHardLandingIsWingsLevelAndSinking)
{
    const FlightRecorder r = Record([](Real t, bool) {
        FlightFrame f = Cruise(t, Max(15.0 - 3.0 * t, 0.0), 11.0);
        f.VelocityWorld.z = 4.6;
        return f;
    });
    const CrashReport report = AnalyzeCrash(r, Hit("gear", false, true));
    RC_CHECK(report.Cause == CrashCause::HardLanding);
    RC_CHECK_NEAR(report.SinkRate, 4.6, 1e-9);
}

RC_TEST(CrashAnalysis, SteepBankIsASpiral)
{
    const FlightRecorder r = Record([](Real t, bool) {
        FlightFrame f = Cruise(t, Max(50.0 - 10.0 * t, 0.0), 20.0);
        f.Orientation = Quat::FromEuler(units::Degrees(75.0), units::Degrees(-40.0), 0.0);
        f.VelocityWorld = Vec3(15.0, 0.0, 13.0);
        return f;
    });
    const CrashReport report = AnalyzeCrash(r, Hit("wing_tip_right"));
    RC_CHECK(report.Cause == CrashCause::SpiralDive);
    RC_CHECK(report.Title == "Spiral dive");
}

RC_TEST(CrashAnalysis, LevelAndFlyingIsFlyingIntoTheGround)
{
    const FlightRecorder r = Record([](Real t, bool) {
        FlightFrame f = Cruise(t, Max(10.0 - 2.0 * t, 0.0), 12.0);
        f.VelocityWorld.z = 2.0;
        return f;
    });
    const CrashReport report = AnalyzeCrash(r, Hit("propeller"));
    RC_CHECK(report.Cause == CrashCause::FlewIntoGround);
    RC_CHECK(!report.Detail.empty() && !report.Advice.empty());
}

RC_TEST(CrashAnalysis, EachAircraftSpinsInTrueToItsCharacter)
{
    // Physics, not a hand-built recording. Every aircraft in the roster at
    // 25 m, motor off, full up elevator and full left rudder held all the way
    // down - the classic way to spin in. They do not all do the same thing,
    // and the analysis has to say what each one actually did:
    //
    //   the trainer never stalls; it just winds into a spiral (forgiving, as a
    //   trainer should be - full up alone, wings level, does not even crash it)
    //   the warbird, with the highest wing loading, snaps into a spin
    //   the glider stalls straight ahead
    //   the sport aerobat drops a wing
    //
    // A change to the flight model that erases those differences fails here.
    struct Expectation { const char* stem; CrashCause a; CrashCause b; };
    const Expectation roster[] = {
        {"Trainer1500", CrashCause::SpiralDive, CrashCause::SpiralDive},
        {"Warbird1100", CrashCause::Spin,       CrashCause::Spin},
        {"Glider2400",  CrashCause::Stall,      CrashCause::Stall},
        {"Sport1200",   CrashCause::TipStall,   CrashCause::Spin},
    };
    std::printf("\n");
    for (const Expectation& e : roster)
    {
        FlightTestRig rig;
        if (!rig.Load(e.stem).empty()) { RC_FAIL(std::string("could not load ") + e.stem); return; }
        rig.EnableGround(true);
        rig.PlaceAtAlpha(11.0, units::Degrees(2.0), 25.0);

        FlightRecorder recorder(60.0, 60.0);
        CrashResult crash;
        rig.Evaluate();
        while (rig.Time < 30.0 && !crash.Crashed)
        {
            rig.Controls.Set(RCChannel::Elevator, 1.0);
            rig.Controls.Set(RCChannel::Rudder, -1.0);
            rig.Step();
            crash = rig.Plane.Crash().Check(rig.State, rig.Ground, rig.LastForces.Wheels);

            FlightFrame f;
            f.Time = rig.Time;
            f.PositionWorld = rig.State.PositionWorld;
            f.Orientation = rig.State.Orientation;
            f.VelocityWorld = rig.State.VelocityWorld;
            f.AngularVelocityBody = rig.State.AngularVelocityBody;
            f.Airspeed = rig.LastForces.Airspeed;
            f.Alpha = rig.LastForces.Alpha;
            f.StalledFraction = rig.LastForces.StalledWingFraction;
            f.HeightAboveGround = rig.LastForces.HeightAboveGround;
            f.OnGround = rig.LastForces.OnGround;
            f.Controls = rig.Controls;
            f.Crashed = crash.Crashed;
            recorder.Offer(f);
        }

        const CrashReport report =
            AnalyzeCrash(recorder, crash, CrashAnalysisSettingsFor(rig.Definition));
        std::printf("        %-12s %-13s %s\n", e.stem, report.Title.c_str(),
                    report.Detail.c_str());
        RC_CHECK(crash.Crashed);
        RC_CHECK(report.Cause == e.a || report.Cause == e.b);
    }
    std::printf("\n");
}
