// OpenRC Simulator - does this profile actually match the radio in front of us?
//
// A binding can be perfectly well-formed and still be wrong for the device, and
// the failure is dangerous rather than cosmetic: a throttle bound to what is
// really a rudder means the motor answers a stick the pilot is using to steer.
//
// The check needs no calibration and no pilot action, because a transmitter at
// rest already says which axis is which:
//
//   a self-centring stick rests at the middle of its travel
//   a throttle rests at one end of it
//
// So if the axis bound to the throttle is sitting in the centre, it is not a
// throttle - and if an axis bound to a stick is pinned at an end, it is not a
// stick. Either way the pilot is told before the aircraft moves rather than
// after.

#ifndef RCPHYSICS_INPUT_PROFILECHECK_H
#define RCPHYSICS_INPUT_PROFILECHECK_H

#include "RCPhysics/Input/ChannelMapper.h"
#include "RCPhysics/Input/ChannelTypes.h"

#include <string>

namespace rc
{
    /** Normalised distance from the centre of an axis's travel beyond which it
     *  is taken to be resting at an end. Generous, because "at rest" here also
     *  covers a stick a pilot happens to be touching. */
    inline constexpr Real kRestingExtremeThreshold = Real(0.60);

    /** And within which it is taken to be centred. */
    inline constexpr Real kRestingCentreThreshold = Real(0.25);

    /** Describe what is wrong with `mapper` given a transmitter sitting at rest,
     *  or return an empty string if nothing is. */
    std::string DescribeProfileMismatch(const ChannelMapper& mapper,
                                        const RawAxisState& resting);
}

#endif
