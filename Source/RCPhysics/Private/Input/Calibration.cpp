#include "RCPhysics/Input/Calibration.h"

#include <cmath>

namespace rc
{
namespace
{
    /** Below this the captured travel is treated as noise rather than a stick. */
    constexpr Real kMinimumUsableTravel = 0.10;

    /** Rescale a deadzone-clipped value back to full range so that the stick
     *  still reaches +/-1 at the ends. Without this a 2% deadzone would cost 2%
     *  of maximum control deflection. */
    Real RemoveDeadzone(Real value, Real deadzone)
    {
        const Real magnitude = std::fabs(value);
        if (magnitude <= deadzone)
        {
            return 0.0;
        }
        const Real span = 1.0 - deadzone;
        if (span <= kEpsilon)
        {
            return Sign(value);
        }
        return Sign(value) * ((magnitude - deadzone) / span);
    }
}

Real AxisCalibration::Normalize(Real raw, bool bipolar) const
{
    if (!IsValid())
    {
        return 0.0;
    }

    Real normalized = 0.0;

    if (bipolar)
    {
        // Pivot on the captured centre so an off-centre stick still rests at
        // exactly zero and still reaches full travel on both sides.
        if (raw >= RawCenter)
        {
            normalized = SafeDivide(raw - RawCenter, RawMax - RawCenter, 0.0);
        }
        else
        {
            normalized = -SafeDivide(RawCenter - raw, RawCenter - RawMin, 0.0);
        }
        normalized = ClampUnit(normalized);
        normalized = RemoveDeadzone(normalized, Deadzone);
    }
    else
    {
        normalized = SafeDivide(raw - RawMin, RawMax - RawMin, 0.0);
        normalized = Clamp(normalized, 0.0, 1.0);
        // A unipolar channel's deadzone belongs at the bottom of the travel, so
        // that a throttle stick that does not quite reach its stop still gives
        // a true zero.
        if (normalized <= Deadzone)
        {
            normalized = 0.0;
        }
        else
        {
            normalized = (normalized - Deadzone) / Max(1.0 - Deadzone, kEpsilon);
        }
    }

    return Reversed ? -normalized : normalized;
}

bool AxisCalibration::IsValid() const
{
    if (!IsFinite(RawMin) || !IsFinite(RawCenter) || !IsFinite(RawMax))
    {
        return false;
    }
    if (RawMax - RawMin < kMinimumUsableTravel)
    {
        return false;
    }
    return RawCenter > RawMin && RawCenter < RawMax;
}

// --------------------------------------------------------- CalibrationCapture

void CalibrationCapture::Reset()
{
    CentreSum         = 0.0;
    CentreSampleCount = 0;
    ObservedMin       =  1e30;
    ObservedMax       = -1e30;
    TravelSampleCount = 0;
}

void CalibrationCapture::ResetTravel()
{
    ObservedMin       =  1e30;
    ObservedMax       = -1e30;
    TravelSampleCount = 0;
}

void CalibrationCapture::SampleCentre(Real raw)
{
    if (!IsFinite(raw)) { return; }
    CentreSum += raw;
    ++CentreSampleCount;
    // A centre sample is also a travel sample; the stick is somewhere real.
    SampleTravel(raw);
}

void CalibrationCapture::SampleTravel(Real raw)
{
    if (!IsFinite(raw)) { return; }
    ObservedMin = Min(ObservedMin, raw);
    ObservedMax = Max(ObservedMax, raw);
    ++TravelSampleCount;
}

Real CalibrationCapture::ObservedRange() const
{
    if (TravelSampleCount == 0) { return 0.0; }
    return ObservedMax - ObservedMin;
}

AxisCalibration CalibrationCapture::Result(Real deadzone) const
{
    AxisCalibration calibration;
    calibration.Deadzone = Clamp(deadzone, 0.0, 0.4);

    if (TravelSampleCount == 0)
    {
        // Nothing was ever sampled. Return a deliberately INVALID calibration
        // rather than the default -1/0/+1, so that a caller cannot bind a
        // channel to an axis the pilot never swept - which would look fine in
        // the wizard and then read full deflection at rest.
        calibration.RawMin    = 0.0;
        calibration.RawCenter = 0.0;
        calibration.RawMax    = 0.0;
        return calibration;
    }

    calibration.RawMin = ObservedMin;
    calibration.RawMax = ObservedMax;
    calibration.RawCenter = (CentreSampleCount > 0)
                          ? (CentreSum / static_cast<Real>(CentreSampleCount))
                          : (0.5 * (ObservedMin + ObservedMax));

    // A centre outside the captured travel means the pilot moved the stick
    // during the centring step; fall back to the midpoint rather than producing
    // a calibration that reports full deflection at rest.
    if (calibration.RawCenter <= calibration.RawMin ||
        calibration.RawCenter >= calibration.RawMax)
    {
        calibration.RawCenter = 0.5 * (calibration.RawMin + calibration.RawMax);
    }

    return calibration;
}

int FindMostMovedAxis(const CalibrationCapture* captures, size_t captureCount,
                      Real minimumRange)
{
    int  bestIndex = -1;
    Real bestRange = minimumRange;
    Real runnerUp  = 0.0;

    for (size_t i = 0; i < captureCount; ++i)
    {
        const Real range = captures[i].ObservedRange();
        if (range > bestRange)
        {
            runnerUp  = bestRange;
            bestRange = range;
            bestIndex = static_cast<int>(i);
        }
        else if (range > runnerUp)
        {
            runnerUp = range;
        }
    }

    // Reject an ambiguous result. Some radios move two axes together on a
    // gimbal; asking the pilot to wiggle again beats binding the wrong one.
    if (bestIndex >= 0 && runnerUp > 0.0 && bestRange < runnerUp * 1.5)
    {
        return -1;
    }
    return bestIndex;
}

} // namespace rc
