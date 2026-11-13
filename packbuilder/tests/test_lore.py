"""Lore (issue #56) against a stub Anthropic client: every sentence cites existing facts, a warm lore lock survives a
rebuild unchanged and makes no request, and lore is written again only on request."""

import json
import sqlite3
from pathlib import Path

import pytest

from packbuilder import lore as lore_module
from packbuilder import pipeline
from packbuilder.definition import BoundingBox, PackDefinition, SpeciesEntry
from packbuilder.descriptions import derive
from packbuilder.factsheet import Fact
from packbuilder.lore import (
    PENDING, InvalidLore, LoreLock, LoreWriter, MissingAPIKey, api_key_from_environment, review, review_sheet, validate, validate_title,
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
    "title": {"text": "The Waterside Mason", "facts": ["f4"]},
}


class StubClient:
    """Replies with the drafts given, in turn, and keeps the prompts it was sent."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.prompts = []

    def complete(self, system, prompt, schema):
        assert (schema, system) in ((lore_module.SCHEMA, lore_module.SYSTEM), (lore_module.TITLE_SCHEMA, lore_module.TITLE_SYSTEM)) and "fact sheet" in system
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


def test_at_most_one_number_in_the_lore_and_none_in_the_tagline():
    one = {**GOOD, "sentences": [{**GOOD["sentences"][0], "text": "It weighs about nineteen grams, and waits by the water."}, *GOOD["sentences"][1:]]}
    assert not any("numbers" in problem for problem in validate(one, FACTS)), "twenty-six or nineteen is one number"
    two = {**one, "sentences": [*one["sentences"][:-1], {**GOOD["sentences"][-1], "text": "Its wings spread about twenty-six centimeters."}]}
    assert any("holds 2 numbers" in problem for problem in validate(two, FACTS))
    assert any("tagline holds a number" in problem for problem in validate({**GOOD, "tagline": {"text": "Keeper of 400 kin.", "facts": ["f3"]}}, FACTS))


def test_the_prompt_groups_the_article_before_the_coarse_dataset_labels():
    text = lore_module.prompt("Black Phoebe", "Sayornis nigricans", FACTS)
    assert text.index("from its Wikipedia article:") < text.index("f3: The black phoebe hunts") < text.index("from the datasets (coarse labels):") < text.index("f1: It feeds")


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
    assert entry["facts"] == [fact.as_dict() for fact in FACTS] and entry["model"] == "claude-opus-5-5" and entry["prompt_version"] == 5
    assert entry["sentences"][1] == {"text": GOOD["sentences"][1]["text"], "facts": ["f1", "f3"]}
    assert entry["title"] == {"text": "The Waterside Mason", "facts": ["f4"], "model": "claude-opus-5-5", "prompt_version": 5, "review": PENDING}
    assert phoebe.title["text"] == "The Waterside Mason" and phoebe.shipped_title is None


def test_a_draft_that_fails_its_checks_goes_back_with_what_was_wrong(tmp_path):
    bad = {**GOOD, "sentences": [{**GOOD["sentences"][0], "facts": ["f9"]}, *GOOD["sentences"][1:]]}
    client = StubClient("not json", bad, GOOD)
    written = writer(tmp_path, client).write(PHOEBE, {"sayornis-nigricans": FACTS})
    assert "sayornis-nigricans" in written
    assert "the reply was not the JSON asked for" in client.prompts[1]
    assert "sentence 1 cites facts the sheet lacks: f9" in client.prompts[2]


def test_a_cut_off_reply_is_sent_back_and_a_refusal_costs_only_its_species(tmp_path):
    from packbuilder.lore import LoreRefused, LoreTruncated

    class Scripted(StubClient):
        def complete(self, system, prompt, schema):
            self.prompts.append(prompt)
            reply = self.replies.pop(0)
            if isinstance(reply, Exception):
                raise reply
            return json.dumps(reply)

    client = Scripted(LoreTruncated("max_tokens"), GOOD, LoreRefused("bio"), GOOD)
    species = PHOEBE + [("calypte-anna", "Anna's Hummingbird", "Calypte anna"), ("zenaida-macroura", "Mourning Dove", "Zenaida macroura")]
    written = writer(tmp_path, client).write(species, {id: FACTS for id, _, _ in species})
    assert set(written) == {"sayornis-nigricans", "zenaida-macroura"}
    assert "the reply was cut off" in client.prompts[1]


def test_the_run_stops_once_past_its_budget_keeping_what_it_wrote(tmp_path):
    from packbuilder.lore import LoreBudgetExceeded

    class Counted(StubClient):
        input_tokens = output_tokens = 0

        def complete(self, system, prompt, schema):
            self.input_tokens += 1000
            self.output_tokens += 2000  # $0.044 a request at Opus 5.5's prices
            return super().complete(system, prompt, schema)

    species = PHOEBE + [("calypte-anna", "Anna's Hummingbird", "Calypte anna"), ("zenaida-macroura", "Mourning Dove", "Zenaida macroura")]
    with pytest.raises(LoreBudgetExceeded, match="past the \\$0.05 budget"):
        writer(tmp_path, Counted(GOOD, GOOD, GOOD), budget=0.05).write(species, {id: FACTS for id, _, _ in species})
    assert list(LoreLock.load(tmp_path / "lore.lock.json").species) == ["calypte-anna", "sayornis-nigricans"], "the reply that crossed it is kept"


def test_a_set_may_not_lean_on_one_opening_or_on_ask_why(tmp_path):
    places = "Beside Under Over Along Near Past Within Below Above Across Around".split()
    epithets = iter(f"{place}stream {word}" for place, word in zip(places * 2, "Mason Sentinel Keeper Builder Hunter Watcher Weaver Sitter Dancer Singer Waiter Rider Potter Diver".split()))

    def opened(text):
        return {**GOOD, "sentences": [{"text": text, "facts": ["f3"]}, *GOOD["sentences"][1:]], "title": {"text": next(epithets), "facts": ["f4"]}}

    asked = [opened("Ask why the dark sentinel keeps its low perch by running water.") for _ in range(3)]
    others = [opened(f"{place} the stream the dark sentinel keeps its low perch.") for place in places]
    species = [(f"bird-{n}", f"Bird {n}", f"Avis {n}") for n in range(12)]
    client = StubClient(*(asked + others))
    writer(tmp_path, client).write(species, {id: FACTS for id, _, _ in species})

    lock = LoreLock.load(tmp_path / "lore.lock.json").species
    openings = [lore_module.opening(entry) for entry in lock.values()]
    assert openings.count("ask why") == 2, "15 % of twelve rounds up to two"
    assert any('already begin "ask why"' in prompt for prompt in client.prompts)
    assert "Do not fall back" not in client.prompts[0] and "do not fall back on" in lore_module.SYSTEM


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
    assert "the article's facts changed since its lore was written" in caplog.text
    assert (tmp_path / "lore.lock.json").read_bytes() == before


WREN = ("troglodytes-aedon", "Northern House Wren", "Troglodytes aedon")
WREN_FACTS = [
    Fact("f1", "The house wren nests in holes in trees and in nest boxes.", REVISION),
    Fact("f2", "It feeds mostly on insects and other invertebrates.", "avonet"),
    Fact("f3", "It lays its eggs in other birds' nests.", "birdbase"),
    Fact("f4", "The IUCN Red List rates it Least Concern.", "birdbase"),
]
WREN_LORE = {
    "sentences": [
        {"text": "In a hole in an old tree, or a box that people hung, the small brown wren makes its home.", "facts": ["f1"]},
        {"text": "It hunts the bark and the leaves for beetles and spiders, and brings them back to the hole.", "facts": ["f2"]},
        {"text": "The tellers say its eggs lie in nests that other birds once made, a borrowed house for every brood.", "facts": ["f3"]},
        {"text": "So it goes on, and the world counts it among the birds of least concern.", "facts": ["f4"]},
    ],
    "tagline": {"text": "The small brown keeper of the borrowed hole.", "facts": ["f1"]},
    "title": {"text": "Keeper of the Borrowed Hole", "facts": ["f1"]},
}
REUSE = "It nests in a cavity, an old nest another bird built or a crevice."


def test_a_changed_dataset_fact_the_lore_cites_sends_only_that_entry_back(tmp_path, caplog):
    writer(tmp_path, StubClient(GOOD, WREN_LORE)).write(PHOEBE + [WREN], {"sayornis-nigricans": FACTS, WREN[0]: WREN_FACTS})
    review(LoreLock.load(tmp_path / "lore.lock.json"), approve_all=True)

    fixed = [WREN_FACTS[0], WREN_FACTS[1], Fact("f3", REUSE, "birdbase"), WREN_FACTS[3]]
    retold = {**WREN_LORE, "sentences": WREN_LORE["sentences"][:2] + [{**WREN_LORE["sentences"][2], "text": "The tellers say it takes an old nest another bird built."}] + WREN_LORE["sentences"][3:]}
    client = StubClient(retold)
    written = writer(tmp_path, client).write(PHOEBE + [WREN], {"sayornis-nigricans": FACTS, WREN[0]: fixed})

    assert len(client.prompts) == 1 and REUSE in client.prompts[0], "only the wren is written again, from the new sheet"
    assert "a fact its lore cites changed (f3: \"It lays its eggs in other birds' nests.\")" in caplog.text
    assert written[WREN[0]].review == PENDING and REUSE in [fact.text for fact in written[WREN[0]].facts]
    assert written["sayornis-nigricans"].ships, "the phoebe's facts did not change"


def test_a_changed_dataset_fact_the_lore_does_not_cite_is_swapped_in_and_the_lore_stays(tmp_path):
    uncited = {**WREN_LORE, "sentences": WREN_LORE["sentences"][:2] + [{**WREN_LORE["sentences"][2], "facts": ["f1"]}] + WREN_LORE["sentences"][3:]}
    writer(tmp_path, StubClient(uncited)).write([WREN], {WREN[0]: WREN_FACTS})
    review(LoreLock.load(tmp_path / "lore.lock.json"), approve_all=True)

    moved_article = [Fact("f1", "The house wren is a small brown bird.", "https://en.wikipedia.org/w/index.php?oldid=2")] + WREN_FACTS[1:2]
    fixed = moved_article + [Fact("f3", REUSE, "birdbase"), WREN_FACTS[3]]
    written = writer(tmp_path, NoRequests()).write([WREN], {WREN[0]: fixed})

    entry = LoreLock.load(tmp_path / "lore.lock.json").species[WREN[0]]
    assert entry["review"] == "approved" and written[WREN[0]].ships
    assert [fact["text"] for fact in entry["facts"]] == [WREN_FACTS[0].text, WREN_FACTS[1].text, REUSE, WREN_FACTS[3].text], (
        "the dataset fact is swapped in place under its id; the article's stay as locked"
    )
    assert [fact["id"] for fact in entry["facts"]] == ["f1", "f2", "f3", "f4"]


def test_refreshing_drops_gone_facts_and_appends_new_ones_with_fresh_ids():
    from packbuilder.lore import refreshed, stats_changes

    locked = WREN_FACTS
    current = [WREN_FACTS[0], WREN_FACTS[1], WREN_FACTS[3], Fact("f4", "It migrates.", "avonet"), Fact("f5", "It weighs about 11 g.", "avonet")]
    removed, added = stats_changes(locked, current)
    assert [fact.id for fact in removed] == ["f3"] and [fact.text for fact in added] == ["It migrates.", "It weighs about 11 g."]
    assert [(fact.id, fact.text) for fact in refreshed(locked, removed, added)] == [
        ("f1", WREN_FACTS[0].text), ("f2", WREN_FACTS[1].text), ("f3", "It migrates."), ("f4", WREN_FACTS[3].text), ("f5", "It weighs about 11 g."),
    ]
    assert [fact.id for fact in refreshed(locked, removed, [])] == ["f1", "f2", "f4"]


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


def test_the_key_comes_only_from_its_own_variable_or_the_keychain(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "not-this-one")
    with pytest.raises(MissingAPIKey, match="BIRDJOURNAL_ANTHROPIC_API_KEY"):
        api_key_from_environment()
    assert api_key_from_environment(keychain=lambda: "sk-keychain\n") == "sk-keychain"
    monkeypatch.setenv("BIRDJOURNAL_ANTHROPIC_API_KEY", "sk-test")
    assert api_key_from_environment(keychain=lambda: "sk-keychain") == "sk-test", "the variable first"


def anthropic_answering(status, body):
    """A real SDK client whose every request gets this answer, with no retries."""
    import anthropic
    import httpx2 as httpx

    transport = httpx.MockTransport(lambda request: httpx.Response(status, json=body))
    return anthropic.Anthropic(api_key="sk-bad-key-1234", http_client=httpx.Client(transport=transport), max_retries=0)


def test_a_refused_key_stops_the_run_at_once_writes_nothing_and_never_shows_the_key(tmp_path):
    from packbuilder.lore import AnthropicLoreClient, LoreAPIError

    client = AnthropicLoreClient("sk-bad-key-1234", client=anthropic_answering(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}))
    lore_writer = writer(tmp_path, client)
    with pytest.raises(LoreAPIError, match="refused the key \\(401\\)") as raised:
        lore_writer.write(PHOEBE + [("calypte-anna", "Anna's Hummingbird", "Calypte anna")], {"sayornis-nigricans": FACTS, "calypte-anna": FACTS})
    assert lore_writer.requests == 1, "no second species is tried"
    assert "sk-bad" not in str(raised.value) and raised.value.__cause__ is None
    assert not (tmp_path / "lore.lock.json").exists()


def test_the_client_returns_the_structured_reply():
    from packbuilder.lore import AnthropicLoreClient

    reply = {
        "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "stop_reason": "end_turn", "stop_sequence": None,
        "content": [{"type": "text", "text": json.dumps(GOOD)}], "usage": {"input_tokens": 10, "output_tokens": 10},
    }
    client = AnthropicLoreClient("sk-test", client=anthropic_answering(200, reply))
    assert json.loads(client.complete(lore_module.SYSTEM, "Species: Black Phoebe", lore_module.SCHEMA)) == GOOD


def test_the_review_file_lists_the_tagline_lore_and_cited_facts(tmp_path):
    writer(tmp_path, StubClient(GOOD)).write(PHOEBE, {"sayornis-nigricans": FACTS})
    sheet = review_sheet(LoreLock.load(tmp_path / "lore.lock.json"), tmp_path / "review.md", "Test Pack").read_text()
    assert "## Black Phoebe (pending)" in sheet
    assert "Pending: Black Phoebe." in sheet
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

    # The stub cites the sheet as the builder numbers it: f1 to f6 the article, f7 to f15 the stats.
    drafted = {**GOOD, "sentences": [{**s, "facts": ["f2"]} for s in GOOD["sentences"]], "tagline": {**GOOD["tagline"], "facts": ["f9"]}, **titled("The Waterside Mason", ("f13",))}
    facts, lore_rows = build(StubClient(drafted), "first")
    assert len(facts) == 15 and facts[6] == (6, "Its wingspan is estimated at about 28 cm from its wing length.", "wingspan")
    assert lore_rows == [], "pending lore does not ship"
    assert (tmp_path / "review.md").exists()
    report = json.loads((tmp_path / "first" / "report.json").read_text())
    assert report["unreviewed"]["lore"] == ["sayornis-nigricans"]

    review(LoreLock.load(tmp_path / "lore.lock.json"), approve_all=True)
    locked = (tmp_path / "lore.lock.json").read_bytes()
    facts_again, lore_rows = build(NoRequests(), "second")
    assert facts_again == facts and (tmp_path / "lore.lock.json").read_bytes() == locked
    row = ("sayornis-nigricans", " ".join(s["text"] for s in GOOD["sentences"]), GOOD["tagline"]["text"], json.dumps([REVISION, "avonet"], separators=(",", ":")))
    assert lore_rows == [(*row, None)], "the lore ships; its title, pending, does not"
    license_text = (tmp_path / "second" / "LICENSE").read_text()
    assert "written from the fact sheet alone by Claude (claude-opus-5-5, Anthropic)" in license_text
    assert "the lore is\nshared under CC BY-SA 4.0" in license_text and "story title" not in license_text
    assert json.loads((tmp_path / "second" / "report.json").read_text())["unreviewed"] == {"lore": [], "titles": ["sayornis-nigricans"]}

    # Approving the title alone ships it with the lore, and its cited fact joins the sources.
    review(LoreLock.load(tmp_path / "lore.lock.json"), approve_titles=["Black Phoebe"])
    _, lore_rows = build(NoRequests(), "third")
    sources = json.dumps([REVISION, "avonet", "birdbase"], separators=(",", ":"))
    assert lore_rows == [(*row[:3], sources, "The Waterside Mason")]
    assert "Each story title was written the same way" in (tmp_path / "third" / "LICENSE").read_text()
    assert json.loads((tmp_path / "third" / "report.json").read_text())["unreviewed"] == {"lore": [], "titles": []}


# Story titles (issue #113): 2 to 5 words heading the lore, citing the facts they rest on, never naming the bird, with
# their own review so lore approved before titles existed is not reopened.

LA = Path(__file__).resolve().parents[1] / "packs" / "us-ca-la"
LA_SPECIES = [
    ("sayornis-nigricans", "Black Phoebe", "Sayornis nigricans"),
    ("haemorhous-mexicanus", "House Finch", "Haemorhous mexicanus"),
    ("ardea-alba", "Great Egret", "Ardea alba"),
]


def titled(text, facts=("f4",)):
    return {"title": {"text": text, "facts": list(facts)}}


def untitled(text):
    """A lore lock's text with its titles taken out, written as `LoreLock` writes it."""
    document = json.loads(text)
    for entry in document["species"].values():
        entry.pop("title", None)
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


