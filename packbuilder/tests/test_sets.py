"""The set definition (issue #54): a pack's region boundary simplified from public-domain sources or a committed
hand-drawn polygon, its species in taxonomic order, and its edition."""

import json
import math
from pathlib import Path

import pytest

from packbuilder.countries import Land, cached_files, land_by_code
from packbuilder.definition import BoundingBox, PackDefinition, SpeciesEntry
from packbuilder.sets import (
    BoundaryPart,
    Edition,
    PublicBoundaries,
    SetSection,
    Taxonomy,
    UnmappedSpecies,
    build_set,
    check_set,
    load_set,
    polygon_area_km2,
    simplify_polygons,
    simplify_ring,
)

REPO = Path(__file__).resolve().parents[2]
PACKS = REPO / "packbuilder" / "packs"

IOC_XML = """<?xml version="1.0" encoding="UTF-8"?>
<ioclist version="15.1" year="2025"><list>
<order><latin_name>APODIFORMES</latin_name>
  <family><latin_name>Trochilidae</latin_name>
    <genus><latin_name>Calypte</latin_name><species><latin_name>anna</latin_name></species><species><latin_name>costae</latin_name></species></genus>
  </family>
</order>
<order><latin_name>PICIFORMES</latin_name>
  <family><latin_name>Picidae</latin_name>
    <genus><latin_name>Leuconotopicus</latin_name><species><latin_name>villosus</latin_name></species></genus>
  </family>
</order>
<order><latin_name>PASSERIFORMES</latin_name>
  <family><latin_name>Tyrannidae</latin_name>
    <genus><latin_name>Sayornis</latin_name><species><latin_name>nigricans</latin_name></species></genus>
  </family>
  <family><latin_name>Fringillidae</latin_name>
    <genus><latin_name>Haemorhous</latin_name><species><latin_name>mexicanus</latin_name></species></genus>
  </family>
</order>
</list></ioclist>
"""


def entry(name: str, common: str) -> SpeciesEntry:
    return SpeciesEntry(scientific_name=name, common_name=common, birdnet_label=name, inat_taxon_id=abs(hash(name)) % 100000 + 1)


def definition(species: list[SpeciesEntry], section: SetSection | None) -> PackDefinition:
    return PackDefinition(
        id="test-pack", name="Test Pack", region="Testland", version=1, place_ids=(1,),
        bounding_box=BoundingBox(south=0, west=0, north=1, east=1), species=species, set=section,
    )


SQUARE = [[-118.0, 34.0], [-117.0, 34.0], [-117.0, 35.0], [-118.0, 35.0], [-118.0, 34.0]]


class FakeBoundaries:
    """Answers every part with the polygons it was given, and records what was asked."""

    def __init__(self, polygons, land=None):
        self.polygons = polygons
        self.asked = []
        self.land = land

    def polygons_for(self, part, definition_dir):
        self.asked.append(part)
        return self.polygons

    def natural_earth(self):
        return self.land


# Simplification


def test_simplify_ring_drops_points_closer_to_the_line_than_the_tolerance():
    # A square with a 50 m wobble on one side and a 5 km bump on another: the wobble goes, the bump stays.
    wobble = 0.05 / 92.0  # about 50 m of longitude at 34° N
    ring = [[-118.0, 34.0], [-117.5, 34.0 + wobble], [-117.0, 34.0], [-117.0, 34.5], [-116.95, 34.6], [-117.0, 34.7], [-117.0, 35.0], [-118.0, 35.0], [-118.0, 34.0]]
    simplified = simplify_ring(ring, tolerance_km=0.25)
    assert [-117.5, 34.0 + wobble] not in simplified
    assert [-116.95, 34.6] in simplified
    assert simplified[0] == simplified[-1], "the ring stays closed"


def test_simplify_ring_keeps_a_ring_that_would_collapse():
    tiny = [[0.0, 0.0], [0.0001, 0.0], [0.0001, 0.0001], [0.0, 0.0001], [0.0, 0.0]]
    assert len(simplify_ring(tiny, tolerance_km=1.0)) >= 4


