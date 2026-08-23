// OpenRC Simulator - the physics step has to fit in its budget.
//
// At 240 Hz a step has 4167 microseconds of wall clock. If the flight model
// cannot be evaluated in a small fraction of that, the fixed timestep starts
// dropping steps under load and the aircraft quietly begins to fly differently
// on a busy frame - which is the exact failure the fixed timestep exists to
// prevent.
//
// These are timings, so they are machine dependent. The assertions are
// deliberately loose - they exist to catch an order-of-magnitude regression
// (an accidental allocation per section, an O(n^2) loop) rather than to police
// a few percent. The printed numbers are the useful part.
#include "../Aero/FlightTestRig.h"

#include <chrono>
#include <cstdio>

using namespace rc;
using namespace rctest;

namespace
{
    /** Microseconds per iteration of `work`, averaged over `iterations`. */
    template <typename Work>
    double MicrosecondsPer(int iterations, Work&& work)
    {
        // A short warm-up so the first-touch page faults and the branch
        // predictor are not part of the measurement.
        for (int i = 0; i < iterations / 10 + 1; ++i) { work(); }

        const auto start = std::chrono::steady_clock::now();
        for (int i = 0; i < iterations; ++i) { work(); }
        const auto finish = std::chrono::steady_clock::now();

        const auto elapsed =
            std::chrono::duration_cast<std::chrono::nanoseconds>(finish - start).count();
        return static_cast<double>(elapsed) / (1000.0 * static_cast<double>(iterations));
    }

    constexpr double kStepBudgetMicroseconds = 1e6 / 240.0;   // 4167 us
}

RC_TEST(Performance, AFullPhysicsStepFitsComfortablyInTheBudget)
{
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }
    rig.EnablePower(true);
    rig.EnableGround(true);
    rig.Wind.SetSeed(7u);
    rig.Wind.SetSteady(4.0, units::Degrees(250.0));
    rig.Wind.SetGust(3.0, 8.0);
    rig.Wind.SetTurbulence(1.2, 5.0);
    rig.PlaceAtAlpha(14.0, units::Degrees(3.0), 30.0);
    rig.Controls.Set(RCChannel::Throttle, 0.7);

    const double perStep = MicrosecondsPer(20000, [&]() { rig.Step(); });
    const double load = perStep / kStepBudgetMicroseconds;

    std::printf("\n        full step (11 sections, propulsion, ground, wind): "
                "%.2f us\n", perStep);
    std::printf("        %.2f%% of the 240 Hz budget - headroom for %.0f Hz\n",
                load * 100.0, 1e6 / perStep);

    RC_CHECK(rig.State.IsFinite());
    // Two orders of magnitude of headroom is what this should have; anything
    // over a tenth of the budget means something has gone badly wrong.
    RC_CHECK(perStep < 0.10 * kStepBudgetMicroseconds);
}

RC_TEST(Performance, CostBreaksDownWhereExpected)
{
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }
    rig.PlaceAtAlpha(14.0, units::Degrees(3.0), 30.0);

    const double aeroOnly = MicrosecondsPer(20000, [&]()
    {
        rig.Plane.ComputeForces(rig.State, rig.Controls, rig.Air, rig.Wind, rig.Propulsion);
    });

    rig.EnablePower(true);
    const double withPower = MicrosecondsPer(20000, [&]()
    {
        rig.StepPropulsion();
        rig.Plane.ComputeForces(rig.State, rig.Controls, rig.Air, rig.Wind, rig.Propulsion);
    });

    rig.EnableGround(true);
    const double withGround = MicrosecondsPer(20000, [&]()
    {
        rig.StepPropulsion();
        rig.Plane.ComputeForces(rig.State, rig.Controls, rig.Air, rig.Wind,
                                rig.Propulsion, &rig.Ground);
    });

    rig.Wind.SetTurbulence(1.5, 5.0);
    const double withTurbulence = MicrosecondsPer(20000, [&]()
    {
        rig.StepPropulsion();
        rig.Plane.ComputeForces(rig.State, rig.Controls, rig.Air, rig.Wind,
                                rig.Propulsion, &rig.Ground);
    });

    std::printf("        aerodynamics only     %6.2f us\n", aeroOnly);
    std::printf("        + propulsion          %6.2f us\n", withPower);
    std::printf("        + ground contact      %6.2f us\n", withGround);
    std::printf("        + seeded turbulence   %6.2f us\n", withTurbulence);
    std::printf("        per section           %6.2f us\n",
                aeroOnly / static_cast<double>(rig.Definition.Surfaces.size()));

    RC_CHECK(aeroOnly > 0.0);
    // Each addition costs something, but none of them should dominate the
    // section model - if one does, it is doing more work than it should.
    RC_CHECK(withPower < 3.0 * aeroOnly);
    RC_CHECK(withGround < 4.0 * aeroOnly);
    RC_CHECK(withTurbulence < 6.0 * aeroOnly);
}

