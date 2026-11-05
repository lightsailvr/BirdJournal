# /// script
# dependencies = ["pillow"]
# ///
"""Issue #138's contact sheets: a row of screenshots with their names, for the PR.

uv run docs/screenshots/138/sheet.py <out.jpg> <columns> <image>...
"""
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

out, columns, names = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
width = 320
images = [Image.open(name).convert("RGB") for name in names]
height = round(width * images[0].height / images[0].width)
label = 26
rows = (len(images) + columns - 1) // columns
sheet = Image.new("RGB", (columns * (width + 8) + 8, rows * (height + label + 8) + 8), "#1b2b2e")
draw = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 15)
except OSError:
    font = ImageFont.load_default()
for index, (name, image) in enumerate(zip(names, images)):
    x = 8 + (index % columns) * (width + 8)
    y = 8 + (index // columns) * (height + label + 8)
    draw.text((x + 2, y + 3), pathlib.Path(name).stem, fill="#e8e4d8", font=font)
    sheet.paste(image.resize((width, height), Image.LANCZOS), (x, y + label))
sheet.save(out, quality=84)
