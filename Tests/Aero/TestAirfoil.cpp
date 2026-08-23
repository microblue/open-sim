#include "TestHarness.h"

#include "RCPhysics/Physics/Aero/Airfoil.h"
#include "RCPhysics/Core/Units/Units.h"

using namespace rc;

namespace
{
    /** The Trainer 1500's wing section, as shipped in Trainer1500.json. */
    AirfoilParameters TrainerFlatBottom()
    {
        AirfoilParameters p;
        p.ClZeroAlpha       = 0.30;
        p.ClAlphaPerRad     = 5.70;
        p.ClMax             = 1.20;
        p.AlphaStall        = units::Degrees(13.0);
        p.StallBlend        = units::Degrees(5.0);
        p.ReattachHysteresis = units::Degrees(2.5);
        p.CdMin             = 0.016;
        p.CdAlphaQuadratic  = 0.012;
        p.CdSeparatedMax    = 1.30;
        p.CmQuarterChord    = -0.075;
        p.OswaldEfficiency  = 0.85;
        p.ReferenceReynolds = 200000.0;
        return p;
    }

    AirfoilParameters SymmetricTail()
    {
        AirfoilParameters p;
        p.ClZeroAlpha       = 0.0;
        p.ClAlphaPerRad     = 5.50;
        p.ClMax             = 1.00;
        p.AlphaStall        = units::Degrees(12.0);
        p.StallBlend        = units::Degrees(3.5);
        p.ReattachHysteresis = units::Degrees(2.0);
        p.CdMin             = 0.012;
        p.CdSeparatedMax    = 1.25;
        p.CmQuarterChord    = 0.0;
        p.OswaldEfficiency  = 0.80;
        p.ReferenceReynolds = 120000.0;
        return p;
    }

    constexpr Real kWingAspectRatio = 7.03;
    constexpr Real kCruiseReynolds  = 233000.0;

    AirfoilQuery Query(Real alphaDegrees, Real aspectRatio = kWingAspectRatio,
                       Real reynolds = kCruiseReynolds)
    {
        AirfoilQuery q;
        q.Alpha = units::Degrees(alphaDegrees);
        q.AspectRatio = aspectRatio;
        q.Reynolds = reynolds;
        return q;
    }
}

// ---------------------------------------------------------------- geometry --

RC_TEST(Airfoil, FlapEffectivenessMatchesThinAirfoilTheory)
{
    // tau = 1 - (theta - sin theta)/pi with theta = acos(2E - 1).
    RC_CHECK_NEAR(Airfoil::FlapEffectiveness(0.25), 0.60900, 1e-4);   // aileron
    RC_CHECK_NEAR(Airfoil::FlapEffectiveness(0.40), 0.74779, 1e-4);   // elevator
    RC_CHECK_NEAR(Airfoil::FlapEffectiveness(0.45), 0.78483, 1e-4);   // rudder

    // A control surface is always less effective than its chord fraction is
    // large would naively suggest, but more than proportionally so.
    RC_CHECK(Airfoil::FlapEffectiveness(0.25) > 0.25);
    RC_CHECK(Airfoil::FlapEffectiveness(0.25) < 1.0);

    RC_CHECK_NEAR(Airfoil::FlapEffectiveness(0.0), 0.0, 1e-12);
    RC_CHECK_NEAR(Airfoil::FlapEffectiveness(1.0), 1.0, 1e-12);
    RC_CHECK_NEAR(Airfoil::FlapEffectiveness(-1.0), 0.0, 1e-12);
}

RC_TEST(Airfoil, FiniteWingReducesTheLiftCurveSlope)
{
    const Airfoil wing(TrainerFlatBottom());

    // a3D = a0 / (1 + a0/(pi*AR*e)) = 5.7 / (1 + 5.7/(pi*7.03*0.85))
    RC_CHECK_NEAR(wing.LiftCurveSlope(kWingAspectRatio), 4.3724, 1e-3);
    RC_CHECK(wing.LiftCurveSlope(kWingAspectRatio) < 5.70);

    // The fin's aspect ratio is under 2, and its slope is far shallower - which
    // is exactly why a fin needs so much area to do its job.
    RC_CHECK(wing.LiftCurveSlope(1.80) < 0.6 * wing.LiftCurveSlope(kWingAspectRatio));

    // Monotonic in aspect ratio, and approaching the 2D value in the limit.
    RC_CHECK(wing.LiftCurveSlope(20.0) > wing.LiftCurveSlope(7.0));
    RC_CHECK(wing.LiftCurveSlope(1000.0) < 5.70);
    RC_CHECK(wing.LiftCurveSlope(1000.0) > 5.60);
}

