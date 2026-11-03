"""Set covers (issue #114) against a stub ComfyUI: the step paints a round of candidate landscapes in the set's edition
theme, the lock pins the maintainer's choice, only an approved cover ships in the pack, and the pack index carries
its committed thumbnail."""

import base64
import io
import json
import shutil
import sqlite3
from pathlib import Path

import pytest
from PIL import Image

from packbuilder import cli
from packbuilder.comfy import ComfyClient, PaintingFailed
from packbuilder.covers import (
    APPROVED, CANDIDATES, CANVAS_SIZE, COVER_SIZE, LOCK_FILE, PENDING, REJECTED, THUMBNAIL_FILE, THUMBNAIL_SIZE, UNPAINTED, CoverLock, CoverPainter, CoverPrompts,
    StaleThumbnail, index_cover, review, round_seed,
)
from packbuilder.index import pack_index
from packbuilder.pack_art import ArtLock, PackArtist
from packbuilder.writer import write_pack
from tests.comfy_stub import serve
from tests.test_writer import definition, result_for

THEME = "citrus groves, chaparral hills and warm golden valley light"
REPO = Path(__file__).resolve().parents[2]
PACKS = REPO / "packbuilder" / "packs"
MANIFEST = json.loads((REPO / "packs" / "manifest.json").read_text())


@pytest.fixture
def comfy():
    state, server = serve()
    yield state
    server.shutdown()


def painter(tmp_path, comfy, theme=THEME):
    return CoverPainter(
        ComfyClient(comfy.url, poll_seconds=0.01), pack_id="us-ca-la", theme=theme, lock=CoverLock.load(tmp_path / LOCK_FILE),
        cache_dir=tmp_path / "cache" / "covers",
    )


def lock(tmp_path) -> dict:
    return json.loads((tmp_path / LOCK_FILE).read_text())


def test_a_round_of_candidates_is_painted_from_text_in_the_editions_theme_and_the_lock_pins_it(tmp_path, comfy):
    cover = painter(tmp_path, comfy).paint()

    assert (cover.review, cover.file, cover.ships) == (PENDING, None, False), "nothing ships before the review"
    assert len(comfy.jobs) == CANDIDATES
    first = round_seed("us-ca-la", 0)
    assert [job.seed for job in comfy.jobs] == list(range(first, first + CANDIDATES))
    for job in comfy.jobs:
        assert job.kind == "text" and job.filename_prefix == "birdjournal/set-cover"
        assert THEME in job.prompt and "no birds" in job.prompt and "no lettering" in job.prompt and "no map" in job.prompt
        assert (job.node("canvas")["inputs"]["width"], job.node("canvas")["inputs"]["height"]) == CANVAS_SIZE
    entry = lock(tmp_path)
    assert (entry["theme"], entry["workflow"], entry["prompts"], entry["model"], entry["round"], entry["review"], entry["chosen"]) == (
        THEME, "set-cover@1", CoverPrompts.load().version, "FLUX.3 Image Klein", 0, PENDING, None)
    assert [c["seed"] for c in entry["candidates"]] == list(range(first, first + CANDIDATES))
    assert len({c["sha256"] for c in entry["candidates"]}) == CANDIDATES, "each seed is its own picture"
    for candidate in entry["candidates"]:
        assert Image.open(tmp_path / "cache" / "covers" / f"{candidate['sha256']}.png").size == COVER_SIZE


def test_a_run_with_a_warm_lock_paints_nothing(tmp_path, comfy):
    painter(tmp_path, comfy).paint()
    again = painter(tmp_path, comfy)
    again.paint()
    assert len(comfy.jobs) == CANDIDATES and again.painted == 0


def test_the_contact_sheet_numbers_the_candidates_beside_the_pack_arts_sheets_and_survives_them(tmp_path, comfy):
    cover_painter = painter(tmp_path, comfy)
    cover_painter.paint()
    sheets = tmp_path / "sheets"
    sheet = cover_painter.sheet(sheets, "Citrus edition")
    assert sheet == sheets / "cover.jpg" and Image.open(sheet).width >= 2 * 768
    # The pack art redraws its own sheets into the same folder and must leave the cover's alone.
    artist = PackArtist(ComfyClient(comfy.url), pack_id="us-ca-la", theme=THEME, lock=ArtLock.load(tmp_path / "art.lock.json"), cache_dir=tmp_path / "art")
    (sheets / "sheet-07.jpg").write_bytes(b"stale")
    artist.sheets([], {}, sheets)
    assert sheet.exists() and not (sheets / "sheet-07.jpg").exists()


