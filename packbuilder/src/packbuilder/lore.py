"""Lore (issue #56, CONTEXT.md "Lore"): a species' short myth-voiced text built from its fact sheet, written once per
pack by a Claude model through the Anthropic API, reviewed by hand and pinned in `lore.lock.json` beside the pack
definition.

Each species gets 50 to 80 words of lore in a legend's voice, a tagline of 12 words or fewer and a story title of 2
to 5 words (issue #113) that heads the lore on the card's front. Every sentence, the tagline and the title name the
fact-sheet entries they rest on (`f1`, `f2`, ...); a draft that cites nothing, cites a fact the sheet lacks or misses
the word counts is sent back with what was wrong, up to `ATTEMPTS` times. A title may not name the bird (`name_words`)
or hold a number, and a set's titles may not lean on one opening or one closing word (`OPENING_SHARE`).

The lock pins per species the facts the lore was written from (the pack ships those, so lore and fact sheet always
agree), the sentences with their citations, the tagline, the model, the prompt version and the review:

- `pending`: written, not reviewed yet. Only `approved` lore goes into the pack.
- `approved`: in the pack.
- `rejected`: written again by the next build, with the maintainer's reason in the prompt.

The title has its own review, in its own object of the entry (`title`, with its citations, model and prompt version),
so lore approved before titles existed stays approved while its title is written and reviewed: an entry with lore but
no title gets one from a title-only request (`TITLE_SYSTEM`, the locked lore in the prompt), and a rejected title is
written again alone. New lore is written with its title in one request. Only an approved title on approved lore ships.

A warm lock makes no API call and needs no key. Lore is written again on request (a rejection, or
`packbuilder build --regenerate-lore`) and when a dataset fact it cites changed (issue #86). A dataset fact is matched
by its text, since the stats sentences are the datasets' own: one the lore cites that is gone from the sheet sends the
entry back to be written from the new sheet, and comes back pending; one it doesn't cite is swapped for the new
sentence in the locked sheet (keeping its id) and the lore and its review stay. The article's facts are left as they
were locked: a Wikipedia revision that moved is logged and changes nothing until the lore is regenerated.

The key is read from `BIRDJOURNAL_ANTHROPIC_API_KEY` (never `ANTHROPIC_API_KEY`, which would switch Claude Code itself
to API billing), else from the login Keychain item `birdjournal-anthropic-api-key`, and passed to the client; it is
never logged or written anywhere. A key the API refuses stops the run at once, before anything is locked.
"""

from __future__ import annotations

import copy
import json
import logging
import math
import os
import re
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Protocol

from packbuilder.factsheet import Fact

log = logging.getLogger("packbuilder.lore")

LOCK_FILE = "lore.lock.json"
PENDING, APPROVED, REJECTED = "pending", "approved", "rejected"
SHARED_FROM = "shared_from"
"""On a lock entry: the id of the pack whose lore for this species it is (lore is written once per species, #58)."""
API_KEY_VARIABLE = "BIRDJOURNAL_ANTHROPIC_API_KEY"
KEYCHAIN_SERVICE = "birdjournal-anthropic-api-key"
MODEL = "claude-opus-5-5"
"""DECISIONS.md, "Lore and captions": the current Opus, for the voice; a pack of 160 species costs a few dollars."""
PROMPT_VERSION = 5
"""4: varied openings (#56). 5: the story title, with the lore or alone (#113)."""
ATTEMPTS = 3
PRICES = {"claude-opus-5-5": (4.0, 20.0), "claude-sonnet-5-5": (2.0, 10.0)}
"""Dollars per million input and output tokens, for the run's spend and its budget."""
DEFAULT_INTERVAL = 2.0
"""Seconds between API requests: the step is paced like the other network steps, one request at a time."""
LORE_WORDS = (50, 80)
TAGLINE_WORDS = 12
TITLE_WORDS = (2, 5)
MAX_NUMBERS = 1
NUMBER = re.compile(
    r"\b(\d[\d,.]*|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|"
    r"eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundreds?|thousands?|millions?|dozens?)\b",
    re.IGNORECASE,
)
"""Numbers in figures or words; "one" is left out, as prose uses it for other things. "twenty-six" counts once."""
ALL = "all"
OPENING_SHARE = 0.15
"""At most this share of a set's lore may begin with the same two words, or use "ask why" anywhere (prompts v4): the
first full run opened 72 of 160 with "Ask why". The same share caps a set's titles beginning with the same two words
("the night") or ending on the same word ("hunter")."""
ASK_WHY = re.compile(r"\bask why\b", re.IGNORECASE)

TITLE_RULES = """The title gives the bird an epithet, as a legend would, from what it does, what it makes or where it \
keeps: imaginative, not taxonomic. It claims nothing its cited facts don't say. Never name the bird: not its common or \
scientific name, not the word for its kind (owl, wren, hawk), not the person it is named for, and not a marking its \
name gives it (red-tailed, black-chinned). No numbers. A set holds many cards, so vary how the titles begin and end."""

SYSTEM = """You write the lore on the back of collectible bird cards: true natural history told as a small legend.

Write 50 to 80 words of lore about one species, a tagline of 12 words or fewer for the card's front, and a story title \
of 2 to 5 words that heads the lore on the front.

Tell it as a small legend about one or two things the bird does. Lead with how it lives: where it keeps, how it hunts, \
what it builds, how it sounds. A set holds many cards, so vary how you begin and how you frame the tale: open on the \
bird at its work, a place, a sound, a season of its life, a name, a contrast or a question, and do not fall back on \
one habit such as "Ask why" or "Hear now".

The only facts you may use are the numbered entries of the species' fact sheet. Prefer the article's facts; the \
datasets' entries are coarse category labels, so use one only where the article says nothing on that point. Use at \
most one number in the whole lore, and none in the tagline.

Each sentence must say only what the facts it cites say. The legend lives in the telling (the cadence, the epithets, \
the order of things), never in new facts: no behaviour, food, colour, number, place, season, sound or purpose of your \
own. A "why" may join two facts only when it is signposted as the tale's own telling ("the tale answers", "they say", \
"so the story goes"); never state a cause the sheet does not give as fact. Do not name gods, peoples or real people \
unless the sheet does.

""" + TITLE_RULES + """

Every sentence of the lore, the tagline and the title list the ids of the fact-sheet entries they rest on; each rests \
on at least one. Use plain words a ten-year-old could read aloud; no archaic spellings."""

