#include "TestHarness.h"

#include "RCPhysics/Physics/Aero/AeroSurface.h"
#include "RCPhysics/Physics/Dynamics/ForceAccumulator.h"
#include "RCPhysics/Core/Units/Units.h"

using namespace rc;

namespace
{
    Airfoil TrainerWingAirfoil()
    {
        AirfoilParameters p;
        p.ClZeroAlpha = 0.30;  p.ClAlphaPerRad = 5.70;  p.ClMax = 1.20;
        p.AlphaStall = units::Degrees(13.0);
        p.StallBlend = units::Degrees(5.0);
        p.ReattachHysteresis = units::Degrees(2.5);
        p.CdMin = 0.016; p.CdAlphaQuadratic = 0.012; p.CdSeparatedMax = 1.30;
        p.CmQuarterChord = -0.075; p.OswaldEfficiency = 0.85;
        p.ReferenceReynolds = 200000.0;
        return Airfoil(p);
    }

    Airfoil SymmetricTailAirfoil()
    {
        AirfoilParameters p;
        p.ClZeroAlpha = 0.0; p.ClAlphaPerRad = 5.50; p.ClMax = 1.00;
        p.AlphaStall = units::Degrees(12.0);
        p.StallBlend = units::Degrees(3.5);
        p.ReattachHysteresis = units::Degrees(2.0);
        p.CdMin = 0.012; p.CdSeparatedMax = 1.25; p.CmQuarterChord = 0.0;
        p.OswaldEfficiency = 0.80; p.ReferenceReynolds = 120000.0;
        return Airfoil(p);
    }

    /** A right-wing outer section of the Trainer 1500, with an aileron. */
    AeroSurfaceSpec RightWingSection(bool withAileron = false)
    {
        AeroSurfaceSpec s;
        s.Name = "wing_right";
        s.Role = SurfaceRole::Wing;
        s.PositionBody = Vec3(0.009, 0.46875, -0.1137);
        s.Area = 0.03994; s.Chord = 0.2133; s.Span = 0.1875;
        s.Incidence = units::Degrees(2.0);
        s.Dihedral  = units::Degrees(3.5);
        s.EffectiveAspectRatio = 7.03;
        if (withAileron)
        {
            s.HasControl = true;
            s.Control.Channel = RCChannel::Aileron;
            s.Control.ChordFraction = 0.25;
            s.Control.SpanFraction = 1.0;
            // Positive aileron stick = roll RIGHT, so the right aileron must go
            // UP, which is a negative (trailing edge up) deflection.
            s.Control.Direction = -1.0;
            s.Control.MaxDeflection = units::Degrees(20.0);
        }
        return s;
    }

    AeroSurfaceSpec MirrorToLeft(AeroSurfaceSpec s)
    {
        s.Name = "wing_left";
        s.PositionBody.y = -s.PositionBody.y;
        if (s.HasControl) { s.Control.Direction = -s.Control.Direction; }
        return s;
    }

    AeroSurfaceSpec HorizontalTailSection()
    {
        AeroSurfaceSpec s;
        s.Name = "htail_right";
        s.Role = SurfaceRole::HorizontalTail;
        s.PositionBody = Vec3(-0.620, 0.105, -0.020);
        s.Area = 0.029; s.Chord = 0.138; s.Span = 0.21;
        s.EffectiveAspectRatio = 3.04;
        s.HasControl = true;
        s.Control.Channel = RCChannel::Elevator;
        s.Control.ChordFraction = 0.40;
        // Positive elevator stick = nose UP, which needs the tail pushed DOWN,
        // which is a trailing-edge-UP (negative) deflection.
        s.Control.Direction = -1.0;
        s.Control.MaxDeflection = units::Degrees(22.0);
        return s;
    }

    AeroSurfaceSpec VerticalTailSection()
    {
        AeroSurfaceSpec s;
        s.Name = "vtail";
        s.Role = SurfaceRole::VerticalTail;
        s.PositionBody = Vec3(-0.600, 0.0, -0.100);
        s.Area = 0.033; s.Chord = 0.165; s.Span = 0.20;
        s.EffectiveAspectRatio = 1.80;
        s.HasControl = true;
        s.Control.Channel = RCChannel::Rudder;
        s.Control.ChordFraction = 0.45;
        s.Control.Direction = 1.0;   // positive rudder stick = nose right
        s.Control.MaxDeflection = units::Degrees(25.0);
        return s;
    }

