"""The mascot patches (issue #150, slice 11) against a stub ComfyUI: a round of numbered candidates per bird from its app
icon, a warm lock paints nothing, only what the maintainer picks ships, and a rejected bird paints a new round."""

import hashlib
import io
import json
import shutil

import numpy as np
import pytest
from PIL import Image, ImageDraw

from packbuilder import cli
from packbuilder.comfy import ComfyClient
from packbuilder.mascot_art import APP_ICONS, FELT_PICTURE, PERCHED_FINCH, PRIMARY_ICON, REPO, SIZE, MascotArtist, MascotBird, MascotLock, MascotPrompts, StaleApproval, approved, draw_sheets, review, shipped, write_app_assets
from tests.comfy_stub import BACKGROUND, bird_on, serve

FINCH, EGRET = "house-finch", "great-egret"
ROUND = (("bust", "tan"), ("whole", "peach"))
SPECIES_WORDS = ("finch", "egret", "warbler", "hawk", "jay")


@pytest.fixture
def comfy():
    state, server = serve()
    yield state
    server.shutdown()


@pytest.fixture
def prompts() -> MascotPrompts:
    real = MascotPrompts.load()
    birds = tuple(MascotBird(bird.id, bird.title, f"icons/{bird.id}.png", bird.markings, ROUND, bird.compositions) for bird in real.birds if bird.id in (FINCH, EGRET))
    return MascotPrompts(real.version, real.template, real.grounds, real.compositions, birds)


def artist(tmp_path, comfy, prompts) -> MascotArtist:
    (tmp_path / "icons").mkdir(exist_ok=True)
    for index, bird in enumerate(prompts.birds):
        target = tmp_path / bird.icon
        if not target.exists():
            bird_on(Image.new("RGB", (1024, 1024), BACKGROUND), colours=((180, 60 + index * 40, 40), (120, 95, 70))).save(target)
    return MascotArtist(ComfyClient(comfy.url, poll_seconds=0.01), MascotLock.load(tmp_path / "mascot" / "mascot.lock.json"), tmp_path / "cache", prompts, repo=tmp_path)


def reload(tmp_path) -> MascotLock:
    return MascotLock.load(tmp_path / "mascot" / "mascot.lock.json")


def test_the_committed_prompts_describe_the_glasses_and_never_name_the_species():
    prompts = MascotPrompts.load()
    assert [bird.id for bird in prompts.birds] == [FINCH, "perched-finch", "blue-bird", EGRET, "prothonotary-warbler", "red-tailed-hawk", "stellers-jay"]
    for bird in prompts.birds:
        for composition, ground in bird.round:
            text = prompts.render(bird, composition, ground)
            assert "glasses" in text and "binoculars" in text and bird.markings in text
            assert not any(word in text.lower() for word in SPECIES_WORDS)


def test_every_committed_icon_exists():
    prompts = MascotPrompts.load()
    for bird in prompts.birds:
        assert (REPO / bird.icon).exists(), bird.icon


def test_a_bird_can_swap_a_composition_for_its_own():
    prompts = MascotPrompts.load()
    assert "wading" in prompts.render(prompts.bird(EGRET), "whole", "tan")
    assert "branch" in prompts.render(prompts.bird(FINCH), "whole", "tan")


def test_a_round_paints_numbered_candidates_from_the_icon_on_white_and_cuts_them_at_icon_size(tmp_path, comfy, prompts):
    painter = artist(tmp_path, comfy, prompts)
    painter.paint()
    assert len(comfy.paintings) == 4 and all(job.filename_prefix == "birdjournal/mascot-patch" for job in comfy.paintings)
    lock = reload(tmp_path)
    numbers = [candidate["number"] for bird in (FINCH, EGRET) for candidate in lock.birds[bird]["candidates"]]
    assert numbers == [1, 2, 3, 4] and lock.next_number == 5
    entry = lock.birds[FINCH]
    assert entry["review"] == "pending" and entry["workflow"].startswith("mascot-patch@") and entry["prompts"] == prompts.version
    assert entry["icon_sha256"] == hashlib.sha256((tmp_path / f"icons/{FINCH}.png").read_bytes()).hexdigest()
    assert [(c["composition"], c["ground"]) for c in entry["candidates"]] == list(ROUND)
    uploaded = Image.open(io.BytesIO(comfy.paintings[0].images[0])).convert("RGB")
    assert uploaded.getpixel((2, 2)) == (255, 255, 255)
    with Image.open(tmp_path / "cache" / "patches" / f"{entry['candidates'][0]['sha256']}.png") as patch:
        assert max(patch.size) == SIZE and patch.mode == "RGBA" and patch.getpixel((1, 1))[3] == 0


