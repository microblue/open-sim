// OpenRC Simulator - stick shaping, in the order a real transmitter does it.
//
//     normalised stick
//        -> expo        softens the centre without losing full travel
//        -> dual rate   scales the whole throw
//        -> trim        offsets the neutral point
//        -> clamp
//
// The order matters and is not arbitrary. Applying rate before expo would make
// the expo curve act on a shortened throw and change its feel every time the
// pilot flips the rate switch, which is not how a radio behaves.
//
// Raw Mode bypasses all three. Pilots who have already dialled expo and rates
// into their transmitter must not get them applied twice.
#pragma once

#include "RCPhysics/Core/Types.h"

namespace rc
{
/** The standard RC exponential curve.
 *
 *      y = e * x^3 + (1 - e) * x
 *
 *  e = 0 is linear; e = 1 is pure cubic. Full stick still gives full output at
 *  any e, which is the property that makes this the curve radios use. */
Real ApplyExpo(Real normalized, Real expo);

/** Slope of the expo curve at the centre stick - the number that actually
 *  describes "how soft does it feel around neutral". */
Real ExpoCentreSensitivity(Real expo);

struct ChannelShaping
{
    /** 0..1. Typical trainer settings are 0.2 - 0.35. */
    Real Expo = 0.0;

    /** 0..1 multiplier on total throw. */
    Real DualRate = 1.0;

    /** Neutral offset in normalised units, -1..1. Usually a few percent. */
    Real Trim = 0.0;

    /** Bypass expo, dual rate and trim entirely. Calibration and reverse still
     *  apply, because those describe the hardware rather than the feel. */
    bool RawMode = false;

    Real Apply(Real normalized, bool bipolar) const;
};

} // namespace rc
