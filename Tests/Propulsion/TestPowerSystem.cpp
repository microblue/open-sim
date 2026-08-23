#include "TestHarness.h"

#include "RCPhysics/Aircraft/AircraftLoader.h"
#include "RCPhysics/Core/Units/Units.h"
#include "RCPhysics/Physics/Environment/Atmosphere.h"
#include "RCPhysics/Physics/Propulsion/PowerSystem.h"

#include <cstdio>

using namespace rc;

namespace
{
    PropulsionSpec TrainerPropulsion()
    {
        AircraftDefinition definition;
        const std::string path = std::string(RC_REPO_ROOT) + "/Data/Aircraft/Trainer1500.json";
        AircraftLoader::LoadFromFile(path, definition);
        return definition.Propulsion;
    }

    constexpr Real kSeaLevelDensity = units::kSeaLevelDensity;
    constexpr Real kTrainerWeight = 1.35 * units::kGravity;
}

// ------------------------------------------------------------- propeller ----

RC_TEST(Propeller, StaticCoefficientsMatchPublishedApcData)
{
    // An 11x6 has a pitch-to-diameter ratio of 0.545. APC's published electric
    // data puts Ct(0) near 0.115 and Cp(0) near 0.055 for that ratio.
    PropellerSpec spec;
    spec.Diameter = units::Inches(11.0);
    spec.Pitch = units::Inches(6.0);
    spec.BladeCount = 2;

    Propeller propeller;
    propeller.Configure(spec);

    RC_CHECK_NEAR(spec.PitchOverDiameter(), 6.0 / 11.0, 1e-12);

    // 8000 rpm static, sea level.
    const PropellerState state = propeller.Evaluate(units::RPM(8000.0), 0.0, kSeaLevelDensity);
    RC_CHECK_NEAR(state.ThrustCoefficient, 0.117, 0.01);
    RC_CHECK(state.Thrust > 12.0 && state.Thrust < 18.0);
    RC_CHECK(state.Torque > 0.15 && state.Torque < 0.45);
}

RC_TEST(Propeller, ThrustFallsToZeroNearPitchSpeed)
{
    // This is what stops a model accelerating past its pitch speed, and why an
    // over-pitched propeller gives an aircraft that is fast but will not climb.
    PropellerSpec spec;
    spec.Diameter = units::Inches(11.0);
    spec.Pitch = units::Inches(6.0);

    Propeller propeller;
    propeller.Configure(spec);

    const Real rate = units::RPM(8000.0);
    const Real revolutionsPerSecond = rate / kTwoPi;

    const Real staticThrust = propeller.Evaluate(rate, 0.0, kSeaLevelDensity).Thrust;
    RC_CHECK(staticThrust > 0.0);

    // Thrust must fall monotonically with airspeed.
    Real previous = staticThrust;
    for (Real speed = 1.0; speed <= 30.0; speed += 1.0)
    {
        const Real thrust = propeller.Evaluate(rate, speed, kSeaLevelDensity).Thrust;
        if (thrust > previous + 1e-9)
        {
            RC_FAIL("thrust rose with airspeed at " + std::to_string(speed) + " m/s");
            break;
        }
        previous = thrust;
    }

    // Zero thrust near the pitch advance ratio.
    const Real zeroThrustSpeed = propeller.ZeroThrustAdvanceRatio()
                               * revolutionsPerSecond * spec.Diameter;
    RC_CHECK(zeroThrustSpeed > 20.0 && zeroThrustSpeed < 40.0);
    RC_CHECK_NEAR(propeller.Evaluate(rate, zeroThrustSpeed, kSeaLevelDensity).Thrust,
                  0.0, 0.3);
    // And it windmills - negative thrust - beyond it.
    RC_CHECK(propeller.Evaluate(rate, zeroThrustSpeed * 1.4, kSeaLevelDensity).Thrust < 0.0);
}

RC_TEST(Propeller, TorqueFallsMoreSlowlyThanThrust)
{
    // A blade keeps stirring the air long after it has stopped pushing it,
    // which is why a windmilling propeller still drags.
    PropellerSpec spec;
    spec.Diameter = units::Inches(11.0);
    spec.Pitch = units::Inches(6.0);
    Propeller propeller;
    propeller.Configure(spec);

    const Real rate = units::RPM(8000.0);
    const PropellerState atStatic = propeller.Evaluate(rate, 0.0, kSeaLevelDensity);
    const Real zeroThrustSpeed = propeller.ZeroThrustAdvanceRatio() * (rate / kTwoPi) * spec.Diameter;
    const PropellerState atPitchSpeed = propeller.Evaluate(rate, zeroThrustSpeed, kSeaLevelDensity);

    RC_CHECK(atPitchSpeed.Torque > 0.3 * atStatic.Torque);
    RC_CHECK(atPitchSpeed.Torque < atStatic.Torque);
}

