// OpenRC Simulator - guards the shipped aircraft definition.
//
// Data/Aircraft/Trainer1500.json is edited by hand constantly while tuning. This
// test is what stops a mistyped digit or a stray comma from being discovered in
// the air. It checks the file parses, and that the geometry is self-consistent -
// areas that add up, a symmetric airframe, gear that is actually under the
// aircraft, and a static load split that can steer and rotate.
//
// The full AircraftLoader arrives in Milestone 2; until then these checks run
// straight off the JSON.
#include "TestHarness.h"

#include "RCPhysics/Core/Json.h"
#include "RCPhysics/Core/Units/Units.h"

#include <cmath>
#include <set>
#include <string>

using namespace rc;

namespace
{
    const std::string kAircraftPath = std::string(RC_REPO_ROOT) + "/Data/Aircraft/Trainer1500.json";

    const JsonValue& Trainer(rctest::TestContext& ctx)
    {
        static JsonValue root;
        static bool loaded = false;
        static std::string failure;

        if (!loaded)
        {
            JsonParseResult result;
            root = ParseJsonFile(kAircraftPath, result);
            loaded = true;
            if (!result.Success) { failure = result.Describe(); }
        }
        if (!failure.empty())
        {
            ctx.Fail("Trainer1500.json: " + failure, __FILE__, __LINE__);
        }
        return root;
    }

    struct Surface
    {
        std::string Name;
        std::string Role;
        std::string Airfoil;
        Real X = 0.0, Y = 0.0, Z = 0.0;
        Real Area = 0.0, Chord = 0.0, Span = 0.0;
    };

    std::vector<Surface> ReadSurfaces(const JsonValue& root)
    {
        std::vector<Surface> surfaces;
        const JsonValue& list = root["aero_surfaces"];
        for (size_t i = 0; i < list.Size(); ++i)
        {
            const JsonValue& entry = list.At(i);
            Surface s;
            s.Name    = entry.GetString("name");
            s.Role    = entry.GetString("role");
            s.Airfoil = entry.GetString("airfoil");
            entry.GetVector3("position_m", s.X, s.Y, s.Z);
            s.Area  = entry.GetNumber("area_m2");
            s.Chord = entry.GetNumber("chord_m");
            s.Span  = entry.GetNumber("span_m");
            surfaces.push_back(s);
        }
        return surfaces;
    }
}

RC_TEST(Trainer1500, FileParsesAndDeclaresAKnownFormat)
{
    const JsonValue& root = Trainer(ctx);
    RC_CHECK(root.IsObject());
    RC_CHECK_NEAR(root.GetNumber("format_version"), 1.0, 1e-15);
    RC_CHECK(root.GetString("name") == "Trainer 1500");
}

RC_TEST(Trainer1500, MassAndInertiaArePhysical)
{
    const JsonValue& mass = Trainer(ctx)["mass"];
    RC_CHECK_NEAR(mass.GetNumber("mass_kg"), 1.35, 1e-12);

    const JsonValue& inertia = mass["inertia"];
    const Real ixx = inertia.GetNumber("ixx_kg_m2");
    const Real iyy = inertia.GetNumber("iyy_kg_m2");
    const Real izz = inertia.GetNumber("izz_kg_m2");

    RC_CHECK(ixx > 0.0 && iyy > 0.0 && izz > 0.0);

    // The triangle inequality on principal moments. Any tensor that violates it
    // does not correspond to a real mass distribution, and it is an easy typo
    // to make when hand-tuning.
    RC_CHECK(ixx + iyy >= izz);
    RC_CHECK(iyy + izz >= ixx);
    RC_CHECK(izz + ixx >= iyy);

    // For an aircraft, yaw inertia is the largest and roll the smallest.
    RC_CHECK(izz > iyy);
    RC_CHECK(iyy > ixx);
}

RC_TEST(Trainer1500, SectionAreasSumToTheReferenceArea)
{
    const JsonValue& root = Trainer(ctx);
    const std::vector<Surface> surfaces = ReadSurfaces(root);
    RC_CHECK(surfaces.size() == 11);

    Real wingArea = 0.0;
    for (const Surface& s : surfaces)
    {
        if (s.Role == "wing") { wingArea += s.Area; }
    }

    const Real reference = root["reference"].GetNumber("wing_area_m2");
    // Within 1 %: the discretisation rounds, but it must not drift.
    RC_CHECK_NEAR(wingArea, reference, reference * 0.01);
}

