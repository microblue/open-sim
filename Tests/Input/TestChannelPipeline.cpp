#include "TestHarness.h"

#include "RCPhysics/Input/ChannelMapper.h"
#include "RCPhysics/Input/ProfileCheck.h"
#include "RCPhysics/Input/ThrottleArming.h"
#include <string>
#include <sstream>
#include <fstream>
#include "RCPhysics/Core/Units/Units.h"

using namespace rc;

namespace
{
    /** A well-behaved bipolar stick reporting -1..1 with a clean centre. */
    AxisCalibration IdealBipolar(Real deadzone = 0.0)
    {
        AxisCalibration cal;
        cal.RawMin = -1.0; cal.RawCenter = 0.0; cal.RawMax = 1.0;
        cal.Deadzone = deadzone;
        return cal;
    }

    RawAxisState MakeRaw(std::initializer_list<Real> axes)
    {
        RawAxisState raw;
        raw.Connected = true;
        for (Real v : axes)
        {
            raw.Axes[raw.AxisCount++] = v;
        }
        return raw;
    }
}

// ------------------------------------------------------------------- expo ---

RC_TEST(Expo, ZeroExpoIsLinear)
{
    for (Real x = -1.0; x <= 1.0; x += 0.25)
    {
        RC_CHECK_NEAR(ApplyExpo(x, 0.0), x, 1e-15);
    }
}

RC_TEST(Expo, FullTravelSurvivesAnyExpo)
{
    // The defining property of the RC expo curve: it softens the centre without
    // costing any maximum deflection. If this fails, high expo would quietly
    // reduce control authority.
    for (Real e = 0.0; e <= 1.0; e += 0.1)
    {
        RC_CHECK_NEAR(ApplyExpo(1.0, e), 1.0, 1e-14);
        RC_CHECK_NEAR(ApplyExpo(-1.0, e), -1.0, 1e-14);
        RC_CHECK_NEAR(ApplyExpo(0.0, e), 0.0, 1e-15);
    }
}

RC_TEST(Expo, SoftensTheCentre)
{
    // 30% expo, half stick: 0.3*0.125 + 0.7*0.5 = 0.3875
    RC_CHECK_NEAR(ApplyExpo(0.5, 0.3), 0.3875, 1e-14);
    RC_CHECK(ApplyExpo(0.5, 0.3) < 0.5);
    RC_CHECK_NEAR(ExpoCentreSensitivity(0.3), 0.7, 1e-15);
}

RC_TEST(Expo, IsOddSymmetric)
{
    // An asymmetric expo curve would make left and right aileron feel different.
    for (Real x = 0.0; x <= 1.0; x += 0.125)
    {
        RC_CHECK_NEAR(ApplyExpo(-x, 0.4), -ApplyExpo(x, 0.4), 1e-15);
    }
}

RC_TEST(Expo, ClampsOutOfRangeInput)
{
    RC_CHECK_NEAR(ApplyExpo(2.0, 0.5), 1.0, 1e-14);
    RC_CHECK_NEAR(ApplyExpo(-2.0, 0.5), -1.0, 1e-14);
}

// ------------------------------------------------------------ calibration ---

RC_TEST(Calibration, IdealAxisPassesThrough)
{
    const AxisCalibration cal = IdealBipolar();
    RC_CHECK_NEAR(cal.Normalize(0.0, true), 0.0, 1e-15);
    RC_CHECK_NEAR(cal.Normalize(1.0, true), 1.0, 1e-15);
    RC_CHECK_NEAR(cal.Normalize(-1.0, true), -1.0, 1e-15);
    RC_CHECK_NEAR(cal.Normalize(0.5, true), 0.5, 1e-15);
}

