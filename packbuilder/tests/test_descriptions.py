"""Wikipedia-derived descriptions (issue #12): the lens details page gets field marks, a size and a habitat line
inside its word budget, the phone a short summary; every derived text names its article revision."""

import json

import pytest

from packbuilder.definition import SpeciesEntry
from packbuilder.descriptions import (
    FIELD_MARKS_WORDS,
    Description,
    WikipediaDescriptions,
    article_matches,
    derive,
    field_marks,
    habitat,
    sections,
    sentences,
    size,
    summary,
)

EXTRACT = """The black phoebe (Sayornis nigricans) is a passerine bird in the tyrant-flycatcher family. It breeds from southwest Oregon and California south through Central and South America. It occurs year-round throughout most of its range and migrates less than the other birds in its genus though its northern populations are partially migratory.
The black phoebe has predominantly black plumage, with a white belly and undertail coverts. Its song is a repeated tee-hee, tee ho.


== Description ==

The black phoebe is a medium-sized flycatcher, being 16 cm (6.3 in) in length and weighing 15 to 22 g (0.5 to 0.8 oz). It has predominantly black plumage, with white on its belly and undertail coverts. The white forms an inverted "V" in the lower breast. The sexes are identical and plumage does not vary seasonally. Juveniles have browner plumage, cinnamon-brown feather tips on their body, and brown wing-bars.
The phoebe can be recognized by a characteristic "tail-wagging" motion, in which the tail is lowered and the tail's feathers fanned out.


== Systematics ==
The phoebes are a genus, Sayornis, of birds in the tyrant flycatcher family.


== Distribution and habitat ==
The black phoebe breeds in the west and southwest United States, Mexico and Central America, and parts of South America. In Oregon it is found in river valleys on the Pacific coast, and in California on the western side of Coast Ranges.
It is always found near water and is often found at coastal cliffs, river/lake banks, or even park fountains. Habitats must also include a supply of mud for nest building.


== References ==


== External links ==

Black phoebe photo gallery at VIREO (Drexel University)
"""

ENTRY = SpeciesEntry(scientific_name="Sayornis nigricans", common_name="Black Phoebe", birdnet_label="Sayornis nigricans", inat_taxon_id=17013, wikipedia_url="https://en.wikipedia.org/wiki/Black_phoebe")


def test_sections_split_the_lead_from_the_headed_sections():
    parts = sections(EXTRACT)
    assert list(parts) == ["", "Description", "Systematics", "Distribution and habitat", "References", "External links"]
    assert parts[""].startswith("The black phoebe (Sayornis nigricans)")
    assert parts["Description"].startswith("The black phoebe is a medium-sized flycatcher")
    assert parts["Distribution and habitat"].endswith("nest building.")


def test_sentences_drop_parentheticals_and_split_on_full_stops():
    text = "It is 16 cm (6.3 in) long. Its song is a repeated tee-hee, tee ho. The genus (Sayornis) honours T. Say."
    assert sentences(text) == ["It is 16 cm long.", "Its song is a repeated tee-hee, tee ho.", "The genus honours T. Say."]


def test_summary_is_the_first_sentences_of_the_lead_within_budget():
    assert summary(sections(EXTRACT)[""], max_words=30) == (
        "The black phoebe is a passerine bird in the tyrant-flycatcher family. "
        "It breeds from southwest Oregon and California south through Central and South America."
    )


def test_field_marks_skip_measurements_and_prefer_plumage_sentences():
    marks = field_marks(sections(EXTRACT), max_words=FIELD_MARKS_WORDS)
    assert marks == 'It has predominantly black plumage, with white on its belly and undertail coverts. The white forms an inverted "V" in the lower breast. The sexes are identical and plumage does not vary seasonally.'
    assert len(marks.split()) <= FIELD_MARKS_WORDS
    assert field_marks(sections(EXTRACT), max_words=20) == "It has predominantly black plumage, with white on its belly and undertail coverts."


def test_field_marks_take_a_second_sentence_when_the_budget_allows():
    marks = field_marks(sections(EXTRACT), max_words=30)
    assert marks == 'It has predominantly black plumage, with white on its belly and undertail coverts. The white forms an inverted "V" in the lower breast.'


def test_field_marks_take_the_longest_clause_of_a_long_sentence_and_never_an_ellipsis():
    parts = {"": "", "Description": "Adults are brown above with a rusty tail, a pale belly crossed by a dark band, and a dark bar on the leading edge of the wing that shows in flight."}
    marks = field_marks(parts, max_words=12)
    assert marks == "Adults are brown above with a rusty tail."
    assert not marks.endswith("…")