def test_approving_a_candidate_ships_it_and_writes_the_index_thumbnail_beside_the_lock(tmp_path, comfy):
    painter(tmp_path, comfy).paint()
    review(CoverLock.load(tmp_path / LOCK_FILE), tmp_path / "cache" / "covers", approve=3)

    cover = painter(tmp_path, comfy).paint()

    entry = lock(tmp_path)
    assert (entry["review"], entry["chosen"]) == (APPROVED, 3)
    chosen = entry["candidates"][2]
    assert cover.ships and cover.seed == chosen["seed"] and cover.file.name == f"{chosen['sha256']}.png"
    assert (cover.workflow, cover.theme, cover.model) == (f"set-cover@1 cover-prompts@{CoverPrompts.load().version}", THEME, "FLUX.3 Image Klein")
    thumbnail = tmp_path / THUMBNAIL_FILE
    with Image.open(thumbnail) as opened:
        assert (opened.format, opened.size) == ("JPEG", THUMBNAIL_SIZE)
        assert not opened.info.get("exif")
    assert entry["thumbnail"]["file"] == THUMBNAIL_FILE and len(entry["thumbnail"]["sha256"]) == 64
    assert len(comfy.jobs) == CANDIDATES


def test_review_refuses_a_number_off_the_sheet_both_choices_at_once_or_no_round(tmp_path, comfy):
    with pytest.raises(ValueError, match="no cover yet"):
        review(CoverLock.load(tmp_path / LOCK_FILE), tmp_path / "cache" / "covers", approve=1)
    painter(tmp_path, comfy).paint()
    for kwargs, message in (({"approve": 0}, "1 to 4"), ({"approve": 5}, "1 to 4"), ({"approve": 1, "reject": True}, "approve one"), ({}, "approve one")):
        with pytest.raises(ValueError, match=message):
            review(CoverLock.load(tmp_path / LOCK_FILE), tmp_path / "cache" / "covers", **kwargs)
    assert lock(tmp_path)["review"] == PENDING


def test_a_rejected_round_is_painted_again_from_new_seeds_and_its_reason_and_seeds_stay(tmp_path, comfy):
    painter(tmp_path, comfy).paint()
    review(CoverLock.load(tmp_path / LOCK_FILE), tmp_path / "cache" / "covers", approve=2)
    review(CoverLock.load(tmp_path / LOCK_FILE), tmp_path / "cache" / "covers", reject=True, why="too much sky")
    review(CoverLock.load(tmp_path / LOCK_FILE), tmp_path / "cache" / "covers", reject=True)  # twice before a repaint skips no round
    assert lock(tmp_path)["review"] == REJECTED and not (tmp_path / THUMBNAIL_FILE).exists(), "a rejected cover's thumbnail never reaches the index"
    with pytest.raises(ValueError, match="rejected"):
        review(CoverLock.load(tmp_path / LOCK_FILE), tmp_path / "cache" / "covers", approve=1)

    cover = painter(tmp_path, comfy).paint()

    entry = lock(tmp_path)
    first = round_seed("us-ca-la", 0)
    assert cover.review == PENDING and entry["round"] == 1
    assert [c["seed"] for c in entry["candidates"]] == list(range(round_seed("us-ca-la", 1), round_seed("us-ca-la", 1) + CANDIDATES))
    assert entry["rejected_seeds"] == list(range(first, first + CANDIDATES)) and entry["why"] == "too much sky"
    assert len(comfy.jobs) == 2 * CANDIDATES


def test_a_changed_theme_paints_a_new_round_for_review_and_withdraws_the_thumbnail(tmp_path, comfy):
    painter(tmp_path, comfy).paint()
    review(CoverLock.load(tmp_path / LOCK_FILE), tmp_path / "cache" / "covers", approve=1)

    cover = painter(tmp_path, comfy, theme="orange groves at dusk").paint()

    assert cover.review == PENDING and lock(tmp_path)["theme"] == "orange groves at dusk"
    assert "thumbnail" not in lock(tmp_path) and not (tmp_path / THUMBNAIL_FILE).exists()
    assert "orange groves at dusk" in comfy.jobs[-1].prompt


