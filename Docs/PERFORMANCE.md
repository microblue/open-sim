# Performance

## The frame rate measured under Xvfb is not the frame rate

Every rendered frame in this repository is captured through `xvfb-run`, and the
frame time that comes back is dominated by the presentation path rather than by
anything drawn. This was established by bisection rather than assumed, because
it had already caused one round of quality settings to be cut for nothing.

Frame time at 1920x1080, with pieces of the scene removed:

| scene | ms/frame |
|---|---|
| everything | 33.0 |
| no field grass | 34.5 |
| no scattered vegetation | 35.7 |
| no ocean | 36.8 |
| no shadows | 31.5 |
| no streamed terrain | 32.5 |
| **sky, aircraft and HUD only** | **31.4** |

Removing essentially the entire world saves under two milliseconds. Turning off
TAA, MSAA, SSAO, glow, fog and the sky radiance map changes nothing measurable
either.

But the cost does scale with resolution:

| resolution | ms/frame |
|---|---|
| 480 x 270 | 7.5 |
| 960 x 540 | 17.6 |
| 1920 x 1080 | 39.6 |

Content-independent and proportional to pixels is the signature of the readback
and blit through a software X server. `nvidia-smi` reports 100% GPU during these
runs, which is what a pipeline stalled on a full-framebuffer copy looks like
from outside.

**Measure on the real display.** The HUD's own counter, in a window on the
desktop, is the number that means something.

## What that does not excuse

Two real inefficiencies were found while looking, and both are fixed:

**The terrain shader was fetching a hundred and eight textures per pixel.** Six
materials, three maps, two scales and three triplanar projections, multiplied
out - and almost all of them multiplied by a weight of zero, because at any
given point the ground is one or two materials and not six. It now skips a layer
whose weight cannot show, takes the anti-tiling macro sample only for albedo -
it exists to break a grid the eye only finds in colour - and uses a single
projection on ground that reads as flat.

**The detail scatter re-examined every cell every frame.** Several hundred
dictionary entries, walked to discover that nothing needed building. It now only
looks when the camera has moved far enough to change the answer.

## Tools

```bash
godot --path Godot --resolution 1920x1080 --script res://tools/FrameTime.gd
```

Reports the mean frame time over 180 settled frames. The environment variables
listed at the top of that file remove parts of the scene, which is how the table
above was produced. Reach for it before tuning anything: the first three things
cut in this project's history - shadow resolution, multisampling and the
anti-aliasing mode - all turned out to cost nothing that showed.
