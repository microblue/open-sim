#include "RCPhysics/Training/FailurePractice.h"

#include <cmath>

namespace rc
{
namespace
{
/** SplitMix64: small, fast, and identical on every compiler, which is what a
 *  repeatable flight needs. The standard library's engines are portable but
 *  its distributions are not. */
class SplitMix
{
public:
    explicit SplitMix(std::uint64_t seed) : State(seed) {}

    std::uint64_t Next()
    {
        std::uint64_t z = (State += 0x9E3779B97F4A7C15ull);
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }

    /** Uniform in [0, 1) from the top 53 bits. */
    Real Unit() { return static_cast<Real>(Next() >> 11) * (1.0 / 9007199254740992.0); }

private:
    std::uint64_t State;
};
} // namespace

const char* ToString(PracticeOutcome outcome)
{
    switch (outcome)
    {
    case PracticeOutcome::Pending:          return "pending";
    case PracticeOutcome::NoFailure:        return "no_failure";
    case PracticeOutcome::EndedBeforeOnset: return "ended_before_onset";
    case PracticeOutcome::Survived:         return "survived";
    case PracticeOutcome::Crashed:          return "crashed";
    }
    return "unknown";
}

void FailurePractice::Configure(const FailurePracticeSettings& settings)
{
    Config = settings;
    Config.Probability = Clamp(Config.Probability, 0.0, 1.0);
    Config.EarliestOnset = Max(Config.EarliestOnset, 0.0);
    Config.LatestOnset = Max(Config.LatestOnset, Config.EarliestOnset);
}

std::vector<PracticeFailure> FailurePractice::PoolFor(bool hasMotor, bool hasRudder,
                                                      bool includeRadio)
{
    std::vector<PracticeFailure> pool;
    if (hasMotor) { pool.push_back({FailureKind::DeadStick, RCChannel::Throttle}); }

    const RCChannel surfaces[3] = {RCChannel::Aileron, RCChannel::Elevator, RCChannel::Rudder};
    for (RCChannel channel : surfaces)
    {
        if (channel == RCChannel::Rudder && !hasRudder) { continue; }
        pool.push_back({FailureKind::StuckSurface, channel});
        pool.push_back({FailureKind::DeadSurface, channel});
    }
    if (includeRadio)
    {
        pool.push_back({FailureKind::RadioLoss, RCChannel::Aileron});
        pool.push_back({FailureKind::Brownout, RCChannel::Aileron});
    }
    return pool;
}

void FailurePractice::BeginFlight(std::uint32_t seed, bool hasMotor, bool hasRudder)
{
    Pool = PoolFor(hasMotor, hasRudder, Config.IncludeRadio);
    CurrentPlan = FailurePlan{};
    CurrentPlan.Seed = seed;
    Qualified = 0.0;
    HasTriggered = false;

    // Three draws in a fixed order - whether, when, what - so that changing
    // the pool (another aircraft) changes WHAT fails but not WHETHER or WHEN.
    SplitMix random(0xC0FFEEull ^ (static_cast<std::uint64_t>(seed) << 17) ^ seed);
    const Real whether = random.Unit();
    const Real when = random.Unit();
    const std::uint64_t what = random.Next();

    // Strictly less than: probability 0 never fails, 1 always does.
    CurrentPlan.WillFail = !Pool.empty() && whether < Config.Probability;
    if (!CurrentPlan.WillFail) { return; }

    CurrentPlan.OnsetAirborneTime =
        Config.EarliestOnset + when * (Config.LatestOnset - Config.EarliestOnset);
    CurrentPlan.Failure = Pool[static_cast<std::size_t>(what % Pool.size())];
}

bool FailurePractice::Update(Real dt, bool wheelsUnloaded, Real heightAboveGround)
{
    if (!(dt > 0.0)) { return false; }

    // The airborne clock runs on every flight, failing or not, so that a
    // flight that never left the ground can be told apart from one that flew
    // and came back clean.
    if (wheelsUnloaded && heightAboveGround >= Config.QualifyingHeight)
    {
        Qualified += dt;
    }
    if (!CurrentPlan.WillFail || HasTriggered) { return false; }
    if (Qualified >= CurrentPlan.OnsetAirborneTime)
    {
        HasTriggered = true;
        return true;
    }
    return false;
}

PracticeOutcome FailurePractice::Outcome(bool crashed, bool atRest, bool flightOver) const
{
    if (!CurrentPlan.WillFail)
    {
        return flightOver || crashed ? PracticeOutcome::NoFailure : PracticeOutcome::Pending;
    }
    if (!HasTriggered)
    {
        // A crash before the failure arrived is still a flight the failure
        // never reached; the crash report says what that crash was.
        return flightOver || crashed ? PracticeOutcome::EndedBeforeOnset
                                     : PracticeOutcome::Pending;
    }
    if (crashed) { return PracticeOutcome::Crashed; }
    if (atRest) { return PracticeOutcome::Survived; }
    // Reset while still in the air after the failure: not survived, not
    // crashed. Counted with the crashes - the model was not brought home.
    return flightOver ? PracticeOutcome::Crashed : PracticeOutcome::Pending;
}

} // namespace rc
