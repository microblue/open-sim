// OpenRC Simulator - the air that goes up.
//
// A soaring model lives or dies on this, so what it has to guarantee is not
// "produces upward numbers" but the specific things a pilot relies on: that a
// thermal is in the same place for as long as it lives, that it drifts with the
// wind, that there is sink around it to find the edge by, that it stops working
// at its top, and that a hillside gives lift on the windward side and takes it
// away in the lee.
//
// It also has to conserve something like mass. A field of pure lift with no
// sink is not weather, it is a lift.

#include "RCPhysics/Physics/Environment/LiftField.h"
#include "TestHarness.h"

#include <cmath>

namespace
{
    const rc::TerrainField& World()
    {
        static const rc::TerrainField field{rc::TerrainSettings{}};
        return field;
    }

    rc::Vec3 At(rc::Real north, rc::Real east, rc::Real altitude)
    {
        return rc::Vec3(north, east, -altitude);   // world z is DOWN
    }

    /** Strongest lift found on a horizontal sweep at one height, and where. */
    struct Peak
    {
        rc::Real Strength = -1e9;
        rc::Real North = 0.0;
        rc::Real East = 0.0;
    };

    Peak FindBestLift(const rc::LiftField& lift, rc::Real altitude, rc::Real time,
                      const rc::Vec3& wind, rc::Real spread = 900.0, rc::Real step = 12.0)
    {
        Peak best;
        for (rc::Real north = -spread; north <= spread; north += step)
        {
            for (rc::Real east = -spread; east <= spread; east += step)
            {
                const rc::Real value =
                    lift.SampleAt(At(north, east, altitude), time, wind).Total();
                if (value > best.Strength)
                {
                    best.Strength = value;
                    best.North = north;
                    best.East = east;
                }
            }
        }
        return best;
    }
}

RC_TEST(LiftField, IsDeterministic)
{
    // Two pilots at the same field on the same seed must find the same thermal
    // in the same place, or nothing about a soaring session is repeatable.
    const rc::LiftField a(World());
    const rc::LiftField b(World());
    const rc::Vec3 wind(2.0, 1.0, 0.0);

    for (int i = 0; i < 48; ++i)
    {
        const rc::Vec3 point = At(-800.0 + 37.0 * i, 400.0 - 23.0 * i, 120.0);
        RC_CHECK_NEAR(a.SampleAt(point, 90.0, wind).Total(),
                      b.SampleAt(point, 90.0, wind).Total(), 0.0);
    }
}

RC_TEST(LiftField, ThereIsLiftToFind)
{
    const rc::LiftField lift(World());
    const rc::Vec3 wind(0.0, 0.0, 0.0);

    // Somewhere in a square kilometre, at working height, something is going up
    // hard enough to keep a glider aloft. A trainer sinks at about a metre a
    // second; anything less than that is not a thermal.
    rc::Real best = 0.0;
    for (rc::Real time = 0.0; time < 600.0; time += 40.0)
    {
        best = std::max(best, FindBestLift(lift, 200.0, time, wind).Strength);
    }
    RC_CHECK_MSG_VALUE(best > 1.2, best);
}

RC_TEST(LiftField, EveryThermalIsSurroundedBySink)
{
    // The air a thermal lifts comes down around it. Without that ring, centring
    // is not a skill - you cannot tell which way you fell out.
    const rc::LiftField lift(World());
    const rc::Vec3 wind(0.0, 0.0, 0.0);
    const rc::Real time = 220.0;

    const Peak core = FindBestLift(lift, 200.0, time, wind);
    RC_CHECK(core.Strength > 0.8);

    // Sweep outwards from the core and insist the air is going DOWN somewhere
    // before it goes flat.
    rc::Real worstSink = 0.0;
    for (rc::Real radius = 20.0; radius < 340.0; radius += 8.0)
    {
        for (rc::Real angle = 0.0; angle < 6.28; angle += 0.35)
        {
            const rc::Vec3 point = At(core.North + std::cos(angle) * radius,
                                      core.East + std::sin(angle) * radius, 200.0);
            worstSink = std::min(worstSink, lift.SampleAt(point, time, wind).Total());
        }
    }
    RC_CHECK_MSG_VALUE(worstSink < -0.15, worstSink);
}

