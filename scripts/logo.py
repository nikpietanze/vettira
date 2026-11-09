#!/usr/bin/env python3
"""Draws Vettira's logo and app icon.

The mark is a price line that rises to its high and pulls back, with the high it pulled back from
drawn level across the top. This script holds its geometry and the palette, and is the only source
of the logo: it writes the SVGs in docs/assets/ and renders the app icon's PNGs, from the icon's
SVG, into App/Vettira/Assets.xcassets/AppIcon.appiconset/. Never edit those files by hand; change
this script and run it again.

    python3 scripts/logo.py                  # write the SVGs and the icon's PNGs
    python3 scripts/logo.py --preview DIR    # and render previews of each into DIR

It needs pycairo, Pillow built with libraqm, PyGObject with librsvg (Debian and Ubuntu:
python3-cairo python3-pil python3-gi gir1.2-rsvg-2.0) and the Noto Sans font, whose outlines
make the wordmark.
"""
import argparse
import json
import re
import sys
from pathlib import Path

import subprocess
import warnings

import cairo
import gi
from PIL import Image, ImageFont, features

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "docs" / "assets"
CATALOG = ROOT / "App" / "Vettira" / "Assets.xcassets"

# The palette: one colour, teal, and a slate neutral.
TEAL = "#0F766E"        # the price line on light backgrounds
TEAL_LIGHT = "#3CC7B4"  # the price line on dark backgrounds and on the icon's tile
HIGH = "#94A3B8"        # the high, a mid slate that reads on light and dark
INK = "#1E293B"         # the wordmark on light backgrounds
INK_LIGHT = "#E2E8F0"   # the wordmark on dark backgrounds
TILE = "#162032"        # the icon's tile, a dark slate

# The mark's geometry. The price line rises, dips, peaks and pulls back to the latest price,
# its dot; the high is level from the peak, out past the dot.
PRICE = [(0, 36), (13, 22), (20, 27), (33, 3), (44, 17)]
PRICE_SIMPLE = [(0, 36), (33, 3), (44, 17)]  # without the dip, for the icon's smallest sizes
PRICE_WIDTH = 6
DOT_RADIUS = 5
HIGH_WIDTH = 3
HIGH_END = 54  # the high runs from the peak's x to here


def mark_bounds(weight: float = 1) -> tuple[float, float, float, float]:
    """The mark's ink: left, top, right, bottom."""
    pw, hw, r = PRICE_WIDTH * weight / 2, HIGH_WIDTH * weight / 2, DOT_RADIUS * weight
    xs, ys = [x for x, _ in PRICE], [y for _, y in PRICE]
    return (min(xs) - pw, min(ys) - max(pw, hw), max(HIGH_END + hw, PRICE[-1][0] + r),
            max(max(ys) + pw, PRICE[-1][1] + r))


def mark(price: str, high: str = HIGH, weight: float = 1, simple: bool = False) -> str:
    """The mark as SVG elements, its ink from (0, 0). For small sizes, weight thickens its strokes
    and simple leaves out the dip."""
    left, top, _, _ = mark_bounds(weight)
    line = PRICE_SIMPLE if simple else PRICE
    points = " ".join(f"{x - left:g},{y - top:g}" for x, y in line)
    peak_x, peak_y = min(line, key=lambda point: point[1])
    x, y = line[-1]
    return (
        f'<line x1="{peak_x - left:g}" y1="{peak_y - top:g}" x2="{HIGH_END - left:g}" y2="{peak_y - top:g}" '
        f'stroke="{high}" stroke-width="{HIGH_WIDTH * weight:g}" stroke-linecap="round"/>'
        f'<polyline points="{points}" fill="none" stroke="{price}" stroke-width="{PRICE_WIDTH * weight:g}" '
        'stroke-linecap="round" stroke-linejoin="round"/>'
        f'<circle cx="{x - left:g}" cy="{y - top:g}" r="{DOT_RADIUS * weight:g}" fill="{price}"/>'
    )


