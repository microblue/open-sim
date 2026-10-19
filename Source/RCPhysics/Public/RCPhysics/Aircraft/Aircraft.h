// OpenRC Simulator - the assembled force model.
//
// Turns an AircraftDefinition into the thing the integrator asks for: given a
// rigid body state, the stick positions and the air, what force and moment act
// on the aircraft?
//
// Wind is sampled PER SECTION, at each section's own world position. That is
// what makes a wingspan-scale gust roll the aircraft rather than merely
// displace it, and it costs one extra evaluation per section per step.
//
// One caveat on purity: stall hysteresis means each section carries a
// separation flag between steps, so ComputeForces is not a pure function of the
// rigid body state alone. SnapshotAeroState()/RestoreAeroState() exist so that
// a multi-stage integrator or an offline sweep can freeze that state.
#pragma once

#include "RCPhysics/Aircraft/AircraftDefinition.h"
#include "RCPhysics/Physics/Dynamics/ForceAccumulator.h"
#include "RCPhysics/Physics/Environment/WindField.h"
#include "RCPhysics/Physics/Ground/LandingGear.h"

#include <vector>

namespace rc
{
/** What the propulsion system produced this step. Milestone 3 fills this in;
 *  until then it is all zeros and the aircraft glides. */
struct PropulsionOutput
{
    Real Thrust           = 0.0;   ///< N along the thrust axis
    Real ShaftTorque      = 0.0;   ///< N*m, the reaction the airframe feels
    Real InducedVelocity  = 0.0;   ///< m/s at the disc (half the wake increment)
    Real WakeSwirl        = 0.0;   ///< m^2/s swirl circulation, signed with rotation
    Real PropellerRate    = 0.0;   ///< rad/s
    Real Current          = 0.0;   ///< A
    Real Voltage          = 0.0;   ///< V

    /** Angular momentum of the spinning propeller about the thrust axis
     *  [kg m^2/s], signed with the rotation. Drives the gyroscopic moment. */
    Real AngularMomentum  = 0.0;
};

/** Everything one force evaluation produced. The HUD, the debug view and the
 *  validation suite all read this. */
struct AircraftForces
{
    Wrench Total;
    ForceAccumulator Accumulator;

    std::vector<SectionResult> Sections;
    FuselageResult Fuselage;

    /** True airspeed of the CG relative to the air [m/s]. */
    Real Airspeed = 0.0;
    Real Alpha    = 0.0;   ///< rad, whole-aircraft
    Real Beta     = 0.0;   ///< rad, whole-aircraft

    /** Total lift and drag resolved in the wind axes [N]. Reported for the
     *  validation suite, which needs L/D directly. */
    Real TotalLift = 0.0;
    Real TotalDrag = 0.0;

    /** How much of the airframe has let go, 0..1 - the fraction of wing area
     *  whose flow is separated. */
    Real StalledWingFraction = 0.0;

    /** Wing lift coefficient, and the downwash the wing puts into the air at
     *  the tail. Both drop away at the stall, which is what produces the
     *  nose-down pitch break. */
    Real WingLiftCoefficient = 0.0;
    Real DownwashVelocity = 0.0;   ///< m/s, downward
    Real DownwashAngle = 0.0;      ///< rad, for the HUD

    /** Height of the CG above the ground under it [m], and the share of
     *  free-air induced flow the wing still sees there (1 = out of ground
     *  effect). Both stay at their free-air values when no ground provider
     *  was supplied. */
    Real HeightAboveGround = -1.0;
    Real GroundEffectFactor = 1.0;

    /** Per-wheel ground contact. Empty when no ground provider was supplied. */
    std::vector<WheelResult> Wheels;

    /** Weight currently carried by the wheels [N]. Reaching zero is how the
     *  takeoff test knows the aircraft has flown. */
    Real WeightOnWheels = 0.0;
    bool OnGround = false;
};

class Aircraft
{
public:
    bool Configure(const AircraftDefinition& definition);

    const AircraftDefinition& Definition() const { return Definition_; }
    MassProperties GetMassProperties() const { return MassData; }

    /** Clear stall hysteresis. Called on reset. */
    void ResetAeroState();

    std::vector<bool> SnapshotAeroState() const { return Separated; }
    void RestoreAeroState(const std::vector<bool>& state);

    AircraftForces ComputeForces(const RigidBodyState& state,
                                 const ChannelValues& controls,
                                 const Atmosphere& atmosphere,
                                 const WindField& wind,
                                 const PropulsionOutput& propulsion = PropulsionOutput{},
                                 const GroundProvider* ground = nullptr) const;

    const LandingGear& Gear() const { return Wheels; }
    const CrashModel& Crash() const { return CrashDetector; }

    /** Propeller-induced flow at a body-frame point, expressed as an addition
     *  to the section's relative airflow. Public so the debug view can draw the
     *  wake cone and the validation suite can probe it. */
    /** Ground effect, as the fraction of free-air induced flow a wing keeps at
     *  a height h above the ground, given as h / wingspan.
     *
     *  McCormick's image-vortex result:
     *
     *      phi = (16 h/b)^2 / (1 + (16 h/b)^2)
     *
     *  At half a span up it is 0.98 - effectively free air - and at a tenth of
     *  a span, which is a 1.5 m model holding off a few inches above the grass,
     *  it is 0.72: the wing behaves as if it had 40 % more aspect ratio. That
     *  is the float that makes a too-fast approach run the length of the strip. */
    static Real GroundEffectInducedFactor(Real heightOverSpan);

    Vec3 PropwashAt(const Vec3& positionBody, const PropulsionOutput& propulsion,
                    Real spanExtent = 0.0,
                    const Vec3& spanDirectionBody = Vec3::UnitY()) const;

private:
    AircraftDefinition Definition_;
    MassProperties     MassData;
    std::vector<AeroSurface> Surfaces;
    FuselageAero Fuselage;
    LandingGear  Wheels;
    CrashModel   CrashDetector;

    /** Per-section stall hysteresis. Mutable because ComputeForces is logically
     *  const from the caller's point of view. */
    mutable std::vector<bool> Separated;

    /** Downwash VELOCITY at the tail from one wing section's lift [m/s].
     *
     *      epsilon = 2 CL / (pi AR)  =>  w = V epsilon = 4 L / (rho V pi b^2)
     *
     *  Expressing it as a velocity rather than an angle matters: the angle
     *  form has to divide by the aircraft's airspeed, which is nearly zero on
     *  the takeoff roll while the propeller is blowing 20 m/s over the wing
     *  root. That produced a downwash angle of 79 degrees, put the tail at
     *  minus four, and lifted the aircraft off the runway at 4 m/s.
     *
     *  Using each section's OWN local speed keeps it bounded and correct for a
     *  blown wing root. */
    Real DownwashVelocityFrom(Real lift, Real localSpeed, Real density) const;

    Real TotalWingArea = 0.0;
    Real WingAspectRatio = 6.0;
    Real DownwashScale = 1.0;
};

} // namespace rc
