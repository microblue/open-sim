#!/usr/bin/env bash
# OpenRC Simulator - build the standalone `opensim` application.
#
# Produces dist/ holding a self-contained executable and the loose Data/
# directory it reads:
#
#   dist/opensim              the application - no Godot installation needed
#   dist/Data/Aircraft/*.json aircraft definitions, still hand-editable
#   dist/Data/Input/Profiles  built-in transmitter bindings
#
# Data/ stays loose on purpose: tuning means editing the aircraft JSON and
# reloading it in place with F5, and the offline validation suite reads the very
# same files. Packing it into the executable would end both.
#
# Usage:  scripts/package.sh [--install]
#   --install  also link ~/.local/bin/opensim and add a desktop entry
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
GODOT="${GODOT:-godot}"
PRESET="Linux"

info() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m ok \033[0m %s\n' "$*"; }
die()  { printf '\033[31mfail\033[0m %s\n' "$*" >&2; exit 1; }

command -v "$GODOT" >/dev/null || die "godot not on PATH (set GODOT=/path/to/godot)"

TEMPLATE_DIR="$HOME/.local/share/godot/export_templates"
GODOT_VERSION="$("$GODOT" --version | head -1 | cut -d. -f1-3)"
[ -d "$TEMPLATE_DIR/$GODOT_VERSION.stable" ] \
  || die "export templates for $GODOT_VERSION missing. Install them from
       https://github.com/godotengine/godot/releases into $TEMPLATE_DIR/"

# ---------------------------------------------------------------- the core --
info "=== Physics core ==="
cmake -S "$ROOT" -B "$ROOT/build" -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null
cmake --build "$ROOT/build" -j"$(nproc)" >/dev/null
"$ROOT/build/rcphysics_tests" >/dev/null || die "core tests failed - not packaging a broken build"
ok "core tests pass"

# ------------------------------------------------------------ the extension --
# The exported application is a release build, so it loads the template_release
# library named in Godot/openrcsim.gdextension. Building only the debug variant
# would export cleanly and then fail to find the extension at runtime.
info "=== GDExtension (template_release) ==="
cmake -S "$ROOT" -B "$ROOT/build-godot-release" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DRC_BUILD_GODOT_EXTENSION=ON \
      -DGODOTCPP_TARGET=template_release >/dev/null
cmake --build "$ROOT/build-godot-release" -j"$(nproc)" >/dev/null
RELEASE_LIB="$ROOT/Godot/bin/libopenrcsim.linux.template_release.x86_64.so"
[ -f "$RELEASE_LIB" ] || die "release library missing at $RELEASE_LIB"
ok "$(basename "$RELEASE_LIB")"

# ---------------------------------------------------------------- the pack --
info "=== Export ==="
rm -rf "$DIST"
mkdir -p "$DIST"

# Godot needs an import pass before it can export. It aborts at shutdown on
# 4.7.2 whenever a GDExtension registers a class - the import output is valid,
# so the exit code is deliberately ignored here. See Docs/MILESTONES.md.
bash -c "'$GODOT' --headless --path '$ROOT/Godot' --import; exit 0" >/dev/null 2>&1

"$GODOT" --headless --path "$ROOT/Godot" \
         --export-release "$PRESET" "$DIST/opensim" >/dev/null 2>&1 || true
[ -f "$DIST/opensim" ] || die "export produced no binary"
chmod +x "$DIST/opensim"
ok "dist/opensim  ($(du -h "$DIST/opensim" | cut -f1))"

# A GDExtension library cannot be loaded from inside the pack - it has to be a
# real file on disk. Godot's exporter drops it flat beside the binary, but
# openrcsim.gdextension names it as res://bin/..., so it goes in bin/ to match.
mkdir -p "$DIST/bin"
cp "$RELEASE_LIB" "$DIST/bin/"
rm -f "$DIST/$(basename "$RELEASE_LIB")"
ok "dist/bin/$(basename "$RELEASE_LIB")"

cp -r "$ROOT/Data" "$DIST/Data"
ok "dist/Data ($(find "$DIST/Data" -type f | wc -l) files)"

# ------------------------------------------------------------- the install --
if [ "${1:-}" = "--install" ]; then
    info "=== Install ==="
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
    ln -sfn "$DIST/opensim" "$HOME/.local/bin/opensim"
    ok "$HOME/.local/bin/opensim -> dist/opensim"

    cat > "$HOME/.local/share/applications/opensim.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=OpenRC Simulator
Comment=RC flight training simulator
Exec=$DIST/opensim
Path=$DIST
Terminal=false
Categories=Game;Simulation;
DESKTOP
    ok "desktop entry"
fi

printf '\n\033[32mPackaged.\033[0m  Run it with:  %s\n' "$DIST/opensim"