def test_field_marks_skip_a_long_first_sentence_for_a_later_one_that_fits_whole():
    parts = {"": "", "Description": "The plumage is a bewildering mix of brown, buff, grey, black and white streaks, bars and spots that varies by age, sex, season and region. The belly is white."}
    assert field_marks(parts, max_words=12) == "The belly is white."


def test_field_marks_fall_back_to_the_lead_when_no_section_sentence_or_clause_fits():
    parts = {
        "": "Its plumage is plain brown.",
        "Description": "The plumage is a bewildering mix of brown buff grey black and white streaks bars and spots that varies by age sex season and region without pause",
    }
    assert field_marks(parts, max_words=8) == "Its plumage is plain brown."


def test_field_marks_are_empty_rather_than_cut_when_nothing_fits():
    parts = {"": "", "Description": "The plumage is brown buff grey black and white streaks bars spots everywhere"}
    assert field_marks(parts, max_words=5) == ""


def test_field_marks_prefer_the_lead_plumage_over_the_section_measurements():
    parts = {
        "": "Bell's vireo is a small songbird, gray above and whitish below, with a faint white eye ring and two pale wing bars.",
        "Description": "Measurements: Length: 4.5–4.9 in Weight: 0.3 oz Wingspan: 7 in. Females weigh slightly less than males. The species is dimorphic in size, males being larger than females.",
    }
    marks = field_marks(parts, max_words=25)
    assert marks == "Bell's vireo is a small songbird, gray above and whitish below, with a faint white eye ring and two pale wing bars."


def test_field_marks_fall_back_to_the_lead_when_there_is_no_description_section():
    parts = {"": "The wrentit is a small bird with uniform dull olive plumage and a long tail held high. It lives in chaparral."}
    assert field_marks(parts, max_words=20) == "The wrentit is a small bird with uniform dull olive plumage and a long tail held high."


def test_size_is_the_first_body_length_in_centimetres():
    assert size(sections(EXTRACT)) == "16 cm"
    assert size({"Description": "It is 12.5 to 15 cm (5 to 6 in) long, with a wingspan of 20 to 25 cm."}) == "13–15 cm"
    assert size({"Description": "Adults are 3.9 to 4.3 in (9.9 to 10.9 cm) long with a wingspan of 4.7 inches (12 cm)."}) == "10–11 cm"
    assert size({"Description": "It has a wingspan of 81–98 cm and is 50–65 cm long."}) == "50–65 cm", "the wingspan is not the body length"
    assert size({"Description": "Its mass is 20 g."}) == ""


@pytest.mark.parametrize("text, expected", [
    ("The bushtit has a length of 100–110 mm (3.9–4.3 in) and a weight of 5 g.", "10–11 cm"),
    ("It measures between 28 and 34 centimetres (11 and 13 in) in length.", "28–34 cm"),
    ("Adults are generally 15–18 centimeters in length, with a wingspan of 35.5 cm.", "15–18 cm"),
    ("A small, 10.8-centimetre-long (4.3 in) insectivore.", "11 cm"),
    ("Immature adults reaching only 3 to 3.5 in (76 to 89 mm) in length.", "8–9 cm"),
    ("The pelican measures 1 to 1.52 m (3 ft 3 in to 5 ft 0 in) in length and has a wingspan of 2.03 to 2.28 m.", "100–152 cm"),
    ("The whydah's tail adds another 20 cm to this.", ""),
    ("A few birds, no more than 1 in 200, have white wingtips.", ""),
    ("Nests are placed 2 m up in a shrub.", ""),
    ("The eggs measure 6–7 cm and the nest is 30 cm across.", ""),
    ("Standing up to 1 m (3 ft 3 in) tall, this species can measure 80 to 104 cm (31 to 41 in) in length.", "80–104 cm"),
    ("Standing up to 1 m (3 ft 3 in) tall, it is a large heron.", "100 cm"),
    ("The royal tern has a 125–135 cm (49–53 in) wingspan and is 45–50 cm (18–20 in) long.", "45–50 cm"),
    ("The bill is 9 cm (3.5 in) long and bright red; the bird is 42–47 cm in length.", "42–47 cm"),
    ("A wing chord of 63 cm has been recorded; adults are 70–102 cm long.", "70–102 cm"),
    ("It is 50–65 cm (20–26 in) long, of which the body makes up two-thirds, and has a wingspan of 81–98 cm.", "50–65 cm"),
    ("Adults have an average wingspan of 130 cm (51 in) for both sexes, with a range from 125–135 cm (49–53 in). The bird is 45–50 cm (18–20 in) long.", "45–50 cm"),
    ("Wing and tail length are about 3.82 in (9.70 cm) and 3.87 in (9.83 cm) long. Adults are 20–23 cm long.", "20–23 cm"),
    ("It measures 1 to 1.52 m (3 ft 3 in to 5 ft 0 in) in length. The pouch holds 28–35 cm of fish.", "100–152 cm"),
    ("Measurement ranges Length: 7.9–9.1 in (20–23 cm) Weight: 1.2–1.8 oz (34–51 g) Wingspan: 11.0–12.6 in (27.9–32.0 cm)", "20–23 cm"),
    ("A stocky bird with a long (9 cm (3.5 in)) bright red bill.", ""),
    ("Adults have an average wingspan of 130 cm (51 in). Its bill-to-tail length ranges from 45–50 cm (18–20 in).", "45–50 cm"),
    ("It is 32 cm (13 in) from tip of beak to tip of tail, with a wingspan of 51 cm.", "32 cm"),
    ("It ranges up to 3,000 m in the mountains.", ""),
])
def test_size_reads_other_units_and_spellings(text, expected):
    assert size({"Description": text}) == expected


