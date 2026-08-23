#include "TestHarness.h"

#include "RCPhysics/Core/Clock/SimulationClock.h"

using namespace rc;

namespace
{
    int RunFrame(SimulationClock& clock, Real frameSeconds)
    {
        clock.AddFrameTime(frameSeconds);
        int steps = 0;
        while (clock.ConsumeStep()) { ++steps; }
        return steps;
    }
}

RC_TEST(SimulationClock, DefaultsTo240Hz)
{
    SimulationClock clock;
    RC_CHECK_NEAR(clock.RateHz(), 240.0, 1e-12);
    RC_CHECK_NEAR(clock.FixedDeltaSeconds(), 1.0 / 240.0, 1e-15);
}

RC_TEST(SimulationClock, SixtyFpsFrameYieldsFourSteps)
{
    SimulationClock clock;
    RC_CHECK(RunFrame(clock, 1.0 / 60.0) == 4);
    RC_CHECK(clock.TotalStepCount() == 4);
}

RC_TEST(SimulationClock, SimulatedTimeTracksWallClockOverManyFrames)
{
    // One second of 144 FPS rendering must simulate one second of physics,
    // give or take the partial step still sitting in the accumulator.
    SimulationClock clock;
    const Real frame = 1.0 / 144.0;
    for (int i = 0; i < 144; ++i)
    {
        RunFrame(clock, frame);
    }

    RC_CHECK(clock.DroppedSteps() == 0);
    RC_CHECK_NEAR(clock.SimulatedTimeSeconds(), 1.0, clock.FixedDeltaSeconds());
    RC_CHECK(clock.SimulatedTimeSeconds() <= 1.0 + 1e-12);
}

RC_TEST(SimulationClock, PhysicsRateIsIndependentOfFramerate)
{
    // The whole point of the fixed step: 30 FPS and 200 FPS must produce the
    // same number of physics steps for the same elapsed wall-clock time.
    SimulationClock slow;
    SimulationClock fast;

    const int slowFrames = 30;
    const int fastFrames = 200;
    for (int i = 0; i < slowFrames; ++i) { RunFrame(slow, 1.0 / 30.0); }
    for (int i = 0; i < fastFrames; ++i) { RunFrame(fast, 1.0 / 200.0); }

    RC_CHECK(slow.DroppedSteps() == 0);
    RC_CHECK(fast.DroppedSteps() == 0);
    RC_CHECK(slow.TotalStepCount() == fast.TotalStepCount());
    RC_CHECK(slow.TotalStepCount() == 240);
}

RC_TEST(SimulationClock, InterpolationAlphaStaysInRange)
{
    SimulationClock clock;
    clock.AddFrameTime(1.0 / 100.0);   // 2.4 steps worth
    while (clock.ConsumeStep()) {}

    const Real alpha = clock.InterpolationAlpha();
    RC_CHECK(alpha >= 0.0 && alpha <= 1.0);
    RC_CHECK_NEAR(alpha, 0.4, 1e-9);
}

RC_TEST(SimulationClock, LongHitchIsClampedNotCaughtUp)
{
    // A two-second stall (breakpoint, level load) must not fire 480 steps.
    SimulationClock clock;
    const int steps = RunFrame(clock, 2.0);

    RC_CHECK(steps <= clock.GetMaxStepsPerFrame());
    RC_CHECK(clock.DiscardedTimeSeconds() > 1.0);
}

RC_TEST(SimulationClock, StepBudgetPreventsSpiralOfDeath)
{
    SimulationClock clock;
    clock.SetMaxStepsPerFrame(4);

    // Ask for 24 steps worth of time in one frame; only 4 may run.
    const int steps = RunFrame(clock, 24.0 / 240.0);
    RC_CHECK(steps == 4);
    RC_CHECK(clock.DroppedSteps() > 0);

    // The accumulator must not still hold a backlog, or the next frame stalls too.
    RC_CHECK(clock.InterpolationAlpha() <= 1.0);
}

RC_TEST(SimulationClock, RejectsNonsenseFrameTimes)
{
    SimulationClock clock;
    clock.AddFrameTime(-1.0);
    clock.AddFrameTime(0.0);
    clock.AddFrameTime(std::nan(""));
    RC_CHECK(clock.TotalStepCount() == 0);
    RC_CHECK(!clock.ConsumeStep());
}

RC_TEST(SimulationClock, RateChangeIsHonoured)
{
    SimulationClock clock(480.0);
    RC_CHECK_NEAR(clock.RateHz(), 480.0, 1e-12);
    clock.SetMaxStepsPerFrame(64);
    RC_CHECK(RunFrame(clock, 1.0 / 60.0) == 8);

    clock.SetRateHz(-5.0);   // ignored
    RC_CHECK_NEAR(clock.RateHz(), 480.0, 1e-12);
}

RC_TEST(SimulationClock, ResetClearsEverything)
{
    SimulationClock clock;
    RunFrame(clock, 0.1);
    clock.Reset();
    RC_CHECK(clock.TotalStepCount() == 0);
    RC_CHECK_NEAR(clock.SimulatedTimeSeconds(), 0.0, 1e-15);
    RC_CHECK_NEAR(clock.InterpolationAlpha(), 0.0, 1e-15);
}
