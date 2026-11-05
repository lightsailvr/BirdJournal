"""Thumbnails for the art CDN (issues #62 and #136): one small image per painting, keyed as the phone's find policy sends
it: a JPEG for pack art, a PNG for a patch, which is cut out on transparency."""

import sqlite3
from pathlib import Path

from PIL import Image

from packbuilder.cli import main
from packbuilder.thumbnails import THUMBNAIL_LONG_SIDE, patch_thumbnail_key, thumbnail_key, write_thumbnails


def _pack(directory: Path, *, art: dict[str, tuple[int, int]] | None, patches: dict[str, tuple[int, int]] | None = None) -> Path:
    (directory / "art").mkdir(parents=True)
    (directory / "patch").mkdir()
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
    if patches is not None:
        database.execute("CREATE TABLE patch (species_id TEXT, file TEXT)")
        for species, size in patches.items():
            file = f"patch/{species}.avif"
            exif = Image.Exif()
            exif[0x010F] = "Camera maker that must not travel"
            # Corners clear, as a patch is cut out of its card.
            painting = Image.new("RGBA", size, (0, 0, 0, 0))
            painting.paste((180, 120, 60, 255), (size[0] // 4, size[1] // 4, size[0] * 3 // 4, size[1] * 3 // 4))
            painting.save(directory / file, "AVIF", exif=exif)
            database.execute("INSERT INTO patch VALUES (?, ?)", (species, file))
    database.commit()
    database.close()
    return directory


def test_the_key_is_the_one_the_phone_sends() -> None:
    assert thumbnail_key("us-ca-la", "art/sayornis-nigricans.avif") == "packs/us-ca-la/sayornis-nigricans.jpg"


def test_a_patchs_key_is_the_one_the_phone_sends() -> None:
    # `FindPolicy.patchArtKey` in the app, under packs/, which the deployed server's art key rule takes.
    assert patch_thumbnail_key("us-ca-la", "patch/sayornis-nigricans.avif") == "packs/us-ca-la/patch/sayornis-nigricans.png"


def test_every_patch_gets_a_small_cut_out_png_without_metadata(tmp_path: Path) -> None:
    pack = _pack(tmp_path / "pack", art={}, patches={"sayornis-nigricans": (720, 720), "troglodytes-aedon": (200, 120)})
    written = write_thumbnails(pack, tmp_path / "out")

    assert sorted(written) == ["packs/us-ca-la/patch/sayornis-nigricans.png", "packs/us-ca-la/patch/troglodytes-aedon.png"]
    path = written["packs/us-ca-la/patch/sayornis-nigricans.png"]
    assert path == tmp_path / "out" / "patch" / "sayornis-nigricans.png"
    with Image.open(path) as thumbnail:
        assert thumbnail.format == "PNG"
        assert thumbnail.size == (THUMBNAIL_LONG_SIDE, THUMBNAIL_LONG_SIDE)
        assert not thumbnail.getexif()
        assert thumbnail.convert("RGBA").getpixel((0, 0))[3] == 0, "the corners stay transparent"
        assert thumbnail.convert("RGBA").getpixel((160, 160))[3] == 255
    with Image.open(written["packs/us-ca-la/patch/troglodytes-aedon.png"]) as small:
        assert small.size == (200, 120), "never enlarged"


def test_a_pack_with_both_writes_both(tmp_path: Path) -> None:
    pack = _pack(tmp_path / "pack", art={"sayornis-nigricans": (640, 480)}, patches={"sayornis-nigricans": (720, 720)})
    assert sorted(write_thumbnails(pack, tmp_path / "out")) == [
        "packs/us-ca-la/patch/sayornis-nigricans.png",
        "packs/us-ca-la/sayornis-nigricans.jpg",
    ]


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
