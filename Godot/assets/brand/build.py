#!/usr/bin/env python3
"""Generate every brand asset from code: mark, wordmark lockups, app icons, boot splash.

Run from anywhere (no project environment needed; pixi fetches the three packages):

    pixi exec --spec python=3.12 --spec cairosvg --spec fonttools --spec pillow \
        python Godot/assets/brand/build.py

To rename the product, change NAME_* / SUBTITLE below and re-run. The symbol never
depends on the name. Letterforms come from the bundled OFL fonts in assets/fonts and
are converted to outlines, so nothing here needs a font installed.

Concept: the front view of a high-wing trainer, banked, inside the ring of an
attitude indicator. The horizon stays level; the aircraft is what moves - which is
exactly what a pilot learns to read. The ring opens where the wingtips pass through it.
"""
from __future__ import annotations

import io
import math
from pathlib import Path

import cairosvg
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from PIL import Image

HERE = Path(__file__).resolve().parent
FONTS = HERE.parent / "fonts"

# --- Name -------------------------------------------------------------------
NAME_MAIN = "OPEN"        # in TEXT colour
NAME_ACCENT = "RC"        # in ACCENT colour
SUBTITLE = "FLIGHT SIMULATOR"

# --- Palette (ui/UITheme.gd) ----------------------------------------------------
BASE = "#0B0E13"
PANEL = "#141A20"
TEXT = "#E8EFFA"
DIM = "#8C9CB3"
ACCENT = "#4DD6E6"

BANK = -14.0  # degrees; negative = left wing down

# =========================================================================================
# Symbol
# =========================================================================================


def _rot(p, deg, c):
    a = math.radians(deg)
    x, y = p[0] - c[0], p[1] - c[1]
    return (c[0] + x * math.cos(a) - y * math.sin(a), c[1] + x * math.sin(a) + y * math.cos(a))


