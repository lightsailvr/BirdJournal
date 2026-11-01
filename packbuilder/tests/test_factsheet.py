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


def test_article_facts_stand_alone_and_come_from_every_kind_of_section_first():
    facts = wikipedia_facts(EXTRACT)
    assert facts == [
        "The black phoebe is a passerine bird in the tyrant flycatcher family.",
        "The black phoebe hunts from a low perch, flying out to catch insects in the air.",
        "The nest is a cup of mud and grass fibres stuck to a wall, a bridge or a cliff.",
        "Its song is a thin, rising and falling tee-hee, tee-hoo, given by the male.",
        "It has predominantly black plumage, with white on its belly and undertail coverts.",
        "Pairs defend a territory along streams and ponds through the year.",
    ], "the measurement, the 'However' sentence and the references are left out; behaviour's second sentence comes after one of each kind"


def test_the_article_gives_at_most_eight_facts():
    long = "The lead says the bird is a small grey songbird of the west.\n\n== Behaviour ==\n" + "\n".join(
        f"The bird does thing number {word} on most days of the year." for word in "one two three four five six seven eight nine ten".split()
    )
    assert len(wikipedia_facts(long)) == WIKIPEDIA_FACTS


def test_the_sheet_numbers_the_stats_then_the_article():
    sheet = fact_sheet(JOINED, (EXTRACT, REVISION))
    assert [fact.id for fact in sheet] == [f"f{n}" for n in range(1, 16)]
    assert sheet[0].source == "wingspan" and sheet[9].source == REVISION
    assert sheet[9].text == "The black phoebe is a passerine bird in the tyrant flycatcher family."
    assert fact_sheet(None, None) == []
