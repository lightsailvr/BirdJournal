"""Contact sheets for reviewing art by eye (issues #49 and #57): a grid of labelled pictures on paper."""

from __future__ import annotations

from PIL import Image, ImageDraw, ImageFont

CELL = (288, 384)
"""A 3:4 cell, the card's shape."""
LABEL_HEIGHT = 44
PAPER = (248, 245, 237)
MAT = (235, 232, 224)
INK = (38, 51, 41)
FADED_INK = (93, 103, 94)


def font(size: int):
    return ImageFont.load_default(size=size)


def fit(image: Image.Image, size: tuple[int, int] = CELL) -> Image.Image:
    """`image` scaled to fit inside `size`, centred on the mat."""
    canvas = Image.new("RGB", size, MAT)
    image = image.convert("RGB").copy()
    image.thumbnail(size, Image.Resampling.LANCZOS)
    canvas.paste(image, ((size[0] - image.width) // 2, (size[1] - image.height) // 2))
    return canvas


def grid(rows: list[list[tuple[Image.Image | None, str]]], title: str, footer: list[str], cell: tuple[int, int] = CELL) -> Image.Image:
    """Rows of (picture or None, label of up to two lines) under a title, with footer lines (credits) below."""
    columns = max(len(row) for row in rows)
    header, line = 56, 22
    label_size = 16 if cell[0] >= 200 else 12
    label_height = LABEL_HEIGHT if cell[0] >= 200 else 34
    width = columns * cell[0] + (columns + 1) * 8
    height = header + len(rows) * (cell[1] + label_height + 8) + 16 + line * len(footer)
    sheet = Image.new("RGB", (width, height), PAPER)
    draw = ImageDraw.Draw(sheet)
    draw.text((12, 12), title, fill=INK, font=font(28 if width > 1200 else 18))
    for r, row in enumerate(rows):
        for c, (image, label) in enumerate(row):
            x, y = 8 + c * (cell[0] + 8), header + r * (cell[1] + label_height + 8)
            if image is not None:
                sheet.paste(fit(image, cell), (x, y))
            for i, text in enumerate(label.split("\n")[:2]):
                draw.text((x + 2, y + cell[1] + 3 + i * (label_size + 3)), text, fill=INK, font=font(label_size))
    y = header + len(rows) * (cell[1] + label_height + 8) + 8
    for text in footer:
        draw.text((12, y), text, fill=FADED_INK, font=font(15))
        y += line
    return sheet
