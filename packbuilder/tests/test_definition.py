"""The committed pack definitions: every species is a BirdNET+ label (the key the engine and the pack share), named
as the label file names it, with an iNaturalist taxon and a Wikipedia article (issue #12)."""

import csv
import json
from pathlib import Path

import pytest

from packbuilder.definition import PackDefinition, load_overrides

REPO = Path(__file__).resolve().parents[2]
PACKS = REPO / "packbuilder" / "packs"
LABELS = REPO / "models" / "BirdNET+_V3.0-preview3.1_Global_11K_Labels.csv"


def birdnet_labels() -> dict[str, str]:
    with LABELS.open(encoding="utf-8-sig") as handle:
        return {row["sci_name"]: row["com_name"] for row in csv.DictReader(handle, delimiter=";")}


@pytest.mark.parametrize("pack_dir", sorted(PACKS.iterdir()), ids=lambda p: p.name)
def test_pack_definition_loads_with_unique_complete_species(pack_dir):
    definition = PackDefinition.load(pack_dir / "pack.json")
    assert definition.id == pack_dir.name
    names = [s.scientific_name for s in definition.species]
    assert len(names) == len(set(names)), "a species is listed twice"
    taxa = [s.inat_taxon_id for s in definition.species]
    assert len(taxa) == len(set(taxa)), "an iNaturalist taxon is listed twice"
    for species in definition.species:
        assert species.wikipedia_url and species.wikipedia_url.startswith("https://en.wikipedia.org/wiki/"), species.scientific_name
        assert species.inat_taxon_id > 0


@pytest.mark.parametrize("pack_dir", sorted(PACKS.iterdir()), ids=lambda p: p.name)
def test_overrides_name_species_of_the_pack(pack_dir):
    definition = PackDefinition.load(pack_dir / "pack.json")
    overrides = load_overrides(pack_dir / "overrides.json")
    names = {s.scientific_name for s in definition.species}
    for key in overrides:
        if not key.startswith("_"):
            assert key in names, f"override for {key!r}, which is not in the pack"


@pytest.mark.skipif(not LABELS.exists(), reason="BirdNET label file not downloaded (scripts/download-models.sh)")
@pytest.mark.parametrize("pack_dir", sorted(PACKS.iterdir()), ids=lambda p: p.name)
def test_every_species_is_a_birdnet_label_spelled_as_the_label_file(pack_dir):
    labels = birdnet_labels()
    definition = PackDefinition.load(pack_dir / "pack.json")
    for species in definition.species:
        assert species.scientific_name in labels, f"{species.scientific_name} is not a BirdNET+ label"
        assert species.common_name == labels[species.scientific_name], f"{species.scientific_name}: {species.common_name!r} vs label {labels[species.scientific_name]!r}"


def test_la_pack_is_about_150_species():
    definition = PackDefinition.load(PACKS / "us-ca-la" / "pack.json")
    assert 140 <= len(definition.species) <= 170
    assert json.loads((PACKS / "us-ca-la" / "pack.json").read_text())["inat_created_before"] == "2026-09-26"
