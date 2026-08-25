// OpenRC Simulator - recording a flight so it can be watched again.
//
// The most useful thing a simulator can give a learner is the chance to see
// what they just did from outside. A pilot who has just cartwheeled a model on
// landing has no idea why; the same landing watched from the wingtip, slowly,
// answers it in one pass.
//
// So this runs continuously. There is no "start recording" - by the time you
// know you want the last thirty seconds, they have happened. It keeps a rolling
// window in a ring buffer and hands back frames at any point in it.
//
// What is stored is the STATE, not the inputs. Replaying inputs would need the
// whole simulation to be deterministic to the last bit across a reload, which
// it is not obliged to be; storing where the aircraft was and what it was doing
// is smaller, exact, and can be scrubbed to any point without replaying from
// the beginning. It also means a replay can be watched from a camera the
// original flight never used.
//
// Sampled at a fixed rate well below the physics rate. Sixty a second is far
// more than the eye needs and a twentieth of what 240 Hz would cost.

#ifndef RCPHYSICS_CORE_FLIGHTRECORDER_H
#define RCPHYSICS_CORE_FLIGHTRECORDER_H

#include "RCPhysics/Core/Math/Quat.h"
#include "RCPhysics/Core/Math/Vec3.h"
#include "RCPhysics/Core/Types.h"
#include "RCPhysics/Input/ChannelTypes.h"

#include <cstddef>
#include <vector>

namespace rc
{
    /** One instant of a flight. Everything a viewer needs to redraw the scene
     *  and everything the telemetry overlay reads, and nothing else. */
    struct FlightFrame
    {
        Real Time = 0.0;              ///< simulation seconds

        Vec3 PositionWorld = Vec3::Zero();
        Quat Orientation = Quat::Identity();
        Vec3 VelocityWorld = Vec3::Zero();
        Vec3 AngularVelocityBody = Vec3::Zero();

        // Telemetry, so a replay can show what the aircraft was doing as well
        // as where it was - which is most of the value in watching one.
        Real Airspeed = 0.0;
        Real Alpha = 0.0;             ///< rad
        Real StalledFraction = 0.0;
        Real Rpm = 0.0;
        Real Thrust = 0.0;
        Real BatteryCharge = 1.0;
        Real VerticalAirSpeed = 0.0;  ///< what the variometer showed

        ChannelValues Controls;
        bool OnGround = false;
        bool Crashed = false;
    };

    class FlightRecorder
    {
    public:
        /** Seconds of flight kept. Beyond this the oldest frames are dropped. */
        static constexpr Real kDefaultWindow = 120.0;

        /** Frames per second stored. */
        static constexpr Real kDefaultRate = 60.0;

        explicit FlightRecorder(Real windowSeconds = kDefaultWindow,
                                Real rateHz = kDefaultRate);

        /** Offer a frame. Ignored unless enough time has passed since the last
         *  one, so the caller can hand one over every physics step without
         *  thinking about it. */
        void Offer(const FlightFrame& frame);

        /** Throw away everything. Called on reset: a replay that runs across a
         *  reset shows the aircraft teleporting, which teaches nothing. */
        void Clear();

        bool Empty() const { return Count == 0; }
        std::size_t Size() const { return Count; }

        /** Simulation time of the oldest and newest frames kept. */
        Real EarliestTime() const;
        Real LatestTime() const;
        Real Duration() const { return Empty() ? Real(0) : LatestTime() - EarliestTime(); }

        /** The state at a moment, interpolated between stored frames.
         *
         *  Interpolated rather than nearest: at sixty a second a scrub bar
         *  moving slowly would otherwise step visibly, and the whole point of
         *  watching a landing again is to watch it slowly. */
        FlightFrame SampleAt(Real time) const;

        /** Frame by index, oldest first. For writing a file, or drawing the
         *  path the aircraft took. */
        const FlightFrame& At(std::size_t index) const;

        void SetWindow(Real seconds);
        Real Window() const { return WindowSeconds; }

    private:
        std::vector<FlightFrame> Ring;
        std::size_t Head = 0;         ///< where the next frame goes
        std::size_t Count = 0;
        Real WindowSeconds = kDefaultWindow;
        Real Interval = Real(1) / kDefaultRate;
        Real NextSampleTime = -1e30;

        std::size_t IndexOf(std::size_t age) const;
    };
}

#endif
