"""Lore (issue #56) against a stub Anthropic client: every sentence cites existing facts, a warm lore lock survives a
rebuild unchanged and makes no request, and lore is written again only on request."""

import json
import sqlite3

import pytest

from packbuilder import lore as lore_module
from packbuilder import pipeline
from packbuilder.definition import BoundingBox, PackDefinition, SpeciesEntry
from packbuilder.descriptions import derive
from packbuilder.factsheet import Fact
from packbuilder.lore import (
    PENDING, InvalidLore, LoreLock, LoreWriter, MissingAPIKey, api_key_from_environment, review, review_sheet, validate,
)
from tests.test_factsheet import EXTRACT, JOINED, REVISION

FACTS = [
    Fact("f1", "It feeds mostly on insects and other invertebrates.", "avonet"),
    Fact("f2", "It nests in a half cup or a cup.", "birdbase"),
    Fact("f3", "The black phoebe hunts from a low perch, flying out to catch insects in the air.", REVISION),
    Fact("f4", "The nest is a cup of mud and grass fibres stuck to a wall, a bridge or a cliff.", REVISION),
]

GOOD = {
    "sentences": [
        {"text": "Where water runs, the dark sentinel keeps its low perch and waits.", "facts": ["f3"]},
        {"text": "No moth or gnat crosses that air unseen, for insects are its bread and its tribute.", "facts": ["f1", "f3"]},
        {"text": "From the mud of the stream it raises a cup and fixes it to stone, to bridge, to cliff.", "facts": ["f2", "f4"]},
        {"text": "So the keeper of the water's edge has built since the first spring, and builds still.", "facts": ["f4"]},
    ],
    "tagline": {"text": "Keeper of the low perch, builder in mud.", "facts": ["f3", "f4"]},
}


