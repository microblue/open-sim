// OpenRC Simulator - battery, ESC, motor and propeller as one system.
//
// The four parts cannot be solved separately: the propeller's torque sets the
// motor's current, the current sags the battery, the sag changes the motor's
// speed, and that changes the propeller's torque again.
//
// Rather than solving that loop to equilibrium every step, the propeller's
// angular rate is a STATE and is integrated:
//
//     I_prop * dOmega/dt = Q_motor(Omega, throttle) - Q_prop(Omega, V)
//
// which is both simpler and more honest: it reproduces the spool-up lag, and it
// is why chopping the throttle on final does not remove the propwash instantly.
//
// The update is linearly implicit. Explicit Euler on this system is stable at
// 240 Hz but only marginally, and would go unstable at 120 Hz - which would
// make the physics rate change the aircraft, exactly what the fixed timestep
// exists to prevent.
#pragma once

#include "RCPhysics/Aircraft/AircraftDefinition.h"
#include "RCPhysics/Physics/Propulsion/Propeller.h"

namespace rc
{
struct PowerSystemState
{
    Real PropellerRate    = 0.0;   ///< rad/s
    Real Rpm              = 0.0;
    Real Thrust           = 0.0;   ///< N
    Real ShaftTorque      = 0.0;   ///< N*m the airframe feels in reaction
    Real Current          = 0.0;   ///< A
    Real BusVoltage       = 0.0;   ///< V under load
    Real ElectricalPower  = 0.0;   ///< W
    Real MechanicalPower  = 0.0;   ///< W
    Real InducedVelocity  = 0.0;   ///< m/s at the disc
    Real WakeSwirl        = 0.0;   ///< m^2/s circulation, signed with the rotation
    Real AdvanceRatio     = 0.0;
    Real StateOfCharge    = 1.0;   ///< 0..1
    bool CurrentLimited   = false;
};

class PowerSystem
{
public:
    void Configure(const PropulsionSpec& spec);
    const PropulsionSpec& Spec() const { return SpecData; }
    const Propeller& GetPropeller() const { return Prop; }

    /** Back to a full battery and a stopped propeller. */
    void Reset();

    /** Advance one fixed step.
     *  `throttle` is 0..1, `axialAirspeed` is the component of the aircraft's
     *  airspeed along the thrust axis [m/s]. */
    void Step(Real throttle, Real axialAirspeed, Real density, Real dt);

    const PowerSystemState& State() const { return Current; }

    /** Terminal voltage at the present state of charge, off load. */
    Real OpenCircuitVoltage() const;

    /** Angular momentum of the spinning propeller about the thrust axis
     *  [kg m^2/s], signed with the direction of rotation. Drives the
     *  gyroscopic moment. */
    Real AngularMomentum() const;

    /** Solve the steady operating point without integrating, for the static
     *  thrust test and for initialising the state. */
    PowerSystemState SolveSteady(Real throttle, Real axialAirspeed, Real density) const;

private:
    Real MotorCurrentAt(Real angularRate, Real duty, Real busVoltageOpen) const;
    Real MotorTorqueFromCurrent(Real current) const;
    Real CurrentLimit() const;

    PropulsionSpec SpecData;
    Propeller Prop;

    PowerSystemState Current;
    Real ConsumedCharge = 0.0;   ///< coulomb
};

} // namespace rc
