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

        /** True when nothing on the device is anywhere but dead centre. */
        bool IsSilent(const RawAxisState& resting)
        {
            if (resting.AxisCount == 0) { return true; }
            for (size_t i = 0; i < resting.AxisCount; ++i)
            {
                if (std::fabs(resting.GetAxis(static_cast<int>(i))) > Real(1e-6))
                {
                    return false;
                }
            }
            return true;
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

        // A transmitter that enumerates but sends nothing.
        //
        // Every axis sitting at exactly zero is not a position a radio can
        // physically be in: a throttle rests at one end of its travel, and even
        // a centred gimbal lands a count or two off. It means the device is on
        // the bus but the radio is not driving it - switched off and merely
        // charging, out of USB Joystick mode, or on a model with no mixes.
        //
        // Worth its own message: read as a binding problem it sends the pilot
        // to the calibration wizard, which cannot succeed against a radio that
        // is not sending anything.
        if (IsSilent(resting))
        {
            return "the transmitter is connected but every channel reads zero, "
                   "so it is not sending anything. Check that the radio is "
                   "switched on rather than just charging, that its USB mode is "
                   "Joystick, and that a model with normal mixes is selected - "
                   "its channel monitor should show the bars moving.";
        }

        const ChannelBinding& throttle = mapper.Binding(RCChannel::Throttle);
        if (throttle.IsBound())
        {
            const Real offset = OffsetFromMiddle(throttle, resting.GetAxis(throttle.AxisIndex));
            if (std::fabs(offset) < kRestingCentreThreshold)
            {
                return std::string("axis ") + std::to_string(throttle.AxisIndex) +
                       " is bound to the throttle but is resting at " +
                       std::to_string(resting.GetAxis(throttle.AxisIndex)) +
                       ", the centre of its travel, which is what a self-centring "
                       "stick does. A throttle rests at one end. The binding is "
                       "probably wrong - press F3 to recalibrate.";
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
                       " is bound to the " + NameOf(channel) + " but is resting at " +
                       std::to_string(resting.GetAxis(binding.AxisIndex)) +
                       ", one end of its travel, which is what a throttle or a "
                       "switch does, not a self-centring stick. The binding is "
                       "probably wrong - press F3 to recalibrate.";
            }
        }

        return {};
    }
}
