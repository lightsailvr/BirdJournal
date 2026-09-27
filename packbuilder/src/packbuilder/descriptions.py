"""Species descriptions derived from Wikipedia (issue #12, spec "Pack builder": Wikipedia summaries for descriptions).

The lens details page has about twenty words for field marks and one short line for size and habitat (DECISIONS.md
"Lens UI"; `LensCardRenderer` cuts anything longer), the phone shows a summary. Each is cut from the article's
plain-text extract by rule, so a rebuild from the cached page gives the same text, and `overrides.json` can replace
any field by hand. Wikipedia text is CC BY-SA 4.0; the pack records the article revision it was taken from.
"""

from __future__ import annotations

import dataclasses
import json
import logging
import re
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Callable
from urllib.parse import unquote, urlparse

from packbuilder.http import session

from packbuilder.definition import SpeciesEntry

log = logging.getLogger(__name__)

FIELD_MARKS_WORDS = 40
"""The lens details page's budget for field marks, shown there in the Display DSL's small text style (issue #32;
`LensCardRenderer.detailsWordBudget` is this plus the name, match rate, size and habitat, credit and button)."""
SUMMARY_WORDS = 60
HABITAT_TERMS = 3

API = "https://en.wikipedia.org/w/api.php"
ARTICLE = "https://en.wikipedia.org/w/index.php"
USER_AGENT = "BirdJournal packbuilder (https://github.com/lightsailvr/BirdJournal)"

DESCRIPTION_SECTIONS = ("Description", "Physical description", "Identification", "Appearance", "Description and identification")
HABITAT_SECTIONS = ("Habitat", "Distribution and habitat", "Habitat and distribution", "Range and habitat", "Distribution", "Ecology", "Distribution and ecology", "Range")

# A sentence about plumage, shape or a part of the bird reads as a field mark; one about measurements does not.
PLUMAGE_WORDS = re.compile(
    r"\b(plumage|feather|black|white|grey|gray|brown|rufous|rusty|red|orange|yellow|green|blue|pink|buff|olive|"
    r"streak|spot|bar|band|patch|stripe|crown|cap|head|face|throat|breast|belly|back|wing|tail|bill|beak|legs?|eye|"
    r"crest|iridescent|glossy|pale|dark|sooty|mottled|barred|streaked|spotted|male|female|adult|juvenile)\w*",
    re.IGNORECASE,
)
MEASUREMENT = re.compile(
    r"\b(\d[\d.,]*\s*(cm|mm|m|g|kg|oz|lb|in|inches|ft|grams?|centimet\w+|millimet\w+)|weigh\w*|wingspan|in length|body mass|measurements?|"
    r"larger than|smaller than|bigger than|dimorphi\w*)\b",
    re.IGNORECASE,
)
LENGTH = re.compile(
    r"(?:between\s+)?(\d+(?:\.\d+)?)(?:\s*(?:–|-|—|to|and)\s*(\d+(?:\.\d+)?))?[\s-]*"
    r"(cm|centimet(?:er|re)s?|mm|millimet(?:er|re)s?|m|in|inches)\b(?!\s*\d)",
    re.IGNORECASE,
)
UNIT_TO_CM = {"cm": 1.0, "centimeter": 1.0, "centimetre": 1.0, "mm": 0.1, "millimeter": 0.1, "millimetre": 0.1, "m": 100.0, "in": 2.54, "inch": 2.54}
# Metres and inches are taken only next to "long" or "length": "2 m up in a shrub" and "1 in 200" are not sizes.
UNITS_NEEDING_CONTEXT = {"m", "in", "inch"}
LENGTH_NEARBY = re.compile(r"\b(long|length|measur\w*|total|tall|stand\w*)\b", re.IGNORECASE)
FEET_BEFORE = re.compile(r"\bft\s*$", re.IGNORECASE)
# "from tip of beak to tip of tail", "bill-to-tail": the whole bird, although it names the bill and the tail.
BILL_TO_TAIL = re.compile(r"(bill|beak|tip)[- ]to[- ](tail|tip)|tip of (the )?(bill|beak) to (the )?tip of (the )?tail|from (bill|beak) to tail|head to tail", re.IGNORECASE)
# A figure in the same clause as one of these is not the body length.
OTHER_MEASURE = re.compile(r"\b(wingspan|wing chord|wings?|tails?|bills?|culmen|tarsus|beaks?|eggs?|nests?|clutch|burrows?|depth|deep|high|feet|legs?|necks?)\b", re.IGNORECASE)
CLAUSE_BOUNDARY = re.compile(r"(?<!\d)[.;,](?!\d)|\band\b|\bwith\b|\bwhile\b")
# Body lengths outside this range are something else (an egg, a nest, a range in metres).
PLAUSIBLE_CM = (7, 200)

