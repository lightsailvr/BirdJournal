"""`packbuilder draft-continental` (issue #211, spec #206): a species list for a continent-wide pack, drafted from the
BirdNET geomodel instead of observation counts, which a continent's worth of places would bury under its big cities.

The geomodel is read for every bird at each city of a committed sample (`packbuilder/cities/<name>.json`) and all 48
of BirdNET's weeks. The method, and the choices it leaves, which are made here once so a rerun gives the same list:

- **Present** means an occurrence at or above the identification floor (0.03, `rarity.FLOOR`): the reading under which
  the app does not admit a bird it hears at a place. Readings below it count for nothing anywhere in the draft.
- **Coast-to-coast birds come first**: present for two months or more (8 of the 48 weeks, not necessarily in a row) in
  at least 90 % of the cities. They are taken in the order of their mean occurrence over every city and week.
- **Coverage** of a city is the share of its occurrence weight the list's birds hold. A bird's weight in a city is
  the sum of its occurrence over the weeks it is present; the city's is the sum over all the geomodel's birds, with
  or without an acoustic class, since a birder meets those too. The geomodel's other classes (insects, frogs,
  mammals) are no part of it.
- **Then one bird at a time**, each the one that most lifts the cities furthest behind: the bird whose coverage most
  reduces the sum over the cities of the squared shortfall, (1 − coverage)². A point of coverage therefore counts in
  proportion to how far its city is behind: twice as much in a city at 60 % as in one at 80 %.
- **Ties** go to the higher mean occurrence, then to the scientific name.
- **Names** are the BirdNET+ label file's. A geomodel class is the label of the same binomial; failing that, the one
  label of the same common name (logged, for a person to check); failing that it has no acoustic class and is left
  out. Where the two files split a bird differently the sample file says which label the class means there.
- **By hand**: an added bird is always in, and takes one of the places asked for; an excluded bird is never in. Both
  are named by their label's scientific name, and a name that is not a label stops the draft.
"""

from __future__ import annotations

import json
import math
from collections.abc import Callable, Mapping, Sequence, Set
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np

from packbuilder.rarity import FLOOR, WEEKS
from packbuilder.species_list import Ranked, wikipedia_guess

if TYPE_CHECKING:
    from packbuilder.sets import Taxonomy

PRESENT_WEEKS = 8
"""Two months of BirdNET's four-week months."""

MISSED = 5
"""How many of the birds a city misses the draft names."""

COAST_TO_COAST = 0.9
"""The share of the cities a bird is present in, for `PRESENT_WEEKS` or more, to be taken before any other."""


@dataclass(frozen=True)
class City:
    name: str
    region: str
    """Its state or province."""
    latitude: float
    longitude: float


@dataclass(frozen=True)
class Sample:
    """The committed file a draft is made from (`packbuilder/cities/<name>.json`)."""

    cities: tuple[City, ...]
    geomodel_names: dict[str, str]
    """A geomodel class's scientific name → the BirdNET+ label it means in these cities."""


def load_sample(path: Path) -> Sample:
    data = json.loads(path.read_text(encoding="utf-8"))
    return Sample(
        cities=tuple(
            City(name=c["name"], region=c["region"], latitude=float(c["latitude"]), longitude=float(c["longitude"]))
            for c in data["cities"]
        ),
        geomodel_names=dict(data.get("geomodel_names", {})),
    )


@dataclass(frozen=True)
class GeoLabel:
    """One class of the geomodel, as its label file has it."""

    code: str
    scientific_name: str
    common_name: str


GEOMODEL = "BirdNET+_Geomodel_V3.0.4_Global_14K_FP16.onnx"
GEOMODEL_LABELS = "BirdNET+_Geomodel_V3.0.4_Global_14K_Labels.txt"


def read_geomodel(models_dir: Path) -> tuple[Callable[[np.ndarray], np.ndarray], list[GeoLabel]]:
    """The pinned geomodel as `draft` takes it: its occurrence function and its labels, one per output class."""
    import onnxruntime

    session = onnxruntime.InferenceSession(str(models_dir / GEOMODEL))
    lines = (models_dir / GEOMODEL_LABELS).read_text(encoding="utf-8").splitlines()
    labels = [GeoLabel(*line.split("\t")) for line in lines if line]
    return (lambda inputs: session.run(["probabilities"], {"input": inputs})[0]), labels