TITLE_SYSTEM = """You write the story titles on the front of collectible bird cards. Each card's back tells true natural \
history as a small legend, and the title heads it.

Write a story title of 2 to 5 words for one species' legend. """ + TITLE_RULES + """

The only facts you may use are the numbered entries of the species' fact sheet; the title lists the ids of the entries \
it rests on, at least one. The legend is there to set the tone, not as a source. Use plain words a ten-year-old could \
read aloud; no archaic spellings."""

CITED_TEXT = {
    "type": "object",
    "properties": {"text": {"type": "string"}, "facts": {"type": "array", "items": {"type": "string"}}},
    "required": ["text", "facts"],
    "additionalProperties": False,
}
"""A sentence, the tagline or the title: its text and the fact ids it rests on."""

SCHEMA = {
    "type": "object",
    "properties": {"sentences": {"type": "array", "items": CITED_TEXT}, "tagline": CITED_TEXT, "title": CITED_TEXT},
    "required": ["sentences", "tagline", "title"],
    "additionalProperties": False,
}

TITLE_SCHEMA = {
    "type": "object",
    "properties": {"title": CITED_TEXT},
    "required": ["title"],
    "additionalProperties": False,
}


class MissingAPIKey(RuntimeError):
    pass


def api_key_from_environment(keychain: Callable[[], str | None] | None = None) -> str:
    """`BIRDJOURNAL_ANTHROPIC_API_KEY`, else the login Keychain's `birdjournal-anthropic-api-key` item (macOS)."""
    key = os.environ.get(API_KEY_VARIABLE, "").strip() or ((keychain or _keychain_key)() or "").strip()
    if not key:
        raise MissingAPIKey(
            f"lore needs an Anthropic API key in {API_KEY_VARIABLE} or the Keychain item {KEYCHAIN_SERVICE} (never the repository; "
            "not ANTHROPIC_API_KEY): set it, or build with --no-lore, or keep the lore lock warm"
        )
    return key