HABITAT_VOCABULARY: dict[str, str] = {
    "water": "water", "waters": "water",
    "wetland": "marsh", "wetlands": "marsh", "marsh": "marsh", "marshes": "marsh", "swamp": "marsh", "swamps": "marsh", "bog": "marsh", "bogs": "marsh",
    "lake": "lakes", "lakes": "lakes", "pond": "lakes", "ponds": "lakes", "reservoir": "lakes", "reservoirs": "lakes",
    "river": "rivers", "rivers": "rivers", "stream": "rivers", "streams": "rivers", "creek": "rivers", "creeks": "rivers", "riparian": "rivers",
    "coast": "coast", "coasts": "coast", "coastal": "coast", "shore": "coast", "shores": "coast", "shoreline": "coast", "shorelines": "coast", "beach": "coast", "beaches": "coast",
    "ocean": "ocean", "oceans": "ocean", "sea": "ocean", "seas": "ocean", "offshore": "ocean", "pelagic": "ocean",
    "mudflat": "estuaries", "mudflats": "estuaries", "estuary": "estuaries", "estuaries": "estuaries", "lagoon": "estuaries", "lagoons": "estuaries", "tidal": "estuaries", "saltmarsh": "estuaries",
    "forest": "forest", "forests": "forest", "forested": "forest",
    "woodland": "woodland", "woodlands": "woodland", "woods": "woodland", "wooded": "woodland", "oak": "woodland", "oaks": "woodland",
    "conifer": "mountains", "coniferous": "mountains", "pine": "mountains", "pines": "mountains", "fir": "mountains", "montane": "mountains", "mountain": "mountains", "mountains": "mountains",
    "chaparral": "chaparral",
    "scrub": "scrub", "scrubland": "scrub", "scrublands": "scrub", "shrub": "scrub", "shrubs": "scrub", "shrubland": "scrub", "shrublands": "scrub", "sagebrush": "scrub", "brush": "scrub", "thicket": "scrub", "thickets": "scrub",
    "grassland": "grassland", "grasslands": "grassland", "meadow": "grassland", "meadows": "grassland", "prairie": "grassland", "prairies": "grassland", "field": "grassland", "fields": "grassland",
    "desert": "desert", "deserts": "desert", "arid": "desert",
    "cliff": "cliffs", "cliffs": "cliffs", "canyon": "cliffs", "canyons": "cliffs", "rocky": "cliffs",
    "urban": "urban", "city": "urban", "cities": "urban", "suburban": "urban", "suburbs": "urban", "town": "urban", "towns": "urban", "residential": "urban",
    "park": "parks", "parks": "parks", "garden": "parks", "gardens": "parks", "yard": "parks", "yards": "parks", "backyard": "parks", "backyards": "parks", "feeder": "parks", "feeders": "parks",
    "farmland": "farmland", "agricultural": "farmland", "farm": "farmland", "farms": "farmland", "orchard": "farmland", "orchards": "farmland", "pasture": "farmland", "pastures": "farmland", "cropland": "farmland",
}
WORD = re.compile(r"[a-z]+")
# Phrases whose habitat word is not about habitat.
NOT_HABITAT = re.compile(r"\bsea level\b|\bfield (guides?|marks?|notes?|studies|work)\b|\bcity of\b")
HEADING = re.compile(r"^(=+)\s*(.+?)\s*=+\s*$", re.MULTILINE)
PARENTHETICAL = re.compile(r"\s*\([^()]*\)")
SENTENCE_END = re.compile(r"(?<=[.!?])(?<!\b[A-Z]\.)\s+(?=[A-Z\"'])")
STATEMENT_END = re.compile(r"(?<=[.;!?])(?<!\b[A-Z]\.)\s+")
ABBREVIATIONS = ("e.g.", "i.e.", "c.", "ca.", "cf.", "sp.", "spp.", "subsp.", "var.")


DESCRIPTION_FIELDS = ("summary", "field_marks", "size", "habitat")
"""The text fields, the ones `overrides.json` may replace."""


