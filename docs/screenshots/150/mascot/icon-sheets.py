# /// script
# dependencies = ["pillow"]
# ///
"""Issue #150 slice 11's icon sheets, at the simulator's true pixels, so an icon is seen at the size it is on a phone.

uv run docs/screenshots/150/mascot/icon-sheets.py <folder of shots> <out folder>
"""
import pathlib
import sys

from PIL import Image, ImageDraw

shots, out = map(pathlib.Path, sys.argv[1:])
BIRDS = ["red-tailed-hawk", "blue-bird", "great-egret", "house-finch", "prothonotary-warbler", "stellers-jay"]
ICON = (880, 540, 1206, 840)  # the Featherguild icon and its label on the home screen, in pixels of a 402 pt screen at 3x


def labelled(pictures):
    width = sum(p.width for _, p in pictures) + 8 * (len(pictures) + 1)
    sheet = Image.new("RGB", (width, max(p.height for _, p in pictures) + 34), "#1b2b2e")
    draw = ImageDraw.Draw(sheet)
    x = 8
    for name, picture in pictures:
        draw.text((x + 2, 6), name, fill="#e8e4d8")
        sheet.paste(picture.convert("RGB"), (x, 26))
        x += picture.width + 8
    return sheet


def screen(name):
    return Image.open(shots / f"{name}.png").crop(ICON)


labelled([("before: hawk", screen("before-home")), *[(bird, screen(f"home-{bird}")) for bird in BIRDS]]).save(out / "home-icons.jpg", quality=88)
labelled([(r, Image.open(shots / f"r-{r}.png")) for r in ("Default", "Dark", "TintedLight", "TintedDark", "ClearLight", "ClearDark")]).save(out / "icon-appearances.jpg", quality=88)