    AeroEnvironment Cruise(const Vec3& airVelocityBody = Vec3(16.0, 0.0, 0.0),
                           const Vec3& angularVelocity = Vec3::Zero())
    {
        AeroEnvironment e;
        e.AirVelocityBody = airVelocityBody;
        e.AngularVelocityBody = angularVelocity;
        e.Atmosphere = Atmosphere::StandardSeaLevel();
        return e;
    }

    SectionResult Run(const AeroSurfaceSpec& spec, const Airfoil& airfoil,
                      const AeroEnvironment& environment, Real channelValue = 0.0)
    {
        AeroSurface surface;
        surface.Configure(spec);
        bool separated = false;
        return surface.Evaluate(environment, airfoil,
                                surface.DeflectionFor(channelValue), Vec3::Zero(), separated);
    }

    /** Body-frame moment about the CG produced by one section. */
    Vec3 MomentAboutCG(const AeroSurfaceSpec& spec, const SectionResult& result)
    {
        return Cross(spec.PositionBody, result.ForceBody) + result.MomentBody;
    }
}

// ----------------------------------------------------------- basic section --

RC_TEST(AeroSurface, IncidenceSetsTheAngleOfAttackInLevelFlight)
{
    // A wing rigged at +2 degrees must see +2 degrees of alpha when the
    // fuselage is flying level. If this is wrong, every trim state is wrong.
    const AeroSurfaceSpec spec = RightWingSection();
    const SectionResult result = Run(spec, TrainerWingAirfoil(), Cruise());

    RC_CHECK_NEAR(units::ToDegrees(result.Alpha), 2.0, 0.05);
    RC_CHECK(result.LocalSpeed > 15.9 && result.LocalSpeed < 16.01);
    RC_CHECK(result.Reynolds > 2.0e5 && result.Reynolds < 2.6e5);
}

RC_TEST(AeroSurface, LiftActsUpwardsAndDragBackwards)
{
    const AeroSurfaceSpec spec = RightWingSection();
    const SectionResult result = Run(spec, TrainerWingAirfoil(), Cruise());

    // In body FRD, up is -Z and backwards is -X.
    RC_CHECK(result.ForceBody.z < 0.0);
    RC_CHECK(result.ForceBody.x < 0.0);
    RC_CHECK(result.Lift > 0.0);
    RC_CHECK(result.Drag > 0.0);

    // Lift must dominate drag by a wide margin at cruise.
    RC_CHECK(result.Lift > 10.0 * result.Drag);

    // Dihedral tilts the lift vector inboard - on the RIGHT wing that is -Y.
    RC_CHECK(result.ForceBody.y < 0.0);
}

RC_TEST(AeroSurface, LiftScalesWithDynamicPressure)
{
    const AeroSurfaceSpec spec = RightWingSection();
    const Airfoil airfoil = TrainerWingAirfoil();

    const SectionResult slow = Run(spec, airfoil, Cruise(Vec3(10.0, 0.0, 0.0)));
    const SectionResult fast = Run(spec, airfoil, Cruise(Vec3(20.0, 0.0, 0.0)));

    // Four times the dynamic pressure. Not exactly four times the lift, because
    // Reynolds number changes the coefficients slightly - which is the point.
    const Real ratio = fast.Lift / slow.Lift;
    RC_CHECK(ratio > 3.7 && ratio < 4.3);
    RC_CHECK_NEAR(fast.DynamicPressure / slow.DynamicPressure, 4.0, 1e-9);
}

RC_TEST(AeroSurface, StationaryAircraftProducesNoForce)
{
    const AeroSurfaceSpec spec = RightWingSection();
    const SectionResult result = Run(spec, TrainerWingAirfoil(), Cruise(Vec3::Zero()));

    RC_CHECK(result.ForceBody.IsNearlyZero());
    RC_CHECK(result.MomentBody.IsNearlyZero());
    RC_CHECK(result.ForceBody.IsFinite());
}

// ------------------------------------------------------ damping from omega --

