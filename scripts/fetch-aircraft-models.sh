#!/usr/bin/env bash
# OpenRC Simulator - fetch the aircraft airframe models.
#
# The visible aeroplanes used to be generated from the flight model's own
# geometry: a fuselage lofted between stations, a wing lofted through the
# aerodynamic sections. That guaranteed the thing you saw was the thing that
# was flying, and it looked like what it was - an aeroplane assembled out of
# primitives.
#
# These are models of real aeroplanes, scaled to the span the definition
# declares. See Docs/ASSETS.md for what that trades away.
#
# Every model here is CC-BY-4.0: free to use commercially, attribution
# required. The attribution is not optional and not a formality - it is the
# licence. Each model keeps its own LICENSE.txt beside it, and Docs/ASSETS.md
# carries the credits. Nothing under a NonCommercial licence is used, however
# good it looks: this project cannot accept that restriction on its behalf.
#
# Usage:  scripts/fetch-aircraft-models.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/ThirdParty/aircraft-models"

# name | source repo | directory within it | file to take
MODELS=(
  "cessna172|walids2003/APEX|Airplane_model/cessna_kog| cessna172_named.glb"
  "sailplane|albertkemp/JSFS|Assets/glTF/underpoly_free_sailplane_glider|scene.gltf"
  "mustang|KieArm/airplane-game|public/models/p-51|scene.glb"
  "spitfire|Mafo369/OpenGLDemos|Assets/soviet_trainer_spitfire|scene.gltf"
  "biplane|theringsofsaturn/3D-sky-island-portfolio-threejs-react|src/assets/aircarft_biplane|scene-transformed.glb"
)

fetch_file() {
    local repo="$1" path="$2" out="$3" url
    url="$(gh api "repos/$repo/contents/$path" --jq '.download_url' 2>/dev/null || true)"
    if [ -z "$url" ] || [ "$url" = "null" ]; then
        echo "  !! cannot resolve $repo/$path" >&2
        return 1
    fi
    curl -sSL -o "$out" "$url"
}

for entry in "${MODELS[@]}"; do
    IFS='|' read -r name repo dir file <<< "$entry"
    echo "== $name"
    mkdir -p "$DEST/$name"
    if [ -s "$DEST/$name/LICENSE.txt" ] \
       && [ -n "$(find "$DEST/$name" -name '*.glb' -o -name '*.gltf' | head -1)" ]; then
        echo "  already present"
        continue
    fi
    # The licence first. A model without its licence beside it is a model this
    # project will not ship.
    fetch_file "$repo" "$dir/license.txt" "$DEST/$name/LICENSE.txt"
    grep -E "title|author|license type" "$DEST/$name/LICENSE.txt" | sed 's/^/  /'
    if ! grep -q "CC-BY-4.0" "$DEST/$name/LICENSE.txt"; then
        echo "  !! not CC-BY-4.0 - refusing to vendor it" >&2
        rm -rf "${DEST:?}/$name"
        continue
    fi

    fetch_file "$repo" "$dir/$file" "$DEST/$name/$(basename "$file" | sed 's/^ //')"
    # A .gltf needs its buffer and its textures alongside.
    if [[ "$file" == *.gltf ]]; then
        fetch_file "$repo" "$dir/scene.bin" "$DEST/$name/scene.bin" || true
        gh api "repos/$repo/contents/$dir/textures" --jq '.[].name' 2>/dev/null \
        | while read -r tex; do
            [ -n "$tex" ] || continue
            mkdir -p "$DEST/$name/textures"
            fetch_file "$repo" "$dir/textures/$tex" "$DEST/$name/textures/$tex" || true
        done
    fi
    du -sh "$DEST/$name" | sed 's/^/  /'
done

echo
echo "Fetched into ThirdParty/aircraft-models/."
echo "Next:  scripts/build-aircraft-models.sh"
