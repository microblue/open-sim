// OpenRC Simulator - per-axis calibration.
//
// A transmitter's raw axis range is never what the API claims. Sticks do not
// reach the ends of their travel, the centre is off, and different radios use
// different conventions for which way is "up". Calibration turns whatever the
// device reports into a clean normalised channel value, and it is captured once
// by the setup wizard rather than guessed.
#pragma once

#include "RCPhysics/Core/Types.h"
#include "RCPhysics/Input/ChannelTypes.h"

namespace rc
{
/** Captured travel limits for one physical axis. */
struct AxisCalibration
{
    Real RawMin    = -1.0;
    Real RawCenter =  0.0;
    Real RawMax    =  1.0;

    /** Fraction of travel around the centre that reads as exactly zero.
     *  Small by design: a trainer pilot needs fine inputs, and a large deadzone
     *  teaches a stick feel the real aircraft will not have. */
    Real Deadzone = 0.02;

    /** Set when the physical direction is opposite the convention. */
    bool Reversed = false;

    /** Map a raw reading onto the channel's normalised range.
     *  Bipolar channels come out -1..1 using RawCenter as the pivot, so an
     *  off-centre stick still gives exactly 0 at rest and full travel at both
     *  ends. Unipolar (throttle) comes out 0..1 across the whole range. */
    Real Normalize(Real raw, bool bipolar) const;

    /** True when the captured range is wide enough to be usable. */
    bool IsValid() const;
};

/** Accumulates min/max/centre while the pilot sweeps a stick, for the wizard.
 *
 *      capture.BeginCentre();  ... pilot holds sticks centred ...
 *      capture.SampleCentre(raw);
 *      capture.BeginTravel();  ... pilot sweeps to both extremes ...
 *      capture.SampleTravel(raw);
 *      AxisCalibration cal = capture.Result();
 */
class CalibrationCapture
{
public:
    /** Clear everything. */
    void Reset();

    /** Clear the swept travel but KEEP the captured centre.
     *
     *  The wizard captures every axis's centre once, then sweeps one stick at a
     *  time. Without this, starting the second sweep would either wipe the
     *  centres or leave the first stick's travel in the running, and the
     *  "which axis just moved" test would keep naming the aileron. */
    void ResetTravel();

    void SampleCentre(Real raw);
    void SampleTravel(Real raw);

    /** How far this axis has moved since Reset(). The wizard uses this to work
     *  out WHICH axis the pilot just wiggled, without asking them to know. */
    Real ObservedRange() const;

    AxisCalibration Result(Real deadzone = 0.02) const;

    bool HasCentre() const { return CentreSampleCount > 0; }
    bool HasTravel() const { return TravelSampleCount > 0; }

private:
    Real CentreSum         = 0.0;
    int  CentreSampleCount = 0;
    Real ObservedMin       =  1e30;
    Real ObservedMax       = -1e30;
    int  TravelSampleCount = 0;
};

/** Identify which axis of a device the pilot is currently moving. Returns -1
 *  when nothing has moved far enough to be unambiguous. This is what lets the
 *  wizard say "now move ELEVATOR" instead of asking for an axis number. */
int FindMostMovedAxis(const CalibrationCapture* captures, size_t captureCount,
                      Real minimumRange = 0.35);

} // namespace rc
