"""`packbuilder draft-continental` (issue #211): a continental species list from the geomodel's occurrence at sample
cities, with an occurrence function stood in for the geomodel as the rarity tests stand one in."""

import json
from pathlib import Path

import numpy as np
import pytest

from packbuilder.continental import City, Entries, GeoLabel, Pick, draft, load_sample, read_geomodel, report, species_entries
from packbuilder.sets import Taxonomy
from packbuilder.species_list import Ranked, birdnet_labels

REPO = Path(__file__).resolve().parents[2]
NORTH_AMERICA = REPO / "packbuilder" / "cities" / "north-america.json"
MODELS = REPO / "models"
BIRDNET_LABELS = MODELS / "BirdNET+_V3.0-preview3.1_Global_11K_Labels.csv"

CITIES = [City(name=f"City {i}", region="Somewhere", latitude=float(i), longitude=-100.0) for i in range(10)]
"""Ten cities, told apart by latitude: city 3 is at latitude 3."""


class Geomodel:
    """A stand-in geomodel: each bird is a function of (city, week) giving its occurrence there and then."""

    def __init__(self, birds: dict[tuple[str, ...], object]):
        """`birds` is keyed by (scientific name, common name), or (code, scientific name, common name) for a class
        that is not a bird: the geomodel's birds carry eBird codes, its other classes iNaturalist taxon numbers."""
        keys = [key if len(key) == 3 else (f"bird{i}", *key) for i, key in enumerate(birds)]
        self.labels = [GeoLabel(code=code, scientific_name=sci, common_name=common) for code, sci, common in keys]
        self.birds = list(birds.values())

    def occurrence(self, inputs: np.ndarray) -> np.ndarray:
        return np.array([[bird(int(latitude), int(week)) for bird in self.birds] for latitude, _, week in inputs], dtype=np.float32)

    @property
    def birdnet_labels(self) -> dict[str, str]:
        """A label file naming every bird as the geomodel does."""
        return {label.scientific_name: label.common_name for label in self.labels}


def names(result) -> list[str]:
    return [pick.common_name for pick in result.picks]


def test_coast_to_coast_birds_come_first_by_mean_occurrence():
    geomodel = Geomodel({
        ("Turdus migratorius", "American Robin"): lambda city, week: 0.5,
        ("Corvus brachyrhynchos", "American Crow"): lambda city, week: 0.9,
        # Nine cities in ten for eight weeks: two months of passage is enough to be coast to coast.
        ("Calidris minutilla", "Least Sandpiper"): lambda city, week: 0.1 if city < 9 and week <= 8 else 0.0,
        # Far more of what is met in the eight cities it has, but eight in ten is not coast to coast.
        ("Cardinalis cardinalis", "Northern Cardinal"): lambda city, week: 1.0 if city < 8 else 0.0,
        # Everywhere, but for seven weeks.
        ("Plectrophenax nivalis", "Snow Bunting"): lambda city, week: 1.0 if week <= 7 else 0.0,
    })

    result = draft(geomodel.occurrence, geomodel.labels, geomodel.birdnet_labels, CITIES, count=3)

    assert names(result) == ["American Crow", "American Robin", "Least Sandpiper"]
    assert [pick.how for pick in result.picks] == ["coast to coast"] * 3


def test_the_next_bird_is_the_one_that_lifts_the_city_furthest_behind():
    geomodel = Geomodel({
        # Nine tenths of what is met in eight cities, all of it in the ninth and three tenths in the tenth.
        ("Corvus brachyrhynchos", "American Crow"): lambda city, week: 0.3 if city == 9 else 0.9,
        # The other tenth in each of the eight: 80 points of coverage in all.
        ("Cyanocitta cristata", "Blue Jay"): lambda city, week: 0.1 if city < 8 else 0.0,
        # The other seven tenths in the tenth city: 70 points, all of them where coverage is furthest behind.
        ("Auriparus flaviceps", "Verdin"): lambda city, week: 0.7 if city == 9 else 0.0,
    })

    result = draft(geomodel.occurrence, geomodel.labels, geomodel.birdnet_labels, CITIES, count=2)

    assert names(result) == ["American Crow", "Verdin"]
    assert [pick.how for pick in result.picks] == ["coast to coast", "lift"]
    assert result.coverage == pytest.approx([0.9] * 8 + [1.0, 1.0])


EVERYWHERE = lambda city, week: 0.5  # noqa: E731