RC_TEST(Airfoil, CamberSetsTheZeroLiftAngle)
{
    const Airfoil wing(TrainerFlatBottom());
    // -Cl0/a0 = -0.30/5.70 = -0.05263 rad = -3.016 deg.
    RC_CHECK_NEAR(units::ToDegrees(wing.ZeroLiftAngle()), -3.016, 1e-2);
    RC_CHECK(wing.ZeroLiftAngle() < 0.0);

    // A symmetric section produces no lift at zero alpha, by definition.
    const Airfoil tail(SymmetricTail());
    RC_CHECK_NEAR(tail.ZeroLiftAngle(), 0.0, 1e-15);
    RC_CHECK_NEAR(tail.Evaluate(Query(0.0, 3.04, 120000.0)).Cl, 0.0, 1e-12);
}

// ------------------------------------------------------------ lift curve ----

RC_TEST(Airfoil, LiftIsLinearBelowTheStall)
{
    const Airfoil wing(TrainerFlatBottom());
    const Real slope = wing.LiftCurveSlope(kWingAspectRatio);

    // Two points well inside the attached region must lie on the same line.
    const Real cl2 = wing.Evaluate(Query(2.0)).Cl;
    const Real cl6 = wing.Evaluate(Query(6.0)).Cl;
    const Real measured = (cl6 - cl2) / units::Degrees(4.0);
    RC_CHECK_NEAR(measured, slope, 1e-9);

    // And through the zero-lift angle.
    RC_CHECK_NEAR(wing.Evaluate(Query(units::ToDegrees(wing.ZeroLiftAngle()))).Cl, 0.0, 1e-12);
    RC_CHECK(wing.Evaluate(Query(0.0)).Cl > 0.0);   // cambered: lifts at zero alpha
}

RC_TEST(Airfoil, LiftPeaksAtTheStallAngleThenFalls)
{
    const Airfoil wing(TrainerFlatBottom());

    Real peakCl = -1e30;
    Real peakAlphaDeg = 0.0;
    for (Real deg = -5.0; deg <= 40.0; deg += 0.25)
    {
        const Real cl = wing.Evaluate(Query(deg)).Cl;
        if (cl > peakCl) { peakCl = cl; peakAlphaDeg = deg; }
    }

    // The peak must land at the declared stall angle, not past it.
    RC_CHECK(peakAlphaDeg > 11.0 && peakAlphaDeg < 14.0);
    RC_CHECK_NEAR(peakCl, 1.20, 0.02);

    // And lift must genuinely fall away afterwards.
    RC_CHECK(wing.Evaluate(Query(16.0)).Cl < peakCl);
    RC_CHECK(wing.Evaluate(Query(20.0)).Cl < wing.Evaluate(Query(16.0)).Cl);
    RC_CHECK(wing.Evaluate(Query(20.0)).Cl < 0.75 * peakCl);
}

RC_TEST(Airfoil, DragRisesSharplyThroughTheStall)
{
    const Airfoil wing(TrainerFlatBottom());

    const Real cruiseDrag = wing.Evaluate(Query(3.0)).Cd;
    const Real stallDrag  = wing.Evaluate(Query(13.0)).Cd;
    const Real deepDrag   = wing.Evaluate(Query(30.0)).Cd;

    RC_CHECK(cruiseDrag > 0.0);
    RC_CHECK(stallDrag > 2.0 * cruiseDrag);
    RC_CHECK(deepDrag > 3.0 * stallDrag);

    // And it must keep rising, monotonically, all the way to broadside - the
    // property that actually matters, because it is what arrests a spin entry
    // and what makes a deep stall descend steeply instead of mushing along.
    Real previous = cruiseDrag;
    for (Real deg = 5.0; deg <= 90.0; deg += 2.5)
    {
        const Real current = wing.Evaluate(Query(deg)).Cd;
        if (current < previous - 1e-9)
        {
            RC_FAIL("drag fell between " + std::to_string(deg - 2.5) +
                    " and " + std::to_string(deg) + " degrees");
            break;
        }
        previous = current;
    }

    // Deep in the stall it behaves like a plate broadside to the flow.
    RC_CHECK(wing.Evaluate(Query(90.0)).Cd > 1.0);
    RC_CHECK(wing.Evaluate(Query(90.0)).Cd > 10.0 * cruiseDrag);
}

RC_TEST(Airfoil, GlideRatioOfTheSectionIsPlausible)
{
    // Not the aircraft's glide ratio - the fuselage, tail and gear have not
    // been added - but the wing section alone should peak in the high teens.
    const Airfoil wing(TrainerFlatBottom());

    Real bestRatio = 0.0;
    for (Real deg = 0.0; deg <= 12.0; deg += 0.25)
    {
        const AeroCoefficients c = wing.Evaluate(Query(deg));
        bestRatio = Max(bestRatio, c.Cl / Max(c.Cd, 1e-9));
    }
    RC_CHECK(bestRatio > 12.0 && bestRatio < 25.0);
}