def la_lock(tmp_path):
    """A copy of the committed Los Angeles lore lock as it was before titles: every entry approved under prompts v4,
    its titles (written 2026-11-02, see `test_the_committed_los_angeles_titles_pass_the_checks`) taken out."""
    (tmp_path / "lore.lock.json").write_text(untitled((LA / "lore.lock.json").read_text()))
    lock = LoreLock.load(tmp_path / "lore.lock.json")
    return lock, {species_id: [Fact.from_dict(f) for f in lock.species[species_id]["facts"]] for species_id, _, _ in LA_SPECIES}


def without_titles(path):
    """The lock's text with its titles taken out: what must stay byte for byte when titles are written or reviewed."""
    return untitled(Path(path).read_text())


def test_a_title_is_two_to_five_words_citing_facts_on_the_sheet_and_holds_no_number():
    def check(text, facts=("f4",)):
        return validate_title({"text": text, "facts": list(facts)}, FACTS, "Black Phoebe", "Sayornis nigricans")

    assert check("The Waterside Mason") == [] and check("Mason") != [] and check("The Mason Who Builds in Mud") != []
    assert any("the title is 1 words; it must be 2 to 5" in problem for problem in check("Mason"))
    assert any("the title is 6 words" in problem for problem in check("The Mason Who Builds in Mud"))
    assert any("the title cites no fact" in problem for problem in check("The Waterside Mason", facts=()))
    assert any("the title cites facts the sheet lacks: f9" in problem for problem in check("The Waterside Mason", facts=("f4", "f9")))
    assert any("the title holds a number" in problem for problem in check("Keeper of Three Bridges"))
    assert any("the title holds a number" in problem for problem in check("The 1000 Gnats"))
    assert check("The One by the Water") == [], '"one" is left out of the numbers, as for the lore'
    assert validate_title(None, FACTS, "Black Phoebe", "Sayornis nigricans") == ["there is no title"]


