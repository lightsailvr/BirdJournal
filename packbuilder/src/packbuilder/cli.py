"""`packbuilder build <definition-dir> --out <pack-dir>`: builds one pack from its definition folder.
`packbuilder set <definition-dir>`: builds the pack's set definition into set.json beside pack.json (`sets.py`).
`packbuilder art-review <definition-dir> ...`: records the maintainer's review of the pack art in art.lock.json (`pack_art.py`).
`packbuilder lore <definition-dir>`: writes only the fact sheets and the lore the lore lock lacks, without building the pack.
`packbuilder lore-review <definition-dir> ...`: records the maintainer's review of the lore in lore.lock.json (`lore.py`).
`packbuilder index --out <file>`: writes the pack index the phone reads, with every pack's set (`index.py`).
`packbuilder draft --place <id> ...`: prints a first species list for a new pack (`species_list.py`).
`packbuilder calibrate-rarity --version <n>`: writes the rarity label thresholds the app ships (`rarity.py`)."""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from packbuilder import xenocanto
from packbuilder.definition import PackDefinition
from packbuilder.descriptions import WikipediaDescriptions
from packbuilder.detector import BirdDetector, ensure_model
from packbuilder.licenses import PHOTO_LICENSES, inat_codes, normalize_license
from packbuilder.pipeline import BuildOptions, build_pack
from packbuilder.sets import check_set, load_set

