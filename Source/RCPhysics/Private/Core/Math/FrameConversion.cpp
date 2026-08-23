#include "RCPhysics/Core/Math/FrameConversion.h"

#include "RCPhysics/Core/Units/Units.h"

namespace rc::frame
{
AttitudeDegrees ToAttitudeDegrees(const Quat& attitudeNED)
{
    const EulerAngles e = attitudeNED.ToEuler();
    AttitudeDegrees attitude;
    attitude.Roll  = units::ToDegrees(e.roll);
    attitude.Pitch = units::ToDegrees(e.pitch);
    attitude.Yaw   = units::ToDegrees(e.yaw);
    return attitude;
}

} // namespace rc::frame