@dataclass(frozen=True)
class Description:
    summary: str
    field_marks: str
    size: str
    habitat: str
    source: str
    """The article revision the text was cut from, as a permanent link; empty for hand-written text."""

    @classmethod
    def empty(cls) -> "Description":
        return cls(summary="", field_marks="", size="", habitat="", source="")

    def replaced(self, fields: dict[str, str]) -> "Description":
        """This description with the given fields (from `overrides.json`, already limited to `DESCRIPTION_FIELDS`)
        written over; once every field is hand-written nothing is left to credit to the article."""
        source = "" if all(name in fields for name in DESCRIPTION_FIELDS) else self.source
        return dataclasses.replace(self, **fields, source=source)


def sections(extract: str) -> dict[str, str]:
    """The plain-text extract split at its top-level headings: the lead under "", then each section's text (with its
    subsections), in order."""
    parts: dict[str, str] = {}
    current = ""
    start = 0
    for match in HEADING.finditer(extract):
        if len(match.group(1)) == 2:
            parts[current] = parts.get(current, "") + extract[start:match.start()]
            current = match.group(2)
            start = match.end()
        else:
            parts[current] = parts.get(current, "") + extract[start:match.start()]
            start = match.end()
    parts[current] = parts.get(current, "") + extract[start:]
    return {name: text.strip() for name, text in parts.items()}


def sentences(text: str) -> list[str]:
    """Sentences of a passage with the parentheticals (unit conversions, binomials) removed."""
    flat = PARENTHETICAL.sub("", text.replace("\n", " "))
    flat = re.sub(r"\s+", " ", flat).strip()
    out: list[str] = []
    for piece in SENTENCE_END.split(flat):
        piece = piece.strip()
        if not piece:
            continue
        if out and out[-1].split()[-1].lower() in ABBREVIATIONS:
            out[-1] = out[-1] + " " + piece
        else:
            out.append(piece)
    return out


def words(text: str) -> int:
    return len(text.split())


def take_sentences(candidates: list[str], max_words: int) -> str:
    """Whole sentences in order while they fit, skipping ones that do not until the first that does; when no
    sentence fits whole, the first sentence's longest clause that fits (issue #32: text is never cut mid-phrase and
    never ends with an ellipsis); when not even a clause fits, nothing, so the caller can try another source."""
    taken: list[str] = []
    used = 0
    for sentence in candidates:
        count = words(sentence)
        if used + count <= max_words:
            taken.append(sentence)
            used += count
        elif taken:
            break
    if taken:
        return " ".join(taken)
    return clause(candidates[0], max_words) if candidates else ""


CLAUSE_BREAKS = (", ", "; ", ": ", " and ", " but ", " while ", " with ")


def clause(sentence: str, max_words: int) -> str:
    """The longest prefix of a sentence that ends at a clause boundary inside `max_words` words and keeps at least
    half the budget, closed with a full stop; empty when there is none."""
    head = " ".join(sentence.split()[:max_words])
    cut = max(head.rfind(mark) for mark in CLAUSE_BREAKS)
    if cut <= 0 or words(head[:cut]) * 2 < max_words:
        return ""
    return head[:cut].rstrip(",;: ") + "."


def summary(lead: str, max_words: int = SUMMARY_WORDS) -> str:
    return take_sentences(sentences(lead), max_words)


def _first(parts: dict[str, str], names: tuple[str, ...]) -> str | None:
    for name in names:
        if parts.get(name):
            return parts[name]
    for name, text in parts.items():
        if text and any(name.lower().startswith(n.lower()) for n in names):
            return text
    return None


def field_marks(parts: dict[str, str], max_words: int = FIELD_MARKS_WORDS) -> str:
    """The description section's plumage sentences, in order, inside the budget; then the lead's plumage sentences;
    then, when neither has any, sentences that at least are not measurements."""
    section = sentences(_first(parts, DESCRIPTION_SECTIONS) or "")
    lead = sentences(parts.get("", ""))
    for candidates in (section, lead):
        marks = [s for s in candidates if PLUMAGE_WORDS.search(s) and not MEASUREMENT.search(s)]
        if marks and (taken := take_sentences(marks, max_words)):
            return taken
    for candidates in (section, lead):
        plain = [s for s in candidates if not MEASUREMENT.search(s)]
        if plain and (taken := take_sentences(plain, max_words)):
            return taken
    return take_sentences(section or lead, max_words)


def size(parts: dict[str, str]) -> str:
    """The first body length of the description section (else of the whole article) as "16 cm" or "13–15 cm": lengths
    marked "long" or "in length" first, wing and bill measurements skipped, millimetres, metres and inches converted."""
    section = _first(parts, DESCRIPTION_SECTIONS)
    passages = [section] if section else []
    passages.append(" ".join(parts.values()))
    for passage in passages:
        found = _size_in(passage.replace("\n", " "))
        if found:
            return found
    return ""


