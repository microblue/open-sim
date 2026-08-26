# Assets

## The aeroplanes

The four airframes used to be **generated** — a fuselage lofted between
stations, a wing lofted through the aerodynamic sections the flight model
integrates over. That had one large virtue: what you saw was, exactly and
provably, what was flying. It also looked like what it was, which is an
aeroplane assembled out of primitives.

Two of them are now real models of real aeroplanes:

| Aircraft | Model | Author | Licence |
| --- | --- | --- | --- |
| Trainer 1500 | [Cessna172](https://sketchfab.com/3d-models/cessna172-d1b15841c29c43d0862667300bad55a4) | [KOG_THORNS](https://sketchfab.com/ioai25312) | CC-BY-4.0 |
| Glider 2400 | [UNDERPOLY: Free Sailplane Glider](https://sketchfab.com/3d-models/underpoly-free-sailplane-glider-4b1e6ac35d9c4e9a9f9d1a52d1b0ee73) | [UNDERPOLY Project](https://sketchfab.com/underpolyproject) | CC-BY-4.0 |

> This work is based on "Cessna172" by KOG_THORNS, and on "UNDERPOLY: Free
> Sailplane Glider" by UNDERPOLY Project, both licensed under
> [CC-BY-4.0](http://creativecommons.org/licenses/by/4.0/).

**The attribution is the licence, not a courtesy.** Each model keeps its own
`AIRFRAME-LICENSE.txt` next to it in `Godot/aircraft/<Name>/`, and the fetch
script refuses to vendor anything that is not CC-BY-4.0 — including models that
are only NonCommercial, however good they look. This project cannot accept that
restriction on a user's behalf.

```bash
scripts/fetch-aircraft-models.sh     # download them with their licences
scripts/build-aircraft-models.sh     # 1024 px textures, welded, deduplicated
```

Sport 1200 and Warbird 1100 still use the generated airframe, because no
suitably licensed low-wing aerobat or warbird has been found. Both paths are
live: `AircraftModel.gd` loads `airframe.glb` if there is one and generates the
aeroplane if there is not, so adding a model for either is a fetch and a build.

### What this trades away

A downloaded model is a **different aeroplane**. The Cessna 172 is eleven
metres across and this trainer is one and a half; the planform, the tail volume
and the dihedral are the real Cessna's, not the definition's. Two things keep
it honest:

- **The span is fitted to the definition**, always. The flight model computes
  lift over a 1.5 m wing, and a visible wing of any other size would be lying
  about the aeroplane.
- **Nothing about the flight model changed.** The aerodynamics still integrates
  over the sections in `Data/Aircraft/*.json`. The model is a shell.

What is lost is moving control surfaces. The generated aeroplane hinged every
aileron, elevator and rudder off the section the flight model was deflecting;
a downloaded airframe is one mesh and has no separable ones. The propeller
still turns, where the model names it.

### Fitting a model

Two things have to be told to the loader, in `Godot/aircraft/<Name>/airframe.json`,
and both are properties of the FILE rather than of the aeroplane:

- `rotation_deg` — which way it faces. Both models here arrive nose-along-+X
  with their span down Z, and want a quarter turn.
- `hide_nodes` — what came with it that is not the aeroplane. The Cessna ships
  sitting on a museum display plinth.

The **scale is not configurable**, and deliberately so. It is measured from the
vertices: every visible vertex, sorted across the span, with the outermost
tenth of a percent at each end discarded. A bounding box was tried first and
does not survive contact with real files — this model's `main_gear_left` mesh
carries a stray vertex eleven hundred units out when the whole aeroplane is six
hundred and eighty long, which made the measured span 16.3 m on an 11 m
aircraft and drew the aeroplane at three quarters of its size. One loose vertex
nobody will ever see does not get to decide how big the aeroplane is.

## Scenery

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

## Impostors

```bash
godot --path Godot --script res://tools/BakeImpostors.gd
```

Renders each tree from eight angles into one atlas, and writes the metrics the
renderer needs beside it. The scatter then draws a two-triangle quad that turns
to face the camera about the vertical and picks the view nearest to how the
camera is looking at it — a photograph of a real scanned tree, from any
direction, for the cost of a quad.

Two things had to be got right:

**Bake from a canopy, not from a LOD.** The first run baked from
`<name>_lod0.glb`, whose leaves the decimation had already removed, and produced
eight beautiful photographs of a bare trunk. `build-assets.sh` now emits a third
output, `<name>_bake.glb`, at an error tight enough to keep the canopy whole. It
is never instanced — it is rendered exactly eight times in its life.

**The corner comes from UV, not from VERTEX.** Under `world_vertex_coords` the
incoming vertex has already been through the model matrix, so it is a world
position rather than the unit quad the billboard needs. Reading it as local put
every card somewhere else entirely and the whole forest vanished.

Ground cover is deliberately not impostored. A card is convincing exactly as
long as its lack of parallax does not show, and grass is under the aircraft on
every landing.

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

This is why trees are drawn as impostors rather than geometry — see above.
`DetailAssets.SPECIES` lists the kinds instanced as real meshes;
`DetailAssets.IMPOSTORS` lists the kinds drawn as billboards. Anything in
neither uses the generated shapes.

## The sky

`kloofendal_43d_clear_puresky` is a captured HDRI, used both as the visible sky
and as the scene's light source. Image-based lighting from a real sky is most of
what separates a rendered scene from a lit one: the shadow side of an object
picks up the blue of the sky above it and the green of the ground beneath it,
which no ambient colour reproduces. The directional light is aimed to agree with
where the sun actually is in the capture — a sun that disagrees with its own sky
is immediately readable.
