#!/usr/bin/env bash
# OpenRC Simulator - fetch the CC0 asset set. See Data/Assets/manifest.json.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/fetch-assets.py" "$@"