RC_TEST(Propeller, InducedVelocityFollowsMomentumTheory)
{
    PropellerSpec spec;
    spec.Diameter = units::Inches(11.0);
    spec.Pitch = units::Inches(6.0);
    Propeller propeller;
    propeller.Configure(spec);

    // Static: T = 2 rho A v_i^2, so v_i = sqrt(T / (2 rho A)).
    const Real thrust = 14.0;
    const Real area = spec.DiskArea();
    const Real expected = std::sqrt(thrust / (2.0 * kSeaLevelDensity * area));
    RC_CHECK_NEAR(propeller.InducedVelocity(thrust, 0.0, kSeaLevelDensity), expected, 1e-9);

    // The wake is fast: this is why the tail still works at a standstill.
    RC_CHECK(expected > 8.0 && expected < 16.0);

    // Induced velocity falls as the aircraft speeds up.
    RC_CHECK(propeller.InducedVelocity(thrust, 20.0, kSeaLevelDensity) < 0.5 * expected);
    RC_CHECK_NEAR(propeller.InducedVelocity(0.0, 10.0, kSeaLevelDensity), 0.0, 1e-15);
    RC_CHECK_NEAR(propeller.InducedVelocity(-5.0, 10.0, kSeaLevelDensity), 0.0, 1e-15);
}

RC_TEST(Propeller, MoreBladesMoveMoreAir)
{
    PropellerSpec two, three;
    two.Diameter = three.Diameter = units::Inches(11.0);
    two.Pitch = three.Pitch = units::Inches(6.0);
    two.BladeCount = 2;
    three.BladeCount = 3;

    Propeller a, b;
    a.Configure(two);
    b.Configure(three);

    const Real rate = units::RPM(8000.0);
    RC_CHECK(b.Evaluate(rate, 0.0, kSeaLevelDensity).Thrust >
             a.Evaluate(rate, 0.0, kSeaLevelDensity).Thrust);
    RC_CHECK(b.Evaluate(rate, 0.0, kSeaLevelDensity).Torque >
             a.Evaluate(rate, 0.0, kSeaLevelDensity).Torque);
}

// ---------------------------------------------------------- power system ----

RC_TEST(PowerSystem, StaticThrustAtFullThrottle)
{
    PowerSystem power;
    power.Configure(TrainerPropulsion());

    const PowerSystemState state = power.SolveSteady(1.0, 0.0, kSeaLevelDensity);

    std::printf("\n        static: %.2f N  %.0f rpm  %.1f A  %.2f V  %.0f W  "
                "T/W %.2f  v_i %.1f m/s\n",
                state.Thrust, state.Rpm, state.Current, state.BusVoltage,
                state.ElectricalPower, state.Thrust / kTrainerWeight,
                state.InducedVelocity);

    // A 1000 KV motor on 3S with an 11x6 lands between 7000 and 9000 rpm.
    RC_CHECK(state.Rpm > 6500.0 && state.Rpm < 9500.0);
    RC_CHECK(state.Current > 15.0 && state.Current <= 35.0);
    RC_CHECK(state.BusVoltage > 9.5 && state.BusVoltage < 12.6);

    // Thrust-to-weight near unity is the whole point of this power system: a
    // trainee has to be able to climb out of a mistake.
    const Real thrustToWeight = state.Thrust / kTrainerWeight;
    RC_CHECK(thrustToWeight > 0.85 && thrustToWeight < 1.35);

    // The wake is fast enough to give the tail real authority at a standstill.
    RC_CHECK(state.InducedVelocity > 8.0);
}

