#include "TestHarness.h"

#include "RCPhysics/Core/Math/LookupTable.h"
#include "RCPhysics/Core/Units/Units.h"

using namespace rc;

RC_TEST(Table1D, RejectsMalformedInput)
{
    Table1D table;
    std::string error;

    RC_CHECK(!table.Build({}, {}, &error));
    RC_CHECK(!error.empty());

    RC_CHECK(!table.Build({0.0, 1.0}, {1.0}, &error));
    RC_CHECK(!table.Build({1.0, 0.0}, {1.0, 2.0}, &error));   // not increasing
    RC_CHECK(!table.Build({0.0, 0.0}, {1.0, 2.0}, &error));   // not strictly
    RC_CHECK(table.IsEmpty());
}

RC_TEST(Table1D, InterpolatesLinearly)
{
    // A crude CL(alpha) curve for a flat-bottom trainer airfoil, degrees in.
    Table1D lift;
    RC_CHECK(lift.Build({-10.0, 0.0, 10.0, 14.0, 20.0},
                        {-0.70, 0.25, 1.20, 1.35, 0.90}));

    RC_CHECK_NEAR(lift.Evaluate(0.0),  0.25, 1e-15);
    RC_CHECK_NEAR(lift.Evaluate(5.0),  0.725, 1e-14);   // midway 0.25 -> 1.20
    RC_CHECK_NEAR(lift.Evaluate(12.0), 1.275, 1e-14);
    RC_CHECK_NEAR(lift.Evaluate(-5.0), -0.225, 1e-14);
}

RC_TEST(Table1D, ClampsOutsideTheSampledRangeByDefault)
{
    Table1D lift;
    RC_CHECK(lift.Build({-10.0, 0.0, 10.0}, {-0.70, 0.25, 1.20}));

    RC_CHECK_NEAR(lift.Evaluate(-90.0), -0.70, 1e-15);
    RC_CHECK_NEAR(lift.Evaluate( 90.0),  1.20, 1e-15);
    RC_CHECK_NEAR(lift.EvaluateSlope(90.0), 0.0, 1e-15);
}

RC_TEST(Table1D, LinearExtrapolationContinuesTheEdgeSlope)
{
    Table1D table;
    RC_CHECK(table.Build({0.0, 1.0, 2.0}, {0.0, 2.0, 4.0}));
    table.SetExtrapolation(ExtrapolationMode::Linear);

    RC_CHECK_NEAR(table.Evaluate(3.0), 6.0, 1e-14);
    RC_CHECK_NEAR(table.Evaluate(-1.0), -2.0, 1e-14);
}

RC_TEST(Table1D, SlopeMatchesTheSegment)
{
    // Lift-curve slope of a real wing is roughly 0.1 per degree; check the
    // table reports the slope we built into it.
    Table1D lift;
    RC_CHECK(lift.Build({0.0, 10.0}, {0.25, 1.25}));
    RC_CHECK_NEAR(lift.EvaluateSlope(5.0), 0.1, 1e-14);
}

RC_TEST(Table1D, SinglePointBehavesAsAConstant)
{
    Table1D table;
    RC_CHECK(table.Build({3.0}, {7.0}));
    RC_CHECK_NEAR(table.Evaluate(-100.0), 7.0, 1e-15);
    RC_CHECK_NEAR(table.Evaluate(100.0), 7.0, 1e-15);
}

RC_TEST(Table2D, RejectsMalformedInput)
{
    Table2D table;
    std::string error;
    RC_CHECK(!table.Build({}, {1.0}, {1.0}, &error));
    RC_CHECK(!table.Build({0.0, 1.0}, {0.0, 1.0}, {1.0, 2.0, 3.0}, &error));
    RC_CHECK(table.IsEmpty());
}

RC_TEST(Table2D, BilinearInterpolation)
{
    // CL(alpha, Reynolds). Rows = alpha [deg], columns = Re.
    // Low Reynolds costs peak lift, which is exactly the RC-scale effect the
    // architecture has to leave room for.
    Table2D lift;
    RC_CHECK(lift.Build(/*rows: alpha*/   {0.0, 10.0},
                        /*cols: Reynolds*/{50000.0, 200000.0},
                        /*values*/        {0.20, 0.25,
                                           1.00, 1.20}));

    RC_CHECK_NEAR(lift.Evaluate(0.0, 50000.0), 0.20, 1e-15);
    RC_CHECK_NEAR(lift.Evaluate(10.0, 200000.0), 1.20, 1e-15);
    RC_CHECK_NEAR(lift.Evaluate(5.0, 125000.0), 0.6625, 1e-14);
    // Clamped outside the grid.
    RC_CHECK_NEAR(lift.Evaluate(30.0, 1e7), 1.20, 1e-15);
}