RC_TEST(Calibration, OffCentreStickStillRestsAtZeroAndReachesFullTravel)
{
    // A real gimbal: doesn't reach the ends, and its centre is off.
    AxisCalibration cal;
    cal.RawMin = -0.82; cal.RawCenter = 0.06; cal.RawMax = 0.91;
    cal.Deadzone = 0.0;

    RC_CHECK_NEAR(cal.Normalize(0.06, true), 0.0, 1e-14);
    RC_CHECK_NEAR(cal.Normalize(0.91, true), 1.0, 1e-14);
    RC_CHECK_NEAR(cal.Normalize(-0.82, true), -1.0, 1e-14);

    // Half travel on each side must read as half, despite the asymmetry.
    RC_CHECK_NEAR(cal.Normalize(0.06 + 0.5 * (0.91 - 0.06), true), 0.5, 1e-14);
    RC_CHECK_NEAR(cal.Normalize(0.06 - 0.5 * (0.06 + 0.82), true), -0.5, 1e-14);
}

RC_TEST(Calibration, DeadzoneDoesNotCostFullDeflection)
{
    // The stick must still reach exactly 1.0 with a deadzone applied, or a
    // deadzone would silently reduce maximum control throw.
    const AxisCalibration cal = IdealBipolar(0.05);
    RC_CHECK_NEAR(cal.Normalize(0.0, true), 0.0, 1e-15);
    RC_CHECK_NEAR(cal.Normalize(0.04, true), 0.0, 1e-15);
    RC_CHECK_NEAR(cal.Normalize(1.0, true), 1.0, 1e-14);
    RC_CHECK_NEAR(cal.Normalize(-1.0, true), -1.0, 1e-14);
    // Just past the deadzone the output starts from zero, not from 0.05.
    RC_CHECK_NEAR(cal.Normalize(0.05, true), 0.0, 1e-14);
    RC_CHECK(cal.Normalize(0.10, true) > 0.0);
    RC_CHECK(cal.Normalize(0.10, true) < 0.10);
}

RC_TEST(Calibration, ThrottleIsUnipolar)
{
    AxisCalibration cal;
    cal.RawMin = -1.0; cal.RawCenter = 0.0; cal.RawMax = 1.0;
    cal.Deadzone = 0.0;

    RC_CHECK_NEAR(cal.Normalize(-1.0, false), 0.0, 1e-15);
    RC_CHECK_NEAR(cal.Normalize(0.0, false), 0.5, 1e-15);
    RC_CHECK_NEAR(cal.Normalize(1.0, false), 1.0, 1e-15);
    // Never negative, whatever the device reports.
    RC_CHECK(cal.Normalize(-5.0, false) >= 0.0);
}

RC_TEST(Calibration, ReverseFlipsTheSense)
{
    AxisCalibration cal = IdealBipolar();
    cal.Reversed = true;
    RC_CHECK_NEAR(cal.Normalize(1.0, true), -1.0, 1e-15);
    RC_CHECK_NEAR(cal.Normalize(-1.0, true), 1.0, 1e-15);
}

RC_TEST(Calibration, RejectsUnusableRanges)
{
    AxisCalibration dead;
    dead.RawMin = 0.0; dead.RawCenter = 0.0; dead.RawMax = 0.0;
    RC_CHECK(!dead.IsValid());
    RC_CHECK_NEAR(dead.Normalize(0.5, true), 0.0, 1e-15);

    AxisCalibration centreOutside;
    centreOutside.RawMin = -1.0; centreOutside.RawCenter = 2.0; centreOutside.RawMax = 1.0;
    RC_CHECK(!centreOutside.IsValid());
}

// ------------------------------------------------------ calibration capture --

RC_TEST(CalibrationCapture, LearnsTravelAndCentre)
{
    CalibrationCapture capture;
    for (int i = 0; i < 20; ++i) { capture.SampleCentre(0.04); }
    capture.SampleTravel(-0.88);
    capture.SampleTravel(0.93);

    const AxisCalibration cal = capture.Result(0.02);
    RC_CHECK_NEAR(cal.RawMin, -0.88, 1e-12);
    RC_CHECK_NEAR(cal.RawMax, 0.93, 1e-12);
    RC_CHECK_NEAR(cal.RawCenter, 0.04, 1e-12);
    RC_CHECK(cal.IsValid());
    RC_CHECK_NEAR(capture.ObservedRange(), 1.81, 1e-12);
}

