#!/usr/bin/env bash
# OpenRC Simulator - fetch the third-party dependency needed for the Godot build.
#
# The physics core and its tests need NOTHING from here; they build with a bare
# C++17 toolchain. This is only required for -DRC_BUILD_GODOT_EXTENSION=ON.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_CPP_DIR="$REPO_ROOT/ThirdParty/godot-cpp"

# Pinned so that a fresh clone builds the same bindings we tested against.
GODOT_CPP_COMMIT="9c8aeff0f58ad030f3d1030e8262de1322cd0ccd"

if [ -d "$GODOT_CPP_DIR/.git" ]; then
    echo "godot-cpp already present at $GODOT_CPP_DIR"
else
    echo "Fetching godot-cpp into $GODOT_CPP_DIR"
    git clone --filter=blob:none https://github.com/godotengine/godot-cpp.git "$GODOT_CPP_DIR"
fi

git -C "$GODOT_CPP_DIR" fetch --depth 1 origin "$GODOT_CPP_COMMIT" 2>/dev/null || true
git -C "$GODOT_CPP_DIR" checkout --quiet "$GODOT_CPP_COMMIT"
echo "godot-cpp at $(git -C "$GODOT_CPP_DIR" rev-parse --short HEAD)"

echo
echo "Next:"
echo "  cmake -S . -B build-godot -DRC_BUILD_GODOT_EXTENSION=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo"
echo "  cmake --build build-godot -j"