@pytest.mark.parametrize("common, scientific, title, named", [
    ("Black Phoebe", "Sayornis nigricans", "The Black Phoebe's Perch", "phoebe"),
    ("Black Phoebe", "Sayornis nigricans", "Where Phoebes Wait", "phoebes"),
    ("Black Phoebe", "Sayornis nigricans", "Sayornis of the Stream", "sayornis"),
    ("Black Phoebe", "Sayornis nigricans", "The Nigricans Bridge", "nigricans"),
    ("Anna's Hummingbird", "Calypte anna", "Anna’s Bright Jewel", "anna"),
    ("Red-tailed Hawk", "Buteo jamaicensis", "The Red-tailed Sentinel", "red-tailed"),
    ("Great Horned Owl", "Bubo virginianus", "The Owl-eyed Watcher", "owl-eyed"),
    ("California Scrub-Jay", "Aphelocoma californica", "The Loud Blue Jay", "jay"),
    ("Mallard", "Anas platyrhynchos", "Mallards of the Pond", "mallards"),
    ("Great Egret", "Ardea alba", "The Egrets' Tree", "egrets"),
])
def test_a_title_may_not_name_the_bird(common, scientific, title, named):
    problems = validate_title({"text": title, "facts": ["f1"]}, FACTS, common, scientific)
    assert any(f"the title names the bird ({named})" in problem for problem in problems), problems