class StubClient:
    """Replies with the drafts given, in turn, and keeps the prompts it was sent."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.prompts = []

    def complete(self, system, prompt, schema):
        assert schema is lore_module.SCHEMA and "fact-sheet" in system
        self.prompts.append(prompt)
        reply = self.replies.pop(0)
        return reply if isinstance(reply, str) else json.dumps(reply)


class NoRequests:
    def complete(self, system, prompt, schema):
        raise AssertionError("a warm lore lock made a request")


def writer(tmp_path, client, **kwargs):
    return LoreWriter(lock=LoreLock.load(tmp_path / "lore.lock.json"), client_factory=lambda: client, sleep=lambda _: None, **kwargs)


PHOEBE = [("sayornis-nigricans", "Black Phoebe", "Sayornis nigricans")]


def test_a_good_draft_passes_and_every_sentence_must_cite_facts_on_the_sheet():
    assert validate(GOOD, FACTS) == []
    uncited = {**GOOD, "sentences": [*GOOD["sentences"][:-1], {"text": GOOD["sentences"][-1]["text"], "facts": []}]}
    assert any("cites no fact" in problem for problem in validate(uncited, FACTS))
    invented = {**GOOD, "sentences": [*GOOD["sentences"][:-1], {"text": GOOD["sentences"][-1]["text"], "facts": ["f9"]}]}
    assert any("the sheet lacks: f9" in problem for problem in validate(invented, FACTS))
    joined = {**GOOD, "sentences": [{"text": "It waits. It strikes.", "facts": ["f3"]}, *GOOD["sentences"]]}
    assert any("more than one sentence" in problem for problem in validate(joined, FACTS))


def test_word_counts_for_the_lore_and_the_tagline():
    short = {**GOOD, "sentences": GOOD["sentences"][:1]}
    assert any("it must be 50 to 80" in problem for problem in validate(short, FACTS))
    long_tagline = {**GOOD, "tagline": {"text": " ".join(["word"] * 13), "facts": ["f1"]}}
    assert any("tagline is 13 words" in problem for problem in validate(long_tagline, FACTS))
    assert any("tagline cites no fact" in problem for problem in validate({**GOOD, "tagline": {"text": "A bird.", "facts": []}}, FACTS))


def test_the_prompt_carries_the_names_and_the_numbered_sheet():
    text = lore_module.prompt("Black Phoebe", "Sayornis nigricans", FACTS)
    assert text.splitlines()[0] == "Species: Black Phoebe (Sayornis nigricans)"
    assert "f3: The black phoebe hunts from a low perch, flying out to catch insects in the air." in text


def test_written_lore_is_locked_pending_with_its_facts(tmp_path):
    client = StubClient(GOOD)
    written = writer(tmp_path, client).write(PHOEBE, {"sayornis-nigricans": FACTS})

    phoebe = written["sayornis-nigricans"]
    assert phoebe.review == PENDING and not phoebe.ships
    assert phoebe.tagline["text"] == "Keeper of the low perch, builder in mud."
    assert phoebe.sources == ["avonet", "birdbase", REVISION]
    entry = json.loads((tmp_path / "lore.lock.json").read_text())["species"]["sayornis-nigricans"]
    assert entry["facts"] == [fact.as_dict() for fact in FACTS] and entry["model"] == "claude-opus-5-5" and entry["prompt_version"] == 1
    assert entry["sentences"][1] == {"text": GOOD["sentences"][1]["text"], "facts": ["f1", "f3"]}


def test_a_draft_that_fails_its_checks_goes_back_with_what_was_wrong(tmp_path):
    bad = {**GOOD, "sentences": [{**GOOD["sentences"][0], "facts": ["f9"]}, *GOOD["sentences"][1:]]}
    client = StubClient("not json", bad, GOOD)
    written = writer(tmp_path, client).write(PHOEBE, {"sayornis-nigricans": FACTS})
    assert "sayornis-nigricans" in written
    assert "the reply was not the JSON asked for" in client.prompts[1]
    assert "sentence 1 cites facts the sheet lacks: f9" in client.prompts[2]


def test_no_lore_after_three_failed_drafts(tmp_path):
    client = StubClient(*[{**GOOD, "tagline": {"text": "x", "facts": []}}] * 3)
    assert writer(tmp_path, client).write(PHOEBE, {"sayornis-nigricans": FACTS}) == {}
    assert not (tmp_path / "lore.lock.json").exists()


def test_a_warm_lock_makes_no_request_and_is_left_unchanged(tmp_path, caplog):
    writer(tmp_path, StubClient(GOOD)).write(PHOEBE, {"sayornis-nigricans": FACTS})
    before = (tmp_path / "lore.lock.json").read_bytes()

    warm = writer(tmp_path, NoRequests())
    again = warm.write(PHOEBE, {"sayornis-nigricans": FACTS})
    assert warm.requests == 0 and again["sayornis-nigricans"].text.startswith("Where water runs")
    assert (tmp_path / "lore.lock.json").read_bytes() == before

    # A sheet that moved keeps the locked facts and lore until a regeneration is asked for.
    moved = writer(tmp_path, NoRequests()).write(PHOEBE, {"sayornis-nigricans": FACTS[:3]})
    assert moved["sayornis-nigricans"].facts == tuple(FACTS)
    assert "the fact sheet changed since its lore was written" in caplog.text
    assert (tmp_path / "lore.lock.json").read_bytes() == before


def test_lore_is_written_again_only_on_request(tmp_path):
    writer(tmp_path, StubClient(GOOD)).write(PHOEBE, {"sayornis-nigricans": FACTS})
    review(LoreLock.load(tmp_path / "lore.lock.json"), approve=["Black Phoebe"])
    retold = {**GOOD, "tagline": {"text": "The water's dark keeper.", "facts": ["f3"]}}

    client = StubClient(retold)
    written = writer(tmp_path, client, regenerate=frozenset({"sayornis-nigricans"})).write(PHOEBE, {"sayornis-nigricans": FACTS})
    assert written["sayornis-nigricans"].tagline["text"] == "The water's dark keeper." and written["sayornis-nigricans"].review == PENDING

    review(LoreLock.load(tmp_path / "lore.lock.json"), reject=["sayornis-nigricans"], why="Too grand; say less about tribute.")
    client = StubClient(GOOD)
    writer(tmp_path, client).write(PHOEBE, {"sayornis-nigricans": FACTS})
    assert "The maintainer rejected it: Too grand; say less about tribute." in client.prompts[0], "a rejection is a request, with its reason"
    assert LoreLock.load(tmp_path / "lore.lock.json").species["sayornis-nigricans"]["review"] == PENDING


def test_a_hand_edited_lock_that_cites_a_missing_fact_stops_the_build(tmp_path):
    writer(tmp_path, StubClient(GOOD)).write(PHOEBE, {"sayornis-nigricans": FACTS})
    lock = LoreLock.load(tmp_path / "lore.lock.json")
    lock.species["sayornis-nigricans"]["sentences"][0]["facts"] = ["f12"]
    lock.write()
    with pytest.raises(InvalidLore, match="f12"):
        writer(tmp_path, NoRequests()).write(PHOEBE, {"sayornis-nigricans": FACTS})


def test_the_key_comes_only_from_its_own_variable(monkeypatch):
    monkeypatch.delenv("BIRDJOURNAL_ANTHROPIC_API_KEY", raising=False)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "not-this-one")
    with pytest.raises(MissingAPIKey, match="BIRDJOURNAL_ANTHROPIC_API_KEY"):
        api_key_from_environment()
    monkeypatch.setenv("BIRDJOURNAL_ANTHROPIC_API_KEY", "sk-test")
    assert api_key_from_environment() == "sk-test"


def test_the_review_file_lists_the_tagline_lore_and_cited_facts(tmp_path):
    writer(tmp_path, StubClient(GOOD)).write(PHOEBE, {"sayornis-nigricans": FACTS})
    sheet = review_sheet(LoreLock.load(tmp_path / "lore.lock.json"), tmp_path / "review.md", "Test Pack").read_text()
    assert "## Black Phoebe (pending)" in sheet
    assert "**Keeper of the low perch, builder in mud.** (f3, f4)" in sheet
    assert "   - f2: It nests in a half cup or a cup. (BIRDBASE)" in sheet
    assert "   - f4: The nest is a cup of mud and grass fibres stuck to a wall, a bridge or a cliff. (Wikipedia)" in sheet


class FakeDescriptions:
    def describe(self, entry, trust_article=False):
        return derive(EXTRACT, REVISION)

    def article(self, entry, trust_article=False):
        return EXTRACT, REVISION


class NoMetadata:
    def candidates_for(self, taxon_id):
        return []


def test_a_rebuild_with_a_warm_lock_ships_the_same_fact_sheet_and_lore(tmp_path):
    definition = PackDefinition(
        id="test-pack", name="Test Pack", region="Testland", version=1, place_ids=(1,), bounding_box=BoundingBox(0, 0, 1, 1),
        species=[SpeciesEntry(scientific_name="Sayornis nigricans", common_name="Black Phoebe", birdnet_label="Sayornis nigricans", inat_taxon_id=17013, wikipedia_url="https://en.wikipedia.org/wiki/Black_phoebe")],
    )
    (tmp_path / "overrides.json").write_text("{}")
    joined = {"Sayornis nigricans": JOINED}

    def build(client, out):
        lore_writer = writer(tmp_path, client)
        options = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / out, min_photos=0, built_at="2026-11-01T00:00:00Z")
        pipeline.build_pack(definition, tmp_path / "overrides.json", NoMetadata(), None, options, FakeDescriptions(), joined=joined, lore=lore_writer, lore_review=tmp_path / "review.md")
        db = sqlite3.connect(tmp_path / out / "pack.sqlite")
        return db.execute("SELECT rank, text, source FROM fact ORDER BY rank").fetchall(), db.execute("SELECT * FROM lore").fetchall()

    # The stub cites the sheet as the builder numbers it: f1 to f9 the stats, f10 on the article.
    drafted = {**GOOD, "sentences": [{**s, "facts": ["f10"]} for s in GOOD["sentences"]], "tagline": {**GOOD["tagline"], "facts": ["f3"]}}
    facts, lore_rows = build(StubClient(drafted), "first")
    assert len(facts) == 15 and facts[0] == (0, "Its wingspan is estimated at about 28 cm from its wing length.", "wingspan")
    assert lore_rows == [], "pending lore does not ship"
    assert (tmp_path / "review.md").exists()
    report = json.loads((tmp_path / "first" / "report.json").read_text())
    assert report["unreviewed"]["lore"] == ["sayornis-nigricans"]

    review(LoreLock.load(tmp_path / "lore.lock.json"), approve_all=True)
    locked = (tmp_path / "lore.lock.json").read_bytes()
    facts_again, lore_rows = build(NoRequests(), "second")
    assert facts_again == facts and (tmp_path / "lore.lock.json").read_bytes() == locked
    assert lore_rows == [("sayornis-nigricans", " ".join(s["text"] for s in GOOD["sentences"]), GOOD["tagline"]["text"], json.dumps(["avonet", REVISION], separators=(",", ":")))]
    license_text = (tmp_path / "second" / "LICENSE").read_text()
    assert "written from the fact sheet alone by Claude (claude-opus-5-5, Anthropic)" in license_text
    assert "the lore is\nshared under CC BY-SA 4.0" in license_text
