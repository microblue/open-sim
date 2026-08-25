// OpenRC Simulator - can the glider actually soar?
//
// The lift field's own tests say the air rises in the right places. This says
// the thing that matters to a pilot: that an aeroplane put into that air, and
// flown, gains height - and that one flown in dead air does not, so the climb
// is coming from the sky and not from a bug.
//
// It is deliberately not a test of the autopilot. The "pilot" here holds the
// wings level and the speed sensible; it does not hunt for lift. If a glider
// can gain height on that alone when parked over a working thermal, the air is
// doing the work.

#include "../Aero/FlightTestRig.h"
#include "RCPhysics/Physics/Environment/LiftField.h"
#include "RCPhysics/Physics/Ground/TerrainField.h"
#include "TestHarness.h"

#include <cmath>

namespace
{
    /** Fly for `seconds` holding the wings level, and report the height gained.
     *  `lift` may be null, which is the control case. */
    rc::Real FlyAndMeasureClimb(rctest::FlightTestRig& rig, const rc::LiftField* lift,
                                rc::Real north, rc::Real east, rc::Real seconds)
    {
        rig.EnablePower(false);
        rig.EnableGround(false);
        rig.Wind.SetLiftField(lift);

        rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, rc::units::Degrees(3.0), 260.0);
        rig.State.PositionWorld.x = north;
        rig.State.PositionWorld.y = east;

        const rc::Real startAltitude = -rig.State.PositionWorld.z;
        const int steps = static_cast<int>(seconds * 240.0);
        for (int step = 0; step < steps; ++step)
        {
            rig.HoldWingsLevel();

            // Fly it for minimum sink, not for cruise.
            //
            // The first version held eighty percent of cruise and the glider
            // came down at two and a half metres a second - a thirteen-to-one
            // machine being flown like a brick, because a glider's sink rate
            // rises steeply with speed and cruise is nowhere near its best.
            // Approach speed is close enough to minimum sink for this.
            //
            // Damped on the rate as well as the error, or the aeroplane
            // phugoids and the average sink is worse than either extreme.
            const rc::Real speed = rig.State.VelocityWorld.Length();
            const rc::Real wanted = rig.Definition.ApproachSpeed;
            const rc::Real pitchRate = rig.State.AngularVelocityBody.y;
            rig.Controls.Set(rc::RCChannel::Elevator,
                             rc::ClampUnit((speed - wanted) * 0.16 - pitchRate * 0.55));
            rig.Step();

            // Keep it over the same patch of air: this measures the sky, not
            // the aircraft's ability to stay in a thermal.
            rig.State.PositionWorld.x = north;
            rig.State.PositionWorld.y = east;
        }
        return -rig.State.PositionWorld.z - startAltitude;
    }

    /** Somewhere the air is going up hard, at a height a glider would use. */
    bool FindWorkingAir(const rc::LiftField& lift, rc::Real time, rc::Real& north,
                        rc::Real& east)
    {
        rc::Real best = 0.0;
        for (rc::Real n = -900.0; n <= 900.0; n += 15.0)
        {
            for (rc::Real e = -900.0; e <= 900.0; e += 15.0)
            {
                const rc::Real value =
                    lift.SampleAt(rc::Vec3(n, e, -260.0), time, rc::Vec3::Zero()).Total();
                if (value > best) { best = value; north = n; east = e; }
            }
        }
        return best > 1.0;
    }
}

RC_TEST(Soaring, TheGliderClimbsInAThermal)
{
    static const rc::TerrainField world{rc::TerrainSettings{}};
    static const rc::LiftField sky{world};

    rc::Real north = 0.0, east = 0.0;
    if (!FindWorkingAir(sky, 200.0, north, east))
    {
        RC_FAIL("no working lift found to test in");
        return;
    }

    rctest::FlightTestRig rig;
    const std::string error = rig.Load("Glider2400");
    if (!error.empty()) { RC_FAIL(error); return; }

    const rc::Real climb = FlyAndMeasureClimb(rig, &sky, north, east, 45.0);

    rctest::FlightTestRig still;
    still.Load("Glider2400");
    const rc::Real deadAir = FlyAndMeasureClimb(still, nullptr, north, east, 45.0);

    std::printf("       glider over lift %+.1f m in 45 s, in dead air %+.1f m\n",
                climb, deadAir);

    // In dead air a glider goes down. That is what a glider does.
    RC_CHECK_MSG_VALUE(deadAir < -10.0, deadAir);
    // Over a working thermal it does markedly better - and should gain.
    RC_CHECK_MSG_VALUE(climb > deadAir + 25.0, climb - deadAir);
    RC_CHECK_MSG_VALUE(climb > 0.0, climb);
}

RC_TEST(Soaring, TheTrainerDoesFarLessWellInTheSameAir)
{
    // The roster has to mean something in the air as well as on paper. A
    // trainer in the same thermal climbs less, because it sinks faster.
    static const rc::TerrainField world{rc::TerrainSettings{}};
    static const rc::LiftField sky{world};

    rc::Real north = 0.0, east = 0.0;
    if (!FindWorkingAir(sky, 200.0, north, east)) { return; }

    rctest::FlightTestRig glider;
    glider.Load("Glider2400");
    const rc::Real gliderClimb = FlyAndMeasureClimb(glider, &sky, north, east, 45.0);

    rctest::FlightTestRig trainer;
    trainer.Load("Trainer1500");
    const rc::Real trainerClimb = FlyAndMeasureClimb(trainer, &sky, north, east, 45.0);

    std::printf("       same air: glider %+.1f m, trainer %+.1f m\n",
                gliderClimb, trainerClimb);
    RC_CHECK_MSG_VALUE(gliderClimb > trainerClimb, gliderClimb - trainerClimb);
}

RC_TEST(Soaring, AWingInTheEdgeOfAThermalIsRolled)
{
    // The cue the whole skill rests on. One wing tip in the lift and the other
    // outside it is a rolling moment, and that roll is how a pilot knows which
    // way to turn. It only exists because the lift is sampled per section - at
    // the centre of gravity there would be climb and no cue at all.
    static const rc::TerrainField world{rc::TerrainSettings{}};
    static const rc::LiftField sky{world};

    rc::Real north = 0.0, east = 0.0;
    if (!FindWorkingAir(sky, 200.0, north, east)) { return; }

    rctest::FlightTestRig rig;
    if (!rig.Load("Glider2400").empty()) { return; }
    rig.EnablePower(false);
    rig.EnableGround(false);
    rig.Wind.SetLiftField(&sky);

    // Placed so the thermal is off to one side, about a wing's length away.
    rig.PlaceAtAlpha(rig.Definition.CruiseSpeed, rc::units::Degrees(3.0), 260.0);
    rig.State.PositionWorld.x = north;
    rig.State.PositionWorld.y = east + 55.0;

    const rc::AircraftForces forces = rig.Evaluate();

    // A rolling moment, and it points towards the lift: the wing in the rising
    // air comes up, so the aircraft rolls AWAY from the thermal, which is why a
    // pilot is taught to turn towards the wing that drops.
    std::printf("       rolling moment at the edge: %+.4f N m\n", forces.Total.Moment.x);
    RC_CHECK_MSG_VALUE(std::fabs(forces.Total.Moment.x) > 0.01, forces.Total.Moment.x);
}