RC_TEST(CalibrationCapture, FallsBackWhenTheCentreLandsOnTheEdgeOfTravel)
{
    // Pilot held the stick at 0.95 during the centring step. A centre sample is
    // also a travel sample - the stick really was reachable there - so travel
    // becomes -0.5..0.95 and the captured "centre" sits exactly on RawMax.
    //
    // Taking that at face value would report full deflection at rest, so the
    // capture must reject it and fall back to the midpoint.
    CalibrationCapture capture;
    capture.SampleCentre(0.95);
    capture.SampleTravel(-0.5);
    capture.SampleTravel(0.6);

    const AxisCalibration cal = capture.Result();
    RC_CHECK_NEAR(cal.RawMin, -0.5, 1e-12);
    RC_CHECK_NEAR(cal.RawMax, 0.95, 1e-12);
    RC_CHECK(cal.RawCenter > cal.RawMin && cal.RawCenter < cal.RawMax);
    RC_CHECK_NEAR(cal.RawCenter, 0.225, 1e-12);   // midpoint of -0.5..0.95
    RC_CHECK(cal.IsValid());

    // And the resulting calibration must read zero at rest, not full stick.
    RC_CHECK_NEAR(cal.Normalize(0.225, true), 0.0, 1e-14);
}

RC_TEST(CalibrationCapture, AnUnsweptAxisYieldsAnInvalidCalibration)
{
    // The default -1/0/+1 would look perfectly valid, so an axis that was never
    // moved would bind successfully in the wizard and then read full deflection
    // at rest. It must come back explicitly invalid instead.
    CalibrationCapture untouched;
    const AxisCalibration cal = untouched.Result();
    RC_CHECK(!cal.IsValid());
    RC_CHECK_NEAR(untouched.ObservedRange(), 0.0, 1e-15);

    // And a barely-moved axis is rejected too - that is noise, not a stick.
    CalibrationCapture jittered;
    jittered.SampleTravel(0.001);
    jittered.SampleTravel(-0.001);
    RC_CHECK(!jittered.Result().IsValid());
}

RC_TEST(CalibrationCapture, ResetTravelKeepsTheCentre)
{
    // The wizard captures every axis's centre once and then sweeps one stick at
    // a time. Resetting the travel between sticks must not throw the centres
    // away, or every axis after the first would be calibrated without one.
    CalibrationCapture capture;
    for (int i = 0; i < 10; ++i) { capture.SampleCentre(0.05); }
    capture.SampleTravel(-0.9);
    capture.SampleTravel(0.9);
    RC_CHECK(capture.Result().IsValid());

    capture.ResetTravel();
    RC_CHECK(capture.HasCentre());
    RC_CHECK(!capture.HasTravel());
    RC_CHECK_NEAR(capture.ObservedRange(), 0.0, 1e-15);
    RC_CHECK(!capture.Result().IsValid());   // no travel yet, so unusable

    capture.SampleTravel(-0.7);
    capture.SampleTravel(0.8);
    const AxisCalibration cal = capture.Result();
    RC_CHECK(cal.IsValid());
    RC_CHECK_NEAR(cal.RawCenter, 0.05, 1e-12);   // the centre survived
    RC_CHECK_NEAR(cal.RawMin, -0.7, 1e-12);
    RC_CHECK_NEAR(cal.RawMax, 0.8, 1e-12);
}

