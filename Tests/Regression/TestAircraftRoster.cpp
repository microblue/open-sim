// OpenRC Simulator - every aircraft in Data/Aircraft/, not just the trainer.
//
// TestAircraftDataFile pins Trainer1500 in detail: its measured targets, its
// tail volumes, its gear geometry. This is the other half - the checks that
// must hold for ANY aeroplane in the roster, so that adding one cannot ship a
// file that parses and then flies like a brick or refuses to leave the ground.
//
// The roster is discovered rather than listed. A new aircraft is covered the
// moment its file exists, which is the only way a check like this stays true.

#include "RCPhysics/Aircraft/AircraftLoader.h"
#include "RCPhysics/Aircraft/Aircraft.h"
#include "TestHarness.h"

#include <algorithm>
#include <filesystem>
#include <string>
#include <vector>

namespace
{
    struct Entry
    {
        std::string Path;
        std::string Name;
    };

    const std::vector<Entry>& Roster()
    {
        static std::vector<Entry> roster = [] {
            std::vector<Entry> found;
            const std::string dir = std::string(RC_REPO_ROOT) + "/Data/Aircraft";
            std::error_code error;
            for (const auto& item : std::filesystem::directory_iterator(dir, error))
            {
                if (!item.is_regular_file()) { continue; }
                if (item.path().extension() != ".json") { continue; }
                found.push_back({item.path().string(), item.path().stem().string()});
            }
            std::sort(found.begin(), found.end(),
                      [](const Entry& a, const Entry& b) { return a.Name < b.Name; });
            return found;
        }();
        return roster;
    }

    rc::Real WingLoadingPa(const rc::AircraftDefinition& definition)
    {
        return definition.Mass * 9.80665 / definition.WingArea;
    }
}

RC_TEST(Roster, EveryFileParses)
{
    RC_CHECK(!Roster().empty());
    for (const Entry& entry : Roster())
    {
        rc::AircraftDefinition definition;
        const rc::AircraftLoadResult result =
            rc::AircraftLoader::LoadFromFile(entry.Path, definition);
        if (!result.Success)
        {
            RC_FAIL(entry.Name + ": " +
                    (result.Errors.empty() ? std::string("unknown error") : result.Errors[0]));
            continue;
        }
        RC_CHECK(!definition.Name.empty());
        RC_CHECK(!definition.Surfaces.empty());
    }
}

RC_TEST(Roster, EveryAirframeIsPhysicallyCoherent)
{
    for (const Entry& entry : Roster())
    {
        rc::AircraftDefinition definition;
        if (!rc::AircraftLoader::LoadFromFile(entry.Path, definition).Success) { continue; }

        // Mass and inertia have to be positive and of a sane order, or the
        // integrator produces a non-finite state on the first step.
        RC_CHECK(definition.Mass > 0.05 && definition.Mass < 25.0);
        RC_CHECK(definition.Inertia.m[0][0] > 0.0);
        RC_CHECK(definition.Inertia.m[1][1] > 0.0);
        RC_CHECK(definition.Inertia.m[2][2] > 0.0);

        // The wing area the reference quotes must be the area the sections add
        // up to, or every coefficient in the model is scaled against a lie.
        rc::Real summed = 0.0;
        for (const rc::AeroSurfaceSpec& surface : definition.Surfaces)
        {
            if (surface.Role == rc::SurfaceRole::Wing) { summed += surface.Area; }
        }
        const rc::Real error = std::fabs(summed - definition.WingArea)
                             / definition.WingArea;
        RC_CHECK_MSG_VALUE(error < 0.06, error);

        // Wing loading, in the range a model aeroplane occupies. Below this it
        // cannot penetrate wind; above it, nothing in this size class flies.
        const rc::Real loading = WingLoadingPa(definition);
        RC_CHECK_MSG_VALUE(loading > 12.0 && loading < 110.0, loading);
    }
}

RC_TEST(Roster, EveryAircraftHasTheControlsToFly)
{
    for (const Entry& entry : Roster())
    {
        rc::AircraftDefinition definition;
        if (!rc::AircraftLoader::LoadFromFile(entry.Path, definition).Success) { continue; }

        bool aileron = false, elevator = false, rudder = false;
        for (const rc::AeroSurfaceSpec& surface : definition.Surfaces)
        {
            if (!surface.HasControl) { continue; }
            switch (surface.Control.Channel)
            {
                case rc::RCChannel::Aileron:  aileron = true; break;
                case rc::RCChannel::Elevator: elevator = true; break;
                case rc::RCChannel::Rudder:   rudder = true; break;
                default: break;
            }
        }
        RC_CHECK(aileron);
        RC_CHECK(elevator);
        RC_CHECK(rudder);
    }
}

