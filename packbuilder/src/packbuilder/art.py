"""Card art (issue #49): prompts from the committed templates in `art/prompts.json`, the committed ComfyUI workflows,
and the image work around them.

Pack art paints a species in its set's edition theme from an open-license reference photo. Scene art pastes the
species' cut-out reference bird into the zoomed glasses photo from the add and paints the composite, so the bird's
identity comes from a real photo rather than the model's idea of the species. Photo art embellishes the birder's own
photo. Legendary scene and photo art get more dramatic light. The model is Qwen-Image-Edit-2511 on comfybox (ADR-0003).
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
"""Card art is 3:4 portrait (#57); the workflows paint 864 x 1152."""


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
    negative: str
    """What every painting steers away from (the sampler runs at cfg 4, so the negative prompt counts)."""

    @classmethod
    def load(cls, path: Path = ART_DIR / "prompts.json") -> "ArtPrompts":
        data = json.loads(Path(path).read_text())
        return cls(version=data["version"], editions=data["editions"], light=data["light"], templates=data["templates"], negative=data["negative"])

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
    """A committed ComfyUI graph (`art/workflows/<name>.json`, API format: `pack-art`, `scene-art`, `photo-art` and
    `bird-cutout`) with its inputs left empty. Its nodes are found by title: "image 1", "image 2", ... (LoadImage),
    "prompt" and "negative" (the text encoders) and "sampler" (the seed); the cut-out has only an image."""

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

    def fill(self, images: list[str], prompt: str | None = None, negative: str | None = None, seed: int | None = None) -> dict:
        """A copy of the graph ready to queue: `images` are names ComfyUI's upload returned, in order."""
        if len(images) != self.image_count:
            raise ValueError(f"{self.name} takes {self.image_count} image(s), got {len(images)}")
        graph = copy.deepcopy(self.graph)
        nodes = {_title(node): node for node in graph.values()}
        for index, image in enumerate(images, start=1):
            nodes[f"image {index}"]["inputs"]["image"] = image
        if prompt is not None:
            nodes["prompt"]["inputs"]["prompt"] = prompt
        if negative is not None:
            nodes["negative"]["inputs"]["prompt"] = negative
        if seed is not None:
            nodes["sampler"]["inputs"]["seed"] = seed
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


def paste_bird(scene: Image.Image, cutout: Image.Image, height_fraction: float = 0.38, ground: float = 0.72) -> Image.Image:
    """The scene with the cut-out bird (RGBA, transparent around the bird) pasted in: scaled so the bird is
    `height_fraction` of the scene's height (narrower than seven tenths of its width), centred, its lowest point at
    `ground` of the height. The painting then gives it a perch and shadows; the zoomed scene makes the size believable."""
    bird = cutout.convert("RGBA")
    bounds = bird.getchannel("A").point(lambda a: 255 if a > 127 else 0).getbbox()
    if bounds is None:
        raise ValueError("the cut-out has no bird")
    bird = bird.crop(bounds)
    scale = min(scene.height * height_fraction / bird.height, scene.width * 0.7 / bird.width)
    bird = bird.resize((max(1, round(bird.width * scale)), max(1, round(bird.height * scale))), Image.Resampling.LANCZOS)
    left = round(scene.width / 2 - bird.width / 2)
    top = round(scene.height * ground) - bird.height
    composite = scene.convert("RGB").copy()
    composite.paste(bird, (left, top), bird)
    return composite
