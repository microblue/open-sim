// OpenRC Simulator - reads an aircraft definition from JSON.
//
// Converts every modeller-facing unit into SI exactly once, validates the
// result, and reports failures precisely. Tuning a flight model means editing
// the file dozens of times a session, so a vague error message costs more than
// the check does.
//
// See Docs/AIRCRAFT_FORMAT.md for the schema.
#pragma once

#include "RCPhysics/Aircraft/AircraftDefinition.h"

#include <string>
#include <vector>

namespace rc
{
struct AircraftLoadResult
{
    bool Success = false;

    /** Fatal problems. Non-empty means the definition was rejected. */
    std::vector<std::string> Errors;

    /** Non-fatal: defaults that were substituted, values that look odd. */
    std::vector<std::string> Warnings;

    std::string Describe() const;
};

class AircraftLoader
{
public:
    /** Parse from JSON text. */
    static AircraftLoadResult LoadFromString(const std::string& text,
                                             AircraftDefinition& outDefinition,
                                             const std::string& sourceName = "<memory>");

    /** Read and parse a file. */
    static AircraftLoadResult LoadFromFile(const std::string& path,
                                           AircraftDefinition& outDefinition);

    /** Structural checks that do not need the JSON: positive areas, known
     *  airfoil indices, an invertible inertia tensor, sane power system.
     *  Run automatically by the loaders; exposed for definitions built in code. */
    static AircraftLoadResult Validate(const AircraftDefinition& definition);
};

} // namespace rc
