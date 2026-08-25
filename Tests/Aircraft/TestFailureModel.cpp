// OpenRC Simulator - things going wrong.
//
// The value of a failure model is entirely in whether it fails the way the real
// thing does. A "dead stick" that also centres the sticks teaches nothing,
// because the hard part of a dead stick is that you still have full control and
// no power. A jammed servo that goes neutral is not a jammed servo - it is the
// OTHER failure, and the one that is far easier to survive.
//
// So these check the specifics, not that something changed.

#include "RCPhysics/Aircraft/FailureModel.h"
#include "TestHarness.h"

#include <cmath>
#include <string>

namespace
{
    rc::ChannelValues Turning()
    {
        rc::ChannelValues c;
        c.Set(rc::RCChannel::Aileron, 0.6);
        c.Set(rc::RCChannel::Elevator, -0.25);
        c.Set(rc::RCChannel::Rudder, 0.15);
        c.Set(rc::RCChannel::Throttle, 0.7);
        return c;
    }
}

RC_TEST(FailureModel, NothingIsWrongToBeginWith)
{
    rc::FailureModel model;
    RC_CHECK(!model.State().Active());
    RC_CHECK(model.Describe().empty());
    RC_CHECK_NEAR(model.ThrottleAuthority(), 1.0, 0.0);

    const rc::ChannelValues out = model.Apply(Turning());
    RC_CHECK_NEAR(out.Aileron(), 0.6, 0.0);
    RC_CHECK_NEAR(out.Throttle(), 0.7, 0.0);
}

RC_TEST(FailureModel, ADeadStickLeavesTheControlsWorking)
{
    // This is the whole point of a dead stick. The motor is gone; the aeroplane
    // is a glider and you have every control you had a moment ago. A model that
    // also froze the sticks would teach the wrong lesson.
    rc::FailureModel model;
    model.Induce(rc::FailureKind::DeadStick);
    model.Update(1.0 / 240.0, Turning());

    const rc::ChannelValues out = model.Apply(Turning());
    RC_CHECK_NEAR(out.Aileron(), 0.6, 0.0);
    RC_CHECK_NEAR(out.Elevator(), -0.25, 0.0);
    RC_CHECK_NEAR(out.Rudder(), 0.15, 0.0);

    RC_CHECK_NEAR(model.ThrottleAuthority(), 0.0, 0.0);
    RC_CHECK(model.Describe().find("DEAD STICK") != std::string::npos);
}

RC_TEST(FailureModel, AJammedServoHoldsWhereItWasNotWhereItIsSafe)
{
    // The frightening part: it jams mid-turn and the turn continues. A jam that
    // went to neutral would be a different, much kinder failure.
    rc::FailureModel model;
    const rc::ChannelValues mid = Turning();

    // Flying, mid-turn. The model has to have SEEN the command to hold it: a
    // servo jams where it was, and where it was is the instant before the
    // failure, not the first frame after it.
    for (int i = 0; i < 24; ++i) { model.Update(1.0 / 240.0, mid); }

    model.Induce(rc::FailureKind::StuckSurface, rc::RCChannel::Aileron);

    rc::ChannelValues corrected = mid;
    corrected.Set(rc::RCChannel::Aileron, 0.0);
    const rc::ChannelValues out = model.Apply(corrected);

    RC_CHECK_MSG_VALUE(std::fabs(out.Aileron() - 0.6) < 1e-9, out.Aileron());
    RC_CHECK_NEAR(out.Elevator(), mid.Elevator(), 0.0);
    RC_CHECK_NEAR(out.Throttle(), mid.Throttle(), 0.0);
    RC_CHECK_NEAR(model.ThrottleAuthority(), 1.0, 0.0);
}

RC_TEST(FailureModel, ALinkageFailureGoesNeutralAndStaysThere)
{
    rc::FailureModel model;
    model.Induce(rc::FailureKind::DeadSurface, rc::RCChannel::Elevator);
    model.Update(1.0 / 240.0, Turning());

    for (rc::Real command = -1.0; command <= 1.0; command += 0.25)
    {
        rc::ChannelValues asked = Turning();
        asked.Set(rc::RCChannel::Elevator, command);
        RC_CHECK_NEAR(model.Apply(asked).Elevator(), 0.0, 0.0);
    }
    RC_CHECK_NEAR(model.Apply(Turning()).Aileron(), 0.6, 0.0);
}