def test_size_falls_back_to_the_lead_when_the_description_section_has_none():
    parts = {"": "The pin-tailed whydah is 12–13 cm in length, though the male's tail adds another 20 cm.", "Description": "The adult male has a black back and crown."}
    assert size(parts) == "12–13 cm"


def test_habitat_is_the_most_mentioned_habitat_terms():
    assert habitat(sections(EXTRACT)) == "coast, rivers, water"
    assert habitat({"": "A bird of chaparral and oak woodland, common in suburban gardens."}) == "woodland, chaparral, urban"
    assert habitat({"": "A bird."}) == ""


def test_habitat_falls_back_to_the_lead_when_the_section_is_only_range():
    parts = {"": "The western gull is a large gull that lives on the west coast and the Pacific Ocean.", "Distribution and habitat": "It is a year-round resident in California and Oregon."}
    assert habitat(parts) == "coast, ocean"


def test_habitat_ignores_sea_level_and_field_guides():
    parts = {"Habitat": "It breeds from sea level to 3,000 m, as field guides note, in montane forest."}
    assert habitat(parts) == "mountains, forest"


def test_article_matches_the_species_by_its_scientific_name():
    assert article_matches(EXTRACT, "Sayornis nigricans")
    family_page = "The bushtits or long-tailed tits are small passerine birds from the family Aegithalidae, all but one of which (Psaltriparus) are found in Eurasia."
    assert not article_matches(family_page, "Psaltriparus minimus", "American Bushtit")


def test_article_matches_a_split_species_by_genus_and_common_name():
    split = "The vermilion flycatcher (Pyrocephalus obscurus) is a small passerine bird in the tyrant flycatcher family."
    assert article_matches(split, "Pyrocephalus rubinus", "Scarlet Flycatcher") is False
    assert article_matches(split, "Pyrocephalus rubinus", "Vermilion Flycatcher")
    assert not article_matches(split, "Sayornis nigricans", "Vermilion Flycatcher")


def test_derive_builds_the_whole_description():
    description = derive(EXTRACT, source="https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245")
    assert description == Description(
        summary="The black phoebe is a passerine bird in the tyrant-flycatcher family. It breeds from southwest Oregon and California south through Central and South America. It occurs year-round throughout most of its range and migrates less than the other birds in its genus though its northern populations are partially migratory.",
        field_marks='It has predominantly black plumage, with white on its belly and undertail coverts. The white forms an inverted "V" in the lower breast. The sexes are identical and plumage does not vary seasonally.',
        size="16 cm",
        habitat="coast, rivers, water",
        source="https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245",
    )


def test_replaced_writes_override_fields_over_the_text_and_drops_the_credit_once_nothing_is_left():
    original = Description(summary="A.", field_marks="B.", size="1 cm", habitat="x", source="https://example/oldid=1")
    partly = original.replaced({"field_marks": "By hand."})
    assert partly == Description(summary="A.", field_marks="By hand.", size="1 cm", habitat="x", source="https://example/oldid=1")
    wholly = original.replaced({"summary": "S", "field_marks": "F", "size": "2 cm", "habitat": "y"})
    assert wholly == Description(summary="S", field_marks="F", size="2 cm", habitat="y", source="")
    assert Description.empty().replaced({"size": "3 cm"}).size == "3 cm"


class FakeWikipedia:
    def __init__(self, pages):
        self.pages = pages
        self.calls = []

    def __call__(self, title):
        self.calls.append(title)
        return self.pages[title]


def page(title, extract, revid=1361402245, pageid=3600673):
    return {"title": title, "pageid": pageid, "revisions": [{"revid": revid}], "extract": extract}