def test_every_name_is_a_birdnet_label_and_a_bird_without_one_is_left_out():
    geomodel = Geomodel({
        ("Turdus migratorius", "American Robin"): EVERYWHERE,
        # The label file's binomial differs: the bird is taken under the label's, by its common name.
        ("Leuconotopicus villosus", "Hairy Woodpecker"): EVERYWHERE,
        # The label file's common name differs: the label's is used.
        ("Setophaga coronata", "Yellow-rumped Warbler"): EVERYWHERE,
        # No acoustic class.
        ("Gymnogyps californianus", "California Condor"): EVERYWHERE,
        # Not a bird, though the label file has an acoustic class for it.
        ("24268", "Pseudacris crucifer", "Spring Peeper"): EVERYWHERE,
    })
    labels = {
        "Turdus migratorius": "American Robin",
        "Dryobates villosus": "Hairy Woodpecker",
        "Setophaga coronata": "Myrtle Warbler",
        "Pseudacris crucifer": "Spring Peeper",
    }

    result = draft(geomodel.occurrence, geomodel.labels, labels, CITIES, count=10)

    assert sorted((pick.scientific_name, pick.common_name) for pick in result.picks) == [
        ("Dryobates villosus", "Hairy Woodpecker"), ("Setophaga coronata", "Myrtle Warbler"), ("Turdus migratorius", "American Robin"),
    ]
    assert result.renamed == [("Leuconotopicus villosus", "Dryobates villosus")]
    assert draft(geomodel.occurrence, geomodel.labels, labels, CITIES, count=10, exclude={"Dryobates villosus"}).renamed == []
    # The geomodel's own name for the bird is kept beside the label's, for the person reading the list.
    assert {pick.common_name: pick.geomodel_common_name for pick in result.picks} == {
        "Hairy Woodpecker": "Hairy Woodpecker", "Myrtle Warbler": "Yellow-rumped Warbler", "American Robin": "American Robin",
    }
    assert [label.common_name for label in result.no_acoustic_class] == ["California Condor"]
    # The condor is a bird a birder can meet, so the list covers three birds of four; the frog is no part of it.
    assert result.coverage == pytest.approx([0.75] * 10)


def test_a_class_the_label_file_splits_differently_is_taken_under_the_label_named_for_it():
    # The geomodel's whimbrel is the world's, under the binomial the label file keeps for the Old World bird.
    geomodel = Geomodel({("Numenius phaeopus", "Eurasian Whimbrel"): EVERYWHERE})
    labels = {"Numenius phaeopus": "Eurasian Whimbrel", "Numenius hudsonicus": "Hudsonian Whimbrel"}

    result = draft(geomodel.occurrence, geomodel.labels, labels, CITIES, count=10, geomodel_names={"Numenius phaeopus": "Numenius hudsonicus"})

    assert [(pick.scientific_name, pick.common_name) for pick in result.picks] == [("Numenius hudsonicus", "Hudsonian Whimbrel")]


def regional_geomodel() -> Geomodel:
    """Two coast-to-coast birds, and two met in a few cities: the jay in eight, far more than the verdin in one."""
    return Geomodel({
        ("Corvus brachyrhynchos", "American Crow"): lambda city, week: 0.6,
        ("Turdus migratorius", "American Robin"): lambda city, week: 0.2,
        ("Cyanocitta cristata", "Blue Jay"): lambda city, week: 0.2 if city < 8 else 0.0,
        ("Auriparus flaviceps", "Verdin"): lambda city, week: 0.05 if city == 9 else 0.0,
    })


def test_an_excluded_bird_is_never_taken_coast_to_coast_or_not():
    geomodel = regional_geomodel()

    result = draft(geomodel.occurrence, geomodel.labels, geomodel.birdnet_labels, CITIES, count=2, exclude={"Corvus brachyrhynchos", "Cyanocitta cristata"})

    assert names(result) == ["American Robin", "Verdin"]
    # The excluded birds are still met: the list covers a fifth of each of the eight cities with all three.
    assert result.coverage[0] == pytest.approx(0.2)


def test_an_added_bird_is_in_the_list_and_the_list_keeps_its_size():
    geomodel = regional_geomodel()

    result = draft(geomodel.occurrence, geomodel.labels, geomodel.birdnet_labels, CITIES, count=3, add=["Auriparus flaviceps"])

    # Without the addition the third bird is the Blue Jay, which lifts eight cities.
    assert names(result) == ["American Crow", "American Robin", "Verdin"]
    assert [pick.how for pick in result.picks] == ["coast to coast", "coast to coast", "added"]

    # An addition keeps its place before a coast-to-coast bird does.
    smaller = draft(geomodel.occurrence, geomodel.labels, geomodel.birdnet_labels, CITIES, count=2, add=["Auriparus flaviceps"])
    assert names(smaller) == ["American Crow", "Verdin"]


