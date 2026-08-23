// OpenRC Simulator - conversion between the physics frame and Godot's frame.
//
// This is the highest-risk boundary in the project, so the arithmetic lives here
// in the engine-agnostic core, where it is unit-tested without an engine. The
// GDExtension layer does nothing but copy the resulting components into
// godot::Vector3 / godot::Quaternion.
//
//   PHYSICS  world NED, right-handed, metres
//              X = North,  Y = East,  Z = Down
//   GODOT    world,       right-handed, metres
//              X = right,  Y = up,   Z = back   (a node's forward is -Z)
//
// Mapping the aircraft's sense of direction onto Godot's:
//
//     North (nose)      ->  -Z   (Godot forward)
//     East  (right wing)->  +X   (Godot right)
//     Down              ->  -Y   (Godot down)
//
// giving
//
//     M = [  0  1  0 ]        det(M) = +1
//         [  0  0 -1 ]        M M^T  = I
//         [ -1  0  0 ]
//
// Two consequences that make this much safer than the Unreal equivalent:
//
//   1. det = +1, so M is a PURE ROTATION. There is no reflection and no
//      handedness change, which means the quaternion conversion is an ordinary
//      similarity transform rather than a sign-flipping special case.
//   2. Godot works in metres, so there is no unit scaling at all. The classic
//      "forgot the factor of 100" bug simply cannot occur.
//
// M is a 120 degree rotation about (1, 1, -1)/sqrt(3), whose quaternion has the
// exact components (1/2, 1/2, 1/2, -1/2) - no floating point error is introduced
// by the conversion itself.
//
//     v_godot = M v_ned
//     q_godot = m (x) q_ned (x) m*
//
// Verified in Tests/Core/TestFrameConversion.cpp, including that rotation and
// vector conversion commute.
//
// NOTE: the returned Vec3 / Quat are *Godot-convention values carried in the
// core's own types*. Never feed one back into a physics routine.
#pragma once

#include "RCPhysics/Core/Math/Quat.h"
#include "RCPhysics/Core/Math/Vec3.h"

namespace rc::frame
{
/** Godot works in metres, same as the physics core. Kept as a named constant so
 *  that call sites read the same as they would for an engine that did not. */
inline constexpr Real kMetresToGodot = 1.0;
inline constexpr Real kGodotToMetres = 1.0;

/** The basis-change rotation, exactly representable. */
inline constexpr Quat NedToGodotRotation() { return Quat(0.5, 0.5, 0.5, -0.5); }
inline constexpr Quat GodotToNedRotation() { return Quat(0.5, -0.5, -0.5, 0.5); }

/** Position [m, NED] -> Godot position [m]. */
inline constexpr Vec3 PositionToGodot(const Vec3& positionNED)
{
    return Vec3(positionNED.y, -positionNED.z, -positionNED.x);
}

/** Godot position [m] -> position [m, NED]. */
inline constexpr Vec3 PositionFromGodot(const Vec3& positionGodot)
{
    return Vec3(-positionGodot.z, positionGodot.x, -positionGodot.y);
}

/** Any free vector - velocity, force, an offset from the CG. Identical to the
 *  position mapping because there is no scaling to apply. */
inline constexpr Vec3 VectorToGodot(const Vec3& vectorNED)
{
    return PositionToGodot(vectorNED);
}

inline constexpr Vec3 VectorFromGodot(const Vec3& vectorGodot)
{
    return PositionFromGodot(vectorGodot);
}

/** A direction only. Same mapping - M is a rotation, so it already preserves
 *  length. Kept as a distinct name so intent is visible at the call site. */
inline constexpr Vec3 DirectionToGodot(const Vec3& directionNED)
{
    return PositionToGodot(directionNED);
}

inline constexpr Vec3 DirectionFromGodot(const Vec3& directionGodot)
{
    return PositionFromGodot(directionGodot);
}

/** Attitude q_wb (body -> world, NED) -> the equivalent Godot rotation. */
inline Quat RotationToGodot(const Quat& attitudeNED)
{
    const Quat m = NedToGodotRotation();
    return (m * attitudeNED * m.Conjugate()).Normalized();
}

inline Quat RotationFromGodot(const Quat& rotationGodot)
{
    const Quat m = NedToGodotRotation();
    return (m.Conjugate() * rotationGodot * m).Normalized();
}

/** Height above the Z = 0 datum, in Godot units. Godot's Y axis is up and its
 *  unit is the metre, so altitude maps straight onto the Y coordinate. */
inline constexpr Real AltitudeToGodot(Real altitudeMetres)
{
    return altitudeMetres;
}

/** Godot exposes rotation to designers as degrees. Deriving the Euler angles
 *  from the NED attitude and restating them in degrees is safer than converting
 *  Godot's own Euler triple, whose axis order differs. For HUD and tuning UI
 *  only - never round-trip an attitude through this. */
struct AttitudeDegrees
{
    Real Roll  = 0.0;   ///< right wing down positive
    Real Pitch = 0.0;   ///< nose up positive
    Real Yaw   = 0.0;   ///< clockwise from North, seen from above
};

AttitudeDegrees ToAttitudeDegrees(const Quat& attitudeNED);

} // namespace rc::frame
