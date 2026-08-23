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
#ifdef DEBUG_ENABLED
    rc::SetLogVerbosity(rc::LogLevel::Info);
#else
    rc::SetLogVerbosity(rc::LogLevel::Warning);
#endif
}

void RemoveGodotLogSink()
{
    rc::SetLogSink(nullptr);
}

} // namespace openrc
