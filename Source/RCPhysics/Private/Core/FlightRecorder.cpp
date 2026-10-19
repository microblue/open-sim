#include "RCPhysics/Core/FlightRecorder.h"

#include "RCPhysics/Core/Units/Units.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <cstdio>
#include <ostream>

namespace rc
{
    namespace
    {
        // Vec3 already has a Lerp in rc; this is the scalar one, named apart
        // so the two cannot be confused at a call site.
        Real Blend(Real a, Real b, Real t) { return a + (b - a) * t; }
    }

    FlightRecorder::FlightRecorder(Real windowSeconds, Real rateHz)
    {
        Interval = Real(1) / std::max(rateHz, Real(1));
        SetWindow(windowSeconds);
    }

    void FlightRecorder::SetWindow(Real seconds)
    {
        WindowSeconds = std::max(seconds, Real(1));
        const auto capacity = static_cast<std::size_t>(WindowSeconds / Interval) + 2;
        Ring.assign(capacity, FlightFrame{});
        Head = 0;
        Count = 0;
        NextSampleTime = -1e30;
    }

    void FlightRecorder::Clear()
    {
        Head = 0;
        Count = 0;
        NextSampleTime = -1e30;
    }

    void FlightRecorder::Offer(const FlightFrame& frame)
    {
        if (Ring.empty()) { return; }

        // A reset moves the clock backwards. Keeping frames from before it
        // would show the aircraft teleporting mid-replay.
        if (frame.Time < NextSampleTime - Interval * Real(2) - Real(1))
        {
            Clear();
        }
        if (frame.Time < NextSampleTime) { return; }

        Ring[Head] = frame;
        Head = (Head + 1) % Ring.size();
        Count = std::min(Count + 1, Ring.size());

        // The next sample point comes from the SCHEDULE, not from when this
        // frame happened to arrive. A caller stepping at 240 Hz always lands a
        // little past the target, and adding the interval to that pushed the
        // schedule further out every time: the recorder asked for sixty a
        // second and stored fifty-six.
        NextSampleTime += Interval;
        // Unless it has fallen so far behind that catching up would store a
        // burst - after a hitch, or on the first frame.
        if (NextSampleTime < frame.Time)
        {
            NextSampleTime = frame.Time + Interval;
        }
    }

    std::size_t FlightRecorder::IndexOf(std::size_t age) const
    {
        // age 0 is the oldest frame kept.
        const std::size_t oldest = (Head + Ring.size() - Count) % Ring.size();
        return (oldest + age) % Ring.size();
    }

    const FlightFrame& FlightRecorder::At(std::size_t index) const
    {
        static const FlightFrame empty;
        if (index >= Count) { return empty; }
        return Ring[IndexOf(index)];
    }

    Real FlightRecorder::EarliestTime() const
    {
        return Empty() ? Real(0) : Ring[IndexOf(0)].Time;
    }

    Real FlightRecorder::LatestTime() const
    {
        return Empty() ? Real(0) : Ring[IndexOf(Count - 1)].Time;
    }

