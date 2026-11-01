"""Card stats and the type line (issue #55): AVONET, BIRDBASE and the avian wingspan database joined to a pack's
species through AVONET's eBird/Clements sheet and its Avibase IDs, with committed fixes, known gaps, the threatened
hand list and the group-word and family-word mappings."""

import json
from pathlib import Path

import pytest

from packbuilder.definition import PackDefinition, SpeciesEntry
from packbuilder.sets import UnmappedSpecies
from packbuilder.stats import (
    STATS_DIR,
    AvonetSpecies,
    BirdbaseSpecies,
    Datasets,
    StatsFixes,
    TypeLines,
    WingspanSpecies,
    join,
)


def entry(name: str, common: str = "") -> SpeciesEntry:
    return SpeciesEntry(scientific_name=name, common_name=common or name, birdnet_label=name, inat_taxon_id=abs(hash(name)) % 100000 + 1)


def avonet(name: str, avibase: str, **fields) -> AvonetSpecies:
    values = dict(mass_g=21.0, habitat="Human Modified", migration=1, trophic_niche="Granivore", lifestyle="Insessorial")
    values.update(fields)
    return AvonetSpecies(name=name, avibase_id=avibase, **values)


def birdbase(name: str, order: str = "Passeriformes", family: str = "Fringillidae", **fields) -> BirdbaseSpecies:
    values = dict(clements_name=name, iucn="LC", nest_types=("CP",), clutch_min=3.0, clutch_max=5.0, flightless=False)
    values.update(fields)
    return BirdbaseSpecies(name=name, order=order, family=family, **values)


TYPE_LINES = TypeLines(
    orders={"Passeriformes": "Songbird", "Accipitriformes": "Raptor", "Struthioniformes": "Ratite", "Strigiformes": "Owl"},
    families={"Fringillidae": {"word": "Finch"}, "Accipitridae": {"word": "Hawk"}, "Struthionidae": {"word": "Ostrich"}, "Tytonidae": {"word": "Barn Owl"}},
    genera={"Haliaeetus": "Eagle"},
)


def datasets(**overrides) -> Datasets:
    values = dict(
        avonet=[
            avonet("Haemorhous mexicanus", "AVIBASE-HOFI"),
            avonet("Accipiter cooperii", "AVIBASE-COHA", mass_g=450.0, habitat="Woodland", migration=2, trophic_niche="Vertivore", lifestyle="Insessorial"),
            avonet("Struthio camelus", "AVIBASE-OSTR", mass_g=111000.0, habitat="Grassland", trophic_niche="Herbivore terrestrial", lifestyle="Terrestrial"),
            avonet("Haliaeetus leucocephalus", "AVIBASE-BAEA", mass_g=4700.0, habitat="Wetland", migration=2, trophic_niche="Aquatic predator", lifestyle="Generalist"),
        ],
        crosswalk=[],
        wingspan=[
            WingspanSpecies(name="Haemorhous mexicanus", avibase_id="AVIBASE-HOFI", measured_cm=None, predicted_cm=23.4),
            WingspanSpecies(name="Accipiter cooperii", avibase_id="AVIBASE-COHA", measured_cm=78.0, predicted_cm=None),
            WingspanSpecies(name="Haliaeetus leucocephalus", avibase_id="AVIBASE-BAEA", measured_cm=203.0, predicted_cm=None),
        ],
        birdbase=[
            birdbase("Haemorhous mexicanus"),
            birdbase("Astur cooperii", order="Accipitriformes", family="Accipitridae", nest_types=("PL",), clutch_min=3.0, clutch_max=5.0),
            birdbase("Struthio camelus", order="Struthioniformes", family="Struthionidae", nest_types=("SC",), clutch_min=2.0, clutch_max=11.0, flightless=True),
            birdbase("Haliaeetus leucocephalus", order="Accipitriformes", family="Accipitridae", nest_types=("PL",), clutch_min=1.0, clutch_max=3.0),
        ],
    )
    values.update(overrides)
    return Datasets(**values)


def fixes(**overrides) -> StatsFixes:
    values = dict(avonet={"Astur cooperii": "Accipiter cooperii"}, wingspan={}, birdbase={}, known_gaps={}, threatened={})
    values.update(overrides)
    return StatsFixes(**values)


def test_a_manual_fix_joins_a_renamed_species():
    joined = join([entry("Astur cooperii", "Cooper's Hawk")], datasets(), fixes(), TYPE_LINES)["Astur cooperii"]

    assert joined.stats is not None
    assert joined.stats.avibase_id == "AVIBASE-COHA"
    assert joined.stats.mass_g == 450.0
    assert joined.stats.habitat == "woodland"
    assert joined.stats.migration == "partial_migrant"
    assert joined.stats.diet == "vertivore"
    assert joined.stats.lifestyle == "insessorial"
    assert joined.stats.nest == ("platform",)
    assert (joined.stats.clutch_min, joined.stats.clutch_max) == (3.0, 5.0)
    assert joined.type_line.text == "Raptor — Hawk"


