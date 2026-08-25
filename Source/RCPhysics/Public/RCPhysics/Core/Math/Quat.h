// OpenRC Simulator - unit quaternion attitude.
//
// Convention: `Quat` stores q_wb, the rotation that takes a vector expressed in
// the BODY frame (FRD) and expresses it in the WORLD frame (NED).
//
//      v_world = q.Rotate(v_body)
//      v_body  = q.RotateInverse(v_world)
//
// Euler order is the aerospace standard 3-2-1: yaw about Z, then pitch about Y,
// then roll about X, i.e. R_wb = Rz(yaw) * Ry(pitch) * Rx(roll).
#pragma once

#include "RCPhysics/Core/Math/Mat3.h"
#include "RCPhysics/Core/Math/Vec3.h"

namespace rc
{
/** Roll / pitch / yaw triple, radians. Named to avoid confusing it with Vec3. */
struct EulerAngles
{
    Real roll  = 0.0;   ///< phi,   about body X (right wing down positive)
    Real pitch = 0.0;   ///< theta, about body Y (nose up positive)
    Real yaw   = 0.0;   ///< psi,   about body Z (nose right positive, from North)
};

struct Quat
{
    Real w = 1.0;
    Real x = 0.0;
    Real y = 0.0;
    Real z = 0.0;

    constexpr Quat() = default;
    constexpr Quat(Real inW, Real inX, Real inY, Real inZ) : w(inW), x(inX), y(inY), z(inZ) {}

    static constexpr Quat Identity() { return Quat(1.0, 0.0, 0.0, 0.0); }

    static Quat FromAxisAngle(const Vec3& axis, Real angleRadians)
    {
        const Vec3 unit = axis.Normalized(Vec3::UnitZ());
        const Real half = 0.5 * angleRadians;
        const Real s    = std::sin(half);
        return Quat(std::cos(half), unit.x * s, unit.y * s, unit.z * s);
    }

    /** Exponential map of a rotation vector (axis * angle). Exact, and safe
     *  through zero. This is what the attitude integrator uses. */
    static Quat FromRotationVector(const Vec3& rotationVector)
    {
        const Real angle = rotationVector.Length();
        if (angle < 1e-12)
        {
            // Second-order series; renormalisation below keeps it unit-norm.
            return Quat(1.0, 0.5 * rotationVector.x,
                             0.5 * rotationVector.y,
                             0.5 * rotationVector.z).Normalized();
        }
        const Real half = 0.5 * angle;
        const Real s    = std::sin(half) / angle;
        return Quat(std::cos(half), rotationVector.x * s,
                                    rotationVector.y * s,
                                    rotationVector.z * s);
    }

    static Quat FromEuler(Real roll, Real pitch, Real yaw)
    {
        const Real cr = std::cos(0.5 * roll),  sr = std::sin(0.5 * roll);
        const Real cp = std::cos(0.5 * pitch), sp = std::sin(0.5 * pitch);
        const Real cy = std::cos(0.5 * yaw),   sy = std::sin(0.5 * yaw);
        return Quat(cr * cp * cy + sr * sp * sy,
                    sr * cp * cy - cr * sp * sy,
                    cr * sp * cy + sr * cp * sy,
                    cr * cp * sy - sr * sp * cy);
    }

    static Quat FromEuler(const EulerAngles& e) { return FromEuler(e.roll, e.pitch, e.yaw); }