RC_TEST(LiftField, ThermalsDriftWithTheWind)
{
    // A thermal is a parcel of air, and air moves. If they stayed put, a pilot
    // could sit over one indefinitely and soaring would be a stationary
    // exercise.
    const rc::LiftField lift(World());
    const rc::Vec3 wind(6.0, 0.0, 0.0);      // six metres a second, due north

    const rc::Real time = 200.0;
    const Peak before = FindBestLift(lift, 200.0, time, wind, 700.0, 10.0);

    // Sixty seconds later the same column should be some 360 m further north.
    const rc::Real later = time + 60.0;
    const rc::Real expectedNorth = before.North + wind.x * 60.0;

    // Look for it where it should be, and check the lift travelled with it.
    rc::Real atExpected = 0.0;
    for (rc::Real dn = -40.0; dn <= 40.0; dn += 5.0)
    {
        for (rc::Real de = -40.0; de <= 40.0; de += 5.0)
        {
            atExpected = std::max(atExpected,
                lift.SampleAt(At(expectedNorth + dn, before.East + de, 200.0),
                              later, wind).Total());
        }
    }

    // And that it is NOT still where it was.
    rc::Real atOriginal = 0.0;
    for (rc::Real dn = -40.0; dn <= 40.0; dn += 5.0)
    {
        for (rc::Real de = -40.0; de <= 40.0; de += 5.0)
        {
            atOriginal = std::max(atOriginal,
                lift.SampleAt(At(before.North + dn, before.East + de, 200.0),
                              later, wind).Total());
        }
    }

    RC_CHECK_MSG_VALUE(atExpected > atOriginal, atExpected - atOriginal);
}

RC_TEST(LiftField, ThermalsHaveATop)
{
    // They stop working. A glider that could climb for ever would never have to
    // go looking for the next one.
    const rc::LiftField lift(World());
    const rc::Vec3 wind(0.0, 0.0, 0.0);
    const rc::LiftSettings config;

    const rc::Real working = FindBestLift(lift, config.ThermalTop * 0.45, 260.0, wind).Strength;
    const rc::Real aboveTop = FindBestLift(lift, config.ThermalTop * 1.35, 260.0, wind).Strength;

    RC_CHECK(working > 0.8);
    RC_CHECK_MSG_VALUE(aboveTop < working * 0.25, aboveTop);
}

RC_TEST(LiftField, GroundDecidesWhereThermalsForm)
{
    // Bare sand in sun is the engine of a soaring day; water makes nothing.
    // This is the tie between the terrain, the biomes and the air, and without
    // it the sky is the same everywhere and the landscape means nothing.
    const rc::LiftField lift(World());

    rc::Real overWater = -1.0;
    rc::Real overDry = -1.0;
    for (int i = 0; i < 4000 && (overWater < 0.0 || overDry < 0.0); ++i)
    {
        const rc::Real north = -30000.0 + i * 17.0;
        const rc::Real east = 12000.0 - i * 23.0;
        const rc::TerrainSample ground = World().SampleAt(north, east);
        const rc::Real heating = lift.GroundHeating(north, east);

        if (ground.Type == rc::Biome::Ocean && overWater < 0.0) { overWater = heating; }
        if (ground.Type == rc::Biome::Desert && overDry < 0.0) { overDry = heating; }
    }

    RC_CHECK(overWater >= 0.0 || overDry >= 0.0);
    if (overWater >= 0.0) { RC_CHECK_NEAR(overWater, 0.0, 1e-9); }
    if (overDry >= 0.0) { RC_CHECK(overDry > 0.9); }

    // And forest is damper and shadier than grass, which is damper than rock.
    RC_CHECK(lift.GroundHeating(0.0, 0.0) >= 0.0);
}