COMFY = "http://comfybox:8189"
"""The FLUX.3 ComfyUI on comfybox (art/README.md), reached over the tailnet."""


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
    build.add_argument("--photo-licenses", type=_license_set, default=PHOTO_LICENSES, metavar="CODES", help=f"iNaturalist license codes a photo may carry, comma-separated (default {','.join(inat_codes(PHOTO_LICENSES))}, ADR-0001)")
    build.add_argument("--no-descriptions", action="store_true", help="skip the Wikipedia descriptions (overrides.json text still applies)")
    build.add_argument("--no-sounds", action="store_true", help="skip the reference sounds (the pack then has none)")
    build.add_argument("--xc-interval", type=float, default=xenocanto.DEFAULT_INTERVAL, help=f"seconds between xeno-canto requests (default {xenocanto.DEFAULT_INTERVAL:g}; {xenocanto.MIN_INTERVAL:g} is the floor)")
    build.add_argument("--xc-max-requests", type=int, default=xenocanto.DEFAULT_MAX_REQUESTS, help=f"xeno-canto requests after which the run stops; rerun to continue from the cache (default {xenocanto.DEFAULT_MAX_REQUESTS})")
    build.add_argument("--sound-tries", type=int, default=3, help="recordings downloaded per species and kind before the kind is a gap (default 3)")
    build.add_argument("--comfy", default=COMFY, help=f"the FLUX.3 ComfyUI that paints the pack art the lock lacks (default {COMFY}, on the tailnet)")
    build.add_argument("--no-art", action="store_true", help="skip the pack art (the pack then has none)")
    build.add_argument("--art-sheets", type=Path, help="folder for the pack art's contact sheets (default build/pack-art/<pack id>)")
    build.add_argument("--no-lore", action="store_true", help="skip the lore (the pack then has none; the fact sheet still ships)")
    build.add_argument("--regenerate-lore", action="append", default=[], metavar="SPECIES", help="write a species' lore again (species id or common name; repeat; 'all' for every species)")
    build.add_argument("--lore-interval", type=float, default=None, help="seconds between Anthropic API requests for the lore (default lore.DEFAULT_INTERVAL)")
    build.add_argument("--lore-model", default=None, help="the Claude model that writes the lore (default lore.MODEL)")
    build.add_argument("--lore-review", type=Path, help="the lore's review file (default build/lore/<pack id>/review.md)")
    lore_command = commands.add_parser("lore", help="write the lore lore.lock.json lacks, and its review file, without building the pack")
    lore_command.add_argument("definition", type=Path, help="folder holding pack.json, overrides.json and lore.lock.json")
    lore_command.add_argument("--cache", type=Path, default=Path(__file__).resolve().parents[2] / "cache", help="download cache (default: packbuilder/cache)")
    lore_command.add_argument("--regenerate-lore", action="append", default=[], metavar="SPECIES", help="write a species' lore again (repeat; 'all' for every species)")
    lore_command.add_argument("--lore-interval", type=float, default=None, help="seconds between Anthropic API requests (default lore.DEFAULT_INTERVAL)")
    lore_command.add_argument("--lore-model", default=None, help="the Claude model that writes the lore (default lore.MODEL)")
    lore_command.add_argument("--lore-review", type=Path, help="the review file (default build/lore/<pack id>/review.md)")
    lore_command.add_argument("--only", action="append", default=[], metavar="SPECIES", help="only these species (repeat), for a trial")
    lore_review = commands.add_parser("lore-review", help="record the review of the lore in lore.lock.json and rewrite its review file")
    lore_review.add_argument("definition", type=Path, help="folder holding pack.json and lore.lock.json")
    lore_review.add_argument("--approve", action="append", default=[], metavar="SPECIES", help="approve a species' lore (species id or common name; repeat)")
    lore_review.add_argument("--approve-all", action="store_true", help="approve all lore still pending")
    lore_review.add_argument("--reject", action="append", default=[], metavar="SPECIES", help="reject a species' lore: the next build writes it again, with --why in the prompt (repeat)")
    lore_review.add_argument("--why", help="the reason, kept in the lock and given to the model with --reject")
    lore_review.add_argument("--sheet", type=Path, help="the review file to write (default build/lore/<pack id>/review.md)")
    art_review = commands.add_parser("art-review", help="record the review of the pack art's contact sheets in art.lock.json")
    art_review.add_argument("definition", type=Path, help="folder holding pack.json and art.lock.json")
    art_review.add_argument("--approve", action="append", default=[], metavar="SPECIES", help="approve a painting (species id or common name; repeat)")
    art_review.add_argument("--approve-all", action="store_true", help="approve every painting still pending")
    art_review.add_argument("--reject", action="append", default=[], metavar="SPECIES", help="reject a painting: the next build paints it again with new seeds (repeat)")
    art_review.add_argument("--gap", action="append", default=[], metavar="SPECIES", help="give up on a species' art: its cards fall back to the reference photo (repeat)")
    art_review.add_argument("--why", help="the reason, kept in the lock with --reject or --gap")
    set_command = commands.add_parser("set", help="build the set definition (boundary, taxonomic order, edition) into set.json")
    set_command.add_argument("definition", type=Path, help="folder holding pack.json")
    set_command.add_argument("--cache", type=Path, default=Path(__file__).resolve().parents[2] / "cache", help="download cache (default: packbuilder/cache)")
    set_command.add_argument("--tolerance-km", type=float, default=None, help="boundary simplification tolerance in km (default sets.DEFAULT_TOLERANCE_KM)")
    index_command = commands.add_parser("index", help="write the pack index from packs/manifest.json and every pack's set.json")
    index_command.add_argument("--out", type=Path, required=True, help="index file to write")
    index_command.add_argument("--repo", default="lightsailvr/BirdJournal", help="GitHub repository the pack zips are released on")
    draft = commands.add_parser("draft", help="print a species list for a new pack from iNaturalist observation counts")
    draft.add_argument("--place", type=int, action="append", required=True, help="iNaturalist place id (repeat for several)")
    draft.add_argument("--before", required=True, help="count observations created up to this date (YYYY-MM-DD); goes in the pack as inat_created_before")
    draft.add_argument("--top", type=int, default=150, help="most-observed species of the year (default 150)")
    draft.add_argument("--season", help="months for a second ranking, such as 10,11")
    draft.add_argument("--season-top", type=int, default=0, help="most-observed species of --season also taken")
    draft.add_argument("--add", action="append", default=[], help="a species taken by hand, by scientific name (repeat)")
    draft.add_argument("--exclude", action="append", default=[], help="a species never taken, by scientific name (repeat)")
    draft.add_argument("--cache", type=Path, default=Path(__file__).resolve().parents[2] / "cache", help="download cache (default: packbuilder/cache)")
    calibrate = commands.add_parser("calibrate-rarity", help="write the rarity label thresholds from the geomodel over every pack definition")
    calibrate.add_argument("--version", type=int, required=True, help="the calibration version; bump it for any new calibration")
    calibrate.add_argument("--out", type=Path, help="file to write (default: the Identification module's RarityCalibration.json)")
    args = parser.parse_args(argv)
    if args.command == "draft":
        return _draft(args)
    if args.command == "set":
        return _set(args)
    if args.command == "index":
        return _index(args)
    if args.command == "calibrate-rarity":
        return _calibrate_rarity(args)
    if args.command == "art-review":
        return _art_review(args)
    if args.command == "lore-review":
        return _lore_review(args)
    if args.command == "lore":
        return _lore(args)

    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    definition = PackDefinition.load(args.definition / "pack.json")
    # The pinned set first, so a stale one stops the build before any download (issue #54).
    card_set = load_set(args.definition / "set.json")
    check_set(card_set, definition)
    # The stats join next (issue #55): an unmapped species fails here too, not after an hour of photos.
    from packbuilder.stats import Datasets, StatsFixes, TypeLines, join

    joined = join(definition.species, Datasets.load(args.cache), StatsFixes.load(), TypeLines.load())

    if args.source == "opendata":
        if not args.metadata_dir:
            parser.error("--source opendata needs --metadata-dir")
        from packbuilder.metadata_opendata import OpenDataMetadata

        metadata = OpenDataMetadata(args.metadata_dir, definition.bounding_box, [s.inat_taxon_id for s in definition.species])
    else:
        from packbuilder.metadata_api import APIMetadata

        metadata = APIMetadata(definition.place_ids, args.cache, created_before=definition.created_before, licenses=args.photo_licenses)

    detector = BirdDetector(ensure_model(args.cache))
    descriptions = None if args.no_descriptions else WikipediaDescriptions(args.cache, lock_path=args.definition / "wikipedia.lock.json")
    options = BuildOptions(
        cache_dir=args.cache, out_dir=args.out, candidate_limit=args.limit, min_photos=args.min_photos, max_photos=args.max_photos,
        archive_path=args.zip, built_at=args.built_at, download_workers=args.workers, photo_licenses=args.photo_licenses,
    )
    sounds = None if args.no_sounds else _sound_picker(args, definition)
    artist = None if args.no_art else _artist(args, definition)
    sheets = args.art_sheets or Path(__file__).resolve().parents[3] / "build" / "pack-art" / definition.id
    lore = None if args.no_lore else _lore_writer(args, definition)
    lore_review = args.lore_review or _lore_review_path(definition.id)
    from packbuilder.lore import InvalidLore, LoreAPIError, LoreRefused, MissingAPIKey as MissingLoreKey
    from packbuilder.xenocanto import MissingAPIKey, RateLimited, RequestBudgetExceeded, XenoCantoBusy, XenoCantoError

    try:
        build_pack(
            definition, args.definition / "overrides.json", metadata, detector, options, descriptions, sounds,
            card_set=card_set, joined=joined, artist=artist, art_sheets=sheets, lore=lore, lore_review=lore_review,
        )
    except (MissingAPIKey, RateLimited, RequestBudgetExceeded, XenoCantoBusy, XenoCantoError) as error:
        logging.getLogger("packbuilder").error("sounds stopped the build: %s", error)
        return 2
    except (MissingLoreKey, LoreAPIError, LoreRefused, InvalidLore) as error:
        logging.getLogger("packbuilder").error("lore stopped the build: %s", error)
        return 2
    if descriptions is not None:
        descriptions.write_lock()
    return 0


