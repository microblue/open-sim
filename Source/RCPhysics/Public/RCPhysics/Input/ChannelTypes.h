// OpenRC Simulator - RC transmitter channel definitions.
//
// The simulator reads a real transmitter as a generic HID device and does its
// own channel processing. Nothing here knows about a specific vendor: a
// RadioMaster TX16S, a FlySky through a dongle and a plain gamepad all arrive
// as "some device with N axes", and the calibration wizard works out the rest.
#pragma once

#include "RCPhysics/Core/Types.h"

#include <array>
#include <cstddef>

namespace rc
{
enum class RCChannel
{
    Aileron = 0,
    Elevator,
    Throttle,
    Rudder,
    Flap,
    Aux1,
    Count
};

inline constexpr size_t kChannelCount = static_cast<size_t>(RCChannel::Count);

const char* ToString(RCChannel channel);

/** True for channels whose neutral is the centre of the stick. Throttle is the
 *  exception: its neutral is the bottom of its travel, so it is normalised to
 *  0..1 rather than -1..1. */
inline constexpr bool IsBipolar(RCChannel channel)
{
    return channel != RCChannel::Throttle;
}

/** Processed stick positions handed to the flight model.
 *  Bipolar channels are -1..1; throttle is 0..1. */
struct ChannelValues
{
    std::array<Real, kChannelCount> Values{};

    Real Get(RCChannel channel) const
    {
        return Values[static_cast<size_t>(channel)];
    }

    void Set(RCChannel channel, Real value)
    {
        Values[static_cast<size_t>(channel)] = value;
    }

    Real Aileron()  const { return Get(RCChannel::Aileron); }
    Real Elevator() const { return Get(RCChannel::Elevator); }
    Real Throttle() const { return Get(RCChannel::Throttle); }
    Real Rudder()   const { return Get(RCChannel::Rudder); }
    Real Flap()     const { return Get(RCChannel::Flap); }

    /** Everything centred, throttle closed - the state to fall back to when no
     *  device is connected, or when one is unplugged mid-flight. */
    static ChannelValues Neutral() { return ChannelValues{}; }
};

/** A snapshot of one HID device's axes, exactly as the platform reported them.
 *  No scaling, no deadzone, no sign correction - that is the whole point. */
struct RawAxisState
{
    static constexpr size_t kMaxAxes = 16;

    std::array<Real, kMaxAxes> Axes{};
    size_t AxisCount = 0;
    bool   Connected = false;

    Real GetAxis(int index) const
    {
        if (index < 0 || static_cast<size_t>(index) >= AxisCount) { return 0.0; }
        return Axes[static_cast<size_t>(index)];
    }
};

} // namespace rc