def test_simplify_polygons_drops_islets_and_rounds_coordinates():
    islet = [[[-119.0, 33.0], [-118.999, 33.0], [-118.999, 33.001], [-119.0, 33.0]]]
    detailed = [[-118.000001 + i * 0.1, 34.0000004] for i in range(11)] + [[-117.0, 35.0], [-118.0, 35.0], [-118.000001, 34.0000004]]
    simplified = simplify_polygons([[detailed], islet], tolerance_km=0.25, min_area_km2=1.0)
    assert len(simplified) == 1, "the islet of about 0.01 km² is dropped"
    outer = simplified[0][0]
    assert all(round(value, 4) == value for point in outer for value in point)
    assert len(outer) < len(detailed)


def test_polygon_area_is_about_right_and_holes_subtract():
    # One degree square at 34° N is about 111.3 × cos(34°) × 110.6 km.
    expected = 111.32 * math.cos(math.radians(34.5)) * 110.57
    assert polygon_area_km2([SQUARE]) == pytest.approx(expected, rel=0.01)
    hole = [[-117.75, 34.25], [-117.25, 34.25], [-117.25, 34.75], [-117.75, 34.75], [-117.75, 34.25]]
    assert polygon_area_km2([SQUARE, hole]) == pytest.approx(expected * 0.75, rel=0.01)


# Taxonomic order


def test_taxonomic_order_follows_the_ioc_sequence(tmp_path):
    taxonomy = Taxonomy.parse(IOC_XML)
    species = [entry("Haemorhous mexicanus", "House Finch"), entry("Sayornis nigricans", "Black Phoebe"), entry("Calypte costae", "Costa's Hummingbird"), entry("Calypte anna", "Anna's Hummingbird")]
    ordered = taxonomy.ordered(species)
    assert [s.scientific_name for s in ordered] == ["Calypte anna", "Calypte costae", "Sayornis nigricans", "Haemorhous mexicanus"]
    assert taxonomy.version == "15.1"


def test_taxonomic_order_maps_birdnet_names_through_the_fixes():
    taxonomy = Taxonomy.parse(IOC_XML, fixes={"Dryobates villosus": "Leuconotopicus villosus"})
    ordered = taxonomy.ordered([entry("Sayornis nigricans", "Black Phoebe"), entry("Dryobates villosus", "Hairy Woodpecker")])
    assert [s.scientific_name for s in ordered] == ["Dryobates villosus", "Sayornis nigricans"]


def test_taxonomic_order_fails_on_a_species_the_list_lacks():
    with pytest.raises(UnmappedSpecies, match="Avis ignota"):
        Taxonomy.parse(IOC_XML).ordered([entry("Avis ignota", "Unknown Bird")])


# The set document


def section(*parts: BoundaryPart) -> SetSection:
    return SetSection(edition=Edition(name="Citrus edition", theme="citrus groves and golden valley light"), boundary=parts or (BoundaryPart(name="Testland County", census_county="06037"),))


def test_build_set_carries_the_edition_regions_and_species_in_taxonomic_order(tmp_path):
    species = [entry("Haemorhous mexicanus", "House Finch"), entry("Calypte anna", "Anna's Hummingbird")]
    boundaries = FakeBoundaries([[SQUARE]])
    document = build_set(definition(species, section()), tmp_path, boundaries, Taxonomy.parse(IOC_XML), tolerance_km=0.25)

    assert document["id"] == "test-pack"
    assert document["name"] == "Test Pack"
    assert document["edition"] == {"name": "Citrus edition", "theme": "citrus groves and golden valley light"}
    assert document["taxonomy"] == "IOC World Bird List 15.1"
    assert document["species"] == [
        {"scientificName": "Calypte anna", "commonName": "Anna's Hummingbird"},
        {"scientificName": "Haemorhous mexicanus", "commonName": "House Finch"},
    ]
    [region] = document["regions"]
    assert region["name"] == "Testland County"
    assert "Census" in region["source"]
    assert region["polygons"] == [[SQUARE]]
    assert boundaries.asked == [BoundaryPart(name="Testland County", census_county="06037")]


