"""Issue #150 slice 11: each icon's lower-left arc at its own 1024 px, from the approved patch as it was (top) and trimmed to its
cord as it ships (bottom), on the icon's felt. Run from packbuilder/, which has the module:

cd packbuilder && uv run python ../docs/screenshots/150/mascot/icon-edges.py ../docs/screenshots/150/mascot/icon-edges-before-after.jpg
"""
import sys
from pathlib import Path

from PIL import Image

from packbuilder import mascot_art as mascot

felt = Image.open(mascot.REPO / mascot.FELT_PICTURE).convert("RGBA")
SIDE = 330
sheet = Image.new("RGB", (len(mascot.APP_ICONS) * (SIDE + 8) + 8, 2 * SIDE + 24), (40, 40, 40))
for index, bird in enumerate(mascot.APP_ICONS):
    patch = Image.open(mascot.REPO / "art/mascot/approved" / f"{bird}.png").convert("RGBA")
    arc = (170, 640, 170 + SIDE, 640 + SIDE)
    sheet.paste(mascot.app_icon(patch, felt, 1024).crop(arc), (8 + index * (SIDE + 8), 8))
    sheet.paste(mascot.app_icon(mascot.trimmed_to_cord(patch), felt, 1024).crop(arc), (8 + index * (SIDE + 8), SIDE + 16))
sheet.save(Path(sys.argv[1]), quality=90)
