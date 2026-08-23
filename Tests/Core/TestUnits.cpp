#include "TestHarness.h"

#include "RCPhysics/Core/Units/Units.h"

using namespace rc;

RC_TEST(Units, AngleConversions)
{
    RC_CHECK_NEAR(units::Degrees(180.0), kPi, 1e-15);
    RC_CHECK_NEAR(units::ToDegrees(kPi * 0.5), 90.0, 1e-13);
    RC_CHECK_NEAR(units::ToDegrees(units::Degrees(37.5)), 37.5, 1e-13);
}

RC_TEST(Units, LengthConversions)
{
    // An 11x6 propeller: 11 inch diameter.
    RC_CHECK_NEAR(units::Inches(11.0), 0.2794, 1e-12);
    RC_CHECK_NEAR(units::ToInches(units::Inches(6.0)), 6.0, 1e-12);
    RC_CHECK_NEAR(units::Millimetres(1500.0), 1.5, 1e-15);
}

RC_TEST(Units, MassConversions)
{
    RC_CHECK_NEAR(units::Grams(1350.0), 1.35, 1e-15);
    RC_CHECK_NEAR(units::ToPounds(units::Pounds(3.0)), 3.0, 1e-12);
}

RC_TEST(Units, SpeedConversions)
{
    RC_CHECK_NEAR(units::KilometresPerHour(36.0), 10.0, 1e-14);
    RC_CHECK_NEAR(units::ToKilometresPerHour(10.0), 36.0, 1e-13);
    RC_CHECK_NEAR(units::Knots(1.0), 0.514444444444, 1e-12);
}

RC_TEST(Units, RotationalConversions)
{
    // 10000 RPM is a normal cruise figure for a 1000 KV motor on 3S.
    const Real radPerSec = units::RPM(10000.0);
    RC_CHECK_NEAR(units::ToRPM(radPerSec), 10000.0, 1e-9);
    RC_CHECK_NEAR(units::RPM(60.0), kTwoPi, 1e-14);
}

RC_TEST(Units, BatteryCapacityIsCoulombs)
{
    // 2200 mAh = 2.2 Ah = 7920 coulomb.
    RC_CHECK_NEAR(units::MilliampHours(2200.0), 7920.0, 1e-9);
    RC_CHECK_NEAR(units::ToMilliampHours(units::MilliampHours(2200.0)), 2200.0, 1e-9);
}

RC_TEST(Units, PhysicalConstantsAreISA)
{
    RC_CHECK_NEAR(units::kGravity, 9.80665, 1e-12);
    RC_CHECK_NEAR(units::kSeaLevelDensity, 1.225, 1e-12);
    // Density must follow from the ideal gas law with the other ISA constants.
    const Real density = units::kSeaLevelPressure
                       / (units::kAirGasConstant * units::kSeaLevelTemperature);
    RC_CHECK_NEAR(density, units::kSeaLevelDensity, 1e-3);
}