RC_TEST(CalibrationCapture, IdentifiesTheMovedAxis)
{
    CalibrationCapture captures[4];
    // Axis 2 is the one the pilot wiggled; the others only drift.
    captures[0].SampleTravel(0.00); captures[0].SampleTravel(0.01);
    captures[1].SampleTravel(0.00); captures[1].SampleTravel(-0.02);
    captures[2].SampleTravel(-0.9); captures[2].SampleTravel(0.9);
    captures[3].SampleTravel(0.00); captures[3].SampleTravel(0.00);

    RC_CHECK(FindMostMovedAxis(captures, 4) == 2);
}

RC_TEST(CalibrationCapture, RefusesToGuessWhenTwoAxesMoveTogether)
{
    // Some gimbals cross-talk. Binding the wrong axis here would be worse than
    // asking the pilot to try again.
    CalibrationCapture captures[2];
    captures[0].SampleTravel(-0.8); captures[0].SampleTravel(0.8);
    captures[1].SampleTravel(-0.75); captures[1].SampleTravel(0.75);

    RC_CHECK(FindMostMovedAxis(captures, 2) == -1);
}

RC_TEST(CalibrationCapture, ReportsNothingWhenNothingMoved)
{
    CalibrationCapture captures[3];
    for (auto& c : captures) { c.SampleTravel(0.0); }
    RC_CHECK(FindMostMovedAxis(captures, 3) == -1);
}

// ---------------------------------------------------------- channel mapper --

RC_TEST(ChannelMapper, MapsFourPrimaryChannels)
{
    ChannelMapper mapper;
    mapper.Bind(RCChannel::Aileron,  0, IdealBipolar());
    mapper.Bind(RCChannel::Elevator, 1, IdealBipolar());
    mapper.Bind(RCChannel::Throttle, 2, IdealBipolar());
    mapper.Bind(RCChannel::Rudder,   3, IdealBipolar());
    RC_CHECK(mapper.IsFullyBound());

    const ChannelValues values = mapper.Update(MakeRaw({0.5, -0.25, 0.0, 1.0}));
    RC_CHECK_NEAR(values.Aileron(),  0.5, 1e-14);
    RC_CHECK_NEAR(values.Elevator(), -0.25, 1e-14);
    RC_CHECK_NEAR(values.Throttle(), 0.5, 1e-14);    // unipolar: mid-travel
    RC_CHECK_NEAR(values.Rudder(),   1.0, 1e-14);
}

RC_TEST(ChannelMapper, DisconnectionClosesTheThrottleAndCentresTheSticks)
{
    // A stuck throttle after an unplug teaches exactly the wrong reflex.
    ChannelMapper mapper;
    mapper.Bind(RCChannel::Aileron,  0, IdealBipolar());
    mapper.Bind(RCChannel::Throttle, 1, IdealBipolar());

    RawAxisState live = MakeRaw({0.9, 1.0});
    const ChannelValues flying = mapper.Update(live);
    RC_CHECK_NEAR(flying.Throttle(), 1.0, 1e-14);

    live.Connected = false;
    const ChannelValues lost = mapper.Update(live);
    RC_CHECK_NEAR(lost.Throttle(), 0.0, 1e-15);
    RC_CHECK_NEAR(lost.Aileron(), 0.0, 1e-15);
}

RC_TEST(ChannelMapper, UnboundChannelsReadNeutral)
{
    ChannelMapper mapper;
    mapper.Bind(RCChannel::Aileron, 0, IdealBipolar());
    RC_CHECK(!mapper.IsFullyBound());

    const ChannelValues values = mapper.Update(MakeRaw({1.0, 1.0, 1.0, 1.0}));
    RC_CHECK_NEAR(values.Aileron(), 1.0, 1e-14);
    RC_CHECK_NEAR(values.Elevator(), 0.0, 1e-15);
    RC_CHECK_NEAR(values.Rudder(), 0.0, 1e-15);
}

RC_TEST(ChannelMapper, OutOfRangeAxisIndexIsSafe)
{
    ChannelMapper mapper;
    mapper.Bind(RCChannel::Aileron, 9, IdealBipolar());
    const ChannelValues values = mapper.Update(MakeRaw({1.0, 1.0}));
    RC_CHECK_NEAR(values.Aileron(), 0.0, 1e-15);
}

