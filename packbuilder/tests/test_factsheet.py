"""The fact sheet (issue #56): the stats as sentences credited to their datasets, then sentences of the article that stand
alone, taken across its kinds of section."""

from packbuilder.factsheet import WIKIPEDIA_FACTS, fact_sheet, stats_facts, wikipedia_facts
from packbuilder.stats import JoinedSpecies, SpeciesStats, Threat, TypeLine

REVISION = "https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245"

EXTRACT = """The black phoebe is a passerine bird in the tyrant flycatcher family. It is 16 cm long.

== Description ==
It has predominantly black plumage, with white on its belly and undertail coverts.

== Behavior ==
The black phoebe hunts from a low perch, flying out to catch insects in the air.
However, it also takes small fish from the surface of ponds.
Pairs defend a territory along streams and ponds through the year.

=== Breeding ===
The nest is a cup of mud and grass fibres stuck to a wall, a bridge or a cliff.

== Vocalizations ==
Its song is a thin, rising and falling tee-hee, tee-hoo, given by the male.

== References ==
Ridgely, R. S. (1989). The Birds of South America. University of Texas Press.
"""

JOINED = JoinedSpecies(
    stats=SpeciesStats(
        avibase_id="AVIBASE-BLPH", wingspan_cm=27.5, wingspan_predicted=True, mass_g=18.6, diet="invertivore", habitat="riverine",
        migration="resident", nest=("half_cup", "cup"), clutch_min=3.0, clutch_max=6.0, lifestyle="insessorial", sources=("avonet", "birdbase", "wingspan"),
    ),
    type_line=TypeLine(order="Passeriformes", family="Tyrannidae", group_word="Songbird", family_word="Phoebe"),
    threat=Threat(threatened=False, iucn_category="LC", source="BIRDBASE: IUCN Red List 2024"),
)


def test_the_stats_read_as_sentences_credited_to_their_datasets():
    assert stats_facts(JOINED) == [
        ("Its wingspan is estimated at about 28 cm from its wing length.", "wingspan"),
        ("It weighs about 19 g.", "avonet"),
        ("It feeds mostly on insects and other invertebrates.", "avonet"),
        ("It lives mostly in rivers and streams.", "avonet"),
        ("It stays in its range all year.", "avonet"),
        ("It spends most of its time perched in trees and shrubs.", "avonet"),
        ("It nests in a half cup or a cup.", "birdbase"),
        ("It lays 3 to 6 eggs in a clutch.", "birdbase"),
        ("The IUCN Red List rates it Least Concern.", "birdbase"),
    ]


def test_a_known_gap_keeps_only_what_the_datasets_have():
    gap = JoinedSpecies(stats=None, type_line=None, threat=Threat(threatened=True, iucn_category=None, source="hand list"))
    assert stats_facts(gap) == []
    parasite = JoinedSpecies(
        stats=SpeciesStats("X", None, False, 1500.0, None, None, None, ("other_nest",), None, 2.0, None, ("birdbase",)),
        type_line=None, threat=Threat(threatened=True, iucn_category="VU", source="BIRDBASE"),
    )
    assert stats_facts(parasite) == [
        ("It weighs about 1.5 kg.", "avonet"), ("It lays its eggs in other birds' nests.", "birdbase"),
        ("It lays 2 eggs in a clutch.", "birdbase"), ("The IUCN Red List rates it Vulnerable.", "birdbase"),
    ]


def test_a_borrowed_avonet_row_tells_no_habitat_or_migration():
    import dataclasses

    borrowed = dataclasses.replace(JOINED, borrowed=True)
    texts = [text for text, _ in stats_facts(borrowed)]
    assert "It lives mostly in rivers and streams." not in texts and "It stays in its range all year." not in texts
    assert "It weighs about 19 g." in texts and "It feeds mostly on insects and other invertebrates." in texts


def test_the_committed_borrowed_rows_are_split_species_with_their_reasons():
    from packbuilder.stats import StatsFixes

    fixes = StatsFixes.load()
    assert "Troglodytes aedon" in fixes.borrowed, "AVONET rates the House Wren complex resident"
    for name, why in fixes.borrowed.items():
        assert "split" in why, name
    splits = {name for name, fix in __import__("json").loads((__import__("packbuilder.stats", fromlist=["STATS_DIR"]).STATS_DIR / "fixes.json").read_text())["avonet"].items() if "split" in fix["why"]}
    assert splits <= set(fixes.borrowed), "every AVONET fix to the species before a split is a borrowed row"


def test_article_facts_name_the_bird_then_tell_how_it_lives_before_where_and_what_it_looks_like():
    facts = wikipedia_facts(EXTRACT)
    assert facts == [
        "The black phoebe is a passerine bird in the tyrant flycatcher family.",
        "The black phoebe hunts from a low perch, flying out to catch insects in the air.",
        "The nest is a cup of mud and grass fibres stuck to a wall, a bridge or a cliff.",
        "Its song is a thin, rising and falling tee-hee, tee-hoo, given by the male.",
        "Pairs defend a territory along streams and ponds through the year.",
        "It has predominantly black plumage, with white on its belly and undertail coverts.",
    ], "the measurement, the 'However' sentence and the references are left out; behaviour before appearance"


def test_classification_comes_last_and_a_repeat_or_a_third_of_one_kind_is_left_out():
    extract = "\n".join([
        "The test bird is a small songbird of the west.",
        "== Taxonomy ==",
        "The test bird was formally described in 1850 and placed in its own genus.",
        "== Behaviour ==",
        "It forages for insects among the leaves of oak trees.",
        "It forages for insects among the leaves of oak trees in winter.",
        "It sings a rising whistle from a high perch at dawn.",
        "It roosts in tight flocks on cold nights.",
        "== Distribution ==",
        "It lives near streams and ponds in the foothills.",
    ])
    assert wikipedia_facts(extract) == [
        "The test bird is a small songbird of the west.",
        "It forages for insects among the leaves of oak trees.",
        "It sings a rising whistle from a high perch at dawn.",
        "It lives near streams and ponds in the foothills.",
        "The test bird was formally described in 1850 and placed in its own genus.",
    ]


def test_the_article_gives_at_most_eight_facts():
    sections = {
        "Behaviour": ["It forages for beetles under loose bark.", "Pairs roost together in hollow trunks."],
        "Breeding": ["The nest is woven from grass and spider silk.", "Both parents feed the young for three weeks."],
        "Vocalizations": ["Its song is a rolling trill at dawn.", "Alarm calls are sharp dry ticks."],
        "Distribution": ["It keeps to oak woodland and canyon streams.", "Some winter in desert towns far south."],
        "Conservation": ["Feeders in gardens have helped it spread north."],
    }
    extract = "The lead says the bird is a small grey songbird of the west.\n" + "\n".join(f"== {name} ==\n" + "\n".join(text) for name, text in sections.items())
    assert len(wikipedia_facts(extract)) == WIKIPEDIA_FACTS


def test_the_sheet_numbers_the_article_then_the_stats():
    sheet = fact_sheet(JOINED, (EXTRACT, REVISION))
    assert [fact.id for fact in sheet] == [f"f{n}" for n in range(1, 16)]
    assert sheet[0].source == REVISION and sheet[6].source == "wingspan", "the article first, then the stats"
    assert sheet[0].text == "The black phoebe is a passerine bird in the tyrant flycatcher family."
    assert fact_sheet(None, None) == []
