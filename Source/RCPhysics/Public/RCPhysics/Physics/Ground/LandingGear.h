// OpenRC Simulator - wheels, suspension and ground friction.
//
// A single capsule sliding on the terrain is not acceptable: it cannot taxi,
// cannot steer, cannot rotate, and above all cannot GROUND LOOP. That last one
// matters, because the lateral force saturating at mu * N is the whole lesson -
// once the tyre breaks away there is nothing left to stop the yaw, and the
// pilot has to catch it with rudder before it develops.
//
// The terrain query is abstracted so the core stays engine-free. A flat plane
// is the default; the Godot side supplies a raycast provider later.
#pragma once

#include "RCPhysics/Aircraft/AircraftDefinition.h"
#include "RCPhysics/Physics/Dynamics/ForceAccumulator.h"

#include <memory>
#include <vector>

namespace rc
{
/** What the ground looks like under a point. Heights are NED, so the ground
 *  being at Z = 0 means SurfaceHeight = 0 and the normal points at -Z. */
struct GroundSample
{
    Real SurfaceHeight = 0.0;                  ///< world Z of the surface [m]
    Vec3 Normal = Vec3(0.0, 0.0, -1.0);        ///< unit, pointing up out of the ground
    /** Multiplies the wheel's friction. 1 for the mown strip, less for wet
     *  grass, more for tarmac. */
    Real FrictionScale = 1.0;
    /** Multiplies rolling resistance. Long grass is what actually sets a
     *  model's takeoff roll. */
    Real RollingScale = 1.0;
};

class GroundProvider
{
public:
    virtual ~GroundProvider() = default;
    virtual GroundSample Sample(Real north, Real east) const = 0;
};

/** A perfectly flat field. The default, and what the validation suite uses so
 *  that takeoff and landing numbers are reproducible. */
class FlatGround : public GroundProvider
{
public:
    explicit FlatGround(Real surfaceHeight = 0.0) : Height(surfaceHeight) {}

    GroundSample Sample(Real /*north*/, Real /*east*/) const override
    {
        GroundSample sample;
        sample.SurfaceHeight = Height;
        return sample;
    }

private:
    Real Height;
};

struct WheelResult
{
    bool InContact     = false;
    Real Compression   = 0.0;   ///< m
    Real NormalForce   = 0.0;   ///< N
    Real SteeringAngle = 0.0;   ///< rad
    Real RollSpeed     = 0.0;   ///< m/s along the wheel's heading
    Real SlipSpeed     = 0.0;   ///< m/s across it
    bool Skidding      = false;

    Vec3 ForceBody = Vec3::Zero();
    /** Where the force is applied, relative to the CG, body axes. */
    Vec3 ContactPointBody = Vec3::Zero();
};

class LandingGear
{
public:
    void Configure(const std::vector<LandingGearSpec>& wheels);

    size_t WheelCount() const { return Wheels.size(); }
    const LandingGearSpec& Wheel(size_t index) const { return Wheels[index]; }

    /** Evaluate every wheel and push the forces into the accumulator.
     *  Returns the per-wheel detail for the debug view and the tests. */
    std::vector<WheelResult> Evaluate(const RigidBodyState& state,
                                      const ChannelValues& controls,
                                      const GroundProvider& ground,
                                      ForceAccumulator& forces) const;

    /** Total weight the wheels are carrying [N]. Zero once airborne, which is
     *  how the takeoff test knows the aircraft has left the ground. */
    static Real TotalNormalForce(const std::vector<WheelResult>& wheels);

    static bool AnyInContact(const std::vector<WheelResult>& wheels);

private:
    std::vector<LandingGearSpec> Wheels;
};

// -------------------------------------------------------------- crash -------

/** A point on the airframe that must not touch the ground. */
struct HardPoint
{
    std::string Name;
    Vec3 PositionBody = Vec3::Zero();
};

struct CrashResult
{
    bool Crashed = false;
    std::string Reason;
    Real ImpactSpeed = 0.0;   ///< m/s along the ground normal at the moment of contact
    Vec3 PointBody = Vec3::Zero();
};

/** V0.1 crash detection: no structural model, just "did something that is not a
 *  wheel hit the ground, or did a wheel hit it too hard". */
class CrashModel
{
public:
    /** Build hard points from the airframe: wing tips, nose, tail and fin top. */
    void Configure(const AircraftDefinition& definition);

    void SetImpactLimit(Real metresPerSecond) { ImpactLimit = metresPerSecond; }
    Real GetImpactLimit() const { return ImpactLimit; }

    const std::vector<HardPoint>& HardPoints() const { return Points; }

    CrashResult Check(const RigidBodyState& state,
                      const GroundProvider& ground,
                      const std::vector<WheelResult>& wheels) const;

private:
    std::vector<HardPoint> Points;
    /** Descent rate a wheel can absorb. Beyond this the gear folds. */
    Real ImpactLimit = 4.0;
};

} // namespace rc
