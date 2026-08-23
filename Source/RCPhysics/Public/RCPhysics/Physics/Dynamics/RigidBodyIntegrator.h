// OpenRC Simulator - 6-DoF integration.
//
// Equations, in the frames declared in Vec3.h:
//
//   linear   a_world = R_wb * F_body / m  +  g_world
//   angular  omega_dot = I^-1 * ( M_body - omega x (I * omega) )
//   attitude q_dot = 0.5 * q (x) (0, omega_body)
//
// Two integrators are provided and they are not interchangeable by accident:
//
//   SemiImplicitEuler - the DEFAULT for the live sim. Symplectic, so it does
//       not pump energy over long flights, and it stays well behaved when the
//       force field is discontinuous (wheel touchdown, stall break). At 240 Hz
//       its phase error on a trainer's fastest mode (roll, ~5 Hz) is well under
//       a percent, which is far below the uncertainty in the aero data itself.
//
//   RK4 - used by the validation suite to prove that results are step-rate
//       independent, and available for smooth-force studies (glide polars,
//       phugoid periods). It calls the force model four times per step, so it
//       needs that model to be a pure function of state - which it is, by
//       design. Do not use it across a contact discontinuity.
#pragma once

#include "RCPhysics/Core/Log.h"
#include "RCPhysics/Core/Units/Units.h"
#include "RCPhysics/Physics/Dynamics/RigidBodyState.h"

namespace rc
{
/** Gravity in world/NED axes. Down is +Z, so gravity is +Z. */
inline Vec3 DefaultGravityWorld() { return Vec3(0.0, 0.0, units::kGravity); }

namespace detail
{
    /** Non-unit quaternion helpers, needed only inside RK4 where intermediate
     *  quaternion states are deliberately not normalised. */
    inline constexpr Quat QuatScale(const Quat& q, Real s)
    {
        return Quat(q.w * s, q.x * s, q.y * s, q.z * s);
    }

    inline constexpr Quat QuatAdd(const Quat& a, const Quat& b)
    {
        return Quat(a.w + b.w, a.x + b.x, a.y + b.y, a.z + b.z);
    }

