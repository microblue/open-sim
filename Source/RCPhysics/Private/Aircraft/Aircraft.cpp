#include "RCPhysics/Aircraft/Aircraft.h"

#include "RCPhysics/Core/Log.h"

#include <cmath>

namespace rc
{
namespace
{
    /** The slipstream contracts just behind the disc before expanding again.
     *  Momentum theory gives 1/sqrt(2) far downstream; this is the near-field
     *  value that matters for a tail one metre back. */
    constexpr Real kSlipstreamContraction = 0.85;

    /** The wake edge is a shear layer, not a knife edge, so a little smoothing
     *  is physical. Most of the partial-immersion behaviour now comes from
     *  integrating along the section's span, so this stays narrow. */
    Real WakeEdgeFalloff(Real radius, Real wakeRadius)
    {
        if (wakeRadius <= kEpsilon) { return 0.0; }
        const Real t = radius / wakeRadius;
        if (t >= 1.0) { return 0.0; }
        if (t <= 0.85) { return 1.0; }
        const Real x = (1.0 - t) / 0.15;
        return x * x * (3.0 - 2.0 * x);
    }

    /** How many points to sample along a section when integrating its immersion
     *  in the wake. Five is enough to make the result smooth, and is nothing
     *  next to the cost of the aerodynamics itself. */
    constexpr int kWakeSamplesPerSection = 5;

