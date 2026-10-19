#include "RCPhysics/Training/CrashAnalysis.h"

#include "RCPhysics/Aircraft/FailureModel.h"
#include "RCPhysics/Core/Units/Units.h"

#include <cmath>
#include <cstdarg>
#include <cstdio>

namespace rc
{
namespace
{
std::string Format(const char* pattern, ...)
{
    char buffer[320];
    va_list args;
    va_start(args, pattern);
    std::vsnprintf(buffer, sizeof(buffer), pattern, args);
    va_end(args);
    return std::string(buffer);
}

bool Contains(const std::string& text, const char* part)
{
    return text.find(part) != std::string::npos;
}

/** " at 4 m" when the height is known, nothing when it is not. Heights under
 *  a metre read as "just above the ground" because "at 0 m" sounds like the
 *  impact itself. */
std::string AtHeight(Real height)
{
    if (height < 0.0) { return std::string(); }
    if (height < 1.0) { return " just above the ground"; }
    return Format(" at %.0f m", height);
}

// Thresholds. Display and teaching values, chosen so that each sentence is
// the one an instructor standing next to the pilot would have said.
constexpr Real kStalledFraction   = 0.5;    // most of the wing has let go
constexpr Real kWingDropFraction  = 0.2;    // part of it has, enough to drop a wing
constexpr Real kSpinYawRate       = 90.0;   // deg/s while stalled
constexpr Real kTipStallRollRate  = 120.0;  // deg/s while partly stalled
constexpr Real kSteepBank         = 60.0;   // deg at impact
constexpr Real kSteepDive         = -45.0;  // deg flight path at impact
// A spiral does not need to be steep to kill: 45 deg of bank and a 30 deg
// descent is a spiral a pilot has stopped flying, not an approach.
constexpr Real kSpiralBank        = 30.0;   // deg, together with...
constexpr Real kSpiralPath        = -20.0;  // ...this descent
constexpr Real kInverted          = 100.0;  // deg: more than on its side
constexpr Real kAirborneHeight    = 1.0;    // m: above this, it was flying
constexpr Real kHardLandingBank   = 20.0;   // deg: wings roughly level
} // namespace

const char* ToString(CrashCause cause)
{
    switch (cause)
    {
    case CrashCause::None:           return "none";
    case CrashCause::Failure:        return "failure";
    case CrashCause::Obstacle:       return "obstacle";
    case CrashCause::GroundHandling: return "ground_handling";
    case CrashCause::HardLanding:    return "hard_landing";
    case CrashCause::Spin:           return "spin";
    case CrashCause::TipStall:       return "tip_stall";
    case CrashCause::Stall:          return "stall";
    case CrashCause::SpiralDive:     return "spiral_dive";
    case CrashCause::FlewIntoGround: return "flew_into_ground";
    }
    return "unknown";
}

CrashAnalysisSettings CrashAnalysisSettingsFor(const AircraftDefinition& definition)
{
    CrashAnalysisSettings settings;
    settings.ApproachSpeed = definition.ApproachSpeed;
    // An approach is flown at about 1.3 x the stall speed, so without a
    // measured figure that is the best estimate there is.
    settings.StallSpeed = definition.ApproachSpeed / 1.3;
    const auto stall = definition.ValidationTargets.find("stall_speed_mps");
    if (stall != definition.ValidationTargets.end() && stall->second.Value > 0.0)
    {
        settings.StallSpeed = stall->second.Value;
    }
    return settings;
}

CrashReport AnalyzeCrash(const FlightRecorder& recording,
                         const CrashResult& crash,
                         const CrashAnalysisSettings& settings)
{
    CrashReport report;
    if (!crash.Crashed || recording.Empty()) { return report; }

    // ------------------------------------------------- find the impact ---
    // The impact is the first frame of the LAST run of crashed frames: a
    // flight can hold more than one crash if the pilot reset and flew again
    // without the recorder being cleared.
    const std::size_t count = recording.Size();
    std::size_t impact = count;
    for (std::size_t i = count; i-- > 0; )
    {
        if (recording.At(i).Crashed) { impact = i; }
        else if (impact != count) { break; }
    }
    if (impact == count) { impact = count - 1; }

    const FlightFrame& hit = recording.At(impact);
    const Real impactTime = hit.Time;

    // The frame BEFORE the impact describes the arrival. The impact frame
    // itself is recorded after the rest of that render frame's physics steps,
    // so it already holds the wreck tumbling - rates of a thousand degrees a
    // second that the aircraft never had in the air.
    const FlightFrame& arrival = (impact > 0) ? recording.At(impact - 1) : hit;
    const Real speed = arrival.VelocityWorld.Length();
    const EulerAngles attitude = arrival.Orientation.ToEuler();

    report.ImpactSpeed  = speed;
    report.SinkRate     = arrival.VelocityWorld.z;
    report.Airspeed     = arrival.Airspeed;
    report.BankDegrees  = units::ToDegrees(attitude.roll);
    report.PitchDegrees = units::ToDegrees(attitude.pitch);
    report.PathDegrees  = speed > 0.5
                        ? -units::ToDegrees(std::asin(ClampUnit(arrival.VelocityWorld.z / speed)))
                        : 0.0;
    report.Throttle     = arrival.Controls.Throttle();
    report.StruckPart   = crash.PointName;

    // --------------------------------------------- scan the look-back ---
    bool airborne = false;
    Real stallOnsetTime = -1.0;
    Real stallOnsetHeight = -1.0;
    Real wingDropTime = -1.0;
    Real wingDropHeight = -1.0;
    const std::size_t lastInAir = (impact > 0) ? impact - 1 : 0;
    for (std::size_t i = 0; i <= lastInAir; ++i)
    {
        const FlightFrame& f = recording.At(i);
        if (f.Time < impactTime - settings.LookBack) { continue; }
        if (!f.OnGround && f.HeightAboveGround > kAirborneHeight) { airborne = true; }

        const Real yawRate  = std::abs(units::ToDegrees(f.AngularVelocityBody.z));
        const Real rollRate = std::abs(units::ToDegrees(f.AngularVelocityBody.x));
        report.PeakStalledFraction = Max(report.PeakStalledFraction, f.StalledFraction);
        if (f.StalledFraction > kWingDropFraction && !f.OnGround)
        {
            report.PeakYawRateDegrees  = Max(report.PeakYawRateDegrees, yawRate);
            report.PeakRollRateDegrees = Max(report.PeakRollRateDegrees, rollRate);
            if (wingDropTime < 0.0)
            {
                wingDropTime = f.Time;
                wingDropHeight = f.HeightAboveGround;
            }
        }
        if (f.StalledFraction > kStalledFraction && !f.OnGround && stallOnsetTime < 0.0)
        {
            stallOnsetTime = f.Time;
            stallOnsetHeight = f.HeightAboveGround;
        }
    }

    // ------------------------------------------------------------ rules ---
    // 1. Something broke first. The failure is the cause even if the wing then
    //    stalled on the way down: the stall was the consequence.
    if (hit.Failure != 0 || arrival.Failure != 0)
    {
        const int kind = (hit.Failure != 0) ? hit.Failure : arrival.Failure;
        report.Cause = CrashCause::Failure;
        report.Failure = kind;

        Real onset = impactTime;
        Real onsetHeight = -1.0;
        for (std::size_t i = impact + 1; i-- > 0; )
        {
            const FlightFrame& f = recording.At(i);
            if (f.Failure != kind) { break; }
            onset = f.Time;
            onsetHeight = f.HeightAboveGround;
        }
        report.OnsetHeight = onsetHeight;
        report.OnsetToImpact = impactTime - onset;

        switch (static_cast<FailureKind>(kind))
        {
        case FailureKind::DeadStick:
            report.Title = "Engine failure";
            report.Detail = Format("The motor stopped%s, %.0f s before impact.",
                                   AtHeight(onsetHeight).c_str(), report.OnsetToImpact);
            report.Advice = "Lower the nose at once to keep flying speed, pick a landing "
                            "spot ahead and land on it - do not stretch the glide back.";
            break;
        case FailureKind::StuckSurface:
            report.Title = "Jammed control";
            report.Detail = Format("A servo jammed%s, %.0f s before impact.",
                                   AtHeight(onsetHeight).c_str(), report.OnsetToImpact);
            report.Advice = "Find what still works - rudder can roll the aircraft and "
                            "throttle can pitch it - then make wide, gentle turns home.";
            break;
        case FailureKind::DeadSurface:
            report.Title = "Lost a control";
            report.Detail = Format("A control linkage let go%s, %.0f s before impact.",
                                   AtHeight(onsetHeight).c_str(), report.OnsetToImpact);
            report.Advice = "Climb gently with throttle, use the controls you still have, "
                            "and set up a long, straight approach.";
            break;
        case FailureKind::RadioLoss:
        case FailureKind::Brownout:
            report.Title = "Radio failure";
            report.Detail = Format("The radio link was lost%s, %.0f s before impact.",
                                   AtHeight(onsetHeight).c_str(), report.OnsetToImpact);
            report.Advice = "Set the receiver failsafe to throttle closed and sticks "
                            "neutral, and range-check before every flying day.";
            break;
        default:
            report.Title = "Failure";
            report.Detail = "Something on the aircraft failed before impact.";
            report.Advice = "Fly the aircraft first: keep flying speed, then deal with it.";
            break;
        }
        return report;
    }

    // 2. A tree.
    if (crash.StruckObstacle)
    {
        report.Cause = CrashCause::Obstacle;
        report.Title = "Hit a tree";
        report.Detail = Format("Flew into a tree at %.0f m/s.", speed);
        report.Advice = "Keep circuits clear of the treeline and lose height over open "
                        "ground, where there is room to go around.";
        return report;
    }

    // 3. It never really flew: the crash happened on the ground.
    if (!airborne && !crash.GearCollapsed)
    {
        report.Cause = CrashCause::GroundHandling;
        if (Contains(crash.PointName, "wing_tip"))
        {
            report.Title = "Caught a wingtip";
            report.Detail = Format("A wingtip touched the ground at %.0f m/s, banked %.0f deg.",
                                   speed, std::abs(report.BankDegrees));
            report.Advice = "Keep the wings level on the ground: take off into wind and "
                            "hold a little aileron into any crosswind.";
        }
        else if (Contains(crash.PointName, "propeller") || Contains(crash.PointName, "nose"))
        {
            report.Title = "Nosed over";
            report.Detail = Format("The nose went down onto the ground at %.0f m/s.", speed);
            report.Advice = "Hold a little up elevator while rolling on grass, and open the "
                            "throttle smoothly rather than all at once.";
        }
        else
        {
            report.Title = "Ground handling";
            report.Detail = Format("The %s hit the ground while it was still rolling.",
                                   crash.PointName.empty() ? "airframe" : crash.PointName.c_str());
            report.Advice = "Small, early rudder corrections keep it straight; let it reach "
                            "flying speed before raising the nose.";
        }
        return report;
    }

    // 4. Spin: stalled, and yawing fast.
    if (report.PeakStalledFraction > kStalledFraction
        && report.PeakYawRateDegrees > kSpinYawRate)
    {
        report.Cause = CrashCause::Spin;
        report.OnsetHeight = stallOnsetHeight;
        report.OnsetToImpact = stallOnsetTime >= 0.0 ? impactTime - stallOnsetTime : -1.0;
        report.Title = "Spin";
        report.Detail = Format("Stalled%s and spun, yawing at up to %.0f deg/s.",
                               AtHeight(stallOnsetHeight).c_str(), report.PeakYawRateDegrees);
        report.Advice = "Throttle closed, full opposite rudder, elevator forward until the "
                        "rotation stops, then level the wings and pull out - it takes height.";
        return report;
    }

    // 5. Tip stall: part of the wing let go and it rolled hard.
    if (report.PeakStalledFraction > kWingDropFraction
        && report.PeakRollRateDegrees > kTipStallRollRate)
    {
        report.Cause = CrashCause::TipStall;
        report.OnsetHeight = wingDropHeight;
        report.OnsetToImpact = wingDropTime >= 0.0 ? impactTime - wingDropTime : -1.0;
        report.Title = "Tip stall";
        report.Detail = Format("A wing dropped%s, rolling at %.0f deg/s; %.1f m/s against a "
                               "stall speed of %.1f.",
                               AtHeight(wingDropHeight).c_str(), report.PeakRollRateDegrees,
                               arrival.Airspeed, settings.StallSpeed);
        report.Advice = "Keep the speed up in turns near the ground, and turn with rudder "
                        "and aileron together rather than pulling hard when slow.";
        return report;
    }

    // 6. Stall.
    if (report.PeakStalledFraction > kStalledFraction)
    {
        report.Cause = CrashCause::Stall;
        report.OnsetHeight = stallOnsetHeight;
        report.OnsetToImpact = stallOnsetTime >= 0.0 ? impactTime - stallOnsetTime : -1.0;
        report.Title = "Stall";
        report.Detail = Format("The wing stalled%s; stall speed is about %.1f m/s.",
                               AtHeight(stallOnsetHeight).c_str(), settings.StallSpeed);
        report.Advice = Format("At the first sign, lower the nose and add power. Fly the "
                               "approach at about %.0f m/s until the flare.",
                               settings.ApproachSpeed);
        return report;
    }

    // 7. Gear collapse: an arrival, wings roughly level, sinking too fast.
    if (crash.GearCollapsed
        || (std::abs(report.BankDegrees) < kHardLandingBank
            && arrival.VelocityWorld.z > settings.GearImpactLimit))
    {
        const Real sink = Max(arrival.VelocityWorld.z, hit.VelocityWorld.z);
        report.Cause = CrashCause::HardLanding;
        report.SinkRate = sink;
        report.Title = "Hard landing";
        report.Detail = Format("Touched down sinking at %.1f m/s; the gear takes about %.0f.",
                               sink, settings.GearImpactLimit);
        report.Advice = "Flare: raise the nose gradually over the last metre so the sink "
                        "stops just as the wheels arrive. A touch of power softens it.";
        return report;
    }

    // 8. Steeply banked or diving.
    const Real bank = std::abs(report.BankDegrees);
    if (bank > kSteepBank || report.PathDegrees < kSteepDive
        || (bank > kSpiralBank && report.PathDegrees < kSpiralPath))
    {
        report.Cause = CrashCause::SpiralDive;
        if (bank > kInverted)
        {
            // Upside down is its own lesson, and the one a beginner most needs:
            // pulling while inverted points the nose at the ground.
            report.Title = "Upside down";
            report.Detail = Format("Hit the ground inverted, banked %.0f deg, at %.0f m/s.",
                                   bank, speed);
            report.Advice = "Roll the wings level first - the shortest way round - and only "
                            "then pull. Pulling while inverted only steepens the dive.";
            return report;
        }
        report.Title = bank > kSpiralBank ? "Spiral dive" : "Dive";
        report.Detail = Format("Hit banked %.0f deg, descending at %.0f deg and %.0f m/s.",
                               std::abs(report.BankDegrees), -report.PathDegrees, speed);
        report.Advice = "Level the wings first, then pull. Pulling while steeply banked only "
                        "tightens the turn and steepens the dive.";
        return report;
    }

    // 9. Everything else: it was flying, and the ground arrived.
    report.Cause = CrashCause::FlewIntoGround;
    report.Title = "Flew into the ground";
    report.Detail = Format("Still flying at %.0f m/s, descending at %.0f deg with the wings "
                           "%s.", arrival.Airspeed, -report.PathDegrees,
                           std::abs(report.BankDegrees) < 15.0 ? "level" : "banked");
    report.Advice = "Watch the height on approach and start the flare earlier; the shadow "
                    "under the aircraft is the best height cue there is.";
    return report;
}

} // namespace rc
