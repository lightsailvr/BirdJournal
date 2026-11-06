#!/usr/bin/env python3
"""Writes Collection's tab icon as an SF Symbols template: twelve running stitches round a solid centre, from the audit's
#i-coll, in all nine weights at all three scales, so `.imageScale` and Bold Text both work (issue #150).

    scripts/make-stitched-ring.py
"""
import json
import math
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "BirdJournal/BirdJournal/Assets.xcassets/stitched.ring.symbolset"

# The mock's 18x17 viewBox has r 7.2, stroke 1.5 and centre r 3.6. The tab bar draws the large scale, so at Regular-L the ring's
# outer edge spans 126 units: the height of the system's map and waveform symbols beside it.
OUTER = 49.0
UNIT = OUTER / (7.2 + 0.75)
STROKE = 1.5 * UNIT
CENTRE = 3.6 * UNIT
STITCHES = 12
GAP_DEGREES = 360 / STITCHES * (1.4 / 3.6)
MID_CAP = -35.2  # half way between the template's baseline and capline

WEIGHTS = {  # name: (the stitches' thickness, the centre's radius), against Regular
    "Ultralight": (0.40, 0.86),
    "Thin": (0.55, 0.90),
    "Light": (0.78, 0.95),
    "Regular": (1.00, 1.00),
    "Medium": (1.12, 1.03),
    "Semibold": (1.28, 1.07),
    "Bold": (1.45, 1.11),
    "Heavy": (1.70, 1.16),
    "Black": (1.95, 1.20),
}
SCALES = {"S": (0.78, 696), "M": (1.0, 1126), "L": (1.29, 1556)}  # name: (size against M, the row's baseline)


def number(value):
    return f"{value:.3f}".rstrip("0").rstrip(".")


def ring(scale, thickness, centre_size):
    outer = OUTER * scale
    inner = outer - STROKE * thickness * scale
    centre = CENTRE * centre_size * scale
    middle = outer + 6
    path = []

    def at(radius, degrees):
        return middle + radius * math.cos(math.radians(degrees)), MID_CAP + radius * math.sin(math.radians(degrees))

    for stitch in range(STITCHES):
        start = stitch * 360 / STITCHES - 90 + GAP_DEGREES / 2
        end = (stitch + 1) * 360 / STITCHES - 90 - GAP_DEGREES / 2
        handle = 4 / 3 * math.tan(math.radians(end - start) / 4)

        def control(radius, degrees, sign):
            x, y = at(radius, degrees)
            return x - sign * handle * radius * math.sin(math.radians(degrees)), y + sign * handle * radius * math.cos(math.radians(degrees))

        points = [
            at(outer, start), control(outer, start, 1), control(outer, end, -1), at(outer, end),
            at(inner, end), control(inner, end, -1), control(inner, start, 1), at(inner, start),
        ]
        x = [f"{number(a)} {number(b)}" for a, b in points]
        path.append(f"M{x[0]}C{x[1]} {x[2]} {x[3]}L{x[4]}C{x[5]} {x[6]} {x[7]}Z")
    k = 0.5522847 * centre
    x, y = middle, MID_CAP
    n = number
    path.append(
        f"M{n(x)} {n(y - centre)}C{n(x + k)} {n(y - centre)} {n(x + centre)} {n(y - k)} {n(x + centre)} {n(y)}"
        f"C{n(x + centre)} {n(y + k)} {n(x + k)} {n(y + centre)} {n(x)} {n(y + centre)}"
        f"C{n(x - k)} {n(y + centre)} {n(x - centre)} {n(y + k)} {n(x - centre)} {n(y)}"
        f"C{n(x - centre)} {n(y - k)} {n(x - k)} {n(y - centre)} {n(x)} {n(y - centre)}Z"
    )
    return "".join(path), 2 * middle


guides = []
symbols = []
for scale_name, (scale, baseline) in SCALES.items():
    guides.append(f'  <line id="Baseline-{scale_name}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{baseline}" y2="{baseline}"/>')
    guides.append(f'  <line id="Capline-{scale_name}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{baseline - 70.459:.3f}" y2="{baseline - 70.459:.3f}"/>')
    for column, (weight, (thickness, centre_size)) in enumerate(WEIGHTS.items()):
        left = 300 + column * 296
        path, width = ring(scale, thickness, centre_size)
        name = f"{weight}-{scale_name}"
        guides.append(f'  <line id="left-margin-{name}" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{left}" x2="{left}" y1="{baseline - 96}" y2="{baseline + 24}"/>')
        guides.append(f'  <line id="right-margin-{name}" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{left + width:.3f}" x2="{left + width:.3f}" y1="{baseline - 96}" y2="{baseline + 24}"/>')
        symbols.append(f'  <g id="{name}" transform="matrix(1 0 0 1 {left} {baseline})">\n   <path d="{path}"/>\n  </g>')

nl = "\n"
svg = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <!-- The stitched ring: Collection's tab icon (issue #150). Written by scripts/make-stitched-ring.py. -->
 <g id="Notes">
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 322)">Weight/Scale Variations</text>
 </g>
 <g id="Guides">
  <g id="H-reference" style="fill:#27AAE1;stroke:none;" transform="matrix(1 0 0 1 339 696)">
   <path d="M0.993 0L3.2 0L28.9 -71.1L30.5 -71.1L30.5 -73.8L28.9 -73.8Z"/>
  </g>
{nl.join(guides)}
 </g>
 <g id="Symbols">
{nl.join(symbols)}
 </g>
</svg>
"""
OUT.mkdir(parents=True, exist_ok=True)
(OUT / "stitched.ring.svg").write_text(svg)
(OUT / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}, "symbols": [{"filename": "stitched.ring.svg", "idiom": "universal"}]}, indent=2) + "\n")
