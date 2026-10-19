#include "RCPhysics/Physics/Aero/AeroSurface.h"

#include <cmath>

namespace rc
{
namespace
{
    /** Below this the section produces no force. Guards the normalisations and
     *  keeps a stationary aircraft on the runway from generating noise. */
    constexpr Real kMinimumLocalSpeed = 0.05;
}

const char* ToString(SurfaceRole role)
{
    switch (role)
    {
        case SurfaceRole::Wing:           return "wing";
        case SurfaceRole::HorizontalTail: return "horizontal_tail";
        case SurfaceRole::VerticalTail:   return "vertical_tail";
    }
    return "unknown";
}

void AeroSurface::Configure(const AeroSurfaceSpec& spec)
{
    SpecData = spec;

    // Which side of the aircraft this section is on. Dihedral and sweep are
    // mirrored about the centreline; a centreline surface takes the right-hand
    // sense, which is harmless because its dihedral and sweep are zero.
    const Real side = (spec.PositionBody.y >= 0.0) ? 1.0 : -1.0;

    // Section -> body, built in the order the geometry is defined:
    //   1. rigging angle and washout, about the section's spanwise axis
    //   2. sweep, about the section normal
    //   3. dihedral, about the body's roll axis
    //
    // The dihedral sign is what makes dihedral stabilising: for the RIGHT wing
    // the lift vector must tilt INBOARD, which is a NEGATIVE rotation about
    // body X. Get this backwards and sideslip drives the aircraft further into
    // the slip instead of levelling it.
    const Quat rigging  = Quat::FromAxisAngle(Vec3::UnitY(), spec.Incidence + spec.Twist);
    const Quat sweep    = Quat::FromAxisAngle(Vec3::UnitZ(), spec.Sweep * side);
    const Quat dihedral = Quat::FromAxisAngle(Vec3::UnitX(), -spec.Dihedral * side);

    SectionToBodyRotation = (dihedral * sweep * rigging).Normalized();

    ControlEffectiveness = spec.HasControl
                         ? Airfoil::FlapEffectiveness(spec.Control.ChordFraction)
                         : 0.0;
}

Vec3 AeroSurface::SpanAxisSection() const
{
    // A fin's "span" points up, which in FRD is -Z. Using it as the span axis
    // makes `lift = span x flow` produce a force towards -Y in a right
    // sideslip - the tail swings downwind and the nose weathervanes into it.
    return (SpecData.Role == SurfaceRole::VerticalTail) ? Vec3(0.0, 0.0, -1.0)
                                                        : Vec3::UnitY();
}

Real AeroSurface::DeflectionFor(Real channelValue) const
{
    if (!SpecData.HasControl)
    {
        return 0.0;
    }

    const ControlSurfaceSpec& control = SpecData.Control;
    Real deflection = ClampUnit(channelValue) * control.Direction * control.MaxDeflection;

    // Differential: the down-going surface travels less than the up-going one.
    // "Down" here is a positive deflection in the section's own frame.
    if (deflection > 0.0)
    {
        deflection *= (1.0 - Clamp(control.Differential, 0.0, 0.9));
    }
    return deflection;
}

SectionResult AeroSurface::Evaluate(const AeroEnvironment& environment,
                                    const Airfoil& airfoil,
                                    Real deflection,
                                    const Vec3& propwashBody,
                                    bool& separated) const
{
    SectionResult result;
    result.Deflection = deflection;

    // ------------------------------------------------------ local airflow ---
    // The whole point of section-based aerodynamics. omega x r is what produces
    // roll, pitch and yaw damping; propwash is what gives an RC model control
    // authority at almost zero airspeed.
    const Vec3 rotational = Cross(environment.AngularVelocityBody, SpecData.PositionBody);
    const Vec3 localBody  = environment.AirVelocityBody + rotational + propwashBody;
    result.LocalVelocityBody = localBody;

    const Vec3 localSection = SectionToBodyRotation.RotateInverse(localBody);

    // Only the flow in the section's chordwise plane produces lift; the
    // spanwise component runs along the section and does not turn.
    const Vec3 spanAxis = SpanAxisSection();
    const Vec3 inPlane  = localSection - spanAxis * Dot(localSection, spanAxis);
    const Real speed    = inPlane.Length();

    if (speed < kMinimumLocalSpeed || SpecData.Area <= kEpsilon)
    {
        return result;
    }

    const Vec3 flow = inPlane / speed;

    // n = span x chord is the direction positive lift points at zero alpha:
    // "up" for a wing, "left" for a fin.
    const Vec3 liftAtZeroAlpha = Cross(spanAxis, Vec3::UnitX());
    const Real alpha = std::atan2(-Dot(inPlane, liftAtZeroAlpha), Dot(inPlane, Vec3::UnitX()));

    result.Alpha      = alpha;
    result.LocalSpeed = speed;

    // ------------------------------------------------------- coefficients ---
    const Real dynamicPressure = 0.5 * environment.Atmosphere.Density * speed * speed;
    result.DynamicPressure = dynamicPressure;
    result.Reynolds = Atmosphere::ReynoldsNumber(environment.Atmosphere, speed, SpecData.Chord);

    AirfoilQuery query;
    query.Alpha                = alpha;
    query.Reynolds             = result.Reynolds;
    // Scaling the induced flow by k is exactly an aspect ratio of AR / k in
    // both the finite-wing lift slope and the induced drag, so ground effect
    // needs no separate path through the airfoil model. The floor stops a
    // section that is touching the ground from becoming an infinite wing.
    query.AspectRatio          = SpecData.EffectiveAspectRatio
                               / Max(environment.InducedFactor, 0.05);
    query.ControlDeflection    = deflection;
    query.ControlEffectiveness = ControlEffectiveness;
    query.ControlSpanFraction  = SpecData.HasControl ? SpecData.Control.SpanFraction : 0.0;
    query.WasSeparated         = separated;

    const AeroCoefficients coefficients = airfoil.Evaluate(query);
    result.Coefficients = coefficients;
    separated = coefficients.IsSeparated();

    // -------------------------------------------------------------- forces --
    // Lift is perpendicular to the LOCAL flow in the section's lift plane - not
    // perpendicular to the aircraft's velocity, and not "up".
    const Vec3 liftDirection = Cross(spanAxis, flow);
    const Vec3 dragDirection = -flow;

    const Real lift = dynamicPressure * SpecData.Area * coefficients.Cl;
    const Real drag = dynamicPressure * SpecData.Area * coefficients.Cd;
    result.Lift = lift;
    result.Drag = drag;

    const Vec3 forceSection = liftDirection * lift + dragDirection * drag;

    // The section's own pitching moment, about its span axis at the quarter
    // chord. The moment arm to the CG is applied by the caller.
    const Vec3 momentSection = spanAxis
                             * (dynamicPressure * SpecData.Area * SpecData.Chord * coefficients.Cm);

    result.ForceBody  = SectionToBodyRotation.Rotate(forceSection);
    result.MomentBody = SectionToBodyRotation.Rotate(momentSection);
    result.LiftDirectionBody = SectionToBodyRotation.Rotate(liftDirection);
    result.DragDirectionBody = SectionToBodyRotation.Rotate(dragDirection);

    return result;
}

} // namespace rc
