// Ground effect: what the last half-span of every landing feels like.
//
// The model is one number per section - the share of free-air induced flow it
// still sees - and these tests check that this one number produces each thing a
// pilot notices: the float, the extra lift, the lower drag, the rolling moment
// in a banked flare and the nose-down pitch change as the tail's downwash goes.
#include "FlightTestRig.h"

#include <cstdio>

using namespace rc;
using namespace rctest;

namespace
{
/** Load the trainer twice over: once as shipped, once with ground effect off,
 *  so a test can hold everything else equal. */
bool LoadPair(FlightTestRig& withEffect, FlightTestRig& without)
{
    if (!withEffect.LoadTrainer().empty() || !without.LoadTrainer().empty())
    {
        return false;
    }
    without.Definition.GroundEffectScale = 0.0;
    without.Plane.Configure(without.Definition);
    withEffect.EnableGround(true);
    without.EnableGround(true);
    return true;
}

Real HeightForSpanFraction(const FlightTestRig& rig, Real fraction)
{
    return fraction * rig.Definition.WingSpan;
}
} // namespace

RC_TEST(GroundEffect, FactorFollowsTheImageVortexCurve)
{
    RC_CHECK_NEAR(Aircraft::GroundEffectInducedFactor(0.0), 0.0, 1e-12);
    RC_CHECK_NEAR(Aircraft::GroundEffectInducedFactor(-1.0), 0.0, 1e-12);
    // (1.6^2) / (1 + 1.6^2)
    RC_CHECK_NEAR(Aircraft::GroundEffectInducedFactor(0.1), 2.56 / 3.56, 1e-12);
    RC_CHECK(Aircraft::GroundEffectInducedFactor(0.5) > 0.98);
    RC_CHECK(Aircraft::GroundEffectInducedFactor(2.0) > 0.999);

    Real previous = 0.0;
    bool monotonic = true;
    for (Real x = 0.01; x < 2.0; x += 0.01)
    {
        const Real phi = Aircraft::GroundEffectInducedFactor(x);
        if (phi < previous) { monotonic = false; }
        previous = phi;
    }
    RC_CHECK(monotonic);
}

RC_TEST(GroundEffect, FreeAirIsUntouched)
{
    FlightTestRig a, b;
    if (!LoadPair(a, b)) { RC_FAIL("could not load the trainer"); return; }

    // Two spans up the factor rounds to 1 and the work is skipped entirely, so
    // the two aircraft must agree exactly rather than approximately.
    const Real height = 2.5 * a.Definition.WingSpan;
    a.PlaceAtAlpha(11.0, units::Degrees(4.0), height);
    b.PlaceAtAlpha(11.0, units::Degrees(4.0), height);
    const AircraftForces fa = a.Evaluate();
    const AircraftForces fb = b.Evaluate();
    RC_CHECK(fa.Total.Force.z == fb.Total.Force.z);
    RC_CHECK(fa.Total.Moment.y == fb.Total.Moment.y);
    RC_CHECK_NEAR(fa.GroundEffectFactor, 1.0, 0.0);
}

RC_TEST(GroundEffect, MoreLiftLessDragNearTheGround)
{
    FlightTestRig a, b;
    if (!LoadPair(a, b)) { RC_FAIL("could not load the trainer"); return; }

    // A tenth of a span: a 1.5 m model holding off about six inches up.
    const Real height = HeightForSpanFraction(a, 0.1);
    const Real alpha = units::Degrees(6.0);
    a.PlaceAtAlpha(10.0, alpha, height);
    b.PlaceAtAlpha(10.0, alpha, height);
    const AircraftForces fa = a.Evaluate();
    const AircraftForces fb = b.Evaluate();

    const Real ldWith = fa.TotalLift / fa.TotalDrag;
    const Real ldWithout = fb.TotalLift / fb.TotalDrag;
    std::printf("\n        h/b 0.10, alpha 6: lift %+.1f %%, drag %+.1f %%, L/D %.2f -> %.2f,"
                " factor %.3f\n",
                100.0 * (fa.TotalLift / fb.TotalLift - 1.0),
                100.0 * (fa.TotalDrag / fb.TotalDrag - 1.0),
                ldWithout, ldWith, fa.GroundEffectFactor);

    RC_CHECK(fa.TotalLift > 1.03 * fb.TotalLift);
    RC_CHECK(fa.TotalDrag < fb.TotalDrag);
    // Most of this aircraft's drag at approach speed is profile and fuselage,
    // so a 28 % cut in induced flow is a few percent of the total - enough to
    // be felt as a float, not enough to be a different aeroplane.
    RC_CHECK(ldWith > 1.04 * ldWithout);
    RC_CHECK(fa.GroundEffectFactor > 0.6 && fa.GroundEffectFactor < 0.85);
    RC_CHECK_NEAR(fa.HeightAboveGround, height, 1e-9);
}