def test_a_warm_lock_paints_nothing_and_a_lost_candidate_comes_back_from_its_seed(tmp_path, comfy, prompts):
    artist(tmp_path, comfy, prompts).paint()
    before = reload(tmp_path).birds[FINCH]["candidates"]
    painted = len(comfy.paintings)
    artist(tmp_path, comfy, prompts).paint()
    assert len(comfy.paintings) == painted
    (tmp_path / "cache" / "patches" / f"{before[0]['sha256']}.png").unlink()  # the stub's candidates share a picture, so the first comes back
    artist(tmp_path, comfy, prompts).paint()
    assert len(comfy.paintings) == painted + 1 and comfy.paintings[-1].seed == before[0]["seed"]
    assert reload(tmp_path).birds[FINCH]["candidates"][0]["number"] == before[0]["number"]


def test_an_interrupted_round_finishes_where_it_stopped(tmp_path, comfy, prompts):
    painter = artist(tmp_path, comfy, prompts)
    painter.paint([FINCH])
    lock = reload(tmp_path)
    lock.birds[FINCH]["candidates"].pop()
    lock.next_number -= 1
    lock.write()
    painter = artist(tmp_path, comfy, prompts)
    painter.paint([FINCH])
    assert [c["number"] for c in reload(tmp_path).birds[FINCH]["candidates"]] == [1, 2]
    assert reload(tmp_path).birds[FINCH]["candidates"][1]["composition"] == "whole"


def test_nothing_ships_until_a_number_is_approved_and_the_approved_file_is_checked(tmp_path, comfy, prompts):
    artist(tmp_path, comfy, prompts).paint()
    lock = reload(tmp_path)
    assert approved(lock) == {}
    review(lock, tmp_path / "cache", approve=[2])
    lock = reload(tmp_path)
    entry = lock.birds[FINCH]
    assert entry["review"] == "approved" and entry["chosen"] == 2 and lock.birds[EGRET]["review"] == "pending"
    path = approved(lock)[FINCH]
    assert path == tmp_path / "mascot" / "approved" / f"{FINCH}.png" and list(approved(lock)) == [FINCH]
    with Image.open(path) as patch:
        assert max(patch.size) == SIZE
    path.write_bytes(b"not the patch")
    with pytest.raises(StaleApproval):
        approved(lock)


def test_an_approved_bird_paints_nothing_even_with_its_candidates_gone(tmp_path, comfy, prompts):
    artist(tmp_path, comfy, prompts).paint()
    lock = reload(tmp_path)
    review(lock, tmp_path / "cache", approve=[1, 3])
    for path in (tmp_path / "cache" / "patches").glob("*.png"):
        path.unlink()
    painted = len(comfy.paintings)
    artist(tmp_path, comfy, prompts).paint()
    assert len(comfy.paintings) == painted


@pytest.mark.parametrize("approve", ([99], [1, 2]))
def test_a_bad_pick_changes_nothing(tmp_path, comfy, prompts, approve):
    artist(tmp_path, comfy, prompts).paint()
    lock = reload(tmp_path)
    before = (tmp_path / "mascot" / "mascot.lock.json").read_text()
    with pytest.raises(ValueError):
        review(lock, tmp_path / "cache", approve=approve)
    assert (tmp_path / "mascot" / "mascot.lock.json").read_text() == before and approved(lock) == {}


def test_a_rejected_bird_paints_a_new_round_with_new_numbers_and_seeds(tmp_path, comfy, prompts):
    artist(tmp_path, comfy, prompts).paint()
    lock = reload(tmp_path)
    old = {c["seed"] for c in lock.birds[FINCH]["candidates"]}
    review(lock, tmp_path / "cache", approve=[3], reject=[FINCH], why="the glasses came out thin")
    assert reload(tmp_path).birds[FINCH]["why"] == "the glasses came out thin"
    with pytest.raises(ValueError):  # the old numbers no longer mean anything to a rejected round
        review(reload(tmp_path), tmp_path / "cache", approve=[1])
    painted = len(comfy.paintings)
    artist(tmp_path, comfy, prompts).paint()
    assert len(comfy.paintings) == painted + 2  # the egret, approved, is left alone
    entry = reload(tmp_path).birds[FINCH]
    assert entry["review"] == "pending" and entry["round"] == 1 and set(entry["rejected_seeds"]) == old
    assert [c["number"] for c in entry["candidates"]] == [5, 6] and not old & {c["seed"] for c in entry["candidates"]}


