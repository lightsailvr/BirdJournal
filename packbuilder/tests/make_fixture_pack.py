"""Writes the tiny pack the Swift `PackTests` install from a zip (issue #13): two species, three synthetic photos,
one description, one reference sound (issue #41, a 2 s tone encoded as the builder encodes clips; needs ffmpeg),
schema as `writer.py` writes it (the zip records file times, so a rebuild differs in bytes; the tests
hash the checked-in file rather than pin a digest).

    cd packbuilder && uv run python -m tests.make_fixture_pack ../BirdJournal/BirdJournalKit/Tests/PackTests/Fixtures/test-pack.zip
    cd packbuilder && uv run python -m tests.make_fixture_pack ../BirdJournal/BirdJournalKit/Tests/PackTests/Fixtures/us-ca-la-v2.zip us-ca-la 2

The second form writes the same two species under another pack id and version: the `PackLibrary` test's newer
version of the bundled Los Angeles pack (issue #33). `test-pack-schema2.zip` beside them is the schema-2 pack from
before #41 and `test-pack-schema3.zip` the schema-3 pack from before #54, kept as written then, which the reader must
still open. Since #54 the test pack carries a set (`CARD_SET`): a box around Testland with its two species. Since #55
it carries `JOINED`: stats and a type line for the phoebe, and the hummingbird as a known gap with a type line and the
threatened flag from the hand list. Since #57 the Black Phoebe has approved pack art painted from its photo 1 and the
hummingbird is an art gap. Since #56 both carry a fact sheet (`FACTS`), and the phoebe approved lore (`LORE`) whose
sources are a dataset and its Wikipedia revision; the hummingbird has none. Since #113 the phoebe's lore carries an
approved story title; `test-pack-untitled.zip` beside it is the schema-4 pack from before, whose `lore` table has no
`title` column, kept as written then. Since #114 the test pack has an approved set cover (`COVER_SEED`, a 1536 x 864
landscape of bands); the Los Angeles form, like every pack built before covers, has none.

    cd packbuilder && uv run python -m tests.make_fixture_pack ../BirdJournal/BirdJournalKit/Tests/PackTests/Fixtures/north-america-stand-in.zip north-america 1

The third form (issue #215) is a stand-in for the North America pack, for the tests that need it on a phone as a
download beside the bundled pack before the real one exists: the committed set (`packs/north-america/set.json`: its
300 birds in order, its boundary, the Continental edition) with two of its birds, the Red-tailed Hawk and the Mallard
(both also in the Los Angeles set, so a test can find one bird in either set's place: the Swift tests' `BundledPack.hawk`
and `.mallard`), each with drawn photos and an approved patch that is a drawing too (`stand_in_patch`: the edition's wide
rectangle in its cord and twill), never one of the pack's paintings, which only the maintainer's review lets into a pack.
"""

from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

from packbuilder.definition import BoundingBox, PackDefinition, SpeciesEntry
from packbuilder.descriptions import Description
from packbuilder.geometry import Box
from packbuilder.scoring import CropScore
from packbuilder.selection import ScoredPhoto
from packbuilder.audio import ClipMaker
from packbuilder.covers import COVER_SIZE, Cover
from packbuilder.factsheet import Fact
from packbuilder.lore import Lore
from packbuilder.pack_art import Artwork
from packbuilder.sounds import ChosenSound, SoundCandidate, SoundResult
from packbuilder.stats import JoinedSpecies, SpeciesStats, Threat, TypeLine
from packbuilder.writer import ChosenPhoto, SpeciesResult, write_pack
from PIL import Image
from tests.comfy_stub import bird_on, landscape
from tests.conftest import make_candidate, synthetic_photo

NORTH_AMERICA = "north-america"
REPO_PACKS = Path(__file__).resolve().parents[1] / "packs"
CONTINENTAL_CORD, CONTINENTAL_TWILL = (201, 143, 42), (191, 179, 196)
"""The Continental edition's cord and twill (#214: `#C98F2A`, `#BFB3C4`)."""


def stand_in_definition(version: int) -> PackDefinition:
    """The North America definition's own fields with two of its birds."""
    whole = PackDefinition.load(REPO_PACKS / NORTH_AMERICA / "pack.json")
    return whole.only(["buteo-jamaicensis", "anas-platyrhynchos"])