def test_an_added_bird_the_geomodel_has_no_class_for_is_in_and_covers_nothing():
    geomodel = regional_geomodel()
    labels = geomodel.birdnet_labels | {"Dryobates borealis": "Red-cockaded Woodpecker"}

    result = draft(geomodel.occurrence, geomodel.labels, labels, CITIES, count=3, add=["Dryobates borealis"])

    assert names(result) == ["American Crow", "American Robin", "Red-cockaded Woodpecker"]
    assert result.coverage[9] == pytest.approx(0.8 / 0.85)


@pytest.mark.parametrize("hand", [
    {"add": ["Gymnogyps californianus"]},
    {"exclude": {"Corvus brachyrynchos"}},
    {"add": ["Auriparus flaviceps"], "exclude": {"Auriparus flaviceps"}},
], ids=["added without a label", "excluded under a misspelt name", "added and excluded"])
def test_a_hand_named_bird_that_cannot_be_honoured_stops_the_draft(hand):
    geomodel = regional_geomodel()
    with pytest.raises(ValueError):
        draft(geomodel.occurrence, geomodel.labels, geomodel.birdnet_labels, CITIES, count=3, **hand)


def test_the_same_inputs_give_the_same_list_and_birds_no_reading_tells_apart_are_taken_by_name():
    in_half_the_cities = lambda city, week: 0.3 if city < 5 else 0.0  # noqa: E731
    geomodel = Geomodel({
        ("Zonotrichia albicollis", "White-throated Sparrow"): in_half_the_cities,
        ("Corvus brachyrhynchos", "American Crow"): EVERYWHERE,
        ("Melospiza melodia", "Song Sparrow"): in_half_the_cities,
        ("Aix sponsa", "Wood Duck"): in_half_the_cities,
    })

    def drafted(cities):
        return names(draft(geomodel.occurrence, geomodel.labels, geomodel.birdnet_labels, cities, count=3))

    assert drafted(CITIES) == ["American Crow", "Wood Duck", "Song Sparrow"]
    assert drafted(CITIES) == drafted(CITIES)
    assert drafted(list(reversed(CITIES))) == drafted(CITIES)


def test_the_north_america_sample_is_the_lower_48_and_southern_canada_without_alaska_or_hawaii():
    sample = load_sample(NORTH_AMERICA)

    assert len(sample.cities) >= 75
    assert len({(city.name, city.region) for city in sample.cities}) == len(sample.cities)
    regions = {city.region for city in sample.cities}
    assert not regions & {"Alaska", "Hawaii"}
    for city in sample.cities:
        # Hawaii is south of 23° N; Alaska is north of 54.6° N and west of 130° W.
        assert 24.0 <= city.latitude <= 54.0 and -125.0 <= city.longitude <= -52.0, city
    # User story 7 of #206: the parts of the continent whose birds a list of eastern and northern cities would miss.
    for part in (
        {"Arizona", "New Mexico", "Nevada"}, {"Texas"}, {"Florida"}, {"Washington", "Oregon", "British Columbia"},
        {"Kansas", "Nebraska", "North Dakota", "South Dakota", "Oklahoma"}, {"Nova Scotia", "New Brunswick", "Prince Edward Island"},
    ):
        assert part <= regions, part - regions
    assert sum(city.region == "Texas" for city in sample.cities) >= 3
    assert sum(city.region == "Florida" for city in sample.cities) >= 3
    assert sample.geomodel_names == {"Numenius phaeopus": "Numenius hudsonicus"}


def test_species_entries_reuse_the_committed_packs_and_look_up_the_birds_new_to_the_project():
    picks = [
        Pick("Turdus migratorius", "American Robin", "coast to coast"),
        Pick("Auriparus flaviceps", "Verdin", "lift"),
        Pick("Dryobates arizonae", "Arizona Woodpecker", "added"),
    ]
    robin = {"scientific_name": "Turdus migratorius", "common_name": "American Robin", "inat_taxon_id": 12727, "wikipedia_url": "https://en.wikipedia.org/wiki/American_robin"}

    def taxon(scientific_name: str) -> Ranked:
        if scientific_name == "Auriparus flaviceps":
            return Ranked(taxon_id=13632, name=scientific_name, common_name="Verdin", wikipedia_url="http://en.wikipedia.org/wiki/Verdin", count=0, rank="species")
        raise LookupError(scientific_name)

    entries = species_entries(picks, {"Turdus migratorius": robin}, taxon)

    assert entries.species == [
        robin,
        {"scientific_name": "Auriparus flaviceps", "common_name": "Verdin", "inat_taxon_id": 13632, "wikipedia_url": "https://en.wikipedia.org/wiki/Verdin"},
        # iNaturalist has the bird under another name: a person gives the taxon before the entry can go in a pack.
        {"scientific_name": "Dryobates arizonae", "common_name": "Arizona Woodpecker", "inat_taxon_id": None, "wikipedia_url": "https://en.wikipedia.org/wiki/Arizona_woodpecker"},
    ]
    assert entries.new == ["Auriparus flaviceps", "Dryobates arizonae"]
    assert entries.unresolved == ["Dryobates arizonae"]


