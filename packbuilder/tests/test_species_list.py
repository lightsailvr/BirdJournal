"""`packbuilder draft`: the species list for a new pack, from iNaturalist counts through the BirdNET label file."""

import json

import pytest

from packbuilder.definition import PackDefinition
from packbuilder.species_list import Ranked, draft, wikipedia_guess

LABELS = {
    "Sayornis nigricans": "Black Phoebe",
    "Vireo gilvus": "Warbling Vireo",
    "Anas platyrhynchos": "Mallard",
    "Aix sponsa": "Wood Duck",
    "Aphelocoma californica": "California Scrub Jay",
    "Catherpes mexicanus": "Canyon Wren",
    "Anser cygnoides": "Swan Goose",
}


def ranked(taxon_id, name, common=None, count=10, rank="species", wiki=None):
    return Ranked(taxon_id=taxon_id, name=name, common_name=common, wikipedia_url=wiki, count=count, rank=rank)


class FakeCounts:
    def __init__(self, year, season=(), taxa=()):
        self.year, self.season, self.taxa = year, list(season), {t.name: t for t in taxa}

    def ranking(self, months=(), limit=500):
        return self.season if months else self.year

    def taxon(self, scientific_name):
        return self.taxa[scientific_name]


def test_top_skips_hybrids_and_excluded_without_using_a_place():
    counts = FakeCounts([
        ranked(1, "Anas platyrhynchos × Cairina moschata", rank="hybrid"),
        ranked(2, "Anser cygnoides", "Swan Goose"),
        ranked(3, "Sayornis nigricans", "Black Phoebe", wiki="http://en.wikipedia.org/wiki/Black_phoebe"),
        ranked(4, "Anas platyrhynchos", "Mallard"),
        ranked(5, "Aix sponsa", "Wood Duck"),
    ])
    result = draft(counts, LABELS, {}, top=2, exclude={"Anser cygnoides"})
    assert [s["scientific_name"] for s in result.species] == ["Sayornis nigricans", "Anas platyrhynchos"]
    assert result.species[0]["wikipedia_url"] == "https://en.wikipedia.org/wiki/Black_phoebe"
    assert result.species[1]["wikipedia_url"] == "https://en.wikipedia.org/wiki/Mallard"
    assert [why for _, why in result.skipped] == ["rank hybrid", "excluded"]


def test_names_come_from_committed_packs_then_the_label_file_then_the_common_name():
    known = {10: {"scientific_name": "Vireo gilvus", "common_name": "Warbling Vireo", "inat_taxon_id": 10, "wikipedia_url": "https://en.wikipedia.org/wiki/Warbling_vireo"}}
    counts = FakeCounts([
        ranked(10, "Vireo swainsoni", "Western Warbling-Vireo"),
        ranked(11, "Aphelocoma californica", "California Scrub-Jay"),
        ranked(12, "Aphelocoma occidentalis", "California Scrub Jay"),
        ranked(13, "Nowhere birdus", "Unknown Bird"),
    ])
    result = draft(counts, LABELS, known, top=10)
    assert result.species[0] == known[10]
    assert [s["scientific_name"] for s in result.species] == ["Vireo gilvus", "Aphelocoma californica"]
    # The split scrub jay is the label file's bird by common name, already in; the unknown taxon is left for a person.
    assert [t.name for t in result.unresolved] == ["Nowhere birdus"]


def test_common_name_match_is_logged_as_a_rename():
    counts = FakeCounts([ranked(20, "Catherpes conspersus", "Canyon Wren")])
    result = draft(counts, LABELS, {}, top=5)
    assert [s["scientific_name"] for s in result.species] == ["Catherpes mexicanus"]
    assert [(t.name, name) for t, name in result.renamed] == [("Catherpes conspersus", "Catherpes mexicanus")]


def test_season_top_counts_species_already_in_and_added_species_come_last():
    counts = FakeCounts(
        [ranked(3, "Sayornis nigricans"), ranked(4, "Anas platyrhynchos")],
        season=[ranked(4, "Anas platyrhynchos"), ranked(5, "Aix sponsa"), ranked(3, "Sayornis nigricans")],
        taxa=[ranked(30, "Catherpes mexicanus", count=0)],
    )
    result = draft(counts, LABELS, {}, top=1, season_months=(10, 11), season_top=2, add=["Catherpes mexicanus"])
    assert [s["scientific_name"] for s in result.species] == ["Sayornis nigricans", "Anas platyrhynchos", "Aix sponsa", "Catherpes mexicanus"]


def test_wikipedia_guess_is_sentence_case():
    assert wikipedia_guess("Red-tailed Hawk") == "https://en.wikipedia.org/wiki/Red-tailed_hawk"


def test_a_definition_takes_one_place_or_several(tmp_path):
    base = {"id": "x", "name": "X", "region": "X", "version": 1, "bounding_box": {"south": 0, "west": 0, "north": 1, "east": 1}, "species": []}
    (tmp_path / "pack.json").write_text(json.dumps(base | {"inat_place_id": 962}))
    assert PackDefinition.load(tmp_path / "pack.json").place_ids == (962,)
    (tmp_path / "pack.json").write_text(json.dumps(base | {"inat_place_ids": [934, 839]}))
    assert PackDefinition.load(tmp_path / "pack.json").place_ids == (934, 839)
    (tmp_path / "pack.json").write_text(json.dumps(base | {"inat_place_ids": []}))
    with pytest.raises(ValueError):
        PackDefinition.load(tmp_path / "pack.json")