@pytest.mark.parametrize("common, scientific, title", [
    ("Black Phoebe", "Sayornis nigricans", "The Waterside Mason"),
    ("House Finch", "Haemorhous mexicanus", "The Orchard Singer"),
    ("Great Egret", "Ardea alba", "The White Architect"),
    ("Acorn Woodpecker", "Melanerpes formicivorus", "The Acorn Keeper"),
    ("Black Phoebe", "Sayornis nigricans", "The Black Sentinel"),
])
def test_a_title_may_keep_a_plain_word_of_the_name(common, scientific, title):
    """The design guide's proposals pass; a plain word of the name alone ("acorn", "black") does not name the bird."""
    assert validate_title({"text": title, "facts": ["f1"]}, FACTS, common, scientific) == []


def test_new_lore_comes_with_its_title_and_a_bad_title_sends_the_draft_back(tmp_path):
    client = StubClient({**GOOD, **titled("The Phoebe of the Bridge")}, {**GOOD, **titled("The Waterside Mason", facts=())}, GOOD)
    lore_writer = writer(tmp_path, client)
    written = lore_writer.write(PHOEBE, {"sayornis-nigricans": FACTS})
    assert written["sayornis-nigricans"].title["text"] == "The Waterside Mason"
    assert "the title names the bird (phoebe)" in client.prompts[1] and "the title cites no fact" in client.prompts[2]
    assert lore_writer.requests == 3 and lore_writer.title_requests == 0, "the title is written with the lore, in one request"
    assert "story title" in lore_module.SYSTEM and "Never name the bird" in lore_module.SYSTEM and "Never name the bird" in lore_module.TITLE_SYSTEM