RC_TEST(FailureModel, RadioLossHonoursTheFailsafeSetting)
{
    // Both are configurations people actually fly, and they fail very
    // differently: holding the last command means an aeroplane that was turning
    // keeps turning, all the way into the ground.
    const rc::ChannelValues mid = Turning();

    rc::FailureSettings hold;
    hold.Failsafe = rc::FailsafeMode::HoldLast;
    rc::FailureModel holding;
    holding.Configure(hold);
    for (int i = 0; i < 24; ++i) { holding.Update(1.0 / 240.0, mid); }
    holding.Induce(rc::FailureKind::RadioLoss);

    rc::ChannelValues moved = mid;
    moved.Set(rc::RCChannel::Aileron, -1.0);
    RC_CHECK_NEAR(holding.Apply(moved).Aileron(), 0.6, 0.0);
    RC_CHECK_NEAR(holding.Apply(moved).Throttle(), 0.7, 0.0);

    rc::FailureSettings neutral;
    neutral.Failsafe = rc::FailsafeMode::Neutral;
    rc::FailureModel centring;
    centring.Configure(neutral);
    for (int i = 0; i < 24; ++i) { centring.Update(1.0 / 240.0, mid); }
    centring.Induce(rc::FailureKind::RadioLoss);

    RC_CHECK_NEAR(centring.Apply(moved).Aileron(), 0.0, 0.0);
    RC_CHECK_NEAR(centring.Apply(moved).Throttle(), 0.0, 0.0);
}

RC_TEST(FailureModel, ABrownoutCutsTheMotorWhateverTheFailsafeSays)
{
    // The receiver is down. It cannot hold anything, and the motor stops - the
    // failure that arrives at the moment of highest current draw, which is
    // usually the go-around.
    rc::FailureSettings hold;
    hold.Failsafe = rc::FailsafeMode::HoldLast;
    rc::FailureModel model;
    model.Configure(hold);
    for (int i = 0; i < 24; ++i) { model.Update(1.0 / 240.0, Turning()); }
    model.Induce(rc::FailureKind::Brownout);

    RC_CHECK_NEAR(model.Apply(Turning()).Throttle(), 0.0, 0.0);
    RC_CHECK_NEAR(model.ThrottleAuthority(), 0.0, 0.0);
}

RC_TEST(FailureModel, TemporaryFailuresEndAndPermanentOnesDoNot)
{
    rc::FailureSettings config;
    config.RadioLossSeconds = 2.0;
    rc::FailureModel model;
    model.Configure(config);

    model.Induce(rc::FailureKind::RadioLoss);
    for (int i = 0; i < 240; ++i) { model.Update(1.0 / 240.0, Turning()); }
    RC_CHECK(model.State().Active());

    for (int i = 0; i < 240 * 2; ++i) { model.Update(1.0 / 240.0, Turning()); }
    RC_CHECK(!model.State().Active());

    // A dead stick does not come back. The battery is not going to reconnect
    // itself, and a pilot who expects it to will not commit to the landing.
    model.Induce(rc::FailureKind::DeadStick);
    for (int i = 0; i < 240 * 60; ++i) { model.Update(1.0 / 240.0, Turning()); }
    RC_CHECK(model.State().Active());
    RC_CHECK(model.State().Kind == rc::FailureKind::DeadStick);
}

RC_TEST(FailureModel, RandomFailuresArriveAtRoughlyTheRateAsked)
{
    // Poisson, not a countdown: a failure that arrives on a timer is one a
    // pilot learns the rhythm of and stops being surprised by.
    rc::FailureSettings config;
    config.RatePerMinute = 6.0;
    config.Seed = 12345u;

    int failures = 0;
    rc::Real minutes = 0.0;
    rc::FailureModel model;
    model.Configure(config);

    for (int i = 0; i < 240 * 600; ++i)
    {
        const bool was = model.State().Active();
        model.Update(1.0 / 240.0, Turning());
        if (!was && model.State().Active())
        {
            ++failures;
            model.ClearAll();
        }
        minutes += 1.0 / 240.0 / 60.0;
    }

    const double rate = failures / minutes;
    std::printf("       %d failures in %.1f minutes = %.2f per minute\n",
                failures, minutes, rate);
    RC_CHECK_MSG_VALUE(rate > 3.0 && rate < 10.0, rate);
}

RC_TEST(FailureModel, NoRandomFailuresWhenTheRateIsZero)
{
    // A lesson decides when things break. An unasked-for failure in the middle
    // of a circuit exercise is not training, it is noise.
    rc::FailureModel model;
    for (int i = 0; i < 240 * 600; ++i)
    {
        model.Update(1.0 / 240.0, Turning());
        if (model.State().Active()) { RC_FAIL("a failure arrived unasked"); return; }
    }
    RC_CHECK(!model.State().Active());
}

RC_TEST(FailureModel, EveryFailureCanBeDescribed)
{
    // The pilot has to be told what went wrong, or they are debugging the
    // simulator rather than flying the aeroplane.
    rc::FailureModel model;
    for (int i = 1; i < static_cast<int>(rc::FailureKind::Count); ++i)
    {
        model.Induce(static_cast<rc::FailureKind>(i), rc::RCChannel::Rudder);
        model.Update(1.0 / 240.0, Turning());
        RC_CHECK(!model.Describe().empty());
        RC_CHECK(std::string(rc::ToString(static_cast<rc::FailureKind>(i))) != "none");
    }
}
