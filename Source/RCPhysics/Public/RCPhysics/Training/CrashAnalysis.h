// OpenRC Simulator - why did it crash?
//
// A pilot who has just put a model into the ground usually has no idea why.
// The replay answers it if they watch it slowly and know what to look for; this
// answers it in one line, straight away, and says what to do differently.
//
// It reads the flight recorder - the same last two minutes the replay bar
// scrubs - rather than keeping a record of its own, so it costs nothing until
// there is a crash, and what it concludes is always something the pilot can go
// and see in the replay.
//
// The rules are ordered: the first that fits wins. A failure comes first,
// because a model that lost its motor and then stalled on the way down did not
// crash because of the stall. After that, what hit and where, then what the
// wing was doing in the last few seconds.
//
// Every threshold here is a teaching aid, not a measurement. They decide which
// sentence a pilot reads, not whether the aircraft is broken.
#pragma once

#include "RCPhysics/Aircraft/AircraftDefinition.h"
#include "RCPhysics/Core/FlightRecorder.h"
#include "RCPhysics/Physics/Ground/LandingGear.h"

#include <string>

namespace rc
{
enum class CrashCause
{
    None,
    Failure,          ///< something broke first; see FailureKind
    Obstacle,         ///< hit a tree
    GroundHandling,   ///< never really flew: a wingtip, a nose-over, a ground loop
    HardLanding,      ///< arrived wings level but sinking too fast
    Spin,             ///< stalled and autorotated
    TipStall,         ///< one wing let go and rolled the aircraft over
    Stall,            ///< the wing stalled and there was no height to recover
    SpiralDive,       ///< steeply banked or diving, fast
    FlewIntoGround    ///< wings level, flying, and the ground arrived
};

const char* ToString(CrashCause cause);

struct CrashAnalysisSettings
{
    /** The aircraft's 1 g stall speed [m/s], for "was it slow?". */
    Real StallSpeed = 8.0;
    /** The approach speed the aircraft file recommends [m/s]. */
    Real ApproachSpeed = 11.0;
    /** The sink rate the gear survives [m/s]. */
    Real GearImpactLimit = 4.0;
    /** How far back to look [s]. Long enough to see a stall develop, short
     *  enough that a stall a minute ago and a recovery since do not count. */
    Real LookBack = 5.0;
};

struct CrashReport
{
    CrashCause Cause = CrashCause::None;
    /** Two or three words for a banner: "Tip stall". */
    std::string Title;
    /** One sentence with the numbers: what happened. */
    std::string Detail;
    /** One sentence: what to do differently. */
    std::string Advice;

    // The numbers behind the sentences, for a debrief screen to lay out.
    Real ImpactSpeed = 0.0;        ///< m/s, ground-relative
    Real SinkRate = 0.0;           ///< m/s, positive down
    Real Airspeed = 0.0;           ///< m/s
    Real BankDegrees = 0.0;        ///< signed, right wing down positive
    Real PitchDegrees = 0.0;
    Real PathDegrees = 0.0;        ///< flight path angle, negative descending
    Real Throttle = 0.0;           ///< 0..1 at impact

    /** Height at which the thing that caused the crash began [m], or -1 when
     *  the cause has no onset (a hard landing happens at zero height). */
    Real OnsetHeight = -1.0;
    /** Seconds from that onset to the impact, or -1. */
    Real OnsetToImpact = -1.0;

    Real PeakYawRateDegrees = 0.0;   ///< deg/s in the look-back window
    Real PeakRollRateDegrees = 0.0;
    Real PeakStalledFraction = 0.0;

    int Failure = 0;                 ///< FailureKind as an integer, 0 = none
    std::string StruckPart;          ///< "wing_tip_left", "gear", ...
};

/** Settings filled in from an aircraft file: its measured stall speed when the
 *  file carries one, otherwise an estimate from its approach speed. */
CrashAnalysisSettings CrashAnalysisSettingsFor(const AircraftDefinition& definition);

/** Explain the crash the recorder ends with. Returns Cause == None when the
 *  recording holds no crash. Pure: reads the recording, changes nothing. */
CrashReport AnalyzeCrash(const FlightRecorder& recording,
                         const CrashResult& crash,
                         const CrashAnalysisSettings& settings = CrashAnalysisSettings{});

} // namespace rc
