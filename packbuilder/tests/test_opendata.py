from pathlib import Path

from packbuilder.definition import BoundingBox
from packbuilder.metadata_opendata import OpenDataMetadata


def write_tsv(path: Path, header: str, rows: list[str]) -> None:
    path.write_text("\n".join([header, *rows]) + "\n")


def test_open_data_join_yields_photo_candidates(tmp_path):
    write_tsv(
        tmp_path / "observations.csv",
        "observation_uuid\tobserver_id\tlatitude\tlongitude\tpositional_accuracy\ttaxon_id\tquality_grade\tobserved_on\tanomaly_score",
        [
            "aaaa-1\t1\t34.05\t-118.25\t10\t17013\tresearch\t2024-01-01\t",
            "aaaa-2\t2\t34.06\t-118.26\t10\t17013\tneeds_id\t2024-01-02\t",
            "aaaa-3\t1\t40.7\t-74.0\t10\t17013\tresearch\t2024-01-03\t",   # outside the bounding box
            "aaaa-4\t1\t34.07\t-118.27\t10\t99999\tresearch\t2024-01-04\t",  # other taxon
        ],
    )
    write_tsv(
        tmp_path / "photos.csv",
        "photo_uuid\tphoto_id\tobservation_uuid\tobserver_id\textension\tlicense\twidth\theight\tposition",
        [
            "p1\t1001\taaaa-1\t1\tjpg\tCC-BY-NC\t2048\t1365\t0",
            "p2\t1002\taaaa-1\t1\tjpeg\tCC-BY-SA\t2048\t1365\t1",
            "p3\t1003\taaaa-2\t2\tjpg\tCC0\t1000\t1000\t0",
            "p4\t1004\taaaa-3\t1\tjpg\tCC0\t1000\t1000\t0",
            "p5\t1005\taaaa-4\t1\tjpg\tCC0\t1000\t1000\t0",
        ],
    )
    write_tsv(tmp_path / "observers.csv", "observer_id\tlogin\tname", ["1\tjbirder\tJane Birder", "2\tother\t"])

    source = OpenDataMetadata(tmp_path, BoundingBox(south=33.7, west=-118.95, north=34.85, east=-117.65), taxon_ids=[17013, 42])
    candidates = source.candidates_for(taxon_id=17013)
    assert source.candidates_for(taxon_id=42) == []

    by_id = {c.photo_id: c for c in candidates}
    assert set(by_id) == {1001, 1002}
    assert by_id[1001].license == "CC-BY-NC"
    assert by_id[1001].observer_name == "Jane Birder"
    assert by_id[1001].observer_login == "jbirder"
    assert by_id[1001].observation_uuid == "aaaa-1"
    assert by_id[1001].observation_id is None
    assert by_id[1001].quality_grade == "research"
    assert by_id[1002].extension == "jpeg"
