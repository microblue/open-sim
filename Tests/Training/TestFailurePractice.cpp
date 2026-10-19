// Failure practice: one honest draw per flight, never on the ground,
// repeatable from its seed.
#include "TestHarness.h"

#include "RCPhysics/Training/FailurePractice.h"

#include <set>

using namespace rc;

namespace
{
FailurePractice Practice(Real probability, bool radio = false)
{
    FailurePractice practice;
    FailurePracticeSettings settings;
    settings.Probability = probability;
    settings.IncludeRadio = radio;
    practice.Configure(settings);
    return practice;
}
} // namespace

RC_TEST(FailurePractice, ZeroNeverFailsAndOneAlwaysDoes)
{
    FailurePractice never = Practice(0.0);
    FailurePractice always = Practice(1.0);
    int neverCount = 0, alwaysCount = 0;
    for (std::uint32_t seed = 1; seed <= 500; ++seed)
    {
        never.BeginFlight(seed);
        always.BeginFlight(seed);
        neverCount += never.Plan().WillFail ? 1 : 0;
        alwaysCount += always.Plan().WillFail ? 1 : 0;
    }
    RC_CHECK(neverCount == 0);
    RC_CHECK(alwaysCount == 500);
}

RC_TEST(FailurePractice, ThirtyPercentMeansThreeFlightsInTen)
{
    FailurePractice practice = Practice(0.3);
    int failing = 0;
    const int flights = 4000;
    for (int seed = 0; seed < flights; ++seed)
    {
        practice.BeginFlight(static_cast<std::uint32_t>(seed));
        failing += practice.Plan().WillFail ? 1 : 0;
    }
    const Real share = static_cast<Real>(failing) / flights;
    // Four thousand flights: one standard deviation is 0.7 %.
    RC_CHECK(share > 0.28 && share < 0.32);
}

RC_TEST(FailurePractice, OnsetFallsInsideTheWindowAndEveryKindTurnsUp)
{
    FailurePractice practice = Practice(1.0, true);
    std::set<int> kinds;
    std::set<int> channels;
    bool inside = true;
    for (std::uint32_t seed = 0; seed < 2000; ++seed)
    {
        practice.BeginFlight(seed);
        const FailurePlan& plan = practice.Plan();
        if (plan.OnsetAirborneTime < 20.0 || plan.OnsetAirborneTime > 120.0) { inside = false; }
        kinds.insert(static_cast<int>(plan.Failure.Kind));
        if (plan.Failure.Kind == FailureKind::StuckSurface)
        {
            channels.insert(static_cast<int>(plan.Failure.Channel));
        }
    }
    RC_CHECK(inside);
    RC_CHECK(kinds.size() == 5);      // dead stick, stuck, dead, radio, brownout
    RC_CHECK(channels.size() == 3);   // aileron, elevator, rudder
}

RC_TEST(FailurePractice, TheSameSeedIsTheSameFlight)
{
    FailurePractice a = Practice(0.5);
    FailurePractice b = Practice(0.5);
    for (std::uint32_t seed = 0; seed < 200; ++seed)
    {
        a.BeginFlight(seed);
        b.BeginFlight(seed);
        RC_CHECK(a.Plan().WillFail == b.Plan().WillFail);
        RC_CHECK(a.Plan().OnsetAirborneTime == b.Plan().OnsetAirborneTime);
        RC_CHECK(a.Plan().Failure.Kind == b.Plan().Failure.Kind);
    }
}

RC_TEST(FailurePractice, AGliderNeverLosesAMotorItDoesNotHave)
{
    const std::vector<PracticeFailure> glider = FailurePractice::PoolFor(false, true, false);
    const std::vector<PracticeFailure> powered = FailurePractice::PoolFor(true, true, false);
    const std::vector<PracticeFailure> noRudder = FailurePractice::PoolFor(true, false, false);
    bool gliderHasDeadStick = false;
    for (const PracticeFailure& f : glider)
    {
        if (f.Kind == FailureKind::DeadStick) { gliderHasDeadStick = true; }
    }
    RC_CHECK(!gliderHasDeadStick);
    RC_CHECK(powered.size() == glider.size() + 1);
    RC_CHECK(noRudder.size() == powered.size() - 2);
    // Radio failures only when asked for.
    for (const PracticeFailure& f : powered)
    {
        RC_CHECK(f.Kind != FailureKind::RadioLoss && f.Kind != FailureKind::Brownout);
    }
}

RC_TEST(FailurePractice, TheClockOnlyRunsWhenProperlyAirborne)
{
    FailurePractice practice = Practice(1.0);
    practice.BeginFlight(7);
    const Real onset = practice.Plan().OnsetAirborneTime;
    const Real dt = 1.0 / 240.0;

    // Ten minutes taxiing, and ten minutes low over the grass: nothing.
    bool early = false;
    for (int i = 0; i < 240 * 600; ++i)
    {
        early = practice.Update(dt, false, 0.2) || early;
        early = practice.Update(dt, true, 3.0) || early;
    }
    RC_CHECK(!early);
    RC_CHECK_NEAR(practice.QualifiedAirborneTime(), 0.0, 0.0);

    // Proper flight: it arrives on time, once.
    int triggers = 0;
    Real at = -1.0;
    for (int i = 0; i < 240 * 200; ++i)
    {
        if (practice.Update(dt, true, 30.0))
        {
            ++triggers;
            at = practice.QualifiedAirborneTime();
        }
    }
    RC_CHECK(triggers == 1);
    RC_CHECK(std::abs(at - onset) <= dt);
    RC_CHECK(practice.Triggered());
}

RC_TEST(FailurePractice, OutcomesAreCountedHonestly)
{
    FailurePractice clean = Practice(0.0);
    clean.BeginFlight(1);
    RC_CHECK(clean.Outcome(false, false, false) == PracticeOutcome::Pending);
    RC_CHECK(clean.Outcome(false, true, true) == PracticeOutcome::NoFailure);

    FailurePractice practice = Practice(1.0);
    practice.BeginFlight(1);
    // Landed and reset before it came: not a survival.
    RC_CHECK(practice.Outcome(false, true, true) == PracticeOutcome::EndedBeforeOnset);
    RC_CHECK(practice.Outcome(true, false, false) == PracticeOutcome::EndedBeforeOnset);

    while (!practice.Update(0.1, true, 50.0)) {}
    RC_CHECK(practice.Outcome(false, false, false) == PracticeOutcome::Pending);
    RC_CHECK(practice.Outcome(false, true, false) == PracticeOutcome::Survived);
    RC_CHECK(practice.Outcome(true, false, false) == PracticeOutcome::Crashed);
    // Reset in the air after the failure: the model was not brought home.
    RC_CHECK(practice.Outcome(false, false, true) == PracticeOutcome::Crashed);
}
