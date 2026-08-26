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
  "mustang|scene.glb|Warbird1100"
  # A Spitfire standing in for the low-wing aerobat. Not what a Sport 1200
  # is, but it is a low-wing single with a lot of power and a short span,
  # which is what the definition flies like.
  "spitfire|scene.gltf|Sport1200"
  "biplane|scene-transformed.glb|Biplane1300"
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

    # Each step is allowed to fail without losing the model. The P-51 carries a
    # JPEG with a corrupt marker table that the resizer will not open; a model
    # that ships with 2K textures is a great deal better than no model.
    step() {
        local from="$1" to="$2"; shift 2
        if $GLTF "$@" "$from" "$to" >/dev/null 2>&1; then
            return 0
        fi
        echo "   (skipped $1 - $GLTF could not process it)" >&2
        cp "$from" "$to"
    }
    step "$SRC/$dir/$file" "$tmp/resized.glb" resize --width 1024 --height 1024
    step "$tmp/resized.glb" "$tmp/welded.glb" weld
    step "$tmp/welded.glb" "$out/airframe.glb" dedup

    # The licence travels with the model. Without it we have no right to ship.
    cp "$SRC/$dir/LICENSE.txt" "$out/AIRFRAME-LICENSE.txt"

    before="$(du -h "$SRC/$dir/$file" | cut -f1)"
    after="$(du -h "$out/airframe.glb" | cut -f1)"
    echo "   $before -> $after   $out/airframe.glb"
    rm -rf "$tmp"
done

echo
echo "Built. The aircraft model loader picks these up automatically."