RC_TEST(AeroSurface, RollRateProducesRollDamping)
{
    // THE test for the omega x r term. Rolling right, the descending right wing
    // meets the air at a higher angle of attack and lifts harder, which opposes
    // the roll. Damping must emerge from the geometry, not be added by hand.
    const AeroSurfaceSpec right = RightWingSection();
    const AeroSurfaceSpec left  = MirrorToLeft(RightWingSection());
    const Airfoil airfoil = TrainerWingAirfoil();

    const Vec3 rollingRight(2.0, 0.0, 0.0);   // p > 0

    const SectionResult rightSteady = Run(right, airfoil, Cruise());
    const SectionResult rightRolling = Run(right, airfoil, Cruise(Vec3(16, 0, 0), rollingRight));
    const SectionResult leftRolling  = Run(left,  airfoil, Cruise(Vec3(16, 0, 0), rollingRight));

    RC_CHECK(rightRolling.Alpha > rightSteady.Alpha);   // descending wing
    RC_CHECK(leftRolling.Alpha  < rightSteady.Alpha);   // rising wing

    const Real rollMoment = MomentAboutCG(right, rightRolling).x
                          + MomentAboutCG(left,  leftRolling).x;
    // Negative = rolling left = opposing the positive roll rate.
    RC_CHECK(rollMoment < 0.0);
}

RC_TEST(AeroSurface, PitchRateProducesPitchDamping)
{
    // Pitching nose-up, the tail swings down, meets the air at a higher angle
    // and lifts harder, pitching the nose back down.
    const AeroSurfaceSpec tail = HorizontalTailSection();
    const Airfoil airfoil = SymmetricTailAirfoil();

    const SectionResult steady  = Run(tail, airfoil, Cruise());
    const SectionResult pitching = Run(tail, airfoil, Cruise(Vec3(16, 0, 0), Vec3(0.0, 2.0, 0.0)));

    RC_CHECK(pitching.Alpha > steady.Alpha);
    RC_CHECK(MomentAboutCG(tail, pitching).y < MomentAboutCG(tail, steady).y);
    RC_CHECK(MomentAboutCG(tail, pitching).y < 0.0);   // nose down, opposing
}

RC_TEST(AeroSurface, YawRateProducesYawDamping)
{
    const AeroSurfaceSpec fin = VerticalTailSection();
    const Airfoil airfoil = SymmetricTailAirfoil();

    const SectionResult yawing = Run(fin, airfoil, Cruise(Vec3(16, 0, 0), Vec3(0.0, 0.0, 2.0)));

    // Yawing nose-right, the fin swings left through the air and generates a
    // force that yaws the nose back left.
    RC_CHECK(MomentAboutCG(fin, yawing).z < 0.0);
}

// ------------------------------------------------------------- stability ----

RC_TEST(AeroSurface, DihedralRollsAwayFromSideslip)
{
    // Lateral stability. Slipping to the right, the right wing sees more alpha
    // and lifts harder, rolling the aircraft LEFT - away from the slip. This is
    // the largest single contributor to a trainer's self-levelling feel, and
    // getting the sign backwards makes the aircraft diverge instead.
    const AeroSurfaceSpec right = RightWingSection();
    const AeroSurfaceSpec left  = MirrorToLeft(RightWingSection());
    const Airfoil airfoil = TrainerWingAirfoil();

    const Vec3 slippingRight(16.0, 2.0, 0.0);   // v > 0

    const SectionResult rightSlip = Run(right, airfoil, Cruise(slippingRight));
    const SectionResult leftSlip  = Run(left,  airfoil, Cruise(slippingRight));
    const SectionResult rightLevel = Run(right, airfoil, Cruise());

    RC_CHECK(rightSlip.Alpha > rightLevel.Alpha);
    RC_CHECK(leftSlip.Alpha  < rightLevel.Alpha);

    const Real rollMoment = MomentAboutCG(right, rightSlip).x
                          + MomentAboutCG(left,  leftSlip).x;
    RC_CHECK(rollMoment < 0.0);   // rolls left, out of a right slip
}

RC_TEST(AeroSurface, FinWeathervanesIntoTheRelativeWind)
{
    // Directional stability. Slipping right, the fin must yaw the nose right,
    // into the relative wind.
    const AeroSurfaceSpec fin = VerticalTailSection();
    const SectionResult result = Run(fin, SymmetricTailAirfoil(), Cruise(Vec3(16.0, 2.0, 0.0)));

    RC_CHECK(result.ForceBody.y < 0.0);              // fin pushed left
    RC_CHECK(MomentAboutCG(fin, result).z > 0.0);    // nose swings right
}