def test_build_set_needs_a_set_section(tmp_path):
    with pytest.raises(ValueError, match="no set section"):
        build_set(definition([entry("Calypte anna", "Anna's Hummingbird")], None), tmp_path, FakeBoundaries([[SQUARE]]), Taxonomy.parse(IOC_XML))


def test_check_set_refuses_a_set_that_no_longer_matches_the_definition(tmp_path):
    species = [entry("Calypte anna", "Anna's Hummingbird"), entry("Sayornis nigricans", "Black Phoebe")]
    built = definition(species, section())
    document = build_set(built, tmp_path, FakeBoundaries([[SQUARE]]), Taxonomy.parse(IOC_XML))
    check_set(document, built)

    grown = definition(species + [entry("Haemorhous mexicanus", "House Finch")], section())
    with pytest.raises(ValueError, match="rebuild it"):
        check_set(document, grown)
    renamed = definition(species, SetSection(edition=Edition(name="Garden edition", theme="x"), boundary=section().boundary))
    with pytest.raises(ValueError, match="rebuild it"):
        check_set(document, renamed)
    with pytest.raises(ValueError, match="taxonomy"):
        check_set({**document, "taxonomy": "IOC World Bird List 14.2"}, built)


def test_boundary_part_needs_exactly_one_source():
    with pytest.raises(ValueError):
        BoundaryPart.from_mapping({"name": "Nowhere"})
    with pytest.raises(ValueError):
        BoundaryPart.from_mapping({"name": "Twice", "census_county": "06037", "nps_park": "JOTR"})
    assert BoundaryPart.from_mapping({"name": "Joshua Tree National Park", "nps_park": "JOTR"}).source_text.startswith("National Park Service")
    assert "hand-drawn" in BoundaryPart.from_mapping({"name": "Coachella Valley", "polygon": "regions/coachella-valley.geojson"}).source_text


# A part bounded by countries (issue #210)


def test_boundary_part_can_be_countries_and_credits_natural_earth():
    part = BoundaryPart.from_mapping({"name": "United States and Canada", "natural_earth_countries": ["USA", "CAN"]})
    assert part.natural_earth_countries == ("USA", "CAN")
    assert part.source_text.startswith("Natural Earth")
    assert "USA, CAN" in part.source_text and "public domain" in part.source_text
    with pytest.raises(ValueError):
        BoundaryPart.from_mapping({"name": "Twice", "census_county": "06037", "natural_earth_countries": ["USA"]})
    with pytest.raises(ValueError):
        BoundaryPart.from_mapping({"name": "Nowhere", "natural_earth_countries": []})


def test_natural_earth_countries_are_keyed_by_code_with_dependencies_apart():
    data = {"type": "FeatureCollection", "features": [
        {"type": "Feature", "properties": {"ADM0_A3": "USA", "NAME": "United States of America"}, "geometry": {"type": "MultiPolygon", "coordinates": [[SQUARE], [ALAND]]}},
        {"type": "Feature", "properties": {"ADM0_A3": "PRI", "NAME": "Puerto Rico"}, "geometry": {"type": "Polygon", "coordinates": [BLAND]}},
    ]}
    assert land_by_code(data) == {"USA": [[SQUARE], [ALAND]], "PRI": [[BLAND]]}


# Two square countries side by side at 45° N, sea all round: Aland from 0° to 1° E, Bland from 1° to 2° E.
ALAND = [[0.0, 45.0], [1.0, 45.0], [1.0, 46.0], [0.0, 46.0], [0.0, 45.0]]
BLAND = [[1.0, 45.0], [2.0, 45.0], [2.0, 46.0], [1.0, 46.0], [1.0, 45.0]]
KM = 1 / (111.32 * math.cos(math.radians(45.5)))
"""A kilometre of longitude at 45.5° N, in degrees."""


def country_region(tmp_path, land, codes=("AAA",), islets=()) -> dict:
    part = BoundaryPart(name="Aland", natural_earth_countries=codes)
    boundaries = FakeBoundaries([], land=Land(by_code=land, islets=list(islets)))
    document = build_set(definition([entry("Calypte anna", "Anna's Hummingbird")], section(part)), tmp_path, boundaries, Taxonomy.parse(IOC_XML))
    [region] = document["regions"]
    return region