def _size_in(flat: str) -> str:
    """The body length among the figures of a passage. A figure is "tainted" when a wing, tail, bill or egg word
    precedes it in its sentence or follows it in its clause; a tainted figure counts only when its own clause says
    "long" or "length", and a foot-and-inch remainder ("3 ft 3 in") never does. A clean centimetre or millimetre
    figure marked "long", "length", "tall" or "measures" wins; then the earliest of the rest, where a metre or inch
    figure needs a mark to count at all."""
    best: tuple[int, int, str] | None = None
    for match in LENGTH.finditer(flat):
        unit = match.group(3).lower().rstrip("s")
        if unit == "inche":
            unit = "inch"
        before = _clause_before(flat, match.start())
        after = _clause_after(flat, match.end())
        whole_bird = bool(BILL_TO_TAIL.search(before) or BILL_TO_TAIL.search(after))
        marked = whole_bird or bool(LENGTH_NEARBY.search(after) or LENGTH_NEARBY.search(before))
        tainted = not whole_bird and bool(OTHER_MEASURE.search(flat[_sentence_start(flat, match.start()) : match.start()]) or OTHER_MEASURE.search(after))
        needs_context = unit in UNITS_NEEDING_CONTEXT
        if FEET_BEFORE.search(before) or (needs_context and not marked):
            continue
        if tainted and not (LENGTH_NEARBY.search(after) or re.search(r"\blength\b", before, re.IGNORECASE)):
            continue  # "a long (9 cm) bill" is marked before the figure; "is 50–65 cm long" and "bill-to-tail length ranges from 45 cm" say what is measured
        factor = UNIT_TO_CM[unit]
        low = _rounded(float(match.group(1)) * factor)
        high = _rounded(float(match.group(2)) * factor) if match.group(2) else low
        if low < PLAUSIBLE_CM[0] or high > PLAUSIBLE_CM[1] or high < low:
            continue
        score = 2 if marked and not needs_context and not tainted else 1
        formatted = f"{low} cm" if high == low else f"{low}–{high} cm"
        if best is None or score > best[0]:
            best = (score, match.start(), formatted)
    return best[2] if best else ""


def _sentence_start(flat: str, position: int) -> int:
    """Where the sentence (or the semicolon-separated statement) holding `position` starts."""
    starts = [m.end() for m in STATEMENT_END.finditer(flat, 0, position)]
    return starts[-1] if starts else 0


def _clause_before(flat: str, start: int) -> str:
    """The text between the previous clause boundary and `start`, at most 60 characters."""
    window = flat[max(0, start - 60) : start]
    boundaries = list(CLAUSE_BOUNDARY.finditer(window))
    return window[boundaries[-1].end() :] if boundaries else window


def _clause_after(flat: str, end: int) -> str:
    """The text from `end` to the next clause boundary, at most 60 characters, with a leading parenthetical (the unit
    conversion) kept so "125 cm (49 in) wingspan" reads as one clause."""
    window = flat[end : end + 60]
    window = re.sub(r"^\s*\([^)]*\)", " ", window)
    boundary = CLAUSE_BOUNDARY.search(window) or re.search(r"[:(]", window)
    cut = min(boundary.start() if boundary else len(window), (re.search(r"[:(]", window) or boundary).start() if boundary else len(window))
    return window[:cut]


def _rounded(number: float) -> int:
    """Half up, so 12.5 cm reads as 13 cm."""
    return int(number + 0.5)


def habitat(parts: dict[str, str]) -> str:
    """The habitat terms the article's habitat section mentions most (from a fixed vocabulary), most mentioned first,
    ties in order of first mention: "coast, rivers, water". When the section (often only range) yields fewer than
    `HABITAT_TERMS`, the lead's terms fill the rest."""
    section = _first(parts, HABITAT_SECTIONS)
    ranked = _habitat_terms(section) if section else []
    if len(ranked) < HABITAT_TERMS:
        fallback = parts.get("", "") if section else " ".join(parts.values())
        ranked += [term for term in _habitat_terms(fallback) if term not in ranked]
    return ", ".join(ranked[:HABITAT_TERMS])


def _habitat_terms(text: str) -> list[str]:
    counts: Counter[str] = Counter()
    first_seen: dict[str, int] = {}
    for position, token in enumerate(WORD.findall(NOT_HABITAT.sub(" ", text.lower()))):
        term = HABITAT_VOCABULARY.get(token)
        if term is None:
            continue
        counts[term] += 1
        first_seen.setdefault(term, position)
    return sorted(counts, key=lambda term: (-counts[term], first_seen[term]))


