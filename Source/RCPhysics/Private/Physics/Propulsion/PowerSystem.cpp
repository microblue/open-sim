#include "RCPhysics/Physics/Propulsion/PowerSystem.h"

#include "RCPhysics/Core/Log.h"

#include <cmath>

namespace rc
{
namespace
{
    /** A lithium polymer cell's voltage against state of charge, normalised so
     *  that 1.0 is the pack's nominal voltage. Flat through the middle and
     *  falling off a cliff at the end, which is what makes a model feel fine
     *  and then suddenly not. */
    Real CellVoltageFraction(Real stateOfCharge)
    {
        const Real soc = Clamp(stateOfCharge, 0.0, 1.0);
        if (soc > 0.8) { return Lerp(1.05, 1.12, (soc - 0.8) / 0.2); }
        if (soc > 0.2) { return Lerp(0.97, 1.05, (soc - 0.2) / 0.6); }
        return Lerp(0.89, 0.97, soc / 0.2);
    }
}

void PowerSystem::Configure(const PropulsionSpec& spec)
{
    SpecData = spec;
    Prop.Configure(spec.Propeller);
    Reset();
}

void PowerSystem::Reset()
{
    Current = PowerSystemState{};
    ConsumedCharge = 0.0;
    Current.StateOfCharge = 1.0;
    Current.BusVoltage = OpenCircuitVoltage();
}

Real PowerSystem::OpenCircuitVoltage() const
{
    const BatterySpec& battery = SpecData.Battery;
    const Real fraction = CellVoltageFraction(Current.StateOfCharge);
    const Real cell = Clamp(battery.NominalCellVoltage * fraction,
                            battery.EmptyCellVoltage * 0.9,
                            battery.FullCellVoltage);
    return cell * static_cast<Real>(Max(battery.CellCount, 1));
}

Real PowerSystem::CurrentLimit() const
{
    return Max(Min(SpecData.Esc.MaxCurrent, SpecData.Motor.MaxCurrent), 1.0);
}

Real PowerSystem::MotorTorqueFromCurrent(Real current) const
{
    // Q = (I - I0) / Kv, with Kv in rad/s per volt. The no-load current is the
    // iron and bearing loss; below it the motor produces no useful torque.
    const Real kv = Max(SpecData.Motor.KvRadPerSecondPerVolt, kEpsilon);
    return (current - SpecData.Motor.NoLoadCurrent) / kv;
}

Real PowerSystem::MotorCurrentAt(Real angularRate, Real duty, Real busVoltageOpen) const
{
    // Applied voltage minus back EMF, across the winding, with the battery's
    // internal resistance folded in because the sag depends on the very current
    // being solved for:
    //
    //     duty * eta * (Voc - I Rint) = Omega/Kv + I Rm
    //
    const MotorSpec& motor = SpecData.Motor;
    const Real kv  = Max(motor.KvRadPerSecondPerVolt, kEpsilon);
    const Real eta = Clamp(SpecData.Esc.Efficiency, 0.5, 1.0);
    const Real d   = Clamp(duty, 0.0, 1.0);

    const Real backEmf = angularRate / kv;
    const Real numerator = d * eta * busVoltageOpen - backEmf;
    const Real denominator = motor.Resistance + d * eta * SpecData.Battery.InternalResistance;
    if (denominator <= kEpsilon)
    {
        return 0.0;
    }
    return numerator / denominator;
}

void PowerSystem::Step(Real throttle, Real axialAirspeed, Real density, Real dt)
{
    const Real duty = Clamp(throttle, 0.0, 1.0);
    const Real openCircuit = OpenCircuitVoltage();

    Real rate = Max(Current.PropellerRate, 0.0);

    // --- electrical side at the CURRENT rate ------------------------------
    Real current = MotorCurrentAt(rate, duty, openCircuit);
    const Real limit = CurrentLimit();
    Current.CurrentLimited = current > limit;
    current = Clamp(current, -limit, limit);

    const Real motorTorque = MotorTorqueFromCurrent(current);

    // --- propeller side ---------------------------------------------------
    const PropellerState prop = Prop.Evaluate(rate, axialAirspeed, density);

    // --- linearly implicit update of the shaft ----------------------------
    // Both torques fall as the shaft speeds up, and the combined stiffness is
    // high enough that explicit Euler would be marginal at 240 Hz and unstable
    // at 120. Dividing by (1 + dt k) makes the step unconditionally stable and
    // removes any dependence of the flight model on the physics rate.
    const Real inertia = Max(SpecData.Propeller.MomentOfInertia, 1e-8);
    const Real kv  = Max(SpecData.Motor.KvRadPerSecondPerVolt, kEpsilon);
    const Real eta = Clamp(SpecData.Esc.Efficiency, 0.5, 1.0);
    const Real resistance = SpecData.Motor.Resistance
                          + duty * eta * SpecData.Battery.InternalResistance;

    const Real motorStiffness = Current.CurrentLimited
                              ? 0.0   // clamped: the motor no longer responds to speed
                              : 1.0 / (Sq(kv) * Max(resistance, kEpsilon));
    const Real propStiffness = (rate > 1.0) ? (2.0 * prop.Torque / rate) : 0.0;
    const Real stiffness = Max(motorStiffness + propStiffness, 0.0) / inertia;

    const Real acceleration = (motorTorque - prop.Torque) / inertia;
    rate += dt * acceleration / (1.0 + dt * stiffness);
    rate = Max(rate, 0.0);

    // --- publish ----------------------------------------------------------
    const PropellerState settled = Prop.Evaluate(rate, axialAirspeed, density);

    Current.PropellerRate = rate;
    Current.Rpm           = rate * 60.0 / kTwoPi;
    Current.Thrust        = settled.Thrust;
    Current.ShaftTorque   = settled.Torque;
    Current.AdvanceRatio  = settled.AdvanceRatio;
    Current.Current       = current;
    Current.BusVoltage    = openCircuit - current * SpecData.Battery.InternalResistance;
    Current.ElectricalPower = Current.BusVoltage * current;
    Current.MechanicalPower = settled.Torque * rate;
    Current.InducedVelocity = Prop.InducedVelocity(settled.Thrust, axialAirspeed, density);
    Current.WakeSwirl     = Prop.WakeSwirlCirculation(settled.Torque, axialAirspeed,
                                                     Current.InducedVelocity, density)
                            * (SpecData.Propeller.Clockwise ? 1.0 : -1.0);

    // --- battery ----------------------------------------------------------
    if (dt > 0.0 && current > 0.0)
    {
        ConsumedCharge += current * dt;
    }
    const Real capacity = Max(SpecData.Battery.CapacityCoulombs, 1.0);
    Current.StateOfCharge = Clamp(1.0 - ConsumedCharge / capacity, 0.0, 1.0);
}

Real PowerSystem::AngularMomentum() const
{
    const Real sign = SpecData.Propeller.Clockwise ? 1.0 : -1.0;
    return sign * SpecData.Propeller.MomentOfInertia * Current.PropellerRate;
}

PowerSystemState PowerSystem::SolveSteady(Real throttle, Real axialAirspeed, Real density) const
{
    // Bisect the shaft rate for zero net torque. The residual is monotonically
    // decreasing in rate - the motor produces less torque and the propeller
    // demands more - so bisection is both safe and exact enough in 60 steps.
    const Real duty = Clamp(throttle, 0.0, 1.0);
    const Real openCircuit = OpenCircuitVoltage();
    const Real limit = CurrentLimit();

    auto netTorque = [&](Real rate)
    {
        Real current = MotorCurrentAt(rate, duty, openCircuit);
        current = Clamp(current, -limit, limit);
        const Real motorTorque = MotorTorqueFromCurrent(current);
        return motorTorque - Prop.Evaluate(rate, axialAirspeed, density).Torque;
    };

    Real low = 0.0;
    Real high = SpecData.Motor.KvRadPerSecondPerVolt * openCircuit * 1.2 + 10.0;

    if (netTorque(low) <= 0.0)
    {
        PowerSystemState idle;
        idle.StateOfCharge = Current.StateOfCharge;
        idle.BusVoltage = openCircuit;
        return idle;   // not even enough torque to start turning
    }

    for (int i = 0; i < 80; ++i)
    {
        const Real middle = 0.5 * (low + high);
        if (netTorque(middle) > 0.0) { low = middle; } else { high = middle; }
    }

    const Real rate = 0.5 * (low + high);
    const PropellerState prop = Prop.Evaluate(rate, axialAirspeed, density);

    PowerSystemState result;
    Real current = MotorCurrentAt(rate, duty, openCircuit);
    result.CurrentLimited = current > limit;
    current = Clamp(current, -limit, limit);

    result.PropellerRate = rate;
    result.Rpm           = rate * 60.0 / kTwoPi;
    result.Thrust        = prop.Thrust;
    result.ShaftTorque   = prop.Torque;
    result.AdvanceRatio  = prop.AdvanceRatio;
    result.Current       = current;
    result.BusVoltage    = openCircuit - current * SpecData.Battery.InternalResistance;
    result.ElectricalPower = result.BusVoltage * current;
    result.MechanicalPower = prop.Torque * rate;
    result.InducedVelocity = Prop.InducedVelocity(prop.Thrust, axialAirspeed, density);
    result.WakeSwirl     = Prop.WakeSwirlCirculation(prop.Torque, axialAirspeed,
                                                    result.InducedVelocity, density)
                           * (SpecData.Propeller.Clockwise ? 1.0 : -1.0);
    result.StateOfCharge = Current.StateOfCharge;
    return result;
}

} // namespace rc