def _keychain_key() -> str | None:
    import subprocess

    try:
        found = subprocess.run(
            ["security", "find-generic-password", "-a", os.environ.get("USER", ""), "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return found.stdout if found.returncode == 0 else None


class LoreClient(Protocol):
    def complete(self, system: str, prompt: str, schema: dict) -> str:
        """The model's reply to `prompt`, as JSON text matching `schema`."""


class AnthropicLoreClient:
    """The Messages API with structured output, one request at a time. The SDK retries rate limits, overloads and
    connection errors itself; any other API error stops the run (`LoreAPIError`)."""

    def __init__(self, api_key: str, model: str = MODEL, client=None):
        import anthropic

        self.model = model
        self.client = client or anthropic.Anthropic(api_key=api_key)
        self.input_tokens = self.output_tokens = 0
        """Tokens billed so far, for the run's report (thinking counts as output)."""

    def complete(self, system: str, prompt: str, schema: dict) -> str:
        import anthropic

        try:
            return self._complete(system, prompt, schema)
        except anthropic.AuthenticationError as error:
            raise LoreAPIError(f"the Anthropic API refused the key ({error.status_code}): check {API_KEY_VARIABLE} or the Keychain item {KEYCHAIN_SERVICE}") from None
        except anthropic.PermissionDeniedError as error:
            raise LoreAPIError(f"the key may not use {self.model} ({error.status_code})") from None
        except anthropic.APIStatusError as error:
            raise LoreAPIError(f"the Anthropic API answered {error.status_code}: {_message(error)}") from None
        except anthropic.APIConnectionError as error:
            raise LoreAPIError(f"the Anthropic API could not be reached: {error.__class__.__name__}") from None

    def _complete(self, system: str, prompt: str, schema: dict) -> str:
        # Fallbacks re-run a declined request on another model server-side; lore about birds is not expected to be
        # declined, so a refusal that survives them is an error.
        response = self.client.beta.messages.create(
            model=self.model,
            max_tokens=16000,
            system=system,
            messages=[{"role": "user", "content": prompt}],
            thinking={"type": "adaptive"},
            output_config={"effort": "high", "format": {"type": "json_schema", "schema": schema}},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )
        self.input_tokens += response.usage.input_tokens
        self.output_tokens += response.usage.output_tokens
        log.info("  %d input and %d output tokens", response.usage.input_tokens, response.usage.output_tokens)
        if response.stop_reason == "refusal":
            raise LoreRefused(getattr(response.stop_details, "category", None) or "no category")
        if response.stop_reason == "max_tokens":
            raise LoreTruncated("the reply hit max_tokens")
        return next(block.text for block in response.content if block.type == "text")


class LoreRefused(RuntimeError):
    pass


class LoreTruncated(ValueError):
    """The reply ran out of tokens: the draft is sent back, as one that fails its checks."""


class LoreBudgetExceeded(RuntimeError):
    """The run spent its budget; what was written is locked, the rest waits for the next run."""


class LoreAPIError(RuntimeError):
    """The API refused the key or the request; the message never holds the key."""


def _message(error) -> str:
    body = getattr(error, "body", None)
    if isinstance(body, dict) and isinstance(body.get("error"), dict):
        return str(body["error"].get("message", ""))[:200]
    return error.__class__.__name__


class InvalidLore(ValueError):
    """A locked entry (edited by hand) whose sentences cite facts its sheet lacks, or that misses the word counts."""


@dataclass(frozen=True)
class Lore:
    """One species' lore as the build has it."""

    species_id: str
    review: str
    sentences: tuple[dict, ...]
    """{"text", "facts"} each, in order."""
    tagline: dict
    facts: tuple[Fact, ...]
    """The fact sheet the lore was written from."""
    model: str = MODEL
    title: dict | None = None
    """{"text", "facts", "model", "prompt_version", "review"}, or None before it is written."""

    @property
    def ships(self) -> bool:
        return self.review == APPROVED

    @property
    def shipped_title(self) -> str | None:
        """The title's text when it goes into the pack: approved, on approved lore."""
        return self.title["text"] if self.ships and self.title and self.title.get("review") == APPROVED else None

    @property
    def text(self) -> str:
        return " ".join(sentence["text"] for sentence in self.sentences)

    @property
    def sources(self) -> list[str]:
        """The distinct sources of the facts it cites, in sheet order: the Wikipedia revision and the datasets; the
        title's count once it ships."""
        parts = (*self.sentences, self.tagline, *([self.title] if self.shipped_title else []))
        cited = {fact_id for sentence in parts for fact_id in sentence["facts"]}
        return list(dict.fromkeys(fact.source for fact in self.facts if fact.id in cited))


def validate(draft: dict, facts: list[Fact] | tuple[Fact, ...]) -> list[str]:
    """What is wrong with a draft against the sheet: empty means it may be locked."""
    problems = []
    known = {fact.id for fact in facts}
    sentences = draft.get("sentences") or []
    if not sentences:
        problems.append("the lore has no sentences")
    for number, sentence in enumerate(sentences, start=1):
        text = sentence.get("text", "").strip()
        cited = sentence.get("facts") or []
        if not cited:
            problems.append(f"sentence {number} cites no fact: {text!r}")
        unknown = [fact_id for fact_id in cited if fact_id not in known]
        if unknown:
            problems.append(f"sentence {number} cites facts the sheet lacks: {', '.join(unknown)}")
        if not re.search(r"[.!?][\"'’”]?$", text):
            problems.append(f"sentence {number} does not end a sentence: {text!r}")
        if len(re.findall(r"[.!?][\"'’”]?\s+[A-Z\"'“]", text)):
            problems.append(f"sentence {number} holds more than one sentence; give each its own citations: {text!r}")
    count = sum(len(sentence.get("text", "").split()) for sentence in sentences)
    if not LORE_WORDS[0] <= count <= LORE_WORDS[1]:
        problems.append(f"the lore is {count} words; it must be {LORE_WORDS[0]} to {LORE_WORDS[1]}")
    numbers = sum(len(_numbers(sentence.get("text", ""))) for sentence in sentences)
    if numbers > MAX_NUMBERS:
        problems.append(f"the lore holds {numbers} numbers; use at most {MAX_NUMBERS}")
    tagline = draft.get("tagline") or {}
    if _numbers(tagline.get("text", "")):
        problems.append("the tagline holds a number; use none")
    tagline_words = len(tagline.get("text", "").split())
    if not 1 <= tagline_words <= TAGLINE_WORDS:
        problems.append(f"the tagline is {tagline_words} words; it must be 1 to {TAGLINE_WORDS}")
    if not tagline.get("facts"):
        problems.append("the tagline cites no fact")
    elif unknown := [fact_id for fact_id in tagline["facts"] if fact_id not in known]:
        problems.append(f"the tagline cites facts the sheet lacks: {', '.join(unknown)}")
    return problems


def name_words(common_name: str, scientific_name: str) -> set[str]:
    """The words a title may not use, lowercased: the scientific name's, the word for the bird's kind (the common
    name's last word, and its last part when hyphenated: "scrub-jay" and "jay"), the person it is named for ("anna"),
    and the markings its name gives it ("red-tailed"). A plain word of the name ("black", "acorn", "house") may stay:
    the bird's story is often in it, and alone it does not name the species."""
    words = {word.lower() for word in scientific_name.split()}
    parts = common_name.lower().replace("’", "'").split()
    if parts:
        words |= {parts[-1], parts[-1].split("-")[-1]}
    for part in parts[:-1]:
        if part.endswith("'s"):
            words.add(part[:-2])
        elif "-" in part:
            words.add(part)
    return words


def validate_title(title: dict | None, facts: list[Fact] | tuple[Fact, ...], common_name: str, scientific_name: str) -> list[str]:
    """What is wrong with a title against the sheet and the bird's names: empty means it may be locked."""
    if not title:
        return ["there is no title"]
    problems = []
    text = title.get("text", "").strip()
    words = len(text.split())
    if not TITLE_WORDS[0] <= words <= TITLE_WORDS[1]:
        problems.append(f"the title is {words} words; it must be {TITLE_WORDS[0]} to {TITLE_WORDS[1]}")
    cited = title.get("facts") or []
    if not cited:
        problems.append("the title cites no fact")
    elif unknown := [fact_id for fact_id in cited if fact_id not in {fact.id for fact in facts}]:
        problems.append(f"the title cites facts the sheet lacks: {', '.join(unknown)}")
    if _numbers(text):
        problems.append("the title holds a number; use none")
    forbidden = name_words(common_name, scientific_name)
    if named := [token for token in _title_words(text) if {token, *_singulars(token), *token.split("-")} & forbidden]:
        problems.append(f"the title names the bird ({', '.join(dict.fromkeys(named))}); give it an epithet instead")
    return problems


def _title_words(text: str) -> list[str]:
    """The title's words, lowercased, without possessive endings: "The Owl's Hour" gives the, owl, hour."""
    return [re.sub(r"'s?$", "", word) for word in re.findall(r"[a-z]+(?:[-'][a-z]+)*'?", text.lower().replace("’", "'"))]


def _singulars(word: str) -> list[str]:
    return [word[:-2], word[:-1]] if word.endswith("es") else [word[:-1]] if word.endswith("s") else []


def title_opening(title: dict | None) -> str:
    """A title's first two words, lowercased: "the waterside"."""
    return " ".join(_title_words((title or {}).get("text", ""))[:2])


def title_ending(title: dict | None) -> str:
    """A title's last word, lowercased: "mason"."""
    return (_title_words((title or {}).get("text", "")) or [""])[-1]


def opening(draft: dict) -> str:
    """The lore's first two words, lowercased: "ask why", "where water"."""
    text = (draft.get("sentences") or [{}])[0].get("text", "")
    return " ".join(re.findall(r"[a-z']+", text.lower())[:2])


def _numbers(text: str) -> list[str]:
    """Each number in the text once: "twenty-six" and "four hundred" are one number each."""
    return re.findall(r"(?:%s)(?:[\s-]+(?:%s))*" % (NUMBER.pattern, NUMBER.pattern), text, flags=re.IGNORECASE)


def prompt(
    common_name: str, scientific_name: str, facts: list[Fact] | tuple[Fact, ...], feedback: list[str] | tuple[str, ...] = (), lore: dict | None = None,
) -> str:
    """The request for one species: its names and its fact sheet, then (for a title alone) its locked lore and
    tagline, then what the maintainer or the checks sent back."""
    lines = [f"Species: {common_name} ({scientific_name})"]
    article = [fact for fact in facts if fact.source.startswith("http")]
    datasets = [fact for fact in facts if not fact.source.startswith("http")]
    if article:
        lines += ["", "Fact sheet, from its Wikipedia article:"] + [f"{fact.id}: {fact.text}" for fact in article]
    if datasets:
        lines += ["", "Fact sheet, from the datasets (coarse labels):"] + [f"{fact.id}: {fact.text}" for fact in datasets]
    if lore is not None:
        lines += ["", "Its legend, which the title heads:", _lore_text(lore), "", f"Its tagline: {(lore.get('tagline') or {}).get('text', '')}"]
    if feedback:
        lines += ["", "Notes on this draft:"] + [f"- {item}" for item in feedback]
    return "\n".join(lines)


class LoreLock:
    """`lore.lock.json`: per species id, the facts, the lore and its review (see the module)."""

    COMMENT = (
        "Lore (issue #56), written by `packbuilder build` and `packbuilder lore-review`; read it in build/lore/<pack id>/review.md. "
        "Per species: the fact sheet the lore was written from (shipped with it), the sentences with the fact ids each rests on, "
        "the tagline, the model and prompt version, and the review: pending, approved (in the pack) or rejected (written again "
        "by the next build, with the reason). The story title (issue #113) has its own citations, model, prompt version and review."
    )

    def __init__(self, path: Path, species: dict[str, dict]):
        self.path, self.species = Path(path), species

    @classmethod
    def load(cls, path: Path) -> "LoreLock":
        path = Path(path)
        return cls(path, json.loads(path.read_text())["species"] if path.exists() else {})

    def write(self) -> None:
        document = {"comment": self.COMMENT, "species": dict(sorted(self.species.items()))}
        self.path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")


def _lore_text(entry: dict) -> str:
    return " ".join(sentence.get("text", "") for sentence in entry.get("sentences") or [])


def _cited(entry: dict) -> set[str]:
    return {fact_id for sentence in (*(entry.get("sentences") or []), entry.get("tagline") or {}) for fact_id in sentence.get("facts") or []}


def _is_dataset(fact: Fact) -> bool:
    return not fact.source.startswith("http")


def stats_changes(locked: list[Fact], current: list[Fact]) -> tuple[list[Fact], list[Fact]]:
    """The locked sheet's dataset facts the current sheet no longer has, and the current sheet's new ones, by text."""
    now = {(fact.text, fact.source) for fact in current if _is_dataset(fact)}
    before = {(fact.text, fact.source) for fact in locked if _is_dataset(fact)}
    return (
        [fact for fact in locked if _is_dataset(fact) and (fact.text, fact.source) not in now],
        [fact for fact in current if _is_dataset(fact) and (fact.text, fact.source) not in before],
    )


def refreshed(locked: list[Fact], removed: list[Fact], added: list[Fact]) -> list[Fact]:
    """The locked sheet with its gone dataset facts swapped for the new ones in turn (each keeping the old id), any
    left over dropped, and further new ones appended with fresh ids."""
    swaps = {old.id: Fact(old.id, new.text, new.source) for old, new in zip(removed, added)}
    gone = {fact.id for fact in removed}
    facts = [swaps.get(fact.id, fact) for fact in locked if fact.id not in gone or fact.id in swaps]
    last = max((int(fact.id[1:]) for fact in locked if fact.id[1:].isdigit()), default=0)
    facts += [Fact(f"f{last + number}", fact.text, fact.source) for number, fact in enumerate(added[len(removed):], start=1)]
    return facts


def stale(entry: dict, facts: list[Fact]) -> list[Fact]:
    """The dataset facts this locked entry's lore cites that the current sheet no longer has."""
    removed, _ = stats_changes([Fact.from_dict(f) for f in entry["facts"]], facts)
    cited = _cited(entry)
    return [fact for fact in removed if fact.id in cited]


def stale_title(entry: dict, facts: list[Fact]) -> list[Fact]:
    """The dataset facts this locked entry's title cites that the current sheet no longer has."""
    if not entry.get("title") or not facts:
        return []
    removed, _ = stats_changes([Fact.from_dict(f) for f in entry["facts"]], facts)
    return [fact for fact in removed if fact.id in entry["title"].get("facts", [])]


def lore_from_entry(species_id: str, entry: dict) -> Lore:
    return Lore(
        species_id, entry["review"], tuple(entry["sentences"]), entry["tagline"], tuple(Fact.from_dict(f) for f in entry["facts"]),
        entry.get("model", MODEL), entry.get("title"),
    )


def _article(facts) -> list[tuple[str, str]]:
    """A sheet's Wikipedia facts as (text, revision link), from `Fact`s or a lock entry's dicts."""
    pairs = [(f["text"], f["source"]) if isinstance(f, dict) else (f.text, f.source) for f in facts]
    return [pair for pair in pairs if pair[1].startswith("http")]


def shared_lore(definitions: Path, pack_id: str) -> dict[str, tuple[str, dict]]:
    """The lore the other packs under `definitions` hold as their own, by species id: (pack id, lock entry). Lore is
    written once per species (#58), so a pack takes these instead of asking for its own; the first pack by id wins."""
    found: dict[str, tuple[str, dict]] = {}
    for path in sorted(Path(definitions).glob(f"*/{LOCK_FILE}")):
        if path.parent.name == pack_id:
            continue
        for species_id, entry in LoreLock.load(path).species.items():
            if not entry.get(SHARED_FROM):
                found.setdefault(species_id, (path.parent.name, entry))
    return found


@dataclass
class LoreWriter:
    """Writes what the lock lacks for one pack and keeps the lock. `client` is made on the first request, so a warm
    lock needs no key; `regenerate` names species ids (or `ALL`) to write again, and `regenerate_titles` those whose
    title alone to write again. `titles` False makes no title-only request (new lore still comes with its title)."""

    lock: LoreLock
    client_factory: Callable[[], LoreClient]
    model: str = MODEL
    regenerate: frozenset[str] = frozenset()
    regenerate_titles: frozenset[str] = frozenset()
    titles: bool = True
    shared: dict[str, tuple[str, dict]] = field(default_factory=dict)
    """Other packs' own lore by species id, as (pack id, lock entry): see `shared_lore`. A species this lock lacks takes
    it, marked `shared_from`, and follows it from then on; such an entry is never written or reviewed here."""
    interval: float = DEFAULT_INTERVAL
    budget: float | None = None
    """Dollars this run may spend (by `PRICES`); no request starts once it is spent, so a run ends at most one
    request past it."""
    sleep: Callable[[float], None] = time.sleep
    clock: Callable[[], float] = time.monotonic
    requests: int = field(default=0, init=False)
    title_requests: int = field(default=0, init=False)
    """Of `requests`, those for a title alone."""

    def __post_init__(self):
        self._client: LoreClient | None = None
        self._last: float | None = None

    def write(self, species: list[tuple[str, str, str]], sheets: dict[str, list[Fact]]) -> dict[str, Lore]:
        """Each species' lore, by id, for (id, common name, scientific name) in pack order; a species whose lore could
        not be written is left out (and logged). The lock is written after each species, so an interrupted run resumes."""
        written: dict[str, Lore] = {}
        mirrors = self._take_shared(species, sheets)
        changed = {
            species_id: gone for species_id, _, _ in species
            if (entry := self.lock.species.get(species_id)) is not None and entry["review"] != REJECTED and sheets.get(species_id)
            and species_id not in mirrors and (gone := stale(entry, sheets[species_id]))
        }
        regenerating = ({species_id for species_id, _, _ in species if ALL in self.regenerate or species_id in self.regenerate} - mirrors) | set(changed)
        kept = [entry for species_id, entry in self.lock.species.items() if species_id not in regenerating]
        self._openings = Counter(opening(entry) for entry in kept)
        self._ask_why = sum(bool(ASK_WHY.search(_lore_text(entry))) for entry in kept)
        self._cap = max(2, math.ceil(OPENING_SHARE * max(len(species), len(self.lock.species))))
        in_run = {species_id for species_id, _, _ in species}
        retitling = regenerating | {
            species_id for species_id, entry in self.lock.species.items()
            if species_id in in_run and species_id not in mirrors
            and (self._needs_title(species_id, entry) or stale_title(entry, sheets.get(species_id) or []))
        }
        kept_titles = [entry["title"] for species_id, entry in self.lock.species.items() if species_id not in retitling and entry.get("title")]
        self._title_openings = Counter(title_opening(title) for title in kept_titles)
        self._title_endings = Counter(title_ending(title) for title in kept_titles)
        for species_id, common_name, scientific_name in species:
            facts = sheets.get(species_id) or []
            entry = self.lock.species.get(species_id)
            wanted = ALL in self.regenerate or species_id in self.regenerate
            if species_id in mirrors:
                # Another pack's lore: its checks, its facts and its review, as that pack's lock holds them.
                locked = [Fact.from_dict(f) for f in entry["facts"]]
                if problems := validate(entry, locked):
                    raise InvalidLore(f"{self.lock.path}: {common_name}'s lore, shared from {entry[SHARED_FROM]}, fails its checks: {'; '.join(problems)}")
                if species_id in self.regenerate or species_id in self.regenerate_titles:
                    log.warning("  %s: its lore is shared from %s; write it again there", common_name, entry[SHARED_FROM])
                if facts and _article(facts) != _article(entry["facts"]):
                    log.warning("  %s: this pack's article facts differ from the ones its shared lore (%s) was written from; the shared facts and lore stay", common_name, entry[SHARED_FROM])
                written[species_id] = lore_from_entry(species_id, entry)
                continue
            if species_id in changed:
                log.warning(
                    "  %s: a fact its lore cites changed (%s); writing it again", common_name,
                    "; ".join(f"{fact.id}: {fact.text!r}" for fact in changed[species_id]),
                )
            elif entry is not None and not wanted and entry["review"] != REJECTED:
                locked = [Fact.from_dict(f) for f in entry["facts"]]
                if problems := validate(entry, locked):
                    raise InvalidLore(f"{self.lock.path}: {common_name}'s locked lore fails its checks: {'; '.join(problems)}")
                title = entry.get("title")
                if title and title.get("review") != REJECTED and (problems := validate_title(title, locked, common_name, scientific_name)):
                    raise InvalidLore(f"{self.lock.path}: {common_name}'s locked title fails its checks: {'; '.join(problems)}")
                if [fact.as_dict() for fact in facts] != entry["facts"]:
                    removed, added = stats_changes(locked, facts) if facts else ([], [])
                    if removed or added:
                        if gone := stale_title(entry, facts):
                            log.warning(
                                "  %s: a fact its title cites changed (%s); writing the title again", common_name,
                                "; ".join(f"{fact.id}: {fact.text!r}" for fact in gone),
                            )
                            del entry["title"]
                        entry["facts"] = [fact.as_dict() for fact in refreshed(locked, removed, added)]
                        self.lock.write()
                        log.info("  %s: dataset facts its lore doesn't cite changed; the locked sheet takes them and the lore stays", common_name)
                    if [fact for fact in facts if not _is_dataset(fact)] != [fact for fact in locked if not _is_dataset(fact)]:
                        log.warning("  %s: the article's facts changed since its lore was written; the locked facts and lore stay (--regenerate-lore to rewrite)", common_name)
                if self._needs_title(species_id, entry):
                    self._write_title(common_name, scientific_name, entry)
                written[species_id] = lore_from_entry(species_id, entry)
                continue
            if not facts:
                log.warning("  %s has no fact sheet; no lore", common_name)
                continue
            feedback = [f"The maintainer rejected it: {entry['why']}"] if entry and entry["review"] == REJECTED and entry.get("why") else []
            draft = self._draft(common_name, scientific_name, facts, feedback + self._crowded() + self._crowded_titles())
            if draft is None:
                continue
            self._openings[opening(draft)] += 1
            self._ask_why += bool(ASK_WHY.search(_lore_text(draft)))
            self._count_title(draft["title"])
            self.lock.species[species_id] = {
                "common_name": common_name, "model": self.model, "prompt_version": PROMPT_VERSION,
                "facts": [fact.as_dict() for fact in facts], "sentences": draft["sentences"], "tagline": draft["tagline"], "review": PENDING,
                "title": self._title_entry(draft["title"]),
            }
            self.lock.write()
            written[species_id] = lore_from_entry(species_id, self.lock.species[species_id])
        if (usage := getattr(self._client, "input_tokens", None)) is not None:
            log.info("lore: %d input and %d output tokens, $%.2f", usage, self._client.output_tokens, self.spent or 0)
        log.info(
            "lore: %d requests (%d for a title alone), %d approved, %d to review; titles: %d approved, %d to review",
            self.requests, self.title_requests, sum(l.ships for l in written.values()), sum(l.review == PENDING for l in written.values()),
            sum(bool(l.title and l.title.get("review") == APPROVED) for l in written.values()),
            sum(bool(l.title and l.title.get("review") == PENDING) for l in written.values()),
        )
        return written

    def _take_shared(self, species: list[tuple[str, str, str]], sheets: dict[str, list[Fact]]) -> set[str]:
        """Brings this lock's shared entries up to date with the packs they come from and takes the shared lore of
        species the lock lacks; the ids of the run's species whose lore is another pack's. A species is first taken
        only when this pack's article facts are the ones that lore was written from, so the pack's text credits
        (its own article revisions) cover it; this pack's own lore is never replaced."""
        mirrors: set[str] = set()
        dirty = False
        for species_id, common_name, _ in species:
            entry = self.lock.species.get(species_id)
            source = self.shared.get(species_id)
            if entry is not None and not entry.get(SHARED_FROM):
                continue
            if source is None:
                if entry is not None:
                    log.warning("  %s: %s no longer holds its lore; it is this pack's own from now on", common_name, entry[SHARED_FROM])
                    del entry[SHARED_FROM]
                    dirty = True
                continue
            pack_id, original = source
            if entry is None and _article(sheets.get(species_id) or []) != _article(original["facts"]):
                log.info("  %s: %s has lore for it, written from other article facts; writing this pack's own", common_name, pack_id)
                continue
            taken = {**copy.deepcopy(original), "common_name": common_name, SHARED_FROM: pack_id}
            if taken != entry:
                self.lock.species[species_id] = taken
                dirty = True
            mirrors.add(species_id)
        if dirty:
            self.lock.write()
        if mirrors:
            log.info("lore: %d species share another pack's lore", len(mirrors))
        return mirrors

    def _needs_title(self, species_id: str, entry: dict) -> bool:
        """Whether a kept entry's title is to be written alone: missing, rejected, or asked for again."""
        title = entry.get("title")
        return self.titles and not entry.get(SHARED_FROM) and entry["review"] != REJECTED and (
            not title or title.get("review") == REJECTED or ALL in self.regenerate_titles or species_id in self.regenerate_titles
        )

    def _write_title(self, common_name: str, scientific_name: str, entry: dict) -> None:
        """A title alone for a kept entry, from its locked sheet and lore; the lore, tagline and their review stay."""
        old = entry.get("title")
        feedback = []
        if old and old.get("review") == REJECTED:
            feedback.append(f"The maintainer rejected the title {old['text']!r}" + (f": {old['why']}" if old.get("why") else "."))
        elif old:
            feedback.append(f"Its title is {old['text']!r}; write another.")
        facts = [Fact.from_dict(f) for f in entry["facts"]]
        draft = self._draft(common_name, scientific_name, facts, feedback + self._crowded_titles(), lore=entry)
        if draft is None:
            return
        self._count_title(draft["title"])
        entry["title"] = self._title_entry(draft["title"])
        self.lock.write()

    def _title_entry(self, title: dict) -> dict:
        return {"text": title["text"], "facts": title["facts"], "model": self.model, "prompt_version": PROMPT_VERSION, "review": PENDING}

    def _count_title(self, title: dict) -> None:
        self._title_openings[title_opening(title)] += 1
        self._title_endings[title_ending(title)] += 1

    def _draft(self, common_name: str, scientific_name: str, facts: list[Fact], feedback: list[str], lore: dict | None = None) -> dict | None:
        """A draft that passes its checks: the lore with its tagline and title, or (given the locked `lore`) a title
        alone, as {"title"}; None after `ATTEMPTS` failures or a refusal."""
        what = "a title" if lore is not None else "lore"
        system, schema = (TITLE_SYSTEM, TITLE_SCHEMA) if lore is not None else (SYSTEM, SCHEMA)
        problems: list[str] = []
        for _ in range(ATTEMPTS):
            try:
                reply = self._complete(prompt(common_name, scientific_name, facts, feedback + problems, lore=lore), system, schema)
            except LoreTruncated:
                problems = [f"the reply was cut off; keep {what} and your thinking short"]
                continue
            except LoreRefused as refusal:
                log.error("  %s: the model declined to write %s (%s); none", common_name, what, refusal)
                return None
            try:
                draft = json.loads(reply)
            except json.JSONDecodeError:
                problems = ["the reply was not the JSON asked for"]
                continue
            title = _cited_part(draft.get("title"))
            problems = validate_title(title, facts, common_name, scientific_name) + self._title_set_problems(title)
            if lore is not None:
                draft = {"title": title}
            else:
                draft = {"sentences": [_cited_part(s) for s in draft.get("sentences") or []], "tagline": _cited_part(draft.get("tagline")), "title": title}
                problems = validate(draft, facts) + self._set_problems(draft) + problems
            if not problems:
                return draft
            log.info("  %s: draft of %s sent back: %s", common_name, what, "; ".join(problems))
        log.error("  %s: no %s after %d drafts (%s)", common_name, what, ATTEMPTS, "; ".join(problems))
        return None

    def _crowded(self) -> list[str]:
        """A note for the next request naming the openings the set already leans on, so a draft avoids them first time."""
        crowded = [phrase for phrase, count in self._openings.most_common() if phrase and count * 2 >= self._cap]
        if self._ask_why * 2 >= self._cap:
            crowded.append("ask why")
        return [f"Other cards of this set already begin often with: {', '.join(dict.fromkeys(crowded))}. Begin differently."] if crowded else []

    def _crowded_titles(self) -> list[str]:
        """The same for titles: the openings and closing words the set's titles already lean on."""
        notes = []
        if openings := [phrase for phrase, count in self._title_openings.most_common() if phrase and count * 2 >= self._cap]:
            notes.append(f"Other titles of this set already begin often with: {', '.join(openings)}. Begin the title differently.")
        if endings := [word for word, count in self._title_endings.most_common() if word and count * 2 >= self._cap]:
            notes.append(f"Other titles of this set already end often on: {', '.join(endings)}. End the title differently.")
        return notes

    def _set_problems(self, draft: dict) -> list[str]:
        """What the draft would overdo across the set: an opening, or "ask why", past `OPENING_SHARE` of it."""
        problems = []
        if self._openings[start := opening(draft)] >= self._cap:
            common = ", ".join(f'"{phrase}"' for phrase, count in self._openings.most_common(5) if count >= self._cap // 2)
            problems.append(f'{self._openings[start]} lore entries of this set already begin "{start}"; begin another way (much used: {common})')
        if ASK_WHY.search(_lore_text(draft)) and self._ask_why >= self._cap:
            problems.append('the set already has its share of "ask why"; frame the tale another way')
        return problems

    def _title_set_problems(self, title: dict) -> list[str]:
        """What the title would overdo across the set: an opening or a closing word past `OPENING_SHARE` of it."""
        problems = []
        if (start := title_opening(title)) and self._title_openings[start] >= self._cap:
            problems.append(f'{self._title_openings[start]} titles of this set already begin "{start}"; begin the title another way')
        if (end := title_ending(title)) and self._title_endings[end] >= self._cap:
            problems.append(f'{self._title_endings[end]} titles of this set already end on "{end}"; end the title another way')
        return problems

    def _complete(self, request: str, system: str = SYSTEM, schema: dict = SCHEMA) -> str:
        if self._client is None:
            self._client = self.client_factory()
        # Checked before a request rather than after, so a reply already paid for is never thrown away.
        if self.budget is not None and (spent := self.spent) is not None and spent > self.budget:
            raise LoreBudgetExceeded(f"spent ${spent:.2f}, past the ${self.budget:.2f} budget; what was written is locked")
        if self._last is not None and (wait := self.interval - (self.clock() - self._last)) > 0:
            self.sleep(wait)
        try:
            return self._client.complete(system, request, schema)
        finally:
            self._last = self.clock()
            self.requests += 1
            self.title_requests += schema is TITLE_SCHEMA

    @property
    def spent(self) -> float | None:
        """Dollars this run has spent, from the client's token counts; None for a client that keeps none."""
        tokens = (getattr(self._client, "input_tokens", None), getattr(self._client, "output_tokens", None))
        if None in tokens or self.model not in PRICES:
            return None
        prices = PRICES[self.model]
        return (tokens[0] * prices[0] + tokens[1] * prices[1]) / 1_000_000


def _cited_part(raw) -> dict:
    """A sentence, tagline or title from a reply, trimmed: {"text", "facts"}."""
    raw = raw if isinstance(raw, dict) else {}
    return {"text": str(raw.get("text", "")).strip(), "facts": list(raw.get("facts") or [])}


def review(
    lock: LoreLock, approve: list[str] = (), reject: list[str] = (), approve_all: bool = False, why: str | None = None,
    approve_titles: list[str] = (), reject_titles: list[str] = (), approve_all_titles: bool = False,
) -> None:
    """Records the maintainer's review: species named by id or common name. The lore's review and its title's are
    separate: approving or rejecting a title leaves the lore, its tagline and their review as they are, and the lore's
    leaves the title's."""
    for name in (*reject_titles, *approve_titles, *reject, *approve):
        entry = lock.species[_species_id(lock, name)]
        if pack_id := entry.get(SHARED_FROM):
            raise KeyError(
                f"{entry['common_name']}'s lore is shared from {pack_id}: review it there (`packbuilder lore-review packs/{pack_id}`), "
                "then run `packbuilder lore` on this pack to take the verdict"
            )
    for name in reject_titles:
        title = _title(lock, name)
        title["review"] = REJECTED
        if why:
            title["why"] = why
    for name in approve_titles:
        title = _title(lock, name)
        title["review"] = APPROVED
        title.pop("why", None)
    if approve_all_titles:
        for entry in lock.species.values():
            if entry.get("title") and entry["title"]["review"] == PENDING and not entry.get(SHARED_FROM):
                entry["title"]["review"] = APPROVED
    for name in reject:
        entry = lock.species[_species_id(lock, name)]
        entry["review"] = REJECTED
        if why:
            entry["why"] = why
    for name in approve:
        entry = lock.species[_species_id(lock, name)]
        entry["review"] = APPROVED
        entry.pop("why", None)
    if approve_all:
        for entry in lock.species.values():
            if entry["review"] == PENDING and not entry.get(SHARED_FROM):
                entry["review"] = APPROVED
    lock.write()


def _title(lock: LoreLock, name: str) -> dict:
    species_id = _species_id(lock, name)
    if not lock.species[species_id].get("title"):
        raise KeyError(f"no title in {lock.path} for {name!r} yet: build the pack or run `packbuilder lore` first")
    return lock.species[species_id]["title"]


def _species_id(lock: LoreLock, name: str) -> str:
    name = name.strip()
    if name in lock.species:
        return name
    for species_id, entry in lock.species.items():
        if entry["common_name"].lower() == name.lower():
            return species_id
    raise KeyError(f"no lore in {lock.path} for {name!r}")


def review_sheet(lock: LoreLock, path: Path, pack_name: str, order: list[str] | None = None) -> Path:
    """The review file: the set's titles together (to judge them as a set), then per species its state, title,
    tagline, lore and the facts each cites, in pack order."""
    ids = [species_id for species_id in (order or sorted(lock.species)) if species_id in lock.species]
    counts = {state: sum(lock.species[i]["review"] == state for i in ids) for state in (PENDING, APPROVED, REJECTED)}
    titles = {i: lock.species[i].get("title") for i in ids}
    title_counts = {state: sum(bool(t) and t["review"] == state for t in titles.values()) for state in (PENDING, APPROVED, REJECTED)}
    lines = [
        f"# {pack_name}: lore for review",
        "",
        f"{len(ids)} species: {counts[APPROVED]} approved, {counts[PENDING]} pending, {counts[REJECTED]} rejected. "
        "Each sentence is followed by the facts it cites. Approve or reject with `packbuilder lore-review`.",
        "",
        f"Titles: {title_counts[APPROVED]} approved, {title_counts[PENDING]} pending, {title_counts[REJECTED]} rejected, "
        f"{sum(not t for t in titles.values())} not written. Approve or reject them alone with `packbuilder lore-review "
        "--approve-title`, `--approve-all-titles` or `--reject-title`; the lore's review stays as it is.",
    ]
    shared = {i: lock.species[i][SHARED_FROM] for i in ids if lock.species[i].get(SHARED_FROM)}
    if shared:
        lines += [
            "", f"{len(shared)} of them share another pack's lore ({', '.join(f'{count} from {pack}' for pack, count in sorted(Counter(shared.values()).items()))}): "
            "it is reviewed in that pack, and `packbuilder lore` on this one takes the verdict.",
        ]
    if pending := [lock.species[i]["common_name"] for i in ids if lock.species[i]["review"] == PENDING and i not in shared]:
        lines += ["", f"Pending: {', '.join(pending)}."]
    if pending_titles := [lock.species[i]["common_name"] for i in ids if titles[i] and titles[i]["review"] == PENDING and i not in shared]:
        lines += ["", f"Titles pending: {', '.join(pending_titles)}."]
    if elsewhere := [f"{lock.species[i]['common_name']} ({shared[i]})" for i in shared if lock.species[i]["review"] == PENDING or (titles[i] and titles[i]["review"] == PENDING)]:
        lines += ["", f"Pending in the pack they are shared from: {', '.join(elsewhere)}."]
    if any(titles.values()):
        lines += ["", "## Titles", ""] + [
            f"- {lock.species[i]['common_name']}: {titles[i]['text']} ({titles[i]['review']})" if titles[i] else f"- {lock.species[i]['common_name']}: no title"
            for i in ids
        ]
    for species_id in ids:
        entry = lock.species[species_id]
        facts = {fact["id"]: fact for fact in entry["facts"]}
        lines += ["", f"## {entry['common_name']} ({entry['review']}{', shared from ' + entry[SHARED_FROM] if entry.get(SHARED_FROM) else ''})", ""]
        if title := entry.get("title"):
            lines.append(f"Title ({title['review']}): *{title['text']}* ({', '.join(title['facts'])})")
            for fact_id in title["facts"]:
                fact = facts.get(fact_id)
                lines.append(f"   - {fact_id}: {fact['text']} ({_source_name(fact['source'])})" if fact else f"   - {fact_id}: NOT ON THE SHEET")
            if title.get("why"):
                lines.append(f"   Title rejected: {title['why']}")
            lines.append("")
        lines += [f"**{entry['tagline']['text']}** ({', '.join(entry['tagline']['facts'])})", ""]
        lines.append(" ".join(sentence["text"] for sentence in entry["sentences"]))
        lines += ["", "Cited:"]
        for number, sentence in enumerate(entry["sentences"], start=1):
            lines.append(f"{number}. {sentence['text']}")
            for fact_id in sentence["facts"]:
                fact = facts.get(fact_id)
                lines.append(f"   - {fact_id}: {fact['text']} ({_source_name(fact['source'])})" if fact else f"   - {fact_id}: NOT ON THE SHEET")
        if entry.get("why"):
            lines += ["", f"Rejected: {entry['why']}"]
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")
    return path


def _source_name(source: str) -> str:
    return "Wikipedia" if source.startswith("http") else {"avonet": "AVONET", "birdbase": "BIRDBASE", "wingspan": "wingspan database"}.get(source, source)
