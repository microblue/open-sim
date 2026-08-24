#!/usr/bin/env bash
# OpenRC Simulator - turn the downloaded photogrammetry into game assets.
#
# Poly Haven's models are film and archviz assets: pine_tree_01 arrives as
# seventeen million triangles with twelve 2K textures, sixty times the entire
# triangle budget of a frame. They are exactly the right source material - real
# scanned geometry, real surface data - and completely unusable as they come.
#
# This decimates each one to a few thousand triangles and packs its textures to
# a size matching what it occupies on screen, writing a .glb the renderer can
# instance thousands of times. Two levels per model:
#
#   lod0  passed close - a tree the aircraft goes by at fifty metres
#   lod1  a silhouette on a hillside
#
# Three steps, and the order matters:
#
#   weld      photogrammetry exports split vertices at every UV seam, and the
#             simplifier cannot collapse an edge whose sides are separate
#             vertices. Without this the decimation stalls far above target.
#   simplify  meshoptimizer, bounded by a geometric ERROR rather than driven to
#             a triangle count. This matters enormously for foliage: leaves are
#             separate alpha-cut cards, and collapsing an edge across two of
#             them does not simplify a leaf, it destroys both. Given a tight
#             error bound the simplifier refuses those collapses and stops -
#             a tree lands at whatever count preserves its leaves, and the
#             trunk and branches decimate freely around them.
#
#             The first version drove this by ratio with a loose error, and
#             every tree came out as a cloud of loose triangles hanging in the
#             air where its canopy had been.
#   resize    the textures, which is where nearly all the file size is: a tree
#             went from 59 MB to 2 MB on this step alone.
#
# Run after scripts/fetch-assets.sh. Output is Godot/assets/lod/, not committed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Godot/assets/models"
OUT="$ROOT/Godot/assets/lod"

# nvm-installed node is not on a non-interactive PATH.
if [ -d "$HOME/.nvm/versions/node" ]; then
    NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | tail -1)"
    [ -n "$NODE_BIN" ] && PATH="$NODE_BIN:$PATH"
fi
export PATH

CLI="@gltf-transform/cli@4.4.2"

info() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m ok \033[0m %s\n' "$*"; }
warn() { printf '\033[33m -- \033[0m %s\n' "$*"; }

# name  lod0_error  lod1_error  lod0_texture
#
# Error is in units of the model's own size, so 0.001 is a millimetre on a metre.
# Foliage needs the tight end; a boulder is a lump and tolerates two orders more.
# A tree carries its shape in its branches and needs more triangles than a rock
# at the same screen size; a boulder is a lump and decimates almost for free.
TARGETS=(
    "fir_tree_01            0.0030  0.015  1024"
    "pine_tree_01           0.0035  0.018  1024"
    "island_tree_02         0.0040  0.020  1024"
    "jacaranda_tree         0.0050  0.022  1024"
    "dead_tree_trunk        0.0060  0.030  1024"
    "tree_stump_01          0.0080  0.040   512"
    "namaqualand_boulder_02 0.0100  0.050   512"
    "namaqualand_boulder_04 0.0100  0.050   512"
    "grass_medium_01        0.0060  0.025   512"
    "grass_medium_02        0.0060  0.025   512"
    "wild_rooibos_bush      0.0050  0.022   512"
    "fern_02                0.0040  0.018   512"
)

count_triangles() {
    python3 - "$1" <<'PY'
import json, os, struct, sys
path = sys.argv[1]
if path.endswith(".glb"):
    with open(path, "rb") as handle:
        handle.read(12)
        length, _kind = struct.unpack("<II", handle.read(8))
        document = json.loads(handle.read(length))
else:
    document = json.load(open(path))
total = 0
for mesh in document.get("meshes", []):
    for primitive in mesh.get("primitives", []):
        indices = primitive.get("indices")
        if indices is not None:
            total += document["accessors"][indices]["count"] // 3
print(total)
PY
}

mkdir -p "$OUT"
command -v npx >/dev/null || { echo "npx not found; install Node." >&2; exit 1; }

for entry in "${TARGETS[@]}"; do
    read -r name lod0_error lod1_error texture <<< "$entry"
    input="$SOURCE/$name/$name.gltf"
    if [ ! -f "$input" ]; then
        warn "$name not fetched - run scripts/fetch-assets.sh"
        continue
    fi

    source_triangles="$(count_triangles "$input")"
    info "=== $name  (${source_triangles} triangles) ==="

    welded="$OUT/.$name.welded.glb"
    if [ ! -f "$welded" ]; then
        npx --yes "$CLI" weld "$input" "$welded" >/dev/null 2>&1
    fi

    for level in 0 1; do
        if [ "$level" -eq 0 ]; then error="$lod0_error"; size="$texture"
        else error="$lod1_error"; size=$((texture / 2)); fi

        output="$OUT/${name}_lod${level}.glb"
        if [ -f "$output" ]; then
            ok "$(basename "$output")  (cached)"
            continue
        fi

        simplified="$OUT/.$name.$level.glb"
        # Ratio wide open, error doing the work: the simplifier takes it as far
        # as the error bound allows and no further.
        if ! npx --yes "$CLI" simplify "$welded" "$simplified" \
                --ratio 0.0 --error "$error" >/dev/null 2>&1; then
            warn "simplify failed for $name lod$level"
            continue
        fi
        npx --yes "$CLI" resize "$simplified" "$output" \
            --width "$size" --height "$size" >/dev/null 2>&1 || mv "$simplified" "$output"
        rm -f "$simplified"

        if [ -f "$output" ]; then
            ok "$(basename "$output")  $(count_triangles "$output") tris, $(( $(stat -c%s "$output") / 1024 )) KB"
        fi
    done

    rm -f "$welded"
done

printf '\n\033[32mBuilt.\033[0m  %s in Godot/assets/lod/\n' "$(du -sh "$OUT" | cut -f1)"
