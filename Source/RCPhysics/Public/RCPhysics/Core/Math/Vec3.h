// OpenRC Simulator - 3D vector.
//
// FRAME CONVENTIONS FOR THE WHOLE PHYSICS CORE (see Docs/ARCHITECTURE.md):
//
//   World frame  : NED, right-handed.  X = North, Y = East, Z = Down.
//                  Gravity is +Z. Altitude AGL = -Z (with ground at Z = 0).
//   Body frame   : FRD, right-handed.  X = out the nose,
//                                      Y = out the right wing,
//                                      Z = down through the belly.
//
// These are the standard aerospace frames (JSBSim / textbook 6-DoF), chosen so
// that every equation in Docs/PHYSICS_DESIGN.md can be transcribed literally.
// Unreal's Z-up / centimetre / left-handed world is a *presentation* frame and
// is converted only at the bridge (Source/OpenRCSim/Bridge/).
#pragma once

#include "RCPhysics/Core/Types.h"

namespace rc
{
struct Vec3
{
    Real x = 0.0;
    Real y = 0.0;
    Real z = 0.0;

    constexpr Vec3() = default;
    constexpr Vec3(Real inX, Real inY, Real inZ) : x(inX), y(inY), z(inZ) {}

    static constexpr Vec3 Zero()    { return Vec3(0.0, 0.0, 0.0); }
    static constexpr Vec3 UnitX()   { return Vec3(1.0, 0.0, 0.0); }
    static constexpr Vec3 UnitY()   { return Vec3(0.0, 1.0, 0.0); }
    static constexpr Vec3 UnitZ()   { return Vec3(0.0, 0.0, 1.0); }

    constexpr Vec3 operator-() const { return Vec3(-x, -y, -z); }

    constexpr Vec3 operator+(const Vec3& o) const { return Vec3(x + o.x, y + o.y, z + o.z); }
    constexpr Vec3 operator-(const Vec3& o) const { return Vec3(x - o.x, y - o.y, z - o.z); }
    constexpr Vec3 operator*(Real s)        const { return Vec3(x * s, y * s, z * s); }
    constexpr Vec3 operator/(Real s)        const { return Vec3(x / s, y / s, z / s); }

    Vec3& operator+=(const Vec3& o) { x += o.x; y += o.y; z += o.z; return *this; }
    Vec3& operator-=(const Vec3& o) { x -= o.x; y -= o.y; z -= o.z; return *this; }
    Vec3& operator*=(Real s)        { x *= s;   y *= s;   z *= s;   return *this; }
    Vec3& operator/=(Real s)        { x /= s;   y /= s;   z /= s;   return *this; }

    /** Component-wise product. Handy for per-axis scaling / inertia diagonals. */
    constexpr Vec3 Scaled(const Vec3& o) const { return Vec3(x * o.x, y * o.y, z * o.z); }

    constexpr Real LengthSquared() const { return x * x + y * y + z * z; }
    Real Length() const { return std::sqrt(LengthSquared()); }

    /** Unit vector, or `fallback` when this vector is degenerate. */
    Vec3 Normalized(const Vec3& fallback = Vec3::Zero()) const
    {
        const Real len = Length();
        return (len > kEpsilon) ? (*this / len) : fallback;
    }

    bool IsFinite() const { return rc::IsFinite(x) && rc::IsFinite(y) && rc::IsFinite(z); }
    bool IsNearlyZero(Real tol = 1e-8) const { return LengthSquared() <= tol * tol; }
};

inline constexpr Vec3 operator*(Real s, const Vec3& v) { return v * s; }

inline constexpr Real Dot(const Vec3& a, const Vec3& b)
{
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline constexpr Vec3 Cross(const Vec3& a, const Vec3& b)
{
    return Vec3(a.y * b.z - a.z * b.y,
                a.z * b.x - a.x * b.z,
                a.x * b.y - a.y * b.x);
}

inline Real Distance(const Vec3& a, const Vec3& b) { return (a - b).Length(); }

inline constexpr Vec3 Lerp(const Vec3& a, const Vec3& b, Real t)
{
    return Vec3(a.x + (b.x - a.x) * t,
                a.y + (b.y - a.y) * t,
                a.z + (b.z - a.z) * t);
}

/** Component of `v` along `unitAxis` (axis assumed normalized). */
inline constexpr Vec3 ProjectOnUnit(const Vec3& v, const Vec3& unitAxis)
{
    return unitAxis * Dot(v, unitAxis);
}

/** Part of `v` perpendicular to `unitAxis` (axis assumed normalized). */
inline constexpr Vec3 RejectFromUnit(const Vec3& v, const Vec3& unitAxis)
{
    return v - ProjectOnUnit(v, unitAxis);
}

inline bool NearlyEqual(const Vec3& a, const Vec3& b, Real tol = 1e-9)
{
    return (a - b).LengthSquared() <= tol * tol;
}

} // namespace rc