def article_matches(extract: str, scientific_name: str, common_name: str | None = None) -> bool:
    """Whether the article is about this species: its lead names the binomial, or (a taxonomic split, BirdNET's
    Pyrocephalus rubinus against Wikipedia's P. obscurus) the genus and the common name. A redirect that lands on a
    family page names neither the binomial nor the common name."""
    lead = _plain(sections(extract).get("", ""))
    if _plain(scientific_name) in lead:
        return True
    genus = scientific_name.split()[0].lower()
    return bool(common_name) and re.search(rf"\b{re.escape(genus)}\b", lead) is not None and _plain(common_name) in lead


def _plain(text: str) -> str:
    return text.lower().replace("-", " ").replace("’", "'")


def derive(extract: str, source: str) -> Description:
    parts = sections(extract)
    return Description(summary=summary(parts.get("", "")), field_marks=field_marks(parts), size=size(parts), habitat=habitat(parts), source=source)


PageFetcher = Callable[[str], dict]
"""(article title) -> the page as the Wikipedia query API returns it (`title`, `pageid`, `revisions`, `extract`, or `missing`)."""


def fetch_page(title: str, pause_seconds: float = 0.5) -> dict:
    params = {
        "action": "query",
        "prop": "extracts|revisions",
        "explaintext": 1,
        "exsectionformat": "wiki",
        "redirects": 1,
        "rvprop": "ids",
        "format": "json",
        "formatversion": 2,
        "titles": title,
    }
    response = session().get(API, params=params, headers={"User-Agent": USER_AGENT}, timeout=60)
    response.raise_for_status()
    pages = response.json().get("query", {}).get("pages", [])
    time.sleep(pause_seconds)
    return pages[0] if pages else {"title": title, "missing": True}


class WikipediaDescriptions:
    """Descriptions from each species' `wikipedia_url`, with the fetched page cached under `cache/wikipedia/` so a
    rebuild is offline and reproduces the same text. The pack's committed lock file (`wikipedia.lock.json`, title to
    revision id) records which revision each text came from: a build from a clean cache fetches the current article
    and warns for every revision that moved, so drift in the text is visible and `write_lock` re-pins it."""

    def __init__(self, cache_dir: Path, fetch: PageFetcher = fetch_page, lock_path: Path | None = None):
        self.cache_dir = Path(cache_dir) / "wikipedia"
        self.fetch = fetch
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.lock_path = lock_path
        self.locked: dict[str, int] = json.loads(lock_path.read_text()) if lock_path and lock_path.exists() else {}
        self.revisions: dict[str, int] = {}
        """The revision each described title came from in this build, in the order described."""

    @staticmethod
    def title_of(url: str) -> str:
        return unquote(urlparse(url).path.rsplit("/", 1)[-1])

    def describe(self, entry: SpeciesEntry, trust_article: bool = False) -> Description | None:
        if not entry.wikipedia_url:
            log.warning("  %s has no Wikipedia URL; no description", entry.common_name)
            return None
        title = self.title_of(entry.wikipedia_url)
        page = self._page(title)
        if page.get("missing") or not page.get("extract"):
            log.warning("  no Wikipedia article %r for %s", title, entry.common_name)
            return None
        extract = page["extract"]
        if not trust_article and not article_matches(extract, entry.scientific_name, entry.common_name):
            log.warning("  Wikipedia article %r (%s) does not name %s; no description", title, page.get("title"), entry.scientific_name)
            return None
        revision = int(page["revisions"][0]["revid"])
        if title in self.locked and self.locked[title] != revision:
            log.warning("  Wikipedia article %r moved from revision %d to %d; the text may differ from the last build", title, self.locked[title], revision)
        self.revisions[title] = revision
        source = f"{ARTICLE}?title={page['title'].replace(' ', '_')}&oldid={revision}"
        return derive(extract, source=source)

    def write_lock(self) -> None:
        """Records this build's revisions in the lock file, keeping entries for titles this build did not describe."""
        if self.lock_path is None:
            return
        self.lock_path.write_text(json.dumps({**self.locked, **self.revisions}, indent=2, sort_keys=True) + "\n")

    def _page(self, title: str) -> dict:
        cache_file = self.cache_dir / f"{title.replace('/', '_')}.json"
        if cache_file.exists():
            return json.loads(cache_file.read_text())
        page = self.fetch(title)
        cache_file.write_text(json.dumps(page))
        return page
