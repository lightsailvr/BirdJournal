"""Writes the tiny pack the Swift `PackTests` install from a zip (issue #13): two species, three synthetic photos,
one description, schema as `writer.py` writes it (the zip records file times, so a rebuild differs in bytes; the tests
hash the checked-in file rather than pin a digest).

    cd packbuilder && uv run python -m tests.make_fixture_pack ../BirdJournal/BirdJournalKit/Tests/PackTests/Fixtures/test-pack.zip
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
from packbuilder.writer import ChosenPhoto, SpeciesResult, write_pack
from tests.conftest import make_candidate, synthetic_photo

DEFINITION = PackDefinition(
    id="test-pack",
    name="Test Pack",
    region="Testland",
    version=1,
    place_id=1,
    bounding_box=BoundingBox(south=0, west=0, north=1, east=1),
    species=[
        SpeciesEntry(scientific_name="Sayornis nigricans", common_name="Black Phoebe", birdnet_label="Sayornis nigricans", inat_taxon_id=17013, wikipedia_url="https://en.wikipedia.org/wiki/Black_phoebe"),
        SpeciesEntry(scientific_name="Calypte anna", common_name="Anna's Hummingbird", birdnet_label="Calypte anna", inat_taxon_id=6317, wikipedia_url=None),
    ],
)


def result_for(entry: SpeciesEntry, photo_ids: list[int], work: Path, description: Description | None = None) -> SpeciesResult:
    photos = []
    for offset, photo_id in enumerate(photo_ids):
        path = work / f"src-{photo_id}.jpg"
        synthetic_photo(size=(800, 600), seed=photo_id).save(path, quality=60)
        candidate = make_candidate(photo_id=photo_id, observation_id=photo_id * 10, license="CC BY-NC" if offset else "CC0")
        score = CropScore(0.5, 0.5, 0.5, 0.5 - offset * 0.1)
        photos.append(ChosenPhoto(scored=ScoredPhoto(candidate=candidate, box=Box(0.05, 0.05, 0.95, 0.95), score=score), original=path))
    return SpeciesResult(entry=entry, photos=photos, gap=len(photo_ids) < 3, description=description)


def main(target: Path) -> None:
    work = Path(tempfile.mkdtemp(prefix="fixture-pack-"))
    try:
        phoebe = Description(
            summary="A black flycatcher of the west.", field_marks="Black with a white belly.", size="16 cm", habitat="water, coast",
            source="https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245",
        )
        results = [result_for(DEFINITION.species[0], [1, 2], work, description=phoebe), result_for(DEFINITION.species[1], [3], work)]
        target.parent.mkdir(parents=True, exist_ok=True)
        write_pack(DEFINITION, results, work / "out", built_at="2026-09-27T00:00:00Z", archive_path=target)
        print(f"wrote {target} ({target.stat().st_size} bytes)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
