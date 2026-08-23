#include "RCDataPaths.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>

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

        const godot::String beside = root + relative;
        if (godot::FileAccess::file_exists(beside))
        {
            return beside;
        }

        const godot::String above = root + godot::String("../") + relative;
        if (godot::FileAccess::file_exists(above))
        {
            return above;
        }

        return beside;
    }
}