def test_titles_for_approved_lore_leave_it_byte_for_byte(tmp_path):
    lock, sheets = la_lock(tmp_path)
    before = without_titles(tmp_path / "lore.lock.json")
    assert before == (tmp_path / "lore.lock.json").read_text(), "the untitled copy, byte for byte"
    client = StubClient(titled("The Waterside Mason"), titled("The Orchard Singer", ("f6",)), titled("The White Architect", ("f3",)))
    lore_writer = LoreWriter(lock=lock, client_factory=lambda: client, sleep=lambda _: None)
    written = lore_writer.write(LA_SPECIES, sheets)

    assert lore_writer.requests == lore_writer.title_requests == 3
    assert [written[i].title["text"] for i, _, _ in LA_SPECIES] == ["The Waterside Mason", "The Orchard Singer", "The White Architect"]
    assert all(written[i].ships and written[i].title["review"] == PENDING and written[i].shipped_title is None for i, _, _ in LA_SPECIES)
    assert without_titles(tmp_path / "lore.lock.json") == before, "only the title is added; the lore, tagline, facts and review are as locked"
    entry = json.loads((tmp_path / "lore.lock.json").read_text())["species"]["sayornis-nigricans"]
    assert entry["prompt_version"] == 4 and entry["title"] == {
        "text": "The Waterside Mason", "facts": ["f4"], "model": "claude-opus-5-5", "prompt_version": 5, "review": PENDING,
    }
    first = client.prompts[0]
    assert first.startswith("Species: Black Phoebe (Sayornis nigricans)") and "Its tagline: Mud-mason by the water, wagging its fanned tail." in first
    assert "Its legend, which the title heads:\n" + lore_module._lore_text(lock.species["sayornis-nigricans"]) in first

    again = LoreWriter(lock=LoreLock.load(tmp_path / "lore.lock.json"), client_factory=lambda: NoRequests(), sleep=lambda _: None)
    titled_lock = (tmp_path / "lore.lock.json").read_bytes()
    again.write(LA_SPECIES, sheets)
    assert again.requests == 0 and (tmp_path / "lore.lock.json").read_bytes() == titled_lock, "a titled lock is warm"


def test_the_committed_los_angeles_titles_pass_the_checks():
    """Every Los Angeles species has a title (written 2026-11-02) that passes the build's checks against its own
    sheet, and the lore under it is still the approved prompts-v4 lore, so a build takes the lock warm."""
    names = {entry["common_name"]: entry["scientific_name"] for entry in json.loads((LA / "pack.json").read_text())["species"]}
    species = LoreLock.load(LA / "lore.lock.json").species
    assert len(species) == len(names) == 160
    for species_id, entry in species.items():
        assert entry["review"] == "approved" and entry["prompt_version"] == 4, species_id
        title = entry["title"]
        assert title["review"] in (PENDING, "approved", "rejected") and title["prompt_version"] == 5, species_id
        facts = [Fact.from_dict(f) for f in entry["facts"]]
        assert validate_title(title, facts, entry["common_name"], names[entry["common_name"]]) == [], (species_id, title["text"])