    /** Tangential velocity in the slipstream at a radius.
     *
     *  A pure free vortex (v ~ 1/r) is right in the outer wake but diverges on
     *  the axis, where a real propeller has a spinner and does no work at all.
     *  This is the standard Rankine-style profile: proportional to r near the
     *  axis, peaking around mid radius, decaying as 1/r outside.
     *
     *      v_theta(r) = C r / (r^2 + rh^2)
     *
     *  normalised so that at the 0.7 R effective radius it matches the momentum
     *  theory value Q / (mdot r). Without the inner rolloff, sections passing
     *  close to the wake axis - which the horizontal tail does - picked up an
     *  enormous and wildly asymmetric swirl. */
    Real SwirlSpeedAt(Real radius, Real circulation, Real discRadius)
    {
        const Real hubRadius = 0.40 * Max(discRadius, kEpsilon);
        const Real effectiveRadius = 0.70 * Max(discRadius, kEpsilon);
        const Real normalisation =
            (Sq(effectiveRadius) + Sq(hubRadius)) / Max(Sq(effectiveRadius), kEpsilon);
        return normalisation * circulation * radius / Max(Sq(radius) + Sq(hubRadius), kEpsilon);
    }
}

bool Aircraft::Configure(const AircraftDefinition& definition)
{
    Definition_ = definition;
    MassData = definition.BuildMassProperties();

    Surfaces.clear();
    Surfaces.reserve(definition.Surfaces.size());
    TotalWingArea = 0.0;

    for (const AeroSurfaceSpec& spec : definition.Surfaces)
    {
        AeroSurface surface;
        surface.Configure(spec);
        Surfaces.push_back(surface);
        if (spec.Role == SurfaceRole::Wing) { TotalWingArea += spec.Area; }
    }

    Fuselage.Configure(definition.Fuselage);
    Wheels.Configure(definition.LandingGear);
    CrashDetector.Configure(definition);

    WingAspectRatio = SafeDivide(Sq(definition.WingSpan), definition.WingArea, 6.0);
    DownwashScale = (definition.DownwashScale > 0.0) ? definition.DownwashScale : 1.0;

    ResetAeroState();

    return !Surfaces.empty() && MassData.IsValid();
}

void Aircraft::ResetAeroState()
{
    Separated.assign(Surfaces.size(), false);
}

void Aircraft::RestoreAeroState(const std::vector<bool>& state)
{
    if (state.size() == Separated.size())
    {
        Separated = state;
    }
}

Real Aircraft::DownwashVelocityFrom(Real lift, Real localSpeed, Real density) const
{
    const Real span = Max(Definition_.WingSpan, 0.05);
    const Real denominator = density * Max(localSpeed, 0.5) * kPi * Sq(span);
    return SafeDivide(4.0 * lift, denominator, 0.0) * DownwashScale;
}

Vec3 Aircraft::PropwashAt(const Vec3& positionBody, const PropulsionOutput& propulsion,
                          Real spanExtent, const Vec3& spanDirectionBody) const
{
    const PropwashSpec& wash = Definition_.Propulsion.Propwash;
    if (!wash.Enabled || propulsion.InducedVelocity <= 0.0)
    {
        return Vec3::Zero();
    }

    const MotorMountSpec& mount = Definition_.Propulsion.Mount;
    const Vec3 axis = mount.ThrustAxisBody();
    const Real discRadius = 0.5 * Definition_.Propulsion.Propeller.Diameter;

    // Integrate the wake ALONG the section rather than sampling it at the
    // centroid. A section lying across the edge of the wake is only partly
    // immersed, and the swirl varies strongly across its span - point sampling
    // turns both into knife edges. Two degrees of right thrust displaces the
    // wake axis by 34 mm at the tail, which point sampling turned into a ten
    // degree left/right difference in angle of attack and flipped the aircraft
    // onto its back during the takeoff roll.
    const int samples = (spanExtent > kEpsilon) ? kWakeSamplesPerSection : 1;
    const Vec3 spanDirection = spanDirectionBody.Normalized(Vec3::UnitY());

    Vec3 sumVelocity = Vec3::Zero();
    Real sumSquaredSpeed = 0.0;

    for (int i = 0; i < samples; ++i)
    {
        const Real fraction = (samples == 1)
            ? 0.0
            : static_cast<Real>(i) / static_cast<Real>(samples - 1) - 0.5;
        const Vec3 point = positionBody + spanDirection * (fraction * spanExtent);

        const Vec3 offset = point - mount.PositionBody;

        // The thrust axis points FORWARD, so the slipstream extends in the
        // NEGATIVE axis direction.
        const Real axialDistance = -Dot(offset, axis);
        if (axialDistance <= 0.0)
        {
            continue;   // ahead of the disc; nothing there yet
        }

        // offset = radial - axis * axial, so the radial part is:
        const Vec3 radialOffset = offset + axis * axialDistance;
        const Real radius = radialOffset.Length();
        const Real wakeRadius = discRadius * kSlipstreamContraction
                              + axialDistance * std::tan(wash.ConeHalfAngle);

        const Real coverage = WakeEdgeFalloff(radius, wakeRadius) * wash.Strength;
        if (coverage <= 0.0)
        {
            continue;
        }

        // Axial: the fully developed wake carries twice the disc's induced
        // velocity. Expressed as an addition to the section's RELATIVE airflow,
        // so it is positive along the thrust axis - the section behaves as
        // though the aircraft were flying faster.
        Vec3 local = axis * (2.0 * propulsion.InducedVelocity * coverage);

        // Swirl, as a free vortex: v_theta = (Q/mdot) / r. The wake rotates
        // with the propeller, so the AIR moves sideways and the section's
        // velocity relative to that air moves the other way - hence the minus.
        // This is what yaws a model left on a hard throttle application.
        if (std::fabs(propulsion.WakeSwirl) > kEpsilon && radius > kEpsilon)
        {
            const Real swirlSpeed = SwirlSpeedAt(radius, propulsion.WakeSwirl, discRadius);
            const Vec3 tangential = Cross(axis, radialOffset).Normalized(Vec3::Zero());
            local -= tangential * (swirlSpeed * wash.SwirlFactor * coverage);
        }

        sumVelocity += local;
        sumSquaredSpeed += local.LengthSquared();
    }

    if (sumVelocity.IsNearlyZero() || sumSquaredSpeed <= 0.0)
    {
        return Vec3::Zero();
    }

    // Take the mean DIRECTION but the root-mean-square MAGNITUDE. Force goes as
    // the square of velocity, so the RMS is what makes a partly immersed
    // section produce the force an area integral would have given, while a
    // plain vector mean would under-count it.
    const Vec3 direction = sumVelocity.Normalized(Vec3::Zero());
    const Real speed = std::sqrt(sumSquaredSpeed / static_cast<Real>(samples));
    return direction * speed;
}

AircraftForces Aircraft::ComputeForces(const RigidBodyState& state,
                                       const ChannelValues& controls,
                                       const Atmosphere& atmosphere,
                                       const WindField& wind,
                                       const PropulsionOutput& propulsion,
                                       const GroundProvider* ground) const
{
    AircraftForces forces;
    forces.Sections.reserve(Surfaces.size());

    const Real altitude = state.AltitudeMetres();
    const AtmosphereSample air = atmosphere.SampleAboveField(altitude);

    // Whole-aircraft air data, for the HUD and the validation suite.
    const Vec3 windAtCG = wind.SampleWorld(state.PositionWorld);
    const Vec3 airVelocityCG = state.Orientation.RotateInverse(state.VelocityWorld - windAtCG);
    forces.Airspeed = airVelocityCG.Length();
    if (forces.Airspeed > kEpsilon)
    {
        forces.Alpha = std::atan2(airVelocityCG.z, airVelocityCG.x);
        forces.Beta  = std::asin(ClampUnit(airVelocityCG.y / forces.Airspeed));
    }

    Real stalledArea = 0.0;
    Real wingLift = 0.0;

    // Sections are evaluated in two passes. The wing goes first because the
    // tail flies in its downwash, and that coupling is not a detail: it roughly
    // halves how much elevator a trim change costs, and it is what produces the
    // nose-down pitch break when the wing lets go and the downwash disappears.
    forces.Sections.resize(Surfaces.size());
    Real downwashVelocity = 0.0;

    for (int pass = 0; pass < 2; ++pass)
    {
        if (pass == 1)
        {
            const Real dynamicPressureAtCG =
                0.5 * air.Density * Sq(Max(forces.Airspeed, 1.0));
            forces.WingLiftCoefficient = SafeDivide(
                wingLift, dynamicPressureAtCG * Definition_.WingArea, 0.0);
            forces.DownwashVelocity = downwashVelocity;
            forces.DownwashAngle =
                std::atan2(downwashVelocity, Max(forces.Airspeed, 1.0));
        }

    for (size_t i = 0; i < Surfaces.size(); ++i)
    {
        const AeroSurface& surface = Surfaces[i];
        const AeroSurfaceSpec& spec = surface.Spec();

        const bool isWing = (spec.Role == SurfaceRole::Wing);
        if ((pass == 0) != isWing) { continue; }

        // Sample the wind where THIS section is. A gust whose length scale is
        // comparable to the span reaches one wing before the other, which is
        // what makes turbulence roll the aircraft.
        const Vec3 sectionWorld = state.PositionWorld
                                + state.Orientation.Rotate(spec.PositionBody);
        const Vec3 windHere = wind.SampleWorld(sectionWorld);

        AeroEnvironment environment;
        environment.AirVelocityBody = state.Orientation.RotateInverse(
            state.VelocityWorld - windHere);
        environment.AngularVelocityBody = state.AngularVelocityBody;
        environment.Atmosphere = air;

        const Real channelValue = spec.HasControl
                                ? controls.Get(spec.Control.Channel)
                                : 0.0;
        const Real deflection = surface.DeflectionFor(channelValue);

        Vec3 propwash = spec.InPropwash
                      ? PropwashAt(spec.PositionBody, propulsion, spec.Span,
                                   surface.SpanAxisBody())
                      : Vec3::Zero();

        // Downwash: the air behind the wing moves downward, so the tail's
        // velocity RELATIVE to that air gains an upward component - which is
        // why the sign here is negative Z. It is a VELOCITY, not an angle
        // multiplied by airspeed, so that it stays bounded when the propeller
        // is blowing over a wing that is barely moving.
        if (spec.Role == SurfaceRole::HorizontalTail && downwashVelocity != 0.0)
        {
            propwash += Vec3(0.0, 0.0, -downwashVelocity);
        }

        bool separated = Separated[i];
        const SectionResult result = surface.Evaluate(
            environment, Definition_.Airfoils[static_cast<size_t>(spec.AirfoilIndex)],
            deflection, propwash, separated);
        Separated[i] = separated;

        forces.Accumulator.AddForceAtOffset(result.ForceBody, spec.PositionBody,
                                            ForceSource::Aerodynamic);
        forces.Accumulator.AddMoment(result.MomentBody, ForceSource::Aerodynamic);

        if (isWing)
        {
            stalledArea += spec.Area * result.Coefficients.SeparationFraction;
            // Lift about the aircraft's own vertical, which is what the wing
            // lift coefficient is referred to.
            wingLift += -result.ForceBody.z;
            // Each section contributes downwash in proportion to the lift it is
            // actually making, at ITS OWN local speed - which for a section in
            // the propeller wake is far higher than the aircraft's airspeed.
            downwashVelocity += DownwashVelocityFrom(result.Lift, result.LocalSpeed,
                                                     air.Density);
        }
        forces.Sections[i] = result;
    }
    }

    forces.StalledWingFraction = SafeDivide(stalledArea, TotalWingArea, 0.0);

    // ------------------------------------------------------------ fuselage --
    {
        AeroEnvironment environment;
        environment.AirVelocityBody = airVelocityCG;
        environment.AngularVelocityBody = state.AngularVelocityBody;
        environment.Atmosphere = air;

        forces.Fuselage = Fuselage.Evaluate(environment);
        forces.Accumulator.AddForceAtOffset(forces.Fuselage.ForceBody,
                                            Definition_.Fuselage.PositionBody,
                                            ForceSource::Aerodynamic);
        forces.Accumulator.AddMoment(forces.Fuselage.MomentBody, ForceSource::Aerodynamic);
    }

    // ---------------------------------------------------------- propulsion --
    {
        const MotorMountSpec& mount = Definition_.Propulsion.Mount;
        const PropellerSpec& propeller = Definition_.Propulsion.Propeller;
        const Vec3 axis = mount.ThrustAxisBody();
        const Real rotationSign = propeller.Clockwise ? 1.0 : -1.0;

        if (propulsion.Thrust != 0.0)
        {
            // P-factor. At a positive angle of attack the descending blade
            // meets the air at a higher local angle than the ascending one, so
            // it produces more thrust and the thrust centre moves sideways.
            // For a propeller turning clockwise seen from behind, the blade
            // descends on the RIGHT, so the centre moves right - and thrust
            // applied to the right of the CG yaws the nose LEFT. That is the
            // classic left-turning tendency on a climb-out.
            //
            // The gain is empirical; a blade-element propeller model would
            // produce it directly, and that is the eventual replacement.
            constexpr Real kPFactorGain = 0.25;
            const Real lateralOffset = kPFactorGain * propeller.Diameter
                                     * std::sin(forces.Alpha) * rotationSign;

            const Vec3 thrustPoint = mount.PositionBody + Vec3(0.0, lateralOffset, 0.0);
            forces.Accumulator.AddForceAtOffset(axis * propulsion.Thrust, thrustPoint,
                                                ForceSource::Propulsion);
        }

        if (propulsion.ShaftTorque != 0.0)
        {
            // The airframe feels the reaction to the torque driving the
            // propeller: a clockwise propeller rolls the aircraft left.
            forces.Accumulator.AddMoment(axis * (-rotationSign * propulsion.ShaftTorque),
                                         ForceSource::Propulsion);
        }

        if (propulsion.AngularMomentum != 0.0)
        {
            // Gyroscopic precession. The spinning propeller resists changes of
            // attitude, and the reaction on the airframe is -Omega x H. Raising
            // the tail of a taildragger with a clockwise propeller yaws it left
            // by exactly this term.
            const Vec3 angularMomentum = axis * propulsion.AngularMomentum;
            forces.Accumulator.AddMoment(
                -Cross(state.AngularVelocityBody, angularMomentum),
                ForceSource::Propulsion);
        }
    }

    // -------------------------------------------------------------- ground --
    if (ground != nullptr)
    {
        forces.Wheels = Wheels.Evaluate(state, controls, *ground, forces.Accumulator);
        forces.WeightOnWheels = LandingGear::TotalNormalForce(forces.Wheels);
        forces.OnGround = LandingGear::AnyInContact(forces.Wheels);
    }

    forces.Total = forces.Accumulator.GetTotal();

    // ------------------------------------------------- lift and drag axes ---
    // Resolve the aerodynamic force into wind axes so the validation suite can
    // read L/D without repeating the geometry.
    const Wrench aero = forces.Accumulator.GetBySource(ForceSource::Aerodynamic);
    if (forces.Airspeed > kEpsilon)
    {
        const Vec3 flow = airVelocityCG / forces.Airspeed;
        forces.TotalDrag = -Dot(aero.Force, flow);
        const Vec3 liftAxis = Cross(Vec3::UnitY(), flow).Normalized(Vec3(0.0, 0.0, -1.0));
        forces.TotalLift = Dot(aero.Force, liftAxis);
    }

    return forces;
}

} // namespace rc
