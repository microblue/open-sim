// OpenRC Simulator - the ONLY place physics values become Godot values.
//
// All the actual arithmetic (the basis rotation) lives in
// RCPhysics/Core/Math/FrameConversion.h, where it is unit-tested without an
// engine. This header does nothing but move components between rc::Vec3 /
// rc::Quat and godot::Vector3 / godot::Quaternion, narrowing double to Godot's
// real_t at the boundary.
//
// Rule: no other file in the extension may convert frames by hand. If you catch
// yourself negating a component next to a physics value, it belongs here.
#pragma once

#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "RCPhysics/Core/Math/FrameConversion.h"
#include "RCPhysics/Core/Math/Quat.h"
#include "RCPhysics/Core/Math/Vec3.h"

namespace openrc
{
/** Position [m, NED] -> Godot world position [m]. */
inline godot::Vector3 ToGodotPosition(const rc::Vec3& positionNED)
{
    const rc::Vec3 converted = rc::frame::PositionToGodot(positionNED);
    return godot::Vector3(static_cast<real_t>(converted.x),
                          static_cast<real_t>(converted.y),
                          static_cast<real_t>(converted.z));
}

inline rc::Vec3 FromGodotPosition(const godot::Vector3& position)
{
    return rc::frame::PositionFromGodot(rc::Vec3(static_cast<rc::Real>(position.x),
                                                 static_cast<rc::Real>(position.y),
                                                 static_cast<rc::Real>(position.z)));
}

/** Velocity, force, or an offset from the CG. */
inline godot::Vector3 ToGodotVector(const rc::Vec3& vectorNED)
{
    const rc::Vec3 converted = rc::frame::VectorToGodot(vectorNED);
    return godot::Vector3(static_cast<real_t>(converted.x),
                          static_cast<real_t>(converted.y),
                          static_cast<real_t>(converted.z));
}

inline rc::Vec3 FromGodotVector(const godot::Vector3& vector)
{
    return rc::frame::VectorFromGodot(rc::Vec3(static_cast<rc::Real>(vector.x),
                                               static_cast<rc::Real>(vector.y),
                                               static_cast<rc::Real>(vector.z)));
}

/** A unit direction. Same mapping as a vector, since the basis change is a
 *  pure rotation and therefore already length preserving; kept as a distinct
 *  name so that intent is readable at the call site. */
inline godot::Vector3 ToGodotDirection(const rc::Vec3& directionNED)
{
    const rc::Vec3 converted = rc::frame::DirectionToGodot(directionNED);
    return godot::Vector3(static_cast<real_t>(converted.x),
                          static_cast<real_t>(converted.y),
                          static_cast<real_t>(converted.z));
}

inline rc::Vec3 FromGodotDirection(const godot::Vector3& direction)
{
    return rc::frame::DirectionFromGodot(rc::Vec3(static_cast<rc::Real>(direction.x),
                                                  static_cast<rc::Real>(direction.y),
                                                  static_cast<rc::Real>(direction.z)));
}

/** Attitude q_wb [NED] -> Godot rotation. */
inline godot::Quaternion ToGodotRotation(const rc::Quat& attitudeNED)
{
    const rc::Quat converted = rc::frame::RotationToGodot(attitudeNED);
    return godot::Quaternion(static_cast<real_t>(converted.x),
                             static_cast<real_t>(converted.y),
                             static_cast<real_t>(converted.z),
                             static_cast<real_t>(converted.w));
}

inline rc::Quat FromGodotRotation(const godot::Quaternion& rotation)
{
    return rc::frame::RotationFromGodot(rc::Quat(static_cast<rc::Real>(rotation.w),
                                                 static_cast<rc::Real>(rotation.x),
                                                 static_cast<rc::Real>(rotation.y),
                                                 static_cast<rc::Real>(rotation.z)));
}

} // namespace openrc