    EulerAngles ToEuler() const
    {
        EulerAngles e;
        e.roll  = std::atan2(2.0 * (w * x + y * z), 1.0 - 2.0 * (x * x + y * y));
        e.pitch = std::asin(ClampUnit(2.0 * (w * y - z * x)));
        e.yaw   = std::atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z));
        return e;
    }

    constexpr Real NormSquared() const { return w * w + x * x + y * y + z * z; }
    Real Norm() const { return std::sqrt(NormSquared()); }

    Quat Normalized() const
    {
        const Real n = Norm();
        if (n < kEpsilon) return Identity();
        const Real inv = 1.0 / n;
        return Quat(w * inv, x * inv, y * inv, z * inv);
    }

    void Normalize() { *this = Normalized(); }

    /** Inverse rotation (valid as the inverse only while unit-norm). */
    constexpr Quat Conjugate() const { return Quat(w, -x, -y, -z); }

    /** Hamilton product. `a * b` applies b first, then a. */
    constexpr Quat operator*(const Quat& o) const
    {
        return Quat(w * o.w - x * o.x - y * o.y - z * o.z,
                    w * o.x + x * o.w + y * o.z - z * o.y,
                    w * o.y - x * o.z + y * o.w + z * o.x,
                    w * o.z + x * o.y - y * o.x + z * o.w);
    }

    /** body -> world */
    constexpr Vec3 Rotate(const Vec3& v) const
    {
        const Vec3 qv(x, y, z);
        const Vec3 t = Cross(qv, v) * 2.0;
        return v + t * w + Cross(qv, t);
    }

    /** world -> body */
    constexpr Vec3 RotateInverse(const Vec3& v) const
    {
        const Vec3 qv(-x, -y, -z);
        const Vec3 t = Cross(qv, v) * 2.0;
        return v + t * w + Cross(qv, t);
    }

    /** Rotation matrix R_wb (columns are the body axes expressed in world). */
    constexpr Mat3 ToMatrix() const
    {
        const Real xx = x * x, yy = y * y, zz = z * z;
        const Real xy = x * y, xz = x * z, yz = y * z;
        const Real wx = w * x, wy = w * y, wz = w * z;
        return Mat3(1.0 - 2.0 * (yy + zz), 2.0 * (xy - wz),       2.0 * (xz + wy),
                    2.0 * (xy + wz),       1.0 - 2.0 * (xx + zz), 2.0 * (yz - wx),
                    2.0 * (xz - wy),       2.0 * (yz + wx),       1.0 - 2.0 * (xx + yy));
    }

    /** Advance attitude by a body-frame angular rate over dt.
     *  Uses the exponential map, so the result is unit-norm by construction and
     *  exact for a constant rate - no drift, no per-step renormalisation hack. */
    Quat IntegrateBodyRate(const Vec3& bodyAngularRate, Real dt) const
    {
        return (*this * Quat::FromRotationVector(bodyAngularRate * dt)).Normalized();
    }

    bool IsFinite() const
    {
        return rc::IsFinite(w) && rc::IsFinite(x) && rc::IsFinite(y) && rc::IsFinite(z);
    }
};

/** True when the two quaternions describe the same rotation (q and -q do). */
inline bool NearlySameRotation(const Quat& a, const Quat& b, Real tol = 1e-9)
{
    const Real d = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z;
    return std::fabs(std::fabs(d) - 1.0) <= tol;
}


/** Shortest-arc spherical interpolation.
 *
 *  A linear blend of two quaternions is not a rotation - renormalising it gives
 *  something that visibly shrinks the attitude towards the halfway point over a
 *  fast roll, which is exactly where a replay is being watched closely. This
 *  costs a trig call and is correct.
 *
 *  Falls back to a linear blend when the two are already close, where the
 *  spherical form loses precision and the difference is invisible. */
inline Quat Slerp(const Quat& a, const Quat& b, Real t)
{
    Real cosine = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z;

    // Take the shorter of the two arcs: q and -q are the same rotation, and
    // without this a roll through more than a half turn goes the long way.
    Quat end = b;
    if (cosine < Real(0))
    {
        end = Quat(-b.w, -b.x, -b.y, -b.z);
        cosine = -cosine;
    }

    if (cosine > Real(0.9995))
    {
        return Quat(a.w + (end.w - a.w) * t,
                    a.x + (end.x - a.x) * t,
                    a.y + (end.y - a.y) * t,
                    a.z + (end.z - a.z) * t).Normalized();
    }

    const Real angle = std::acos(cosine);
    const Real sine = std::sin(angle);
    const Real wa = std::sin((Real(1) - t) * angle) / sine;
    const Real wb = std::sin(t * angle) / sine;
    return Quat(a.w * wa + end.w * wb,
                a.x * wa + end.x * wb,
                a.y * wa + end.y * wb,
                a.z * wa + end.z * wb).Normalized();
}

} // namespace rc
