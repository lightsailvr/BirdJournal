"""Card art (issue #49): prompts from the committed templates in `art/prompts.json`, the committed ComfyUI workflows,
and the image work around them.

Every painting is a natural-history watercolour by FLUX.3 Image Klein on comfybox (ADR-0007, proposed), which takes
the bird from a reference image so that its identity comes from a real photo rather than the model's idea of the
species. Pack art paints the species' open-license reference bird in its set's edition theme. Scene art paints the
same bird into a telephoto crop of the glasses photo from the add. For both, the reference is first isolated: FLUX.3
paints the bird alone on white, with whatever its perch hid completed, and its colours are fitted back to the photo's
(`packbuilder.fidelity`). Photo art paints the birder's own photo, keeping its setting. Legendary scene and photo art
get more dramatic light.
"""

from __future__ import annotations

import copy
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from PIL import Image

from packbuilder.geometry import Box

ART_DIR = Path(__file__).resolve().parents[3] / "art"

ArtKind = Literal["pack", "scene", "photo"]
ART_KINDS: tuple[ArtKind, ...] = ("pack", "scene", "photo")
CARD_ASPECT = 3 / 4
CARD_SIZE = (864, 1152)
"""Card art is 3:4 portrait (#57); the workflows paint 864 x 1152."""
TELEPHOTO_ZOOM_CM = 12 * 14.5
"""A scene's crop zooms 12x for a 14.5 cm House Finch, and in proportion to length for other species, so that every
bird is painted at card size and at its true size against the place."""
PERCH = (0.5, 0.72)
"""Where the perch point lands in a scene's crop: centred, a little below the middle."""


@dataclass(frozen=True)
class Species:
    common_name: str
    scientific_name: str


@dataclass(frozen=True)
class ArtPrompts:
    version: int
    editions: dict[str, dict[str, str]]
    light: dict[str, str]
    templates: dict[str, str]
    isolate: str
    """The prompt that isolates a reference bird on white (workflow `bird-isolate`)."""

    @classmethod
    def load(cls, path: Path = ART_DIR / "prompts.json") -> "ArtPrompts":
        data = json.loads(Path(path).read_text())
        return cls(version=data["version"], editions=data["editions"], light=data["light"], templates=data["templates"], isolate=data["isolate"])

    def render(self, kind: ArtKind, species: Species, edition: str, legendary: bool = False) -> str:
        """The prompt for one painting of `species` in the theme of `edition` (a pack id). Pack art is the same for
        every birder, so it has no Legendary variant."""
        if legendary and kind == "pack":
            raise ValueError("pack art has no Legendary variant")
        theme = self.editions[edition]
        return self.templates[kind].format(
            common_name=species.common_name,
            scientific_name=species.scientific_name,
            place=theme["place"],
            edition_light=theme["light"],
            edition_colors=theme["colors"],
            edition_motifs=theme["motifs"],
            light=self.light["legendary" if legendary else "standard"],
        )


@dataclass(frozen=True)
class Workflow:
    """A committed ComfyUI graph (`art/workflows/<name>.json`, API format: `pack-art`, `scene-art`, `photo-art`,
    `bird-isolate` and `bird-cutout`) with its inputs left empty. Its nodes are found by title: "image 1", "image 2",
    ... (LoadImage), "prompt" (the text encoder), "canvas" (the empty latent) and "sampler" (the seed); the cut-out has
    only an image."""

    name: str
    version: int
    graph: dict

    @classmethod
    def load(cls, name: str, directory: Path = ART_DIR / "workflows") -> "Workflow":
        data = json.loads((Path(directory) / f"{name}.json").read_text())
        return cls(name=name, version=data["version"], graph=data["graph"])

    @property
    def image_count(self) -> int:
        return sum(1 for node in self.graph.values() if _title(node).startswith("image "))

    def fill(self, images: list[str], prompt: str | None = None, seed: int | None = None, size: tuple[int, int] | None = None) -> dict:
        """A copy of the graph ready to queue: `images` are names ComfyUI's upload returned, in order; `size` is the
        canvas (multiples of 16) where it isn't the card's."""
        if len(images) != self.image_count:
            raise ValueError(f"{self.name} takes {self.image_count} image(s), got {len(images)}")
        graph = copy.deepcopy(self.graph)
        nodes = {_title(node): node for node in graph.values()}
        for index, image in enumerate(images, start=1):
            nodes[f"image {index}"]["inputs"]["image"] = image
        if prompt is not None:
            nodes["prompt"]["inputs"]["text"] = prompt
        if seed is not None:
            nodes["sampler"]["inputs"]["seed"] = seed
        if size is not None:
            if size[0] % 16 or size[1] % 16:
                raise ValueError(f"the canvas must be a multiple of 16, got {size}")
            nodes["canvas"]["inputs"]["width"], nodes["canvas"]["inputs"]["height"] = size
        return graph


def _title(node: dict) -> str:
    return node.get("_meta", {}).get("title", "")


def card_crop_box(box: Box | None, size: tuple[int, int], padding: float = 0.5, zoom: float = 1.0) -> tuple[int, int, int, int]:
    """A 3:4 box in pixels around the bird `box`, padded by `padding` of the bird's binding side on each side,
    shifted (not shrunk) to stay inside the image, and never larger than the largest 3:4 box the image holds divided
    by `zoom`. With no box, that largest box, centred: a glasses photo has no detected bird, and zoomed 2x it is the
    viewfinder's crop, the middle half of each side, where the birder was looking."""
    width, height = size
    largest_height = int(min(height, width / CARD_ASPECT) / zoom)
    if box is None:
        crop_height, (cx, cy) = largest_height, (width / 2, height / 2)
    else:
        bx0, by0, bx1, by1 = box.clamped().pixels(size)
        needed_height = max(by1 - by0, (bx1 - bx0) / CARD_ASPECT, 1)
        crop_height = min(int(round(needed_height * (1 + 2 * padding))), largest_height)
        cx, cy = (bx0 + bx1) / 2, (by0 + by1) / 2
    crop_width = min(int(round(crop_height * CARD_ASPECT)), width)
    left = min(max(int(round(cx - crop_width / 2)), 0), width - crop_width)
    top = min(max(int(round(cy - crop_height / 2)), 0), height - crop_height)
    return left, top, left + crop_width, top + crop_height


def telephoto_zoom(length_cm: float) -> float:
    """How far a scene's crop zooms into the glasses photo for a bird `length_cm` long (TELEPHOTO_ZOOM_CM), never
    less than 1."""
    return max(1.0, TELEPHOTO_ZOOM_CM / length_cm)


def telephoto_crop(scene: Image.Image, length_cm: float, perch: tuple[float, float] | None = None) -> Image.Image:
    """The card-size crop of a glasses photo that a long lens would frame from the same spot: zoomed for the bird's
    length, with the `perch` point (fractions of the photo; the middle, where the wearer aimed, if not given) at
    PERCH in the crop, shifted to stay inside the photo. Cropping keeps the photo's perspective; only the depth of
    field differs, and the painting softens the place."""
    width, height = scene.size
    zoom = telephoto_zoom(length_cm)
    crop_width = min(width / zoom, height * CARD_ASPECT)
    crop_height = crop_width / CARD_ASPECT
    px, py = perch or (0.5, 0.5)
    left = min(max(px * width - PERCH[0] * crop_width, 0), width - crop_width)
    top = min(max(py * height - PERCH[1] * crop_height, 0), height - crop_height)
    return scene.convert("RGB").resize(CARD_SIZE, Image.Resampling.LANCZOS, box=(left, top, left + crop_width, top + crop_height))