def inside(region: dict, longitude: float, latitude: float) -> bool:
    return any(_contains(polygon, (longitude, latitude)) for polygon in region["polygons"])


def test_a_country_part_reaches_a_little_offshore_and_stops_at_the_neighbours_land(tmp_path):
    region = country_region(tmp_path, {"AAA": [[ALAND]], "BBB": [[BLAND]]})

    assert region["name"] == "Aland"
    assert region["source"].startswith("Natural Earth")
    assert inside(region, 0.5, 45.5), "inland"
    assert inside(region, -3 * KM, 45.5), "a boat 3 km off the west coast"
    assert inside(region, 0.5, 46.0 + 3 / 110.57), "a pier on the north coast"
    assert not inside(region, -40 * KM, 45.5), "40 km out to sea"
    assert inside(region, 1.0 - 0.1 * KM, 45.5), "the last 100 m before the border"
    assert not inside(region, 1.0 + 10 * KM, 45.5), "10 km into the neighbour"
    assert sum(len(ring) for polygon in region["polygons"] for ring in polygon) < 60, "coarse: a square with rounded corners"


def test_the_countries_of_one_part_merge_and_a_code_the_source_lacks_fails(tmp_path):
    region = country_region(tmp_path, {"AAA": [[ALAND]], "BBB": [[BLAND]]}, codes=("AAA", "BBB"))
    assert len(region["polygons"]) == 1
    assert inside(region, 1.0, 45.5), "on the border the two share"
    assert inside(region, 1.0 + 10 * KM, 45.5)
    assert "AAA, BBB" in region["source"]

    with pytest.raises(ValueError, match="CCC"):
        country_region(tmp_path, {"AAA": [[ALAND]]}, codes=("AAA", "CCC"))


def test_a_country_part_fills_the_sea_it_encloses_and_keeps_far_islands(tmp_path):
    # Land all round an inland sea 50 km across, too wide for the push to close, and an island 150 km to the south.
    sea = [[0.15, 45.25], [0.15 + 50 * KM, 45.25], [0.15 + 50 * KM, 45.7], [0.15, 45.7], [0.15, 45.25]]
    island = [[0.4, 43.6], [0.6, 43.6], [0.6, 43.7], [0.4, 43.7], [0.4, 43.6]]
    region = country_region(tmp_path, {"AAA": [[ALAND, sea], [island]]})

    assert inside(region, 0.15 + 25 * KM, 45.475), "a boat in the middle of the inland sea"
    assert all(len(polygon) == 1 for polygon in region["polygons"]), "no holes"
    assert len(region["polygons"]) == 2
    assert inside(region, 0.5, 43.65), "the island"
    assert not inside(region, 0.5, 44.3), "open sea between the two"


def test_a_country_part_takes_the_unclaimed_islets_nearest_its_land(tmp_path):
    # Natural Earth draws islets under a few square kilometres in a file of their own that does not say whose they are.
    def islet(longitude, latitude):
        return [[[longitude, latitude], [longitude + KM, latitude], [longitude + KM, latitude + 0.01], [longitude, latitude + 0.01], [longitude, latitude]]]

    ours = islet(-100 * KM, 45.5)  # 100 km off Aland's west coast
    theirs = islet(2.0 + 40 * KM, 45.5)  # 40 km off Bland, 120 km from Aland
    nobodys = islet(0.5, 41.4)  # 400 km south of both
    region = country_region(tmp_path, {"AAA": [[ALAND]], "BBB": [[BLAND]]}, islets=[ours, theirs, nobodys])

    assert inside(region, -99.5 * KM, 45.505), "on our islet"
    assert inside(region, -103 * KM, 45.505), "a boat 3 km off it"
    assert not inside(region, -50 * KM, 45.5), "open sea between the islet and the coast"
    assert not inside(region, 2.0 + 40.5 * KM, 45.505), "the neighbour's islet"
    assert not inside(region, 0.5 + 0.5 * KM, 41.405), "an islet out of reach of any land"


