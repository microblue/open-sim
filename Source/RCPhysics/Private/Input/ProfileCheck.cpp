#include "RCPhysics/Input/ProfileCheck.h"

#include <cmath>

namespace rc
{
    namespace
    {
        /** Position on the axis relative to the middle of its calibrated
         *  travel, -1..1. Uses the calibration rather than the raw value so an
         *  axis whose ends are not symmetric still reads correctly. */
        Real OffsetFromMiddle(const ChannelBinding& binding, Real raw)
        {
            const Real low    = binding.Calibration.RawMin;
            const Real high   = binding.Calibration.RawMax;
            const Real middle = (low + high) * Real(0.5);
            const Real half   = (high - low) * Real(0.5);
            if (std::fabs(half) < Real(1e-6)) { return Real(0); }
            return (raw - middle) / half;
        }

        const char* NameOf(RCChannel channel)
        {
            switch (channel)
            {
                case RCChannel::Aileron:  return "aileron";
                case RCChannel::Elevator: return "elevator";
                case RCChannel::Throttle: return "throttle";
                case RCChannel::Rudder:   return "rudder";
                case RCChannel::Flap:     return "flap";
                default:                  return "aux1";
            }
        }
    }

    std::string DescribeProfileMismatch(const ChannelMapper& mapper,
                                        const RawAxisState& resting)
    {
        if (!resting.Connected) { return {}; }

        const ChannelBinding& throttle = mapper.Binding(RCChannel::Throttle);
        if (throttle.IsBound())
        {
            const Real offset = OffsetFromMiddle(throttle, resting.GetAxis(throttle.AxisIndex));
            if (std::fabs(offset) < kRestingCentreThreshold)
            {
                return std::string("axis ") + std::to_string(throttle.AxisIndex) +
                       " is bound to the throttle but is resting at the centre of "
                       "its travel, which is what a self-centring stick does. A "
                       "throttle rests at one end. The binding is probably wrong "
                       "- press F3 to recalibrate.";
            }
        }

        // The self-centring channels. Flap and aux1 are usually switches, which
        // legitimately rest at an end, so they are not checked.
        for (const RCChannel channel : {RCChannel::Aileron, RCChannel::Elevator,
                                        RCChannel::Rudder})
        {
            const ChannelBinding& binding = mapper.Binding(channel);
            if (!binding.IsBound()) { continue; }

            const Real offset = OffsetFromMiddle(binding, resting.GetAxis(binding.AxisIndex));
            if (std::fabs(offset) > kRestingExtremeThreshold)
            {
                return std::string("axis ") + std::to_string(binding.AxisIndex) +
                       " is bound to the " + NameOf(channel) +
                       " but is resting at one end of its travel, which is what a "
                       "throttle or a switch does, not a self-centring stick. The "
                       "binding is probably wrong - press F3 to recalibrate.";
            }
        }

        return {};
    }
}