def test_an_approved_cover_missing_from_the_cache_is_repainted_from_its_seed(tmp_path, comfy):
    painter(tmp_path, comfy).paint()
    review(CoverLock.load(tmp_path / LOCK_FILE), tmp_path / "cache" / "covers", approve=2)
    shutil.rmtree(tmp_path / "cache")

    cover = painter(tmp_path, comfy).paint()

    assert cover.ships and cover.file.exists()
    assert comfy.jobs[-1].seed == lock(tmp_path)["candidates"][1]["seed"] and len(comfy.jobs) == CANDIDATES + 1, "only the chosen one"


def test_a_repaint_that_differs_from_the_locked_cover_goes_back_to_review(tmp_path, comfy):
    painter(tmp_path, comfy).paint()
    review(CoverLock.load(tmp_path / LOCK_FILE), tmp_path / "cache" / "covers", approve=2)
    shutil.rmtree(tmp_path / "cache")
    comfy.cover_drift = 5

    cover = painter(tmp_path, comfy).paint()

    entry = lock(tmp_path)
    assert cover.review == PENDING and not cover.ships and entry["chosen"] is None
    assert "thumbnail" not in entry and not (tmp_path / THUMBNAIL_FILE).exists()


def test_comfyui_out_of_reach_leaves_the_set_without_a_cover_and_the_lock_untouched(tmp_path, comfy, monkeypatch):
    def unreachable(*args, **kwargs):
        raise PaintingFailed("ComfyUI at http://comfybox:8189: connection refused")

    cover_painter = painter(tmp_path, comfy)
    monkeypatch.setattr(cover_painter.client, "paint", unreachable)
    cover = cover_painter.paint()
    assert cover.review == UNPAINTED and not cover.ships
    assert not (tmp_path / LOCK_FILE).exists()


def test_the_pack_carries_only_an_approved_cover_with_its_illustration_credit(tmp_path, comfy):
    pack = definition()
    results = [result_for(pack.species[0], [1], tmp_path), result_for(pack.species[1], [2], tmp_path)]
    pending = painter(tmp_path, comfy).paint()

    written = write_pack(pack, results, tmp_path / "pending", built_at="2026-11-02T00:00:00Z", cover=pending)

    assert sqlite3.connect(written.database).execute("SELECT COUNT(*) FROM cover").fetchone()[0] == 0
    assert not (tmp_path / "pending" / "cover.avif").exists() and "Set cover" not in (tmp_path / "pending" / "LICENSE").read_text()
    assert json.loads((tmp_path / "pending" / "report.json").read_text())["cover"] == {"review": PENDING, "ships": False, "seed": None}

    review(CoverLock.load(tmp_path / LOCK_FILE), tmp_path / "cache" / "covers", approve=4)
    approved = painter(tmp_path, comfy).paint()
    written = write_pack(pack, results, tmp_path / "approved", built_at="2026-11-02T00:00:00Z", cover=approved)

    [(file, workflow, seed, model)] = sqlite3.connect(written.database).execute("SELECT file, workflow_version, seed, model FROM cover").fetchall()
    assert (file, workflow, seed, model) == ("cover.avif", approved.workflow, approved.seed, "FLUX.3 Image Klein")
    with Image.open(tmp_path / "approved" / "cover.avif") as opened:
        assert (opened.format, opened.size) == ("AVIF", COVER_SIZE)
    license_text = (tmp_path / "approved" / "LICENSE").read_text()
    assert "Set cover" in license_text and "AI illustration, not a photograph" in license_text
    assert f"workflow {approved.workflow}, seed {approved.seed}" in license_text and "FLUX.3 Image Klein" in license_text and THEME in license_text
    assert json.loads((tmp_path / "approved" / "report.json").read_text())["cover"] == {"review": APPROVED, "ships": True, "seed": approved.seed}


def test_a_pack_built_without_a_cover_step_has_an_empty_cover_table(tmp_path):
    pack = definition()
    written = write_pack(pack, [result_for(pack.species[0], [1], tmp_path)], tmp_path / "out", built_at="2026-11-02T00:00:00Z")
    assert sqlite3.connect(written.database).execute("SELECT COUNT(*) FROM cover").fetchone()[0] == 0
    assert "cover" not in json.loads((tmp_path / "out" / "report.json").read_text())