def test_a_country_part_near_the_antimeridian_is_cut_at_180_degrees(tmp_path):
    # An island 2 km short of 180°: the push carries it across, and the phone tests plain longitudes.
    island = [[179.7, 51.9], [180 - 2 * KM, 51.9], [180 - 2 * KM, 52.0], [179.7, 52.0], [179.7, 51.9]]
    region = country_region(tmp_path, {"AAA": [[island]]})

    longitudes = [point[0] for polygon in region["polygons"] for ring in polygon for point in ring]
    assert min(longitudes) == -180.0 and max(longitudes) == 180.0
    assert inside(region, 179.8, 51.95), "on the island"
    assert inside(region, -179.98, 51.95), "a boat 3 km east of it, across the line"
    assert not inside(region, -179.0, 51.95)
    assert not inside(region, 0.0, 51.95), "nothing is drawn the long way round the globe"


# The United States and Canada as the builder draws them (issue #210). No pack definition has the boundary yet, so it
# is pinned as a fixture the Album package's placement test reads too: `packbuilder set` on the folder rebuilds it.

COUNTRY_FIXTURE = REPO / "BirdJournal" / "BirdJournalKit" / "Tests" / "AlbumTests" / "Fixtures" / "united-states-and-canada"

# (longitude, latitude)
INLAND = {
    "Chicago": (-87.63, 41.88), "Denver": (-104.99, 39.74), "Winnipeg": (-97.14, 49.90), "Anchorage": (-149.90, 61.22), "Honolulu": (-157.86, 21.31),
    "Washington, DC": (-77.04, 38.90), "Key West": (-81.78, 24.56), "St. John's": (-52.71, 47.56), "Utqiagvik": (-156.79, 71.29), "Alert": (-62.35, 82.50),
    "Adak": (-176.65, 51.88), "Attu, east of 180°": (173.2, 52.9), "St. Paul Island": (-170.28, 57.12),
}
ISLETS = {
    # Drawn among Natural Earth's minor islands, which carry no country, and too far out for the push to reach.
    "Monhegan Island, Maine": (-69.315, 43.765), "Fort Jefferson, Dry Tortugas": (-82.873, 24.628),
    "Southeast Farallon Island": (-123.0, 37.70), "Santa Barbara Island, California": (-119.035, 33.475),
}
ON_THE_BORDER = {
    "Border Field State Park": (-117.12, 32.54), "Santa Ana NWR": (-98.135, 26.08), "Sabal Palm Sanctuary": (-97.418, 25.852),
    "Rio Grande Village": (-102.96, 29.18), "Point Roberts": (-123.07, 48.98), "Niagara Falls, Ontario": (-79.07, 43.09),
}
NEAR_SHORE = {
    "the end of Santa Monica Pier": (-118.4987, 34.0083), "a boat 4 km off Santa Monica": (-118.53, 33.98), "a boat off Halifax": (-63.50, 44.55),
    "a boat 3 km off Galveston": (-94.78, 29.24), "a boat off Tofino": (-125.97, 49.11), "a boat off Waikiki": (-157.84, 21.25),
    "the middle of Lake Michigan": (-87.0, 43.4), "Belcher Channel, 4 km off Cornwall Island, Nunavut": (-93.45, 77.79),
}
ABROAD = {
    "Mexico City": (-99.13, 19.43), "Monterrey": (-100.32, 25.69), "Ensenada": (-116.60, 31.87), "Ciudad Juárez airport": (-106.43, 31.64),
    "Havana": (-82.37, 23.11), "Nuuk": (-51.72, 64.18), "Qaanaaq": (-69.23, 77.47), "Nassau": (-77.35, 25.05), "Saint-Pierre": (-56.17, 46.78),
    "Bermuda": (-64.78, 32.30), "Provideniya": (-173.23, 64.42),
}
MID_OCEAN = {"the mid-Atlantic": (-40.0, 40.0), "between California and Hawaii": (-140.0, 30.0), "the middle of the Gulf of Mexico": (-90.0, 25.0)}
TERRITORIES = {
    "San Juan, Puerto Rico": (-66.11, 18.47), "St. Thomas, US Virgin Islands": (-64.93, 18.34), "Guam": (144.79, 13.44),
    "Saipan": (145.75, 15.18), "Pago Pago": (-170.70, -14.28),
}


