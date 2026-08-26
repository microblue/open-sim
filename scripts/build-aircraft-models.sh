#!/usr/bin/env bash
# OpenRC Simulator - turn the fetched airframe models into game assets.
#
# What comes off Sketchfab is a studio model: 4K textures, a modelled interior,
# a few hundred thousand triangles. What the game needs is an aeroplane that is
# never more than a couple of hundred pixels across except on the hangar
# turntable. So the textures come down to 1024 and the buffers are welded and
# deduplicated - but the geometry is NOT decimated. These are hard-surface
# models: a decimator that does no harm to a tree canopy puts creases down the
# middle of a cowling, and the whole point of using a real model is the shape.
#
# Usage:  scripts/build-aircraft-models.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ThirdParty/aircraft-models"
GLTF="npx --yes @gltf-transform/cli@4.4.2"

# source directory | source file | destination aircraft directory
BUILDS=(
  "cessna172|cessna172_named.glb|Trainer1500"
  "sailplane|scene.gltf|Glider2400"
)

[ -d "$SRC" ] || { echo "Run scripts/fetch-aircraft-models.sh first." >&2; exit 1; }
command -v npx >/dev/null 2>&1 || { echo "npx not found (nvm)." >&2; exit 1; }

for entry in "${BUILDS[@]}"; do
    IFS='|' read -r dir file aircraft <<< "$entry"
    [ -f "$SRC/$dir/$file" ] || { echo "== $aircraft: no source, skipped"; continue; }
    echo "== $aircraft  <-  $dir/$file"

    out="$ROOT/Godot/aircraft/$aircraft"
    mkdir -p "$out"
    tmp="$(mktemp -d)"

    $GLTF resize "$SRC/$dir/$file" "$tmp/resized.glb" \
        --width 1024 --height 1024 >/dev/null
    $GLTF weld "$tmp/resized.glb" "$tmp/welded.glb" >/dev/null
    $GLTF dedup "$tmp/welded.glb" "$out/airframe.glb" >/dev/null

    # The licence travels with the model. Without it we have no right to ship.
    cp "$SRC/$dir/LICENSE.txt" "$out/AIRFRAME-LICENSE.txt"

    before="$(du -h "$SRC/$dir/$file" | cut -f1)"
    after="$(du -h "$out/airframe.glb" | cut -f1)"
    echo "   $before -> $after   $out/airframe.glb"
    rm -rf "$tmp"
done

echo
echo "Built. The aircraft model loader picks these up automatically."
