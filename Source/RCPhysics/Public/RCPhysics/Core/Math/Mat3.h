// OpenRC Simulator - 3x3 matrix.
// Primary users: inertia tensor (and its inverse) and body<->world rotation.
// Storage is row-major: m[row][col].
#pragma once

#include "RCPhysics/Core/Math/Vec3.h"

namespace rc
{
struct Mat3
{
    Real m[3][3] = {{1.0, 0.0, 0.0},
                    {0.0, 1.0, 0.0},
                    {0.0, 0.0, 1.0}};

    constexpr Mat3() = default;

    constexpr Mat3(Real m00, Real m01, Real m02,
                   Real m10, Real m11, Real m12,
                   Real m20, Real m21, Real m22)
        : m{{m00, m01, m02}, {m10, m11, m12}, {m20, m21, m22}} {}

    static constexpr Mat3 Identity() { return Mat3(); }

    static constexpr Mat3 Zero()
    {
        return Mat3(0.0, 0.0, 0.0,
                    0.0, 0.0, 0.0,
                    0.0, 0.0, 0.0);
    }

    /** Diagonal matrix - the common case for an aircraft inertia tensor with
     *  a symmetric airframe (Ixy = Iyz = 0, Ixz often small enough to ignore). */
    static constexpr Mat3 Diagonal(Real d0, Real d1, Real d2)
    {
        return Mat3(d0,  0.0, 0.0,
                    0.0, d1,  0.0,
                    0.0, 0.0, d2);
    }

    static constexpr Mat3 Diagonal(const Vec3& d) { return Diagonal(d.x, d.y, d.z); }

    /** Full symmetric inertia tensor from the six independent components.
     *  Products of inertia follow the physics sign convention
     *  I = [[ Ixx, -Ixy, -Ixz], [-Ixy, Iyy, -Iyz], [-Ixz, -Iyz, Izz]]. */
    static constexpr Mat3 InertiaTensor(Real ixx, Real iyy, Real izz,
                                        Real ixy, Real ixz, Real iyz)
    {
        return Mat3( ixx, -ixy, -ixz,
                    -ixy,  iyy, -iyz,
                    -ixz, -iyz,  izz);
    }

    /** Skew-symmetric matrix such that Skew(a) * b == Cross(a, b). */
    static constexpr Mat3 Skew(const Vec3& v)
    {
        return Mat3( 0.0, -v.z,  v.y,
                     v.z,  0.0, -v.x,
                    -v.y,  v.x,  0.0);
    }

    constexpr Vec3 Row(int r) const    { return Vec3(m[r][0], m[r][1], m[r][2]); }
    constexpr Vec3 Column(int c) const { return Vec3(m[0][c], m[1][c], m[2][c]); }

    constexpr Vec3 operator*(const Vec3& v) const
    {
        return Vec3(m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
                    m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
                    m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z);
    }

    constexpr Mat3 operator*(const Mat3& o) const
    {
        Mat3 r = Mat3::Zero();
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j)
                r.m[i][j] = m[i][0] * o.m[0][j] + m[i][1] * o.m[1][j] + m[i][2] * o.m[2][j];
        return r;
    }

    constexpr Mat3 operator*(Real s) const
    {
        Mat3 r = *this;
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j)
                r.m[i][j] *= s;
        return r;
    }

    constexpr Mat3 operator+(const Mat3& o) const
    {
        Mat3 r = Mat3::Zero();
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j)
                r.m[i][j] = m[i][j] + o.m[i][j];
        return r;
    }

    constexpr Mat3 Transposed() const
    {
        return Mat3(m[0][0], m[1][0], m[2][0],
                    m[0][1], m[1][1], m[2][1],
                    m[0][2], m[1][2], m[2][2]);
    }

    constexpr Real Determinant() const
    {
        return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
             - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
             + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    }

    /** Inverse; returns identity when the matrix is singular. Callers that need
     *  to know should test Determinant() first. Inertia tensors of physical
     *  aircraft are always invertible, so identity is an inert fallback. */
    Mat3 Inverse() const
    {
        const Real det = Determinant();
        if (std::fabs(det) < 1e-18)
        {
            return Mat3::Identity();
        }
        const Real inv = 1.0 / det;
        Mat3 r = Mat3::Zero();
        r.m[0][0] =  (m[1][1] * m[2][2] - m[1][2] * m[2][1]) * inv;
        r.m[0][1] = -(m[0][1] * m[2][2] - m[0][2] * m[2][1]) * inv;
        r.m[0][2] =  (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * inv;
        r.m[1][0] = -(m[1][0] * m[2][2] - m[1][2] * m[2][0]) * inv;
        r.m[1][1] =  (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * inv;
        r.m[1][2] = -(m[0][0] * m[1][2] - m[0][2] * m[1][0]) * inv;
        r.m[2][0] =  (m[1][0] * m[2][1] - m[1][1] * m[2][0]) * inv;
        r.m[2][1] = -(m[0][0] * m[2][1] - m[0][1] * m[2][0]) * inv;
        r.m[2][2] =  (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * inv;
        return r;
    }
};

inline constexpr Mat3 operator*(Real s, const Mat3& mat) { return mat * s; }

inline bool NearlyEqual(const Mat3& a, const Mat3& b, Real tol = 1e-9)
{
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j)
            if (std::fabs(a.m[i][j] - b.m[i][j]) > tol) return false;
    return true;
}

} // namespace rc
