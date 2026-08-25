// OpenRC Simulator - the flight recorder.
//
// A replay is only useful if it shows what actually happened. What this has to
// guarantee: that the window really is the last N seconds, that scrubbing to a
// time returns the state at that time rather than near it, that the attitude is
// interpolated as a rotation rather than as four numbers, and that a reset does
// not leave the aircraft teleporting through the middle of a replay.

#include "RCPhysics/Core/FlightRecorder.h"
#include "TestHarness.h"

#include <cmath>

namespace
{
    /** A frame on a known, smooth trajectory, so any interpolation error is
     *  visible as a departure from it. */
    rc::FlightFrame Synthetic(rc::Real time)
    {
        rc::FlightFrame frame;
        frame.Time = time;
        frame.PositionWorld = rc::Vec3(time * 12.0, std::sin(time) * 30.0, -100.0 - time);
        frame.Orientation = rc::Quat::FromAxisAngle(rc::Vec3(0.0, 0.0, 1.0), time * 0.4);
        frame.VelocityWorld = rc::Vec3(12.0, std::cos(time) * 30.0, -1.0);
        frame.Airspeed = 14.0 + std::sin(time);
        frame.Rpm = 6000.0 + time * 10.0;
        frame.Controls.Set(rc::RCChannel::Elevator, std::sin(time * 0.5));
        return frame;
    }

    void Fill(rc::FlightRecorder& recorder, rc::Real from, rc::Real to, rc::Real step)
    {
        for (rc::Real t = from; t <= to; t += step)
        {
            recorder.Offer(Synthetic(t));
        }
    }
}

RC_TEST(FlightRecorder, StartsEmpty)
{
    const rc::FlightRecorder recorder;
    RC_CHECK(recorder.Empty());
    RC_CHECK(recorder.Size() == 0);
    RC_CHECK_NEAR(recorder.Duration(), 0.0, 0.0);
}

RC_TEST(FlightRecorder, SamplesAtItsOwnRateNotTheCallersRate)
{
    // The caller offers a frame every physics step - 240 a second - and the
    // recorder keeps sixty. Storing all of them would cost four times the
    // memory for detail no eye can use.
    rc::FlightRecorder recorder(10.0, 60.0);
    Fill(recorder, 0.0, 5.0, 1.0 / 240.0);

    // Five seconds at sixty a second, give or take one at each end.
    RC_CHECK_MSG_VALUE(recorder.Size() >= 298 && recorder.Size() <= 303,
                       static_cast<double>(recorder.Size()));
}

RC_TEST(FlightRecorder, KeepsExactlyTheLastWindow)
{
    // A rolling window: by the time a pilot knows they want the last thirty
    // seconds, those seconds have happened. Older ones must fall off.
    rc::FlightRecorder recorder(8.0, 60.0);
    Fill(recorder, 0.0, 40.0, 1.0 / 240.0);

    RC_CHECK_MSG_VALUE(std::fabs(recorder.Duration() - 8.0) < 0.2, recorder.Duration());
    RC_CHECK_MSG_VALUE(recorder.LatestTime() > 39.9, recorder.LatestTime());
    RC_CHECK_MSG_VALUE(recorder.EarliestTime() > 31.5, recorder.EarliestTime());
}

RC_TEST(FlightRecorder, ScrubbingReturnsTheStateAtThatTime)
{
    rc::FlightRecorder recorder(20.0, 60.0);
    Fill(recorder, 0.0, 15.0, 1.0 / 240.0);

    // Sampled between stored frames, against the trajectory they came from.
    // The bound is what a sixtieth of a second of this motion covers.
    rc::Real worst = 0.0;
    for (rc::Real t = 1.0; t < 14.0; t += 0.137)
    {
        const rc::FlightFrame got = recorder.SampleAt(t);
        const rc::FlightFrame want = Synthetic(t);
        worst = std::max(worst, (got.PositionWorld - want.PositionWorld).Length());
        RC_CHECK_NEAR(got.Time, t, 0.02);
    }
    RC_CHECK_MSG_VALUE(worst < 0.05, worst);
}