def united_states_and_canada() -> dict:
    [region] = load_set(COUNTRY_FIXTURE / "set.json")["regions"]
    return region


@pytest.mark.parametrize("place", [*INLAND, *ISLETS, *ON_THE_BORDER, *NEAR_SHORE])
def test_the_united_states_and_canada_hold(place):
    assert inside(united_states_and_canada(), *{**INLAND, **ISLETS, **ON_THE_BORDER, **NEAR_SHORE}[place])


@pytest.mark.parametrize("place", [*ABROAD, *MID_OCEAN, *TERRITORIES])
def test_the_united_states_and_canada_leave_out(place):
    assert not inside(united_states_and_canada(), *{**ABROAD, **MID_OCEAN, **TERRITORIES}[place])


def test_the_united_states_and_canada_are_small_enough_for_the_index():
    region = united_states_and_canada()
    rings = [ring for polygon in region["polygons"] for ring in polygon]
    assert all(ring[0] == ring[-1] and len(ring) >= 4 for ring in rings)
    assert all(-180 <= longitude <= 180 and 18 < latitude < 84 for ring in rings for longitude, latitude in ring)
    assert sum(len(ring) for ring in rings) < 2_000, "every placement call walks these points"
    assert len(json.dumps(region, separators=(",", ":"))) < 35_000, "about what a regional set's counties take"


def test_the_country_fixture_is_current():
    """Its source line names the push and the tolerance, so changing either makes it stale."""
    check_set(load_set(COUNTRY_FIXTURE / "set.json"), PackDefinition.load(COUNTRY_FIXTURE / "pack.json"))


def test_the_country_fixture_is_what_the_builder_draws_from_natural_earth():
    cache = REPO / "packbuilder" / "cache" / "boundaries"
    if not all(path.exists() for path in cached_files(cache)):
        pytest.skip("Natural Earth is not in the cache (`packbuilder set` fetches it)")
    section = PackDefinition.load(COUNTRY_FIXTURE / "pack.json").set
    document = build_set(definition([entry("Calypte anna", "Anna's Hummingbird")], section), COUNTRY_FIXTURE, PublicBoundaries(cache.parent), Taxonomy.parse(IOC_XML))
    assert document["regions"] == load_set(COUNTRY_FIXTURE / "set.json")["regions"]


# The committed set definitions


@pytest.mark.parametrize("pack_dir", sorted(PACKS.iterdir()), ids=lambda p: p.name)
def test_every_pack_has_a_current_set(pack_dir):
    built = PackDefinition.load(pack_dir / "pack.json")
    assert built.set is not None, "pack.json has no set section"
    document = load_set(pack_dir / "set.json")
    check_set(document, built)
    assert len(document["species"]) == len(built.species)
    for region in document["regions"]:
        assert region["polygons"], region["name"]
        for polygon in region["polygons"]:
            for ring in polygon:
                assert ring[0] == ring[-1] and len(ring) >= 4, region["name"]
    assert len(json.dumps(document)) < 200_000, "the index carries every set; keep the boundary simplified"


def test_the_deserts_set_holds_anza_borrego_inside_san_diego_county():
    """Anza-Borrego sits inside San Diego County: the app gives the point to the smaller region, the Deserts set."""
    point = (-116.40, 33.25)  # Borrego Springs
    deserts = load_set(PACKS / "us-ca-desert" / "set.json")
    san_diego = load_set(PACKS / "us-ca-sd" / "set.json")
    containing = [r for r in deserts["regions"] if any(_contains(p, point) for p in r["polygons"])]
    assert [r["name"] for r in containing] == ["Anza-Borrego Desert State Park"]
    assert any(_contains(p, point) for r in san_diego["regions"] for p in r["polygons"])
    assert polygon_area_km2(containing[0]["polygons"][0]) < sum(polygon_area_km2(p) for r in san_diego["regions"] for p in r["polygons"])


def _contains(polygon, point) -> bool:
    x, y = point
    inside = False
    for ring in polygon:
        for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
            if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
                inside = not inside
    return inside