    /** q_dot = 0.5 * q (x) (0, omega_body) */
    inline constexpr Quat QuatDerivative(const Quat& q, const Vec3& omegaBody)
    {
        const Quat omega(0.0, omegaBody.x, omegaBody.y, omegaBody.z);
        return QuatScale(q * omega, 0.5);
    }
}

/** Time derivative of the full state. */
struct StateDerivative
{
    Vec3 VelocityWorld     = Vec3::Zero();   ///< d(position)/dt
    Vec3 AccelerationWorld = Vec3::Zero();   ///< d(velocity)/dt
    Quat OrientationRate   = Quat(0, 0, 0, 0);
    Vec3 AngularAcceleration = Vec3::Zero(); ///< d(omega_body)/dt
};

/** Body-axis linear acceleration excluding gravity, i.e. what an accelerometer
 *  bolted to the CG would read [m/s^2]. Useful for HUD "g" readout. */
inline Vec3 SpecificForceBody(const Wrench& wrench, const MassProperties& mass)
{
    return wrench.Force / mass.Mass;
}

/** Angular acceleration from Euler's equation, body axes [rad/s^2]. */
inline Vec3 AngularAccelerationBody(const Vec3& angularVelocityBody,
                                    const Vec3& momentBody,
                                    const MassProperties& mass)
{
    const Vec3 angularMomentum = mass.Inertia * angularVelocityBody;
    const Vec3 gyroscopic      = Cross(angularVelocityBody, angularMomentum);
    return mass.InverseInertia * (momentBody - gyroscopic);
}

inline StateDerivative ComputeDerivative(const RigidBodyState& state,
                                         const MassProperties& mass,
                                         const Wrench& wrench,
                                         const Vec3& gravityWorld)
{
    StateDerivative d;
    d.VelocityWorld       = state.VelocityWorld;
    d.AccelerationWorld   = state.Orientation.Rotate(wrench.Force / mass.Mass) + gravityWorld;
    d.OrientationRate     = detail::QuatDerivative(state.Orientation, state.AngularVelocityBody);
    d.AngularAcceleration = AngularAccelerationBody(state.AngularVelocityBody,
                                                    wrench.Moment, mass);
    return d;
}

/** Reject a state that has gone non-finite, log once, and report failure so the
 *  caller can trigger a reset rather than propagate NaN into the renderer. */
inline bool ValidateOrRestore(RigidBodyState& state, const RigidBodyState& previous)
{
    if (state.IsFinite())
    {
        return true;
    }
    RC_LOG(Physics, Error,
           "Integration produced a non-finite state; restoring previous step. "
           "Check for a divide-by-zero or an unbounded coefficient in the force model.");
    state = previous;
    return false;
}

/** Symplectic (semi-implicit) Euler: velocities first, then positions with the
 *  NEW velocities. Default integrator for the live sim. */
inline bool StepSemiImplicitEuler(RigidBodyState& state,
                                  const MassProperties& mass,
                                  const Wrench& wrench,
                                  Real dt,
                                  const Vec3& gravityWorld = DefaultGravityWorld())
{
    const RigidBodyState previous = state;

    const Vec3 accelerationWorld =
        state.Orientation.Rotate(wrench.Force / mass.Mass) + gravityWorld;
    const Vec3 angularAcceleration =
        AngularAccelerationBody(state.AngularVelocityBody, wrench.Moment, mass);

    state.VelocityWorld       += accelerationWorld * dt;
    state.AngularVelocityBody += angularAcceleration * dt;

    state.PositionWorld += state.VelocityWorld * dt;
    state.Orientation    = state.Orientation.IntegrateBodyRate(state.AngularVelocityBody, dt);

    return ValidateOrRestore(state, previous);
}

/** Classical RK4. `evaluateWrench` must be a pure function of state:
 *      Wrench evaluateWrench(const RigidBodyState& trialState)
 *  It is called four times per step. */
template <typename WrenchEvaluator>
bool StepRK4(RigidBodyState& state,
             const MassProperties& mass,
             WrenchEvaluator&& evaluateWrench,
             Real dt,
             const Vec3& gravityWorld = DefaultGravityWorld())
{
    const RigidBodyState previous = state;

    auto advance = [](const RigidBodyState& base, const StateDerivative& d, Real step)
    {
        RigidBodyState s;
        s.PositionWorld       = base.PositionWorld + d.VelocityWorld * step;
        s.VelocityWorld       = base.VelocityWorld + d.AccelerationWorld * step;
        s.Orientation         = detail::QuatAdd(base.Orientation,
                                                detail::QuatScale(d.OrientationRate, step));
        s.AngularVelocityBody = base.AngularVelocityBody + d.AngularAcceleration * step;
        return s;
    };

    const StateDerivative k1 = ComputeDerivative(state, mass, evaluateWrench(state), gravityWorld);

    RigidBodyState s2 = advance(state, k1, 0.5 * dt);
    s2.Orientation.Normalize();
    const StateDerivative k2 = ComputeDerivative(s2, mass, evaluateWrench(s2), gravityWorld);

    RigidBodyState s3 = advance(state, k2, 0.5 * dt);
    s3.Orientation.Normalize();
    const StateDerivative k3 = ComputeDerivative(s3, mass, evaluateWrench(s3), gravityWorld);

    RigidBodyState s4 = advance(state, k3, dt);
    s4.Orientation.Normalize();
    const StateDerivative k4 = ComputeDerivative(s4, mass, evaluateWrench(s4), gravityWorld);

    const Real sixth = dt / 6.0;

    state.PositionWorld += (k1.VelocityWorld
                          + k2.VelocityWorld * 2.0
                          + k3.VelocityWorld * 2.0
                          + k4.VelocityWorld) * sixth;

    state.VelocityWorld += (k1.AccelerationWorld
                          + k2.AccelerationWorld * 2.0
                          + k3.AccelerationWorld * 2.0
                          + k4.AccelerationWorld) * sixth;

    state.AngularVelocityBody += (k1.AngularAcceleration
                                + k2.AngularAcceleration * 2.0
                                + k3.AngularAcceleration * 2.0
                                + k4.AngularAcceleration) * sixth;

    Quat blended = detail::QuatAdd(k1.OrientationRate, k4.OrientationRate);
    blended = detail::QuatAdd(blended, detail::QuatScale(k2.OrientationRate, 2.0));
    blended = detail::QuatAdd(blended, detail::QuatScale(k3.OrientationRate, 2.0));
    state.Orientation = detail::QuatAdd(state.Orientation,
                                        detail::QuatScale(blended, sixth)).Normalized();

    return ValidateOrRestore(state, previous);
}

} // namespace rc
