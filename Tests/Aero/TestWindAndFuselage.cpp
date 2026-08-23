#include "TestHarness.h"

#include "RCPhysics/Physics/Aero/FuselageAero.h"
#include "RCPhysics/Physics/Environment/WindField.h"
#include "RCPhysics/Core/Units/Units.h"

using namespace rc;

// ------------------------------------------------------------- wind field ---

RC_TEST(WindField, SteadyWindUsesTheMeteorologicalConvention)
{
    // "Wind 270 at 5" means it blows FROM the west, TOWARDS the east. In NED
    // that is a velocity vector pointing east, +Y.
    WindField wind;
    wind.SetSteady(5.0, units::Degrees(270.0));

    const Vec3 velocity = wind.SteadyVector();
    RC_CHECK_NEAR(velocity.x, 0.0, 1e-12);
    RC_CHECK_NEAR(velocity.y, 5.0, 1e-12);
    RC_CHECK_NEAR(velocity.z, 0.0, 1e-15);

    // A northerly blows from the north, towards the south: -X.
    wind.SetSteady(5.0, units::Degrees(0.0));
    RC_CHECK_NEAR(wind.SteadyVector().x, -5.0, 1e-12);
}

RC_TEST(WindField, StillAirIsExactlyStill)
{
    WindField wind;
    RC_CHECK(wind.SampleWorld(Vec3(10.0, -20.0, -50.0)).IsNearlyZero());
    wind.Advance(5.0);
    RC_CHECK(wind.SampleWorld(Vec3(10.0, -20.0, -50.0)).IsNearlyZero());
}

RC_TEST(WindField, IsDeterministicForAGivenSeed)
{
    // The property the whole regression suite rests on: a takeoff distance test
    // cannot be repeatable if the gusts are not.
    auto run = [](std::uint32_t seed)
    {
        WindField wind;
        wind.SetSeed(seed);
        wind.SetSteady(4.0, units::Degrees(240.0));
        wind.SetGust(3.0, 8.0);
        wind.SetTurbulence(1.2, 6.0);

        std::vector<Vec3> samples;
        for (int i = 0; i < 200; ++i)
        {
            wind.Advance(1.0 / 60.0);
            samples.push_back(wind.SampleWorld(Vec3(i * 0.3, 0.0, -30.0)));
        }
        return samples;
    };

    const std::vector<Vec3> a = run(12345u);
    const std::vector<Vec3> b = run(12345u);
    const std::vector<Vec3> c = run(999u);

    bool identical = true;
    bool different = false;
    for (size_t i = 0; i < a.size(); ++i)
    {
        if (!NearlyEqual(a[i], b[i], 1e-15)) { identical = false; }
        if (!NearlyEqual(a[i], c[i], 1e-9))  { different = true; }
    }
    RC_CHECK(identical);   // same seed, same air
    RC_CHECK(different);   // different seed, different air
}

RC_TEST(WindField, TurbulenceHasRoughlyTheRequestedIntensity)
{
    WindField wind;
    wind.SetSeed(7u);
    wind.SetTurbulence(2.0, 8.0);

    Real sumSquares = 0.0;
    int count = 0;
    for (int i = 0; i < 4000; ++i)
    {
        const Vec3 sample = wind.SampleWorld(Vec3(i * 0.37, i * 0.11, -20.0 - i * 0.05));
        sumSquares += sample.LengthSquared();
        ++count;
    }

    // Three axes, each with the requested RMS.
    const Real rmsPerAxis = std::sqrt(sumSquares / (3.0 * count));
    RC_CHECK(rmsPerAxis > 1.4 && rmsPerAxis < 2.8);
}

RC_TEST(WindField, TurbulenceVariesOverAWingspan)
{
    // If the field were uniform in space it would only displace the aircraft.
    // A length scale near the span is what makes it ROLL the aircraft.
    WindField wind;
    wind.SetSeed(3u);
    wind.SetTurbulence(1.5, 4.0);

    Real biggestDifference = 0.0;
    for (int i = 0; i < 500; ++i)
    {
        const Vec3 centre(i * 0.9, 0.0, -25.0);
        const Vec3 leftTip  = centre + Vec3(0.0, -0.75, 0.0);
        const Vec3 rightTip = centre + Vec3(0.0,  0.75, 0.0);
        const Real difference =
            (wind.SampleWorld(rightTip) - wind.SampleWorld(leftTip)).Length();
        biggestDifference = Max(biggestDifference, difference);
    }
    RC_CHECK(biggestDifference > 0.5);
}

RC_TEST(WindField, GustsRiseAndFallSmoothly)
{
    WindField wind;
    wind.SetSeed(21u);
    wind.SetSteady(4.0, units::Degrees(270.0));
    wind.SetGust(4.0, 6.0);

    Real previous = wind.GustFraction();
    Real peak = 0.0;
    bool everZero = false;
    const Real dt = 1.0 / 120.0;

    for (int i = 0; i < 120 * 60; ++i)
    {
        wind.Advance(dt);
        const Real fraction = wind.GustFraction();
        RC_CHECK(fraction >= 0.0 && fraction <= 1.0);
        // No steps: a gust that arrived instantly would be an impulse, not wind.
        if (std::fabs(fraction - previous) > 0.02)
        {
            RC_FAIL("gust envelope stepped discontinuously");
            break;
        }
        if (fraction < 1e-9) { everZero = true; }
        peak = Max(peak, fraction);
        previous = fraction;
    }

    RC_CHECK(peak > 0.3);      // gusts actually happen
    RC_CHECK(everZero);        // and they end
}

