#include "TestHarness.h"

#include "RCPhysics/Core/Math/Mat3.h"
#include "RCPhysics/Core/Math/Quat.h"
#include "RCPhysics/Core/Math/Vec3.h"
#include "RCPhysics/Core/Units/Units.h"

using namespace rc;

RC_TEST(Vec3, ArithmeticAndProducts)
{
    const Vec3 a(1.0, 2.0, 3.0);
    const Vec3 b(-4.0, 5.0, 6.0);

    RC_CHECK_NEAR(Dot(a, b), -4.0 + 10.0 + 18.0, 1e-15);
    RC_CHECK_NEAR((a + b).x, -3.0, 1e-15);
    RC_CHECK_NEAR((a * 2.0).z, 6.0, 1e-15);
    RC_CHECK_NEAR(a.Length(), std::sqrt(14.0), 1e-15);

    // Cross product must be right-handed and orthogonal to both inputs.
    const Vec3 c = Cross(a, b);
    RC_CHECK_NEAR(Dot(c, a), 0.0, 1e-14);
    RC_CHECK_NEAR(Dot(c, b), 0.0, 1e-14);
}

RC_TEST(Vec3, WorldFrameIsRightHandedNED)
{
    // North x East must be Down. If this ever fails, every moment in the sim
    // has the wrong sign.
    const Vec3 down = Cross(Vec3::UnitX(), Vec3::UnitY());
    RC_CHECK(NearlyEqual(down, Vec3::UnitZ(), 1e-15));
}

RC_TEST(Vec3, NormalizeIsSafeAtZero)
{
    const Vec3 degenerate(0.0, 0.0, 0.0);
    const Vec3 result = degenerate.Normalized(Vec3::UnitX());
    RC_CHECK(NearlyEqual(result, Vec3::UnitX(), 1e-15));
    RC_CHECK(result.IsFinite());
}

RC_TEST(Vec3, ProjectAndReject)
{
    const Vec3 v(3.0, 4.0, 0.0);
    const Vec3 axis = Vec3::UnitX();
    RC_CHECK(NearlyEqual(ProjectOnUnit(v, axis), Vec3(3.0, 0.0, 0.0), 1e-15));
    RC_CHECK(NearlyEqual(RejectFromUnit(v, axis), Vec3(0.0, 4.0, 0.0), 1e-15));
}

RC_TEST(Mat3, InverseTimesOriginalIsIdentity)
{
    // A plausible aircraft inertia tensor including a product of inertia.
    const Mat3 inertia = Mat3::InertiaTensor(0.052, 0.081, 0.124, 0.0, 0.006, 0.0);
    const Mat3 product = inertia * inertia.Inverse();
    RC_CHECK(NearlyEqual(product, Mat3::Identity(), 1e-12));
}

RC_TEST(Mat3, SingularMatrixFallsBackToIdentity)
{
    const Mat3 singular = Mat3::Zero();
    RC_CHECK(NearlyEqual(singular.Inverse(), Mat3::Identity(), 1e-15));
}

RC_TEST(Mat3, SkewReproducesCrossProduct)
{
    const Vec3 a(0.3, -1.2, 0.7);
    const Vec3 b(2.0, 0.5, -0.4);
    RC_CHECK(NearlyEqual(Mat3::Skew(a) * b, Cross(a, b), 1e-14));
}

RC_TEST(Quat, EulerRoundTrip)
{
    const Real roll  = units::Degrees(23.0);
    const Real pitch = units::Degrees(-11.0);
    const Real yaw   = units::Degrees(142.0);

    const EulerAngles recovered = Quat::FromEuler(roll, pitch, yaw).ToEuler();
    RC_CHECK_NEAR(recovered.roll,  roll,  1e-12);
    RC_CHECK_NEAR(recovered.pitch, pitch, 1e-12);
    RC_CHECK_NEAR(recovered.yaw,   yaw,   1e-12);
}

RC_TEST(Quat, PositivePitchPointsTheNoseUp)
{
    // In NED, "up" is -Z. A nose-up attitude must give the nose vector a
    // negative Z component.
    const Quat attitude = Quat::FromEuler(0.0, units::Degrees(10.0), 0.0);
    const Vec3 noseWorld = attitude.Rotate(Vec3::UnitX());

    RC_CHECK_NEAR(noseWorld.x, std::cos(units::Degrees(10.0)), 1e-12);
    RC_CHECK_NEAR(noseWorld.y, 0.0, 1e-12);
    RC_CHECK_NEAR(noseWorld.z, -std::sin(units::Degrees(10.0)), 1e-12);
    RC_CHECK(noseWorld.z < 0.0);
}

RC_TEST(Quat, PositiveRollDropsTheRightWing)
{
    const Quat attitude = Quat::FromEuler(units::Degrees(90.0), 0.0, 0.0);
    const Vec3 rightWingWorld = attitude.Rotate(Vec3::UnitY());
    // Right wing now points straight down (+Z in NED).
    RC_CHECK(NearlyEqual(rightWingWorld, Vec3::UnitZ(), 1e-12));
}

RC_TEST(Quat, PositiveYawTurnsTowardsEast)
{
    const Quat attitude = Quat::FromEuler(0.0, 0.0, units::Degrees(90.0));
    const Vec3 noseWorld = attitude.Rotate(Vec3::UnitX());
    RC_CHECK(NearlyEqual(noseWorld, Vec3::UnitY(), 1e-12));
}

RC_TEST(Quat, RotateInverseUndoesRotate)
{
    const Quat attitude = Quat::FromEuler(0.4, -0.2, 1.1);
    const Vec3 bodyVector(1.3, -0.7, 0.2);
    const Vec3 roundTrip = attitude.RotateInverse(attitude.Rotate(bodyVector));
    RC_CHECK(NearlyEqual(roundTrip, bodyVector, 1e-13));
}

RC_TEST(Quat, MatrixAgreesWithRotate)
{
    const Quat attitude = Quat::FromEuler(0.4, -0.2, 1.1);
    const Vec3 bodyVector(1.3, -0.7, 0.2);
    RC_CHECK(NearlyEqual(attitude.ToMatrix() * bodyVector, attitude.Rotate(bodyVector), 1e-13));
}

RC_TEST(Quat, IntegrateConstantBodyRate)
{
    // One rad/s of roll for one second must produce exactly one radian, with no
    // norm drift, regardless of how the second is subdivided.
    const Vec3 rollRate(1.0, 0.0, 0.0);
    Quat attitude = Quat::Identity();

    const int steps = 240;
    const Real dt = 1.0 / static_cast<Real>(steps);
    for (int i = 0; i < steps; ++i)
    {
        attitude = attitude.IntegrateBodyRate(rollRate, dt);
    }

    RC_CHECK_NEAR(attitude.ToEuler().roll, 1.0, 1e-12);
    RC_CHECK_NEAR(attitude.Norm(), 1.0, 1e-14);
}

RC_TEST(Quat, RotationVectorHandlesZeroRotation)
{
    const Quat q = Quat::FromRotationVector(Vec3::Zero());
    RC_CHECK_NEAR(q.Norm(), 1.0, 1e-15);
    RC_CHECK(NearlySameRotation(q, Quat::Identity(), 1e-14));
}
