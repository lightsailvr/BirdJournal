"""The fact sheet (issue #56, CONTEXT.md "Fact sheet"): the sourced facts a pack holds for a species. Lore and captions
may state nothing that is not on it.

A species' sheet is up to `WIKIPEDIA_FACTS` sentences of its English Wikipedia article at the pinned revision (the
description's source, CC BY-SA 4.0) and then its stats told as short sentences (from the datasets of `stats.py`, each
credited to the dataset that gave it). Both are picked by rule, so a rebuild from the cached page gives the same sheet:

- the article's first sentence names the bird; then sentences about how it lives (feeding, nesting, voice, movement)
  come first, then where it lives, then neutral ones (a range, a date), and naming and classification last; within each tier the sentences are
  taken from the sections in a fixed order of kinds (the lead, behaviour and diet, breeding, voice, people, names,
  range, status, then appearance), the first of each kind, then the second, so one long section never fills the sheet,
  at most two from one kind besides the lead, and a sentence that repeats one already taken is left out;
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
PER_KIND = 2
"""Sentences one kind of section may give besides the lead's (three songs crowd out where the bird lives)."""
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
    """The species' facts: its article's first (`article` is the extract and its revision link), then its stats. The
    article's come first because they are the richer: a dataset's category ("rock", "cup") is coarse beside "always
    near water" and "cemented in its place with mud"."""
    drafted = [(text, article[1]) for text in wikipedia_facts(article[0])] if article is not None else []
    drafted += stats_facts(joined) if joined else []
    return [Fact(id=f"f{number}", text=text, source=source) for number, (text, source) in enumerate(drafted, start=1)]


BEHAVIOUR = re.compile(
    r"\b(nest\w*|mud|eggs?|court\w*|display\w*|feed\w*|eats?|eating|diet|forag\w*|hunt\w*|prey|insect\w*|seeds?|fruit\w*|"
    r"nectar|fish\w*|catch\w*|caught|dives?|diving|swim\w*|wade\w*|perch\w*|sally\w*|hover\w*|flock\w*|roost\w*|tail-\w+|"
    r"wag\w*|bob\w*|pump\w*|songs?|sings?|calls?|voice|territor\w*|mates?|young|chicks?|fledg\w*|cache\w*|mimic\w*)\b",
    re.IGNORECASE,
)
"""Words of how the bird lives: how it feeds, builds, raises young, moves and sounds."""
HABITAT_WORDS = re.compile(
    r"\b(water|streams?|ponds?|rivers?|lakes?|marsh\w*|shores?|coasts?|cliffs?|bridges?|forests?|woodlands?|deserts?|"
    r"grasslands?|scrub\w*|cities|towns?|gardens?|parks?|fountains?|feeders?)\b",
    re.IGNORECASE,
)
"""Words of the places the bird lives in."""
TAXONOMY = re.compile(
    r"\b(genus|genera|subspecies|subfamily|taxon\w*|phylogen\w*|clade|described|classified|binomial|specific (name|epithet)|"
    r"order|families|species of birds|sister|lineage|synonym\w*|mitochondrial|genetic\w*|DNA)\b",
    re.IGNORECASE,
)
"""Words of naming and classification, which tell a reader little about the bird itself."""


def _richness(sentence: str) -> int:
    """2 for a sentence about how the bird lives, 1 about where, -1 about its classification, else 0 (a range, a date)."""
    if TAXONOMY.search(sentence):
        return -1
    if BEHAVIOUR.search(sentence):
        return 2
    return 1 if HABITAT_WORDS.search(sentence) else 0


def _content_words(sentence: str) -> set[str]:
    return {word for word in re.findall(r"[a-z]+", sentence.lower()) if len(word) > 3}


def _repeats(sentence: str, taken: list[str]) -> bool:
    """Whether the sentence says much the same as one already taken: most of its longer words are in it."""
    words = _content_words(sentence)
    return any(len(words & _content_words(other)) * 2 > min(len(words), len(_content_words(other))) for other in taken)


def wikipedia_facts(extract: str, limit: int = WIKIPEDIA_FACTS) -> list[str]:
    """Up to `limit` sentences of the article that stand alone (see the module): the lead's first, which names the
    bird, then sentences about how it lives, where, neutral ones and classification last, each tier taken across the kinds
    of section in turn so one long section never fills the sheet, leaving out a sentence that repeats one taken."""
    parts = headed_parts(extract)
    pools = []
    for kind in SECTION_KINDS:
        names = [name for name in parts if (name == "" if kind == ("",) else any(word in name.lower() for word in kind if word))]
        pools.append([s for name in names for s in sentences(parts[name]) if _stands_alone(s)])
    taken: list[str] = pools[0][:1]
    given = [0] * len(pools)
    for tier in (2, 1, 0, -1):
        tiered = [[s for s in pool if _richness(s) == tier] for pool in pools]
        depth = 0
        while len(taken) < limit and any(depth < len(pool) for pool in tiered):
            for kind, pool in enumerate(tiered):
                if depth >= len(pool) or len(taken) >= limit or (kind > 0 and given[kind] >= PER_KIND):
                    continue
                if pool[depth] not in taken and not _repeats(pool[depth], taken):
                    taken.append(pool[depth])
                    given[kind] += 1
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
        facts += _stats_sentences(stats, borrowed=joined.borrowed)
    if (threat := _threat_sentence(joined.threat)) is not None:
        facts.append((threat, "birdbase"))
    return facts


def _stats_sentences(stats: SpeciesStats, borrowed: bool = False) -> list[tuple[str, str]]:
    """A borrowed AVONET row (a wider species before a split) tells no habitat or migration: those vary across the
    wider species' range (AVONET rates the House Wren complex resident; the Northern House Wren migrates). Mass, diet
    and lifestyle are kept, as near enough for birds that were one species."""
    facts = []
    if stats.wingspan_cm is not None:
        span = f"about {_number(stats.wingspan_cm)} cm"
        facts.append((f"Its wingspan is estimated at {span} from its wing length." if stats.wingspan_predicted else f"Its wingspan is {span}.", "wingspan"))
    if stats.mass_g is not None:
        facts.append((f"It weighs about {_weight(stats.mass_g)}.", "avonet"))
    if stats.diet in DIET:
        facts.append((DIET[stats.diet], "avonet"))
    if stats.habitat in HABITAT and not borrowed:
        facts.append((f"It lives mostly in {HABITAT[stats.habitat]}.", "avonet"))
    if stats.migration in MIGRATION and not borrowed:
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
