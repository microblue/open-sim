#include "RCPhysics/Core/Log.h"

#include <cstdio>

namespace rc
{
namespace
{
    void DefaultStderrSink(LogCategory category, LogLevel level, const char* message)
    {
        std::fprintf(stderr, "[%s][%s] %s\n", ToString(category), ToString(level), message);
    }

    LogSink  ActiveSink      = &DefaultStderrSink;
    LogLevel ActiveVerbosity = LogLevel::Info;
}

void SetLogSink(LogSink sink)
{
    ActiveSink = (sink != nullptr) ? sink : &DefaultStderrSink;
}

void SetLogVerbosity(LogLevel maxLevel) { ActiveVerbosity = maxLevel; }
LogLevel GetLogVerbosity() { return ActiveVerbosity; }

const char* ToString(LogCategory category)
{
    switch (category)
    {
        case LogCategory::Core:       return "OpenRC";
        case LogCategory::Physics:    return "RCPhysics";
        case LogCategory::Aero:       return "RCAero";
        case LogCategory::Propulsion: return "RCPropulsion";
        case LogCategory::Input:      return "RCInput";
        case LogCategory::Test:       return "RCTest";
    }
    return "RCUnknown";
}

const char* ToString(LogLevel level)
{
    switch (level)
    {
        case LogLevel::Error:   return "Error";
        case LogLevel::Warning: return "Warning";
        case LogLevel::Info:    return "Info";
        case LogLevel::Verbose: return "Verbose";
    }
    return "Unknown";
}

void LogPrintf(LogCategory category, LogLevel level, const char* format, ...)
{
    if (level > ActiveVerbosity || ActiveSink == nullptr)
    {
        return;
    }

    char buffer[1024];
    va_list args;
    va_start(args, format);
    const int written = std::vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);

    if (written < 0)
    {
        return;
    }
    buffer[sizeof(buffer) - 1] = '\0';
    ActiveSink(category, level, buffer);
}

} // namespace rc