@dataclass(frozen=True)
class Pick:
    """One bird, on the list or next to it."""

    scientific_name: str
    common_name: str
    how: str
    """Why it is in: "coast to coast", "added" (by hand) or "lift"; "left out" for a bird a city misses."""
    cities: int = 0
    """The cities it is present in for `PRESENT_WEEKS` or more."""
    mean_occurrence: float = 0.0
    """Over every city and week."""
    geomodel_common_name: str = ""
    """What the geomodel calls its class, which is not always the label file's name for it; empty without a class."""


@dataclass
class ContinentalDraft:
    picks: list[Pick]
    """In the order taken."""
    coverage: list[float]
    """Per city, in the cities' order: the share of the city's occurrence weight the list's birds hold."""
    missed: list[list[tuple[Pick, float]]]
    """Per city, the `MISSED` birds off the list that are most met there, each with the coverage it would add."""
    runners_up: list[Pick]
    """The birds the method would take next, in its order."""
    renamed: list[tuple[str, str]]
    """(the geomodel's binomial, the label file's) for each bird of the list or next in line that was matched by its
    common name, for a person to check."""
    no_acoustic_class: list[GeoLabel]
    """The geomodel's birds present in some city that the label file does not name, the most met first."""


def draft(
    occurrence: Callable[[np.ndarray], np.ndarray], geomodel: Sequence[GeoLabel], labels: Mapping[str, str],
    cities: Sequence[City], count: int, add: Sequence[str] = (), exclude: Set[str] = frozenset(), geomodel_names: Mapping[str, str] | None = None,
    runners_up: int = 0,
) -> ContinentalDraft:
    """`count` birds for the cities: the coast-to-coast birds, the highest mean occurrence first, then one bird at a
    time, each the one that most lifts the cities furthest behind (the module's docstring has the method).

    `occurrence` maps rows of (latitude, longitude, week) to one row of probabilities per input, one column per
    geomodel label, as `rarity.readings` takes it; `labels` is the BirdNET+ label file, scientific name → common name.
    `geomodel_names` gives the label a geomodel class means in these cities where the two files split a bird
    differently (the geomodel's whimbrel is the label file's Hudsonian Whimbrel in North America). A bird in
    `exclude`, by its label's scientific name, is never taken; it still counts as met in each city's coverage. A
    bird in `add` is always taken, in a place a coast-to-coast bird would otherwise have when the list is that short.
    `runners_up` asks for that many more, the birds the method would take next, kept apart from the list.
    """
    for hand in [*add, *exclude]:
        if hand not in labels:
            raise ValueError(f"{hand} is not a BirdNET+ label: a bird is added or excluded by its label's scientific name")
    if both := sorted(set(add) & set(exclude)):
        raise ValueError(f"both added and excluded: {', '.join(both)}")

    inputs = np.array([[city.latitude, city.longitude, week] for city in cities for week in WEEKS], dtype=np.float32)
    readings = np.asarray(occurrence(inputs), dtype=np.float64).reshape(len(cities), len(WEEKS), len(geomodel))
    # The geomodel's birds carry eBird codes; its insects, frogs and mammals carry iNaturalist taxon numbers.
    readings[:, :, [k for k, label in enumerate(geomodel) if label.code.isdigit()]] = 0.0
    weight = np.where(readings >= FLOOR, readings, 0.0).sum(axis=1)
    """City × class: the bird's occurrence over the weeks it is present."""
    city_weight = weight.sum(axis=1)

    result = ContinentalDraft(picks=[], coverage=[], missed=[], runners_up=[], renamed=[], no_acoustic_class=[])
    by_common: dict[str, list[str]] = {}
    for scientific_name, common_name in labels.items():
        by_common.setdefault(common_name.lower(), []).append(scientific_name)
    classes: dict[str, int] = {}
    """BirdNET+ label → its geomodel class, for the birds met in some city."""
    for k in sorted(np.flatnonzero(weight.sum(axis=0) > 0), key=lambda k: -weight[:, k].sum()):
        label = geomodel[k]
        same_bird = by_common.get(label.common_name.lower(), [])
        if label.scientific_name in (geomodel_names or {}):
            name = geomodel_names[label.scientific_name]
            if name not in labels:
                raise ValueError(f"{label.scientific_name} is named {name}, which is not a BirdNET+ label")
        elif label.scientific_name in labels:
            name = label.scientific_name
        elif len(same_bird) == 1:
            name = same_bird[0]
            result.renamed.append((label.scientific_name, name))
        else:
            result.no_acoustic_class.append(label)
            continue
        # Two classes under one label: the more met of them stands for it.
        classes.setdefault(name, int(k))

    birds = sorted((set(classes) | set(add)) - set(exclude))
    columns = [classes.get(name) for name in birds]
    known = [k is not None for k in columns]
    """A bird added by hand may have no class: it is met nowhere as far as the geomodel says."""
    share = np.zeros((len(cities), len(birds)))
    share[:, known] = weight[:, [k for k in columns if k is not None]] / city_weight[:, None]
    """City × bird: the bird's share of the city's occurrence weight, which is the coverage it adds there."""
    mean = np.zeros(len(birds))
    mean[known] = readings.mean(axis=(0, 1))[[k for k in columns if k is not None]]
    cities_present = np.zeros(len(birds), dtype=int)
    cities_present[known] = ((readings >= FLOOR).sum(axis=1) >= PRESENT_WEEKS).sum(axis=0)[[k for k in columns if k is not None]]

    by_mean = sorted(range(len(birds)), key=lambda b: (-mean[b], birds[b]))
    added = [birds.index(name) for name in dict.fromkeys(add)]
    enough_cities = math.ceil(round(COAST_TO_COAST * len(cities), 6))
    coast_to_coast = [b for b in by_mean if cities_present[b] >= enough_cities and b not in added]
    taken = coast_to_coast[:max(count - len(added), 0)]
    how = ["coast to coast"] * len(taken) + ["added"] * len(added)
    taken += added
    coverage = share[:, taken].sum(axis=1)
    rest = [b for b in by_mean if b not in taken]
    while len(taken) < count + runners_up and rest:
        # The fall in the cities' squared shortfall: a point of coverage counts for more the further behind its city.
        # Among equals the first wins, which is the higher mean occurrence, then the name.
        shortfall = 1.0 - coverage
        lift = (shortfall[:, None] ** 2 - (shortfall[:, None] - share[:, rest]) ** 2).sum(axis=0)
        best = rest.pop(int(np.argmax(lift)))
        taken.append(best)
        how.append("lift")
        coverage = coverage + share[:, best]

    def pick(b: int, why: str) -> Pick:
        return Pick(
            scientific_name=birds[b], common_name=labels[birds[b]], how=why, cities=int(cities_present[b]), mean_occurrence=float(mean[b]),
            geomodel_common_name=geomodel[columns[b]].common_name if known[b] else "",
        )

    picks = [pick(b, why) for b, why in zip(taken, how)]
    result.picks, result.runners_up = picks[:count], picks[count:]
    result.renamed = [(theirs, ours) for theirs, ours in result.renamed if ours in {birds[b] for b in taken}]
    result.coverage = [float(value) for value in share[:, taken[:count]].sum(axis=1)]
    off_the_list = [b for b in range(len(birds)) if b not in taken[:count]]
    for city in range(len(cities)):
        most_met = sorted(off_the_list, key=lambda b: (-share[city, b], birds[b]))[:MISSED]
        result.missed.append([(pick(b, "left out"), float(share[city, b])) for b in most_met if share[city, b] > 0])
    return result