RC_TEST(AeroSurface, TailProvidesLongitudinalStability)
{
    // Increase the aircraft's angle of attack; the tail must produce a
    // nose-DOWN increment. Without this the aircraft has no static margin.
    const AeroSurfaceSpec tail = HorizontalTailSection();
    const Airfoil airfoil = SymmetricTailAirfoil();

    const SectionResult level  = Run(tail, airfoil, Cruise(Vec3(16.0, 0.0, 0.0)));
    const SectionResult pitched = Run(tail, airfoil, Cruise(Vec3(16.0, 0.0, 1.6)));  // ~5.7 deg

    RC_CHECK(pitched.Alpha > level.Alpha);
    RC_CHECK(MomentAboutCG(tail, pitched).y < MomentAboutCG(tail, level).y);
}

// -------------------------------------------------------- control surfaces --

RC_TEST(AeroSurface, PositiveAileronRollsRight)
{
    const AeroSurfaceSpec right = RightWingSection(true);
    const AeroSurfaceSpec left  = MirrorToLeft(RightWingSection(true));
    const Airfoil airfoil = TrainerWingAirfoil();

    const SectionResult rightUp = Run(right, airfoil, Cruise(), 1.0);
    const SectionResult leftDown = Run(left, airfoil, Cruise(), 1.0);

    // Right aileron up, left aileron down.
    RC_CHECK(rightUp.Deflection < 0.0);
    RC_CHECK(leftDown.Deflection > 0.0);
    RC_CHECK(rightUp.Lift < leftDown.Lift);

    const Real rollMoment = MomentAboutCG(right, rightUp).x
                          + MomentAboutCG(left,  leftDown).x;
    RC_CHECK(rollMoment > 0.0);   // positive roll = right wing down

    // And the opposite stick rolls the other way, symmetrically.
    const Real reversed = MomentAboutCG(right, Run(right, airfoil, Cruise(), -1.0)).x
                        + MomentAboutCG(left,  Run(left,  airfoil, Cruise(), -1.0)).x;
    RC_CHECK(reversed < 0.0);
    RC_CHECK_NEAR(reversed, -rollMoment, 0.02 * std::fabs(rollMoment));
}

RC_TEST(AeroSurface, PositiveElevatorPitchesNoseUp)
{
    const AeroSurfaceSpec tail = HorizontalTailSection();
    const Airfoil airfoil = SymmetricTailAirfoil();

    const SectionResult pulled = Run(tail, airfoil, Cruise(), 1.0);
    const SectionResult neutral = Run(tail, airfoil, Cruise(), 0.0);

    RC_CHECK(pulled.Deflection < 0.0);            // trailing edge up
    RC_CHECK(pulled.ForceBody.z > 0.0);           // tail pushed DOWN (+Z)
    RC_CHECK(MomentAboutCG(tail, pulled).y > 0.0); // nose up
    RC_CHECK(MomentAboutCG(tail, pulled).y > MomentAboutCG(tail, neutral).y);

    RC_CHECK(MomentAboutCG(tail, Run(tail, airfoil, Cruise(), -1.0)).y < 0.0);
}

RC_TEST(AeroSurface, PositiveRudderYawsNoseRight)
{
    const AeroSurfaceSpec fin = VerticalTailSection();
    const Airfoil airfoil = SymmetricTailAirfoil();

    const SectionResult right = Run(fin, airfoil, Cruise(), 1.0);
    RC_CHECK(right.Deflection > 0.0);
    RC_CHECK(right.ForceBody.y < 0.0);
    RC_CHECK(MomentAboutCG(fin, right).z > 0.0);

    RC_CHECK(MomentAboutCG(fin, Run(fin, airfoil, Cruise(), -1.0)).z < 0.0);
}

