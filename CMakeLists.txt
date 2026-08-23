# OpenRC Simulator - standalone build of the engine-agnostic physics core.
#
# By default this builds ONLY the engine-agnostic physics core and its validation
# suite - no engine, no editor, no GPU, about two seconds. That is what makes the
# regression suite in Docs/MILESTONES.md (Milestone 8) cheap enough to run on
# every change, and it is the fast loop to keep working in.
#
#   cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
#   cmake --build build -j
#   ctest --test-dir build --output-on-failure
#
# Adding -DRC_BUILD_GODOT_EXTENSION=ON additionally builds the Godot GDExtension
# into Godot/bin/. That pulls in godot-cpp and takes minutes rather than seconds,
# which is exactly why it is off by default:
#
#   cmake -S . -B build-godot -DRC_BUILD_GODOT_EXTENSION=ON
#   cmake --build build-godot -j
#
cmake_minimum_required(VERSION 3.16)
project(OpenRCSim LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

option(RC_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" ON)

add_library(rc_compile_options INTERFACE)
if(MSVC)
    target_compile_options(rc_compile_options INTERFACE /W4 /permissive-)
    if(RC_WARNINGS_AS_ERRORS)
        target_compile_options(rc_compile_options INTERFACE /WX)
    endif()
else()
    target_compile_options(rc_compile_options INTERFACE
        -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wsign-conversion
        -Wnon-virtual-dtor -Wold-style-cast -Wdouble-promotion)
    if(RC_WARNINGS_AS_ERRORS)
        target_compile_options(rc_compile_options INTERFACE -Werror)
    endif()
endif()

# ---------------------------------------------------------------------------
# rcphysics - the engine-agnostic core.
#
# Everything under Private/UE/ is Unreal glue (IMPLEMENT_MODULE and friends) and
# is excluded here; UnrealBuildTool compiles it, this build must not.
# ---------------------------------------------------------------------------
file(GLOB_RECURSE RCPHYSICS_SOURCES CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/Source/RCPhysics/Private/*.cpp")
list(FILTER RCPHYSICS_SOURCES EXCLUDE REGEX "/Source/RCPhysics/Private/UE/")

file(GLOB_RECURSE RCPHYSICS_HEADERS CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/Source/RCPhysics/Public/*.h")

add_library(rcphysics STATIC ${RCPHYSICS_SOURCES} ${RCPHYSICS_HEADERS})
target_include_directories(rcphysics PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/Source/RCPhysics/Public")
target_link_libraries(rcphysics PRIVATE rc_compile_options)

# The same objects are linked into the shared GDExtension, so they must be
# position independent even when this static library is built on its own.
set_target_properties(rcphysics PROPERTIES POSITION_INDEPENDENT_CODE ON)

# ---------------------------------------------------------------------------
# rcphysics_tests - the validation and regression suite.
# ---------------------------------------------------------------------------
file(GLOB_RECURSE RCPHYSICS_TEST_SOURCES CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/Tests/*.cpp")

add_executable(rcphysics_tests ${RCPHYSICS_TEST_SOURCES})
target_include_directories(rcphysics_tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/Tests")
target_link_libraries(rcphysics_tests PRIVATE rcphysics rc_compile_options)

# Data files (aircraft definitions) are located relative to the repository root.
target_compile_definitions(rcphysics_tests PRIVATE
    RC_REPO_ROOT="${CMAKE_CURRENT_SOURCE_DIR}")

enable_testing()
add_test(NAME physics_core COMMAND rcphysics_tests)

# ---------------------------------------------------------------------------
# openrcsim - the Godot GDExtension.
#
# Off by default. The physics core must never depend on this target; if the
# default build ever needs godot-cpp, an engine dependency has leaked into
# RCPhysics and that is the bug.
# ---------------------------------------------------------------------------
option(RC_BUILD_GODOT_EXTENSION "Build the Godot GDExtension into Godot/bin/" OFF)

if(RC_BUILD_GODOT_EXTENSION)
    if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/godot-cpp/CMakeLists.txt")
        message(FATAL_ERROR
            "godot-cpp is missing. Run scripts/bootstrap.sh to fetch it.")
    endif()

    # Godot 4.7's API surface is identical to the 4.7.0 bindings shipped with
    # godot-cpp; only the patch version string differs. Verified by dumping
    # extension_api.json from the installed engine and diffing it structurally.
    set(GODOTCPP_API_VERSION "4.7" CACHE STRING "Godot API version to bind against")
    set(GODOTCPP_TARGET "template_debug" CACHE STRING "template_debug | template_release | editor")
    set(GODOTCPP_USE_HOT_RELOAD ON CACHE BOOL "Allow the editor to reload the extension")

    add_subdirectory(ThirdParty/godot-cpp godot-cpp EXCLUDE_FROM_ALL)

    # Treat godot-cpp's headers as system headers. Its generated bindings emit
    # hundreds of -Wunused-parameter warnings from virtual stubs, which would
    # otherwise bury any warning in OUR code - and a warning you cannot see is
    # the same as no warning at all. This lets the extension keep the same
    # strict flag set as the core.
    get_target_property(RC_GODOTCPP_INCLUDES godot-cpp INTERFACE_INCLUDE_DIRECTORIES)
    if(RC_GODOTCPP_INCLUDES)
        set_target_properties(godot-cpp PROPERTIES
            INTERFACE_SYSTEM_INCLUDE_DIRECTORIES "${RC_GODOTCPP_INCLUDES}")
    endif()

    file(GLOB_RECURSE OPENRCSIM_SOURCES CONFIGURE_DEPENDS
         "${CMAKE_CURRENT_SOURCE_DIR}/Source/OpenRCSim/*.cpp")

    add_library(openrcsim SHARED ${OPENRCSIM_SOURCES})
    target_link_libraries(openrcsim PRIVATE rcphysics godot::cpp rc_compile_options)

    # Godot resolves the library by filename, so the name must encode platform,
    # build target and architecture exactly as Godot/openrcsim.gdextension says.
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        set(RC_GODOT_PLATFORM "linux")
    elseif(WIN32)
        set(RC_GODOT_PLATFORM "windows")
    elseif(APPLE)
        set(RC_GODOT_PLATFORM "macos")
    else()
        message(FATAL_ERROR "Unsupported platform for the GDExtension: ${CMAKE_SYSTEM_NAME}")
    endif()

    set_target_properties(openrcsim PROPERTIES
        OUTPUT_NAME "openrcsim.${RC_GODOT_PLATFORM}.${GODOTCPP_TARGET}.x86_64"
        PREFIX "lib"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/Godot/bin")

    message(STATUS "GDExtension: Godot/bin/lib$<TARGET_PROPERTY:openrcsim,OUTPUT_NAME>")
endif()
