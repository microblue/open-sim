// OpenRC Simulator - reads a real RC transmitter over USB.
//
// Godot exposes every HID joystick through the same API, which is exactly the
// abstraction this project wants: a RadioMaster TX16S, a FlySky through a
// dongle and a plain gamepad all arrive as "a device with N axes", and the
// calibration wizard works out which axis is which.
//
// This node does no shaping of its own. It polls raw axes and hands them to
// rc::ChannelMapper, which owns calibration, deadzone, reverse, expo, dual rate
// and trim - all of it tested without a device attached.
#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <godot_cpp/core/binder_common.hpp>

#include "RCPhysics/Input/ChannelMapper.h"
#include "RCPhysics/Input/ProfileCheck.h"
#include "RCPhysics/Input/ThrottleArming.h"

#include "LinuxJoystickDevice.h"

namespace openrc
{
class RCInputNode : public godot::Node
{
    GDCLASS(RCInputNode, godot::Node)

public:
    /** Channel indices, exposed to GDScript as RCInputNode.CHANNEL_AILERON etc.
     *  Must stay in step with rc::RCChannel. */
    enum Channel
    {
        CHANNEL_AILERON  = 0,
        CHANNEL_ELEVATOR = 1,
        CHANNEL_THROTTLE = 2,
        CHANNEL_RUDDER   = 3,
        CHANNEL_FLAP     = 4,
        CHANNEL_AUX1     = 5,
        CHANNEL_COUNT    = 6
    };

    RCInputNode() = default;
    ~RCInputNode() override = default;

    void _ready() override;
    void _process(double deltaSeconds) override;

    // ---------------------------------------------------------- the device --

    bool           is_connected() const;
    godot::String  get_device_name() const;
    int            get_device_id() const;
    int            get_axis_count() const;
    double         get_raw_axis(int axisIndex) const;
    godot::PackedFloat64Array get_raw_axes() const;

    /** Pick a specific joypad, or -1 to use the first connected one. */
    void set_device_id(int deviceId);

    // -------------------------------------------------------- the channels --

    /** Processed stick positions. Bipolar channels are -1..1, throttle 0..1. */
    double get_channel(int channel) const;
    godot::PackedFloat64Array get_channels() const;
    godot::String get_channel_name(int channel) const;
    int get_channel_count() const;

    bool is_fully_bound() const;
    bool is_throttle_armed() const;

    /** Empty when the loaded binding is consistent with the transmitter that is
     *  actually attached; otherwise a sentence saying what is wrong. See
     *  RCPhysics/Input/ProfileCheck.h. */
    godot::String get_profile_problem() const;

    /** Locate a file under Data/. See Bridge/RCDataPaths.h. */
    godot::String resolve_data_path(const godot::String& relative) const;

    // ------------------------------------------------- calibration wizard ---

    /** Start collecting samples. `centre` selects whether the samples describe
     *  the resting position or the full sweep. */
    /** Throw away every sample on every axis. */
    void reset_capture();

    /** Throw away the swept travel but keep the captured centres, so the wizard
     *  can move on to the next stick. */
    void reset_travel();

    void begin_capture(bool centre);
    void end_capture();
    bool is_capturing() const;

    /** How far the given axis has moved since the travel was last reset. */
    double get_axis_travel(int axisIndex) const;

    /** Which axis has moved most since begin_capture(), or -1 when the answer
     *  is not yet unambiguous. This is what lets the wizard say "now move
     *  ELEVATOR" rather than asking for an axis number. */
    int identify_moved_axis() const;

    /** Bind a channel to an axis using the samples captured so far. */
    bool bind_channel(int channel, int axisIndex);
    void unbind_channel(int channel);

    void set_channel_reversed(int channel, bool reversed);
    bool get_channel_reversed(int channel) const;

    void set_channel_expo(int channel, double expo);
    void set_channel_dual_rate(int channel, double dualRate);
    void set_channel_trim(int channel, double trim);

    /** Bypass expo, dual rate and trim for pilots who use their transmitter's
     *  own curves. Calibration and reverse still apply. */
    void set_raw_mode(bool rawMode);
    bool get_raw_mode() const;

    // ------------------------------------------------------------ profile ---

    bool save_profile(const godot::String& path) const;
    bool load_profile(const godot::String& path);

    /** True when nothing is plugged in and the keyboard is flying the model.
     *
     *  A transmitter is the point of this simulator and there is no pretending
     *  a keyboard is one. But a player who downloads it before their radio
     *  arrives - or who wants to see what it looks like - had every control
     *  dead and an aeroplane that fell out of the sky, with the only offered
     *  action being a setup wizard that needs the device they have not got.
     *  The keys fly it badly, on purpose, and say so. */
    bool is_using_keyboard() const;

    /** Turns the keyboard fallback off while a menu owns the keyboard.
     *
     *  The fallback reads the keys directly through Input rather than through
     *  the event system, so nothing a screen does with an event can stop it:
     *  arrowing down a list of aeroplanes was also feeding full up-elevator to
     *  the model parked on the strip, and W - which opens the world screen -
     *  was opening the throttle at the same time. */
    void set_keyboard_enabled(bool enabled);
    bool is_keyboard_enabled() const;

    /** The mapper, for C++ callers such as RCSimulationNode. */
    const rc::ChannelValues& Channels() const { return CurrentChannels; }
    const rc::ChannelMapper& Mapper() const { return Mapper_; }

protected:
    static void _bind_methods();

private:
    void PollDevice();
    /** Mode 2 on the keyboard: arrows for the right stick, W/S and A/D for the
     *  left. The three spring-centred channels return to neutral when the key
     *  is let go; the throttle latches, as a throttle stick does. */
    void ApplyKeyboard(double deltaSeconds);
    static bool IsValidChannel(int channel);

    rc::ChannelMapper   Mapper_;
    rc::ThrottleArming  ThrottleArming_;

    /** Preferred path: the kernel device, read directly. Godot's Input layer is
     *  only used where this cannot open one. See LinuxJoystickDevice.h. */
    LinuxJoystickDevice Device;
    bool                UsingDirectDevice = false;
    rc::ChannelValues CurrentChannels;
    rc::RawAxisState  RawAxes;

    rc::CalibrationCapture Captures[rc::RawAxisState::kMaxAxes];
    bool CapturingCentre = false;
    bool Capturing       = false;

    int  RequestedDeviceId = -1;
    int  ActiveDeviceId    = -1;
    bool WarnedNoDevice    = false;

    /** Keyboard stick positions, held between frames so the surfaces move at a
     *  servo's rate rather than snapping between the rails. */
    double KeyThrottle = 0.0;
    double KeyElevator = 0.0;
    double KeyAileron  = 0.0;
    double KeyRudder   = 0.0;
    bool   KeyboardAllowed = true;
};

} // namespace openrc

VARIANT_ENUM_CAST(openrc::RCInputNode::Channel);