def test_the_draft_says_where_each_bird_is_met_what_each_city_still_misses_and_who_is_next_in_line():
    geomodel = regional_geomodel()

    result = draft(geomodel.occurrence, geomodel.labels, geomodel.birdnet_labels, CITIES, count=2, runners_up=5)

    crow, robin = result.picks
    assert (crow.cities, robin.cities) == (10, 10)
    assert crow.mean_occurrence == pytest.approx(0.6)
    # Each city's birds off the list, the most met first, with the share of the city each would add.
    assert [(pick.common_name, pytest.approx(share)) for pick, share in result.missed[0]] == [("Blue Jay", 0.2)]
    assert [(pick.common_name, pytest.approx(share)) for pick, share in result.missed[9]] == [("Verdin", 0.05 / 0.85)]
    assert result.missed[8] == []
    # The birds the method would take next, in its order: all there are, when fewer than asked for.
    assert [(pick.common_name, pick.cities, pick.how) for pick in result.runners_up] == [("Blue Jay", 8, "lift"), ("Verdin", 1, "lift")]
    assert result.runners_up[0].mean_occurrence == pytest.approx(0.16)
    # They are not part of the list's coverage.
    assert result.coverage[0] == pytest.approx(0.8)


def test_the_report_has_the_list_in_taxonomic_order_each_citys_coverage_and_the_birds_new_to_the_project():
    geomodel = regional_geomodel()
    result = draft(geomodel.occurrence, geomodel.labels, geomodel.birdnet_labels, CITIES, count=3, runners_up=1)
    entries = Entries(species=[], new=["Cyanocitta cristata"], unresolved=[])
    taxonomy = Taxonomy("15.1", {"Cyanocitta cristata": 0, "Corvus brachyrhynchos": 1, "Auriparus flaviceps": 2, "Turdus migratorius": 3})

    text = report(result, CITIES, entries, taxonomy)

    numbered = [[cell.strip() for cell in line.split("|")[1:-1]] for line in text.splitlines() if line.startswith("| 00")]
    assert numbered == [
        ["001", "Blue Jay", "*Cyanocitta cristata*", "lift", "8", "0.16", "new"],
        ["002", "American Crow", "*Corvus brachyrhynchos*", "coast to coast", "10", "0.60", ""],
        ["003", "American Robin", "*Turdus migratorius*", "coast to coast", "10", "0.20", ""],
    ]
    # Crow, robin and jay are all the nine cities without the verdin have; the weakest city comes first.
    cities = [line for line in text.splitlines() if line.startswith("| City ") and "Somewhere" in line]
    assert cities[0] == "| City 9, Somewhere | 94.1 % | Verdin 5.9 % |"
    assert cities[1] == "| City 0, Somewhere | 100.0 % |  |"
    assert len(cities) == 10 and "| City | Coverage |" in text
    assert "median 100.0 %" in text and "weakest City 9, Somewhere at 94.1 %" in text
    assert "2 already in a pack definition, 1 new to the project" in text
    assert "- Blue Jay (*Cyanocitta cristata*)" in text
    assert "1. Verdin (*Auriparus flaviceps*)" in text


def test_the_report_sets_apart_a_bird_the_taxonomy_does_not_name():
    geomodel = regional_geomodel()
    result = draft(geomodel.occurrence, geomodel.labels, geomodel.birdnet_labels, CITIES, count=2)
    taxonomy = Taxonomy("15.1", {"Hesperiphona vespertina": 0, "Turdus migratorius": 1}, fixes={})

    text = report(result, CITIES, Entries(species=[], new=[], unresolved=[]), taxonomy)

    rows = [[cell.strip() for cell in line.split("|")[1:-1]] for line in text.splitlines() if line.startswith("| ") and "*" in line]
    assert [row[:2] for row in rows] == [["001", "American Robin"], ["–", "American Crow"]]
    assert "not in the IOC World Bird List 15.1 under the label's name: American Crow (*Corvus brachyrhynchos*)" in text