RC_TEST(GroundEffect, TheLowWingIsLiftedInABankedFlare)
{
    FlightTestRig a, b;
    if (!LoadPair(a, b)) { RC_FAIL("could not load the trainer"); return; }

    // Right wing down by 8 degrees, low over the grass.
    const Real height = HeightForSpanFraction(a, 0.15);
    for (FlightTestRig* rig : {&a, &b})
    {
        rig->PlaceAtAlpha(10.0, units::Degrees(5.0), height);
        rig->State.Orientation = Quat::FromEuler(units::Degrees(8.0), 0.0, 0.0);
        rig->State.VelocityWorld = rig->State.Orientation.Rotate(
            Vec3(10.0 * std::cos(units::Degrees(5.0)), 0.0, 10.0 * std::sin(units::Degrees(5.0))));
    }
    const Real rollWith = a.Evaluate().Total.Moment.x;
    const Real rollWithout = b.Evaluate().Total.Moment.x;
    std::printf("        8 deg bank at h/b 0.15: roll moment %+.4f -> %+.4f N m\n",
                rollWithout, rollWith);

    // Positive roll is right wing down; the ground pushes the low right wing
    // up, so the difference must roll the aircraft LEFT, towards wings level.
    RC_CHECK(rollWith - rollWithout < -0.01);
}

RC_TEST(GroundEffect, PitchesTheNoseDownAsTheTailDownwashGoes)
{
    FlightTestRig a, b;
    if (!LoadPair(a, b)) { RC_FAIL("could not load the trainer"); return; }

    const Real height = HeightForSpanFraction(a, 0.1);
    a.PlaceAtAlpha(10.0, units::Degrees(5.0), height);
    b.PlaceAtAlpha(10.0, units::Degrees(5.0), height);
    const AircraftForces fa = a.Evaluate();
    const AircraftForces fb = b.Evaluate();
    std::printf("        pitch moment at h/b 0.10: %+.4f -> %+.4f N m\n",
                fb.Total.Moment.y, fa.Total.Moment.y);

    // Positive pitch is nose up. In ground effect the trim moves nose-down,
    // which is the extra up elevator a flare needs in its last few inches.
    RC_CHECK(fa.Total.Moment.y < fb.Total.Moment.y - 0.005);
}

RC_TEST(GroundEffect, TheSameLiftCostsLessDrag)
{
    // The textbook statement of ground effect, and the reason a fast approach
    // floats: for the SAME lift, the wing needs less angle and makes less
    // drag. Compared at equal lift rather than equal angle, because equal lift
    // is what level flight asks for.
    FlightTestRig a, b;
    if (!LoadPair(a, b)) { RC_FAIL("could not load the trainer"); return; }

    const Real speed = 9.5;   // about 1.2 x the stall speed
    const Real height = HeightForSpanFraction(a, 0.1);

    auto liftAt = [&](FlightTestRig& rig, Real alpha) {
        rig.PlaceAtAlpha(speed, alpha, height);
        return rig.Evaluate().TotalLift;
    };

    // The free-air aircraft at 8 degrees sets the lift to match.
    const Real targetLift = liftAt(b, units::Degrees(8.0));
    const Real dragWithout = b.LastForces.TotalDrag;

    Real lo = units::Degrees(0.0), hi = units::Degrees(8.0);
    for (int i = 0; i < 60; ++i)
    {
        const Real mid = 0.5 * (lo + hi);
        (liftAt(a, mid) < targetLift ? lo : hi) = mid;
    }
    const Real alphaWith = 0.5 * (lo + hi);
    liftAt(a, alphaWith);
    const Real dragWith = a.LastForces.TotalDrag;

    std::printf("        same lift at h/b 0.10, %.1f m/s: alpha 8.0 -> %.2f deg,"
                " drag %+.1f %%\n\n",
                speed, alphaWith / units::Degrees(1.0),
                100.0 * (dragWith / dragWithout - 1.0));

    RC_CHECK_NEAR(a.LastForces.TotalLift, targetLift, 1e-6 * targetLift);
    // Measured 7.57 and -5.1 % when this was written; the bounds catch a
    // change that loses most of the effect, not a small retune.
    RC_CHECK(alphaWith < units::Degrees(7.8));
    RC_CHECK(dragWith < 0.97 * dragWithout);
}
