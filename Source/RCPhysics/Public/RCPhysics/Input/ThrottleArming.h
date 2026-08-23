// OpenRC Simulator - throttle arming interlock.
//
// The throttle stays closed until the simulator has actually seen the stick at
// idle. Two independent reasons, both real:
//
//   1. A transmitter can report a stale or mid-range value before the pilot has
//      touched it. Godot only refreshes an axis when it changes, so an axis
//      nobody has moved since the device was opened can read zero - and zero is
//      the MIDDLE of a throttle's raw travel, not the bottom of it. Believing
//      that would start the aircraft at half power sitting on the runway.
//
//   2. It is what a pilot should be trained to do. Full-size and RC practice
//      alike: confirm the throttle is closed before the motor can turn. A
//      simulator that skips the check teaches the habit of skipping it.
//
// The interlock is deliberately one-way per session: once idle has been seen the
// throttle is live, because an interlock that keeps re-arming mid-flight would
// cut the motor in the air.

#ifndef RCPHYSICS_INPUT_THROTTLEARMING_H
#define RCPHYSICS_INPUT_THROTTLEARMING_H

#include "RCPhysics/Core/Types.h"

namespace rc
{
    class ThrottleArming
    {
    public:
        /** Normalised throttle at or below this counts as closed. Generous
         *  enough that a slightly miscalibrated bottom end still arms, tight
         *  enough that it cannot be met by a stick the pilot is holding open. */
        static constexpr Real kIdleThreshold = Real(0.05);

        /** Gate a throttle value. Returns zero until the stick has been seen
         *  closed, and the value unchanged from then on. */
        Real Apply(Real throttle)
        {
            if (!Armed && throttle <= kIdleThreshold)
            {
                Armed = true;
            }
            return Armed ? throttle : Real(0);
        }

        bool IsArmed() const { return Armed; }

        /** Re-arm the interlock. Called when the controller changes or the
         *  profile is reloaded - both leave the previous reading meaningless. */
        void Reset() { Armed = false; }

    private:
        bool Armed = false;
    };
}

#endif
