#include "register_types.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "Aircraft/RCSimulationNode.h"
#include "Input/RCInputNode.h"
#include "Bridge/RCGodotLog.h"
#include "RCPhysics/Core/Log.h"

using namespace godot;

void openrcsim_initialize_module(ModuleInitializationLevel level)
{
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE)
    {
        return;
    }

    openrc::InstallGodotLogSink();
    GDREGISTER_CLASS(openrc::RCSimulationNode);
    GDREGISTER_CLASS(openrc::RCInputNode);

    RC_LOG(Core, Info, "OpenRC Simulator extension loaded (physics core %s).",
           "RCPhysics 0.1");
}

void openrcsim_uninitialize_module(ModuleInitializationLevel level)
{
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE)
    {
        return;
    }
    openrc::RemoveGodotLogSink();
}

extern "C"
{
GDExtensionBool GDE_EXPORT openrcsim_library_init(
    GDExtensionInterfaceGetProcAddress getProcAddress,
    const GDExtensionClassLibraryPtr library,
    GDExtensionInitialization* initialization)
{
    GDExtensionBinding::InitObject initObject(getProcAddress, library, initialization);

    initObject.register_initializer(openrcsim_initialize_module);
    initObject.register_terminator(openrcsim_uninitialize_module);
    initObject.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return initObject.init();
}
}
