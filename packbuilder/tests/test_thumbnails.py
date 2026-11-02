"""Pack-art thumbnails for the art CDN (issue #62): one small JPEG per painting, keyed as the phone's find policy sends it."""

import sqlite3
from pathlib import Path

from PIL import Image

from packbuilder.cli import main
from packbuilder.thumbnails import THUMBNAIL_LONG_SIDE, thumbnail_key, write_thumbnails


def _pack(directory: Path, *, art: dict[str, tuple[int, int]] | None) -> Path:
    (directory / "art").mkdir(parents=True)
    database = sqlite3.connect(directory / "pack.sqlite")
    database.execute("CREATE TABLE pack (id TEXT)")
    database.execute("INSERT INTO pack VALUES ('us-ca-la')")
    if art is not None:
        database.execute("CREATE TABLE pack_art (species_id TEXT, file TEXT, source_photo_ids TEXT, workflow_version TEXT)")
        for species, size in art.items():
            file = f"art/{species}.avif"
            painting = Image.new("RGB", size, (180, 120, 60))
            exif = Image.Exif()
            exif[0x010F] = "Camera maker that must not travel"
            painting.save(directory / file, "AVIF", exif=exif)
            database.execute("INSERT INTO pack_art VALUES (?, ?, '[]', 'v1')", (species, file))
    database.commit()
    database.close()
    return directory


def test_the_key_is_the_one_the_phone_sends() -> None:
    assert thumbnail_key("us-ca-la", "art/sayornis-nigricans.avif") == "packs/us-ca-la/sayornis-nigricans.jpg"


def test_every_painting_gets_a_small_jpeg_without_metadata(tmp_path: Path) -> None:
    pack = _pack(tmp_path / "pack", art={"sayornis-nigricans": (1024, 1536), "troglodytes-aedon": (200, 120)})
    written = write_thumbnails(pack, tmp_path / "out")

    assert sorted(written) == ["packs/us-ca-la/sayornis-nigricans.jpg", "packs/us-ca-la/troglodytes-aedon.jpg"]
    with Image.open(written["packs/us-ca-la/sayornis-nigricans.jpg"]) as thumbnail:
        assert thumbnail.format == "JPEG"
        assert thumbnail.size == (213, THUMBNAIL_LONG_SIDE)
        assert not thumbnail.getexif()
    with Image.open(written["packs/us-ca-la/troglodytes-aedon.jpg"]) as small:
        assert small.size == (200, 120), "never enlarged"


def test_a_pack_without_art_writes_none(tmp_path: Path) -> None:
    assert write_thumbnails(_pack(tmp_path / "old", art=None), tmp_path / "out") == {}
    assert write_thumbnails(_pack(tmp_path / "bare", art={}), tmp_path / "out2") == {}


def test_the_command_writes_them(tmp_path: Path, capsys: object) -> None:
    pack = _pack(tmp_path / "pack", art={"sayornis-nigricans": (640, 480)})
    assert main(["thumbnails", str(pack), "--out", str(tmp_path / "out")]) == 0
    assert (tmp_path / "out" / "sayornis-nigricans.jpg").exists()
