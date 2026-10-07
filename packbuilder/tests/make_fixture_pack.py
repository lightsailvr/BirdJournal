"""Writes the tiny pack the Swift `PackTests` install from a zip (issue #13): two species, three synthetic photos,
one description, one reference sound (issue #41, a 2 s tone encoded as the builder encodes clips; needs ffmpeg),
schema as `writer.py` writes it (the zip records file times, so a rebuild differs in bytes; the tests
hash the checked-in file rather than pin a digest).

    cd packbuilder && uv run python -m tests.make_fixture_pack ../BirdJournal/BirdJournalKit/Tests/PackTests/Fixtures/test-pack.zip
    cd packbuilder && uv run python -m tests.make_fixture_pack ../BirdJournal/BirdJournalKit/Tests/PackTests/Fixtures/us-ca-la-v2.zip us-ca-la 2

The second form writes the same two species under another pack id and version: the `PackLibrary` test's newer
version of the bundled Los Angeles pack (issue #33). `test-pack-schema2.zip` beside them is the schema-2 pack from
before #41, kept as written then, which the reader must still open.
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
from packbuilder.sounds import ChosenSound, SoundCandidate, SoundResult
from packbuilder.writer import ChosenPhoto, SpeciesResult, write_pack
from tests.conftest import make_candidate, synthetic_photo

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
        write_pack(pack, results, work / "out", built_at="2026-09-27T00:00:00Z", archive_path=target)
        print(f"wrote {target} ({target.stat().st_size} bytes)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main(Path(sys.argv[1]), *([sys.argv[2], int(sys.argv[3])] if len(sys.argv) > 3 else []))