def _license_set(value: str) -> frozenset[str]:
    """`cc0,cc-by,cc-by-sa` as canonical license names."""
    licenses = {code: normalize_license(code) for code in value.split(",") if code.strip()}
    unknown = [code for code, license in licenses.items() if license is None]
    if unknown or not licenses:
        raise argparse.ArgumentTypeError(f"not iNaturalist license codes: {value}")
    return frozenset(licenses.values())


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


def _artist(args: argparse.Namespace, definition: PackDefinition):
    """The pack-art step (issue #57): paints in the set's edition theme on comfybox what `art.lock.json` lacks, into
    the art cache, with the reference photos `overrides.json` pins as `art.reference`."""
    from packbuilder.comfy import ComfyClient
    from packbuilder.definition import load_overrides
    from packbuilder.pack_art import LOCK_FILE, ArtLock, PackArtist

    if definition.set is None:
        raise SystemExit(f"{definition.id}: pack art is painted in the set's edition theme, and pack.json has no set (or pass --no-art)")
    overrides = load_overrides(args.definition / "overrides.json")
    references = {
        entry.id: int(data["art"]["reference"])
        for entry in definition.species
        if isinstance(data := overrides.get(entry.scientific_name), dict) and isinstance(data.get("art"), dict) and data["art"].get("reference") is not None
    }
    return PackArtist(
        ComfyClient(args.comfy), pack_id=definition.id, theme=definition.set.edition.theme, lock=ArtLock.load(args.definition / LOCK_FILE),
        cache_dir=args.cache / "art", references=references,
    )