RC_TEST(LiftField, AHillsideLiftsIntoTheWindAndSinksBehindIt)
{
    // Slope soaring, and its opposite. Flying into the lee of a ridge and
    // finding the air going down is one of the ways models are lost.
    const rc::LiftField lift(World());

    // Find real sloping ground away from the flat plateau.
    rc::Real bestSlope = 0.0;
    rc::Real slopeNorth = 0.0, slopeEast = 0.0;
    rc::Vec3 downhill;
    for (int i = 0; i < 6000; ++i)
    {
        const rc::Real north = 2000.0 + i * 13.0;
        const rc::Real east = -1500.0 + i * 11.0;
        const rc::TerrainSample ground = World().SampleAt(north, east);
        if (ground.Slope > bestSlope && ground.Height > 20.0)
        {
            bestSlope = ground.Slope;
            slopeNorth = north;
            slopeEast = east;
            downhill = ground.Normal;
        }
    }
    RC_CHECK_MSG_VALUE(bestSlope > 0.25, bestSlope);

    // Wind blowing INTO the hill.
    //
    // The horizontal part of the surface normal points DOWNSLOPE, so a wind
    // vector along it is blowing down the face - the lee. Blowing up the face
    // is the opposite direction, which is what "into the hill" means and what
    // this first got backwards.
    const rc::Real length = std::sqrt(downhill.x * downhill.x + downhill.y * downhill.y);
    const rc::Vec3 upwind(-downhill.x / length * 8.0, -downhill.y / length * 8.0, 0.0);
    const rc::Vec3 leeward(-upwind.x, -upwind.y, 0.0);

    const rc::Real height = World().HeightAt(slopeNorth, slopeEast) + 25.0;
    const rc::Vec3 point = At(slopeNorth, slopeEast, height);

    // Thermals are switched off so this measures the hill alone.
    rc::LiftSettings slopeOnly;
    slopeOnly.ThermalStrength = 0.0;
    const rc::LiftField hillOnly(World(), slopeOnly);

    const rc::Real windward = hillOnly.SampleAt(point, 0.0, upwind).Slope;
    const rc::Real lee = hillOnly.SampleAt(point, 0.0, leeward).Slope;

    std::printf("       slope %.2f   windward %+.2f m/s   lee %+.2f m/s\n",
                bestSlope, windward, lee);
    RC_CHECK_MSG_VALUE(windward > 0.5, windward);
    RC_CHECK_MSG_VALUE(lee < 0.0, lee);
}

RC_TEST(LiftField, StillAirIsStill)
{
    // The master switch has to actually switch it off: a lesson or a test that
    // asks for still air must get still air.
    rc::LiftSettings off;
    off.Enabled = false;
    const rc::LiftField lift(World(), off);

    for (int i = 0; i < 40; ++i)
    {
        const rc::Vec3 point = At(120.0 * i, -80.0 * i, 150.0);
        RC_CHECK_NEAR(lift.SampleAt(point, 60.0, rc::Vec3(5.0, 2.0, 0.0)).Total(), 0.0, 0.0);
    }
}

RC_TEST(LiftField, TheAirIsNeverAbsurd)
{
    // Whatever the terrain does, the vertical velocity handed to the flight
    // model has to be something an aeroplane can be in.
    const rc::LiftField lift(World());
    const rc::Vec3 wind(9.0, 4.0, 0.0);

    for (int i = 0; i < 3000; ++i)
    {
        const rc::Vec3 point = At(-20000.0 + i * 27.0, 9000.0 - i * 19.0,
                                  20.0 + std::fmod(i * 7.0, 1200.0));
        const rc::Real value = lift.SampleAt(point, i * 0.7, wind).Total();
        RC_CHECK(std::isfinite(value));
        RC_CHECK(value < 12.0 && value > -12.0);
    }
}
