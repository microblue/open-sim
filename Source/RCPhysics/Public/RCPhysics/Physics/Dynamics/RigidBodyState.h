// OpenRC Simulator - 6-DoF rigid body state.
//
// Frames (see Vec3.h): position and linear velocity live in WORLD/NED,
// angular velocity lives in BODY/FRD. Mixing them this way keeps the linear
// equation free of Coriolis terms while letting Euler's rotational equation be
// written in its textbook body-frame form.
#pragma once

#include "RCPhysics/Core/Math/Quat.h"
#include "RCPhysics/Core/Math/Vec3.h"

namespace rc
{
struct RigidBodyState
{
    /** Position of the centre of gravity, world NED [m]. Z is down, so
     *  altitude above the field is -PositionWorld.z. */
    Vec3 PositionWorld = Vec3::Zero();

    /** Velocity of the CG, world NED [m/s]. */
    Vec3 VelocityWorld = Vec3::Zero();

    /** Attitude q_wb: rotates body vectors into world. */
    Quat Orientation = Quat::Identity();

    /** Angular velocity in the BODY frame [rad/s] - (p, q, r). */
    Vec3 AngularVelocityBody = Vec3::Zero();

    // ---------------------------------------------------------- accessors ---

    /** Velocity of the CG expressed in body axes [m/s] - (u, v, w). */
    Vec3 VelocityBody() const { return Orientation.RotateInverse(VelocityWorld); }

    void SetVelocityBody(const Vec3& velocityBody)
    {
        VelocityWorld = Orientation.Rotate(velocityBody);
    }

    /** Height above the Z = 0 datum [m]. */
    Real AltitudeMetres() const { return -PositionWorld.z; }

    /** Speed through the ground-fixed frame [m/s]. With no wind this equals
     *  true airspeed; the aero layer computes airspeed from relative wind. */
    Real GroundSpeed() const { return VelocityWorld.Length(); }

    EulerAngles Attitude() const { return Orientation.ToEuler(); }

    bool IsFinite() const
    {
        return PositionWorld.IsFinite()
            && VelocityWorld.IsFinite()
            && Orientation.IsFinite()
            && AngularVelocityBody.IsFinite();
    }
};

/** Mass distribution about the CG, expressed in body axes. */
struct MassProperties
{
    /** Total mass [kg]. */
    Real Mass = 1.0;

    /** Inertia tensor about the CG in body axes [kg*m^2]. */
    Mat3 Inertia = Mat3::Diagonal(1.0, 1.0, 1.0);

    /** Cached inverse - recomputed by Finalize(). */
    Mat3 InverseInertia = Mat3::Diagonal(1.0, 1.0, 1.0);

    /** Call after touching Mass or Inertia. */
    void Finalize() { InverseInertia = Inertia.Inverse(); }

    bool IsValid() const
    {
        return Mass > kEpsilon && std::fabs(Inertia.Determinant()) > 1e-12;
    }
};

/** A force and a moment, both in BODY axes, the moment taken about the CG.
 *  Every force producer in the sim (aero section, propeller, wheel) reports
 *  its contribution as one of these. */
struct Wrench
{
    Vec3 Force  = Vec3::Zero();   ///< [N],   body axes
    Vec3 Moment = Vec3::Zero();   ///< [N*m], body axes, about the CG

    Wrench& operator+=(const Wrench& o)
    {
        Force  += o.Force;
        Moment += o.Moment;
        return *this;
    }

    Wrench operator+(const Wrench& o) const
    {
        Wrench r = *this;
        r += o;
        return r;
    }

    bool IsFinite() const { return Force.IsFinite() && Moment.IsFinite(); }
};

} // namespace rc