def _f(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def _poly(pts):
    return "M" + " L".join(f"{_f(x)},{_f(y)}" for x, y in pts) + " Z"


def _rrect(x0, y0, x1, y1, r):
    r = min(r, (x1 - x0) / 2, (y1 - y0) / 2)
    return (f"M{_f(x0 + r)},{_f(y0)} H{_f(x1 - r)} A{_f(r)},{_f(r)} 0 0 1 {_f(x1)},{_f(y0 + r)} "
            f"V{_f(y1 - r)} A{_f(r)},{_f(r)} 0 0 1 {_f(x1 - r)},{_f(y1)} H{_f(x0 + r)} "
            f"A{_f(r)},{_f(r)} 0 0 1 {_f(x0)},{_f(y1 - r)} V{_f(y0 + r)} A{_f(r)},{_f(r)} 0 0 1 {_f(x0 + r)},{_f(y0)} Z")


def _arc(c, r, a0, a1):
    """Arc path from angle a0 to a1 (degrees, clockwise in screen space)."""
    p0 = (c[0] + r * math.cos(math.radians(a0)), c[1] + r * math.sin(math.radians(a0)))
    p1 = (c[0] + r * math.cos(math.radians(a1)), c[1] + r * math.sin(math.radians(a1)))
    large = 1 if (a1 - a0) % 360 > 180 else 0
    return f"M{_f(p0[0])},{_f(p0[1])} A{_f(r)},{_f(r)} 0 {large} 1 {_f(p1[0])},{_f(p1[1])}"


class Plane:
    """Front view of a high-wing tricycle trainer in local units, origin at the nose."""

    def __init__(self, detail: bool):
        self.detail = detail
        if detail:
            self.span = 236          # half span
            self.root_t, self.tip_t = 28, 18
            self.wing_y = -50        # top of the wing root
            self.dihedral = 3.5
            self.fus = (-34, -50, 34, 36, 16)
        else:  # small sizes: everything heavier, fewer parts
            self.span = 236
            self.root_t, self.tip_t = 52, 44
            self.wing_y = -62
            self.dihedral = 3.0
            self.fus = (-50, -62, 50, 46, 20)

    def wing_pts(self):
        s, d = self.span, math.tan(math.radians(self.dihedral))
        y0 = self.wing_y
        rise = s * d
        top = [(-s, y0 - rise), (0, y0), (s, y0 - rise)]
        bot = [(s, y0 - rise + self.tip_t), (0, y0 + self.root_t), (-s, y0 - rise + self.tip_t)]
        return top + bot

    def wing_centre(self, x):
        """Mid-thickness y of the wing at spanwise x, and its thickness."""
        s, d = self.span, math.tan(math.radians(self.dihedral))
        t = self.root_t + (self.tip_t - self.root_t) * abs(x) / s
        return self.wing_y - abs(x) * d + t / 2, t

    def paths(self, xf):
        """Return list of (layer, path_d). xf maps local -> canvas."""
        out = []
        P = lambda pts: _poly([xf(p) for p in pts])
        if self.detail:
            # Horizontal tail, seen behind the fuselage.
            out.append(("body", P([(-78, -4), (78, -4), (78, 6), (-78, 6)])))
            # Fin, behind the wing.
            out.append(("body", P([(-7, self.wing_y + 4), (-5, -108), (5, -108), (7, self.wing_y + 4)])))
            # Short main gear and nose wheel: enough to say "trainer", not enough to look like legs.
            for sgn in (-1, 1):
                out.append(("body", P([(sgn * 20, 22), (sgn * 30, 16), (sgn * 66, 56), (sgn * 56, 64)])))
                out.append(("body", self._rr(xf, sgn * 62 - 12, 48, sgn * 62 + 12, 82, 10)))
            out.append(("body", self._rr(xf, -10, 30, 10, 70, 9)))
        else:
            out.append(("body", P([(-7, self.wing_y + 4), (-7, -118), (7, -118), (7, self.wing_y + 4)])))
        x0, y0, x1, y1, r = self.fus
        out.append(("body", self._rr(xf, x0, y0, x1, y1, r)))
        out.append(("body", P(self.wing_pts())))
        if self.detail:
            # Spinner, cut out of the cowl.
            out.append(("cut", self._circle(xf, (0, 2), 9)))
        return out

    @staticmethod
    def _rr(xf, x0, y0, x1, y1, r):
        # Rounded rect in local space, approximated as a polygon so it survives rotation.
        pts = []
        for cx, cy, a0 in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
            for k in range(7):
                a = math.radians(a0 + 15 * k)
                pts.append(xf((cx + r * math.cos(a), cy + r * math.sin(a))))
        return _poly(pts)

    @staticmethod
    def _circle(xf, c, r):
        cx, cy = xf(c)
        return f"M{_f(cx - r)},{_f(cy)} a{_f(r)},{_f(r)} 0 1 0 {_f(2 * r)},0 a{_f(r)},{_f(r)} 0 1 0 {_f(-2 * r)},0 Z"


def mark_elements(small=False, ring_color=ACCENT, plane_color=TEXT, cut_color=BASE,
                  ground=True, ticks=True):
    """SVG elements for the symbol in a 512x512 box."""
    C = (256.0, 256.0)
    R = 196.0
    ring_w = 40.0 if small else 20.0
    plane = Plane(detail=not small)
    lift = 0.0 if small else 14.0  # nudge the aircraft so its visual weight sits on centre

    def xf(p):
        q = (C[0] + p[0], C[1] + p[1] + lift)
        return _rot(q, BANK, C)

    # Where the wingtips cross the ring: intersect both wing edges with both edges of the
    # ring stroke, so the opening hugs the wing however steeply it cuts through.
    def crossing(sgn, off, rad):
        lo, hi = 0.0, plane.span
        for _ in range(50):
            m = (lo + hi) / 2
            yc, t = plane.wing_centre(sgn * m)
            px, py = xf((sgn * m, yc + off * t / 2))
            if math.hypot(px - C[0], py - C[1]) < rad:
                lo = m
            else:
                hi = m
        yc, t = plane.wing_centre(sgn * lo)
        px, py = xf((sgn * lo, yc + off * t / 2))
        return math.degrees(math.atan2(py - C[1], px - C[0]))

    clear = 16 if small else 13
    gaps = []
    for sgn in (-1, 1):
        angs = [crossing(sgn, off, R + k * ring_w / 2) for off in (-1, 1) for k in (-1, 1)]
        if sgn < 0:  # left wing sits near +/-180 degrees; keep the numbers continuous
            angs = [a % 360 for a in angs]
        pad = math.degrees(clear / R)
        gaps.append((min(angs) - pad, max(angs) + pad))
    # Two arcs between the gaps (gap at ~180 deg and ~0 deg).
    (l0, l1), (r0, r1) = gaps  # left wing, right wing
    arcs = [_arc(C, R, r1, l0), _arc(C, R, l1, r0 + 360)]

    els = []
    if ground:
        # Ground half of the instrument: level, regardless of the aircraft's bank.
        gr = R - ring_w / 2 - (14 if small else 10)
        els.append(f'<path d="M{_f(C[0] - gr)},{_f(C[1])} A{_f(gr)},{_f(gr)} 0 0 0 {_f(C[0] + gr)},{_f(C[1])} Z" '
                   f'fill="{ring_color}" fill-opacity="{0.16 if small else 0.13}"/>')
        if not small:
            els.append(f'<rect x="{_f(C[0] - gr)}" y="{_f(C[1] - 1.5)}" width="{_f(2 * gr)}" height="3" '
                       f'fill="{ring_color}" fill-opacity="0.55"/>')
    for a in arcs:
        els.append(f'<path d="{a}" fill="none" stroke="{ring_color}" stroke-width="{_f(ring_w)}" stroke-linecap="butt"/>')
    if ticks and not small:
        # Bank scale on the upper arc: 10, 20, 30, 45 each side, index at the top.
        rin = R - ring_w / 2 - 6
        for b in (-45, -30, -20, -10, 10, 20, 30, 45):
            a = math.radians(-90 + b)
            ln = 20 if abs(b) == 30 else 12
            p0 = (C[0] + rin * math.cos(a), C[1] + rin * math.sin(a))
            p1 = (C[0] + (rin - ln) * math.cos(a), C[1] + (rin - ln) * math.sin(a))
            els.append(f'<line x1="{_f(p0[0])}" y1="{_f(p0[1])}" x2="{_f(p1[0])}" y2="{_f(p1[1])}" '
                       f'stroke="{ring_color}" stroke-width="4" stroke-opacity="0.75"/>')
        tip_y = C[1] - rin
        els.append(f'<path d="{_poly([(C[0] - 11, tip_y), (C[0] + 11, tip_y), (C[0], tip_y + 18)])}" fill="{ring_color}"/>')
    body = [d for layer, d in plane.paths(xf) if layer == "body"]
    cut = [d for layer, d in plane.paths(xf) if layer == "cut"]
    # One path per part: their windings differ, so a single compound path would punch holes.
    els.append(f'<g fill="{plane_color}">' + "".join(f'<path d="{d}"/>' for d in body) + "</g>")
    for d in cut:
        els.append(f'<path d="{d}" fill="{cut_color}"/>')
    return els


def svg(w, h, body, bg=None, extra_defs=""):
    bgr = f'<rect width="{w}" height="{h}" fill="{bg}"/>' if bg else ""
    defs = f"<defs>{extra_defs}</defs>" if extra_defs else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
            f'{defs}{bgr}{"".join(body)}</svg>\n')


