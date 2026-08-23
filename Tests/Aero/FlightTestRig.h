// OpenRC Simulator - a minimal flight test rig for the validation suite.
//
// Loads a real aircraft definition and flies it, so the tests measure the same
// thing a pilot would: glide ratio, stall speed, roll rate, trim. Nothing here
// knows about Godot; this is the offline half of Milestone 8's regression gate.
#pragma once

#include "TestHarness.h"

#include "RCPhysics/Aircraft/Aircraft.h"
#include "RCPhysics/Aircraft/AircraftLoader.h"
#include "RCPhysics/Core/Units/Units.h"
#include "RCPhysics/Physics/Dynamics/RigidBodyIntegrator.h"
#include "RCPhysics/Physics/Propulsion/PowerSystem.h"

#include <string>

namespace rctest
{
/** A loaded aircraft plus the state needed to fly it. */
struct FlightTestRig
{
    rc::AircraftDefinition Definition;
    rc::Aircraft           Plane;
    rc::Atmosphere         Air;
    rc::WindField          Wind;            ///< still air unless configured
    rc::RigidBodyState     State;
    rc::ChannelValues      Controls;
    rc::PowerSystem        Power;
    rc::PropulsionOutput   Propulsion;
    bool                   PowerEnabled = false;
    rc::AircraftForces     LastForces;
    rc::FlatGround         Ground{0.0};
    bool                   GroundEnabled = false;

    rc::Real Dt   = 1.0 / 240.0;
    rc::Real Time = 0.0;

    rc::Real Weight() const { return Definition.Mass * rc::units::kGravity; }

    /** Load the shipped Trainer 1500. Returns an empty string on success. */
    std::string LoadTrainer()
    {
        const std::string path = std::string(RC_REPO_ROOT) + "/Data/Aircraft/Trainer1500.json";
        const rc::AircraftLoadResult result = rc::AircraftLoader::LoadFromFile(path, Definition);
        if (!result.Success)
        {
            return result.Describe();
        }
        if (!Plane.Configure(Definition))
        {
            return "aircraft failed to configure";
        }
        Power.Configure(Definition.Propulsion);
        return std::string();
    }

    /** Place the aircraft in still air at a given airspeed and body angle of
     *  attack, wings level, no rotation. World axes coincide with body axes at
     *  zero attitude, so this is a direct way to probe the aerodynamics. */
    void PlaceAtAlpha(rc::Real airspeed, rc::Real alpha, rc::Real altitude = 100.0)
    {
        State = rc::RigidBodyState{};
        State.PositionWorld = rc::Vec3(0.0, 0.0, -altitude);
        State.Orientation = rc::Quat::Identity();
        State.VelocityWorld = rc::Vec3(airspeed * std::cos(alpha), 0.0,
                                       airspeed * std::sin(alpha));
        Plane.ResetAeroState();
        Power.Reset();
        Propulsion = rc::PropulsionOutput{};
    }

    /** A minimal wings-leveller, standing in for a pilot who is holding the
     *  aircraft straight. Not an autopilot for the product - just enough that a
     *  test can ask "does it climb away when flown" rather than "does it climb
     *  away when nobody touches it", which for a powered single is a different
     *  and much less interesting question. */
    void HoldWingsLevel(rc::Real targetPitchStick = 0.0)
    {
        const rc::EulerAngles attitude = State.Attitude();
        const rc::Vec3& rates = State.AngularVelocityBody;

        Controls.Set(rc::RCChannel::Aileron,
                     rc::ClampUnit(-2.0 * attitude.roll - 0.35 * rates.x));
        Controls.Set(rc::RCChannel::Rudder,
                     rc::ClampUnit(-0.6 * rates.z - 1.2 * LastForces.Beta));
        if (targetPitchStick != 0.0)
        {
            Controls.Set(rc::RCChannel::Elevator, targetPitchStick);
        }
    }

    /** Hold a pitch attitude with the elevator. Needed because this aircraft
     *  has the thrust and the tail volume to loop from a small back-stick input
     *  at full power - a test that just held the elevator at a fixed position
     *  would be measuring a loop, not whatever it meant to measure. */
    void HoldPitch(rc::Real targetPitchDegrees)
    {
        const rc::Real error = rc::units::Degrees(targetPitchDegrees) - State.Attitude().pitch;
        Controls.Set(rc::RCChannel::Elevator,
                     rc::ClampUnit(2.5 * error - 0.5 * State.AngularVelocityBody.y));
    }