@dataclass
class Entries:
    species: list[dict]
    """The `species` array of a `pack.json`, in the order the birds were taken."""
    new: list[str]
    """The birds no committed pack definition lists, by scientific name."""
    unresolved: list[str]
    """The new birds iNaturalist has no species for under the label's binomial: their entries lack a taxon."""


def species_entries(picks: Sequence[Pick], known: Mapping[str, dict], taxon: Callable[[str], Ranked]) -> Entries:
    """Each bird's pack definition entry: a committed pack's whole (`known`, by scientific name), as `packbuilder
    draft` reuses it, or for a bird new to the project the label's names with iNaturalist's taxon and Wikipedia
    article (`taxon` is `species_list.named_taxon`, which raises `LookupError`)."""
    entries = Entries(species=[], new=[], unresolved=[])
    for pick in picks:
        if pick.scientific_name in known:
            entries.species.append(dict(known[pick.scientific_name]))
            continue
        entries.new.append(pick.scientific_name)
        try:
            found = taxon(pick.scientific_name)
        except LookupError:
            found = None
            entries.unresolved.append(pick.scientific_name)
        wikipedia_url = (found and found.wikipedia_url) or wikipedia_guess(pick.common_name)
        entries.species.append({
            "scientific_name": pick.scientific_name,
            "common_name": pick.common_name,
            "inat_taxon_id": found.taxon_id if found else None,
            "wikipedia_url": wikipedia_url.replace("http://", "https://", 1),
        })
    return entries