def group(els, x, y, s):
    return f'<g transform="translate({_f(x)},{_f(y)}) scale({s:.5f})">{"".join(els)}</g>'


# =========================================================================================
# Wordmark (text to outlines)
# =========================================================================================

_font_cache: dict[str, TTFont] = {}


def text_path(font_file, text, size, tracking_em=0.0):
    """Outline `text` with the baseline at y=0, starting at x=0. Returns (d, width, cap_height)."""
    font = _font_cache.setdefault(font_file, TTFont(FONTS / font_file))
    upm = font["head"].unitsPerEm
    cmap = font.getBestCmap()
    gs = font.getGlyphSet()
    hmtx = font["hmtx"]
    s = size / upm
    pen = SVGPathPen(gs, ntos=lambda v: f"{v:.2f}".rstrip("0").rstrip("."))
    x = 0.0
    names = [cmap[ord(ch)] for ch in text]
    for i, gn in enumerate(names):
        gs[gn].draw(TransformPen(pen, (s, 0, 0, -s, x, 0)))
        x += hmtx[gn][0] * s
        if i < len(names) - 1:
            x += tracking_em * size
    cap = font["OS/2"].sCapHeight * s
    # Width to the ink edge of the last glyph rather than its advance, so centring is optical.
    last = names[-1]
    lsb_adv = hmtx[last][0]
    glyf = font["glyf"][last] if "glyf" in font else None
    if glyf is not None and hasattr(glyf, "xMax"):
        x -= (lsb_adv - glyf.xMax) * s
    return pen.getCommands(), x, cap