def stand_in_patch(colours: tuple[tuple[int, int, int], tuple[int, int, int]]) -> Image.Image:
    """A drawn Continental patch as `cut_from_card` would leave a painted one: the wide rectangle, 1.42 to 1, 720 px
    on its long side, on transparency, its cord and twill with a little grain (flat colour has no thread to light) and
    a two-tone bird."""
    import numpy as np
    from PIL import ImageDraw

    width, height = 720, round(720 / 1.42)
    patch = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(patch)
    draw.rounded_rectangle((0, 0, width - 1, height - 1), round(height * 0.1), fill=(*CONTINENTAL_CORD, 255))
    draw.rounded_rectangle((25, 25, width - 26, height - 26), round(height * 0.1) - 25, fill=(*CONTINENTAL_TWILL, 255))
    bird = Image.new("RGB", (width, height), CONTINENTAL_TWILL)
    bird_on(bird, box=(0.38, 0.2, 0.62, 0.82), colours=colours)
    mask = Image.fromarray((np.any(np.asarray(bird) != np.array(CONTINENTAL_TWILL), axis=-1) * 255).astype(np.uint8))
    patch.paste(bird, (0, 0), mask)
    pixels = np.asarray(patch).astype(int)
    grain = np.random.default_rng(215).integers(-10, 11, size=(height, width, 1))
    pixels[..., :3] = np.clip(pixels[..., :3] + grain, 0, 255)
    return Image.fromarray(pixels.astype(np.uint8), "RGBA")