def test_no_titles_makes_no_title_request(tmp_path):
    lock, sheets = la_lock(tmp_path)
    before = (tmp_path / "lore.lock.json").read_bytes()
    quiet = LoreWriter(lock=lock, client_factory=lambda: NoRequests(), sleep=lambda _: None, titles=False)
    written = quiet.write(LA_SPECIES, sheets)
    assert quiet.requests == 0 and all(lore.ships and lore.title is None for lore in written.values())
    assert (tmp_path / "lore.lock.json").read_bytes() == before


def test_a_failed_title_leaves_the_lore_and_no_title(tmp_path):
    lock, sheets = la_lock(tmp_path)
    before = (tmp_path / "lore.lock.json").read_bytes()
    client = StubClient(*[titled("The Black Phoebe")] * 3)
    written = LoreWriter(lock=lock, client_factory=lambda: client, sleep=lambda _: None).write(LA_SPECIES[:1], sheets)
    assert written["sayornis-nigricans"].ships and written["sayornis-nigricans"].title is None
    assert (tmp_path / "lore.lock.json").read_bytes() == before


def test_a_set_s_titles_may_not_lean_on_one_opening_or_one_ending(tmp_path):
    lock = LoreLock(tmp_path / "lore.lock.json", {
        f"bird-{n}": {
            "common_name": f"Bird {n}", "model": "claude-opus-5-5", "prompt_version": 4, "facts": [fact.as_dict() for fact in FACTS],
            "sentences": GOOD["sentences"], "tagline": GOOD["tagline"], "review": "approved",
        }
        for n in range(12)
    })
    lock.write()

    replies = [
        "The Night Mason", "The Night Keeper", "The Night Watcher", "Dusk Watcher",  # a third "the night" goes back
        "Reed Hunter", "Mud Hunter", "Sky Hunter", "Sky Diver",  # a third "hunter" goes back
        "Bridge Builder", "Stone Sitter", "Gnat Catcher", "Low Percher", "Cliff Dweller", "Stream Singer",
    ]
    client = StubClient(*[titled(text) for text in replies])
    species = [(f"bird-{n}", f"Bird {n}", f"Avis {n}") for n in range(12)]
    LoreWriter(lock=LoreLock.load(tmp_path / "lore.lock.json"), client_factory=lambda: client, sleep=lambda _: None).write(species, {id: FACTS for id, _, _ in species})

    titles = [entry["title"]["text"] for entry in LoreLock.load(tmp_path / "lore.lock.json").species.values()]
    assert len(titles) == 12 and "The Night Watcher" not in titles and "Sky Hunter" not in titles
    assert sum(lore_module.title_opening({"text": t}) == "the night" for t in titles) == 2, "15 % of twelve rounds up to two"
    assert sum(lore_module.title_ending({"text": t}) == "hunter" for t in titles) == 2
    assert any('2 titles of this set already begin "the night"' in prompt for prompt in client.prompts)
    assert any('2 titles of this set already end on "hunter"' in prompt for prompt in client.prompts)
    assert any("Other titles of this set already begin often with: the night" in prompt for prompt in client.prompts), "the next request is warned first"


def run_cli(*argv):
    from packbuilder.cli import main

    return main([str(arg) for arg in argv])


def test_lore_review_approves_or_rejects_a_title_alone(tmp_path):
    lock, sheets = la_lock(tmp_path)
    (tmp_path / "pack.json").write_bytes((LA / "pack.json").read_bytes())
    client = StubClient(titled("The Waterside Mason"), titled("The Orchard Singer", ("f6",)), titled("The White Architect", ("f3",)))
    LoreWriter(lock=lock, client_factory=lambda: client, sleep=lambda _: None).write(LA_SPECIES, sheets)
    lore_before = without_titles(tmp_path / "lore.lock.json")

    sheet = tmp_path / "review.md"
    assert run_cli("lore-review", tmp_path, "--approve-title", "Black Phoebe", "--reject-title", "ardea-alba", "--why", "Too grand.", "--sheet", sheet) == 0
    species = LoreLock.load(tmp_path / "lore.lock.json").species
    assert species["sayornis-nigricans"]["title"]["review"] == "approved"
    assert species["haemorhous-mexicanus"]["title"]["review"] == PENDING
    assert species["ardea-alba"]["title"] == {**species["ardea-alba"]["title"], "review": "rejected", "why": "Too grand."}
    assert without_titles(tmp_path / "lore.lock.json") == lore_before, "the lore's review is not reopened"

    text = sheet.read_text()
    assert "Titles: 1 approved, 1 pending, 1 rejected, 157 not written." in text and "Titles pending: House Finch." in text
    assert "- Black Phoebe: The Waterside Mason (approved)" in text and "- Allen's Hummingbird: no title" in text
    assert "## Great Egret (approved)\n\nTitle (rejected): *The White Architect* (f3)\n   - f3: " in text and "   Title rejected: Too grand." in text

    # The rejected title alone is written again, with the reason; the approved one is not touched.
    client = StubClient(titled("Builder Before the Bride", ("f3",)))
    written = LoreWriter(lock=LoreLock.load(tmp_path / "lore.lock.json"), client_factory=lambda: client, sleep=lambda _: None).write(LA_SPECIES, sheets)
    assert len(client.prompts) == 1 and "The maintainer rejected the title 'The White Architect': Too grand." in client.prompts[0]
    assert written["ardea-alba"].title["review"] == PENDING and written["ardea-alba"].ships
    assert written["sayornis-nigricans"].shipped_title == "The Waterside Mason" and written["haemorhous-mexicanus"].shipped_title is None
    assert without_titles(tmp_path / "lore.lock.json") == lore_before

    assert run_cli("lore-review", tmp_path, "--approve-all-titles", "--sheet", sheet) == 0
    species = LoreLock.load(tmp_path / "lore.lock.json").species
    assert all(species[i]["title"]["review"] == "approved" for i, _, _ in LA_SPECIES) and "why" not in species["ardea-alba"]["title"]
    assert without_titles(tmp_path / "lore.lock.json") == lore_before
    assert run_cli("lore-review", tmp_path, "--approve-title", "Allen's Hummingbird", "--sheet", sheet) == 1, "no title to approve yet"


