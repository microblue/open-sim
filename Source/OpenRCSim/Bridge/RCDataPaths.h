// OpenRC Simulator - locating Data/ regardless of how the simulator started.
//
// Data/ is deliberately a loose directory on disk rather than something packed
// into the project: the aircraft definition is hand-edited while tuning and
// reloaded in place with F5, and the offline validation suite reads the very
// same files. Loose files cannot live inside res://, so the directory sits in a
// different place depending on the layout:
//
//   running from the repository : <repo>/Godot/../Data/...
//   an installed build         : <directory holding the binary>/Data/...

#ifndef OPENRCSIM_BRIDGE_RCDATAPATHS_H
#define OPENRCSIM_BRIDGE_RCDATAPATHS_H

#include <godot_cpp/variant/string.hpp>

namespace openrc
{
    /** Resolve a path relative to Data/. Absolute, res:// and user:// paths are
     *  returned untouched. When neither layout has the file, the installed-build
     *  candidate is returned so the caller's error names one concrete place. */
    godot::String ResolveDataPath(const godot::String& relative);
}

#endif