def report(result: ContinentalDraft, cities: Sequence[City], entries: Entries, taxonomy: Taxonomy) -> str:
    """The draft as Markdown for the person approving the list: the birds in taxonomic order (the collector numbers
    the set would have), each city's coverage with what it misses, the birds new to the project and the next in line."""
    def named(pick: Pick) -> str:
        return f"{pick.common_name} (*{pick.scientific_name}*)"

    def percent(share: float) -> str:
        return f"{100 * share:.1f} %"

    def place(city: City) -> str:
        return f"{city.name}, {city.region}"

    how = [pick.how for pick in result.picks]
    weakest_first = sorted(range(len(cities)), key=lambda c: (result.coverage[c], c))
    weakest = weakest_first[0]
    new = set(entries.new)
    lines = [
        f"**{len(result.picks)} birds** from {len(cities)} cities: {how.count('coast to coast')} coast to coast, "
        f"{how.count('added')} added by hand, {how.count('lift')} taken to lift the cities furthest behind.",
        "",
        f"**Coverage** (the share of a city's occurrence weight that the list's birds hold): median {percent(float(np.median(result.coverage)))}, "
        f"mean {percent(float(np.mean(result.coverage)))}, weakest {place(cities[weakest])} at {percent(result.coverage[weakest])}.",
        "",
        f"**{len(result.picks) - len(new)} already in a pack definition, {len(new)} new to the project.**",
        "",
        f"### The {len(result.picks)} in taxonomic order",
        "",
        f"The number is the collector number the set would have ({taxonomy.title}). Cities: how many of the {len(cities)} the bird is "
        "present in for two months or more. Mean occurrence: over every city and week.",
        "",
        "| No. | Bird | Scientific name | Taken | Cities | Mean occurrence | |",
        "| --- | --- | --- | --- | ---: | ---: | --- |",
    ]

    def also(pick: Pick) -> str:
        differs = pick.geomodel_common_name and pick.geomodel_common_name != pick.common_name
        return f" (the geomodel's {pick.geomodel_common_name})" if differs else ""

    def sequence(pick: Pick) -> int | None:
        return taxonomy.sequence.get(taxonomy.fixes.get(pick.scientific_name, pick.scientific_name))

    ordered = sorted((pick for pick in result.picks if sequence(pick) is not None), key=sequence)
    unplaced = [pick for pick in result.picks if sequence(pick) is None]
    for number, pick in [*enumerate(ordered, start=1), *((None, pick) for pick in unplaced)]:
        lines.append(
            f"| {f'{number:03d}' if number else '–'} | {pick.common_name}{also(pick)} | *{pick.scientific_name}* | {pick.how} | {pick.cities} "
            f"| {pick.mean_occurrence:.2f} | {'new' if pick.scientific_name in new else ''} |"
        )
    if unplaced:
        lines += ["", f"Without a number, not in the {taxonomy.title} under the label's name: {', '.join(map(named, unplaced))}. "
                  "Each needs a `TAXONOMY_FIXES` entry before `packbuilder set` can number the set."]
    lines += ["", "### Coverage by city, weakest first", "", "| City | Coverage | Most met of what the list lacks there |", "| --- | ---: | --- |"]
    for c in weakest_first:
        lacks = ", ".join(f"{pick.common_name} {percent(share)}" for pick, share in result.missed[c])
        lines.append(f"| {place(cities[c])} | {percent(result.coverage[c])} | {lacks} |")
    lines += ["", f"### New to the project ({len(new)})", "", "In no committed pack definition, so their photos, sounds, lore and stats are all new work.", ""]
    lines += [f"- {named(pick)}" for pick in [*ordered, *unplaced] if pick.scientific_name in new]
    if entries.unresolved:
        by_name = {pick.scientific_name: pick for pick in result.picks}
        lines += ["", "Without an iNaturalist taxon (iNaturalist has no species under the label's binomial; a person gives it): "
                  + ", ".join(named(by_name[name]) for name in entries.unresolved) + "."]
    if result.runners_up:
        lines += ["", "### Next in line", "", "The birds the method would take next, in its order: the replacements if a bird is excluded.", ""]
        lines += [f"{i}. {named(pick)}" for i, pick in enumerate(result.runners_up, start=1)]
    if result.renamed:
        lines += ["", "### Taken under another binomial", "", "The geomodel and the label file name these differently; they were matched by common name. Check each.", ""]
        lines += [f"- the geomodel's *{geomodel_name}* as the label file's *{label_name}*" for geomodel_name, label_name in result.renamed]
    if result.no_acoustic_class:
        lines += ["", "### Left out: no acoustic class", "", "Birds the geomodel expects in some sample city that the BirdNET+ label file does not name, the most met first.", ""]
        lines += [f"- {label.common_name} (*{label.scientific_name}*)" for label in result.no_acoustic_class]
    return "\n".join(lines) + "\n"
