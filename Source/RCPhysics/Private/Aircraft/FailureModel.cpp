#include "RCPhysics/Aircraft/FailureModel.h"

#include <algorithm>
#include <cmath>

namespace rc
{
    namespace
    {
        inline std::uint32_t Mix(std::uint32_t h)
        {
            h ^= h >> 16; h *= 0x7feb352du;
            h ^= h >> 15; h *= 0x846ca68bu;
            h ^= h >> 16;
            return h;
        }

        inline Real Unit(std::uint32_t seed, std::uint32_t counter)
        {
            return static_cast<Real>(Mix(seed + counter * 0x9e3779b9u) >> 8)
                 / static_cast<Real>(0x01000000u);
        }
    }

    const char* ToString(FailureKind kind)
    {
        switch (kind)
        {
            case FailureKind::DeadStick:    return "dead stick";
            case FailureKind::StuckSurface: return "jammed servo";
            case FailureKind::DeadSurface:  return "linkage failure";
            case FailureKind::RadioLoss:    return "radio loss";
            case FailureKind::Brownout:     return "receiver brownout";
            default:                        return "none";
        }
    }

    void FailureModel::Induce(FailureKind kind, RCChannel channel)
    {
        Current = FailureState{};
        Current.Kind = kind;
        Current.Channel = channel;
        Current.Elapsed = 0.0;

        switch (kind)
        {
            case FailureKind::RadioLoss: Current.Duration = Config.RadioLossSeconds; break;
            case FailureKind::Brownout:  Current.Duration = Config.BrownoutSeconds;  break;
            default:                     Current.Duration = 0.0;   // until reset
        }
    }

    void FailureModel::ClearAll() { Current = FailureState{}; }

    void FailureModel::Update(Real dt, const ChannelValues& commanded)
    {
        if (!Current.Active())
        {
            // Keep the last good command, always.
            //
            // A servo jams where it WAS - at the instant before the failure,
            // not at the first frame after it. Capturing on the first update
            // after Induce() looked equivalent and was not: a pilot who
            // centres the stick the moment they notice would have the jam
            // freeze the CENTRED value, which is the one position that makes a
            // jam harmless. The failure has to hold what they were holding.
            Held = commanded;
        }

        if (Current.Active())
        {
            Current.Elapsed += dt;
            if (!Current.Permanent() && Current.Elapsed >= Current.Duration)
            {
                ClearAll();
            }
            return;
        }

        if (Config.RatePerMinute <= Real(0)) { return; }

        // Poisson: the chance in this step, not a countdown. A failure that
        // arrives on a timer is one a pilot learns the rhythm of.
        const Real chance = Config.RatePerMinute / Real(60) * dt;
        if (Unit(Config.Seed, ++Rolls) >= chance) { return; }

        // Weighted towards what actually happens. Dead sticks are far and away
        // the commonest failure on an electric model.
        const Real which = Unit(Config.Seed, ++Rolls);
        const Real channelRoll = Unit(Config.Seed, ++Rolls);
        const RCChannel channel = (channelRoll < Real(0.45)) ? RCChannel::Aileron
                                : (channelRoll < Real(0.80)) ? RCChannel::Elevator
                                                             : RCChannel::Rudder;

        if      (which < Real(0.46)) { Induce(FailureKind::DeadStick); }
        else if (which < Real(0.66)) { Induce(FailureKind::StuckSurface, channel); }
        else if (which < Real(0.80)) { Induce(FailureKind::DeadSurface, channel); }
        else if (which < Real(0.92)) { Induce(FailureKind::RadioLoss); }
        else                         { Induce(FailureKind::Brownout); }

        Held = commanded;
    }

    ChannelValues FailureModel::Apply(const ChannelValues& commanded) const
    {
        if (!Current.Active()) { return commanded; }

        ChannelValues out = commanded;

        switch (Current.Kind)
        {
            case FailureKind::StuckSurface:
                // Held where it was, including the throttle if that is what
                // jammed.
                out.Set(Current.Channel, Held.Get(Current.Channel));
                break;

            case FailureKind::DeadSurface:
                // A linkage off: the surface finds neutral and stays there.
                out.Set(Current.Channel, Real(0));
                break;

            case FailureKind::RadioLoss:
            case FailureKind::Brownout:
                if (Config.Failsafe == FailsafeMode::HoldLast)
                {
                    out = Held;
                }
                else
                {
                    out = ChannelValues::Neutral();
                }
                // A brownout takes the receiver down entirely, so the motor
                // stops whatever the failsafe says about the sticks.
                if (Current.Kind == FailureKind::Brownout)
                {
                    out.Set(RCChannel::Throttle, Real(0));
                }
                break;

            case FailureKind::DeadStick:
                // The sticks still work. The motor does not - see
                // ThrottleAuthority.
                break;

            default:
                break;
        }

        return out;
    }

    Real FailureModel::ThrottleAuthority() const
    {
        if (!Current.Active()) { return Real(1); }
        switch (Current.Kind)
        {
            case FailureKind::DeadStick:
            case FailureKind::Brownout:
                return Real(0);
            default:
                return Real(1);
        }
    }

    std::string FailureModel::Describe() const
    {
        if (!Current.Active()) { return {}; }

        switch (Current.Kind)
        {
            case FailureKind::DeadStick:
                return "DEAD STICK - the motor has stopped. Fly it as a glider.";
            case FailureKind::StuckSurface:
                return std::string("JAMMED SERVO - the ") + ToString(Current.Channel)
                     + " is stuck where it was.";
            case FailureKind::DeadSurface:
                return std::string("LINKAGE FAILURE - the ") + ToString(Current.Channel)
                     + " has gone neutral and will not answer.";
            case FailureKind::RadioLoss:
                return "RADIO LOSS - nothing is getting through.";
            case FailureKind::Brownout:
                return "BROWNOUT - the receiver has reset.";
            default:
                return {};
        }
    }
}
