#include "RCGodotLog.h"

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "RCPhysics/Core/Log.h"

namespace openrc
{
namespace
{
    void ForwardToGodot(rc::LogCategory category, rc::LogLevel level, const char* message)
    {
        const godot::String text =
            godot::String("[") + rc::ToString(category) + "] " + message;

        switch (level)
        {
            case rc::LogLevel::Error:
                godot::UtilityFunctions::push_error(text);
                break;
            case rc::LogLevel::Warning:
                godot::UtilityFunctions::push_warning(text);
                break;
            case rc::LogLevel::Info:
            case rc::LogLevel::Verbose:
                godot::UtilityFunctions::print(text);
                break;
        }
    }
}

void InstallGodotLogSink()
{
    rc::SetLogSink(&ForwardToGodot);

    // Info in release too, not just in debug.
    //
    // A packaged build is exactly where these lines matter: it is the one a
    // pilot runs, and "which device did it open, which profile did it load" is
    // the first thing anyone needs when a transmitter misbehaves. Dropping them
    // in release made the log file we enable for that purpose useless for it -
    // and cost an afternoon chasing a device that was in fact opening fine and
    // simply not saying so.
    //
    // Verbose stays a debug-only level; it is per-step and would swamp the log.
#ifdef DEBUG_ENABLED
    rc::SetLogVerbosity(rc::LogLevel::Verbose);
#else
    rc::SetLogVerbosity(rc::LogLevel::Info);
#endif
}

void RemoveGodotLogSink()
{
    rc::SetLogSink(nullptr);
}

} // namespace openrc