WORD_FONT = "SairaCondensed-Bold.ttf"
SUB_FONT = "Rajdhani-SemiBold.ttf"
SUB_RATIO = 0.25  # subtitle cap size relative to the name; tracking is then solved to match widths


def wordmark(size, sub_size, gap, sub_tracking=0.42):
    """Name + subtitle stacked, left-aligned at x=0, top of caps at y=0.
    Returns (elements, width, height)."""
    d1, w1, cap = text_path(WORD_FONT, NAME_MAIN, size, 0.035)
    sp = 0.035 * size
    d2, w2, _ = text_path(WORD_FONT, NAME_ACCENT, size, 0.035)
    ds, ws, scap = text_path(SUB_FONT, SUBTITLE, sub_size, sub_tracking)
    els = [
        f'<path transform="translate(0,{_f(cap)})" d="{d1}" fill="{TEXT}"/>',
        f'<path transform="translate({_f(w1 + sp)},{_f(cap)})" d="{d2}" fill="{ACCENT}"/>',
        f'<path transform="translate(0,{_f(cap + gap + scap)})" d="{ds}" fill="{DIM}"/>',
    ]
    return els, max(w1 + sp + w2, ws), cap + gap + scap, (w1 + sp + w2, ws)


def lockup_horizontal(mark_h=160):
    """Mark on the left, name and subtitle on the right."""
    s = mark_h / 512
    word_size = mark_h * 0.62
    sub = word_size * SUB_RATIO
    els, ww, wh, (wn, wsub) = wordmark(word_size, sub, word_size * 0.20)
    # Stretch the subtitle tracking so it spans the name exactly.
    track = 0.42 + (wn - wsub) / sub / (len(SUBTITLE) - 1)
    els, ww, wh, _ = wordmark(word_size, sub, word_size * 0.20, track)
    pad = mark_h * 0.05
    gap = mark_h * 0.16
    W = pad + mark_h + gap + ww + pad
    H = mark_h + 2 * pad
    body = [group(mark_elements(), pad, pad, s),
            f'<g transform="translate({_f(pad + mark_h + gap)},{_f((H - wh) / 2)})">{"".join(els)}</g>']
    return W, H, body


def lockup_stacked(mark_h, word_size, cx, top):
    """Mark centred above name and subtitle; returns elements and bottom y."""
    s = mark_h / 512
    sub = word_size * SUB_RATIO
    els, ww, wh, (wn, wsub) = wordmark(word_size, sub, word_size * 0.2)
    track = 0.42 + (wn - wsub) / sub / (len(SUBTITLE) - 1)
    els, ww, wh, _ = wordmark(word_size, sub, word_size * 0.2, track)
    out = [group(mark_elements(), cx - mark_h / 2, top, s)]
    ty = top + mark_h + word_size * 0.42
    out.append(f'<g transform="translate({_f(cx - ww / 2)},{_f(ty)})">{"".join(els)}</g>')
    return out, ty + wh


# =========================================================================================
# Icons and splash
# =========================================================================================


def icon_svg(size=1024, inset=0.0, small=False, radius_frac=0.225):
    """Rounded-square tile with the mark. inset = fraction of canvas left empty on each side."""
    x0 = size * inset
    side = size - 2 * x0
    r = side * radius_frac
    defs = (f'<linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="#18202A"/><stop offset="1" stop-color="{BASE}"/></linearGradient>')
    hair = max(1.0, size / 512)
    body = [
        f'<path d="{_rrect(x0, x0, x0 + side, x0 + side, r)}" fill="url(#tile)"/>',
        f'<path d="{_rrect(x0 + hair / 2, x0 + hair / 2, x0 + side - hair / 2, x0 + side - hair / 2, r - hair / 2)}" '
        f'fill="none" stroke="#FFFFFF" stroke-opacity="0.10" stroke-width="{_f(hair)}"/>',
    ]
    m = side * (0.86 if small else 0.80)
    body.append(group(mark_elements(small=small, ticks=not small, cut_color="#141A20"),
                      size / 2 - m / 2, size / 2 - m / 2, m / 512))
    return svg(size, size, body, extra_defs=defs)


