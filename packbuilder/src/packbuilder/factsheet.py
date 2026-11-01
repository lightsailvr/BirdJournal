"""The fact sheet (issue #56, CONTEXT.md "Fact sheet"): the sourced facts a pack holds for a species. Lore and captions
may state nothing that is not on it.

A species' sheet is its stats told as short sentences (from the datasets of `stats.py`, each credited to the dataset
that gave it) and then up to `WIKIPEDIA_FACTS` sentences of its English Wikipedia article at the pinned revision (the
description's source, CC BY-SA 4.0). Both are picked by rule, so a rebuild from the cached page gives the same sheet:

- the article's sentences are taken from its sections in a fixed order of kinds (the lead, behaviour and diet,
  breeding, voice, people, names, range, status, then appearance), the first fitting sentence of each kind, then the
  second, until the sheet is full, so one long section never fills it;
- a sentence fits when it stands alone: whole, 6 to 32 words, no measurements (the stats carry the numbers) and not
  opening on a word that leans on the sentence before ("This", "However", "Both").

Each fact has an id (`f1`, `f2`, ...) the lore cites, in sheet order.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from packbuilder.descriptions import HEADING, MEASUREMENT, sentences, words
from packbuilder.stats import JoinedSpecies, SpeciesStats, Threat

WIKIPEDIA_FACTS = 8
"""The spec's "up to about eight short facts" from the article, on top of the stats."""
FACT_WORDS = (6, 32)

SECTION_KINDS: tuple[tuple[str, ...], ...] = (
    ("",),
    ("behavio", "ecology", "diet", "feeding", "food", "forag", "predat"),
    ("breeding", "reproduction", "nesting", "life cycle"),
    ("call", "song", "voice", "vocal", "sound"),
    ("culture", "human", "state bird", "aviculture", "in art", "mytholog", "folklore"),
    ("taxonomy", "etymology", "systematics", "evolution", "name"),
    ("distribution", "habitat", "range", "migration"),
    ("status", "conservation", "threat", "population", "survival"),
    ("description", "identification", "appearance"),
)
"""Which top-level sections each kind takes, by a word of the heading, in the order the sheet takes them. The lead is
the article's first section (""); references, galleries and links match no kind."""

