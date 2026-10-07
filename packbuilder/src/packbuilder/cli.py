"""`packbuilder build <definition-dir> --out <pack-dir>`: builds one pack from its definition folder.
`packbuilder draft --place <id> ...`: prints a first species list for a new pack (`species_list.py`)."""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from packbuilder import xenocanto
from packbuilder.definition import PackDefinition
from packbuilder.descriptions import WikipediaDescriptions
from packbuilder.detector import BirdDetector, ensure_model
from packbuilder.pipeline import BuildOptions, build_pack


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="packbuilder", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="build a pack")
    build.add_argument("definition", type=Path, help="folder holding pack.json and overrides.json")
    build.add_argument("--out", type=Path, required=True, help="pack directory to write (replaced)")
    build.add_argument("--source", choices=["api", "opendata"], default="api", help="iNaturalist API (default) or the Open Data metadata CSVs")
    build.add_argument("--metadata-dir", type=Path, help="folder with the extracted Open Data CSVs (with --source opendata)")
    build.add_argument("--cache", type=Path, default=Path(__file__).resolve().parents[2] / "cache", help="download cache (default: packbuilder/cache)")
    build.add_argument("--limit", type=int, default=60, help="cleared candidates per species to download and detect (default 60)")
    build.add_argument("--min-photos", type=int, default=3, help="photos per species below which a gap is logged (default 3)")
    build.add_argument("--max-photos", type=int, default=5, help="photos kept per species (default 5)")
    build.add_argument("--zip", type=Path, metavar="PATH", help="also write a zip of the pack at PATH")
    build.add_argument("--built-at", help="ISO timestamp to record instead of now (for reproducible output)")
    build.add_argument("--workers", type=int, default=8, help="concurrent photo downloads per species (default 8)")
    build.add_argument("--no-descriptions", action="store_true", help="skip the Wikipedia descriptions (overrides.json text still applies)")
    build.add_argument("--no-sounds", action="store_true", help="skip the reference sounds (the pack then has none)")
    build.add_argument("--xc-interval", type=float, default=xenocanto.DEFAULT_INTERVAL, help=f"seconds between xeno-canto requests (default {xenocanto.DEFAULT_INTERVAL:g}; {xenocanto.MIN_INTERVAL:g} is the floor)")
    build.add_argument("--xc-max-requests", type=int, default=xenocanto.DEFAULT_MAX_REQUESTS, help=f"xeno-canto requests after which the run stops; rerun to continue from the cache (default {xenocanto.DEFAULT_MAX_REQUESTS})")
    build.add_argument("--sound-tries", type=int, default=3, help="recordings downloaded per species and kind before the kind is a gap (default 3)")
    draft = commands.add_parser("draft", help="print a species list for a new pack from iNaturalist observation counts")
    draft.add_argument("--place", type=int, action="append", required=True, help="iNaturalist place id (repeat for several)")
    draft.add_argument("--before", required=True, help="count observations created up to this date (YYYY-MM-DD); goes in the pack as inat_created_before")
    draft.add_argument("--top", type=int, default=150, help="most-observed species of the year (default 150)")
    draft.add_argument("--season", help="months for a second ranking, such as 10,11")
    draft.add_argument("--season-top", type=int, default=0, help="most-observed species of --season also taken")
    draft.add_argument("--add", action="append", default=[], help="a species taken by hand, by scientific name (repeat)")
    draft.add_argument("--exclude", action="append", default=[], help="a species never taken, by scientific name (repeat)")
    draft.add_argument("--cache", type=Path, default=Path(__file__).resolve().parents[2] / "cache", help="download cache (default: packbuilder/cache)")
    args = parser.parse_args(argv)
    if args.command == "draft":
        return _draft(args)

    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    definition = PackDefinition.load(args.definition / "pack.json")

    if args.source == "opendata":
        if not args.metadata_dir:
            parser.error("--source opendata needs --metadata-dir")
        from packbuilder.metadata_opendata import OpenDataMetadata

        metadata = OpenDataMetadata(args.metadata_dir, definition.bounding_box, [s.inat_taxon_id for s in definition.species])
    else:
        from packbuilder.metadata_api import APIMetadata

        metadata = APIMetadata(definition.place_ids, args.cache, created_before=definition.created_before)

    detector = BirdDetector(ensure_model(args.cache))
    descriptions = None if args.no_descriptions else WikipediaDescriptions(args.cache, lock_path=args.definition / "wikipedia.lock.json")
    options = BuildOptions(
        cache_dir=args.cache, out_dir=args.out, candidate_limit=args.limit, min_photos=args.min_photos, max_photos=args.max_photos,
        archive_path=args.zip, built_at=args.built_at, download_workers=args.workers,
    )
    sounds = None if args.no_sounds else _sound_picker(args, definition)
    from packbuilder.xenocanto import MissingAPIKey, RateLimited, RequestBudgetExceeded, XenoCantoBusy, XenoCantoError

    try:
        build_pack(definition, args.definition / "overrides.json", metadata, detector, options, descriptions, sounds)
    except (MissingAPIKey, RateLimited, RequestBudgetExceeded, XenoCantoBusy, XenoCantoError) as error:
        logging.getLogger("packbuilder").error("sounds stopped the build: %s", error)
        return 2
    if descriptions is not None:
        descriptions.write_lock()
    return 0


