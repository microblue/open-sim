#include "TestHarness.h"

#include "RCPhysics/Physics/Environment/Atmosphere.h"

using namespace rc;

RC_TEST(Atmosphere, SeaLevelMatchesISA)
{
    const AtmosphereSample sample = Atmosphere::StandardSeaLevel();
    RC_CHECK_NEAR(sample.Pressure, 101325.0, 1.0);
    RC_CHECK_NEAR(sample.Temperature, 288.15, 1e-9);
    RC_CHECK_NEAR(sample.Density, 1.225, 1e-3);
    RC_CHECK_NEAR(sample.SpeedOfSound, 340.29, 0.05);
}

RC_TEST(Atmosphere, ViscosityMatchesSutherland)
{
    // The published value at 15 C is 1.789e-5 Pa*s. Reynolds number depends
    // directly on this, and Reynolds number is what separates RC aerodynamics
    // from full-scale aerodynamics - so it gets a tight check.
    RC_CHECK_NEAR(Atmosphere::DynamicViscosityAt(288.15), 1.789e-5, 2e-8);
    // And it must rise with temperature, unlike a liquid.
    RC_CHECK(Atmosphere::DynamicViscosityAt(310.0) > Atmosphere::DynamicViscosityAt(288.15));
}

RC_TEST(Atmosphere, DensityFallsWithAltitude)
{
    Atmosphere atmosphere;
    const Real seaLevel = atmosphere.SampleAboveSeaLevel(0.0).Density;
    const Real at1000   = atmosphere.SampleAboveSeaLevel(1000.0).Density;
    const Real at3000   = atmosphere.SampleAboveSeaLevel(3000.0).Density;

    RC_CHECK(at1000 < seaLevel);
    RC_CHECK(at3000 < at1000);
    // ISA at 1000 m is 1.112 kg/m^3.
    RC_CHECK_NEAR(at1000, 1.112, 5e-3);
}

RC_TEST(Atmosphere, FieldElevationShiftsTheSample)
{
    Atmosphere atmosphere;
    atmosphere.SetFieldElevation(600.0);

    const AtmosphereSample atField = atmosphere.SampleAboveField(0.0);
    const AtmosphereSample direct  = atmosphere.SampleAboveSeaLevel(600.0);
    RC_CHECK_NEAR(atField.Density, direct.Density, 1e-12);

    // A 600 m field is about 6 % down on density, which is 3 % on stall speed -
    // small, but exactly the sort of thing a pilot notices on a hot day.
    RC_CHECK(atField.Density < 0.95 * units::kSeaLevelDensity);
    RC_CHECK(atField.Density > 0.92 * units::kSeaLevelDensity);
}

RC_TEST(Atmosphere, HotDayThinsTheAir)
{
    Atmosphere atmosphere;
    const Real standard = atmosphere.SampleAboveField(0.0).Density;

    atmosphere.SetTemperatureOffset(20.0);
    const Real hot = atmosphere.SampleAboveField(0.0).Density;

    RC_CHECK(hot < standard);
    // 20 K on 288 K is about 6.5 % of density.
    RC_CHECK_NEAR(hot / standard, 288.15 / 308.15, 1e-3);
}

RC_TEST(Atmosphere, ReynoldsNumberForTheTrainerAtCruise)
{
    // 0.2133 m chord at 16 m/s, sea level. This is THE number that makes an RC
    // model behave unlike a full-scale aircraft: a light aircraft cruises an
    // order of magnitude higher.
    const AtmosphereSample sample = Atmosphere::StandardSeaLevel();
    const Real reynolds = Atmosphere::ReynoldsNumber(sample, 16.0, 0.2133);

    RC_CHECK(reynolds > 2.0e5 && reynolds < 2.6e5);
    // Near the stall it drops by nearly half, which is why the coefficients
    // cannot be treated as Reynolds independent.
    const Real atStall = Atmosphere::ReynoldsNumber(sample, 8.3, 0.2133);
    RC_CHECK(atStall < 0.6 * reynolds);
}

RC_TEST(Atmosphere, DegenerateInputsAreSafe)
{
    const AtmosphereSample sample = Atmosphere::StandardSeaLevel();
    RC_CHECK_NEAR(Atmosphere::ReynoldsNumber(sample, 16.0, 0.0), 0.0, 1e-15);
    RC_CHECK_NEAR(Atmosphere::ReynoldsNumber(sample, 0.0, 0.2), 0.0, 1e-15);

    Atmosphere atmosphere;
    atmosphere.SetFieldElevation(1e9);
    RC_CHECK(atmosphere.SampleAboveField(0.0).Density > 0.0);
    RC_CHECK(IsFinite(atmosphere.SampleAboveField(1e9).Density));
}