def mark_size(weight: float = 1) -> tuple[float, float]:
    left, top, right, bottom = mark_bounds(weight)
    return right - left, bottom - top


def svg(width: float, height: float, body: str, title: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:g}" height="{height:g}" '
        f'viewBox="0 0 {width:g} {height:g}" role="img" aria-label="{title}">'
        f"<title>{title}</title>{body}</svg>\n"
    )


def wordmark() -> tuple[str, float, float, float]:
    """'Vettira' in Noto Sans, as SVG path data from its ink's top left: the path, its width, and
    the top of its capitals and its baseline, measured from that top.

    cairo draws the glyphs' outlines, and Pillow's HarfBuzz layout places them, kerned.
    """
    text, size, spacing = "Vettira", 100, 2
    path = subprocess.run(["fc-match", "--format=%{file}", "Noto Sans:weight=bold"],
                          capture_output=True, text=True).stdout
    if not path.endswith("NotoSans-Bold.ttf") or not features.check("raqm"):
        sys.exit("logo: needs the Noto Sans font and Pillow with libraqm to draw the wordmark")
    font = ImageFont.truetype(path, size, layout_engine=ImageFont.Layout.RAQM)
    ctx = cairo.Context(cairo.RecordingSurface(cairo.CONTENT_COLOR_ALPHA, None))
    ctx.select_font_face("Noto Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
    ctx.set_font_size(size)
    for i, letter in enumerate(text):
        ctx.move_to(font.getlength(text[:i]) + i * spacing, 0)
        ctx.text_path(letter)
    x0, y0, x1, y1 = ctx.fill_extents()
    data = []
    capitals = cairo.Context(cairo.RecordingSurface(cairo.CONTENT_COLOR_ALPHA, None))
    capitals.select_font_face("Noto Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
    capitals.set_font_size(size)
    capitals.text_path(text[0])
    cap_top = capitals.fill_extents()[1]
    for kind, points in ctx.copy_path():
        coords = " ".join(f"{p - (x0 if i % 2 == 0 else y0):.2f}" for i, p in enumerate(points))
        data.append({0: "M", 1: "L", 2: "C", 3: "Z"}[kind] + coords)
    return "".join(data), x1 - x0, cap_top - y0, -y0


def lockup(price: str, ink: str, title: str) -> str:
    """The mark and the wordmark side by side: the wordmark's capitals a little shorter than the
    mark, the mark centred on them, and padding all round so nothing touches the edge."""
    text, text_w, cap_top, baseline = wordmark()
    mark_w, mark_h = mark_size()
    scale = mark_h * 0.7 / (baseline - cap_top)
    gap, pad = mark_w * 0.22, mark_h * 0.14
    centre = pad + mark_h / 2
    text_y = centre - (cap_top + baseline) / 2 * scale
    body = (
        f'<g transform="translate({pad:.2f} {pad:.2f})">{mark(price)}</g>'
        f'<path transform="translate({pad + mark_w + gap:.2f} {text_y:.2f}) scale({scale:.4f})" '
        f'fill="{ink}" d="{text}"/>'
    )
    return svg(round(2 * pad + mark_w + gap + text_w * scale, 2), round(2 * pad + mark_h, 2), body, title)


def square(body_w: float, body_h: float, body: str, size: float, fill: float, nudge: float = 0) -> str:
    """Centres a body body_w by body_h in a size square, scaled to fill that share of it and moved
    right by nudge, a share of the square."""
    scale = size * fill / max(body_w, body_h)
    x, y = (size - body_w * scale) / 2 + nudge * size, (size - body_h * scale) / 2
    return f'<g transform="translate({x:.2f} {y:.2f}) scale({scale:.4f})">{body}</g>'


def app_icon(small: bool = False) -> str:
    """The app icon on macOS's grid: a 1024-point canvas with an 824-point tile, its corners
    185.4 points, lifted a little above centre for its shadow. The small one, for 32 pixels and
    below, draws the mark larger and simpler, with thicker strokes. The mark spans 64% of the
    tile, moved a little left of centre because the dot and the high line weigh its right side."""
    weight, fill, nudge = (1.6, 0.72, 0) if small else (1.15, 0.64, -0.008)
    tile, lift = 824, 10
    inset = (1024 - tile) / 2
    body = (
        '<defs><filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">'
        '<feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000" flood-opacity="0.3"/>'
        "</filter></defs>"
        f'<rect x="{inset:g}" y="{inset - lift:g}" width="{tile}" height="{tile}" rx="185.4" '
        f'fill="{TILE}" filter="url(#shadow)"/>'
        f'<g transform="translate({inset:g} {inset - lift:g})">'
        + square(*mark_size(weight), mark(TEAL_LIGHT, weight=weight, simple=small), tile, fill, nudge)
        + "</g>"
    )
    return svg(1024, 1024, body, "Vettira")


def render(svg_text: str, width: int, out: Path, background: str | None = None) -> None:
    """Renders an SVG into a PNG width pixels wide, keeping its aspect, onto a background if given."""
    w, h = (float(v) for v in re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', svg_text).groups())
    height = round(width * h / w)
    sized = re.sub(r'width="[\d.]+" height="[\d.]+"', f'width="{width}" height="{height}"', svg_text, count=1)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)  # get_pixbuf is fine for one-off renders
        pixbuf = Rsvg.Handle.new_from_data(sized.encode()).get_pixbuf()
    image = Image.frombytes("RGBA", (pixbuf.get_width(), pixbuf.get_height()),
                            pixbuf.get_pixels(), "raw", "RGBA", pixbuf.get_rowstride())
    if background:
        image = Image.alpha_composite(Image.new("RGBA", image.size, background), image).convert("RGB")
    image.save(out, optimize=True)


# The macOS app icon's sizes: (points, scale).
ICON_SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--preview", type=Path, help="also render previews into this directory")
    args = parser.parse_args()

    files = {
        "mark.svg": svg(64, 64, square(*mark_size(), mark(TEAL), 64, 0.84), "Vettira"),
        "logo-light.svg": lockup(TEAL, INK, "Vettira"),
        "logo-dark.svg": lockup(TEAL_LIGHT, INK_LIGHT, "Vettira"),
        "app-icon.svg": app_icon(),
        "app-icon-small.svg": app_icon(small=True),
    }
    ASSETS.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (ASSETS / name).write_text(text)

    iconset = CATALOG / "AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    (CATALOG / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    images = []
    for points, scale in ICON_SIZES:
        pixels = points * scale
        name = f"icon_{pixels}.png"
        if name not in {image["filename"] for image in images}:  # 32@1x is 16@2x, and so on
            render(files["app-icon.svg" if pixels > 32 else "app-icon-small.svg"], pixels, iconset / name)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (iconset / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")

    if args.preview:
        out = args.preview
        out.mkdir(parents=True, exist_ok=True)
        render(files["mark.svg"], 512, out / "mark-512.png")
        render(files["mark.svg"], 32, out / "mark-32.png")
        render(files["logo-light.svg"], 1200, out / "logo-light.png", background="#FFFFFF")
        render(files["logo-dark.svg"], 1200, out / "logo-dark.png", background="#0D1117")
        render(files["app-icon.svg"], 1024, out / "app-icon-1024.png")
        for pixels in (16, 32):
            small = Image.open(iconset / f"icon_{pixels}.png")
            small.resize((256, 256), Image.NEAREST).save(out / f"app-icon-{pixels}-zoomed.png")
        Image.open(out / "mark-32.png").resize((256, 256), Image.NEAREST).save(out / "mark-32-zoomed.png")


if __name__ == "__main__":
    main()
