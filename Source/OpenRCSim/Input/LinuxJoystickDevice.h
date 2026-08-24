// OpenRC Simulator - reading the transmitter straight from the kernel.
//
// Godot's joystick layer sits between us and the device, and on this project it
// has cost three separate defects:
//
//   1. It applies an SDL gamepad mapping to any device whose GUID it knows,
//      including RC transmitters. That mapping folds the device into the
//      six-axis Xbox model, so a radio with more channels loses the surplus and
//      the survivors arrive renumbered and rescaled.
//   2. It only refreshes an axis when the value changes, so an axis nobody has
//      touched since the device was opened reads zero - and zero is the MIDDLE
//      of a throttle's travel, not the bottom of it.
//   3. Its axis numbering is its own, and reconciling it with the device's real
//      axis order turned out not to be something we could establish from the
//      outside.
//
// The kernel's joystick interface has none of those problems. Opening the
// device replays a synthetic event for every axis, so the full current state is
// known immediately and correctly; the axis order is the device's own; and
// nothing is remapped. It is also one less layer between the stick and the
// flight model, which matters given where input latency sits in this project's
// priorities.
//
// Linux only, by construction. Everywhere else RCInputNode falls back to
// Godot's Input singleton, which is correct for a gamepad even where it is
// wrong for a radio.

#ifndef OPENRCSIM_INPUT_LINUXJOYSTICKDEVICE_H
#define OPENRCSIM_INPUT_LINUXJOYSTICKDEVICE_H

#include "RCPhysics/Input/ChannelTypes.h"

#include <cstddef>
#include <string>

namespace openrc
{
    class LinuxJoystickDevice
    {
    public:
        LinuxJoystickDevice() = default;
        ~LinuxJoystickDevice();

        LinuxJoystickDevice(const LinuxJoystickDevice&)            = delete;
        LinuxJoystickDevice& operator=(const LinuxJoystickDevice&) = delete;

        /** Find and open the first joystick. Cheap to call repeatedly - it does
         *  nothing while already open, and rate-limits its retries otherwise,
         *  so it doubles as the hot-plug check. */
        bool Open();

        void Close();

        bool IsOpen() const { return Descriptor >= 0; }

        /** Drain everything the kernel has queued and update `out`. Returns
         *  false if the device went away, having closed it. */
        bool Poll(rc::RawAxisState& out);

        const std::string& Name() const { return DeviceName; }

        /** Seconds between attempts to find a device once one is missing. */
        static constexpr double kRetryInterval = 1.0;

    private:
        int         Descriptor = -1;
        std::string DeviceName;
        size_t      AxisCount = 0;
        double      NextRetryAt = 0.0;

        /** Latest value per axis, kept across polls: the kernel sends changes,
         *  not a full state, after the initial burst. */
        rc::RawAxisState Axes;
    };
}

#endif