RC_TEST(Trainer1500, EverySurfaceIsWellFormed)
{
    const JsonValue& root = Trainer(ctx);

    std::set<std::string> airfoilNames;
    for (const auto& entry : root["airfoils"].AsObject())
    {
        airfoilNames.insert(entry.first);
    }
    RC_CHECK(!airfoilNames.empty());

    for (const Surface& s : ReadSurfaces(root))
    {
        if (s.Area <= 0.0 || s.Chord <= 0.0 || s.Span <= 0.0)
        {
            RC_FAIL(s.Name + ": area, chord and span must all be positive");
        }
        if (airfoilNames.count(s.Airfoil) == 0)
        {
            RC_FAIL(s.Name + ": references unknown airfoil '" + s.Airfoil + "'");
        }
        if (s.Role != "wing" && s.Role != "horizontal_tail" && s.Role != "vertical_tail")
        {
            RC_FAIL(s.Name + ": unknown role '" + s.Role + "'");
        }
        // Area should be about span x chord for a rectangular panel.
        RC_CHECK_NEAR(s.Area, s.Span * s.Chord, s.Area * 0.05);
    }
}

RC_TEST(Trainer1500, AirframeIsLaterallySymmetric)
{
    // An asymmetry here would show up in the air as a persistent roll or yaw
    // that no amount of trim explains, and it is very hard to find by flying.
    const std::vector<Surface> surfaces = ReadSurfaces(Trainer(ctx));

    int examined = 0;
    for (const Surface& s : surfaces)
    {
        if (std::fabs(s.Y) < 1e-9) { continue; }   // centreline surfaces
        ++examined;

        bool foundMirror = false;
        for (const Surface& other : surfaces)
        {
            if (std::fabs(other.Y + s.Y) < 1e-9 &&
                std::fabs(other.X - s.X) < 1e-9 &&
                std::fabs(other.Z - s.Z) < 1e-9 &&
                std::fabs(other.Area - s.Area) < 1e-9 &&
                other.Role == s.Role)
            {
                foundMirror = true;
                break;
            }
        }
        if (!foundMirror)
        {
            RC_FAIL(s.Name + ": has no mirrored counterpart on the other side");
        }
    }

    // Guard against this test silently passing on an empty surface list.
    RC_CHECK(examined == 10);
}

RC_TEST(Trainer1500, HighWingSitsAboveTheCentreOfGravity)
{
    // The wing being above the CG is a major part of this trainer's roll
    // stability. In body FRD, above means a negative Z.
    for (const Surface& s : ReadSurfaces(Trainer(ctx)))
    {
        if (s.Role == "wing")
        {
            RC_CHECK(s.Z < -0.05);
        }
    }
}

RC_TEST(Trainer1500, TailSurfacesAreBehindTheCentreOfGravity)
{
    for (const Surface& s : ReadSurfaces(Trainer(ctx)))
    {
        if (s.Role == "horizontal_tail" || s.Role == "vertical_tail")
        {
            RC_CHECK(s.X < -0.3);
        }
    }
}

RC_TEST(Trainer1500, TailVolumeCoefficientsAreInTheTrainerRange)
{
    const JsonValue& root = Trainer(ctx);
    const Real wingArea = root["reference"].GetNumber("wing_area_m2");
    const Real span     = root["reference"].GetNumber("wingspan_m");
    const Real chord    = root["reference"].GetNumber("mean_aerodynamic_chord_m");

    Real horizontalArea = 0.0, horizontalArm = 0.0;
    Real verticalArea = 0.0,   verticalArm = 0.0;

    for (const Surface& s : ReadSurfaces(root))
    {
        if (s.Role == "horizontal_tail") { horizontalArea += s.Area; horizontalArm = -s.X; }
        if (s.Role == "vertical_tail")   { verticalArea   += s.Area; verticalArm   = -s.X; }
    }

    const Real vh = horizontalArea * horizontalArm / (wingArea * chord);
    const Real vv = verticalArea * verticalArm / (wingArea * span);

    // A trainer sits at the generous end of both ranges; that generosity is
    // what makes it self-correcting.
    RC_CHECK(vh > 0.40 && vh < 0.80);
    RC_CHECK(vv > 0.025 && vv < 0.060);
}

RC_TEST(Trainer1500, TricycleGearGeometryCanSteerAndRotate)
{
    const JsonValue& root = Trainer(ctx);
    const JsonValue& gear = root["landing_gear"];
    RC_CHECK(gear.Size() == 3);

    Real noseX = 0.0, mainX = 0.0;
    int steerableCount = 0;

    for (size_t i = 0; i < gear.Size(); ++i)
    {
        const JsonValue& wheel = gear.At(i);
        Real x = 0.0, y = 0.0, z = 0.0;
        RC_CHECK(wheel.GetVector3("position_m", x, y, z));

        // Every wheel must be below the CG. In FRD, below is +Z.
        RC_CHECK(z > 0.0);
        RC_CHECK(wheel.GetNumber("spring_n_per_m") > 0.0);
        RC_CHECK(wheel.GetNumber("radius_m") > 0.0);

        if (wheel.GetBool("steerable")) { ++steerableCount; noseX = x; }
        else { mainX = x; }
    }

    RC_CHECK(steerableCount == 1);
    RC_CHECK(noseX > 0.0);    // nose wheel ahead of the CG
    RC_CHECK(mainX < 0.0);    // mains behind it, or the aircraft cannot rotate

    // Static load split. Moment balance about the CG with the mains sharing the
    // load equally gives
    //     N_nose * noseX = 2*N_main * |mainX|,   N_nose + 2*N_main = W
    // and eliminating N_main leaves
    //     N_nose / W = |mainX| / (|mainX| + noseX)
    // A nose that carries too little cannot steer; too much and the elevator
    // cannot lift it at rotation speed.
    const Real noseShare = std::fabs(mainX) / (std::fabs(mainX) + noseX);
    RC_CHECK(noseShare > 0.10 && noseShare < 0.25);
}