    FlightFrame FlightRecorder::SampleAt(Real time) const
    {
        if (Empty()) { return FlightFrame{}; }
        if (Count == 1) { return Ring[IndexOf(0)]; }

        const Real first = EarliestTime();
        const Real last = LatestTime();
        if (time <= first) { return Ring[IndexOf(0)]; }
        if (time >= last)  { return Ring[IndexOf(Count - 1)]; }

        // Binary search on time, not arithmetic on the interval.
        //
        // The first version computed the index from (time - first) / Interval,
        // on the assumption that stored frames are exactly one interval apart.
        // They are not: Offer accepts a frame whose time has merely REACHED the
        // next sample point, and a caller stepping at 240 Hz lands a little
        // past it every time. The drift is tiny per frame and enough to put the
        // index out by one after a few seconds - which showed up as a replay
        // reporting the crash flag from the wrong side of the impact.
        std::size_t low = 0;
        std::size_t high = Count - 1;
        while (high - low > 1)
        {
            const std::size_t middle = (low + high) / 2;
            if (Ring[IndexOf(middle)].Time <= time) { low = middle; }
            else { high = middle; }
        }
        const std::size_t lower = low;

        const Real span = Ring[IndexOf(lower + 1)].Time - Ring[IndexOf(lower)].Time;
        const Real t = (span > Real(1e-9))
                     ? std::min(std::max((time - Ring[IndexOf(lower)].Time) / span,
                                         Real(0)), Real(1))
                     : Real(0);

        const FlightFrame& a = Ring[IndexOf(lower)];
        const FlightFrame& b = Ring[IndexOf(lower + 1)];

        FlightFrame out = a;
        out.Time = Blend(a.Time, b.Time, t);
        out.PositionWorld = Lerp(a.PositionWorld, b.PositionWorld, t);
        // Slerp, not lerp: a linear blend of two quaternions is not a rotation,
        // and over a fast roll it visibly shrinks the aircraft's attitude
        // towards the halfway point.
        out.Orientation = Slerp(a.Orientation, b.Orientation, t).Normalized();
        out.VelocityWorld = Lerp(a.VelocityWorld, b.VelocityWorld, t);
        out.AngularVelocityBody = Lerp(a.AngularVelocityBody, b.AngularVelocityBody, t);

        out.Airspeed = Blend(a.Airspeed, b.Airspeed, t);
        out.Alpha = Blend(a.Alpha, b.Alpha, t);
        out.StalledFraction = Blend(a.StalledFraction, b.StalledFraction, t);
        out.Rpm = Blend(a.Rpm, b.Rpm, t);
        out.Thrust = Blend(a.Thrust, b.Thrust, t);
        out.BatteryCharge = Blend(a.BatteryCharge, b.BatteryCharge, t);
        out.VerticalAirSpeed = Blend(a.VerticalAirSpeed, b.VerticalAirSpeed, t);

        for (std::size_t i = 0; i < kChannelCount; ++i)
        {
            out.Controls.Values[i] = Blend(a.Controls.Values[i], b.Controls.Values[i], t);
        }

        // Flags take the nearer frame's value: a crash is a moment, not a
        // gradient, and blending it would make the aircraft half-crashed.
        const FlightFrame& nearer = (t < Real(0.5)) ? a : b;
        out.OnGround = nearer.OnGround;
        out.Crashed = nearer.Crashed;
        return out;
    }

    bool FlightRecorder::WriteCsv(std::ostream& out) const
    {
        out << "time_s,north_m,east_m,altitude_m,height_agl_m,"
               "roll_deg,pitch_deg,heading_deg,"
               "ground_speed_mps,airspeed_mps,vertical_speed_mps,"
               "roll_rate_dps,pitch_rate_dps,yaw_rate_dps,"
               "alpha_deg,stalled_fraction,rpm,thrust_n,battery,air_vertical_mps,"
               "aileron,elevator,throttle,rudder,flap,aux1,"
               "on_ground,crashed,failure\n";

        char line[512];
        for (std::size_t i = 0; i < Count; ++i)
        {
            const FlightFrame& f = At(i);
            const EulerAngles e = f.Orientation.ToEuler();
            Real heading = units::ToDegrees(e.yaw);
            if (heading < 0.0) { heading += 360.0; }
            const ChannelValues& c = f.Controls;
            std::snprintf(line, sizeof(line),
                "%.4f,%.3f,%.3f,%.3f,%.3f,"
                "%.2f,%.2f,%.2f,"
                "%.3f,%.3f,%.3f,"
                "%.2f,%.2f,%.2f,"
                "%.2f,%.3f,%.0f,%.3f,%.4f,%.3f,"
                "%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,"
                "%d,%d,%d\n",
                f.Time, f.PositionWorld.x, f.PositionWorld.y, -f.PositionWorld.z,
                f.HeightAboveGround,
                units::ToDegrees(e.roll), units::ToDegrees(e.pitch), heading,
                f.VelocityWorld.Length(), f.Airspeed, -f.VelocityWorld.z,
                units::ToDegrees(f.AngularVelocityBody.x),
                units::ToDegrees(f.AngularVelocityBody.y),
                units::ToDegrees(f.AngularVelocityBody.z),
                units::ToDegrees(f.Alpha), f.StalledFraction, f.Rpm, f.Thrust,
                f.BatteryCharge, f.VerticalAirSpeed,
                c.Get(RCChannel::Aileron), c.Get(RCChannel::Elevator),
                c.Get(RCChannel::Throttle), c.Get(RCChannel::Rudder),
                c.Get(RCChannel::Flap), c.Get(RCChannel::Aux1),
                f.OnGround ? 1 : 0, f.Crashed ? 1 : 0, f.Failure);
            out << line;
        }
        return static_cast<bool>(out);
    }

    bool FlightRecorder::WriteCsvFile(const std::string& path) const
    {
        std::ofstream file(path, std::ios::out | std::ios::trunc);
        if (!file) { return false; }
        return WriteCsv(file) && static_cast<bool>(file.flush());
    }
}