LEANING = re.compile(
    r"^(this|these|that|those|such|however|also|both|another|other|others|in addition|additionally|furthermore|moreover|"
    r"similarly|likewise|thus|therefore|meanwhile|instead|here|there|then|the latter|the former|it also|they also|"
    r"some|many|most)\b",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Fact:
    id: str
    text: str
    source: str
    """The Wikipedia revision as a permanent link, or the dataset's key ("avonet", "birdbase", "wingspan")."""

    def as_dict(self) -> dict:
        return {"id": self.id, "text": self.text, "source": self.source}

    @classmethod
    def from_dict(cls, data: dict) -> "Fact":
        return cls(id=data["id"], text=data["text"], source=data["source"])


def fact_sheet(joined: JoinedSpecies | None, article: tuple[str, str] | None) -> list[Fact]:
    """The species' facts: its stats, then its article's (`article` is the extract and its revision link)."""
    drafted = stats_facts(joined) if joined else []
    if article is not None:
        drafted += [(text, article[1]) for text in wikipedia_facts(article[0])]
    return [Fact(id=f"f{number}", text=text, source=source) for number, (text, source) in enumerate(drafted, start=1)]


def wikipedia_facts(extract: str, limit: int = WIKIPEDIA_FACTS) -> list[str]:
    """Up to `limit` sentences of the article that stand alone, taken across its kinds of section (see the module)."""
    parts = headed_parts(extract)
    pools = []
    for kind in SECTION_KINDS:
        names = [name for name in parts if (name == "" if kind == ("",) else any(word in name.lower() for word in kind if word))]
        pools.append([s for name in names for s in sentences(parts[name]) if _stands_alone(s)])
    taken: list[str] = []
    depth = 0
    while len(taken) < limit and any(depth < len(pool) for pool in pools):
        for pool in pools:
            if depth < len(pool) and pool[depth] not in taken and len(taken) < limit:
                taken.append(pool[depth])
        depth += 1
    return taken


def headed_parts(extract: str) -> dict[str, str]:
    """The extract split at every heading, subsections too (a Breeding subsection under Behaviour is its own kind):
    the lead under "", then each part's own text under its heading, same-named parts joined."""
    parts: dict[str, str] = {}
    name, start = "", 0
    for match in HEADING.finditer(extract):
        parts[name] = (parts.get(name, "") + " " + extract[start:match.start()]).strip()
        name, start = match.group(2), match.end()
    parts[name] = (parts.get(name, "") + " " + extract[start:]).strip()
    return parts


def _stands_alone(sentence: str) -> bool:
    low, high = FACT_WORDS
    return (
        low <= words(sentence) <= high
        and sentence[0].isupper()
        and sentence.endswith((".", "!"))
        and not MEASUREMENT.search(sentence)
        and not LEANING.match(sentence)
        and "citation needed" not in sentence.lower()
        and not re.search(r"[\[\]{}=|]|[,;:]\.$|\s\.$", sentence)
    )


DIET = {
    "frugivore": "It feeds mostly on fruit.",
    "granivore": "It feeds mostly on seeds.",
    "nectarivore": "It feeds mostly on nectar.",
    "invertivore": "It feeds mostly on insects and other invertebrates.",
    "vertivore": "It feeds mostly on other vertebrates.",
    "scavenger": "It feeds mostly by scavenging.",
    "omnivore": "It eats a wide mix of foods.",
    "herbivore_terrestrial": "It feeds mostly on plants.",
    "herbivore_aquatic": "It feeds mostly on water plants.",
    "aquatic_predator": "It feeds mostly on fish and other animals it catches in water.",
}
HABITAT = {
    "desert": "deserts", "grassland": "grassland", "shrubland": "shrubland", "woodland": "woodland", "forest": "forest",
    "wetland": "wetlands", "riverine": "rivers and streams", "coastal": "coasts", "marine": "the open sea", "rock": "rocky places",
    "human_modified": "towns, farms and other places people have changed",
}
MIGRATION = {
    "resident": "It stays in its range all year.",
    "partial_migrant": "Some of its populations migrate and others stay all year.",
    "migrant": "It migrates between breeding and wintering grounds.",
}
LIFESTYLE = {
    "aerial": "It spends most of its time in the air.",
    "terrestrial": "It spends most of its time on the ground.",
    "insessorial": "It spends most of its time perched in trees and shrubs.",
    "aquatic": "It spends most of its time on or in water.",
    "generalist": "It forages in the air, on the ground and in the trees alike.",
}
NEST = {
    "burrow": "a burrow", "cup": "a cup", "crevice": "a crevice", "cavity": "a cavity", "dome": "a domed nest", "platform": "a platform",
    "pendant": "a hanging nest", "saucer": "a saucer", "scrape": "a scrape on the ground", "sphere": "a ball-shaped nest",
    "mound": "a mound", "half_cup": "a half cup",
}
IUCN = {"LC": "Least Concern", "NT": "Near Threatened", "VU": "Vulnerable", "EN": "Endangered", "CR": "Critically Endangered"}


def stats_facts(joined: JoinedSpecies) -> list[tuple[str, str]]:
    """The species' stats as (sentence, dataset) pairs, leaving out what the datasets lack."""
    facts: list[tuple[str, str]] = []
    if (stats := joined.stats) is not None:
        facts += _stats_sentences(stats)
    if (threat := _threat_sentence(joined.threat)) is not None:
        facts.append((threat, "birdbase"))
    return facts


def _stats_sentences(stats: SpeciesStats) -> list[tuple[str, str]]:
    facts = []
    if stats.wingspan_cm is not None:
        span = f"about {_number(stats.wingspan_cm)} cm"
        facts.append((f"Its wingspan is estimated at {span} from its wing length." if stats.wingspan_predicted else f"Its wingspan is {span}.", "wingspan"))
    if stats.mass_g is not None:
        facts.append((f"It weighs about {_weight(stats.mass_g)}.", "avonet"))
    if stats.diet in DIET:
        facts.append((DIET[stats.diet], "avonet"))
    if stats.habitat in HABITAT:
        facts.append((f"It lives mostly in {HABITAT[stats.habitat]}.", "avonet"))
    if stats.migration in MIGRATION:
        facts.append((MIGRATION[stats.migration], "avonet"))
    if stats.lifestyle in LIFESTYLE:
        facts.append((LIFESTYLE[stats.lifestyle], "avonet"))
    nests = [NEST[nest] for nest in stats.nest if nest in NEST]
    if "other_nest" in stats.nest:
        facts.append(("It lays its eggs in other birds' nests.", "birdbase"))
    elif "no_nest" in stats.nest:
        facts.append(("It lays its eggs without building a nest.", "birdbase"))
    elif nests:
        facts.append((f"It nests in {_listed(nests)}.", "birdbase"))
    if stats.clutch_min is not None or stats.clutch_max is not None:
        low, high = stats.clutch_min or stats.clutch_max, stats.clutch_max or stats.clutch_min
        eggs = f"{_number(low)}" if low == high else f"{_number(low)} to {_number(high)}"
        facts.append((f"It lays {eggs} {'egg' if eggs == '1' else 'eggs'} in a clutch.", "birdbase"))
    return facts


def _threat_sentence(threat: Threat) -> str | None:
    name = IUCN.get(threat.iucn_category or "")
    return f"The IUCN Red List rates it {name}." if name else None


def _number(value: float) -> str:
    return str(int(round(value))) if value >= 10 or float(value).is_integer() else f"{value:.1f}".rstrip("0").rstrip(".")


def _weight(grams: float) -> str:
    return f"{_number(grams / 1000)} kg" if grams >= 1000 else f"{_number(grams)} g"


def _listed(items: list[str]) -> str:
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + f" or {items[-1]}"