@pytest.mark.skipif(not BIRDNET_LABELS.exists(), reason="models not downloaded (scripts/download-models.sh)")
def test_every_name_drafted_from_the_real_geomodel_is_a_birdnet_label():
    occurrence, geomodel = read_geomodel(MODELS)
    labels = birdnet_labels(BIRDNET_LABELS)
    sample = load_sample(NORTH_AMERICA)

    result = draft(occurrence, geomodel, labels, sample.cities, count=300, geomodel_names=sample.geomodel_names)

    drafted = [pick.scientific_name for pick in result.picks]
    assert len(drafted) == len(set(drafted)) == 300
    assert [name for name in drafted if name not in labels] == []
    assert all(pick.common_name == labels[pick.scientific_name] for pick in result.picks)
    # The whimbrel of the Americas, not the geomodel's one whimbrel under its Old World label.
    assert "Numenius hudsonicus" in drafted and "Numenius phaeopus" not in drafted
    # Birds anyone would expect, from each side of the continent.
    assert {"Turdus migratorius", "Cardinalis cardinalis", "Buteo jamaicensis", "Dryobates villosus", "Calypte anna"} <= set(drafted)
    assert min(result.coverage) > 0.5


@pytest.mark.skipif(not BIRDNET_LABELS.exists(), reason="models not downloaded (scripts/download-models.sh)")
def test_the_command_prints_pack_definition_entries_and_honours_the_hand_lists(tmp_path, capsys, monkeypatch):
    from packbuilder import cli, species_list

    def offline(scientific_name, cache_dir, pause_seconds=1.0):
        raise LookupError(scientific_name)

    monkeypatch.setattr(species_list, "named_taxon", offline)
    arguments = ["draft-continental", "--cities", str(NORTH_AMERICA), "--count", "20", "--cache", str(tmp_path)]

    assert cli.main(arguments) == 0
    plain = json.loads(capsys.readouterr().out)
    assert cli.main([*arguments, "--exclude", "Turdus migratorius", "--add", "Aphelocoma californica"]) == 0
    by_hand = json.loads(capsys.readouterr().out)

    assert len(plain) == len(by_hand) == 20
    # The commonest birds of the continent are in the committed packs, so their entries come whole from there.
    robin = next(entry for entry in plain if entry["scientific_name"] == "Turdus migratorius")
    assert robin == {"scientific_name": "Turdus migratorius", "common_name": "American Robin", "inat_taxon_id": 12727, "wikipedia_url": "https://en.wikipedia.org/wiki/American_robin"}
    names = [entry["scientific_name"] for entry in by_hand]
    assert "Turdus migratorius" not in names and "Aphelocoma californica" in names
    # A name that is not a label stops the command.
    assert cli.main([*arguments, "--add", "Turdus migratorious"]) == 1


def test_the_report_gives_the_geomodels_name_for_a_bird_the_label_file_calls_something_else():
    geomodel = Geomodel({("Setophaga coronata", "Yellow-rumped Warbler"): EVERYWHERE})
    result = draft(geomodel.occurrence, geomodel.labels, {"Setophaga coronata": "Myrtle Warbler"}, CITIES, count=1)

    text = report(result, CITIES, Entries(species=[], new=[], unresolved=[]), Taxonomy("15.1", {"Setophaga coronata": 0}))

    assert "| 001 | Myrtle Warbler (the geomodel's Yellow-rumped Warbler) | *Setophaga coronata* |" in text


@pytest.mark.skipif(not BIRDNET_LABELS.exists(), reason="models not downloaded (scripts/download-models.sh)")
def test_the_committed_north_america_list_is_what_its_recorded_command_drafts():
    """Issue #212: the approved list is the draft with the junglefowl excluded and the barn owl added, and the
    draft's last bird (the Vermilion Flycatcher, the label file's Scarlet Flycatcher) added so the exclusion does not
    cost it its place, in the order taken. A change to the sample cities or to the method that would give another
    list fails here, since the list is fixed at version 1 of the pack."""
    occurrence, geomodel = read_geomodel(MODELS)
    sample = load_sample(NORTH_AMERICA)
    committed = json.loads((REPO / "packbuilder" / "packs" / "north-america" / "pack.json").read_text())["species"]

    result = draft(
        occurrence, geomodel, birdnet_labels(BIRDNET_LABELS), sample.cities, count=300,
        add=["Tyto furcata", "Pyrocephalus rubinus"], exclude={"Gallus gallus"}, geomodel_names=sample.geomodel_names,
    )

    assert [pick.scientific_name for pick in result.picks] == [entry["scientific_name"] for entry in committed]
    assert [pick.common_name for pick in result.picks] == [entry["common_name"] for entry in committed]