RC_TEST(AeroSurface, AileronDifferentialReducesTheDownGoingTravel)
{
    AeroSurfaceSpec spec = RightWingSection(true);
    spec.Control.Differential = 0.30;

    AeroSurface surface;
    surface.Configure(spec);

    // Direction is -1, so a NEGATIVE stick gives a positive (down) deflection.
    const Real down = surface.DeflectionFor(-1.0);
    const Real up   = surface.DeflectionFor(1.0);

    RC_CHECK(down > 0.0 && up < 0.0);
    RC_CHECK_NEAR(down, 0.70 * std::fabs(up), 1e-12);
}

RC_TEST(AeroSurface, ControlTravelIsClampedToFullStick)
{
    AeroSurface surface;
    surface.Configure(HorizontalTailSection());
    const Real full = surface.DeflectionFor(1.0);
    RC_CHECK_NEAR(surface.DeflectionFor(5.0), full, 1e-15);
    RC_CHECK_NEAR(std::fabs(full), units::Degrees(22.0), 1e-12);
}

RC_TEST(AeroSurface, SectionWithoutControlIgnoresTheStick)
{
    const AeroSurfaceSpec spec = RightWingSection(false);
    AeroSurface surface;
    surface.Configure(spec);
    RC_CHECK_NEAR(surface.DeflectionFor(1.0), 0.0, 1e-15);

    const Airfoil airfoil = TrainerWingAirfoil();
    RC_CHECK_NEAR(Run(spec, airfoil, Cruise(), 1.0).Lift,
                  Run(spec, airfoil, Cruise(), 0.0).Lift, 1e-12);
}

// ------------------------------------------------------------ propwash -----

RC_TEST(AeroSurface, PropwashRestoresControlAuthorityAtLowAirspeed)
{
    // The single most important RC-specific effect: with the throttle open, the
    // tail still works at an airspeed where an unpowered model has nothing.
    const AeroSurfaceSpec tail = HorizontalTailSection();
    const Airfoil airfoil = SymmetricTailAirfoil();

    AeroSurface surface;
    surface.Configure(tail);

    const AeroEnvironment crawling = Cruise(Vec3(4.0, 0.0, 0.0));
    bool separated = false;

    const SectionResult unpowered = surface.Evaluate(
        crawling, airfoil, surface.DeflectionFor(1.0), Vec3::Zero(), separated);

    separated = false;
    const SectionResult blown = surface.Evaluate(
        crawling, airfoil, surface.DeflectionFor(1.0), Vec3(12.0, 0.0, 0.0), separated);

    RC_CHECK(blown.LocalSpeed > 3.0 * unpowered.LocalSpeed);
    RC_CHECK(std::fabs(blown.ForceBody.z) > 5.0 * std::fabs(unpowered.ForceBody.z));
    RC_CHECK(MomentAboutCG(tail, blown).y > 5.0 * MomentAboutCG(tail, unpowered).y);
}

// ------------------------------------------------------ stall behaviour -----

RC_TEST(AeroSurface, StallHysteresisPersistsAcrossSteps)
{
    const AeroSurfaceSpec spec = RightWingSection();
    const Airfoil airfoil = TrainerWingAirfoil();
    AeroSurface surface;
    surface.Configure(spec);

    // Pitch up hard enough to separate: alpha = incidence + flow angle.
    const AeroEnvironment deep = Cruise(Vec3(12.0, 0.0, 4.0));   // ~18 deg flow
    bool separated = false;
    surface.Evaluate(deep, airfoil, 0.0, Vec3::Zero(), separated);
    RC_CHECK(separated);

    // Easing off to an angle that would NOT have separated the flow in the
    // first place must nevertheless leave it separated. Detachment happens
    // around 15.5 deg and reattachment around 13 deg, so 14 deg sits inside the
    // hysteresis band: flying, it would be attached; recovering, it is not.
    const AeroEnvironment eased = Cruise(Vec3(14.0, 0.0, 3.0));   // ~12.1 + 2 deg
    surface.Evaluate(eased, airfoil, 0.0, Vec3::Zero(), separated);
    RC_CHECK(separated);

    bool freshlyArriving = false;
    surface.Evaluate(eased, airfoil, 0.0, Vec3::Zero(), freshlyArriving);
    RC_CHECK(!freshlyArriving);   // same alpha, different history

    // Properly unloading does.
    const AeroEnvironment unloaded = Cruise(Vec3(16.0, 0.0, 0.0));
    surface.Evaluate(unloaded, airfoil, 0.0, Vec3::Zero(), separated);
    RC_CHECK(!separated);
}