RC_TEST(Airfoil, RemainsFiniteAllTheWayAround)
{
    // A tumbling aircraft must still produce sane forces, not NaN.
    const Airfoil wing(TrainerFlatBottom());
    for (Real deg = -180.0; deg <= 180.0; deg += 2.5)
    {
        const AeroCoefficients c = wing.Evaluate(Query(deg));
        if (!IsFinite(c.Cl) || !IsFinite(c.Cd) || !IsFinite(c.Cm))
        {
            RC_FAIL("non-finite coefficients at alpha = " + std::to_string(deg) + " deg");
            break;
        }
        RC_CHECK(std::fabs(c.Cl) < 3.0);
        RC_CHECK(c.Cd >= 0.0 && c.Cd < 3.0);
    }
}

// --------------------------------------------------------------- Reynolds ---

RC_TEST(Airfoil, LowReynoldsCostsMaximumLift)
{
    // The defining RC-scale effect. A trainer on final at 8 m/s is at half the
    // Reynolds number of its cruise, and its wing is measurably weaker there.
    const Airfoil wing(TrainerFlatBottom());

    const Real clMaxCruise = wing.MaxLiftCoefficient(233000.0);
    const Real clMaxSlow   = wing.MaxLiftCoefficient(110000.0);

    RC_CHECK(clMaxSlow < clMaxCruise);
    RC_CHECK(clMaxSlow > 0.85 * clMaxCruise);   // mild, not catastrophic
    RC_CHECK(wing.StallAngle(110000.0) < wing.StallAngle(233000.0));
}

RC_TEST(Airfoil, LowReynoldsRaisesProfileDrag)
{
    const Airfoil wing(TrainerFlatBottom());
    RC_CHECK(wing.MinimumDrag(110000.0) > wing.MinimumDrag(233000.0));
    RC_CHECK(wing.MinimumDrag(233000.0) > 0.0);

    // Bounded: an absurd Reynolds number must not produce absurd drag.
    RC_CHECK(wing.MinimumDrag(1.0) < 10.0 * wing.MinimumDrag(233000.0));
    RC_CHECK(wing.MinimumDrag(1e12) > 0.0);
}

// ------------------------------------------------------------- hysteresis ---

RC_TEST(Airfoil, SeparationHasHysteresis)
{
    // Separated flow reattaches at a LOWER angle than it detached at. This is
    // what makes a stall recovery require actually unloading the wing, rather
    // than easing back a fraction of a degree.
    const Airfoil wing(TrainerFlatBottom());

    AirfoilQuery attached = Query(11.5);
    attached.WasSeparated = false;
    const AeroCoefficients stillFlying = wing.Evaluate(attached);
    RC_CHECK(!stillFlying.IsSeparated());

    AirfoilQuery recovering = Query(11.5);
    recovering.WasSeparated = true;
    const AeroCoefficients stillStalled = wing.Evaluate(recovering);
    RC_CHECK(stillStalled.SeparationFraction > stillFlying.SeparationFraction);

    // Far enough below the reattachment angle, it reattaches regardless.
    AirfoilQuery wellBelow = Query(5.0);
    wellBelow.WasSeparated = true;
    RC_CHECK(!wing.Evaluate(wellBelow).IsSeparated());
    RC_CHECK_NEAR(wing.Evaluate(wellBelow).SeparationFraction, 0.0, 1e-12);
}

RC_TEST(Airfoil, SeparationFractionIsContinuous)
{
    // A discontinuity here would be felt through the stick as a buzz.
    const Airfoil wing(TrainerFlatBottom());
    Real previous = wing.Evaluate(Query(0.0)).SeparationFraction;
    for (Real deg = 0.0; deg <= 25.0; deg += 0.1)
    {
        const Real current = wing.Evaluate(Query(deg)).SeparationFraction;
        RC_CHECK(current - previous < 0.06);
        previous = current;
    }
    RC_CHECK_NEAR(previous, 1.0, 1e-9);
}

// -------------------------------------------------------- control surface ---

RC_TEST(Airfoil, ControlDeflectionChangesLiftDragAndMoment)
{
    const Airfoil wing(TrainerFlatBottom());

    AirfoilQuery neutral = Query(2.0);
    neutral.ControlEffectiveness = Airfoil::FlapEffectiveness(0.25);

    AirfoilQuery down = neutral;
    down.ControlDeflection = units::Degrees(15.0);

    const AeroCoefficients a = wing.Evaluate(neutral);
    const AeroCoefficients b = wing.Evaluate(down);

    RC_CHECK(b.Cl > a.Cl);                 // trailing edge down adds lift
    RC_CHECK(b.Cd > a.Cd);                 // and costs drag
    RC_CHECK(b.Cm < a.Cm);                 // and pitches the section nose down

    AirfoilQuery up = neutral;
    up.ControlDeflection = units::Degrees(-15.0);
    RC_CHECK(wing.Evaluate(up).Cl < a.Cl);
    RC_CHECK(wing.Evaluate(up).Cd > a.Cd); // drag is symmetric in deflection
}