RC_TEST(ChannelMapper, AppliesShapingInTransmitterOrder)
{
    // expo -> dual rate -> trim. Applying rate first would change the expo feel
    // every time the rate switch is flipped, which is not how a radio behaves.
    ChannelMapper mapper;
    mapper.Bind(RCChannel::Elevator, 0, IdealBipolar());
    ChannelShaping& shaping = mapper.Binding(RCChannel::Elevator).Shaping;
    shaping.Expo = 0.3;
    shaping.DualRate = 0.8;
    shaping.Trim = 0.05;

    // expo(0.5, 0.3) = 0.3875 ; * 0.8 = 0.31 ; + 0.05 = 0.36
    const ChannelValues values = mapper.Update(MakeRaw({0.5}));
    RC_CHECK_NEAR(values.Elevator(), 0.36, 1e-13);
}

RC_TEST(ChannelMapper, RawModeBypassesShapingButKeepsCalibration)
{
    ChannelMapper mapper;
    AxisCalibration offCentre;
    offCentre.RawMin = -0.8; offCentre.RawCenter = 0.0; offCentre.RawMax = 0.8;
    offCentre.Deadzone = 0.0;
    mapper.Bind(RCChannel::Aileron, 0, offCentre);

    ChannelShaping& shaping = mapper.Binding(RCChannel::Aileron).Shaping;
    shaping.Expo = 0.5;
    shaping.DualRate = 0.5;
    shaping.Trim = 0.2;

    mapper.SetRawMode(true);
    RC_CHECK(mapper.IsRawMode());

    // Calibration still scales 0.4 raw to 0.5, but no expo, rate or trim.
    const ChannelValues values = mapper.Update(MakeRaw({0.4}));
    RC_CHECK_NEAR(values.Aileron(), 0.5, 1e-14);

    mapper.SetRawMode(false);
    RC_CHECK(!mapper.IsRawMode());
    RC_CHECK(std::fabs(mapper.Update(MakeRaw({0.4})).Aileron() - 0.5) > 1e-6);
}

RC_TEST(ChannelMapper, TrimCannotPushTheStickBeyondFullTravel)
{
    ChannelMapper mapper;
    mapper.Bind(RCChannel::Elevator, 0, IdealBipolar());
    mapper.Binding(RCChannel::Elevator).Shaping.Trim = 0.5;

    RC_CHECK_NEAR(mapper.Update(MakeRaw({1.0})).Elevator(), 1.0, 1e-15);
    RC_CHECK_NEAR(mapper.Update(MakeRaw({-1.0})).Elevator(), -0.5, 1e-14);
}

RC_TEST(ChannelMapper, ProfileRoundTripsThroughJson)
{
    ChannelMapper original;
    AxisCalibration cal;
    cal.RawMin = -0.82; cal.RawCenter = 0.06; cal.RawMax = 0.91;
    cal.Deadzone = 0.035; cal.Reversed = true;
    original.Bind(RCChannel::Elevator, 3, cal);
    original.Binding(RCChannel::Elevator).Shaping.Expo = 0.28;
    original.Binding(RCChannel::Elevator).Shaping.DualRate = 0.75;
    original.Binding(RCChannel::Elevator).Shaping.Trim = -0.04;
    original.Bind(RCChannel::Throttle, 2, IdealBipolar());

    const std::string json = original.ToJson();

    ChannelMapper restored;
    std::string error;
    if (!restored.FromJson(json, &error))
    {
        RC_FAIL("profile did not parse: " + error);
        return;
    }

    const ChannelBinding& b = restored.Binding(RCChannel::Elevator);
    RC_CHECK(b.AxisIndex == 3);
    RC_CHECK_NEAR(b.Calibration.RawCenter, 0.06, 1e-9);
    RC_CHECK_NEAR(b.Calibration.Deadzone, 0.035, 1e-9);
    RC_CHECK(b.Calibration.Reversed);
    RC_CHECK_NEAR(b.Shaping.Expo, 0.28, 1e-9);
    RC_CHECK_NEAR(b.Shaping.DualRate, 0.75, 1e-9);
    RC_CHECK_NEAR(b.Shaping.Trim, -0.04, 1e-9);

    // And it must produce identical stick values.
    const RawAxisState raw = MakeRaw({0.1, 0.2, 0.3, 0.45});
    RC_CHECK_NEAR(restored.Update(raw).Elevator(),
                  original.Update(raw).Elevator(), 1e-9);
}

