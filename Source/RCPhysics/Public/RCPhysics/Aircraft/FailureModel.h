// OpenRC Simulator - things going wrong.
//
// This is the part of a simulator that a toy does not have, and it is where
// most of the training value is. Nobody needs practice at flying a model that
// works. What kills models is the motor stopping on the far side of the
// circuit, a servo jamming halfway through a turn, or the radio going quiet for
// two seconds at fifty feet - and every one of those is survivable if you have
// met it before and unrecoverable if you have not.
//
// Every failure here is one that actually happens to electric models:
//
//   Dead stick      The motor stops. Battery gone, ESC cut out, connector
//                   shaken loose. The aeroplane is now a glider, and the only
//                   question is whether it can reach the strip.
//   Stuck surface   A servo jams where it is. Not centred - WHERE IT IS, which
//                   is what makes it frightening: it happens mid-turn and the
//                   turn continues.
//   Dead surface    A linkage comes off. The surface goes to neutral and stays
//                   there, and the aeroplane has to be flown on what is left.
//   Radio loss      Nothing gets through. A real receiver holds its last
//                   commands or goes to failsafe; this does both, because both
//                   are configurations people fly.
//   Brownout        The receiver resets. Everything goes dead for a moment and
//                   then comes back, which is worse than a clean failure
//                   because it happens at the moment of highest current draw -
//                   usually the go-around.
//
// Failures are applied to the CHANNELS, between the transmitter and the flight
// model, and to the propulsion. Nothing downstream knows a failure has
// happened, which is the point: the aerodynamics does not need a special case
// for a jammed aileron, it just gets an aileron that does not move.

#ifndef RCPHYSICS_AIRCRAFT_FAILUREMODEL_H
#define RCPHYSICS_AIRCRAFT_FAILUREMODEL_H

#include "RCPhysics/Core/Types.h"
#include "RCPhysics/Input/ChannelTypes.h"

#include <array>
#include <cstdint>
#include <string>

namespace rc
{
    enum class FailureKind
    {
        None,
        DeadStick,      ///< the motor stops
        StuckSurface,   ///< a servo jams where it is
        DeadSurface,    ///< a linkage comes off; the surface goes neutral
        RadioLoss,      ///< nothing gets through
        Brownout,       ///< the receiver resets, then recovers
        Count
    };

    const char* ToString(FailureKind kind);

    /** What a receiver does when the link goes. Both are configurations people
     *  actually fly, and they fail very differently. */
    enum class FailsafeMode
    {
        HoldLast,       ///< keep the last commands received
        Neutral,        ///< sticks centred, motor closed
    };

    struct FailureSettings
    {
        /** Probability per minute of a random failure, when armed. Zero means
         *  failures only happen when asked for, which is how a lesson uses
         *  them. */
        Real RatePerMinute = 0.0;

        FailsafeMode Failsafe = FailsafeMode::Neutral;

        /** How long a radio loss or brownout lasts [s]. */
        Real RadioLossSeconds = 2.5;
        Real BrownoutSeconds = 0.8;

        std::uint32_t Seed = 0x1FA11u;
    };

    /** What is currently wrong, if anything. */
    struct FailureState
    {
        FailureKind Kind = FailureKind::None;
        RCChannel   Channel = RCChannel::Aileron;   ///< for the surface failures
        Real        Elapsed = 0.0;                  ///< seconds since it began
        Real        Duration = 0.0;                 ///< 0 means it does not end

        bool Active() const { return Kind != FailureKind::None; }
        bool Permanent() const { return Duration <= Real(0); }
    };

    class FailureModel
    {
    public:
        void Configure(const FailureSettings& settings) { Config = settings; }
        const FailureSettings& Settings() const { return Config; }

        /** Break something, now. `channel` is used by the surface failures and
         *  ignored otherwise. */
        void Induce(FailureKind kind, RCChannel channel = RCChannel::Aileron);

        /** Everything works again. */
        void ClearAll();

        /** Advance the clock and roll for a random failure if one is armed. */
        void Update(Real dt, const ChannelValues& commanded);

        const FailureState& State() const { return Current; }

        /** Apply whatever is wrong to the pilot's commands. What comes out is
         *  what the servos actually do. */
        ChannelValues Apply(const ChannelValues& commanded) const;

        /** Multiplier on the throttle the propulsion sees, 0 with a dead
         *  stick. Separate from the channels because a dead stick is a failure
         *  of the power system, not of the pilot's command - a replay or a
         *  telemetry overlay should still show the throttle they were holding. */
        Real ThrottleAuthority() const;

        /** A sentence a pilot can read, or empty when nothing is wrong. */
        std::string Describe() const;

    private:
        FailureSettings Config;
        FailureState    Current;
        ChannelValues   Held;          ///< commands frozen at the moment of failure
        std::uint32_t   Rolls = 0;
    };
}

#endif