RC_TEST(Trainer1500, PropellerAndPowerSystemAreConsistent)
{
    const JsonValue& propulsion = Trainer(ctx)["propulsion"];

    const Real cells   = propulsion["battery"].GetNumber("cell_count");
    const Real cellV   = propulsion["battery"].GetNumber("nominal_cell_voltage_v");
    const Real kv      = propulsion["motor"].GetNumber("kv_rpm_per_volt");
    const Real diameter = units::Inches(propulsion["propeller"].GetNumber("diameter_in"));
    const Real pitch    = units::Inches(propulsion["propeller"].GetNumber("pitch_in"));

    RC_CHECK_NEAR(cells, 3.0, 1e-15);
    // The propeller is a tuning choice, not a fixed constant, so this asserts
    // the range that suits a 1.5 m airframe rather than one specific size.
    RC_CHECK(diameter > units::Inches(8.0) && diameter < units::Inches(12.0));
    RC_CHECK(pitch < diameter);          // pitch greater than diameter is not a thing
    RC_CHECK(pitch > 0.35 * diameter);   // and a very flat pitch would not cruise

    // Unloaded rpm must leave headroom above the rpm the prop will actually
    // turn, or the combination cannot reach its rated thrust.
    const Real noLoadRpm = cells * cellV * kv;
    RC_CHECK(noLoadRpm > 10000.0 && noLoadRpm < 13000.0);

    // Theoretical pitch speed: what the aircraft can reach in level flight.
    // It must comfortably exceed cruise, or the model is under-propped.
    const Real pitchSpeed = (noLoadRpm / 60.0) * pitch * 0.85;
    const Real cruise = Trainer(ctx)["spawn"].GetNumber("cruise_speed_mps");
    RC_CHECK(pitchSpeed > cruise * 1.2);
}

RC_TEST(Trainer1500, ValidationTargetsAreWellFormed)
{
    const JsonValue& targets = Trainer(ctx)["validation_targets"];
    RC_CHECK(targets.Size() >= 7);

    int wellFormed = 0;
    for (const auto& entry : targets.AsObject())
    {
        const JsonValue& target = entry.second;
        if (!target.IsObject())
        {
            RC_FAIL(entry.first + ": target must be an object");
            continue;
        }
        if (!(target.GetNumber("value") > 0.0))
        {
            RC_FAIL(entry.first + ": value must be positive");
        }
        const Real tolerance = target.GetNumber("tolerance");
        if (!(tolerance > 0.0 && tolerance < 1.0))
        {
            RC_FAIL(entry.first + ": tolerance must be a fraction in (0, 1)");
        }
        if (!target.Has("locked"))
        {
            RC_FAIL(entry.first + ": must state whether it is locked or a seed");
        }
        ++wellFormed;
    }

    RC_CHECK(wellFormed == static_cast<int>(targets.Size()));
}

RC_TEST(Trainer1500, StallSpeedTargetIsConsistentWithTheWingLoading)
{
    // Cross-check the seeded stall speed against the geometry it came from, so
    // that changing the mass or the wing area without revisiting the target
    // fails here instead of silently invalidating the regression suite.
    const JsonValue& root = Trainer(ctx);

    const Real mass     = root["mass"].GetNumber("mass_kg");
    const Real wingArea = root["reference"].GetNumber("wing_area_m2");
    const Real clMax    = root["airfoils"]["trainer_flat_bottom"].GetNumber("cl_max");

    // Finite wing with washout reaches roughly 0.88 of the 2D section maximum,
    // and the tail carries about 5 % of the weight as download at trim.
    const Real wingClMax = clMax * 0.88;
    const Real weight    = mass * units::kGravity * 1.05;
    const Real predicted = std::sqrt(2.0 * weight / (units::kSeaLevelDensity * wingArea * wingClMax));

    const JsonValue& target = root["validation_targets"]["stall_speed_mps"];
    RC_CHECK_NEAR(target.GetNumber("value"), predicted, predicted * target.GetNumber("tolerance"));
}