def test_wikipedia_source_derives_from_the_pack_url_and_caches_the_page(tmp_path):
    fetch = FakeWikipedia({"Black_phoebe": page("Black phoebe", EXTRACT)})
    source = WikipediaDescriptions(tmp_path / "cache", fetch=fetch)

    first = source.describe(ENTRY)
    second = source.describe(ENTRY)

    assert first == second and first.size == "16 cm"
    assert first.source == "https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245"
    assert fetch.calls == ["Black_phoebe"], "the second call was served from the cache"
    cached = json.loads((tmp_path / "cache" / "wikipedia" / "Black_phoebe.json").read_text())
    assert cached["revisions"][0]["revid"] == 1361402245


def test_wikipedia_source_pins_revisions_in_the_lock_file_and_warns_when_one_moves(tmp_path, caplog):
    lock = tmp_path / "wikipedia.lock.json"
    fetch = FakeWikipedia({"Black_phoebe": page("Black phoebe", EXTRACT, revid=5)})
    first = WikipediaDescriptions(tmp_path / "cache-a", fetch=fetch, lock_path=lock)
    first.describe(ENTRY)
    first.write_lock()
    assert json.loads(lock.read_text()) == {"Black_phoebe": 5}

    fetch.pages["Black_phoebe"] = page("Black phoebe", EXTRACT, revid=9)
    second = WikipediaDescriptions(tmp_path / "cache-b", fetch=fetch, lock_path=lock)
    with caplog.at_level("WARNING"):
        described = second.describe(ENTRY)
    assert described.source.endswith("oldid=9")
    assert "moved from revision 5 to 9" in caplog.text
    second.write_lock()
    assert json.loads(lock.read_text()) == {"Black_phoebe": 9}


def test_wikipedia_source_rejects_an_article_about_something_else(tmp_path):
    entry = SpeciesEntry(scientific_name="Psaltriparus minimus", common_name="American Bushtit", birdnet_label="Psaltriparus minimus", inat_taxon_id=7266, wikipedia_url="https://en.wikipedia.org/wiki/Bushtit")
    fetch = FakeWikipedia({"Bushtit": page("Aegithalidae", "The bushtits or long-tailed tits are small passerine birds from the family Aegithalidae.")})
    assert WikipediaDescriptions(tmp_path / "cache", fetch=fetch).describe(entry) is None


def test_wikipedia_source_takes_a_trusted_article_about_a_split_species(tmp_path):
    entry = SpeciesEntry(scientific_name="Pyrocephalus rubinus", common_name="Scarlet Flycatcher", birdnet_label="Pyrocephalus rubinus", inat_taxon_id=16447, wikipedia_url="https://en.wikipedia.org/wiki/Vermilion_flycatcher")
    extract = "The vermilion flycatcher (Pyrocephalus obscurus) is a small passerine bird. The males have bright red crowns, chests, and underparts, with brownish wings and tails."
    fetch = FakeWikipedia({"Vermilion_flycatcher": page("Vermilion flycatcher", extract, revid=7)})
    source = WikipediaDescriptions(tmp_path / "cache", fetch=fetch)
    assert source.describe(entry) is None
    trusted = source.describe(entry, trust_article=True)
    assert trusted.field_marks == "The males have bright red crowns, chests, and underparts, with brownish wings and tails."
    assert trusted.source == "https://en.wikipedia.org/w/index.php?title=Vermilion_flycatcher&oldid=7"


def test_wikipedia_source_skips_species_without_an_article(tmp_path):
    entry = SpeciesEntry(scientific_name="Sayornis nigricans", common_name="Black Phoebe", birdnet_label="Sayornis nigricans", inat_taxon_id=17013, wikipedia_url=None)
    fetch = FakeWikipedia({})
    assert WikipediaDescriptions(tmp_path / "cache", fetch=fetch).describe(entry) is None
    assert fetch.calls == []


def test_wikipedia_source_handles_a_missing_page(tmp_path):
    fetch = FakeWikipedia({"Black_phoebe": {"title": "Black phoebe", "missing": True}})
    assert WikipediaDescriptions(tmp_path / "cache", fetch=fetch).describe(ENTRY) is None


@pytest.mark.parametrize("url, title", [
    ("https://en.wikipedia.org/wiki/Black_phoebe", "Black_phoebe"),
    ("http://en.wikipedia.org/wiki/Anna's_hummingbird", "Anna's_hummingbird"),
    ("https://en.wikipedia.org/wiki/Merlin_(bird)", "Merlin_(bird)"),
    ("https://en.wikipedia.org/wiki/Swinhoe%27s_white-eye", "Swinhoe's_white-eye"),
])
def test_article_title_from_url(url, title):
    assert WikipediaDescriptions.title_of(url) == title