RC_TEST(PowerSystem, ThrottleResponseIsMonotonic)
{
    PowerSystem power;
    power.Configure(TrainerPropulsion());

    Real previousThrust = -1.0;
    Real previousRpm = -1.0;
    for (Real throttle = 0.0; throttle <= 1.0; throttle += 0.05)
    {
        const PowerSystemState state = power.SolveSteady(throttle, 0.0, kSeaLevelDensity);
        RC_CHECK(state.Thrust >= previousThrust - 1e-9);
        RC_CHECK(state.Rpm >= previousRpm - 1e-9);
        RC_CHECK(state.Thrust >= 0.0);
        previousThrust = state.Thrust;
        previousRpm = state.Rpm;
    }
    RC_CHECK_NEAR(power.SolveSteady(0.0, 0.0, kSeaLevelDensity).Thrust, 0.0, 1e-9);
}

RC_TEST(PowerSystem, ThrustFallsWithAirspeed)
{
    PowerSystem power;
    power.Configure(TrainerPropulsion());

    const Real staticThrust = power.SolveSteady(1.0, 0.0, kSeaLevelDensity).Thrust;
    const Real atCruise = power.SolveSteady(1.0, 16.0, kSeaLevelDensity).Thrust;
    const Real atTopSpeed = power.SolveSteady(1.0, 26.0, kSeaLevelDensity).Thrust;

    RC_CHECK(atCruise < staticThrust);
    RC_CHECK(atTopSpeed < atCruise);
    // Still climbing at cruise: thrust must exceed the drag at that speed,
    // which for this aircraft is a couple of newtons.
    RC_CHECK(atCruise > 4.0);

    // Unloading the propeller lets it spin up, so rpm RISES with airspeed.
    RC_CHECK(power.SolveSteady(1.0, 20.0, kSeaLevelDensity).Rpm >
             power.SolveSteady(1.0, 0.0, kSeaLevelDensity).Rpm);
}

RC_TEST(PowerSystem, SpoolsUpWithRealisticLag)
{
    // Throttle response is not instant: the propeller has to be accelerated.
    // This is why chopping the throttle on final does not remove the propwash
    // immediately, and why a blip of power does not instantly become thrust.
    PowerSystem power;
    power.Configure(TrainerPropulsion());
    power.Reset();

    const Real dt = 1.0 / 240.0;
    const Real target = power.SolveSteady(1.0, 0.0, kSeaLevelDensity).PropellerRate;

    Real timeTo90Percent = -1.0;
    for (int i = 0; i < 240 * 3; ++i)
    {
        power.Step(1.0, 0.0, kSeaLevelDensity, dt);
        if (timeTo90Percent < 0.0 && power.State().PropellerRate > 0.9 * target)
        {
            timeTo90Percent = static_cast<Real>(i) * dt;
        }
    }

    std::printf("        spool-up to 90%%: %.3f s\n", timeTo90Percent);
    RC_CHECK(timeTo90Percent > 0.005);   // not instantaneous
    RC_CHECK(timeTo90Percent < 1.0);     // but not sluggish either
    RC_CHECK_NEAR(power.State().PropellerRate, target, 0.02 * target);
}

RC_TEST(PowerSystem, IntegrationIsIndependentOfThePhysicsRate)
{
    // THE property the fixed timestep exists to protect: changing the physics
    // rate must not change the aircraft. Explicit Euler on this system would
    // fail here at 120 Hz.
    auto settle = [](Real rateHz)
    {
        PowerSystem power;
        power.Configure(TrainerPropulsion());
        power.Reset();
        const Real dt = 1.0 / rateHz;
        for (int i = 0; i < static_cast<int>(rateHz * 2.0); ++i)
        {
            power.Step(1.0, 0.0, kSeaLevelDensity, dt);
        }
        return power.State();
    };

    const PowerSystemState at120 = settle(120.0);
    const PowerSystemState at240 = settle(240.0);
    const PowerSystemState at480 = settle(480.0);

    RC_CHECK(at120.PropellerRate > 0.0);
    RC_CHECK_NEAR(at120.PropellerRate, at240.PropellerRate, 0.01 * at240.PropellerRate);
    RC_CHECK_NEAR(at480.PropellerRate, at240.PropellerRate, 0.01 * at240.PropellerRate);
    RC_CHECK_NEAR(at120.Thrust, at240.Thrust, 0.02 * at240.Thrust);
    RC_CHECK_NEAR(at480.Thrust, at240.Thrust, 0.02 * at240.Thrust);
}

