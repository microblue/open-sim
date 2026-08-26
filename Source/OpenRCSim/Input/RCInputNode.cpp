#include "RCInputNode.h"

#include "../Bridge/RCDataPaths.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/input.hpp>

#include <algorithm>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include "RCPhysics/Core/Log.h"

using namespace godot;

namespace openrc
{
namespace
{
    static_assert(static_cast<size_t>(RCInputNode::CHANNEL_COUNT) == rc::kChannelCount,
                  "RCInputNode::Channel has drifted out of step with rc::RCChannel");

    /** Godot reports up to ten axes per device. RC transmitters in HID mode
     *  present four to eight, so this covers everything without assuming a
     *  gamepad layout. */
    constexpr int kMaxPolledAxes = 10;
}

void RCInputNode::_ready()
{
    set_process(true);
    PollDevice();
}

void RCInputNode::_process(double deltaSeconds)
{
    PollDevice();

    if (Capturing)
    {
        for (size_t i = 0; i < RawAxes.AxisCount; ++i)
        {
            if (CapturingCentre) { Captures[i].SampleCentre(RawAxes.Axes[i]); }
            else                 { Captures[i].SampleTravel(RawAxes.Axes[i]); }
        }
    }

    CurrentChannels = Mapper_.Update(RawAxes);

    // The motor stays stopped until the throttle has been seen closed. See
    // ThrottleArming.h - this also covers a transmitter that has not yet
    // reported a real value for the throttle axis, where the raw zero would
    // otherwise normalise to half power.
    CurrentChannels.Set(rc::RCChannel::Throttle,
                        ThrottleArming_.Apply(CurrentChannels.Throttle()));

    ApplyKeyboard(deltaSeconds);
}

bool RCInputNode::is_using_keyboard() const
{
    // Asked, not remembered. A cached flag is only true once _process has run,
    // so a caller in the same frame the node was created - the in-engine tests,
    // and the HUD on its first draw - was told the controls were dead when they
    // were not.
    return !is_connected();
}

void RCInputNode::ApplyKeyboard(double deltaSeconds)
{
    if (!is_using_keyboard())
    {
        // Whatever the keys were doing is forgotten the moment a transmitter
        // arrives. A stale keyboard throttle surviving a hot-plug would be a
        // motor running on a command nobody has given.
        KeyThrottle = 0.0;
        KeyElevator = 0.0;
        KeyAileron  = 0.0;
        KeyRudder   = 0.0;
        return;
    }

    Input* input = Input::get_singleton();
    if (input == nullptr) { return; }

    const double dt = deltaSeconds > 0.0 ? std::min(deltaSeconds, 0.1) : 0.0;

    // Rates chosen so a full deflection takes about a third of a second and a
    // release recentres in about a fifth. Slower than a stick, which is the
    // honest result: the keyboard has no proportional control, and ramping is
    // the only thing standing between the player and a bang-bang input.
    const double throw_rate  = 3.0 * dt;
    const double centre_rate = 5.0 * dt;

    auto axis = [&](Key positive, Key negative, double& value)
    {
        const bool up   = input->is_key_pressed(positive);
        const bool down = input->is_key_pressed(negative);
        if (up == down)
        {
            if (value > 0.0)      { value = std::max(0.0, value - centre_rate); }
            else if (value < 0.0) { value = std::min(0.0, value + centre_rate); }
        }
        else if (up)   { value = std::min(1.0, value + throw_rate); }
        else           { value = std::max(-1.0, value - throw_rate); }
    };

    // Right stick: elevator and ailerons on the arrow keys. UP pitches the
    // nose DOWN, as a transmitter's elevator stick does.
    axis(Key::KEY_DOWN, Key::KEY_UP, KeyElevator);
    axis(Key::KEY_RIGHT, Key::KEY_LEFT, KeyAileron);
    // Left stick: rudder on A/D. The throttle latches instead of centring.
    axis(Key::KEY_D, Key::KEY_A, KeyRudder);

    if (input->is_key_pressed(Key::KEY_W))
    {
        KeyThrottle = std::min(1.0, KeyThrottle + throw_rate * 0.5);
    }
    else if (input->is_key_pressed(Key::KEY_S))
    {
        KeyThrottle = std::max(0.0, KeyThrottle - throw_rate * 0.5);
    }

    CurrentChannels.Set(rc::RCChannel::Throttle, KeyThrottle);
    CurrentChannels.Set(rc::RCChannel::Elevator, KeyElevator);
    CurrentChannels.Set(rc::RCChannel::Aileron, KeyAileron);
    CurrentChannels.Set(rc::RCChannel::Rudder, KeyRudder);
}

void RCInputNode::PollDevice()
{
    // The kernel device first. It reports the real axis order, gives the full
    // current state the moment it is opened, and is not remapped by anything -
    // none of which is true of the path below. Open() is also the hot-plug
    // check: it rate-limits itself while no device is present.
    if (Device.Open())
    {
        rc::RawAxisState fresh;
        const bool reporting = Device.Poll(fresh);

        if (!reporting && Device.IsOpen())
        {
            // Open, but the kernel has not delivered its initial burst yet.
            // Falling through to Godot's layer here would hand on ITS zeros -
            // the exact failure this path exists to avoid, and one that reads
            // as a centred throttle rather than a closed one. There is no
            // transmitter state this frame, so say so.
            RawAxes.Connected = false;
            return;
        }

        if (reporting)
        {
            if (!UsingDirectDevice)
            {
                UsingDirectDevice = true;
                WarnedNoDevice    = false;
                ThrottleArming_.Reset();
                RC_LOG(Input, Info, "Transmitter: %s", Device.Name().c_str());
            }
            RawAxes = fresh;
            return;
        }
    }

    if (UsingDirectDevice)
    {
        // The device we were reading went away. Fall through to Godot's layer,
        // which will report no device unless a gamepad is attached.
        UsingDirectDevice = false;
        ActiveDeviceId    = -1;
        ThrottleArming_.Reset();
    }

    Input* input = Input::get_singleton();
    if (input == nullptr)
    {
        RawAxes.Connected = false;
        return;
    }

    const TypedArray<int32_t> pads = input->get_connected_joypads();

    int chosen = -1;
    if (RequestedDeviceId >= 0)
    {
        for (int i = 0; i < pads.size(); ++i)
        {
            if (static_cast<int>(pads[i]) == RequestedDeviceId) { chosen = RequestedDeviceId; break; }
        }
    }
    else if (pads.size() > 0)
    {
        chosen = static_cast<int>(pads[0]);
    }

    if (chosen < 0)
    {
        if (!WarnedNoDevice)
        {
            WarnedNoDevice = true;
            RC_LOG(Input, Warning,
                   "No transmitter or joystick detected. Sticks will read neutral "
                   "and the throttle stays closed.");
        }
        ActiveDeviceId    = -1;
        RawAxes.Connected = false;
        RawAxes.AxisCount = 0;
        return;
    }

    if (chosen != ActiveDeviceId)
    {
        ActiveDeviceId = chosen;
        WarnedNoDevice = false;
        ThrottleArming_.Reset();
        RC_LOG(Input, Info, "Controller detected: %s (device %d)",
               input->get_joy_name(chosen).utf8().get_data(), chosen);

        // Godot ships SDL gamepad mappings and applies one to any device whose
        // GUID it recognises - including RC transmitters in USB HID mode. That
        // mapping folds the device into the six-axis Xbox model, so a radio with
        // more than six channels silently loses the surplus, and the ones that
        // survive arrive renumbered and rescaled (triggers become 0..1).
        //
        // We never want gamepad semantics: the calibration wizard binds raw axes
        // by watching which one the pilot moves. Drop the mapping so every
        // physical axis reaches us unmodified.
        if (input->is_joy_known(chosen))
        {
            const String guid = input->get_joy_guid(chosen);
            input->remove_joy_mapping(guid);
            RC_LOG(Input, Info,
                   "Removed Godot's gamepad mapping for %s so all axes read raw.",
                   guid.utf8().get_data());
        }
    }

    RawAxes.Connected = true;
    RawAxes.AxisCount = 0;
    for (int axis = 0; axis < kMaxPolledAxes; ++axis)
    {
        const double value = input->get_joy_axis(chosen, static_cast<JoyAxis>(axis));
        RawAxes.Axes[RawAxes.AxisCount++] = value;
    }
}

bool RCInputNode::IsValidChannel(int channel)
{
    return channel >= 0 && channel < static_cast<int>(rc::kChannelCount);
}

// -------------------------------------------------------------- the device --

bool RCInputNode::is_connected() const { return RawAxes.Connected; }

String RCInputNode::get_device_name() const
{
    // The kernel device knows its own name; Godot's device id means nothing
    // while we are reading it directly.
    if (UsingDirectDevice) { return String(Device.Name().c_str()); }
    if (ActiveDeviceId < 0) { return String("<none>"); }
    Input* input = Input::get_singleton();
    return (input != nullptr) ? input->get_joy_name(ActiveDeviceId) : String("<none>");
}

int RCInputNode::get_device_id() const { return ActiveDeviceId; }

bool RCInputNode::is_throttle_armed() const { return ThrottleArming_.IsArmed(); }

String RCInputNode::get_profile_problem() const
{
    return String(rc::DescribeProfileMismatch(Mapper_, RawAxes).c_str());
}

String RCInputNode::resolve_data_path(const String& relative) const
{
    return openrc::ResolveDataPath(relative);
}
int RCInputNode::get_axis_count() const { return static_cast<int>(RawAxes.AxisCount); }

double RCInputNode::get_raw_axis(int axisIndex) const
{
    return RawAxes.GetAxis(axisIndex);
}

PackedFloat64Array RCInputNode::get_raw_axes() const
{
    PackedFloat64Array out;
    out.resize(static_cast<int64_t>(RawAxes.AxisCount));
    for (size_t i = 0; i < RawAxes.AxisCount; ++i)
    {
        out[static_cast<int64_t>(i)] = RawAxes.Axes[i];
    }
    return out;
}

void RCInputNode::set_device_id(int deviceId) { RequestedDeviceId = deviceId; }

// ------------------------------------------------------------ the channels --

double RCInputNode::get_channel(int channel) const
{
    if (!IsValidChannel(channel)) { return 0.0; }
    return CurrentChannels.Get(static_cast<rc::RCChannel>(channel));
}

PackedFloat64Array RCInputNode::get_channels() const
{
    PackedFloat64Array out;
    out.resize(static_cast<int64_t>(rc::kChannelCount));
    for (size_t i = 0; i < rc::kChannelCount; ++i)
    {
        out[static_cast<int64_t>(i)] = CurrentChannels.Values[i];
    }
    return out;
}

String RCInputNode::get_channel_name(int channel) const
{
    if (!IsValidChannel(channel)) { return String("???"); }
    return String(rc::ToString(static_cast<rc::RCChannel>(channel)));
}

int RCInputNode::get_channel_count() const { return static_cast<int>(rc::kChannelCount); }
bool RCInputNode::is_fully_bound() const { return Mapper_.IsFullyBound(); }

// ------------------------------------------------------ calibration wizard --

void RCInputNode::reset_capture()
{
    for (auto& capture : Captures) { capture.Reset(); }
}

void RCInputNode::reset_travel()
{
    for (auto& capture : Captures) { capture.ResetTravel(); }
}

void RCInputNode::begin_capture(bool centre)
{
    CapturingCentre = centre;
    Capturing       = true;
}

double RCInputNode::get_axis_travel(int axisIndex) const
{
    if (axisIndex < 0 || static_cast<size_t>(axisIndex) >= rc::RawAxisState::kMaxAxes)
    {
        return 0.0;
    }
    return Captures[static_cast<size_t>(axisIndex)].ObservedRange();
}

void RCInputNode::end_capture() { Capturing = false; }
bool RCInputNode::is_capturing() const { return Capturing; }

int RCInputNode::identify_moved_axis() const
{
    return rc::FindMostMovedAxis(Captures, RawAxes.AxisCount);
}

bool RCInputNode::bind_channel(int channel, int axisIndex)
{
    if (!IsValidChannel(channel) || axisIndex < 0 ||
        static_cast<size_t>(axisIndex) >= rc::RawAxisState::kMaxAxes)
    {
        return false;
    }

    const rc::AxisCalibration calibration = Captures[axisIndex].Result();
    if (!calibration.IsValid())
    {
        RC_LOG(Input, Warning,
               "Axis %d has not been swept far enough to calibrate %s.",
               axisIndex, rc::ToString(static_cast<rc::RCChannel>(channel)));
        return false;
    }

    Mapper_.Bind(static_cast<rc::RCChannel>(channel), axisIndex, calibration);
    RC_LOG(Input, Info, "%s bound to axis %d (min %.3f centre %.3f max %.3f)",
           rc::ToString(static_cast<rc::RCChannel>(channel)), axisIndex,
           calibration.RawMin, calibration.RawCenter, calibration.RawMax);
    return true;
}

void RCInputNode::unbind_channel(int channel)
{
    if (IsValidChannel(channel))
    {
        Mapper_.Unbind(static_cast<rc::RCChannel>(channel));
    }
}

void RCInputNode::set_channel_reversed(int channel, bool reversed)
{
    if (IsValidChannel(channel))
    {
        Mapper_.Binding(static_cast<rc::RCChannel>(channel)).Calibration.Reversed = reversed;
    }
}

bool RCInputNode::get_channel_reversed(int channel) const
{
    if (!IsValidChannel(channel)) { return false; }
    return Mapper_.Binding(static_cast<rc::RCChannel>(channel)).Calibration.Reversed;
}

void RCInputNode::set_channel_expo(int channel, double expo)
{
    if (IsValidChannel(channel))
    {
        Mapper_.Binding(static_cast<rc::RCChannel>(channel)).Shaping.Expo = expo;
    }
}

void RCInputNode::set_channel_dual_rate(int channel, double dualRate)
{
    if (IsValidChannel(channel))
    {
        Mapper_.Binding(static_cast<rc::RCChannel>(channel)).Shaping.DualRate = dualRate;
    }
}

void RCInputNode::set_channel_trim(int channel, double trim)
{
    if (IsValidChannel(channel))
    {
        Mapper_.Binding(static_cast<rc::RCChannel>(channel)).Shaping.Trim = trim;
    }
}

void RCInputNode::set_raw_mode(bool rawMode) { Mapper_.SetRawMode(rawMode); }
bool RCInputNode::get_raw_mode() const { return Mapper_.IsRawMode(); }

// ----------------------------------------------------------------- profile --

bool RCInputNode::save_profile(const String& path) const
{
    Ref<FileAccess> file = FileAccess::open(path, FileAccess::WRITE);
    if (file.is_null())
    {
        RC_LOG(Input, Error, "Cannot write controller profile to '%s'.",
               path.utf8().get_data());
        return false;
    }
    file->store_string(String(Mapper_.ToJson().c_str()));
    file->close();
    RC_LOG(Input, Info, "Controller profile saved to '%s'.", path.utf8().get_data());
    return true;
}

bool RCInputNode::load_profile(const String& path)
{
    if (!FileAccess::file_exists(path))
    {
        return false;
    }
    Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
    if (file.is_null())
    {
        return false;
    }
    const String text = file->get_as_text();
    file->close();

    std::string error;
    // A new profile recalibrates the throttle, so the reading that armed the
    // interlock no longer means what it did.
    ThrottleArming_.Reset();

    if (!Mapper_.FromJson(std::string(text.utf8().get_data()), &error))
    {
        RC_LOG(Input, Error, "Controller profile '%s' is malformed: %s",
               path.utf8().get_data(), error.c_str());
        return false;
    }
    RC_LOG(Input, Info, "Controller profile loaded from '%s'.", path.utf8().get_data());
    return true;
}

// ---------------------------------------------------------------- bindings --

void RCInputNode::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("is_connected"), &RCInputNode::is_connected);
    ClassDB::bind_method(D_METHOD("is_using_keyboard"), &RCInputNode::is_using_keyboard);
    ClassDB::bind_method(D_METHOD("is_throttle_armed"), &RCInputNode::is_throttle_armed);
    ClassDB::bind_method(D_METHOD("get_profile_problem"), &RCInputNode::get_profile_problem);
    ClassDB::bind_method(D_METHOD("resolve_data_path", "relative"), &RCInputNode::resolve_data_path);
    ClassDB::bind_method(D_METHOD("get_device_name"), &RCInputNode::get_device_name);
    ClassDB::bind_method(D_METHOD("get_device_id"), &RCInputNode::get_device_id);
    ClassDB::bind_method(D_METHOD("get_axis_count"), &RCInputNode::get_axis_count);
    ClassDB::bind_method(D_METHOD("get_raw_axis", "axis_index"), &RCInputNode::get_raw_axis);
    ClassDB::bind_method(D_METHOD("get_raw_axes"), &RCInputNode::get_raw_axes);
    ClassDB::bind_method(D_METHOD("set_device_id", "device_id"), &RCInputNode::set_device_id);

    ClassDB::bind_method(D_METHOD("get_channel", "channel"), &RCInputNode::get_channel);
    ClassDB::bind_method(D_METHOD("get_channels"), &RCInputNode::get_channels);
    ClassDB::bind_method(D_METHOD("get_channel_name", "channel"), &RCInputNode::get_channel_name);
    ClassDB::bind_method(D_METHOD("get_channel_count"), &RCInputNode::get_channel_count);
    ClassDB::bind_method(D_METHOD("is_fully_bound"), &RCInputNode::is_fully_bound);

    ClassDB::bind_method(D_METHOD("reset_capture"), &RCInputNode::reset_capture);
    ClassDB::bind_method(D_METHOD("reset_travel"), &RCInputNode::reset_travel);
    ClassDB::bind_method(D_METHOD("get_axis_travel", "axis_index"), &RCInputNode::get_axis_travel);
    ClassDB::bind_method(D_METHOD("begin_capture", "centre"), &RCInputNode::begin_capture);
    ClassDB::bind_method(D_METHOD("end_capture"), &RCInputNode::end_capture);
    ClassDB::bind_method(D_METHOD("is_capturing"), &RCInputNode::is_capturing);
    ClassDB::bind_method(D_METHOD("identify_moved_axis"), &RCInputNode::identify_moved_axis);
    ClassDB::bind_method(D_METHOD("bind_channel", "channel", "axis_index"), &RCInputNode::bind_channel);
    ClassDB::bind_method(D_METHOD("unbind_channel", "channel"), &RCInputNode::unbind_channel);

    ClassDB::bind_method(D_METHOD("set_channel_reversed", "channel", "reversed"), &RCInputNode::set_channel_reversed);
    ClassDB::bind_method(D_METHOD("get_channel_reversed", "channel"), &RCInputNode::get_channel_reversed);
    ClassDB::bind_method(D_METHOD("set_channel_expo", "channel", "expo"), &RCInputNode::set_channel_expo);
    ClassDB::bind_method(D_METHOD("set_channel_dual_rate", "channel", "dual_rate"), &RCInputNode::set_channel_dual_rate);
    ClassDB::bind_method(D_METHOD("set_channel_trim", "channel", "trim"), &RCInputNode::set_channel_trim);

    ClassDB::bind_method(D_METHOD("set_raw_mode", "raw_mode"), &RCInputNode::set_raw_mode);
    ClassDB::bind_method(D_METHOD("get_raw_mode"), &RCInputNode::get_raw_mode);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "raw_mode"), "set_raw_mode", "get_raw_mode");

    ClassDB::bind_method(D_METHOD("save_profile", "path"), &RCInputNode::save_profile);
    ClassDB::bind_method(D_METHOD("load_profile", "path"), &RCInputNode::load_profile);

    BIND_ENUM_CONSTANT(CHANNEL_AILERON);
    BIND_ENUM_CONSTANT(CHANNEL_ELEVATOR);
    BIND_ENUM_CONSTANT(CHANNEL_THROTTLE);
    BIND_ENUM_CONSTANT(CHANNEL_RUDDER);
    BIND_ENUM_CONSTANT(CHANNEL_FLAP);
    BIND_ENUM_CONSTANT(CHANNEL_AUX1);
    BIND_ENUM_CONSTANT(CHANNEL_COUNT);
}

} // namespace openrc
