#include "RCDataPaths.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>

namespace
{
    bool Exists(const godot::String& path)
    {
        return godot::FileAccess::file_exists(path)
            || godot::DirAccess::dir_exists_absolute(path);
    }
}

namespace openrc
{
    godot::String ResolveDataPath(const godot::String& relative)
    {
        if (relative.begins_with("res://") || relative.begins_with("user://") ||
            relative.begins_with("/"))
        {
            return relative;
        }

        // globalize_path("res://") gives the project directory when running from
        // the repository and the executable's directory in an exported build, so
        // both candidates are derived from it and the first that exists wins.
        godot::ProjectSettings* settings = godot::ProjectSettings::get_singleton();
        const godot::String root = (settings != nullptr)
                                 ? settings->globalize_path("res://")
                                 : godot::String("./");

        // Files AND directories. Checking only for a file meant asking for
        // "Data/Aircraft" - a directory - always fell through to the installed
        // candidate, so the hangar listed no aeroplanes at all.
        const godot::String beside = root + relative;
        if (Exists(beside))
        {
            return beside;
        }

        const godot::String above = root + godot::String("../") + relative;
        if (Exists(above))
        {
            return above;
        }

        return beside;
    }
}
