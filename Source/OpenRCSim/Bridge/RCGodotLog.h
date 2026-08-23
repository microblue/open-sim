// OpenRC Simulator - routes the physics core's log sink into Godot.
//
// The core emits into six categories (rc::LogCategory) through a single sink.
// This installs a sink that forwards them to Godot's console with the category
// name as a prefix, so `RCAero` messages are greppable in the output panel.
#pragma once

namespace openrc
{
/** Install the Godot log sink. Called at extension initialisation. */
void InstallGodotLogSink();

/** Restore the core's default stderr sink before the library unloads, or a late
 *  message would call into freed code. */
void RemoveGodotLogSink();

} // namespace openrc