RC_TEST(AeroSurface, WingsCanStallIndependently)
{
    // The property that makes wing drop, snap roll and spin possible at all.
    // A roll rate alone is enough to put one wing over the edge while the other
    // is still flying comfortably.
    const AeroSurfaceSpec right = RightWingSection();
    const AeroSurfaceSpec left  = MirrorToLeft(RightWingSection());
    const Airfoil airfoil = TrainerWingAirfoil();

    AeroSurface rightSurface, leftSurface;
    rightSurface.Configure(right);
    leftSurface.Configure(left);

    const AeroEnvironment onTheEdge = Cruise(Vec3(9.0, 0.0, 1.6), Vec3(3.0, 0.0, 0.0));

    bool rightSeparated = false;
    bool leftSeparated  = false;
    const SectionResult r = rightSurface.Evaluate(onTheEdge, airfoil, 0.0, Vec3::Zero(), rightSeparated);
    const SectionResult l = leftSurface.Evaluate(onTheEdge, airfoil, 0.0, Vec3::Zero(), leftSeparated);

    RC_CHECK(r.Alpha > l.Alpha);
    RC_CHECK(rightSeparated);
    RC_CHECK(!leftSeparated);
    RC_CHECK(r.Coefficients.SeparationFraction > 0.9);
    RC_CHECK(l.Coefficients.SeparationFraction < 0.01);

    // The stalled wing is past the peak of its lift curve: it is producing far
    // less lift than the attached curve at that angle would have given.
    const Real attachedWouldBe = airfoil.LiftCurveSlope(right.EffectiveAspectRatio)
                               * (r.Alpha - airfoil.ZeroLiftAngle());
    RC_CHECK(r.Coefficients.Cl < 0.7 * attachedWouldBe);
}

RC_TEST(AeroSurface, RollDampingCollapsesAtTheStall)
{
    // This is the mechanism of a spin, and it emerges from the section model
    // rather than being scripted.
    //
    // At cruise, rolling right raises the descending wing's angle of attack and
    // it lifts harder, opposing the roll. Near the stall the descending wing is
    // pushed PAST the peak of its lift curve and lifts LESS, while the rising
    // wing unloads onto a better part of the curve - so the damping weakens and
    // can reverse into autorotation.
    const AeroSurfaceSpec right = RightWingSection();
    const AeroSurfaceSpec left  = MirrorToLeft(RightWingSection());
    const Airfoil airfoil = TrainerWingAirfoil();

    auto rollMomentAt = [&](const Vec3& airVelocity, Real rollRate)
    {
        const AeroEnvironment environment = Cruise(airVelocity, Vec3(rollRate, 0.0, 0.0));
        AeroSurface rightSurface, leftSurface;
        rightSurface.Configure(right);
        leftSurface.Configure(left);
        bool rs = false, ls = false;
        const SectionResult r = rightSurface.Evaluate(environment, airfoil, 0.0, Vec3::Zero(), rs);
        const SectionResult l = leftSurface.Evaluate(environment, airfoil, 0.0, Vec3::Zero(), ls);
        return MomentAboutCG(right, r).x + MomentAboutCG(left, l).x;
    };

    // Cruise: strong, restoring roll damping.
    const Real cruiseDamping = rollMomentAt(Vec3(16.0, 0.0, 0.0), 2.0);
    RC_CHECK(cruiseDamping < -0.5);

    // Slow and near the stall: the damping has gone. Whether it merely collapses
    // or fully reverses depends on exactly where on the curve each wing sits,
    // so the assertion is that it is no longer meaningfully restoring.
    const Real stalledDamping = rollMomentAt(Vec3(9.0, 0.0, 1.587), 2.0);
    RC_CHECK(stalledDamping > cruiseDamping);
    RC_CHECK(stalledDamping > 0.5 * cruiseDamping);

    // And with no roll rate at all there is no roll moment either way: the
    // aircraft is symmetric.
    RC_CHECK_NEAR(rollMomentAt(Vec3(16.0, 0.0, 0.0), 0.0), 0.0, 1e-12);
    RC_CHECK_NEAR(rollMomentAt(Vec3(9.0, 0.0, 1.587), 0.0), 0.0, 1e-12);
}
