// OpenRC Simulator - one aerodynamic section.
//
// The aircraft is a collection of these, not a set of whole-aircraft
// coefficients. Each one computes its OWN local airflow and its OWN angle of
// attack, which is what makes wing drop, snap roll, spin and asymmetric stall
// fall out of the equations instead of being special-cased.
//
// The local flow is
//
//     V_local = V_air(CG)  +  omega x r  +  propwash
//
// The `omega x r` term is not a refinement: it IS roll, pitch and yaw damping.
// A rolling aircraft sees more angle of attack on the descending wing and less
// on the rising one, which opposes the roll. Get this term right and the damping
// derivatives appear for free.
#pragma once

#include "RCPhysics/Core/Math/Quat.h"
#include "RCPhysics/Core/Math/Vec3.h"
#include "RCPhysics/Input/ChannelTypes.h"
#include "RCPhysics/Physics/Aero/Airfoil.h"
#include "RCPhysics/Physics/Environment/Atmosphere.h"

#include <string>

namespace rc
{
enum class SurfaceRole
{
    Wing,
    HorizontalTail,
    VerticalTail
};

const char* ToString(SurfaceRole role);

/** A control surface hinged on a section.
 *
 *  SIGN CONVENTION: a POSITIVE deflection is trailing edge DOWN in the
 *  section's own frame (towards the section's positive-lift side). `Direction`
 *  multiplies the channel value to produce that deflection, and is what encodes
 *  "the right aileron goes up when the left goes down".
 *
 *  The channel conventions the whole simulator uses:
 *      positive aileron  = roll right
 *      positive elevator = nose up
 *      positive rudder   = nose right
 *  Tests assert each of those against the resulting body moment.
 */
struct ControlSurfaceSpec
{
    RCChannel Channel       = RCChannel::Aileron;
    Real ChordFraction      = 0.25;   ///< hinge line as a fraction of chord
    Real SpanFraction       = 1.0;    ///< how much of the section it covers
    Real Direction          = 1.0;    ///< +1 / -1
    Real MaxDeflection      = 0.3491; ///< 20 deg
    /** Reduced travel on the down-going side, which is how a trainer keeps
     *  adverse yaw manageable. 0 = none, 0.3 = 30 % less. */
    Real Differential       = 0.0;
};

/** Static description of a section. Everything here comes from the aircraft
 *  definition and never changes at runtime. */
struct AeroSurfaceSpec
{
    std::string Name;
    SurfaceRole Role = SurfaceRole::Wing;
    int  AirfoilIndex = 0;

    /** Quarter-chord point relative to the CG, body FRD [m]. */
    Vec3 PositionBody = Vec3::Zero();

    Real Area  = 0.04;   ///< m^2
    Real Chord = 0.21;   ///< m
    Real Span  = 0.19;   ///< m

    Real Incidence = 0.0;   ///< rad, positive leading edge up
    Real Dihedral  = 0.0;   ///< rad, positive raises the tip
    Real Twist     = 0.0;   ///< rad, negative is washout
    Real Sweep     = 0.0;   ///< rad, positive is swept back

    Real EffectiveAspectRatio = 6.0;

    bool HasControl = false;
    ControlSurfaceSpec Control;

    bool InPropwash = false;
};

/** Everything one section produced this step. The debug visualisation and the
 *  validation suite both read this, so it carries more than the force. */
struct SectionResult
{
    Vec3 ForceBody  = Vec3::Zero();   ///< N, body axes
    Vec3 MomentBody = Vec3::Zero();   ///< N*m about the section's own AC

    Vec3 LocalVelocityBody = Vec3::Zero();
    Vec3 LiftDirectionBody = Vec3::Zero();
    Vec3 DragDirectionBody = Vec3::Zero();

    Real Alpha           = 0.0;   ///< rad
    Real LocalSpeed      = 0.0;   ///< m/s, in the section's chordwise plane
    Real DynamicPressure = 0.0;   ///< Pa
    Real Reynolds        = 0.0;
    Real Deflection      = 0.0;   ///< rad, trailing edge down positive

    Real Lift = 0.0;   ///< N
    Real Drag = 0.0;   ///< N

    AeroCoefficients Coefficients;
};

/** Inputs shared by every section on the airframe for a given step. */
struct AeroEnvironment
{
    /** Velocity of the CG relative to the air, BODY axes [m/s]. */
    Vec3 AirVelocityBody = Vec3::Zero();

    /** Body angular rate [rad/s]. */
    Vec3 AngularVelocityBody = Vec3::Zero();

    AtmosphereSample Atmosphere;

    /** How much of the free-air induced flow this section still sees, 0..1.
     *  Ground effect is what lowers it: near the ground the wing's image in
     *  the surface cancels part of its own trailing vortices, so the section
     *  behaves as if its aspect ratio were larger - a steeper lift curve and
     *  less induced drag, both from the one number. 1 is free air. */
    Real InducedFactor = 1.0;
};

class AeroSurface
{
public:
    void Configure(const AeroSurfaceSpec& spec);

    const AeroSurfaceSpec& Spec() const { return SpecData; }

    /** Rotation taking a vector from section axes into body axes. */
    const Quat& SectionToBody() const { return SectionToBodyRotation; }

    /** The span axis in SECTION axes: +Y for a lifting surface, -Z (up) for a
     *  fin. Lift is `span x flow`, which is what makes both work with one
     *  formula and gives the fin the correct weathervaning sign. */
    Vec3 SpanAxisSection() const;

    /** The same axis in BODY coordinates. Used to integrate propeller wake
     *  coverage along the section rather than sampling it at a single point. */
    Vec3 SpanAxisBody() const { return SectionToBodyRotation.Rotate(SpanAxisSection()); }

    /** Turn a channel value into a hinge deflection [rad]. */
    Real DeflectionFor(Real channelValue) const;

    /** Evaluate this section. `separated` carries the stall hysteresis state
     *  across steps and is updated in place.
     *  `propwashBody` is the propeller-induced flow at this section, already in
     *  body axes; zero for sections outside the wake. */
    SectionResult Evaluate(const AeroEnvironment& environment,
                           const Airfoil& airfoil,
                           Real deflection,
                           const Vec3& propwashBody,
                           bool& separated) const;

private:
    AeroSurfaceSpec SpecData;
    Quat SectionToBodyRotation = Quat::Identity();
    Real ControlEffectiveness  = 0.0;
};

} // namespace rc