def definitions_with_cover(tmp_path, comfy, approve: int | None = 2) -> Path:
    """The us-ca-la definition copied with a painted cover, approved when `approve` is a number."""
    folder = tmp_path / "packs" / "us-ca-la"
    folder.mkdir(parents=True)
    for name in ("pack.json", "set.json"):
        shutil.copy(PACKS / "us-ca-la" / name, folder / name)
    CoverPainter(ComfyClient(comfy.url, poll_seconds=0.01), "us-ca-la", THEME, CoverLock.load(folder / LOCK_FILE), tmp_path / "covers").paint()
    if approve is not None:
        review(CoverLock.load(folder / LOCK_FILE), tmp_path / "covers", approve=approve)
    return folder


def test_the_index_carries_an_approved_covers_thumbnail_and_credit(tmp_path, comfy):
    folder = definitions_with_cover(tmp_path, comfy)
    manifest = {"packs": [p for p in MANIFEST["packs"] if p["id"] == "us-ca-la"]}

    [entry] = pack_index(manifest, folder.parent, "lightsailvr/BirdJournal")["packs"]

    cover = entry["cover"]
    data = base64.b64decode(cover["thumbnail"])
    assert data == (folder / THUMBNAIL_FILE).read_bytes()
    with Image.open(io.BytesIO(data)) as opened:
        assert (opened.format, opened.size) == ("JPEG", THUMBNAIL_SIZE)
    chosen = lock(folder)["candidates"][1]
    assert (cover["width"], cover["height"], cover["model"], cover["seed"]) == (*THUMBNAIL_SIZE, "FLUX.3 Image Klein", chosen["seed"])
    assert cover["workflowVersion"] == f"set-cover@1 cover-prompts@{CoverPrompts.load().version}"
    assert len(data) < 60_000, "small enough to fetch with the index on every refresh"


def test_the_index_has_no_cover_for_a_set_without_an_approved_one(tmp_path, comfy):
    folder = definitions_with_cover(tmp_path, comfy, approve=None)
    assert index_cover(folder) is None
    assert index_cover(tmp_path / "nowhere") is None
    [entry] = pack_index({"packs": [p for p in MANIFEST["packs"] if p["id"] == "us-ca-la"]}, folder.parent, "lightsailvr/BirdJournal")["packs"]
    assert "cover" not in entry


def test_a_missing_or_stale_thumbnail_is_never_published(tmp_path, comfy):
    folder = definitions_with_cover(tmp_path, comfy)
    (folder / THUMBNAIL_FILE).write_bytes(b"not the approved one")
    with pytest.raises(StaleThumbnail, match="isn't the approved cover's thumbnail"):
        index_cover(folder)
    (folder / THUMBNAIL_FILE).unlink()
    with pytest.raises(StaleThumbnail):
        pack_index({"packs": [p for p in MANIFEST["packs"] if p["id"] == "us-ca-la"]}, folder.parent, "lightsailvr/BirdJournal")


def test_the_cover_and_cover_review_commands_paint_draw_and_approve(tmp_path, comfy, capsys):
    folder = tmp_path / "us-ca-la"
    folder.mkdir()
    for name in ("pack.json", "set.json"):
        shutil.copy(PACKS / "us-ca-la" / name, folder / name)
    common = ["--cache", str(tmp_path / "cache"), "--sheets", str(tmp_path / "sheets")]

    assert cli.main(["cover", str(folder), "--comfy", comfy.url, *common]) == 0
    assert (tmp_path / "sheets" / "cover.jpg").exists() and lock(folder)["theme"] == json.loads((folder / "set.json").read_text())["edition"]["theme"]
    assert cli.main(["cover-review", str(folder), "--approve", "9", *common]) == 1
    assert cli.main(["cover-review", str(folder), "--approve", "1", *common]) == 0

    assert lock(folder)["chosen"] == 1 and (folder / THUMBNAIL_FILE).exists()
    assert "approved, candidate 1" in capsys.readouterr().err
    assert len(comfy.jobs) == CANDIDATES, "reviewing paints nothing"