RC_TEST(WindField, GustAddsAlongTheMeanWind)
{
    WindField wind;
    wind.SetSeed(5u);
    wind.SetSteady(4.0, units::Degrees(270.0));   // blowing east
    wind.SetGust(6.0, 4.0);

    Real strongest = 0.0;
    for (int i = 0; i < 2000; ++i)
    {
        wind.Advance(1.0 / 60.0);
        strongest = Max(strongest, wind.SampleWorld(Vec3::Zero()).y);
    }
    RC_CHECK(strongest > 4.5);    // gusting above the steady 4 m/s
    RC_CHECK(strongest <= 10.1);  // and not above steady + amplitude
}

RC_TEST(WindField, ResetReturnsToTheStartOfTheSequence)
{
    WindField wind;
    wind.SetSeed(42u);
    wind.SetTurbulence(1.0, 5.0);

    const Vec3 first = wind.SampleWorld(Vec3(3.0, 1.0, -10.0));
    wind.Advance(7.5);
    RC_CHECK(!NearlyEqual(wind.SampleWorld(Vec3(3.0, 1.0, -10.0)), first, 1e-9));

    wind.Reset();
    RC_CHECK(NearlyEqual(wind.SampleWorld(Vec3(3.0, 1.0, -10.0)), first, 1e-15));
}

// ---------------------------------------------------------------- fuselage --

namespace
{
    FuselageSpec TrainerFuselage()
    {
        FuselageSpec s;
        s.PositionBody = Vec3(0.05, 0.0, 0.0);
        s.Length = 1.05;
        s.FrontalArea = 0.011;
        s.SideArea = 0.055;
        s.CdFrontal = 0.35;
        s.CdSide = 0.60;
        s.CnBetaPerRad = -0.06;
        s.ParasiteArea = 0.030;
        return s;
    }

    AeroEnvironment At(const Vec3& velocity)
    {
        AeroEnvironment e;
        e.AirVelocityBody = velocity;
        e.Atmosphere = Atmosphere::StandardSeaLevel();
        return e;
    }
}

RC_TEST(FuselageAero, DragOpposesMotionOnEveryAxis)
{
    FuselageAero fuselage;
    fuselage.Configure(TrainerFuselage());

    RC_CHECK(fuselage.Evaluate(At(Vec3(16.0, 0.0, 0.0))).ForceBody.x < 0.0);
    RC_CHECK(fuselage.Evaluate(At(Vec3(-16.0, 0.0, 0.0))).ForceBody.x > 0.0);
    RC_CHECK(fuselage.Evaluate(At(Vec3(0.0, 5.0, 0.0))).ForceBody.y < 0.0);
    RC_CHECK(fuselage.Evaluate(At(Vec3(0.0, 0.0, 5.0))).ForceBody.z < 0.0);
}

RC_TEST(FuselageAero, DragGrowsWithTheSquareOfSpeed)
{
    FuselageAero fuselage;
    fuselage.Configure(TrainerFuselage());

    const Real slow = -fuselage.Evaluate(At(Vec3(8.0, 0.0, 0.0))).ForceBody.x;
    const Real fast = -fuselage.Evaluate(At(Vec3(16.0, 0.0, 0.0))).ForceBody.x;
    RC_CHECK_NEAR(fast / slow, 4.0, 1e-9);

    // And it is the biggest single non-lifting drag item on the aircraft.
    RC_CHECK(fast > 1.0 && fast < 6.0);
}

RC_TEST(FuselageAero, BodyIsDirectionallyDestabilising)
{
    // A volume ahead of the CG wants to swap ends. The fin has to beat this,
    // and sizing a fin without modelling it gives an aircraft that is
    // unrealistically solid in yaw.
    FuselageAero fuselage;
    fuselage.Configure(TrainerFuselage());

    const FuselageResult slipRight = fuselage.Evaluate(At(Vec3(16.0, 2.0, 0.0)));
    RC_CHECK(slipRight.Sideslip > 0.0);
    RC_CHECK(slipRight.MomentBody.z < 0.0);   // nose left, away from the wind

    const FuselageResult slipLeft = fuselage.Evaluate(At(Vec3(16.0, -2.0, 0.0)));
    RC_CHECK(slipLeft.MomentBody.z > 0.0);
    RC_CHECK_NEAR(slipLeft.MomentBody.z, -slipRight.MomentBody.z, 1e-12);
}

RC_TEST(FuselageAero, StationaryProducesNothing)
{
    FuselageAero fuselage;
    fuselage.Configure(TrainerFuselage());
    const FuselageResult result = fuselage.Evaluate(At(Vec3::Zero()));
    RC_CHECK(result.ForceBody.IsNearlyZero());
    RC_CHECK(result.MomentBody.IsNearlyZero());
}

RC_TEST(FuselageAero, ParasiteAreaRaisesDrag)
{
    FuselageSpec clean = TrainerFuselage();
    clean.ParasiteArea = 0.0;

    FuselageAero bare, laden;
    bare.Configure(clean);
    laden.Configure(TrainerFuselage());

    const Real bareDrag  = -bare.Evaluate(At(Vec3(16.0, 0.0, 0.0))).ForceBody.x;
    const Real ladenDrag = -laden.Evaluate(At(Vec3(16.0, 0.0, 0.0))).ForceBody.x;
    RC_CHECK(ladenDrag > 2.0 * bareDrag);
}