def test_a_species_the_datasets_lack_fails_the_build_naming_it():
    species = [entry("Haemorhous mexicanus"), entry("Larus smithsonianus"), entry("Tyto furcata")]

    with pytest.raises(UnmappedSpecies) as raised:
        join(species, datasets(), fixes(), TYPE_LINES)

    assert "Larus smithsonianus" in str(raised.value) and "Tyto furcata" in str(raised.value)
    assert "Haemorhous mexicanus" not in str(raised.value)


def test_a_known_gap_has_no_stats_and_does_not_fail():
    known = fixes(known_gaps={"Tyto furcata": "split from Tyto alba after AVONET; not yet mapped"})
    with_owl = datasets(birdbase=datasets().birdbase + [birdbase("Tyto furcata", order="Strigiformes", family="Tytonidae", clutch_min=2.0, clutch_max=7.0)])

    joined = join([entry("Tyto furcata")], with_owl, known, TYPE_LINES)["Tyto furcata"]

    assert joined.stats is None
    assert joined.type_line.text == "Owl — Barn Owl"


def test_a_measured_wingspan_is_exact_and_a_predicted_one_is_flagged():
    joined = join([entry("Astur cooperii"), entry("Haemorhous mexicanus")], datasets(), fixes(), TYPE_LINES)

    hawk, finch = joined["Astur cooperii"].stats, joined["Haemorhous mexicanus"].stats
    assert (hawk.wingspan_cm, hawk.wingspan_predicted) == (78.0, False)
    assert (finch.wingspan_cm, finch.wingspan_predicted) == (23.4, True)
    assert "wingspan" in hawk.sources and "wingspan" in finch.sources


def test_a_known_gap_birdbase_lacks_keeps_its_avonet_stats():
    without = [row for row in datasets().birdbase if row.name != "Haemorhous mexicanus"]
    known = fixes(known_gaps={"Haemorhous mexicanus": "a test"})

    finch = join([entry("Haemorhous mexicanus")], datasets(birdbase=without), known, TYPE_LINES)["Haemorhous mexicanus"]

    assert finch.stats.mass_g == 21.0 and finch.stats.wingspan_cm == 23.4
    assert finch.stats.nest == () and finch.stats.clutch_min is None
    assert finch.stats.sources == ("avonet", "wingspan")
    assert finch.type_line is None and not finch.threat.threatened


def test_a_flightless_species_has_no_wingspan_but_keeps_its_other_stats():
    ostrich = join([entry("Struthio camelus")], datasets(), fixes(), TYPE_LINES)["Struthio camelus"].stats

    assert ostrich.wingspan_cm is None
    assert ostrich.mass_g == 111000.0
    assert ostrich.nest == ("scrape",)
    assert "wingspan" not in ostrich.sources


def test_a_flightless_species_has_no_wingspan_even_where_the_database_has_a_row():
    rows = datasets().wingspan + [WingspanSpecies(name="Struthio camelus", avibase_id="AVIBASE-OSTR", measured_cm=None, predicted_cm=190.0)]

    ostrich = join([entry("Struthio camelus")], datasets(wingspan=rows), fixes(), TYPE_LINES)["Struthio camelus"].stats

    assert ostrich.wingspan_cm is None


def test_a_species_the_wingspan_database_lacks_has_none_and_does_not_fail():
    without = [row for row in datasets().wingspan if row.name != "Haemorhous mexicanus"]

    finch = join([entry("Haemorhous mexicanus")], datasets(wingspan=without), fixes(), TYPE_LINES)["Haemorhous mexicanus"].stats

    assert finch.wingspan_cm is None
    assert finch.mass_g == 21.0


def test_the_crosswalk_leads_to_the_namesake_birdlife_species_or_a_fix():
    teal = avonet("Anas crecca", "AVIBASE-GWTE-EBIRD", trophic_niche="Herbivore aquatic", lifestyle="Aquatic")
    data = datasets(
        avonet=datasets().avonet + [teal],
        crosswalk=[("AVIBASE-GWTE-EBIRD", "AVIBASE-EUTE"), ("AVIBASE-GWTE-EBIRD", "AVIBASE-GWTE")],
        wingspan=datasets().wingspan + [
            WingspanSpecies(name="Anas crecca", avibase_id="AVIBASE-EUTE", measured_cm=58.0, predicted_cm=None),
            WingspanSpecies(name="Anas carolinensis", avibase_id="AVIBASE-GWTE", measured_cm=61.0, predicted_cm=None),
        ],
        birdbase=datasets().birdbase + [birdbase("Anas crecca", order="Anseriformes", family="Anatidae")],
    )
    lines = TypeLines(orders={**TYPE_LINES.orders, "Anseriformes": "Waterfowl"}, families={**TYPE_LINES.families, "Anatidae": {"word": "Duck"}}, genera={})

    assert join([entry("Anas crecca")], data, fixes(), lines)["Anas crecca"].stats.wingspan_cm == 58.0
    fixed = fixes(wingspan={"Anas crecca": "Anas carolinensis"})
    assert join([entry("Anas crecca")], data, fixed, lines)["Anas crecca"].stats.wingspan_cm == 61.0


