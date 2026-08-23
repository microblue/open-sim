#include "TestHarness.h"

#include "RCPhysics/Core/Math/FrameConversion.h"
#include "RCPhysics/Core/Units/Units.h"

using namespace rc;

namespace
{
    /** A spread of attitudes covering every octant, so a sign error anywhere
     *  cannot hide behind a symmetric test case. */
    const EulerAngles kAttitudes[] = {
        {0.0, 0.0, 0.0},
        {units::Degrees(30.0),  units::Degrees(12.0),  units::Degrees(40.0)},
        {units::Degrees(-25.0), units::Degrees(-18.0), units::Degrees(-130.0)},
        {units::Degrees(170.0), units::Degrees(5.0),   units::Degrees(95.0)},
        {units::Degrees(-90.0), units::Degrees(60.0),  units::Degrees(-15.0)},
    };

    const Vec3 kVectors[] = {
        Vec3(1.0, 0.0, 0.0),
        Vec3(0.0, 1.0, 0.0),
        Vec3(0.0, 0.0, 1.0),
        Vec3(0.37, -1.9, 2.4),
        Vec3(-5.0, 0.25, -0.75),
    };
}

RC_TEST(FrameConversion, AxesMapOntoGodotsSenseOfDirection)
{
    // Nose (North) must become Godot's forward, which is -Z.
    RC_CHECK(NearlyEqual(frame::DirectionToGodot(Vec3::UnitX()), Vec3(0.0, 0.0, -1.0), 1e-15));
    // Right wing (East) must become Godot's +X.
    RC_CHECK(NearlyEqual(frame::DirectionToGodot(Vec3::UnitY()), Vec3(1.0, 0.0, 0.0), 1e-15));
    // Down must become Godot's -Y, because Godot's Y is up.
    RC_CHECK(NearlyEqual(frame::DirectionToGodot(Vec3::UnitZ()), Vec3(0.0, -1.0, 0.0), 1e-15));
}

RC_TEST(FrameConversion, AltitudeBecomesTheGodotYCoordinate)
{
    // 50 m above the field is z = -50 in NED. Godot must see y = +50 - and in
    // metres, not centimetres.
    const Vec3 godot = frame::PositionToGodot(Vec3(10.0, -4.0, -50.0));

    RC_CHECK_NEAR(godot.y, 50.0, 1e-15);
    RC_CHECK_NEAR(godot.x, -4.0, 1e-15);   // 4 m west
    RC_CHECK_NEAR(godot.z, -10.0, 1e-15);  // 10 m north = 10 m forward
    RC_CHECK_NEAR(frame::AltitudeToGodot(50.0), 50.0, 1e-15);
}

RC_TEST(FrameConversion, ThereIsNoUnitScaling)
{
    // Godot is metric, so an 18 m/s cruise stays 18 - the "forgot the factor of
    // 100" class of bug cannot exist here. This test exists to keep it that way.
    const Vec3 velocity = frame::VectorToGodot(Vec3(18.0, 0.0, -2.0));
    RC_CHECK_NEAR(velocity.Length(), std::sqrt(18.0 * 18.0 + 4.0), 1e-14);
    RC_CHECK_NEAR(velocity.y, 2.0, 1e-15);     // 2 m/s climb, upward in Godot
    RC_CHECK_NEAR(velocity.z, -18.0, 1e-15);   // 18 m/s forward
    RC_CHECK_NEAR(frame::kMetresToGodot, 1.0, 0.0);
}

RC_TEST(FrameConversion, PositionRoundTrips)
{
    for (const Vec3& v : kVectors)
    {
        RC_CHECK(NearlyEqual(frame::PositionFromGodot(frame::PositionToGodot(v)), v, 1e-15));
    }
}

RC_TEST(FrameConversion, ConversionPreservesLengthsAndAngles)
{
    // M must be orthonormal. If it is not, every force magnitude handed to the
    // renderer is subtly wrong.
    for (const Vec3& a : kVectors)
    {
        RC_CHECK_NEAR(frame::VectorToGodot(a).Length(), a.Length(), 1e-14);

        for (const Vec3& b : kVectors)
        {
            RC_CHECK_NEAR(Dot(frame::VectorToGodot(a), frame::VectorToGodot(b)),
                          Dot(a, b), 1e-13);
        }
    }
}

RC_TEST(FrameConversion, ConversionPreservesHandedness)
{
    // THE test that distinguishes a rotation from a reflection. Under a
    // reflection the converted cross product would come out negated, and every
    // moment in the simulation would be mirrored.
    for (const Vec3& a : kVectors)
    {
        for (const Vec3& b : kVectors)
        {
            const Vec3 crossThenConvert = frame::VectorToGodot(Cross(a, b));
            const Vec3 convertThenCross = Cross(frame::VectorToGodot(a),
                                                frame::VectorToGodot(b));
            RC_CHECK(NearlyEqual(crossThenConvert, convertThenCross, 1e-13));
        }
    }
}

