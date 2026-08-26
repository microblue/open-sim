#!/usr/bin/env bash
# OpenRC Simulator - full verification.
#
# Builds the physics core, runs the validation suite, builds the Godot
# extension, and runs the in-engine smoke test. This is the gate: if it passes,
# the flight model and the engine integration are both known good.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
FAILED=0

step() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
pass() { printf '\033[32m ok \033[0m %s\n' "$1"; }

step "Physics core + validation suite"
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null \
  && cmake --build build -j"$(nproc)" >/dev/null \
  && ./build/rcphysics_tests \
  && pass "core" || fail "core"

step "Architectural invariants"
if grep -rqE '#include <godot_cpp|#include "godot' Source/RCPhysics/ 2>/dev/null; then
    fail "RCPhysics has picked up an engine dependency"
else
    pass "RCPhysics is engine-free"
fi
if grep -rlE 'frame::(Position|Vector|Direction|Rotation)' Source/OpenRCSim/ | grep -qv Bridge/; then
    fail "frame conversion has leaked outside Bridge/"
else
    pass "frame conversion is confined to Bridge/"
fi

if [ ! -d ThirdParty/godot-cpp ]; then
    printf '\nSkipping the Godot steps: run scripts/bootstrap.sh first.\n'
    exit $FAILED
fi

step "Godot extension"
cmake -S . -B build-godot -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DRC_BUILD_GODOT_EXTENSION=ON >/dev/null \
  && cmake --build build-godot -j"$(nproc)" >/dev/null \
  && pass "extension built" || fail "extension build"

step "In-engine tests"
# NOTE: `godot --headless --import` aborts at shutdown on Godot 4.7.2 whenever a
# GDExtension registers any class - reproducible with an empty Node3D subclass,
# so it is not our code. The import itself completes and its output is valid, so
# the exit code is deliberately ignored here. See Docs/MILESTONES.md.
rm -rf Godot/.godot
# Run in a nested shell so that shell's job-control report of the abort is
# swallowed with the rest of the output rather than printed here.
bash -c 'godot --headless --path Godot --import; exit 0' >/dev/null 2>&1

OUTPUT="$(godot --headless --path Godot --script res://tests/HeadlessTests.gd 2>&1)"
STATUS=$?
echo "$OUTPUT" | grep -vE '^\s*$|Godot Engine v'
if [ $STATUS -eq 0 ] && echo "$OUTPUT" | grep -q "in-engine tests passed"; then
    pass "in-engine tests"
else
    fail "in-engine tests"
fi

step "First ten seconds"
# The unit tests are each right about their own piece; none of them noticed
# that the glider was reported crashed before the player had touched a stick.
# This one flies every aeroplane in the roster off its own spawn.
LAUNCH="$(godot --headless --path Godot --script res://tests/SpawnCheck.gd 2>&1)"
LAUNCH_STATUS=$?
echo "$LAUNCH" | grep -E '^\s*\[|^\s*first ten'
if [ $LAUNCH_STATUS -eq 0 ]; then
    pass "every aircraft flies from its own spawn"
else
    fail "an aircraft cannot fly from its own spawn"
fi

step "The pilot can see the aeroplane"
# The default camera in a training simulator. The head lags on purpose, and
# nothing measured how far that went until it was measured: 22 % of the time
# out of frame.
if command -v xvfb-run >/dev/null 2>&1; then
    PILOT="$(timeout 240 xvfb-run -a -s "-screen 0 1280x720x24" \
        godot --path Godot --resolution 1280x720 \
        --script res://tests/PilotViewCheck.gd 2>&1)"
    PILOT_STATUS=$?
    echo "$PILOT" | grep -E 'pilot view over'
    if [ $PILOT_STATUS -eq 0 ]; then
        pass "the aeroplane stays in the pilot's view"
    else
        fail "the pilot loses sight of the aeroplane"
    fi
else
    printf '     %s\n' "pilot view skipped (needs xvfb-run)"
fi

step "After a crash"
# A beginner crashes constantly, so this is one of the most-visited screens in
# the product. It used to show a white speck at twenty-eight metres and a power
# panel reading 90 % on a wreck.
if command -v xvfb-run >/dev/null 2>&1; then
    CRASH="$(timeout 300 xvfb-run -a -s "-screen 0 1280x720x24" \
        godot --path Godot --resolution 1280x720 \
        --script res://tests/CrashShot.gd 2>&1)"
    CRASH_STATUS=$?
    echo "$CRASH" | grep -E 'after the crash|the wreck is'
    if [ $CRASH_STATUS -eq 0 ]; then
        pass "the motor stops and the pilot can see the wreck"
    else
        fail "the crash state is wrong"
    fi
else
    printf '     %s\n' "crash state skipped (needs xvfb-run)"
fi

step "Rendering"
if command -v xvfb-run >/dev/null 2>&1; then
    rm -f Godot/shots/0_pilot_ground.png
    timeout 240 xvfb-run -a -s "-screen 0 1280x720x24" \
        godot --path Godot --resolution 1280x720 \
        --script res://tests/Screenshot.gd >/dev/null 2>&1 || true
    if [ -s Godot/shots/0_pilot_ground.png ]; then
        pass "field renders (frames in Godot/shots/)"
    else
        fail "the field did not render"
    fi
else
    printf '     ..   skipped: xvfb-run not installed\n'
fi

printf '\n'
[ $FAILED -eq 0 ] && printf '\033[32mALL CHECKS PASSED\033[0m\n' || printf '\033[31mSOME CHECKS FAILED\033[0m\n'
exit $FAILED