@pytest.mark.parametrize("category", ["VU", "EN", "CR"])
def test_iucn_vulnerable_endangered_and_critically_endangered_are_threatened(category):
    rows = [birdbase("Haemorhous mexicanus", iucn=category)] + datasets().birdbase[1:]

    threat = join([entry("Haemorhous mexicanus")], datasets(birdbase=rows), fixes(), TYPE_LINES)["Haemorhous mexicanus"].threat

    assert threat.threatened
    assert threat.iucn_category == category
    assert threat.source == f"BIRDBASE: IUCN Red List 2024, {category}"


@pytest.mark.parametrize("category", ["LC", "NT", None])
def test_other_iucn_categories_are_not_threatened(category):
    rows = [birdbase("Haemorhous mexicanus", iucn=category)] + datasets().birdbase[1:]

    threat = join([entry("Haemorhous mexicanus")], datasets(birdbase=rows), fixes(), TYPE_LINES)["Haemorhous mexicanus"].threat

    assert not threat.threatened
    assert threat.iucn_category == category


def test_the_hand_list_makes_a_least_concern_species_threatened():
    listed = fixes(threatened={"Haemorhous mexicanus": "a test population listed under the Endangered Species Act"})

    threat = join([entry("Haemorhous mexicanus")], datasets(), listed, TYPE_LINES)["Haemorhous mexicanus"].threat

    assert threat.threatened
    assert threat.iucn_category == "LC"
    assert threat.source == "hand list: a test population listed under the Endangered Species Act"


def test_the_type_line_takes_the_genus_word_and_fails_on_an_unmapped_family():
    eagle = join([entry("Haliaeetus leucocephalus")], datasets(), fixes(), TYPE_LINES)["Haliaeetus leucocephalus"]
    assert eagle.type_line.text == "Raptor — Eagle"
    assert (eagle.type_line.order, eagle.type_line.family) == ("Accipitriformes", "Accipitridae")

    lines = TypeLines(orders=TYPE_LINES.orders, families={k: v for k, v in TYPE_LINES.families.items() if k != "Fringillidae"}, genera={})
    with pytest.raises(UnmappedSpecies, match="Fringillidae"):
        join([entry("Haemorhous mexicanus")], datasets(), fixes(), lines)


# The committed fixes and mappings


PACKS = Path(__file__).resolve().parents[1] / "packs"
CACHE = Path(__file__).resolve().parents[1] / "cache"


def pack_definitions() -> list[PackDefinition]:
    return [PackDefinition.load(folder / "pack.json") for folder in sorted(PACKS.iterdir()) if (folder / "pack.json").exists()]


def test_every_committed_fix_names_a_pack_species_and_says_why():
    names = {entry.scientific_name for definition in pack_definitions() for entry in definition.species}
    data = json.loads((STATS_DIR / "fixes.json").read_text())
    for kind in ("avonet", "wingspan", "birdbase"):
        for name, fix in data[kind].items():
            assert name in names, f"{kind} fix for {name}, in no pack"
            assert fix["name"] and fix["why"], name
    for kind in ("known_gaps", "threatened"):
        for name, why in data[kind].items():
            assert name in names and why, f"{kind}: {name}"
    loaded = StatsFixes.load()
    assert loaded.avonet["Astur cooperii"] == "Accipiter cooperii"


def test_every_family_of_the_type_lines_has_a_word_and_a_group():
    lines = TypeLines.load()
    for family, mapping in lines.families.items():
        assert mapping["word"], family
        assert set(mapping) <= {"word", "group"}, family
    assert all(lines.orders.values()) and all(lines.genera.values())


@pytest.mark.skipif(not (CACHE / "datasets").exists(), reason="the datasets are not in packbuilder/cache (a pack build fetches them)")
def test_every_committed_pack_joins_with_stats_and_a_type_line_for_every_species():
    datasets = Datasets.load(CACHE)
    for definition in pack_definitions():
        joined = join(definition.species, datasets, StatsFixes.load(), TypeLines.load())
        known = StatsFixes.load().known_gaps
        for entry in definition.species:
            assert joined[entry.scientific_name].type_line is not None, entry.common_name
            assert joined[entry.scientific_name].stats is not None or entry.scientific_name in known, entry.common_name