RC_TEST(PowerSystem, SteadyStepMatchesTheDirectSolve)
{
    PowerSystem power;
    power.Configure(TrainerPropulsion());
    power.Reset();

    const Real dt = 1.0 / 240.0;
    for (int i = 0; i < 240 * 3; ++i) { power.Step(0.7, 12.0, kSeaLevelDensity, dt); }

    const PowerSystemState direct = power.SolveSteady(0.7, 12.0, kSeaLevelDensity);
    RC_CHECK_NEAR(power.State().PropellerRate, direct.PropellerRate,
                  0.01 * direct.PropellerRate);
    RC_CHECK_NEAR(power.State().Thrust, direct.Thrust, 0.02 * Max(direct.Thrust, 1.0));
}

RC_TEST(PowerSystem, BatteryDrainsAndSags)
{
    PowerSystem power;
    power.Configure(TrainerPropulsion());
    power.Reset();

    const Real full = power.OpenCircuitVoltage();
    RC_CHECK(full > 11.0 && full < 13.0);
    RC_CHECK_NEAR(power.State().StateOfCharge, 1.0, 1e-12);

    // Four minutes at full throttle should use most of a 2200 mAh pack.
    const Real dt = 1.0 / 240.0;
    for (int i = 0; i < 240 * 240; ++i) { power.Step(1.0, 14.0, kSeaLevelDensity, dt); }

    std::printf("        after 4 min full throttle: %.0f%% charge, %.2f V, %.2f N\n",
                power.State().StateOfCharge * 100.0, power.State().BusVoltage,
                power.State().Thrust);

    RC_CHECK(power.State().StateOfCharge < 0.5);
    RC_CHECK(power.OpenCircuitVoltage() < full);
    // Voltage under load must never go non-physical.
    RC_CHECK(power.State().BusVoltage > 6.0);
    RC_CHECK(power.State().Thrust > 0.0);
}

RC_TEST(PowerSystem, CurrentIsLimited)
{
    PropulsionSpec spec = TrainerPropulsion();
    spec.Motor.MaxCurrent = 12.0;   // a deliberately undersized motor

    PowerSystem power;
    power.Configure(spec);
    const PowerSystemState state = power.SolveSteady(1.0, 0.0, kSeaLevelDensity);

    RC_CHECK(state.Current <= 12.0 + 1e-9);
    RC_CHECK(state.CurrentLimited);
    RC_CHECK(state.Thrust > 0.0);
    // And a limited system makes less thrust than an unlimited one.
    PowerSystem healthy;
    healthy.Configure(TrainerPropulsion());
    RC_CHECK(state.Thrust < healthy.SolveSteady(1.0, 0.0, kSeaLevelDensity).Thrust);
}

RC_TEST(PowerSystem, WakeSwirlFollowsTheRotationDirection)
{
    PropulsionSpec clockwise = TrainerPropulsion();
    clockwise.Propeller.Clockwise = true;
    PropulsionSpec counter = clockwise;
    counter.Propeller.Clockwise = false;

    PowerSystem a, b;
    a.Configure(clockwise);
    b.Configure(counter);

    const PowerSystemState left = a.SolveSteady(1.0, 5.0, kSeaLevelDensity);
    const PowerSystemState right = b.SolveSteady(1.0, 5.0, kSeaLevelDensity);

    RC_CHECK(left.WakeSwirl > 0.0);
    RC_CHECK(right.WakeSwirl < 0.0);
    RC_CHECK_NEAR(left.WakeSwirl, -right.WakeSwirl, 1e-9);

    // Angular momentum follows the same sign, which is what makes the
    // gyroscopic moment point the right way.
    RC_CHECK(a.AngularMomentum() * left.WakeSwirl >= 0.0);
}

RC_TEST(PowerSystem, ThinAirCostsThrust)
{
    PowerSystem power;
    power.Configure(TrainerPropulsion());

    const Real seaLevel = power.SolveSteady(1.0, 0.0, kSeaLevelDensity).Thrust;
    const Real highField = power.SolveSteady(1.0, 0.0,
        Atmosphere().SampleAboveSeaLevel(1500.0).Density).Thrust;

    RC_CHECK(highField < seaLevel);
    RC_CHECK(highField > 0.8 * seaLevel);
    // And the propeller unloads, so it turns faster in thin air.
    RC_CHECK(power.SolveSteady(1.0, 0.0,
             Atmosphere().SampleAboveSeaLevel(1500.0).Density).Rpm >
             power.SolveSteady(1.0, 0.0, kSeaLevelDensity).Rpm);
}