RC_TEST(Roster, TailSurfacesAreBehindTheCentreOfGravity)
{
    // A tail in front of the CG is not a tail. This is the single mistake that
    // turns a new aircraft into something that diverges on the first step.
    for (const Entry& entry : Roster())
    {
        rc::AircraftDefinition definition;
        if (!rc::AircraftLoader::LoadFromFile(entry.Path, definition).Success) { continue; }

        for (const rc::AeroSurfaceSpec& surface : definition.Surfaces)
        {
            if (surface.Role == rc::SurfaceRole::HorizontalTail
                || surface.Role == rc::SurfaceRole::VerticalTail)
            {
                RC_CHECK_MSG_VALUE(surface.PositionBody.x < -0.1, surface.PositionBody.x);
            }
        }
    }
}

RC_TEST(Roster, ThePowerSystemCanLiftTheAeroplane)
{
    // Not a thrust calculation - that needs the propeller model - but the
    // electrical envelope has to be capable of it, and a motor whose current
    // limit is below what the battery can deliver into it is a typo.
    for (const Entry& entry : Roster())
    {
        rc::AircraftDefinition definition;
        if (!rc::AircraftLoader::LoadFromFile(entry.Path, definition).Success) { continue; }

        const rc::Real volts = definition.Propulsion.Battery.CellCount
                             * definition.Propulsion.Battery.NominalCellVoltage;
        const rc::Real watts = volts * definition.Propulsion.Motor.MaxCurrent;
        const rc::Real wattsPerKilo = watts / definition.Mass;

        RC_CHECK(volts > 3.0 && volts < 30.0);
        // A glider gets by on very little; nothing here needs a kilowatt a kilo.
        RC_CHECK_MSG_VALUE(wattsPerKilo > 60.0 && wattsPerKilo < 800.0, wattsPerKilo);
    }
}

RC_TEST(Roster, TheAircraftAreActuallyDifferent)
{
    // The point of a roster is that the aeroplanes fly differently. If two of
    // them share a wing loading and a power-to-weight ratio, one of them is a
    // renamed copy of the other and the choice means nothing.
    std::vector<std::pair<rc::Real, rc::Real>> signatures;
    for (const Entry& entry : Roster())
    {
        rc::AircraftDefinition definition;
        if (!rc::AircraftLoader::LoadFromFile(entry.Path, definition).Success) { continue; }
        const rc::Real volts = definition.Propulsion.Battery.CellCount
                             * definition.Propulsion.Battery.NominalCellVoltage;
        signatures.push_back({WingLoadingPa(definition),
                              volts * definition.Propulsion.Motor.MaxCurrent
                              / definition.Mass});
    }

    RC_CHECK(signatures.size() >= 2);
    for (size_t i = 0; i < signatures.size(); ++i)
    {
        for (size_t j = i + 1; j < signatures.size(); ++j)
        {
            const rc::Real loading = std::fabs(signatures[i].first - signatures[j].first);
            const rc::Real power = std::fabs(signatures[i].second - signatures[j].second);
            // Different in at least one of the two, by a margin a pilot feels.
            RC_CHECK(loading > 6.0 || power > 40.0);
        }
    }
}

RC_TEST(Roster, TheSpawnBlockReachesTheDefinition)
{
    // The loader never read `spawn`. Every aeroplane in the roster therefore
    // used the struct's defaults - 16 m/s cruise, 11 m/s approach - so the
    // hangar quoted a 2.4 m thermal glider the same approach speed as a
    // warbird, an air start launched all four at the same speed, and the test
    // rig flew the glider's minimum-sink runs eleven metres a second too fast.
    // Four files' worth of hand-measured numbers went through it unnoticed
    // because nothing here read them back.
    //
    // Checked as a spread rather than against fixed values: what went wrong
    // was not one number but every number being the same one.
    rc::Real slowestApproach = 1e9;
    rc::Real fastestApproach = -1e9;
    rc::Real slowestCruise   = 1e9;
    rc::Real fastestCruise   = -1e9;

    for (const Entry& entry : Roster())
    {
        rc::AircraftDefinition definition;
        if (!rc::AircraftLoader::LoadFromFile(entry.Path, definition).Success) { continue; }

        // An approach below the stall is an aeroplane that arrives at the
        // strip already stalled, and a cruise below the approach is nonsense.
        RC_CHECK(definition.ApproachSpeed > 0.0);
        RC_CHECK(definition.CruiseSpeed > definition.ApproachSpeed);
        RC_CHECK(definition.AirStartAltitude > 0.0);

        slowestApproach = std::min(slowestApproach, definition.ApproachSpeed);
        fastestApproach = std::max(fastestApproach, definition.ApproachSpeed);
        slowestCruise   = std::min(slowestCruise, definition.CruiseSpeed);
        fastestCruise   = std::max(fastestCruise, definition.CruiseSpeed);
    }

    // The roster spans a thermal glider and a warbird. If these ever collapse
    // to a single value again, the block has stopped being read.
    RC_CHECK(fastestApproach - slowestApproach > 3.0);
    RC_CHECK(fastestCruise - slowestCruise > 3.0);
}