def _lore_writer(args: argparse.Namespace, definition: PackDefinition):
    """The lore step (issue #56): writes what `lore.lock.json` lacks, or what --regenerate-lore names, through the
    Anthropic API; the key is read only when a request is needed."""
    from packbuilder.lore import ALL, DEFAULT_INTERVAL, LOCK_FILE, MODEL, AnthropicLoreClient, LoreLock, LoreWriter, api_key_from_environment

    model = args.lore_model or MODEL
    lock = LoreLock.load(args.definition / LOCK_FILE)
    by_name = {entry.common_name.lower(): entry.id for entry in definition.species}
    ids = {entry.id for entry in definition.species}
    regenerate = set()
    for name in args.regenerate_lore:
        if name == ALL or name in ids:
            regenerate.add(name)
        elif name.lower() in by_name:
            regenerate.add(by_name[name.lower()])
        else:
            raise SystemExit(f"--regenerate-lore {name!r}: no such species in {definition.id}")
    return LoreWriter(
        lock=lock, client_factory=lambda: AnthropicLoreClient(api_key_from_environment(), model), model=model,
        regenerate=frozenset(regenerate), interval=args.lore_interval if args.lore_interval is not None else DEFAULT_INTERVAL,
    )


def _lore(args: argparse.Namespace) -> int:
    """The fact sheets and lore alone: the descriptions and stats from the cache, then the lore step, as `build` runs
    them, so the lore can be written and reviewed before a pack build."""
    from packbuilder.definition import load_overrides
    from packbuilder.lore import InvalidLore, LoreAPIError, LoreRefused, MissingAPIKey, review_sheet
    from packbuilder.pipeline import describe, fact_sheets
    from packbuilder.selection import Overrides
    from packbuilder.stats import Datasets, StatsFixes, TypeLines, join
    from packbuilder.writer import SpeciesResult

    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    definition = PackDefinition.load(args.definition / "pack.json")
    species = [entry for entry in definition.species if not args.only or entry.id in args.only or entry.common_name.lower() in {name.lower() for name in args.only}]
    joined = join(species, Datasets.load(args.cache), StatsFixes.load(), TypeLines.load())
    descriptions = WikipediaDescriptions(args.cache, lock_path=args.definition / "wikipedia.lock.json")
    overrides = load_overrides(args.definition / "overrides.json")
    results = [
        SpeciesResult(entry=entry, photos=[], gap=False, description=describe(entry, Overrides.from_mapping(overrides.get(entry.scientific_name, {})), descriptions))
        for entry in species
    ]
    sheets = fact_sheets(results, overrides, joined, descriptions)
    writer = _lore_writer(args, definition)
    try:
        written = writer.write([(r.entry.id, r.entry.common_name, r.entry.scientific_name) for r in results], sheets)
    except (MissingAPIKey, LoreAPIError, LoreRefused, InvalidLore) as error:
        logging.getLogger("packbuilder").error("lore stopped: %s", error)
        return 2
    sheet = review_sheet(writer.lock, args.lore_review or _lore_review_path(definition.id), definition.name, [entry.id for entry in definition.species])
    print(f"{len(written)} of {len(species)} species have lore ({writer.requests} requests); review file {sheet}", file=sys.stderr)
    return 0


def _lore_review_path(pack_id: str) -> Path:
    return Path(__file__).resolve().parents[3] / "build" / "lore" / pack_id / "review.md"


def _lore_review(args: argparse.Namespace) -> int:
    from collections import Counter

    from packbuilder.lore import APPROVED, LOCK_FILE, PENDING, REJECTED, LoreLock, review, review_sheet

    definition = PackDefinition.load(args.definition / "pack.json")
    lock = LoreLock.load(args.definition / LOCK_FILE)
    if not lock.species:
        print(f"{lock.path} has no lore yet: build the pack first", file=sys.stderr)
        return 1
    try:
        review(lock, approve=args.approve, reject=args.reject, approve_all=args.approve_all, why=args.why)
    except KeyError as error:
        print(error.args[0], file=sys.stderr)
        return 1
    sheet = review_sheet(lock, args.sheet or _lore_review_path(definition.id), definition.name, [entry.id for entry in definition.species])
    counts = Counter(entry["review"] for entry in lock.species.values())
    print(f"{lock.path}: " + ", ".join(f"{counts[state]} {state}" for state in (APPROVED, PENDING, REJECTED)) + f"; review file {sheet}", file=sys.stderr)
    return 0


