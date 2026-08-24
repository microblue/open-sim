#!/usr/bin/env python3
"""OpenRC Simulator - fetch the CC0 asset set described by Data/Assets/manifest.json.

Poly Haven's API is public and the assets are CC0, so this needs no key and no
account. Nothing here is committed to the repository: the manifest is, so the
set is reproducible, and the several hundred megabytes of photogrammetry are
not.

Stdlib only, on purpose - this has to work from a bare checkout before anything
else is set up.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://api.polyhaven.com"
# The API rejects urllib's default agent.
AGENT = "OpenRCSim/0.1 (asset fetcher; +https://polyhaven.com)"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "Data", "Assets", "manifest.json")
DEST = os.path.join(ROOT, "Godot", "assets")


def strip_comments(text):
    """The manifest is commented, like every other data file in this project."""
    return re.sub(r"^\s*//.*$", "", text, flags=re.M)


def get_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def download(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return 0
    os.makedirs(os.path.dirname(path), exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": AGENT})
    with urllib.request.urlopen(request, timeout=300) as response:
        data = response.read()
    # Written via a temporary name so an interrupted run cannot leave a
    # half-file that the next run then skips as already present.
    temporary = path + ".part"
    with open(temporary, "wb") as handle:
        handle.write(data)
    os.replace(temporary, path)
    return len(data)


def pick(node, *keys):
    """First present key, so a texture that calls its map 'Diffuse' and one that
    calls it 'diffuse' both work."""
    for key in keys:
        if isinstance(node, dict) and key in node:
            return node[key]
    return None


def fetch_hdri(entry, report):
    files = get_json("%s/files/%s" % (API, entry["name"]))
    node = pick(files, "hdri")
    if node is None:
        report("  ! %s: no hdri in file list" % entry["name"])
        return 0
    res = node.get(entry["res"]) or node.get("4k") or node.get("2k")
    url = pick(res or {}, "hdr", "exr")
    if not url:
        report("  ! %s: no hdr at %s" % (entry["name"], entry["res"]))
        return 0
    path = os.path.join(DEST, "hdri", "%s.hdr" % entry["name"])
    size = download(url["url"], path)
    report("  hdri/%s.hdr  %s" % (entry["name"], "%.1f MB" % (size / 1e6) if size else "cached"))
    return size


# The maps we use, in Poly Haven's naming. Anything else in the set is ignored.
MAPS = {
    "Diffuse": "albedo",
    "nor_gl": "normal",      # OpenGL convention, which is Godot's
    "Rough": "roughness",
    "AO": "ao",
    "Displacement": "height",
}


def fetch_texture(entry, report):
    files = get_json("%s/files/%s" % (API, entry["name"]))
    total = 0
    for source, local in MAPS.items():
        node = files.get(source)
        if node is None:
            continue
        res = node.get(entry["res"]) or node.get("2k") or node.get("1k")
        if not res:
            continue
        # jpg where it will do, png where precision matters.
        file_entry = pick(res, "jpg", "png", "exr")
        if not file_entry:
            continue
        extension = ".jpg" if "jpg" in res else (".png" if "png" in res else ".exr")
        path = os.path.join(DEST, "textures", entry["name"], local + extension)
        total += download(file_entry["url"], path)
    report("  textures/%s  %s" % (entry["name"], "%.1f MB" % (total / 1e6) if total else "cached"))
    return total


def fetch_model(entry, report):
    files = get_json("%s/files/%s" % (API, entry["name"]))
    node = pick(files, "gltf", "glTF")
    if node is None:
        report("  ! %s: no gltf in file list" % entry["name"])
        return 0
    res = node.get(entry["res"]) or node.get("2k") or node.get("1k")
    if not res:
        report("  ! %s: no gltf at %s" % (entry["name"], entry["res"]))
        return 0
    main = pick(res, "gltf")
    if not main:
        report("  ! %s: gltf entry has no file" % entry["name"])
        return 0

    base = os.path.join(DEST, "models", entry["name"])
    total = download(main["url"], os.path.join(base, "%s.gltf" % entry["name"]))

    # A glTF references its buffers and textures by relative path; the API lists
    # them under "include" keyed by exactly that path.
    for relative, included in (main.get("include") or {}).items():
        url = included.get("url") if isinstance(included, dict) else None
        if not url:
            continue
        total += download(url, os.path.join(base, relative))

    report("  models/%s  %s" % (entry["name"], "%.1f MB" % (total / 1e6) if total else "cached"))
    return total


def main():
    with open(MANIFEST) as handle:
        manifest = json.loads(strip_comments(handle.read()))

    only = sys.argv[1] if len(sys.argv) > 1 else None
    print("OpenRC Simulator - fetching CC0 assets from %s" % manifest["source"])
    print("Licence: %s. Destination: Godot/assets/ (not committed)\n" % manifest["licence"])

    total = 0
    plan = [("hdris", fetch_hdri), ("textures", fetch_texture), ("models", fetch_model)]
    for key, handler in plan:
        if only and only != key:
            continue
        entries = manifest.get(key, [])
        if not entries:
            continue
        print("%s (%d)" % (key, len(entries)))
        for entry in entries:
            try:
                total += handler(entry, print)
            except urllib.error.HTTPError as error:
                print("  ! %s: HTTP %s" % (entry["name"], error.code))
            except Exception as error:                      # noqa: BLE001
                print("  ! %s: %s" % (entry["name"], error))
        print("")

    print("fetched %.0f MB this run" % (total / 1e6))
    return 0


if __name__ == "__main__":
    sys.exit(main())