def test_regenerating_a_title_on_request_keeps_the_lore(tmp_path):
    writer(tmp_path, StubClient(GOOD)).write(PHOEBE, {"sayornis-nigricans": FACTS})
    review(LoreLock.load(tmp_path / "lore.lock.json"), approve_all=True, approve_all_titles=True)
    client = StubClient(titled("Keeper of the Low Perch", ("f3",)))
    written = writer(tmp_path, client, regenerate_titles=frozenset({"sayornis-nigricans"})).write(PHOEBE, {"sayornis-nigricans": FACTS})
    assert "Its title is 'The Waterside Mason'; write another." in client.prompts[0]
    assert written["sayornis-nigricans"].review == "approved" and written["sayornis-nigricans"].title["review"] == PENDING


def test_a_changed_dataset_fact_the_title_cites_sends_back_the_title_alone(tmp_path, caplog):
    lore = {**WREN_LORE, "sentences": [{**s, "facts": ["f1"]} for s in WREN_LORE["sentences"]], **titled("Keeper of the Borrowed Nest", ("f3",))}
    writer(tmp_path, StubClient(lore)).write([WREN], {WREN[0]: WREN_FACTS})
    review(LoreLock.load(tmp_path / "lore.lock.json"), approve_all=True, approve_all_titles=True)

    fixed = [WREN_FACTS[0], WREN_FACTS[1], Fact("f3", REUSE, "birdbase"), WREN_FACTS[3]]
    client = StubClient(titled("Tenant of the Old Nest", ("f3",)))
    written = writer(tmp_path, client).write([WREN], {WREN[0]: fixed})
    assert "a fact its title cites changed" in caplog.text
    assert len(client.prompts) == 1 and REUSE in client.prompts[0], "the title is written from the refreshed sheet"
    assert written[WREN[0]].review == "approved" and written[WREN[0]].title == {**written[WREN[0]].title, "text": "Tenant of the Old Nest", "review": PENDING}


def test_a_hand_edited_title_that_fails_its_checks_stops_the_build(tmp_path):
    writer(tmp_path, StubClient(GOOD)).write(PHOEBE, {"sayornis-nigricans": FACTS})
    lock = LoreLock.load(tmp_path / "lore.lock.json")
    lock.species["sayornis-nigricans"]["title"]["text"] = "The Black Phoebe"
    lock.write()
    with pytest.raises(InvalidLore, match="locked title fails its checks: the title names the bird \\(phoebe\\)"):
        writer(tmp_path, NoRequests()).write(PHOEBE, {"sayornis-nigricans": FACTS})


# Lore once per species (#58): a pack takes the lore another pack holds for the same species, and follows it.

def other_pack(tmp_path, client=None, review_as=None):
    """A sibling pack whose lock holds the phoebe's lore as its own; its lock's path."""
    folder = tmp_path / "packs" / "us-ca-la"
    folder.mkdir(parents=True, exist_ok=True)
    LoreWriter(lock=LoreLock.load(folder / "lore.lock.json"), client_factory=lambda: client or StubClient(GOOD), sleep=lambda _: None).write(
        PHOEBE, {"sayornis-nigricans": FACTS},
    )
    if review_as == "approved":
        review(LoreLock.load(folder / "lore.lock.json"), approve_all=True, approve_all_titles=True)
    return folder / "lore.lock.json"


def sharing(tmp_path, client, pack="us-ca-sd", **kwargs):
    folder = tmp_path / "packs" / pack
    folder.mkdir(parents=True, exist_ok=True)
    return LoreWriter(
        lock=LoreLock.load(folder / "lore.lock.json"), client_factory=lambda: client, sleep=lambda _: None,
        shared=lore_module.shared_lore(tmp_path / "packs", pack), **kwargs,
    )


