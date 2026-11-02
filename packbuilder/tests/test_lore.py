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
    assert entry["facts"] == [fact.as_dict() for fact in FACTS] and entry["model"] == "claude-opus-5-5" and entry["prompt_version"] == 4
    assert entry["sentences"][1] == {"text": GOOD["sentences"][1]["text"], "facts": ["f1", "f3"]}


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
    def opened(text):
        return {**GOOD, "sentences": [{"text": text, "facts": ["f3"]}, *GOOD["sentences"][1:]]}

    asked = opened("Ask why the dark sentinel keeps its low perch by running water.")
    places = "Beside Under Over Along Near Past Within Below Above Across Around".split()
    others = [opened(f"{place} the stream the dark sentinel keeps its low perch.") for place in places]
    species = [(f"bird-{n}", f"Bird {n}", f"Avis {n}") for n in range(12)]
    client = StubClient(*([asked] * 3 + others))
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
    drafted = {**GOOD, "sentences": [{**s, "facts": ["f2"]} for s in GOOD["sentences"]], "tagline": {**GOOD["tagline"], "facts": ["f9"]}}
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
    assert lore_rows == [("sayornis-nigricans", " ".join(s["text"] for s in GOOD["sentences"]), GOOD["tagline"]["text"], json.dumps([REVISION, "avonet"], separators=(",", ":")))]
    license_text = (tmp_path / "second" / "LICENSE").read_text()
    assert "written from the fact sheet alone by Claude (claude-opus-5-5, Anthropic)" in license_text
    assert "the lore is\nshared under CC BY-SA 4.0" in license_text
