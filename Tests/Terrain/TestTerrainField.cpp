// OpenRC Simulator - the shape of the world.
//
// The terrain function is the one piece of geometry the physics and the
// renderer BOTH depend on, so what it must guarantee is not "looks nice" but
// "is the same surface every time, everywhere, for both callers". These pin
// that, plus the properties the flight model relies on: the strip is flat, the
// world has water and mountains rather than being uniformly bumpy, and nothing
// anywhere returns a value the integrator cannot use.

#include "RCPhysics/Physics/Ground/TerrainField.h"
#include "TestHarness.h"

#include <cmath>

namespace
{
    rc::TerrainField DefaultField() { return rc::TerrainField(rc::TerrainSettings{}); }
}

RC_TEST(TerrainField, IsDeterministic)
{
    // Everything rests on this. Two evaluations of the same point, from
    // different instances, must agree bit for bit - otherwise the ground the
    // aircraft hits is not the ground that was drawn.
    const rc::TerrainField a = DefaultField();
    const rc::TerrainField b = DefaultField();

    for (int i = 0; i < 64; ++i)
    {
        const rc::Real north = -9000.0 + 291.0 * i;
        const rc::Real east  =  4200.0 - 173.0 * i;
        RC_CHECK_NEAR(a.HeightAt(north, east), b.HeightAt(north, east), 0.0);
    }
}

RC_TEST(TerrainField, SampleAgreesWithHeight)
{
    // SampleAt does more work than HeightAt but must not disagree with it: the
    // renderer uses one and the collision surface the other.
    const rc::TerrainField field = DefaultField();
    for (int i = 0; i < 32; ++i)
    {
        const rc::Real north = 1500.0 * std::sin(0.7 * i);
        const rc::Real east  = 1500.0 * std::cos(1.1 * i);
        RC_CHECK_NEAR(field.SampleAt(north, east).Height, field.HeightAt(north, east), 0.0);
    }
}

RC_TEST(TerrainField, TheFlyingFieldIsFlat)
{
    // The strip has to stay level: the landing gear model, the ground handling
    // and every locked performance target were measured on flat ground.
    const rc::TerrainField field = DefaultField();
    const rc::Real centre = field.HeightAt(0.0, 0.0);

    rc::Real worst = 0.0;
    for (int i = 0; i < 400; ++i)
    {
        const rc::Real angle = 0.0157 * i;
        const rc::Real radius = 380.0;
        const rc::Real height = field.HeightAt(std::cos(angle) * radius,
                                               std::sin(angle) * radius);
        worst = std::max(worst, std::fabs(height - centre));
    }
    RC_CHECK_MSG_VALUE(worst < 0.05, worst);

    // And it is at the elevation the settings asked for.
    RC_CHECK_NEAR(centre, rc::TerrainSettings{}.FieldElevation, 0.05);
}

RC_TEST(TerrainField, TerrainRisesOutsideThePlateau)
{
    // If the blend were too gentle the world would be a saucer, and the
    // mountains the pilot can see would be an hour's flight away.
    const rc::TerrainField field = DefaultField();

    rc::Real highest = -1e9;
    rc::Real lowest  =  1e9;
    for (int i = 0; i < 2000; ++i)
    {
        const rc::Real angle = 0.031 * i;
        const rc::Real radius = 3000.0 + 9.0 * i;
        const rc::Real height = field.HeightAt(std::cos(angle) * radius,
                                               std::sin(angle) * radius);
        highest = std::max(highest, height);
        lowest  = std::min(lowest, height);
    }

    RC_CHECK_MSG_VALUE(highest > 400.0, highest);
    RC_CHECK_MSG_VALUE(lowest < 40.0, lowest);
}

RC_TEST(TerrainField, TheWorldHasWaterAndMountains)
{
    // A world that is all one biome is the failure this replaced, in the other
    // direction. Sample a wide area and insist on genuine variety.
    const rc::TerrainField field = DefaultField();

    int counts[static_cast<size_t>(rc::Biome::Count)] = {0};
    for (int ix = -40; ix <= 40; ++ix)
    {
        for (int iy = -40; iy <= 40; ++iy)
        {
            const rc::TerrainSample sample =
                field.SampleAt(ix * 900.0, iy * 900.0);
            counts[static_cast<size_t>(sample.Type)] += 1;
        }
    }

    RC_CHECK(counts[static_cast<size_t>(rc::Biome::Ocean)] > 0);
    RC_CHECK(counts[static_cast<size_t>(rc::Biome::Grassland)] > 0);

    int represented = 0;
    for (int i = 0; i < static_cast<int>(rc::Biome::Count); ++i)
    {
        if (counts[i] > 0) { ++represented; }
    }
    RC_CHECK_MSG_VALUE(represented >= 5, represented);
}

RC_TEST(TerrainField, NormalsArePlausibleEverywhere)
{
    const rc::TerrainField field = DefaultField();
    for (int i = 0; i < 500; ++i)
    {
        const rc::Real north = -12000.0 + 51.0 * i;
        const rc::Real east  =  8000.0 - 37.0 * i;
        const rc::TerrainSample sample = field.SampleAt(north, east);

        RC_CHECK_NEAR(sample.Normal.Length(), 1.0, 1e-9);
        // World Z points down, so an upward normal is negative in z. It must
        // never point into the ground or the contact solver would push the
        // aircraft under.
        RC_CHECK(sample.Normal.z < 0.0);
        RC_CHECK(std::isfinite(sample.Height));
    }
}

RC_TEST(TerrainField, TheFieldIsFlatEnoughForTheNormalToPointStraightUp)
{
    const rc::TerrainField field = DefaultField();
    const rc::TerrainSample sample = field.SampleAt(0.0, 0.0);
    RC_CHECK_NEAR(sample.Normal.x, 0.0, 1e-6);
    RC_CHECK_NEAR(sample.Normal.y, 0.0, 1e-6);
    RC_CHECK_NEAR(sample.Normal.z, -1.0, 1e-6);
    RC_CHECK(sample.Slope < 0.001);
}

RC_TEST(TerrainGround, ReportsTheSurfaceInWorldAxes)
{
    // GroundSample carries world Z, which points DOWN. A surface 120 m above
    // sea level is at z = -120; getting this backwards would put the whole
    // world upside down under the aircraft.
    const rc::TerrainField field = DefaultField();
    const rc::TerrainGround ground(field);

    const rc::GroundSample sample = ground.Sample(0.0, 0.0);
    RC_CHECK_NEAR(sample.SurfaceHeight, -rc::TerrainSettings{}.FieldElevation, 0.05);
    RC_CHECK(sample.Normal.z < 0.0);
}

RC_TEST(TerrainGround, SurfacesDifferInHowTheyRoll)
{
    // Sand drags, snow does not grip, water stops you. If these were all the
    // same the biomes would be paint.
    rc::TerrainSettings settings;
    const rc::TerrainField field(settings);
    const rc::TerrainGround ground(field);

    // Find one of each and check they are not identical.
    bool sawDistinct = false;
    rc::Real firstFriction = -1.0;
    for (int i = 0; i < 4000 && !sawDistinct; ++i)
    {
        const rc::Real north = -20000.0 + 13.0 * i;
        const rc::Real east  =  7000.0 + 29.0 * i;
        const rc::GroundSample sample = ground.Sample(north, east);
        if (firstFriction < 0.0) { firstFriction = sample.FrictionScale; }
        else if (std::fabs(sample.FrictionScale - firstFriction) > 1e-6) { sawDistinct = true; }
    }
    RC_CHECK(sawDistinct);
}