def test_a_species_another_pack_has_lore_for_takes_it_with_its_review_and_makes_no_request(tmp_path):
    source = other_pack(tmp_path, review_as="approved")

    taking = sharing(tmp_path, NoRequests())
    written = taking.write(PHOEBE, {"sayornis-nigricans": FACTS})

    assert taking.requests == 0 and written["sayornis-nigricans"].ships and written["sayornis-nigricans"].shipped_title == "The Waterside Mason"
    entry = json.loads((tmp_path / "packs" / "us-ca-sd" / "lore.lock.json").read_text())["species"]["sayornis-nigricans"]
    original = json.loads(source.read_text())["species"]["sayornis-nigricans"]
    assert entry == {**original, "shared_from": "us-ca-la"}
    # A second run changes nothing, and a third pack takes the first pack's lore, not the copy.
    before = (tmp_path / "packs" / "us-ca-sd" / "lore.lock.json").read_bytes()
    sharing(tmp_path, NoRequests()).write(PHOEBE, {"sayornis-nigricans": FACTS})
    assert (tmp_path / "packs" / "us-ca-sd" / "lore.lock.json").read_bytes() == before
    sharing(tmp_path, NoRequests(), pack="us-pnw").write(PHOEBE, {"sayornis-nigricans": FACTS})
    assert json.loads((tmp_path / "packs" / "us-pnw" / "lore.lock.json").read_text())["species"]["sayornis-nigricans"]["shared_from"] == "us-ca-la"


def test_shared_lore_follows_the_pack_it_comes_from_and_is_reviewed_there(tmp_path):
    source = other_pack(tmp_path)
    taken = sharing(tmp_path, NoRequests()).write(PHOEBE, {"sayornis-nigricans": FACTS})
    assert taken["sayornis-nigricans"].review == PENDING

    # It can't be reviewed in the pack that took it, and approve-all leaves it.
    lock = LoreLock.load(tmp_path / "packs" / "us-ca-sd" / "lore.lock.json")
    with pytest.raises(KeyError, match="shared from us-ca-la"):
        review(lock, approve=["Black Phoebe"])
    review(lock, approve_all=True, approve_all_titles=True)
    assert lock.species["sayornis-nigricans"]["review"] == PENDING and lock.species["sayornis-nigricans"]["title"]["review"] == PENDING
    sheet = review_sheet(lock, tmp_path / "review.md", "Test Pack").read_text()
    assert "## Black Phoebe (pending, shared from us-ca-la)" in sheet and "Pending: Black Phoebe." not in sheet
    assert "Pending in the pack they are shared from: Black Phoebe (us-ca-la)." in sheet

    # The verdict in its own pack reaches the taker on its next run; a rejection is rewritten there, never here.
    review(LoreLock.load(source), approve_all=True, approve_all_titles=True)
    assert sharing(tmp_path, NoRequests()).write(PHOEBE, {"sayornis-nigricans": FACTS})["sayornis-nigricans"].ships
    review(LoreLock.load(source), reject=["Black Phoebe"], why="too grand")
    rejected = sharing(tmp_path, NoRequests()).write(PHOEBE, {"sayornis-nigricans": FACTS})
    assert not rejected["sayornis-nigricans"].ships
    other_pack(tmp_path, client=StubClient({**GOOD, "tagline": {"text": "Builder in mud by the water.", "facts": ["f4"]}}))
    again = sharing(tmp_path, NoRequests(), regenerate=frozenset({"sayornis-nigricans"})).write(PHOEBE, {"sayornis-nigricans": FACTS})
    assert again["sayornis-nigricans"].tagline["text"] == "Builder in mud by the water." and again["sayornis-nigricans"].review == PENDING


def test_lore_is_shared_only_when_written_from_this_packs_article_facts_and_never_replaces_its_own(tmp_path):
    other_pack(tmp_path, review_as="approved")
    # Another revision of the article here: this pack's text credits would not cover the shared lore, so it writes its own.
    moved = [Fact(fact.id, fact.text, fact.source.replace("oldid=", "oldid=9") if fact.source.startswith("http") else fact.source) for fact in FACTS]
    assert _moved_revision(moved)
    client = StubClient(GOOD)
    own = sharing(tmp_path, client).write(PHOEBE, {"sayornis-nigricans": moved})
    entry = json.loads((tmp_path / "packs" / "us-ca-sd" / "lore.lock.json").read_text())["species"]["sayornis-nigricans"]
    assert len(client.prompts) == 1 and "shared_from" not in entry and own["sayornis-nigricans"].review == PENDING
    # Its own lore stays its own on later runs, whatever the other pack holds.
    sharing(tmp_path, NoRequests()).write(PHOEBE, {"sayornis-nigricans": moved})
    assert "shared_from" not in json.loads((tmp_path / "packs" / "us-ca-sd" / "lore.lock.json").read_text())["species"]["sayornis-nigricans"]


def _moved_revision(facts):
    return [fact.source for fact in facts if fact.source.startswith("http")] != [fact.source for fact in FACTS if fact.source.startswith("http")]


def test_shared_lore_whose_pack_dropped_it_becomes_this_packs_own(tmp_path, caplog):
    source = other_pack(tmp_path, review_as="approved")
    sharing(tmp_path, NoRequests()).write(PHOEBE, {"sayornis-nigricans": FACTS})
    source.unlink()
    kept = sharing(tmp_path, NoRequests()).write(PHOEBE, {"sayornis-nigricans": FACTS})
    entry = json.loads((tmp_path / "packs" / "us-ca-sd" / "lore.lock.json").read_text())["species"]["sayornis-nigricans"]
    assert kept["sayornis-nigricans"].ships and "shared_from" not in entry and "no longer holds its lore" in caplog.text
