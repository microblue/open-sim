#include "RCDataPaths.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/os.hpp>
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
        // the repository and the executable's directory in an exported build.
        // A macOS .app keeps its data in Contents/Resources instead, and the
        // executable directory is checked too in case res:// points elsewhere.
        // For each base, the path itself and one level up; the first that
        // exists wins.
        godot::ProjectSettings* settings = godot::ProjectSettings::get_singleton();
        const godot::String root = (settings != nullptr)
                                 ? settings->globalize_path("res://")
                                 : godot::String("./");

        godot::PackedStringArray bases;
        bases.push_back(root);
        if (godot::OS* os = godot::OS::get_singleton())
        {
            const godot::String exe = os->get_executable_path().get_base_dir() + godot::String("/");
            bases.push_back(exe);
            bases.push_back(exe + godot::String("../Resources/"));
        }

        // Files AND directories. Checking only for a file meant asking for
        // "Data/Aircraft" - a directory - always fell through to the installed
        // candidate, so the hangar listed no aeroplanes at all.
        const godot::String beside = root + relative;
        for (const godot::String& base : bases)
        {
            if (Exists(base + relative))
            {
                return base + relative;
            }
            if (Exists(base + godot::String("../") + relative))
            {
                return base + godot::String("../") + relative;
            }
        }

        return beside;
    }
}
