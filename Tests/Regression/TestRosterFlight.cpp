// OpenRC Simulator - does each aeroplane in the roster actually fly?
//
// The airframe checks say a file is coherent. They say nothing about whether
// the thing described can be flown, and the whole point of a roster is that
// each one flies DIFFERENTLY - a glider that behaves like the trainer is a
// renamed trainer.
//
// So each is flown: released hands-off to see whether it glides, trimmed to
// find its stall, and rolled to see how quickly. The bounds are wide, because
// this is not the trainer's locked-target test - it is the check that nothing
// in the roster is secretly a brick.

#include "../Aero/FlightTestRig.h"
#include "TestHarness.h"

#include <string>
#include <vector>

namespace
{
    struct Expectation
    {
        const char* Stem;
        rc::Real MinGlide;      ///< best glide ratio, at least
        rc::Real MaxGlide;
        rc::Real MinStall;      ///< m/s
        rc::Real MaxStall;
        rc::Real MinRollRate;   ///< deg/s at full aileron
        rc::Real MaxRollRate;
    };

    // Wide, and deliberately non-overlapping where the aeroplanes are meant to
    // differ: a sport model that stalls where the glider does, or a glider that
    // rolls like the sport model, is not the aeroplane it says it is.
    const std::vector<Expectation>& Fleet()
    {
        static const std::vector<Expectation> fleet = {
            {"Trainer1500",  5.0, 12.0,  6.0, 10.0,   90.0, 260.0},
            {"Sport1200",    4.0, 10.0,  7.0, 13.0,  180.0, 700.0},
            {"Glider2400",   9.0, 26.0,  4.0,  8.5,   30.0, 190.0},
            {"Warbird1100",  4.0, 11.0,  9.0, 17.0,  100.0, 420.0},
            // The biplane. Two wings interfering with each other make it the
            // worst glider here by some way, and four ailerons make it the
            // fastest roller - which is the whole point of the type.
            {"Biplane1300",  2.5,  8.0,  6.0, 12.0,  250.0, 900.0},
        };
        return fleet;
    }

    /** Best glide ratio, from the trimmed power-off polar.
     *
     *  Not from a hands-off release: released untrimmed an aeroplane pitches
     *  down and dives, and the first version of this measured exactly that -
     *  it reported the trainer at 0.76 : 1, which is a brick. Glide ratio means
     *  the BEST lift-to-drag the aircraft can be trimmed to, which is what
     *  TestTrainerTargets has always measured and what a pilot means by it.
     */
    rc::Real MeasureGlide(rctest::FlightTestRig& rig)
    {
        rig.EnablePower(false);
        rig.EnableGround(false);

        rc::Real best = 0.0;
        for (rc::Real degrees = 0.0; degrees <= 18.0; degrees += 0.25)
        {
            const rctest::TrimPoint point = rctest::TrimAtAlpha(rig, rc::units::Degrees(degrees));
            if (!point.Converged) { continue; }
            best = std::max(best, point.GlideRatio);
        }
        return best;
    }

    /** Slowest speed at which the wing still carries the weight. */
    rc::Real MeasureStall(rctest::FlightTestRig& rig)
    {
        for (rc::Real speed = 4.0; speed < 30.0; speed += 0.05)
        {
            rc::Real best = 0.0;
            for (rc::Real alpha = 0.0; alpha < 0.30; alpha += 0.005)
            {
                rig.FreezeAtAlpha(speed, alpha);
                const rc::AircraftForces forces = rig.Evaluate();
                best = std::max(best, forces.TotalLift);
            }
            if (best >= rig.Weight()) { return speed; }
        }
        return 0.0;
    }

    /** Steady roll rate at full aileron, in degrees per second. */
    rc::Real MeasureRollRate(rctest::FlightTestRig& rig)
    {
        rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, 0.02, 300.0);
        rc::Real peak = 0.0;
        for (int step = 0; step < 240 * 3; ++step)
        {
            rig.Controls.Set(rc::RCChannel::Aileron, 1.0);
            rig.Step();
            peak = std::max(peak, std::fabs(rig.State.AngularVelocityBody.x));
        }
        return rc::units::ToDegrees(peak);
    }
}

RC_TEST(RosterFlight, EveryAircraftGlides)
{
    for (const Expectation& want : Fleet())
    {
        rctest::FlightTestRig rig;
        const std::string error = rig.Load(want.Stem);
        if (!error.empty()) { RC_FAIL(std::string(want.Stem) + ": " + error); continue; }

        const rc::Real glide = MeasureGlide(rig);
        std::printf("       %-14s glide %5.2f : 1\n", want.Stem, glide);
        RC_CHECK_MSG_VALUE(glide > want.MinGlide && glide < want.MaxGlide, glide);
    }
}

RC_TEST(RosterFlight, EveryAircraftHasAStallSpeed)
{
    for (const Expectation& want : Fleet())
    {
        rctest::FlightTestRig rig;
        if (!rig.Load(want.Stem).empty()) { continue; }

        const rc::Real stall = MeasureStall(rig);
        std::printf("       %-14s stall %5.2f m/s\n", want.Stem, stall);
        RC_CHECK_MSG_VALUE(stall > want.MinStall && stall < want.MaxStall, stall);
    }
}

RC_TEST(RosterFlight, EveryAircraftRollsAtItsOwnRate)
{
    for (const Expectation& want : Fleet())
    {
        rctest::FlightTestRig rig;
        if (!rig.Load(want.Stem).empty()) { continue; }

        const rc::Real rate = MeasureRollRate(rig);
        std::printf("       %-14s roll  %5.1f deg/s\n", want.Stem, rate);
        RC_CHECK_MSG_VALUE(rate > want.MinRollRate && rate < want.MaxRollRate, rate);
    }
}

RC_TEST(RosterFlight, TheGliderReallyIsTheBestGlider)
{
    // The one comparison that matters: if the thermal glider does not out-glide
    // everything else in the roster, it is not a glider.
    rc::Real gliderRatio = 0.0;
    rc::Real bestOther = 0.0;

    for (const Expectation& want : Fleet())
    {
        rctest::FlightTestRig rig;
        if (!rig.Load(want.Stem).empty()) { continue; }
        const rc::Real glide = MeasureGlide(rig);
        if (std::string(want.Stem) == "Glider2400") { gliderRatio = glide; }
        else { bestOther = std::max(bestOther, glide); }
    }

    RC_CHECK_MSG_VALUE(gliderRatio > bestOther * 1.25, gliderRatio - bestOther);
}