def stand_in_main(target: Path, version: int) -> None:
    import json

    from packbuilder.patch_art import Patch

    pack = stand_in_definition(version)
    card_set = json.loads((REPO_PACKS / NORTH_AMERICA / "set.json").read_text())
    work = Path(tempfile.mkdtemp(prefix="fixture-pack-"))
    try:
        hawk, mallard = pack.species
        described = Description(summary="A stand-in for the North America pack's hawk.", field_marks="Brown above, pale below, a brick-red tail.", size="50 cm", habitat="open country, woods",
                                source="https://en.wikipedia.org/w/index.php?title=Red-tailed_hawk&oldid=1")
        results = [result_for(hawk, [215001, 215002, 215003], work, description=described), result_for(mallard, [215011, 215012, 215013], work)]
        patches = {}
        for result, colours in ((results[0], ((120, 84, 56), (176, 84, 44))), (results[1], ((30, 104, 62), (150, 150, 150)))):
            result.sounds = SoundResult()
            file = work / f"{result.entry.id}.png"
            stand_in_patch(colours).save(file)
            patches[result.entry.id] = Patch(result.entry.id, "approved", file, (result.photos[0].candidate.photo_id,))
        target.parent.mkdir(parents=True, exist_ok=True)
        write_pack(pack, results, work / "out", built_at="2026-11-26T00:00:00Z", archive_path=target, card_set=card_set, patches=patches,
                   patch_versions="a drawing standing in for a painting (tests/make_fixture_pack.py)")
        print(f"wrote {target} ({target.stat().st_size} bytes)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


def definition(pack_id: str = "test-pack", version: int = 1) -> PackDefinition:
    return PackDefinition(
        id=pack_id,
        name="Test Pack" if pack_id == "test-pack" else "Los Angeles",
        region="Testland",
        version=version,
    place_ids=(1,),
    bounding_box=BoundingBox(south=0, west=0, north=1, east=1),
        species=[
            SpeciesEntry(scientific_name="Sayornis nigricans", common_name="Black Phoebe", birdnet_label="Sayornis nigricans", inat_taxon_id=17013, wikipedia_url="https://en.wikipedia.org/wiki/Black_phoebe"),
            SpeciesEntry(scientific_name="Calypte anna", common_name="Anna's Hummingbird", birdnet_label="Calypte anna", inat_taxon_id=6317, wikipedia_url=None),
        ],
    )


CARD_SET = {
    "id": "test-pack", "name": "Test Pack", "edition": {"name": "Test edition", "theme": "a test card's light"}, "taxonomy": "IOC World Bird List 15.1",
    "regions": [{"name": "Testland", "source": "hand-drawn polygon committed with the pack definition (regions/testland.geojson)", "polygons": [[[[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [0.0, 0.0]]]]}],
    "species": [{"scientificName": "Calypte anna", "commonName": "Anna's Hummingbird"}, {"scientificName": "Sayornis nigricans", "commonName": "Black Phoebe"}],
}


JOINED = {
    "Sayornis nigricans": JoinedSpecies(
        stats=SpeciesStats(
            avibase_id="AVIBASE-BLPH", wingspan_cm=27.5, wingspan_predicted=True, mass_g=18.6, diet="invertivore", habitat="riverine",
            migration="resident", nest=("half_cup", "cup"), clutch_min=3.0, clutch_max=6.0, lifestyle="insessorial", sources=("avonet", "birdbase", "wingspan"),
        ),
        type_line=TypeLine(order="Passeriformes", family="Tyrannidae", group_word="Songbird", family_word="Phoebe"),
        threat=Threat(threatened=False, iucn_category="LC", source="BIRDBASE: IUCN Red List 2024"),
    ),
    "Calypte anna": JoinedSpecies(
        stats=None,
        type_line=TypeLine(order="Caprimulgiformes", family="Trochilidae", group_word="Landbird", family_word="Hummingbird"),
        threat=Threat(threatened=True, iucn_category="LC", source="hand list: a test"),
    ),
}


COVER_SEED = 2471396767
COVER_WORKFLOW = "set-cover@1 cover-prompts@1"


REVISION = "https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245"
FACTS = {
    "sayornis-nigricans": [
        Fact("f1", "It feeds mostly on insects and other invertebrates.", "avonet"),
        Fact("f2", "The black phoebe hunts from a low perch, flying out to catch insects in the air.", REVISION),
    ],
    "calypte-anna": [Fact("f1", "It feeds mostly on nectar.", "avonet")],
}
LORE = {
    "sayornis-nigricans": Lore(
        "sayornis-nigricans", "approved",
        (
            {"text": "Where water runs, the dark sentinel keeps its low perch and waits.", "facts": ["f2"]},
            {"text": "No gnat crosses that air unseen, for insects are its bread.", "facts": ["f1", "f2"]},
        ),
        {"text": "Keeper of the low perch.", "facts": ["f2"]},
        tuple(FACTS["sayornis-nigricans"]),
        title={"text": "The Waterside Sentinel", "facts": ["f2"], "model": "claude-opus-5-5", "prompt_version": 5, "review": "approved"},
    ),
}


def result_for(entry: SpeciesEntry, photo_ids: list[int], work: Path, description: Description | None = None) -> SpeciesResult:
    photos = []
    for offset, photo_id in enumerate(photo_ids):
        path = work / f"src-{photo_id}.jpg"
        synthetic_photo(size=(800, 600), seed=photo_id).save(path, quality=60)
        candidate = make_candidate(photo_id=photo_id, observation_id=photo_id * 10, license="CC BY-NC" if offset else "CC0")
        score = CropScore(0.5, 0.5, 0.5, 0.5 - offset * 0.1)
        photos.append(ChosenPhoto(scored=ScoredPhoto(candidate=candidate, box=Box(0.05, 0.05, 0.95, 0.95), score=score), original=path))
    return SpeciesResult(entry=entry, photos=photos, gap=len(photo_ids) < 3, description=description)


def tone_sound(work: Path) -> ChosenSound:
    """A 2 s 3 kHz tone through the builder's clip maker, credited as a xeno-canto song."""
    import subprocess

    wav = work / "tone.wav"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=3000:duration=2", "-ac", "1", str(wav)], check=True)
    clip = ClipMaker().make(wav, work / "xc-1.m4a")
    candidate = SoundCandidate(
        id="xc-1", source="xeno-canto", catalogue="XC1", kind="song", file_url="https://xeno-canto.org/1/download", extension="wav",
        recordist="Jane Recordist", license="CC BY-SA 4.0", source_url="https://xeno-canto.org/1", quality="A",
    )
    return ChosenSound(candidate=candidate, kind="song", clip=clip, score=1.0)


def main(target: Path, pack_id: str = "test-pack", version: int = 1) -> None:
    if pack_id == NORTH_AMERICA:
        return stand_in_main(target, version)
    pack = definition(pack_id, version)
    work = Path(tempfile.mkdtemp(prefix="fixture-pack-"))
    try:
        phoebe = Description(
            summary="A black flycatcher of the west.", field_marks="Black with a white belly.", size="16 cm", habitat="water, coast",
            source="https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245",
        )
        results = [result_for(pack.species[0], [1, 2], work, description=phoebe), result_for(pack.species[1], [3], work)]
        results[0].sounds = SoundResult(sounds=[tone_sound(work)])
        results[1].sounds = SoundResult()
        target.parent.mkdir(parents=True, exist_ok=True)
        card_set = CARD_SET if pack_id == "test-pack" else None
        joined = JOINED if pack_id == "test-pack" else None
        art = None
        if pack_id == "test-pack":
            painting = work / "painting.png"
            bird_on(Image.new("RGB", (864, 1152), (246, 240, 228))).save(painting)
            art = {
                "sayornis-nigricans": Artwork("sayornis-nigricans", "approved", painting, (1,), "pack-art@3 bird-isolate@1 prompts@8", True),
                "calypte-anna": Artwork("calypte-anna", "gap", None, (3,), "pack-art@3 bird-isolate@1 prompts@8"),
            }
        facts = FACTS if pack_id == "test-pack" else None
        lore = LORE if pack_id == "test-pack" else None
        cover = None
        if pack_id == "test-pack":
            landscape(COVER_SIZE, COVER_SEED).save(work / "cover.png")
            cover = Cover("approved", work / "cover.png", COVER_SEED, COVER_WORKFLOW, CARD_SET["edition"]["theme"])
        write_pack(pack, results, work / "out", built_at="2026-09-27T00:00:00Z", archive_path=target, card_set=card_set, joined=joined, art=art, facts=facts, lore=lore,
                   cover=cover)
        print(f"wrote {target} ({target.stat().st_size} bytes)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main(Path(sys.argv[1]), *([sys.argv[2], int(sys.argv[3])] if len(sys.argv) > 3 else []))