RC_TEST(ChannelMapper, RejectsMalformedProfile)
{
    ChannelMapper mapper;
    std::string error;
    RC_CHECK(!mapper.FromJson("{ not json", &error));
    RC_CHECK(!error.empty());
    RC_CHECK(!mapper.FromJson("{\"format_version\": 1}", &error));
}

// ------------------------------------------------ the throttle interlock --

RC_TEST(ThrottleArming, StaysClosedUntilIdleIsSeen)
{
    rc::ThrottleArming arming;
    RC_CHECK(!arming.IsArmed());

    // A stale mid-range reading must not reach the motor. This is the exact
    // case a transmitter presents at startup when no axis has moved yet.
    RC_CHECK_NEAR(arming.Apply(0.5), 0.0, 1e-12);
    RC_CHECK(!arming.IsArmed());

    // Nor may holding the stick open force it through.
    RC_CHECK_NEAR(arming.Apply(1.0), 0.0, 1e-12);
    RC_CHECK_NEAR(arming.Apply(0.9), 0.0, 1e-12);
    RC_CHECK(!arming.IsArmed());
}

RC_TEST(ThrottleArming, ArmsOnIdleAndThenPassesThrough)
{
    rc::ThrottleArming arming;

    RC_CHECK_NEAR(arming.Apply(0.0), 0.0, 1e-12);
    RC_CHECK(arming.IsArmed());

    RC_CHECK_NEAR(arming.Apply(0.35), 0.35, 1e-12);
    RC_CHECK_NEAR(arming.Apply(1.0), 1.0, 1e-12);
}

RC_TEST(ThrottleArming, DoesNotDisarmInFlight)
{
    rc::ThrottleArming arming;
    arming.Apply(0.0);

    // Throttling back on approach and opening up for a go-around must not be
    // interrupted by the interlock re-engaging.
    RC_CHECK_NEAR(arming.Apply(0.6), 0.6, 1e-12);
    RC_CHECK_NEAR(arming.Apply(0.0), 0.0, 1e-12);
    RC_CHECK(arming.IsArmed());
    RC_CHECK_NEAR(arming.Apply(0.8), 0.8, 1e-12);
}

RC_TEST(ThrottleArming, ResetRequiresIdleAgain)
{
    rc::ThrottleArming arming;
    arming.Apply(0.0);
    RC_CHECK(arming.IsArmed());

    // Swapping controller or reloading a profile invalidates the reading that
    // armed it.
    arming.Reset();
    RC_CHECK(!arming.IsArmed());
    RC_CHECK_NEAR(arming.Apply(0.7), 0.0, 1e-12);
}

RC_TEST(ThrottleArming, AcceptsASlightlyMiscalibratedBottomEnd)
{
    rc::ThrottleArming arming;

    // A bottom end a couple of percent off must still arm - otherwise a pilot
    // whose calibration is marginally short can never start the motor.
    RC_CHECK_NEAR(arming.Apply(0.04), 0.04, 1e-12);
    RC_CHECK(arming.IsArmed());
}

// ------------------------------------------------------- profile versioning --

