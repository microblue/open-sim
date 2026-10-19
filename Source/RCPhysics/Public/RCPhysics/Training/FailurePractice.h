// OpenRC Simulator - emergency practice, one flight at a time.
//
// The failure model can break anything at any moment. What turns that into
// practice is deciding WHEN, and keeping score honestly. The rules:
//
//   One draw per flight. "30 %" means three flights in ten get a failure - not
//   a 30 % chance every minute, which over a long flight makes a failure
//   certain and teaches the pilot to expect one.
//
//   Never on the ground. The clock that decides when it happens only runs
//   while the aircraft is properly airborne - well clear of the ground, wheels
//   unloaded - so a failure always arrives as an emergency to be flown, never
//   as a model that will not take off. It starts somewhere between twenty
//   seconds and two minutes of that time, which is long enough to forget about
//   it.
//
//   At most one, and it stays. A flight is about one problem.
//
//   Honest outcomes. A flight that ends before its failure arrived is counted
//   as exactly that, not as a clean flight: a pilot who lands at once every
//   time has not survived anything.
//
//   Repeatable. The draw comes from a seed, so the same flight - the same
//   failure at the same moment - can be flown again until it is flown well.
#pragma once

#include "RCPhysics/Aircraft/FailureModel.h"
#include "RCPhysics/Core/Types.h"
#include "RCPhysics/Input/ChannelTypes.h"

#include <cstdint>
#include <vector>

namespace rc
{
struct FailurePracticeSettings
{
    /** Chance that a flight has a failure at all, 0..1. Zero is off. */
    Real Probability = 0.0;
    /** Allow radio loss and brownout in the pool. Off by default: they are
     *  the failures a pilot can do least about, and the most discouraging. */
    bool IncludeRadio = false;
    /** Window of qualified airborne time the failure starts in [s]. */
    Real EarliestOnset = 20.0;
    Real LatestOnset = 120.0;
    /** Height above the ground the airborne clock needs [m]. */
    Real QualifyingHeight = 5.0;
};

/** One possible failure: what breaks and, for a surface, which one. */
struct PracticeFailure
{
    FailureKind Kind = FailureKind::None;
    RCChannel Channel = RCChannel::Aileron;
};

/** What a flight will do, decided when it begins. */
struct FailurePlan
{
    std::uint32_t Seed = 0;
    bool WillFail = false;
    Real OnsetAirborneTime = 0.0;   ///< s of qualified airborne time
    PracticeFailure Failure;
};

enum class PracticeOutcome
{
    Pending,            ///< the flight is still going
    NoFailure,          ///< this flight drew no failure
    EndedBeforeOnset,   ///< it was going to fail; the flight ended first
    Survived,           ///< failed, and the aircraft came to rest in one piece
    Crashed             ///< failed, and then crashed
};

const char* ToString(PracticeOutcome outcome);

class FailurePractice
{
public:
    void Configure(const FailurePracticeSettings& settings);
    const FailurePracticeSettings& Settings() const { return Config; }

    /** The failures this aircraft can have. A glider with no motor cannot
     *  have a dead stick, and an aircraft with no rudder cannot have it jam. */
    static std::vector<PracticeFailure> PoolFor(bool hasMotor, bool hasRudder,
                                                bool includeRadio);

    /** Start a flight. Draws the plan from `seed` alone, so the same seed and
     *  settings always give the same flight. */
    void BeginFlight(std::uint32_t seed, bool hasMotor = true, bool hasRudder = true);

    /** Advance by one step. `airborne` is whether the aircraft is clear of the
     *  ground with its wheels unloaded; the height test is applied here.
     *  Returns true on exactly the step the failure should begin. */
    bool Update(Real dt, bool wheelsUnloaded, Real heightAboveGround);

    const FailurePlan& Plan() const { return CurrentPlan; }
    /** Seconds of proper airborne time this flight - counted whether or not
     *  it has a failure coming. Zero means it never really flew. */
    Real QualifiedAirborneTime() const { return Qualified; }
    bool Triggered() const { return HasTriggered; }

    /** How this flight has gone so far. `atRest` means stopped on the ground:
     *  a failed aircraft that has stopped without crashing has survived. Pass
     *  `flightOver` when the pilot resets or leaves, which is what turns a
     *  failure that never came into EndedBeforeOnset. */
    PracticeOutcome Outcome(bool crashed, bool atRest, bool flightOver) const;

private:
    FailurePracticeSettings Config;
    FailurePlan CurrentPlan;
    std::vector<PracticeFailure> Pool;
    Real Qualified = 0.0;
    bool HasTriggered = false;
};

} // namespace rc
