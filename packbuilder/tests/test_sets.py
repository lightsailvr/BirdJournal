"""The set definition (issue #54): a pack's region boundary simplified from public-domain sources or a committed
hand-drawn polygon, its species in taxonomic order, and its edition."""

import json
import math
from pathlib import Path

import pytest

from packbuilder.definition import BoundingBox, PackDefinition, SpeciesEntry
from packbuilder.sets import (
    BoundaryPart,
    Edition,
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

    def __init__(self, polygons):
        self.polygons = polygons
        self.asked = []

    def polygons_for(self, part, definition_dir):
        self.asked.append(part)
        return self.polygons


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