    /** Reposition WITHOUT touching the power system, so a spooled-up propeller
     *  keeps turning. Used to freeze a flight condition and probe the forces. */
    void FreezeAtAlpha(rc::Real airspeed, rc::Real alpha, rc::Real altitude = 100.0)
    {
        State.PositionWorld = rc::Vec3(0.0, 0.0, -altitude);
        State.Orientation = rc::Quat::Identity();
        State.AngularVelocityBody = rc::Vec3::Zero();
        State.VelocityWorld = rc::Vec3(airspeed * std::cos(alpha), 0.0,
                                       airspeed * std::sin(alpha));
    }

    /** Turn the motor on. Off by default so the aerodynamic tests are clean. */
    void EnablePower(bool enabled) { PowerEnabled = enabled; }

    /** Turn ground contact on. Off by default so the aerodynamic tests fly in
     *  free air without a runway underneath them. */
    void EnableGround(bool enabled) { GroundEnabled = enabled; }

    /** Park the aircraft on the runway with the wheels just touching, at rest. */
    void PlaceOnRunway(rc::Real northing = 0.0)
    {
        State = rc::RigidBodyState{};
        State.Orientation = rc::Quat::Identity();

        // Sit the CG so the lowest wheel is exactly on the surface, then let
        // the suspension settle under its own weight.
        rc::Real lowest = 0.0;
        for (const rc::LandingGearSpec& wheel : Definition.LandingGear)
        {
            lowest = rc::Max(lowest, wheel.PositionBody.z + wheel.Radius);
        }
        State.PositionWorld = rc::Vec3(northing, 0.0, -lowest);
        Plane.ResetAeroState();
        Power.Reset();
        Propulsion = rc::PropulsionOutput{};
    }

    /** Advance the power system and publish its output for the force model. */
    void StepPropulsion()
    {
        if (!PowerEnabled)
        {
            Propulsion = rc::PropulsionOutput{};
            return;
        }

        const rc::AtmosphereSample sample = Air.SampleAboveField(State.AltitudeMetres());
        const rc::Vec3 axis = Definition.Propulsion.Mount.ThrustAxisBody();
        const rc::Vec3 airVelocityBody =
            State.Orientation.RotateInverse(State.VelocityWorld - Wind.SampleWorld(State.PositionWorld));
        const rc::Real axialAirspeed = rc::Dot(airVelocityBody, axis);

        Power.Step(Controls.Throttle(), axialAirspeed, sample.Density, Dt);

        const rc::PowerSystemState& power = Power.State();
        Propulsion.Thrust          = power.Thrust;
        Propulsion.ShaftTorque     = power.ShaftTorque;
        Propulsion.InducedVelocity = power.InducedVelocity;
        Propulsion.WakeSwirl = power.WakeSwirl;
        Propulsion.PropellerRate   = power.PropellerRate;
        Propulsion.Current         = power.Current;
        Propulsion.Voltage         = power.BusVoltage;
        Propulsion.AngularMomentum = Power.AngularMomentum();
    }

    /** Force evaluation without advancing time. */
    rc::AircraftForces Evaluate()
    {
        LastForces = Plane.ComputeForces(State, Controls, Air, Wind, Propulsion,
                                         GroundEnabled ? &Ground : nullptr);
        return LastForces;
    }

    void Step()
    {
        StepPropulsion();
        LastForces = Plane.ComputeForces(State, Controls, Air, Wind, Propulsion,
                                         GroundEnabled ? &Ground : nullptr);
        rc::StepSemiImplicitEuler(State, Plane.GetMassProperties(), LastForces.Total, Dt);
        Wind.Advance(Dt);
        Time += Dt;
    }

    void StepFor(rc::Real seconds)
    {
        const int steps = static_cast<int>(seconds / Dt + 0.5);
        for (int i = 0; i < steps; ++i) { Step(); }
    }