RC_TEST(Performance, SectionCountScalesLinearly)
{
    // The section model is the thing most likely to be scaled up - more
    // sections per wing buys resolution in the spanwise stall. It has to cost
    // linearly, or that knob becomes unusable.
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }
    rig.PlaceAtAlpha(14.0, units::Degrees(3.0), 30.0);

    auto costWithSections = [&](int copies)
    {
        AircraftDefinition definition = rig.Definition;
        const std::vector<AeroSurfaceSpec> original = definition.Surfaces;
        for (int copy = 1; copy < copies; ++copy)
        {
            for (AeroSurfaceSpec spec : original)
            {
                spec.Name += "_copy" + std::to_string(copy);
                spec.Area /= static_cast<Real>(copies);
                definition.Surfaces.push_back(spec);
            }
        }
        Aircraft plane;
        plane.Configure(definition);
        return MicrosecondsPer(6000, [&]()
        {
            plane.ComputeForces(rig.State, rig.Controls, rig.Air, rig.Wind, rig.Propulsion);
        });
    };

    const double at11 = costWithSections(1);
    const double at44 = costWithSections(4);

    std::printf("        11 sections %6.2f us,  44 sections %6.2f us  (%.2fx)\n",
                at11, at44, at44 / at11);

    RC_CHECK(at44 > at11);
    // Four times the sections for less than six times the cost: linear, plus
    // the fixed per-step overhead that does not scale.
    RC_CHECK(at44 < 6.0 * at11);
}

RC_TEST(Performance, ThirtyMinutesOfFlightStaysStable)
{
    // The V0.1 stability criterion, run for real. Thirty simulated minutes at
    // 240 Hz is 432 000 steps, through gusts and turbulence, with the ground
    // underneath.
    FlightTestRig rig;
    if (!rig.LoadTrainer().empty()) { RC_FAIL("could not load the trainer"); return; }
    rig.EnablePower(true);
    rig.EnableGround(true);
    rig.Wind.SetSeed(31u);
    rig.Wind.SetSteady(3.5, units::Degrees(240.0));
    rig.Wind.SetGust(2.5, 9.0);
    rig.Wind.SetTurbulence(1.0, 5.0);
    rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, units::Degrees(2.0), 120.0);

    const int steps = 240 * 60 * 30;
    const auto start = std::chrono::steady_clock::now();

    for (int i = 0; i < steps; ++i)
    {
        // Fly it: hold a gentle circuit rather than letting it spiral in.
        rig.HoldPitch(2.0);
        rig.HoldWingsLevel();
        rig.Controls.Set(RCChannel::Throttle, rig.Altitude() < 100.0 ? 0.75 : 0.45);
        rig.Step();

        if (!rig.State.IsFinite())
        {
            RC_FAIL("state became non-finite after " + std::to_string(i) + " steps");
            return;
        }
    }

    const auto finish = std::chrono::steady_clock::now();
    const double seconds =
        static_cast<double>(std::chrono::duration_cast<std::chrono::milliseconds>(finish - start).count()) / 1000.0;

    std::printf("        30 simulated minutes in %.2f s of wall clock "
                "(%.0fx real time)\n", seconds, 1800.0 / seconds);
    std::printf("        final: %.1f m, %.1f m/s, attitude %.1f / %.1f / %.1f deg\n",
                rig.Altitude(), rig.Airspeed(),
                units::ToDegrees(rig.State.Attitude().roll),
                units::ToDegrees(rig.State.Attitude().pitch),
                units::ToDegrees(rig.State.Attitude().yaw));

    RC_CHECK(rig.State.IsFinite());
    RC_CHECK_NEAR(rig.State.Orientation.Norm(), 1.0, 1e-9);
    RC_CHECK(rig.Altitude() > 0.0);
    RC_CHECK(rig.Airspeed() > 3.0 && rig.Airspeed() < 40.0);
    // It must still be a flying aircraft, not a tumbling one.
    RC_CHECK(std::fabs(units::ToDegrees(rig.State.Attitude().roll)) < 45.0);
    RC_CHECK(std::fabs(units::ToDegrees(rig.State.Attitude().pitch)) < 45.0);
}
