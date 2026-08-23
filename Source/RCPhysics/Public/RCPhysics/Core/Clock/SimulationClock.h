// OpenRC Simulator - fixed timestep clock.
//
// The flight model must NEVER see a variable dt. Render framerate swings
// between 60 and 200 FPS on the same machine; if that reached the integrator,
// the aircraft would handle differently on every scene. So the renderer feeds
// wall-clock time in, and the clock hands out identical fixed steps.
//
//     clock.AddFrameTime(renderDeltaSeconds);
//     while (clock.ConsumeStep())
//     {
//         Simulate(clock.FixedDeltaSeconds());
//     }
//     const rc::Real alpha = clock.InterpolationAlpha();  // for render lerp
//
// Default rate is 240 Hz (Docs/PHYSICS_DESIGN.md); 120 / 480 Hz are supported
// by SetRateHz() and change nothing else in the pipeline.
#pragma once

#include "RCPhysics/Core/Types.h"

namespace rc
{
class SimulationClock
{
public:
    static constexpr Real kDefaultRateHz = 240.0;

    /** Longest single render frame we will honour. A frame longer than this
     *  (alt-tab, breakpoint, level load) has its excess discarded rather than
     *  triggering a burst of catch-up steps. */
    static constexpr Real kMaxFrameTimeSeconds = 0.25;

    SimulationClock() = default;
    explicit SimulationClock(Real rateHz) { SetRateHz(rateHz); }

    /** Change the physics rate. Ignored for non-positive values. Any partially
     *  accumulated time is kept, so switching rates mid-flight is smooth. */
    void SetRateHz(Real rateHz)
    {
        if (rateHz > 0.0)
        {
            FixedDelta = 1.0 / rateHz;
        }
    }

    Real RateHz() const { return 1.0 / FixedDelta; }
    Real FixedDeltaSeconds() const { return FixedDelta; }

    /** Upper bound on physics steps executed per render frame. Prevents the
     *  "spiral of death" where slow steps cause more steps. */
    void SetMaxStepsPerFrame(int maxSteps)
    {
        MaxStepsPerFrame = (maxSteps > 0) ? maxSteps : 1;
    }
    int GetMaxStepsPerFrame() const { return MaxStepsPerFrame; }

    /** Feed one render frame's elapsed wall-clock time. */
    void AddFrameTime(Real renderDeltaSeconds)
    {
        if (!IsFinite(renderDeltaSeconds) || renderDeltaSeconds <= 0.0)
        {
            return;
        }

        Real clamped = renderDeltaSeconds;
        if (clamped > kMaxFrameTimeSeconds)
        {
            DiscardedSeconds += clamped - kMaxFrameTimeSeconds;
            clamped = kMaxFrameTimeSeconds;
        }

        Accumulator += clamped;
        StepsRemainingThisFrame = MaxStepsPerFrame;
    }

    /** Take one fixed step if one is due. Returns false when the frame's
     *  budget is exhausted or not enough time has accumulated. */
    bool ConsumeStep()
    {
        if (Accumulator < FixedDelta)
        {
            return false;
        }
        if (StepsRemainingThisFrame <= 0)
        {
            // Budget blown: drop the backlog instead of falling further behind.
            const Real dropped = Accumulator - FixedDelta;
            if (dropped > 0.0)
            {
                DiscardedSeconds += dropped;
                DroppedStepCount += static_cast<std::uint64_t>(dropped / FixedDelta);
                Accumulator = std::fmod(Accumulator, FixedDelta);
            }
            return false;
        }

        Accumulator -= FixedDelta;
        --StepsRemainingThisFrame;
        ++StepCount;
        SimulatedSeconds += FixedDelta;
        return true;
    }

    /** 0..1 fraction of a step already elapsed. Use it to interpolate the
     *  rendered transform between the previous and current physics state so
     *  the aircraft looks smooth at any framerate. */
    Real InterpolationAlpha() const
    {
        return Clamp(Accumulator / FixedDelta, 0.0, 1.0);
    }

    /** Total simulated time since Reset(), in seconds. Monotonic, independent
     *  of wall clock - this is the time physics should timestamp with. */
    Real SimulatedTimeSeconds() const { return SimulatedSeconds; }

    /** Number of fixed steps executed since Reset(). */
    std::uint64_t TotalStepCount() const { return StepCount; }

    /** Steps skipped because a frame exceeded its budget. Non-zero here means
     *  the machine cannot sustain the configured rate - surface it on the HUD. */
    std::uint64_t DroppedSteps() const { return DroppedStepCount; }

    /** Wall-clock seconds thrown away (long frames + dropped backlog). */
    Real DiscardedTimeSeconds() const { return DiscardedSeconds; }

    void Reset()
    {
        Accumulator             = 0.0;
        SimulatedSeconds        = 0.0;
        DiscardedSeconds        = 0.0;
        StepCount               = 0;
        DroppedStepCount        = 0;
        StepsRemainingThisFrame = 0;
    }

private:
    Real FixedDelta              = 1.0 / kDefaultRateHz;
    Real Accumulator             = 0.0;
    Real SimulatedSeconds        = 0.0;
    Real DiscardedSeconds        = 0.0;
    std::uint64_t StepCount      = 0;
    std::uint64_t DroppedStepCount = 0;
    int MaxStepsPerFrame         = 12;
    int StepsRemainingThisFrame  = 0;
};

} // namespace rc
