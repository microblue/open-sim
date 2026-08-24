# Assets

Everything in `Godot/assets/` is CC0, from [Poly Haven](https://polyhaven.com) —
no attribution required, no restriction on use. None of it is committed: it is
about two gigabytes of photogrammetry. What is committed is
`Data/Assets/manifest.json`, so any checkout can reproduce the exact set.

```bash
scripts/fetch-assets.sh     # download the set named in the manifest  (~2 GB)
scripts/build-assets.sh     # decimate it into game-ready LODs        (~45 MB)
```

The simulator runs without either. Everything falls back to the generated
meshes and the procedural sky, which is what the test suite exercises and what
someone gets before they have run the scripts.

## Why there are two steps

Poly Haven's models are film and archviz assets. `pine_tree_01` arrives as
**seventeen million triangles** with twelve 2K textures — sixty times the entire
triangle budget of a frame, for one tree. They are exactly the right source
material, real scanned geometry and real surface data, and completely unusable
as they come.

`build-assets.sh` welds, decimates and repacks each one into two levels:

| | |
|---|---|
| `lod0` | passed close — a tree the aircraft goes by at fifty metres |
| `lod1` | a silhouette on a hillside |

The order matters. Photogrammetry exports split vertices at every UV seam, and
the simplifier cannot collapse an edge whose two sides are separate vertices —
without welding first the decimation stalls far above its target. Textures are
resized last, and that step is where nearly all the file size goes: one tree
went from 59 MB to 2 MB on it alone.

## Decimation is bounded by error, not by triangle count

This matters enormously for foliage and is the single thing that took longest to
get right.

Leaves in a scan are thousands of separate alpha-cut cards. Collapsing an edge
between two of them does not simplify a leaf — it destroys both, and a general
simplifier has no way to know the difference. Driving the simplifier to a
triangle count with a loose error bound produced trees that rendered as a cloud
of loose triangles hanging in the air where the canopy had been.

Bounding it by error instead makes it refuse those collapses. The trunk and
branches then decimate freely around the leaves, and each model lands at
whatever count preserves it.

## What foliage still needs

There is no error bound that makes a scanned tree instanceable:

| error | island_tree_02 | canopy |
|---|---|---|
| 0.001 | 131,477 triangles | intact |
| 0.004 | 9,264 triangles | destroyed |

There is nothing between the two. Bark, bare wood and rock have no such
problem — a boulder at 1,200 triangles is indistinguishable from the scan at
98,000 — so those are used as they are, and `DetailAssets.SPECIES` lists exactly
the kinds whose geometry survives.

The answer for foliage is **impostors**: render each tree offline from a ring of
angles and instance a billboard that picks the nearest view. That is how flight
simulators draw a forest, it is a separate piece of work, and until it exists
foliage uses the generated meshes — honest low-poly shapes rather than broken
high-poly ones.

## The sky

`kloofendal_43d_clear_puresky` is a captured HDRI, used both as the visible sky
and as the scene's light source. Image-based lighting from a real sky is most of
what separates a rendered scene from a lit one: the shadow side of an object
picks up the blue of the sky above it and the green of the ground beneath it,
which no ambient colour reproduces. The directional light is aimed to agree with
where the sun actually is in the capture — a sun that disagrees with its own sky
is immediately readable.