def test_a_new_icon_starts_a_new_round_and_takes_back_the_approval(tmp_path, comfy, prompts):
    artist(tmp_path, comfy, prompts).paint()
    lock = reload(tmp_path)
    review(lock, tmp_path / "cache", approve=[1])
    bird_on(Image.new("RGB", (1024, 1024), BACKGROUND), colours=((10, 200, 40), (120, 95, 70))).save(tmp_path / f"icons/{FINCH}.png")
    artist(tmp_path, comfy, prompts).paint()
    lock = reload(tmp_path)
    assert lock.birds[FINCH]["review"] == "pending" and lock.birds[FINCH]["round"] == 1 and approved(lock) == {}
    assert not lock.approved_path(FINCH).exists()


def test_a_thin_rim_of_card_is_gone_from_what_ships(tmp_path, comfy, prompts):
    patch = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    draw = ImageDraw.Draw(patch)
    draw.ellipse((6, 16, 1018, 1018), fill=(232, 232, 230, 255))  # the card under the shadow, 10 px low
    noise = Image.effect_noise((1024, 1024), 70).convert("L")
    thread = Image.merge("RGB", (noise, noise.point(lambda v: v // 2), noise.point(lambda v: v // 3))).convert("RGBA")
    mask = Image.new("L", (1024, 1024), 0)
    ImageDraw.Draw(mask).ellipse((6, 6, 1018, 1006), fill=255)
    patch.paste(thread, (0, 0), mask)
    def pale(image):
        pixels = np.asarray(image)
        return ((pixels[..., :3].min(-1) > 200) & (pixels[..., 3] > 128)).sum()
    assert pale(shipped(patch)) < pale(patch) / 2


def test_the_sheets_show_every_candidate_and_need_no_painter(tmp_path, comfy, prompts):
    artist(tmp_path, comfy, prompts).paint()
    sheets = draw_sheets(reload(tmp_path), tmp_path / "cache", tmp_path / "sheets", prompts, tmp_path, per_sheet=1)
    assert [sheet.name for sheet in sheets] == ["sheet-1.jpg", "sheet-2.jpg"]
    with Image.open(sheets[0]) as sheet:
        assert sheet.width > 3 * 340


def test_the_review_command_records_picks_and_redraws_the_sheets(tmp_path, comfy, prompts, monkeypatch, capsys):
    artist(tmp_path, comfy, prompts).paint()
    monkeypatch.setattr("packbuilder.mascot_art.MascotPrompts.load", classmethod(lambda cls, path=None: prompts))
    code = cli.main(["mascot-review", "--lock", str(tmp_path / "mascot" / "mascot.lock.json"), "--cache", str(tmp_path / "cache"), "--sheets", str(tmp_path / "sheets"), "--approve", "2"])
    assert code == 0
    assert json.loads((tmp_path / "mascot" / "mascot.lock.json").read_text())["birds"][FINCH]["chosen"] == 2
    assert (tmp_path / "sheets" / "sheet-1.jpg").exists()
    assert cli.main(["mascot-review", "--lock", str(tmp_path / "mascot" / "mascot.lock.json"), "--cache", str(tmp_path / "cache"), "--sheets", str(tmp_path / "sheets"), "--approve", "99"]) == 1
    assert "candidate 99" in capsys.readouterr().err


def committed_lock() -> MascotLock:
    return MascotLock.load()


def felt_in(root) -> None:
    target = root / FELT_PICTURE
    target.parent.mkdir(parents=True, exist_ok=True)
    Image.effect_noise((1056, 1056), 40).convert("RGB").save(target)


def approved_tree(root, birds=tuple(APP_ICONS) + (PERCHED_FINCH,)) -> MascotLock:
    """A lock in `root` whose birds are approved, each a disc like a cut patch, with no transparency left out of its check."""
    folder = root / "mascot"
    (folder / "approved").mkdir(parents=True, exist_ok=True)
    entries = {}
    for bird in birds:
        patch = Image.new("RGBA", (1004, 1024), (0, 0, 0, 0))
        ImageDraw.Draw(patch).ellipse((3, 3, 1000, 1021), fill=(200, 170, 120, 255))
        path = folder / "approved" / f"{bird}.png"
        patch.save(path)
        entries[bird] = {"review": "approved", "chosen": 1, "approved": {"file": f"approved/{bird}.png", "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}}
    return MascotLock(folder / "mascot.lock.json", entries, 2)


def test_each_approved_bird_still_matches_the_picture_it_was_painted_from():
    """The icons the patches were painted from were replaced by the patches. A mismatch here is a new round, which paints
    again and takes the maintainer's approval back."""
    prompts, lock = MascotPrompts.load(), committed_lock()
    for bird in prompts.birds:
        assert hashlib.sha256((REPO / bird.icon).read_bytes()).hexdigest() == lock.birds[bird.id]["icon_sha256"], bird.id


def test_the_app_icons_are_opaque_squares_with_the_patch_on_felt(tmp_path):
    felt_in(tmp_path)
    write_app_assets(approved_tree(tmp_path), tmp_path)
    for bird, icon in APP_ICONS.items():
        with Image.open(tmp_path / "BirdJournal" / f"{icon}.icon" / "Assets" / f"{bird}.png") as picture:
            assert picture.mode == "RGB", bird  # no alpha channel at all, so nothing shows through
            assert picture.width == picture.height == (1024 if bird == PRIMARY_ICON else 512), bird
            pixels = np.asarray(picture, dtype=int)
        side = picture.width
        centre = pixels[side // 2 - 4:side // 2 + 4, side // 2 - 4:side // 2 + 4].mean(axis=(0, 1))
        corner = pixels[:side // 20, :side // 20].mean(axis=(0, 1))
        assert abs(centre - (200, 170, 120)).max() < 3, f"{bird}: the patch isn't in the middle"
        assert corner[2] > corner[0], f"{bird}: the corner isn't the felt"
        with Image.open(tmp_path / "BirdJournal/BirdJournal/Assets.xcassets/AppIconPreview" / f"{icon}.imageset" / f"{icon}.png") as thumbnail:
            assert (thumbnail.mode, thumbnail.size) == ("RGB", (180, 180)), bird


def test_an_icon_smaller_than_the_canvas_is_scaled_up_to_fill_it(tmp_path):
    felt_in(tmp_path)
    write_app_assets(approved_tree(tmp_path), tmp_path)
    layers = {}
    for bird, icon in APP_ICONS.items():
        document = json.loads((tmp_path / "BirdJournal" / f"{icon}.icon" / "icon.json").read_text())
        layer = document["groups"][0]["layers"][0]
        assert layer["image-name"] == f"{bird}.png"
        layers[bird] = layer["position"]["scale"]
    assert layers.pop(PRIMARY_ICON) == 1
    assert set(layers.values()) == {2}


def test_the_finch_keeps_its_transparency_and_gains_a_soft_shadow(tmp_path):
    felt_in(tmp_path)
    write_app_assets(approved_tree(tmp_path), tmp_path)
    for scale, side in ((2, 480), (3, 720)):
        with Image.open(tmp_path / "BirdJournal/BirdJournal/Assets.xcassets/PerchedFinch.imageset" / f"PerchedFinch@{scale}x.png") as picture:
            assert (picture.mode, picture.size) == ("RGBA", (side, side))
            alpha = np.asarray(picture.getchannel("A"), dtype=int)
        assert alpha[0, 0] == 0, "a corner shows the page"
        assert alpha[side // 2, side // 2] == 255, "the patch is solid"
        edge, reach = side // 12, side // 60  # the patch's edge, 20 pt in from the canvas's, and a little way past it
        below = alpha[side - edge + reach, side // 2]
        above = alpha[edge - reach, side // 2]
        assert 0 < below < 255 and below > above, "the shadow falls below the patch, opposite the light"


def test_nothing_is_written_from_a_file_the_review_did_not_choose(tmp_path):
    felt_in(tmp_path)
    lock = approved_tree(tmp_path)
    (tmp_path / "mascot" / "approved" / f"{PERCHED_FINCH}.png").write_bytes(b"not it")
    with pytest.raises(StaleApproval):
        write_app_assets(lock, tmp_path)
    assert not (tmp_path / "BirdJournal").joinpath("MyBirdJournal-RedTailedHawk.icon").exists()


def test_a_bird_without_an_approved_patch_stops_the_assets(tmp_path):
    felt_in(tmp_path)
    with pytest.raises(StaleApproval, match="great-egret"):
        write_app_assets(approved_tree(tmp_path, [bird for bird in (*APP_ICONS, PERCHED_FINCH) if bird != "great-egret"]), tmp_path)


def test_the_committed_app_art_is_made_from_the_approved_patches(tmp_path):
    """The app takes a mascot only from `art/mascot/approved/`: what's committed is what the approved files make."""
    shutil.copytree(REPO / "BirdJournal/BirdJournal/Assets.xcassets/MaterialFelt.imageset", tmp_path / FELT_PICTURE.parent)
    write_app_assets(committed_lock(), tmp_path)
    made = sorted(path.relative_to(tmp_path) for path in (tmp_path / "BirdJournal").rglob("*.png"))
    assert len(made) == 6 + 6 + 2
    for path in made:
        with Image.open(tmp_path / path) as ours, Image.open(REPO / path) as theirs:
            assert ours.mode == theirs.mode and ours.size == theirs.size, path
            assert np.abs(np.asarray(ours, dtype=int) - np.asarray(theirs, dtype=int)).max() <= 2, path