RC_TEST(ProfileFormat, RejectsPreRawAxisProfiles)
{
    // A version 1 file was captured through Godot's SDL gamepad mapping, which
    // renumbers axes and rescales some to 0..1. Here it binds the throttle to
    // axis 4 with a 0..1 range - under the raw axis layout that axis is a
    // three-position switch, so loading it would hand the motor to a switch.
    const std::string stale = R"({
        "format_version": 1,
        "channels": {
            "throttle": { "axis": 4, "raw_min": 0.0, "raw_center": 0.5, "raw_max": 1.0 }
        }
    })";

    rc::ChannelMapper mapper;
    std::string error;
    RC_CHECK(!mapper.FromJson(stale, &error));
    RC_CHECK(!error.empty());

    // Nothing may have been bound from the rejected file.
    RC_CHECK(!mapper.Binding(rc::RCChannel::Throttle).IsBound());
}

RC_TEST(ProfileFormat, AcceptsCurrentProfiles)
{
    const std::string current = R"({
        "format_version": 2,
        "channels": {
            "throttle": { "axis": 2, "raw_min": -1.0, "raw_center": 0.0, "raw_max": 1.0 }
        }
    })";

    rc::ChannelMapper mapper;
    std::string error;
    RC_CHECK(mapper.FromJson(current, &error));
    RC_CHECK(mapper.Binding(rc::RCChannel::Throttle).AxisIndex == 2);
}

RC_TEST(ProfileFormat, WhatWeWriteIsWhatWeAccept)
{
    // A round trip must survive, or the wizard would save profiles it then
    // refuses to load.
    rc::ChannelMapper saved;
    rc::AxisCalibration calibration;
    calibration.RawMin = -1.0;
    calibration.RawMax =  1.0;
    saved.Bind(rc::RCChannel::Aileron, 0, calibration);

    rc::ChannelMapper loaded;
    std::string error;
    RC_CHECK(loaded.FromJson(saved.ToJson(), &error));
    RC_CHECK(loaded.Binding(rc::RCChannel::Aileron).AxisIndex == 0);
}

// ------------------------------------------- profile against a real device --

namespace
{
    /** A radio at rest, laid out the way EdgeTX presents it: three centred
     *  sticks, a throttle at the bottom, three switches at one end. */
    rc::RawAxisState RestingRadio()
    {
        rc::RawAxisState raw;
        raw.Connected = true;
        raw.AxisCount = 7;
        raw.Axes[0] =  0.00;   // aileron
        raw.Axes[1] =  0.00;   // elevator
        raw.Axes[2] = -1.00;   // throttle, closed
        raw.Axes[3] =  0.00;   // rudder
        raw.Axes[4] = -1.00;
        raw.Axes[5] = -1.00;
        raw.Axes[6] = -1.00;
        return raw;
    }

    rc::ChannelMapper MapperBinding(int aileron, int elevator, int throttle, int rudder)
    {
        rc::AxisCalibration calibration;
        calibration.RawMin = -1.0;
        calibration.RawCenter = 0.0;
        calibration.RawMax = 1.0;

        rc::ChannelMapper mapper;
        mapper.Bind(rc::RCChannel::Aileron, aileron, calibration);
        mapper.Bind(rc::RCChannel::Elevator, elevator, calibration);
        mapper.Bind(rc::RCChannel::Throttle, throttle, calibration);
        mapper.Bind(rc::RCChannel::Rudder, rudder, calibration);
        return mapper;
    }
}

RC_TEST(ProfileCheck, AcceptsABindingThatMatchesTheRadio)
{
    const rc::ChannelMapper mapper = MapperBinding(0, 1, 2, 3);
    RC_CHECK(rc::DescribeProfileMismatch(mapper, RestingRadio()).empty());
}