def splash_svg(W=1920, H=1080):
    cx = W / 2
    mark_h = 320
    word = 112
    # Measure the block to centre it vertically.
    _, bottom = lockup_stacked(mark_h, word, cx, 0)
    top = (H - bottom) / 2 - 10
    els, _ = lockup_stacked(mark_h, word, cx, top)
    horizon_y = top + mark_h / 2
    defs = (
        f'<radialGradient id="glow" cx="0.5" cy="{_f(horizon_y / H)}" r="0.62" gradientTransform="translate(0.5 {_f(horizon_y / H)}) scale(1 {_f(W / H)}) translate(-0.5 {_f(-horizon_y / H)})">'
        f'<stop offset="0" stop-color="#131A22"/><stop offset="0.75" stop-color="{BASE}"/></radialGradient>'
        f'<linearGradient id="hz" x1="0" y1="0" x2="1" y2="0">'
        f'<stop offset="0" stop-color="{ACCENT}" stop-opacity="0"/>'
        f'<stop offset="0.5" stop-color="{ACCENT}" stop-opacity="0.38"/>'
        f'<stop offset="1" stop-color="{ACCENT}" stop-opacity="0"/></linearGradient>')
    # The mark's level horizon carries on across the screen, broken where the ring sits.
    ring_out = mark_h / 512 * (196 + 10) + 22
    body = [f'<rect width="{W}" height="{H}" fill="url(#glow)"/>',
            f'<rect x="0" y="{_f(horizon_y - 0.75)}" width="{_f(cx - ring_out)}" height="1.5" fill="url(#hz)"/>',
            f'<rect x="{_f(cx + ring_out)}" y="{_f(horizon_y - 0.75)}" width="{_f(W - cx - ring_out)}" height="1.5" fill="url(#hz)"/>']
    # Re-map the gradient so each half fades out toward its screen edge.
    defs = defs.replace('x2="1" y2="0"', f'x2="{W}" y2="0" gradientUnits="userSpaceOnUse"')
    body += els
    return svg(W, H, body, bg=BASE, extra_defs=defs)


def png(svg_text, path, w, h=None):
    cairosvg.svg2png(bytestring=svg_text.encode(), write_to=str(path), output_width=w, output_height=h or w)


def main():
    out = HERE
    (out / "mark.svg").write_text(svg(512, 512, mark_elements()))
    (out / "mark-small.svg").write_text(svg(512, 512, mark_elements(small=True)))
    W, H, body = lockup_horizontal()
    (out / "lockup.svg").write_text(svg(round(W), round(H), body))
    (out / "lockup-on-dark.svg").write_text(svg(round(W), round(H), body, bg=BASE))
    png(svg(round(W), round(H), body), out / "lockup.png", round(W) * 4, round(H) * 4)

    # Icons. The Godot window icon is the full-bleed tile; macOS gets Apple's 10% margin.
    (out / "icon.svg").write_text(icon_svg(1024, inset=0.03))
    (out / "icon-small.svg").write_text(icon_svg(1024, inset=0.0, small=True, radius_frac=0.2))
    png(icon_svg(1024, inset=0.03), out / "icon-1024.png", 1024)
    png(icon_svg(1024, inset=0.0977), out / "icon-macos-1024.png", 1024)

    frames = []
    for s in (16, 24, 32, 48, 64, 128, 256):
        src = icon_svg(1024, inset=0.0, small=True, radius_frac=0.2) if s <= 48 else icon_svg(1024, inset=0.03)
        buf = io.BytesIO()
        cairosvg.svg2png(bytestring=src.encode(), write_to=buf, output_width=s, output_height=s)
        frames.append(Image.open(io.BytesIO(buf.getvalue())).convert("RGBA"))
    frames[-1].save(out / "icon.ico", format="ICO", sizes=[f.size for f in frames], append_images=frames[:-1])

    Image.open(out / "icon-macos-1024.png").save(out / "icon.icns", format="ICNS")

    (out / "splash.svg").write_text(splash_svg())
    png(splash_svg(), out / "splash.png", 1920, 1080)
    print("wrote", sorted(p.name for p in out.iterdir() if p.suffix in (".svg", ".png", ".ico", ".icns")))


if __name__ == "__main__":
    main()
