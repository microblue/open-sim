// OpenRC Simulator - force and moment accumulation.
//
// Every contributor (wing section, propeller, wheel, gust) pushes into one of
// these. Nothing writes to the rigid body directly; the accumulator is the only
// path from "a thing that makes a force" to "the integrator". That is what lets
// the whole force model be re-evaluated as a pure function for RK4 and for the
// offline validation tests.
//
// The accumulator also keeps a per-source breakdown so the debug HUD and the
// physics tuning panel can show where each newton came from.
#pragma once

#include "RCPhysics/Physics/Dynamics/RigidBodyState.h"

#include <array>

namespace rc
{
/** Coarse buckets for debug attribution. Cheap enough to always keep on. */
enum class ForceSource
{
    Aerodynamic = 0,
    Propulsion,
    Ground,
    Gravity,
    Other,
    Count
};

class ForceAccumulator
{
public:
    void Reset()
    {
        Total = Wrench{};
        for (auto& bucket : PerSource) { bucket = Wrench{}; }
    }

    /** Force applied at the CG - contributes no moment. */
    void AddForceAtCG(const Vec3& forceBody, ForceSource source = ForceSource::Other)
    {
        Wrench w;
        w.Force = forceBody;
        Add(w, source);
    }

    /** Force applied at `offsetFromCGBody` (body axes, metres from the CG).
     *  This is the workhorse: it is how a wing section's lift both accelerates
     *  the aircraft and pitches/rolls it. */
    void AddForceAtOffset(const Vec3& forceBody,
                          const Vec3& offsetFromCGBody,
                          ForceSource source = ForceSource::Other)
    {
        Wrench w;
        w.Force  = forceBody;
        w.Moment = Cross(offsetFromCGBody, forceBody);
        Add(w, source);
    }

    /** Pure couple - propeller reaction torque, aerodynamic pitching moment
     *  of a section about its own quarter chord, wheel steering torque. */
    void AddMoment(const Vec3& momentBody, ForceSource source = ForceSource::Other)
    {
        Wrench w;
        w.Moment = momentBody;
        Add(w, source);
    }

    void Add(const Wrench& wrench, ForceSource source = ForceSource::Other)
    {
        Total += wrench;
        PerSource[static_cast<size_t>(source)] += wrench;
    }

    const Wrench& GetTotal() const { return Total; }

    const Wrench& GetBySource(ForceSource source) const
    {
        return PerSource[static_cast<size_t>(source)];
    }

private:
    Wrench Total;
    std::array<Wrench, static_cast<size_t>(ForceSource::Count)> PerSource{};
};

} // namespace rc
