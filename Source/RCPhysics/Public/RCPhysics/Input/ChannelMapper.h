// OpenRC Simulator - raw HID axes to flight-model channel values.
//
// One binding per channel: which physical axis it reads, how that axis is
// calibrated, and how it is shaped. The whole pipeline for a frame is a single
// Update() call, and it is a pure function of the raw state plus the bindings -
// so it can be tested exhaustively without a device attached.
#pragma once

#include "RCPhysics/Input/Calibration.h"
#include "RCPhysics/Input/ChannelTypes.h"
#include "RCPhysics/Input/ExpoRates.h"

#include <array>
#include <string>

namespace rc
{
struct ChannelBinding
{
    /** Index into RawAxisState. -1 means unbound; the channel reads neutral. */
    int AxisIndex = -1;

    AxisCalibration Calibration;
    ChannelShaping  Shaping;

    bool IsBound() const { return AxisIndex >= 0; }
};

class ChannelMapper
{
public:
    ChannelMapper();

    ChannelBinding&       Binding(RCChannel channel);
    const ChannelBinding& Binding(RCChannel channel) const;

    /** Bind a channel to a physical axis with a captured calibration. */
    void Bind(RCChannel channel, int axisIndex, const AxisCalibration& calibration);

    void Unbind(RCChannel channel);
    bool IsFullyBound() const;

    /** Turn a device snapshot into channel values. When the device is
     *  disconnected this returns neutral with the throttle closed, rather than
     *  holding the last value - a stuck throttle after an unplug is dangerous
     *  even in a simulator, because it teaches the wrong reflex. */
    ChannelValues Update(const RawAxisState& raw) const;

    /** Apply Raw Mode to every channel at once. */
    void SetRawMode(bool rawMode);
    bool IsRawMode() const;

    /** Serialise to / from the aircraft-independent controller profile. */
    std::string ToJson() const;
    bool FromJson(const std::string& text, std::string* outError = nullptr);

private:
    std::array<ChannelBinding, kChannelCount> Bindings;
};

} // namespace rc
