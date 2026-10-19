#!/usr/bin/env bash
# OpenRC Simulator - build the downloadable packages for Linux, Windows and macOS.
#
#   scripts/release.sh 0.2.0             build dist/*.zip / *.tar.gz
#   scripts/release.sh 0.2.0 --publish   ...and publish them as GitHub release v0.2.0
#
# The Godot extension is native code, so each platform's library is compiled on
# that platform by the `extension` CI workflow; this downloads the newest
# successful run (or EXT_RUN=<run id>). The export itself happens here because
# it needs the CC0 asset set, which is fetched and built locally, not committed.
#
# What a package holds:
#   the game            one executable with the scenes and meshes packed inside
#   the extension       the physics core, beside the executable
#   Data/               aircraft and transmitter definitions, still hand-editable
#   Godot/assets/       sky HDRIs, ground textures and impostor atlases, which
#                       the world reads from disk at load time
#
# On macOS the last two go inside the .app (Contents/Resources) and the bundle
# is ad-hoc signed again afterwards. It is not notarised - that needs a paid
# Apple developer account - so first launch needs right-click > Open.
set -euo pipefail

VERSION="${1:-}"
PUBLISH="${2:-}"
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh <version> [--publish]" >&2; exit 2; }

NAME="OpenRC Simulator"
SLUG="OpenRC-Simulator"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
WORK="$ROOT/build/release"
GODOT="${GODOT:-godot}"
RCODESIGN_VERSION="0.29.0"

info() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m ok \033[0m %s\n' "$*"; }
die()  { printf '\033[31mfail\033[0m %s\n' "$*" >&2; exit 1; }

command -v "$GODOT" >/dev/null || die "godot not on PATH (set GODOT=/path/to/godot)"
command -v gh >/dev/null || die "gh (GitHub CLI) is needed to fetch the CI-built libraries"
[ -d "$ROOT/Godot/assets/hdri" ] || die "assets missing - run scripts/fetch-assets.sh and scripts/build-assets.sh"

# ---------------------------------------------------------------- the core --
info "=== Physics core ==="
cmake -S "$ROOT" -B "$ROOT/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$ROOT/build" -j"$(nproc)" >/dev/null
"$ROOT/build/rcphysics_tests" >/dev/null || die "core tests failed - not packaging a broken build"
ok "core tests pass"

# ------------------------------------------------------- the extension libs --
info "=== Extension libraries (from CI) ==="
RUN="${EXT_RUN:-$(gh run list --workflow extension.yml --status success --limit 1 \
                   --json databaseId -q '.[0].databaseId')}"
[ -n "$RUN" ] || die "no successful 'extension' workflow run - start one with: gh workflow run extension.yml"
RUN_SHA="$(gh run view "$RUN" --json headSha -q .headSha)"
if ! git -C "$ROOT" diff --quiet "$RUN_SHA" HEAD -- Source CMakeLists.txt 2>/dev/null; then
    die "CI run $RUN was built from ${RUN_SHA:0:7}, but Source/ has changed since.
       Push and run: gh workflow run extension.yml"
fi
rm -rf "$WORK/ext"
gh run download "$RUN" -D "$WORK/ext"
mkdir -p "$ROOT/Godot/bin"
find "$WORK/ext" -type f \( -name '*.so' -o -name '*.dll' -o -name '*.dylib' \) \
     -exec cp {} "$ROOT/Godot/bin/" \;
for lib in libopenrcsim.linux.template_release.x86_64.so \
           libopenrcsim.windows.template_release.x86_64.dll \
           libopenrcsim.macos.template_release.universal.dylib; do
    [ -f "$ROOT/Godot/bin/$lib" ] || die "missing $lib in CI run $RUN"
    ok "$lib"
done

# ------------------------------------------------------- the loose payload --
info "=== Payload ==="
PAYLOAD="$WORK/payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD/Godot/assets"
cp -r "$ROOT/Data" "$PAYLOAD/Data"
rm -rf "$PAYLOAD/Data/Assets"     # the fetch manifest, not something the game reads
for dir in hdri impostors; do
    mkdir -p "$PAYLOAD/Godot/assets/$dir"
    find "$ROOT/Godot/assets/$dir" -maxdepth 1 -type f ! -name '*.import' \
         -exec cp {} "$PAYLOAD/Godot/assets/$dir/" \;
done
# Ground textures: only the maps the terrain shader samples.
for layer in "$ROOT"/Godot/assets/textures/*/; do
    name="$(basename "$layer")"
    mkdir -p "$PAYLOAD/Godot/assets/textures/$name"
    for map in albedo normal roughness; do
        [ -f "$layer/$map.jpg" ] && cp "$layer/$map.jpg" "$PAYLOAD/Godot/assets/textures/$name/"
    done
done
cp "$ROOT/LICENSE" "$PAYLOAD/LICENSE.txt"
cat > "$PAYLOAD/README.txt" <<EOF
$NAME $VERSION
https://github.com/microblue/open-sim

An RC flight training simulator. Plug in a transmitter over USB (EdgeTX /
OpenTX joystick mode), or fly from the keyboard. Press H in flight for help.

Data/Aircraft holds the aircraft definitions as plain JSON. They can be edited
while the game runs: press F5 in flight to reload.

Code: MIT License (LICENSE.txt). Sky, ground and vegetation assets: CC0, from
Poly Haven (polyhaven.com).
EOF
ok "payload $(du -sh "$PAYLOAD" | cut -f1)"

# ---------------------------------------------------------------- the pack --
info "=== Import ==="
# Godot 4.7.2 aborts at shutdown whenever a GDExtension registers a class; the
# import output is valid, so the exit code is ignored. See Docs/MILESTONES.md.
bash -c "'$GODOT' --headless --path '$ROOT/Godot' --import; exit 0" >/dev/null 2>&1
ok "imported"

export_preset() {  # <preset> <output file>
    mkdir -p "$(dirname "$2")"
    "$GODOT" --headless --path "$ROOT/Godot" --export-release "$1" "$2" >"$WORK/export-$1.log" 2>&1 || true
    [ -e "$2" ] || die "$1 export produced nothing - see $WORK/export-$1.log"
}

rm -rf "$DIST"
mkdir -p "$DIST"

info "=== Linux ==="
L="$WORK/linux/$SLUG"
rm -rf "$WORK/linux"
export_preset Linux "$L/opensim"
chmod +x "$L/opensim"
cp -r "$PAYLOAD/." "$L/"
tar -C "$WORK/linux" -czf "$DIST/$SLUG-$VERSION-linux-x86_64.tar.gz" "$SLUG"
ok "$SLUG-$VERSION-linux-x86_64.tar.gz  ($(du -h "$DIST/$SLUG-$VERSION-linux-x86_64.tar.gz" | cut -f1))"

info "=== Windows ==="
W="$WORK/windows/$SLUG"
rm -rf "$WORK/windows"
export_preset Windows "$W/$NAME.exe"
cp -r "$PAYLOAD/." "$W/"
(cd "$WORK/windows" && zip -qr -9 "$DIST/$SLUG-$VERSION-windows-x86_64.zip" "$SLUG")
ok "$SLUG-$VERSION-windows-x86_64.zip  ($(du -h "$DIST/$SLUG-$VERSION-windows-x86_64.zip" | cut -f1))"

info "=== macOS ==="
M="$WORK/macos"
rm -rf "$M"
export_preset macOS "$M/export.zip"
(cd "$M" && unzip -q export.zip && rm export.zip)
APP="$M/$NAME.app"
[ -d "$APP" ] || die "no $NAME.app in the macOS export"
cp -r "$PAYLOAD/Data" "$PAYLOAD/Godot" "$APP/Contents/Resources/"

RCODESIGN="$WORK/tools/rcodesign"
if [ ! -x "$RCODESIGN" ]; then
    mkdir -p "$WORK/tools"
    tarball="apple-codesign-$RCODESIGN_VERSION-x86_64-unknown-linux-musl.tar.gz"
    url="https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F$RCODESIGN_VERSION"
    curl -fsSL -o "$WORK/tools/$tarball" "$url/$tarball"
    curl -fsSL -o "$WORK/tools/$tarball.sha256" "$url/$tarball.sha256"
    (cd "$WORK/tools" && echo "$(cut -d' ' -f1 "$tarball.sha256")  $tarball" | sha256sum -c --quiet) \
        || die "rcodesign download failed its checksum"
    tar -C "$WORK/tools" -xzf "$WORK/tools/$tarball"
    cp "$WORK/tools/${tarball%.tar.gz}/rcodesign" "$RCODESIGN"
fi
# Ad-hoc: no identity. Seals the resources added above, so the bundle is not
# reported as damaged.
"$RCODESIGN" sign "$APP" >"$WORK/rcodesign.log" 2>&1 || die "signing failed - see $WORK/rcodesign.log"
cp "$PAYLOAD/README.txt" "$PAYLOAD/LICENSE.txt" "$M/"
cat >> "$M/README.txt" <<'EOF'

macOS: this build is not notarised by Apple. The first time, right-click the
app and choose Open (or System Settings > Privacy & Security > Open Anyway).
If macOS says the app is damaged, run once in Terminal:
    xattr -dr com.apple.quarantine "/Applications/OpenRC Simulator.app"
EOF
(cd "$M" && zip -qry -9 "$DIST/$SLUG-$VERSION-macos-universal.zip" "$NAME.app" README.txt LICENSE.txt)
ok "$SLUG-$VERSION-macos-universal.zip  ($(du -h "$DIST/$SLUG-$VERSION-macos-universal.zip" | cut -f1))"

(cd "$DIST" && sha256sum ./*.zip ./*.tar.gz > SHA256SUMS.txt)

# ------------------------------------------------------------- the release --
if [ "$PUBLISH" = "--publish" ]; then
    info "=== GitHub release v$VERSION ==="
    notes="$ROOT/Docs/releases/v$VERSION.md"
    [ -f "$notes" ] || die "release notes missing: $notes"
    gh release create "v$VERSION" --title "$NAME $VERSION" --notes-file "$notes" \
        "$DIST"/*.zip "$DIST"/*.tar.gz "$DIST/SHA256SUMS.txt"
    ok "published"
fi

printf '\n\033[32mPackaged.\033[0m  %s\n' "$DIST"
ls -la "$DIST"
