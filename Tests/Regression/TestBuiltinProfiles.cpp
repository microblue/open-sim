// OpenRC Simulator - the shipped transmitter profiles.
//
// Data/Input/Profiles/*.json are applied automatically at startup when a
// matching radio is plugged in, which means a pilot may never run the wizard and
// never see these numbers. A typo in one of them would show up as an aircraft
// that rolls the wrong way on the first flight, so the files are pinned here:
// they must parse, bind every channel, and produce the sense the flight model
// expects.
//
// The axis assignment was confirmed against a RadioMaster Boxer (USB 1209:4f54)
// reading /dev/input/js0 directly, so these are measured, not assumed.

#include "RCPhysics/Input/ChannelMapper.h"
#include "RCPhysics/Input/ChannelTypes.h"
#include "TestHarness.h"

#include <fstream>
#include <sstream>
#include <string>

namespace
{
    const std::string kEdgeTxPath =
        std::string(RC_REPO_ROOT) + "/Data/Input/Profiles/edgetx_aetr.json";

    std::string ReadFile(const std::string& path)
    {
        std::ifstream file(path);
        if (!file) { return {}; }
        std::ostringstream buffer;
        buffer << file.rdbuf();
        return buffer.str();
    }

    // A radio at rest: sticks centred, throttle closed, switches at one end.
    rc::RawAxisState RestingBoxer()
    {
        rc::RawAxisState raw;
        raw.Connected = true;
        raw.AxisCount = 7;
        raw.Axes[0] =  0.0;   // aileron  centred
        raw.Axes[1] =  0.0;   // elevator centred
        raw.Axes[2] = -1.0;   // throttle closed
        raw.Axes[3] =  0.0;   // rudder   centred
        raw.Axes[4] = -1.0;
        raw.Axes[5] = -1.0;
        raw.Axes[6] = -1.0;
        return raw;
    }

    rc::ChannelMapper LoadEdgeTx()
    {
        rc::ChannelMapper mapper;
        std::string error;
        mapper.FromJson(ReadFile(kEdgeTxPath), &error);
        return mapper;
    }
}

RC_TEST(BuiltinProfile, EdgeTxFileParses)
{
    const std::string text = ReadFile(kEdgeTxPath);
    RC_CHECK(!text.empty());

    rc::ChannelMapper mapper;
    std::string error;
    const bool ok = mapper.FromJson(text, &error);
    if (!ok) { RC_FAIL(error.c_str()); }
    RC_CHECK(mapper.IsFullyBound());
}

RC_TEST(BuiltinProfile, EdgeTxBindsAetrInChannelOrder)
{
    const rc::ChannelMapper mapper = LoadEdgeTx();

    // EdgeTX publishes channel N on axis N-1, and the model is set up AETR.
    RC_CHECK(mapper.Binding(rc::RCChannel::Aileron).AxisIndex  == 0);
    RC_CHECK(mapper.Binding(rc::RCChannel::Elevator).AxisIndex == 1);
    RC_CHECK(mapper.Binding(rc::RCChannel::Throttle).AxisIndex == 2);
    RC_CHECK(mapper.Binding(rc::RCChannel::Rudder).AxisIndex   == 3);
}

RC_TEST(BuiltinProfile, EdgeTxRestsSafely)
{
    const rc::ChannelMapper mapper = LoadEdgeTx();
    const rc::ChannelValues values = mapper.Update(RestingBoxer());

    // Nothing may creep while the pilot is not touching the radio, and the
    // motor must be stopped - this is the state the aircraft sits on the
    // runway in.
    RC_CHECK_NEAR(values.Aileron(),  0.0, 1e-9);
    RC_CHECK_NEAR(values.Elevator(), 0.0, 1e-9);
    RC_CHECK_NEAR(values.Rudder(),   0.0, 1e-9);
    RC_CHECK_NEAR(values.Throttle(), 0.0, 1e-9);
}

RC_TEST(BuiltinProfile, EdgeTxThrottleOpensFullyAndMonotonically)
{
    const rc::ChannelMapper mapper = LoadEdgeTx();

    rc::RawAxisState raw = RestingBoxer();
    raw.Axes[2] = 1.0;
    RC_CHECK_NEAR(mapper.Update(raw).Throttle(), 1.0, 1e-9);

    raw.Axes[2] = 0.0;
    const rc::Real half = mapper.Update(raw).Throttle();
    RC_CHECK(half > 0.4 && half < 0.6);
}

RC_TEST(BuiltinProfile, EdgeTxStickSenseMatchesTheFlightModel)
{
    const rc::ChannelMapper mapper = LoadEdgeTx();

    // The aircraft definition is written so that a positive channel means roll
    // right, pitch nose up, yaw nose right. Aileron and rudder come off the
    // radio with that sense already; elevator is reversed in the profile
    // because EdgeTX makes a forward (nose-down) stick positive.
    rc::RawAxisState raw = RestingBoxer();

    raw.Axes[0] = 1.0;                                    // stick right
    RC_CHECK_NEAR(mapper.Update(raw).Aileron(), 1.0, 1e-9);
    raw.Axes[0] = 0.0;

    raw.Axes[1] = -1.0;                                   // stick pulled back
    RC_CHECK_NEAR(mapper.Update(raw).Elevator(), 1.0, 1e-9);
    raw.Axes[1] = 0.0;

    raw.Axes[3] = 1.0;                                    // stick right
    RC_CHECK_NEAR(mapper.Update(raw).Rudder(), 1.0, 1e-9);
}

RC_TEST(BuiltinProfile, EdgeTxDoesNotDoubleApplyShaping)
{
    const rc::ChannelMapper mapper = LoadEdgeTx();

    // The radio has already applied whatever expo and rates the pilot set
    // before the value reaches USB. Shaping it again here would mean the sim
    // stops feeling like their transmitter.
    for (const rc::RCChannel channel : {rc::RCChannel::Aileron,
                                        rc::RCChannel::Elevator,
                                        rc::RCChannel::Throttle,
                                        rc::RCChannel::Rudder})
    {
        const rc::ChannelBinding& binding = mapper.Binding(channel);
        RC_CHECK_NEAR(binding.Shaping.Expo, 0.0, 1e-12);
        RC_CHECK_NEAR(binding.Shaping.DualRate, 1.0, 1e-12);
        RC_CHECK_NEAR(binding.Shaping.Trim, 0.0, 1e-12);
    }
}

RC_TEST(BuiltinProfile, EdgeTxDeadzoneIsSmallEnoughToFlyPrecisely)
{
    const rc::ChannelMapper mapper = LoadEdgeTx();

    // A wide deadzone teaches a stick feel the real aircraft will not have.
    for (const rc::RCChannel channel : {rc::RCChannel::Aileron,
                                        rc::RCChannel::Elevator,
                                        rc::RCChannel::Rudder})
    {
        RC_CHECK(mapper.Binding(channel).Calibration.Deadzone <= 0.03);
    }

    // A small stick input must still produce a proportional response rather
    // than being swallowed.
    rc::RawAxisState raw = RestingBoxer();
    raw.Axes[0] = 0.10;
    const rc::Real value = mapper.Update(raw).Aileron();
    RC_CHECK(value > 0.05 && value < 0.10);
}
