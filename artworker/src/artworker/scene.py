"""Scene art (issue #68): the species' reference bird painted into the glasses photo from the add.

The same steps the #49 bake-off settled and pack art (#57) uses (art/README.md, "How a painting is made"):

- the species' isolated reference bird (`packbuilder art-references`, from the pack build) as `<ref_image_0>`;
- the telephoto crop of the glasses photo as `<ref_image_1>`, zoomed for the bird's length so it is painted at card
  size and at its true size against the place, around the photo's centre, where the wearer aimed the viewfinder;
- the committed `scene-art` workflow and `prompts.json`'s scene template, in the card's edition light, with the
  Legendary light for a Legendary card. No prompt names the species: the reference is its identity.

Every painting goes through the fidelity gate (`packbuilder.fidelity`): the painted bird is cut out, registered onto
the reference bird and its colours fitted to the reference's, and it is faithful at ΔE 10 or less with the outlines
overlapping by 0.65 or more. An unfaithful painting is painted again with the next seed, three times in all. Pack art
keeps the closest for the maintainer's review; scene art has no reviewer, so a painting that never passes fails the
job and the card keeps its pack art, with Retry art (a new job, a new seed).
"""

from __future__ import annotations

import dataclasses
import io
import json
import zlib
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageOps

from packbuilder.art import ArtPrompts, Species, Workflow, telephoto_crop
from packbuilder.comfy import ComfyClient
from packbuilder.fidelity import Fidelity
from packbuilder.painting import ATTEMPTS, Painter, png

MODEL = "FLUX.3 Image Klein"
NEUTRAL_EDITION = {
    "place": "",
    "light": "the soft daylight of the photograph",
    "colors": "the place's own colours",
    "motifs": "",
}
"""A card outside the editions `prompts.json` lights (no set, or a pack without scene light yet) keeps its photo's own
light."""
JPEG_QUALITY = 88


class NoReference(Exception):
    """No reference bird for the species: it isn't in any exported pack, or its pack art was painted from text."""


class Unfaithful(Exception):
    """No painting of three kept the bird's markings."""

    def __init__(self, fidelity: Fidelity):
        super().__init__(f"the closest painting was dE {fidelity.dE_mean}, IoU {fidelity.iou}")
        self.fidelity = fidelity


def edition_prompt(prompts: ArtPrompts, kind: str, edition: str | None, legendary: bool, scientific_name: str) -> str:
    """A scene or photo prompt in the edition's light (the neutral light outside every edition), never naming the
    species: the template takes no names, an empty Species makes sure none could slip in, and a prompt that names it
    anyway is refused."""
    if edition not in prompts.editions:
        prompts = dataclasses.replace(prompts, editions={**prompts.editions, "neutral": NEUTRAL_EDITION})
        edition = "neutral"
    text = prompts.render(kind, Species("", ""), edition, legendary=legendary)  # type: ignore[arg-type]
    if scientific_name.lower() in text.lower():
        raise AssertionError("an art prompt must never name the species")
    return text


@dataclass(frozen=True)
class Reference:
    scientific_name: str
    pack: str
    bird: Path
    length_cm: float
    photo_id: int
    species_id: str


class References:
    """The reference birds of every exported pack under one folder (`<root>/<pack id>/references.json`)."""

    def __init__(self, root: Path):
        self.by_pack: dict[str, dict[str, Reference]] = {}
        for listing in sorted(Path(root).glob("*/references.json")):
            data = json.loads(listing.read_text())
            self.by_pack[data["pack"]] = {
                name: Reference(name, data["pack"], listing.parent / entry["file"], float(entry["length_cm"]), int(entry["photo_id"]), entry["species_id"])
                for name, entry in data["species"].items()
            }

    def find(self, scientific_name: str, edition: str | None) -> Reference:
        """The card's own pack's bird first, so a scene matches its pack art, else any pack's."""
        packs = ([edition] if edition in self.by_pack else []) + sorted(set(self.by_pack) - {edition})
        for pack in packs:
            if scientific_name in self.by_pack[pack]:
                return self.by_pack[pack][scientific_name]
        raise NoReference(scientific_name)


@dataclass(frozen=True)
class SceneArt:
    jpeg: bytes
    provenance: str
    fidelity: Fidelity
    seed: int


class ScenePainter:
    def __init__(self, comfy: ComfyClient, references: References, cutouts: Path | None = None, prompts: ArtPrompts | None = None):
        self.painter = Painter(comfy, cutouts=cutouts)
        self.references = references
        self.prompts = prompts or ArtPrompts.load()
        self.workflow = Workflow.load("scene-art")

    def prompt(self, edition: str | None, legendary: bool, reference: Reference) -> str:
        return edition_prompt(self.prompts, "scene", edition, legendary, reference.scientific_name)

    def paint(self, job_id: str, scene_jpeg: bytes, scientific_name: str, edition: str | None, legendary: bool) -> SceneArt:
        reference = self.references.find(scientific_name, edition)
        scene = ImageOps.exif_transpose(Image.open(io.BytesIO(scene_jpeg))).convert("RGB")
        crop = telephoto_crop(scene, reference.length_cm)
        bird = Image.open(reference.bird).convert("RGB")
        bird_mask = self.painter.mask(bird, f"references/{reference.pack}/{reference.species_id}")
        # A seed per job, so Try again (a new job) paints a new picture.
        seed = zlib.crc32(job_id.encode())
        images = [(f"bird-{reference.species_id}.png", png(bird)), (f"scene-{job_id}.png", png(crop))]
        best, tries = self.painter.best_of(
            self.workflow, images, self.prompt(edition, legendary, reference), seed, bird, bird_mask, f"scene/{job_id}", attempts=ATTEMPTS
        )
        if not best.after.faithful:
            raise Unfaithful(best.after)
        output = io.BytesIO()
        best.fitted.save(output, "JPEG", quality=JPEG_QUALITY, optimize=True)
        provenance = (
            f"{MODEL}; {self.workflow.tag} prompts@{self.prompts.version}; reference photo {reference.photo_id} ({reference.pack}); "
            f"seed {best.seed}, {tries} painting(s); dE {best.after.dE_mean}, IoU {best.after.iou}"
        )
        return SceneArt(output.getvalue(), provenance, best.after, best.seed)