def _sound_picker(args: argparse.Namespace, definition: PackDefinition):
    """The sounds stage (issue #41): xeno-canto first, through its paced, capped client, then iNaturalist; the clips
    checked with the app's BirdNET model; `sounds.lock.json` beside the definition pinning what was chosen."""
    import json

    from packbuilder.audio import BirdNETCheck, ClipMaker
    from packbuilder.definition import load_overrides
    from packbuilder.sounds import SoundLock, SoundOverrides, SoundPicker
    from packbuilder.sounds_inat import INaturalistSoundSource
    from packbuilder.xenocanto import XenoCantoClient, XenoCantoSoundSource, api_key_from_environment, xeno_canto_pacer

    repo = Path(__file__).resolve().parents[3]
    country = json.loads((args.definition / "pack.json").read_text()).get("country", "United States")
    sound_overrides = {
        name: SoundOverrides.from_mapping(data.get("sounds"))
        for name, data in load_overrides(args.definition / "overrides.json").items() if isinstance(data, dict)
    }
    names = {name: overrides.xeno_canto_name for name, overrides in sound_overrides.items() if overrides.xeno_canto_name}
    cache = args.cache / "sounds"
    client = XenoCantoClient(cache / "xeno-canto", api_key_from_environment(), pacer=xeno_canto_pacer(args.xc_interval), max_requests=args.xc_max_requests)
    xeno_canto = XenoCantoSoundSource(client, country=country, names=names)
    inaturalist = INaturalistSoundSource(cache / "inaturalist")
    return SoundPicker(
        sources=[xeno_canto, inaturalist], clips=ClipMaker(), check=BirdNETCheck(repo / "models"),
        clip_dir=cache / "clips", lock=SoundLock(args.definition / "sounds.lock.json"), country=country, max_tries=args.sound_tries,
    )


def _draft(args: argparse.Namespace) -> int:
    import json

    from packbuilder.species_list import SpeciesCounts, birdnet_labels, draft, known_entries

    repo = Path(__file__).resolve().parents[3]
    counts = SpeciesCounts(tuple(args.place), args.cache, args.before)
    months = tuple(int(m) for m in args.season.split(",")) if args.season else ()
    result = draft(
        counts, birdnet_labels(repo / "models" / "BirdNET+_V3.0-preview3.1_Global_11K_Labels.csv"),
        known_entries(sorted((repo / "packbuilder" / "packs").iterdir())), args.top,
        season_months=months, season_top=args.season_top, add=args.add, exclude=set(args.exclude),
    )
    for ranked, why in result.skipped:
        print(f"skipped   {ranked.name} ({ranked.common_name}), {why}", file=sys.stderr)
    for ranked, name in result.renamed:
        print(f"renamed   {ranked.name} ({ranked.common_name}) as BirdNET's {name}: check", file=sys.stderr)
    for ranked in result.unresolved:
        print(f"UNRESOLVED {ranked.name} ({ranked.common_name}, taxon {ranked.taxon_id}, {ranked.count} obs): not a BirdNET label", file=sys.stderr)
    print(f"{len(result.species)} species", file=sys.stderr)
    json.dump(result.species, sys.stdout, indent=2, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
