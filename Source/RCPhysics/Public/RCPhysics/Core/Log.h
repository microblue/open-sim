// OpenRC Simulator - logging for the engine-agnostic core.
//
// The core cannot call UE_LOG, and must never call printf directly from
// scattered places. Instead it emits into categories through a single sink.
// The UE bridge installs a sink that forwards to LogOpenRC / LogRCPhysics /
// LogRCAero / LogRCPropulsion / LogRCInput / LogRCTest. Standalone builds
// (unit tests, tuning tools) get a stderr sink.
//
//     RC_LOG(Aero, Warning, "section %d stalled at alpha=%.1f deg", i, deg);
#pragma once

#include <cstdarg>

namespace rc
{
enum class LogCategory
{
    Core,           ///< LogOpenRC
    Physics,        ///< LogRCPhysics
    Aero,           ///< LogRCAero
    Propulsion,     ///< LogRCPropulsion
    Input,          ///< LogRCInput
    Test            ///< LogRCTest
};

enum class LogLevel
{
    Error,
    Warning,
    Info,
    Verbose
};

/** Sink signature. `message` is a fully formatted, NUL-terminated line with no
 *  trailing newline. Implementations must be callable from the physics thread. */
using LogSink = void (*)(LogCategory category, LogLevel level, const char* message);

/** Install a sink. Passing nullptr restores the default stderr sink. */
void SetLogSink(LogSink sink);

/** Messages below this level are dropped before formatting. */
void SetLogVerbosity(LogLevel maxLevel);
LogLevel GetLogVerbosity();

const char* ToString(LogCategory category);
const char* ToString(LogLevel level);

/** Formats and dispatches. Prefer the RC_LOG macro, which skips the call
 *  entirely when the message would be filtered out. */
void LogPrintf(LogCategory category, LogLevel level, const char* format, ...)
#if defined(__GNUC__) || defined(__clang__)
    __attribute__((format(printf, 3, 4)))
#endif
    ;

} // namespace rc

#define RC_LOG(CategoryName, LevelName, ...)                                           \
    do {                                                                               \
        if (::rc::LogLevel::LevelName <= ::rc::GetLogVerbosity())                      \
        {                                                                              \
            ::rc::LogPrintf(::rc::LogCategory::CategoryName,                           \
                            ::rc::LogLevel::LevelName, __VA_ARGS__);                   \
        }                                                                              \
    } while (false)