RC_TEST(FlightRecorder, AttitudeIsInterpolatedAsARotation)
{
    // A linear blend of two quaternions is not a rotation. Renormalising one
    // gives an attitude that visibly shrinks towards the halfway point over a
    // fast roll - which is exactly when a replay is being watched closely.
    rc::FlightRecorder recorder(20.0, 30.0);   // deliberately coarse
    for (rc::Real t = 0.0; t <= 4.0; t += 1.0 / 30.0)
    {
        rc::FlightFrame frame;
        frame.Time = t;
        // A fast roll: half a turn a second.
        frame.Orientation = rc::Quat::FromAxisAngle(rc::Vec3(1.0, 0.0, 0.0), t * 3.14159);
        recorder.Offer(frame);
    }

    rc::Real worst = 0.0;
    for (rc::Real t = 0.5; t < 3.5; t += 0.011)
    {
        const rc::Quat got = recorder.SampleAt(t).Orientation;
        const rc::Quat want = rc::Quat::FromAxisAngle(rc::Vec3(1.0, 0.0, 0.0), t * 3.14159);

        // Unit length, and the same rotation to within the sampling interval.
        RC_CHECK_NEAR(std::sqrt(got.w * got.w + got.x * got.x
                                  + got.y * got.y + got.z * got.z), 1.0, 1e-9);
        const rc::Real dot = std::fabs(got.w * want.w + got.x * want.x
                                     + got.y * want.y + got.z * want.z);
        worst = std::max(worst, 1.0 - dot);
    }
    RC_CHECK_MSG_VALUE(worst < 0.002, worst);
}

RC_TEST(FlightRecorder, FlagsAreNotBlended)
{
    // A crash is a moment, not a gradient. Blending it would produce an
    // aircraft that is half crashed, which is not a state anything can draw.
    rc::FlightRecorder recorder(10.0, 60.0);
    for (int i = 0; i < 120; ++i)
    {
        rc::FlightFrame frame;
        frame.Time = i / 60.0;
        frame.Crashed = i >= 60;
        frame.OnGround = i >= 55;
        recorder.Offer(frame);
    }

    // The flag flips at frame sixty, one second in. Nearest-frame selection
    // moves the transition to the midpoint between frames fifty-nine and
    // sixty, so this checks the two things that actually matter: away from the
    // transition the answer is exact, and it is never anything but true or
    // false.
    const rc::Real transition = 1.0;
    const rc::Real interval = 1.0 / 60.0;
    for (rc::Real t = 0.0; t < 2.0; t += 0.007)
    {
        const rc::FlightFrame got = recorder.SampleAt(t);
        if (std::fabs(t - transition) < interval) { continue; }
        RC_CHECK(got.Crashed == (t > transition));
    }
}

RC_TEST(FlightRecorder, AResetClearsTheHistory)
{
    // A replay that runs across a reset shows the aircraft teleporting, which
    // teaches nothing. The clock going backwards is the signal.
    rc::FlightRecorder recorder(20.0, 60.0);
    Fill(recorder, 0.0, 10.0, 1.0 / 240.0);
    RC_CHECK(recorder.Size() > 100);

    // Reset: the simulation clock restarts.
    recorder.Offer(Synthetic(0.0));
    RC_CHECK_MSG_VALUE(recorder.Size() == 1, static_cast<double>(recorder.Size()));
    RC_CHECK_NEAR(recorder.EarliestTime(), 0.0, 1e-9);
}

RC_TEST(FlightRecorder, ScrubbingOutsideTheWindowIsClamped)
{
    rc::FlightRecorder recorder(6.0, 60.0);
    Fill(recorder, 10.0, 20.0, 1.0 / 240.0);

    const rc::FlightFrame before = recorder.SampleAt(-100.0);
    const rc::FlightFrame after = recorder.SampleAt(1e6);
    RC_CHECK_NEAR(before.Time, recorder.EarliestTime(), 1e-9);
    RC_CHECK_NEAR(after.Time, recorder.LatestTime(), 1e-9);
}

RC_TEST(FlightRecorder, TheWindowCanBeResized)
{
    rc::FlightRecorder recorder(10.0, 60.0);
    Fill(recorder, 0.0, 20.0, 1.0 / 240.0);
    RC_CHECK(recorder.Size() > 500);

    recorder.SetWindow(30.0);
    RC_CHECK(recorder.Empty());
    RC_CHECK_NEAR(recorder.Window(), 30.0, 1e-9);
}
