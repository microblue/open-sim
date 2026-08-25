#include "RCPhysics/Physics/Ground/LandingGear.h"

#include "RCPhysics/Core/Log.h"

#include <algorithm>
#include <cmath>

namespace rc
{
namespace
{
    /** Slip speed at which the tyre reaches full sliding friction. Below it the
     *  force builds proportionally, which is what stops a parked model from
     *  buzzing on the spot. */
    constexpr Real kSlipReferenceSpeed = 0.35;

    /** Rolling speed over which rolling resistance reaches full value. Using a
     *  smooth ramp rather than a sign() removes the chatter a stationary wheel
     *  would otherwise produce. */
    constexpr Real kRollReferenceSpeed = 0.15;

    Real SmoothStep(Real edge0, Real edge1, Real x)
    {
        if (edge1 - edge0 <= kEpsilon) { return x < edge0 ? 0.0 : 1.0; }
        const Real t = Clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }
}

void LandingGear::Configure(const std::vector<LandingGearSpec>& wheels)
{
    Wheels = wheels;
}

std::vector<WheelResult> LandingGear::Evaluate(const RigidBodyState& state,
                                               const ChannelValues& controls,
                                               const GroundProvider& ground,
                                               ForceAccumulator& forces) const
{
    std::vector<WheelResult> results;
    results.reserve(Wheels.size());

    for (const LandingGearSpec& spec : Wheels)
    {
        WheelResult result;

        // ---- where is the wheel, and where is the ground under it? --------
        const Vec3 offsetWorld = state.Orientation.Rotate(spec.PositionBody);
        const Vec3 centreWorld = state.PositionWorld + offsetWorld;
        const GroundSample sample = ground.Sample(centreWorld.x, centreWorld.y);

        // NED: down is +Z, so the wheel touches when its lowest point has
        // reached or passed the surface height.
        const Real lowestPoint = centreWorld.z + spec.Radius;
        result.Compression = lowestPoint - sample.SurfaceHeight;

        if (result.Compression <= 0.0)
        {
            results.push_back(result);
            continue;
        }
        result.InContact = true;
        // Past full travel the strut is on its stops and gets much stiffer;
        // clamping instead would let the aircraft sink through the ground.
        const Real travel = Min(result.Compression, Max(spec.MaxTravel, 1e-4));
        const Real overTravel = Max(result.Compression - travel, 0.0);

        // ---- contact point velocity ---------------------------------------
        const Vec3 contactBody = spec.PositionBody + Vec3(0.0, 0.0, spec.Radius);
        const Vec3 contactWorld = state.VelocityWorld
            + state.Orientation.Rotate(Cross(state.AngularVelocityBody, contactBody));
        const Vec3 contactVelocityBody = state.Orientation.RotateInverse(contactWorld);

        const Vec3 normalBody = state.Orientation.RotateInverse(sample.Normal);
        const Real closingSpeed = -Dot(contactVelocityBody, normalBody);

        // ---- suspension ----------------------------------------------------
        // Damping only resists compression. Letting it pull would glue the
        // aircraft to the ground on rebound.
        const Real spring = spec.SpringRate * travel
                          + spec.SpringRate * 12.0 * overTravel;
        const Real damper = spec.DamperRate * Max(closingSpeed, 0.0);
        result.NormalForce = Max(spring + damper, 0.0);

        Vec3 wheelForce = normalBody * result.NormalForce;

        // ---- steering ------------------------------------------------------
        if (spec.Steerable && spec.MaxSteering > 0.0)
        {
            result.SteeringAngle = ClampUnit(controls.Get(spec.SteeringChannel))
                                 * spec.MaxSteering;
        }

        // ---- rolling and lateral directions, in the ground plane ----------
        const Vec3 headingRaw(std::cos(result.SteeringAngle),
                              std::sin(result.SteeringAngle), 0.0);
        const Vec3 rollDirection =
            (headingRaw - normalBody * Dot(headingRaw, normalBody)).Normalized(Vec3::UnitX());
        const Vec3 lateralDirection = Cross(normalBody, rollDirection).Normalized(Vec3::UnitY());

        result.RollSpeed = Dot(contactVelocityBody, rollDirection);
        result.SlipSpeed = Dot(contactVelocityBody, lateralDirection);

        // ---- rolling resistance -------------------------------------------
        // Grass is what actually sets a model's takeoff roll, far more than
        // anything about the tyre.
        const Real rollingScale = SmoothStep(0.0, kRollReferenceSpeed,
                                             std::fabs(result.RollSpeed));
        const Real rollingResistance = spec.RollingResistance * sample.RollingScale
                                     * result.NormalForce * rollingScale;
        wheelForce -= rollDirection * (rollingResistance * Sign(result.RollSpeed));

        // ---- lateral friction, and the break-away that allows a ground loop --
        const Real slip = std::fabs(result.SlipSpeed);
        const Real frictionScale = sample.FrictionScale;
        // Static grip until the tyre breaks away, then the lower sliding value.
        const Real blend = SmoothStep(kSlipReferenceSpeed, 3.0 * kSlipReferenceSpeed, slip);
        const Real coefficient = Lerp(spec.FrictionStatic, spec.FrictionDynamic, blend)
                               * frictionScale;
        result.Skidding = blend > 0.5;

        // Builds linearly with slip and then SATURATES. The saturation is the
        // point: once it is reached the wheel cannot generate any more side
        // force, and nothing stops the aircraft swapping ends.
        const Real lateralMagnitude = coefficient * result.NormalForce
                                    * Min(slip / kSlipReferenceSpeed, 1.0);
        wheelForce -= lateralDirection * (lateralMagnitude * Sign(result.SlipSpeed));

        result.ForceBody = wheelForce;
        result.ContactPointBody = contactBody;

        forces.AddForceAtOffset(wheelForce, contactBody, ForceSource::Ground);
        results.push_back(result);
    }

    return results;
}

Real LandingGear::TotalNormalForce(const std::vector<WheelResult>& wheels)
{
    Real total = 0.0;
    for (const WheelResult& wheel : wheels) { total += wheel.NormalForce; }
    return total;
}

bool LandingGear::AnyInContact(const std::vector<WheelResult>& wheels)
{
    return std::any_of(wheels.begin(), wheels.end(),
                       [](const WheelResult& wheel) { return wheel.InContact; });
}

// ---------------------------------------------------------------- crash -----

void CrashModel::Configure(const AircraftDefinition& definition)
{
    Points.clear();

    // Wing tips: the outermost section, extended to the true tip.
    Real leftMost = 0.0, rightMost = 0.0;
    Vec3 leftTip = Vec3::Zero(), rightTip = Vec3::Zero();
    Real furthestAft = 0.0;
    Vec3 tailPoint = Vec3::Zero();
    Real highest = 0.0;
    Vec3 finTop = Vec3::Zero();

    for (const AeroSurfaceSpec& surface : definition.Surfaces)
    {
        const Vec3& p = surface.PositionBody;
        if (surface.Role == SurfaceRole::Wing)
        {
            const Real tipY = p.y + Sign(p.y) * 0.5 * surface.Span;
            if (tipY > rightMost) { rightMost = tipY; rightTip = Vec3(p.x, tipY, p.z); }
            if (tipY < leftMost)  { leftMost = tipY;  leftTip  = Vec3(p.x, tipY, p.z); }
        }
        if (p.x < furthestAft) { furthestAft = p.x; tailPoint = p; }
        if (surface.Role == SurfaceRole::VerticalTail)
        {
            const Real top = p.z - 0.5 * surface.Span;
            if (top < highest) { highest = top; finTop = Vec3(p.x, p.y, top); }
        }
    }

    if (rightMost > 0.0) { Points.push_back({"wing_tip_right", rightTip}); }
    if (leftMost < 0.0)  { Points.push_back({"wing_tip_left", leftTip}); }
    if (furthestAft < 0.0) { Points.push_back({"tail", tailPoint}); }
    if (highest < 0.0) { Points.push_back({"fin_top", finTop}); }

    // The propeller disc and the nose. Hitting either ends the flight.
    const Vec3 mount = definition.Propulsion.Mount.PositionBody;
    Points.push_back({"propeller", mount + Vec3(0.0, 0.0,
                      0.5 * definition.Propulsion.Propeller.Diameter)});
    Points.push_back({"nose", mount});

    // --------------------------------------------------------- the hull --
    // Everything above, plus the fuselage itself. The crash points alone are a
    // sparse frame: a body resting on them would have the fuselage through the
    // ground between the nose and the tail. These fill it in.
    //
    // They are NOT crash points. The aircraft stands on its wheels with the
    // belly a few centimetres clear, and a belly that counted as an impact
    // would have it wrecked before it had moved - which is exactly the bug the
    // spawn code hit once already.
    Hull = Points;

    const FuselageSpec& body = definition.Fuselage;
    // Circular-equivalent radius from the frontal area. Close enough for a
    // fuselage that is roughly as tall as it is wide, which a trainer is.
    const Real radius = std::sqrt(std::max(body.FrontalArea, Real(1e-6)) / Real(3.14159265358979));

    // Three stations: nose, centre and tail, top and bottom at each, so the
    // hull holds the aircraft up whichever way it comes to rest.
    const Real stations[3] = { Real(0.42), Real(0.0), Real(-0.42) };
    for (int i = 0; i < 3; ++i)
    {
        const Vec3 station = body.PositionBody + Vec3(stations[i] * body.Length, 0.0, 0.0);
        Hull.push_back({"belly", station + Vec3(0.0, 0.0, radius)});
        Hull.push_back({"spine", station - Vec3(0.0, 0.0, radius)});
    }

    // Wing tips top and bottom, so an inverted wreck rests on its wing rather
    // than sinking to the fin.
    if (rightMost > 0.0) { Hull.push_back({"wing_tip_right_upper", rightTip - Vec3(0, 0, radius)}); }
    if (leftMost  < 0.0) { Hull.push_back({"wing_tip_left_upper",  leftTip  - Vec3(0, 0, radius)}); }
}

CrashResult CrashModel::Check(const RigidBodyState& state,
                              const GroundProvider& ground,
                              const std::vector<WheelResult>& wheels) const
{
    CrashResult result;

    // A wheel arriving too fast folds the gear. 4 m/s is a heavy arrival for a
    // 1.35 kg model - survivable on grass, but not something to build a habit on.
    for (const WheelResult& wheel : wheels)
    {
        if (!wheel.InContact) { continue; }
        if (wheel.Compression > 0.0)
        {
            const Real descent = state.VelocityWorld.z;
            if (descent > ImpactLimit)
            {
                result.Crashed = true;
                result.Reason = "landing gear collapsed on touchdown";
                result.ImpactSpeed = descent;
                result.PointBody = wheel.ContactPointBody;
                return result;
            }
        }
    }

    // Anything that is not a wheel touching the ground is a crash. A tree is
    // part of the ground for this purpose - the terrain ground raises its
    // surface to the canopy - but it deserves its own reason.
    for (const HardPoint& point : Points)
    {
        const Vec3 world = state.PositionWorld + state.Orientation.Rotate(point.PositionBody);
        const GroundSample sample = ground.Sample(world.x, world.y);
        if (world.z >= sample.SurfaceHeight)
        {
            result.Crashed = true;
            result.Reason = point.Name + (ground.IsObstacle(world.x, world.y)
                                          ? " struck a tree"
                                          : " struck the ground");
            result.ImpactSpeed = state.VelocityWorld.Length();
            result.PointBody = point.PositionBody;
            return result;
        }
    }

    return result;
}

} // namespace rc