def _art_review(args: argparse.Namespace) -> int:
    from collections import Counter

    from packbuilder.pack_art import APPROVED, GAP, LOCK_FILE, PENDING, REJECTED, ArtLock, review

    lock = ArtLock.load(args.definition / LOCK_FILE)
    if not lock.species:
        print(f"{lock.path} has no pack art yet: build the pack first", file=sys.stderr)
        return 1
    try:
        review(lock, approve=args.approve, reject=args.reject, gap=args.gap, approve_all=args.approve_all, why=args.why)
    except KeyError as error:
        print(error.args[0], file=sys.stderr)
        return 1
    counts = Counter(entry["review"] for entry in lock.species.values())
    print(f"{lock.path}: " + ", ".join(f"{counts[state]} {state}" for state in (APPROVED, PENDING, REJECTED, GAP)), file=sys.stderr)
    unchecked = [entry["common_name"] for entry in lock.species.values() if entry["review"] == PENDING]
    if unchecked:
        print(f"still pending (from text or not faithful, approve by name): {', '.join(unchecked)}", file=sys.stderr)
    return 0


def _set(args: argparse.Namespace) -> int:
    from packbuilder.sets import DEFAULT_TOLERANCE_KM, PublicBoundaries, Taxonomy, build_set, dump_set, polygon_area_km2

    definition = PackDefinition.load(args.definition / "pack.json")
    tolerance = args.tolerance_km if args.tolerance_km is not None else DEFAULT_TOLERANCE_KM
    document = build_set(definition, args.definition, PublicBoundaries(args.cache), Taxonomy.load(args.cache), tolerance_km=tolerance)
    text = dump_set(document)
    (args.definition / "set.json").write_text(text, encoding="utf-8")
    for region in document["regions"]:
        points = sum(len(ring) for polygon in region["polygons"] for ring in polygon)
        area = sum(polygon_area_km2(polygon) for polygon in region["polygons"])
        print(f"{region['name']}: {len(region['polygons'])} polygons, {points} points, {area:,.0f} km²", file=sys.stderr)
    print(f"wrote {args.definition / 'set.json'}: {len(document['species'])} species, {len(text):,} bytes", file=sys.stderr)
    return 0


def _index(args: argparse.Namespace) -> int:
    from packbuilder.index import write_index

    repo_root = Path(__file__).resolve().parents[3]
    index = write_index(repo_root / "packs" / "manifest.json", repo_root / "packbuilder" / "packs", args.out, args.repo)
    print(f"wrote {args.out} with {len(index['packs'])} packs", file=sys.stderr)
    return 0


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


def _calibrate_rarity(args: argparse.Namespace) -> int:
    import json

    import onnxruntime

    from packbuilder.rarity import GRID_SIZE, Region, calibration, readings

    repo = Path(__file__).resolve().parents[3]
    model = "BirdNET+_Geomodel_V3.0.4_Global_14K_FP16.onnx"
    session = onnxruntime.InferenceSession(str(repo / "models" / model))
    labels_file = repo / "models" / "BirdNET+_Geomodel_V3.0.4_Global_14K_Labels.txt"
    labels = [line.split("\t")[1] for line in labels_file.read_text(encoding="utf-8").splitlines() if line]
    definitions = [PackDefinition.load(folder / "pack.json") for folder in sorted((repo / "packbuilder" / "packs").iterdir())]
    regions = [Region(d.bounding_box, [s.scientific_name for s in d.species]) for d in definitions]
    values, unknown = readings(lambda inputs: session.run(["probabilities"], {"input": inputs})[0], labels, regions)
    document = calibration(values, version=args.version, geomodel=model, packs=[d.id for d in definitions], grid_size=GRID_SIZE, unknown=unknown)
    out = args.out or repo / "BirdJournal" / "BirdJournalKit" / "Sources" / "Identification" / "RarityCalibration.json"
    out.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    print(f"calibration {args.version}: {document['thresholds']} from {document['readings']} readings; geomodel lacks {document['unknown_species']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