    rc::Real Airspeed() const { return LastForces.Airspeed; }
    rc::Real Altitude() const { return State.AltitudeMetres(); }
};

/** One point on the trimmed glide polar. */
struct TrimPoint
{
    bool Converged = false;
    rc::Real Alpha      = 0.0;   ///< rad
    rc::Real Elevator   = 0.0;   ///< stick, -1..1
    rc::Real Speed      = 0.0;   ///< m/s
    rc::Real Lift       = 0.0;   ///< N
    rc::Real Drag       = 0.0;   ///< N
    rc::Real GlideRatio = 0.0;
    rc::Real SinkRate   = 0.0;   ///< m/s
    rc::Real LiftCoefficient = 0.0;
    rc::Real StalledFraction = 0.0;
};

/** Solve for the trimmed, power-off condition at a given angle of attack:
 *  the elevator that zeroes the pitching moment, and the airspeed at which the
 *  resulting lift supports the weight along the glide path.
 *
 *  Two nested bisections rather than a Newton solve: the pitching moment is not
 *  monotone once a section separates, and bisection degrades gracefully where
 *  Newton would run away. */
inline TrimPoint TrimAtAlpha(FlightTestRig& rig, rc::Real alpha,
                             rc::Real initialSpeed = 14.0)
{
    using namespace rc;

    TrimPoint point;
    point.Alpha = alpha;

    Real speed = initialSpeed;

    for (int outer = 0; outer < 40; ++outer)
    {
        // --- inner: bisect the elevator to zero the pitching moment ---------
        Real low = -1.0, high = 1.0;
        Real elevator = 0.0;

        rig.Controls.Set(RCChannel::Elevator, low);
        rig.PlaceAtAlpha(speed, alpha);
        const Real momentLow = rig.Evaluate().Total.Moment.y;

        rig.Controls.Set(RCChannel::Elevator, high);
        rig.PlaceAtAlpha(speed, alpha);
        const Real momentHigh = rig.Evaluate().Total.Moment.y;

        if (momentLow * momentHigh > 0.0)
        {
            // No trim within the elevator's travel: saturate towards zero.
            elevator = (std::fabs(momentLow) < std::fabs(momentHigh)) ? low : high;
        }
        else
        {
            for (int i = 0; i < 50; ++i)
            {
                elevator = 0.5 * (low + high);
                rig.Controls.Set(RCChannel::Elevator, elevator);
                rig.PlaceAtAlpha(speed, alpha);
                const Real moment = rig.Evaluate().Total.Moment.y;
                if ((moment > 0.0) == (momentLow > 0.0)) { low = elevator; }
                else                                     { high = elevator; }
            }
        }

        rig.Controls.Set(RCChannel::Elevator, elevator);
        rig.PlaceAtAlpha(speed, alpha);
        const AircraftForces forces = rig.Evaluate();

        // --- outer: the speed at which this lift supports the weight --------
        const Real lift = forces.TotalLift;
        if (lift <= 1e-6)
        {
            point.Elevator = elevator;
            return point;   // cannot support the aircraft at this alpha
        }

        // Along a glide path, lift balances W*cos(gamma).
        const Real glideRatio = lift / Max(forces.TotalDrag, 1e-9);
        const Real gamma = std::atan2(1.0, glideRatio);   // descent angle
        const Real required = rig.Weight() * std::cos(gamma);

        const Real newSpeed = speed * std::sqrt(required / lift);
        const Real change = std::fabs(newSpeed - speed);
        speed = Clamp(0.5 * (speed + newSpeed), 2.0, 60.0);

        if (change < 1e-4)
        {
            point.Converged = true;
            point.Elevator   = elevator;
            point.Speed      = speed;
            point.Lift       = lift;
            point.Drag       = forces.TotalDrag;
            point.GlideRatio = glideRatio;
            point.SinkRate   = speed / std::sqrt(1.0 + glideRatio * glideRatio);
            point.LiftCoefficient = lift
                / Max(0.5 * units::kSeaLevelDensity * Sq(speed) * rig.Definition.WingArea, 1e-9);
            point.StalledFraction = forces.StalledWingFraction;
            return point;
        }
    }

    point.Speed = speed;
    return point;
}

} // namespace rctest