RC_TEST(ProfileCheck, CatchesAThrottleBoundToASelfCentringStick)
{
    // Throttle on axis 3, which is a rudder. This is the dangerous one: the
    // motor would answer the stick the pilot steers with.
    const rc::ChannelMapper mapper = MapperBinding(0, 1, 3, 2);
    const std::string problem = rc::DescribeProfileMismatch(mapper, RestingRadio());
    RC_CHECK(!problem.empty());
    RC_CHECK(problem.find("throttle") != std::string::npos);
}

RC_TEST(ProfileCheck, CatchesAStickBoundToTheThrottle)
{
    // Rudder on axis 2, which is the throttle - the other half of the same
    // mix-up, and the reason the aircraft would steer itself on the runway.
    const rc::ChannelMapper mapper = MapperBinding(0, 1, 3, 2);
    rc::RawAxisState resting = RestingRadio();
    // Put a real throttle on axis 3 so the throttle check passes and the stick
    // check is the one that has to catch it.
    resting.Axes[3] = -1.0;
    resting.Axes[2] = -1.0;
    const std::string problem = rc::DescribeProfileMismatch(mapper, resting);
    RC_CHECK(!problem.empty());
    RC_CHECK(problem.find("rudder") != std::string::npos);
}

RC_TEST(ProfileCheck, SaysNothingWithNoDeviceAttached)
{
    const rc::ChannelMapper mapper = MapperBinding(0, 1, 2, 3);
    rc::RawAxisState absent;
    absent.Connected = false;
    RC_CHECK(rc::DescribeProfileMismatch(mapper, absent).empty());
}

RC_TEST(ProfileCheck, ToleratesSwitchesRestingAtAnEnd)
{
    // Flap and aux1 sit on switches, which legitimately rest at one end. They
    // must not be reported as mis-bound sticks.
    rc::AxisCalibration calibration;
    calibration.RawMin = -1.0;
    calibration.RawMax = 1.0;
    rc::ChannelMapper mapper = MapperBinding(0, 1, 2, 3);
    mapper.Bind(rc::RCChannel::Flap, 4, calibration);
    mapper.Bind(rc::RCChannel::Aux1, 5, calibration);
    RC_CHECK(rc::DescribeProfileMismatch(mapper, RestingRadio()).empty());
}

RC_TEST(ProfileCheck, TheShippedEdgeTxProfileMatchesAnEdgeTxRadio)
{
    // The whole point of the built-in profile is that a pilot never has to run
    // the wizard, so it has to survive its own check.
    std::ifstream file(std::string(RC_REPO_ROOT) + "/Data/Input/Profiles/edgetx_aetr.json");
    std::ostringstream buffer;
    buffer << file.rdbuf();

    rc::ChannelMapper mapper;
    RC_CHECK(mapper.FromJson(buffer.str()));
    RC_CHECK(rc::DescribeProfileMismatch(mapper, RestingRadio()).empty());
}

RC_TEST(ProfileCheck, CatchesATransmitterThatSendsNothing)
{
    // A radio that enumerates but is not driving its channels - switched off
    // and charging, out of USB Joystick mode, or on a model with no mixes. It
    // has to be told apart from a bad binding, because the advice differs: the
    // wizard cannot calibrate a radio that is not sending anything.
    rc::RawAxisState silent;
    silent.Connected = true;
    silent.AxisCount = 7;   // every axis defaults to exactly zero

    const rc::ChannelMapper mapper = MapperBinding(0, 1, 2, 3);
    const std::string problem = rc::DescribeProfileMismatch(mapper, silent);
    RC_CHECK(!problem.empty());
    RC_CHECK(problem.find("not sending anything") != std::string::npos);
    // And it must not send them to the wizard.
    RC_CHECK(problem.find("recalibrate") == std::string::npos);
}

RC_TEST(ProfileCheck, ARealRadioIsNotMistakenForASilentOne)
{
    // A live radio always has something off centre - the throttle at least.
    const rc::ChannelMapper mapper = MapperBinding(0, 1, 2, 3);
    RC_CHECK(rc::DescribeProfileMismatch(mapper, RestingRadio()).empty());
}
