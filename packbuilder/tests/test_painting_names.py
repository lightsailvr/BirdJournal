"""Two builds painting on one ComfyUI server must never share an input's name (#58)."""
import io

import numpy as np
from PIL import Image

from packbuilder.comfy import Painting
from packbuilder.painting import Painter


class RecordingClient:
    def __init__(self):
        self.names = []

    def paint(self, workflow, images, prompt=None, seed=None, size=None):
        self.names += [name for name, _ in images]
        buffer = io.BytesIO()
        Image.new("RGBA", (8, 8), (0, 0, 0, 255)).save(buffer, "PNG")
        return Painting(image=buffer.getvalue(), seconds=0.0)


def picture(shade: int) -> Image.Image:
    return Image.fromarray(np.full((8, 8, 3), shade, dtype=np.uint8))


def test_an_unnamed_cut_out_is_uploaded_under_a_name_of_its_own_contents():
    client = RecordingClient()
    painter = Painter(client)
    painter.mask(picture(10))
    painter.mask(picture(200))
    painter.mask(picture(10))
    assert client.names[0] != client.names[1] and client.names[0] == client.names[2]
    assert "cutout-image" not in "".join(client.names)