RC_TEST(Airfoil, ControlAuthorityCollapsesWhenSeparated)
{
    // The lesson a trainee has to learn: a stalled wing's aileron does very
    // little, so picking up a dropped wing with aileron makes it worse.
    const Airfoil wing(TrainerFlatBottom());
    const Real tau = Airfoil::FlapEffectiveness(0.25);

    auto liftChangeAt = [&](Real alphaDeg)
    {
        AirfoilQuery neutral = Query(alphaDeg);
        neutral.ControlEffectiveness = tau;
        AirfoilQuery deflected = neutral;
        deflected.ControlDeflection = units::Degrees(20.0);
        return wing.Evaluate(deflected).Cl - wing.Evaluate(neutral).Cl;
    };

    const Real attachedResponse = liftChangeAt(2.0);
    const Real stalledResponse  = liftChangeAt(22.0);

    RC_CHECK(attachedResponse > 0.15);
    RC_CHECK(stalledResponse < 0.35 * attachedResponse);
}

RC_TEST(Airfoil, ControlEffectScalesWithSpanFraction)
{
    const Airfoil wing(TrainerFlatBottom());

    AirfoilQuery full = Query(2.0);
    full.ControlEffectiveness = Airfoil::FlapEffectiveness(0.25);
    full.ControlDeflection = units::Degrees(15.0);
    full.ControlSpanFraction = 1.0;

    AirfoilQuery half = full;
    half.ControlSpanFraction = 0.5;

    AirfoilQuery none = full;
    none.ControlSpanFraction = 0.0;

    const Real base = wing.Evaluate(Query(2.0)).Cl;
    RC_CHECK(wing.Evaluate(full).Cl - base > wing.Evaluate(half).Cl - base);
    RC_CHECK_NEAR(wing.Evaluate(none).Cl, base, 0.05);
}

// ------------------------------------------------------------ tabulated -----

RC_TEST(Airfoil, TabulatedPolarsOverrideTheAnalyticCurve)
{
    // The hook for XFoil and wind-tunnel data. When tables are present they
    // must win, so that improving the data never means editing code.
    Airfoil wing(TrainerFlatBottom());

    Table2D lift, drag, moment;
    const std::vector<Real> alphas = {units::Degrees(-10.0), 0.0, units::Degrees(10.0)};
    const std::vector<Real> reynolds = {100000.0, 300000.0};
    RC_CHECK(lift.Build(alphas, reynolds, {-0.50, -0.55,
                                            0.40,  0.45,
                                            1.30,  1.40}));
    RC_CHECK(drag.Build(alphas, reynolds, {0.050, 0.045,
                                           0.020, 0.018,
                                           0.070, 0.065}));
    RC_CHECK(moment.Build(alphas, reynolds, {-0.08, -0.08,
                                             -0.07, -0.07,
                                             -0.06, -0.06}));

    const Real analyticCl = wing.Evaluate(Query(0.0, kWingAspectRatio, 300000.0)).Cl;
    RC_CHECK(wing.SetTables(lift, drag, moment));
    RC_CHECK(wing.HasTables());

    const AeroCoefficients tabulated = wing.Evaluate(Query(0.0, kWingAspectRatio, 300000.0));
    RC_CHECK_NEAR(tabulated.Cl, 0.45, 1e-12);
    RC_CHECK_NEAR(tabulated.Cd, 0.018, 1e-12);
    RC_CHECK_NEAR(tabulated.Cm, -0.07, 1e-12);
    RC_CHECK(std::fabs(tabulated.Cl - analyticCl) > 1e-6);

    // Control surfaces must still work against tabulated data.
    AirfoilQuery deflected = Query(0.0, kWingAspectRatio, 300000.0);
    deflected.ControlEffectiveness = Airfoil::FlapEffectiveness(0.25);
    deflected.ControlDeflection = units::Degrees(15.0);
    RC_CHECK(wing.Evaluate(deflected).Cl > tabulated.Cl);
}

RC_TEST(Airfoil, RejectsEmptyTables)
{
    Airfoil wing(TrainerFlatBottom());
    std::string error;
    RC_CHECK(!wing.SetTables(Table2D{}, Table2D{}, Table2D{}, &error));
    RC_CHECK(!error.empty());
    RC_CHECK(!wing.HasTables());
}
