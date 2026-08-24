#include "LinuxJoystickDevice.h"

#include "RCPhysics/Core/Log.h"

#if defined(__linux__)

#include <linux/joystick.h>

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

namespace
{
    /** Monotonic seconds. Only used to rate-limit the search for a device. */
    double Now()
    {
        using namespace std::chrono;
        const auto since = steady_clock::now().time_since_epoch();
        return duration_cast<duration<double>>(since).count();
    }

    // The joystick ioctl request numbers come from kernel macros full of
    // C-style casts, which this project otherwise compiles as errors.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wold-style-cast"
#pragma GCC diagnostic ignored "-Wsign-conversion"
#pragma GCC diagnostic ignored "-Wconversion"
    int QueryName(int fd, char* buffer, size_t size)
    {
        return ioctl(fd, JSIOCGNAME(size), buffer);
    }

    int QueryAxisCount(int fd, unsigned char* count)
    {
        return ioctl(fd, JSIOCGAXES, count);
    }
#pragma GCC diagnostic pop
}

namespace openrc
{
    LinuxJoystickDevice::~LinuxJoystickDevice() { Close(); }

    bool LinuxJoystickDevice::Open()
    {
        if (IsOpen()) { return true; }

        const double now = Now();
        if (now < NextRetryAt) { return false; }
        NextRetryAt = now + kRetryInterval;

        for (int index = 0; index < 8; ++index)
        {
            char path[32];
            std::snprintf(path, sizeof(path), "/dev/input/js%d", index);

            // Non-blocking: this is polled from the frame loop and must never
            // wait on a stick that is not moving.
            const int fd = ::open(path, O_RDONLY | O_NONBLOCK);
            if (fd < 0) { continue; }

            char name[128] = {0};
            if (QueryName(fd, name, sizeof(name) - 1) < 0)
            {
                std::snprintf(name, sizeof(name), "joystick %d", index);
            }

            unsigned char axes = 0;
            QueryAxisCount(fd, &axes);

            Descriptor = fd;
            DeviceName = name;
            AxisCount  = static_cast<size_t>(axes);
            Axes       = rc::RawAxisState{};
            Axes.AxisCount = AxisCount;
            SeenAxes   = 0;

            RC_LOG(Input, Info, "Opened %s: %s, %zu axes (kernel joystick interface).",
                   path, DeviceName.c_str(), AxisCount);
            return true;
        }

        return false;
    }

    void LinuxJoystickDevice::Close()
    {
        if (Descriptor >= 0)
        {
            ::close(Descriptor);
            Descriptor = -1;
        }
        DeviceName.clear();
        AxisCount = 0;
        Axes = rc::RawAxisState{};
        SeenAxes = 0;
    }

    bool LinuxJoystickDevice::HasFullState() const
    {
        if (AxisCount == 0) { return false; }
        const unsigned int wanted = (AxisCount >= 32)
                                  ? 0xFFFFFFFFu
                                  : ((1u << AxisCount) - 1u);
        return (SeenAxes & wanted) == wanted;
    }

    bool LinuxJoystickDevice::Poll(rc::RawAxisState& out)
    {
        if (!IsOpen()) { return false; }

        // Opening the device queues a synthetic JS_EVENT_INIT for every axis and
        // button, so the very first poll after Open() already carries the full
        // current state - which is what makes a resting throttle read as closed
        // rather than as the middle of its travel.
        js_event event;
        while (true)
        {
            const ssize_t got = ::read(Descriptor, &event, sizeof(event));
            if (got == static_cast<ssize_t>(sizeof(event)))
            {
                if ((event.type & JS_EVENT_AXIS) != 0)
                {
                    const size_t axis = static_cast<size_t>(event.number);
                    if (axis < rc::RawAxisState::kMaxAxes)
                    {
                        Axes.Axes[axis] = static_cast<rc::Real>(event.value) / 32767.0;
                        if (axis + 1 > Axes.AxisCount) { Axes.AxisCount = axis + 1; }
                        SeenAxes |= (1u << axis);
                    }
                }
                continue;
            }

            if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            {
                break;   // nothing more queued
            }

            // Anything else means the device went away - unplugged, or the
            // radio left USB joystick mode.
            RC_LOG(Input, Warning, "Transmitter disconnected (%s).",
                   DeviceName.empty() ? "unknown" : DeviceName.c_str());
            Close();
            return false;
        }

        if (!HasFullState())
        {
            // Opened, but the kernel has not finished its initial burst. The
            // axes not yet heard from would read as zero, which for a throttle
            // is half travel rather than closed - indistinguishable from a real
            // reading, and exactly how the Godot path went wrong.
            return false;
        }

        Axes.Connected = true;
        out = Axes;
        return true;
    }
}

#else   // not Linux

namespace openrc
{
    LinuxJoystickDevice::~LinuxJoystickDevice() = default;
    bool LinuxJoystickDevice::Open() { return false; }
    void LinuxJoystickDevice::Close() {}
    bool LinuxJoystickDevice::Poll(rc::RawAxisState&) { return false; }
}

#endif