RC_TEST(FrameConversion, BasisRotationIsExactAndUnitNorm)
{
    // A 120 degree rotation about (1,1,-1)/sqrt(3). The components are exactly
    // representable, so the conversion introduces no error of its own.
    const Quat m = frame::NedToGodotRotation();
    RC_CHECK_NEAR(m.w,  0.5, 0.0);
    RC_CHECK_NEAR(m.x,  0.5, 0.0);
    RC_CHECK_NEAR(m.y,  0.5, 0.0);
    RC_CHECK_NEAR(m.z, -0.5, 0.0);
    RC_CHECK_NEAR(m.Norm(), 1.0, 0.0);

    // The stored inverse must really be the inverse.
    const Quat identity = m * frame::GodotToNedRotation();
    RC_CHECK(NearlySameRotation(identity, Quat::Identity(), 1e-15));
}

RC_TEST(FrameConversion, RotationConversionCommutesWithVectorConversion)
{
    // THE test for this file. Rotating in the physics frame and then converting
    // must equal converting and then rotating with the converted quaternion:
    //
    //     M (q v q*)  ==  (M q M*) (M v) (M q M*)*
    //
    for (const EulerAngles& attitude : kAttitudes)
    {
        const Quat q      = Quat::FromEuler(attitude);
        const Quat qGodot = frame::RotationToGodot(q);

        for (const Vec3& v : kVectors)
        {
            const Vec3 rotatedThenConverted = frame::VectorToGodot(q.Rotate(v));
            const Vec3 convertedThenRotated = qGodot.Rotate(frame::VectorToGodot(v));
            RC_CHECK(NearlyEqual(rotatedThenConverted, convertedThenRotated, 1e-13));
        }
    }
}

RC_TEST(FrameConversion, ConvertedRotationStaysUnitLength)
{
    for (const EulerAngles& attitude : kAttitudes)
    {
        RC_CHECK_NEAR(frame::RotationToGodot(Quat::FromEuler(attitude)).Norm(), 1.0, 1e-14);
    }
}

RC_TEST(FrameConversion, RotationRoundTrips)
{
    for (const EulerAngles& attitude : kAttitudes)
    {
        const Quat q = Quat::FromEuler(attitude);
        const Quat back = frame::RotationFromGodot(frame::RotationToGodot(q));
        RC_CHECK(NearlySameRotation(back, q, 1e-14));
    }
}

RC_TEST(FrameConversion, LevelAircraftFacesGodotForward)
{
    const Quat level = Quat::Identity();
    const Quat godot = frame::RotationToGodot(level);

    // A model whose local forward is -Z must still be pointing along -Z.
    const Vec3 noseGodot = godot.Rotate(Vec3(0.0, 0.0, -1.0));
    RC_CHECK(NearlyEqual(noseGodot, Vec3(0.0, 0.0, -1.0), 1e-14));

    // And its up must be Godot's up.
    const Vec3 upGodot = godot.Rotate(Vec3(0.0, 1.0, 0.0));
    RC_CHECK(NearlyEqual(upGodot, Vec3(0.0, 1.0, 0.0), 1e-14));
}

RC_TEST(FrameConversion, NoseUpAttitudeLiftsTheNoseInGodot)
{
    const Quat noseUp = Quat::FromEuler(0.0, units::Degrees(12.0), 0.0);
    const Quat godot  = frame::RotationToGodot(noseUp);

    // The model's forward (-Z local) must now have a positive Y component.
    const Vec3 noseGodot = godot.Rotate(Vec3(0.0, 0.0, -1.0));
    RC_CHECK(noseGodot.y > 0.0);
    RC_CHECK_NEAR(noseGodot.y, std::sin(units::Degrees(12.0)), 1e-13);
    RC_CHECK_NEAR(noseGodot.z, -std::cos(units::Degrees(12.0)), 1e-13);

    const frame::AttitudeDegrees readout = frame::ToAttitudeDegrees(noseUp);
    RC_CHECK_NEAR(readout.Pitch, 12.0, 1e-9);
    RC_CHECK_NEAR(readout.Roll, 0.0, 1e-9);
    RC_CHECK_NEAR(readout.Yaw, 0.0, 1e-9);
}

RC_TEST(FrameConversion, RightBankDropsTheRightWingInGodot)
{
    const Quat rightBank = Quat::FromEuler(units::Degrees(90.0), 0.0, 0.0);
    const Quat godot     = frame::RotationToGodot(rightBank);

    // The model's right (+X local) must now point down, i.e. -Y in Godot.
    const Vec3 rightWingGodot = godot.Rotate(Vec3(1.0, 0.0, 0.0));
    RC_CHECK(NearlyEqual(rightWingGodot, Vec3(0.0, -1.0, 0.0), 1e-13));
}

RC_TEST(FrameConversion, EastwardHeadingPointsAlongGodotPlusX)
{
    const Quat heading = Quat::FromEuler(0.0, 0.0, units::Degrees(90.0));
    const Vec3 noseGodot = frame::RotationToGodot(heading).Rotate(Vec3(0.0, 0.0, -1.0));

    RC_CHECK(NearlyEqual(noseGodot, Vec3(1.0, 0.0, 0.0), 1e-13));
    RC_CHECK_NEAR(frame::ToAttitudeDegrees(heading).Yaw, 90.0, 1e-9);
}
