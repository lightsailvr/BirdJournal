"""Lore (issue #56, CONTEXT.md "Lore"): a species' short myth-voiced text built from its fact sheet, written once per
pack by a Claude model through the Anthropic API, reviewed by hand and pinned in `lore.lock.json` beside the pack
definition.

Each species gets 50 to 80 words of lore in a legend's voice and a tagline of 12 words or fewer. Every sentence, and
the tagline, names the fact-sheet entries it rests on (`f1`, `f2`, ...); a draft that cites nothing, cites a fact the
sheet lacks or misses the word counts is sent back with what was wrong, up to `ATTEMPTS` times.

The lock pins per species the facts the lore was written from (the pack ships those, so lore and fact sheet always
agree), the sentences with their citations, the tagline, the model, the prompt version and the review:

- `pending`: written, not reviewed yet. Only `approved` lore goes into the pack.
- `approved`: in the pack.
- `rejected`: written again by the next build, with the maintainer's reason in the prompt.

A warm lock makes no API call and needs no key. Lore is written again only on request: a rejection, or
`packbuilder build --regenerate-lore`. A fact sheet that changed since its lore was written (the Wikipedia revision
moved, a stats fix) is logged and keeps the locked facts and lore until the lore is regenerated.

The key is read from `BIRDJOURNAL_ANTHROPIC_API_KEY` (never `ANTHROPIC_API_KEY`, which would switch Claude Code itself
to API billing), else from the login Keychain item `birdjournal-anthropic-api-key`, and passed to the client; it is
never logged or written anywhere. A key the API refuses stops the run at once, before anything is locked.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Protocol

from packbuilder.factsheet import Fact

log = logging.getLogger("packbuilder.lore")

LOCK_FILE = "lore.lock.json"
PENDING, APPROVED, REJECTED = "pending", "approved", "rejected"
API_KEY_VARIABLE = "BIRDJOURNAL_ANTHROPIC_API_KEY"
KEYCHAIN_SERVICE = "birdjournal-anthropic-api-key"
MODEL = "claude-opus-5-5"
"""DECISIONS.md, "Lore and captions": the current Opus, for the voice; a pack of 160 species costs a few dollars."""
PROMPT_VERSION = 3
ATTEMPTS = 3
PRICES = {"claude-opus-5-5": (4.0, 20.0), "claude-sonnet-5-5": (2.0, 10.0)}
"""Dollars per million input and output tokens, for the run's spend and its budget."""
DEFAULT_INTERVAL = 2.0
"""Seconds between API requests: the step is paced like the other network steps, one request at a time."""
LORE_WORDS = (50, 80)
TAGLINE_WORDS = 12
MAX_NUMBERS = 1
NUMBER = re.compile(
    r"\b(\d[\d,.]*|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|"
    r"eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundreds?|thousands?|millions?|dozens?)\b",
    re.IGNORECASE,
)
"""Numbers in figures or words; "one" is left out, as prose uses it for other things. "twenty-six" counts once."""
ALL = "all"

SYSTEM = """You write the lore on the back of collectible bird cards: true natural history told as a small legend.

Write 50 to 80 words of lore about one species and a tagline of 12 words or fewer for the card's front.

Tell it as a small myth: a "why it does this" tale, or the way a legend speaks of a creature ("So it is that...", \
"Ask why the..."). Choose one or two things the bird does and build the tale around them. Lead with how it lives: where \
it keeps, how it hunts, what it builds, how it sounds.

The only facts you may use are the numbered entries of the species' fact sheet. Prefer the article's facts; the \
datasets' entries are coarse category labels, so use one only where the article says nothing on that point. Use at \
most one number in the whole lore, and none in the tagline. Every claim about the bird must be on the sheet: no \
behaviour, food, colour, number, place, season or sound of your own. The legend lives in the telling (the framing, the \
cadence, the epithets), never in new facts. A "why" may join two facts only when it is signposted as the tale's own \
telling ("the tale answers", "they say", "so the story goes"); never state a cause the sheet does not give as fact. \
Do not name gods, peoples or real people unless the sheet does.

Every sentence of the lore, and the tagline, lists the ids of the fact-sheet entries it rests on; each sentence rests on \
at least one. Use plain words a ten-year-old could read aloud; no archaic spellings."""

SCHEMA = {
    "type": "object",
    "properties": {
        "sentences": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "facts": {"type": "array", "items": {"type": "string"}}},
                "required": ["text", "facts"],
                "additionalProperties": False,
            },
        },
        "tagline": {
            "type": "object",
            "properties": {"text": {"type": "string"}, "facts": {"type": "array", "items": {"type": "string"}}},
            "required": ["text", "facts"],
            "additionalProperties": False,
        },
    },
    "required": ["sentences", "tagline"],
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

    @property
    def ships(self) -> bool:
        return self.review == APPROVED

    @property
    def text(self) -> str:
        return " ".join(sentence["text"] for sentence in self.sentences)

    @property
    def sources(self) -> list[str]:
        """The distinct sources of the facts it cites, in sheet order: the Wikipedia revision and the datasets."""
        cited = {fact_id for sentence in (*self.sentences, self.tagline) for fact_id in sentence["facts"]}
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


def _numbers(text: str) -> list[str]:
    """Each number in the text once: "twenty-six" and "four hundred" are one number each."""
    return re.findall(r"(?:%s)(?:[\s-]+(?:%s))*" % (NUMBER.pattern, NUMBER.pattern), text, flags=re.IGNORECASE)


def prompt(common_name: str, scientific_name: str, facts: list[Fact] | tuple[Fact, ...], feedback: list[str] | tuple[str, ...] = ()) -> str:
    """The request for one species: its names and its fact sheet, then what the maintainer or the checks sent back."""
    lines = [f"Species: {common_name} ({scientific_name})"]
    article = [fact for fact in facts if fact.source.startswith("http")]
    datasets = [fact for fact in facts if not fact.source.startswith("http")]
    if article:
        lines += ["", "Fact sheet, from its Wikipedia article:"] + [f"{fact.id}: {fact.text}" for fact in article]
    if datasets:
        lines += ["", "Fact sheet, from the datasets (coarse labels):"] + [f"{fact.id}: {fact.text}" for fact in datasets]
    if feedback:
        lines += ["", "Your previous draft was sent back. Fix this:"] + [f"- {item}" for item in feedback]
    return "\n".join(lines)


class LoreLock:
    """`lore.lock.json`: per species id, the facts, the lore and its review (see the module)."""

    COMMENT = (
        "Lore (issue #56), written by `packbuilder build` and `packbuilder lore-review`; read it in build/lore/<pack id>/review.md. "
        "Per species: the fact sheet the lore was written from (shipped with it), the sentences with the fact ids each rests on, "
        "the tagline, the model and prompt version, and the review: pending, approved (in the pack) or rejected (written again "
        "by the next build, with the reason)."
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


def lore_from_entry(species_id: str, entry: dict) -> Lore:
    return Lore(species_id, entry["review"], tuple(entry["sentences"]), entry["tagline"], tuple(Fact.from_dict(f) for f in entry["facts"]), entry.get("model", MODEL))


@dataclass
class LoreWriter:
    """Writes what the lock lacks for one pack and keeps the lock. `client` is made on the first request, so a warm
    lock needs no key; `regenerate` names species ids (or `ALL`) to write again."""

    lock: LoreLock
    client_factory: Callable[[], LoreClient]
    model: str = MODEL
    regenerate: frozenset[str] = frozenset()
    interval: float = DEFAULT_INTERVAL
    budget: float | None = None
    """Dollars this run may spend (by `PRICES`); no request starts once it is spent, so a run ends at most one
    request past it."""
    sleep: Callable[[float], None] = time.sleep
    clock: Callable[[], float] = time.monotonic
    requests: int = field(default=0, init=False)

    def __post_init__(self):
        self._client: LoreClient | None = None
        self._last: float | None = None

    def write(self, species: list[tuple[str, str, str]], sheets: dict[str, list[Fact]]) -> dict[str, Lore]:
        """Each species' lore, by id, for (id, common name, scientific name) in pack order; a species whose lore could
        not be written is left out (and logged). The lock is written after each species, so an interrupted run resumes."""
        written: dict[str, Lore] = {}
        for species_id, common_name, scientific_name in species:
            facts = sheets.get(species_id) or []
            entry = self.lock.species.get(species_id)
            wanted = ALL in self.regenerate or species_id in self.regenerate
            if entry is not None and not wanted and entry["review"] != REJECTED:
                if problems := validate(entry, [Fact.from_dict(f) for f in entry["facts"]]):
                    raise InvalidLore(f"{self.lock.path}: {common_name}'s locked lore fails its checks: {'; '.join(problems)}")
                if [fact.as_dict() for fact in facts] != entry["facts"]:
                    log.warning("  %s: the fact sheet changed since its lore was written; the locked facts and lore stay (--regenerate-lore to rewrite)", common_name)
                written[species_id] = lore_from_entry(species_id, entry)
                continue
            if not facts:
                log.warning("  %s has no fact sheet; no lore", common_name)
                continue
            feedback = [f"The maintainer rejected it: {entry['why']}"] if entry and entry["review"] == REJECTED and entry.get("why") else []
            draft = self._draft(common_name, scientific_name, facts, feedback)
            if draft is None:
                continue
            self.lock.species[species_id] = {
                "common_name": common_name, "model": self.model, "prompt_version": PROMPT_VERSION,
                "facts": [fact.as_dict() for fact in facts], "sentences": draft["sentences"], "tagline": draft["tagline"], "review": PENDING,
            }
            self.lock.write()
            written[species_id] = lore_from_entry(species_id, self.lock.species[species_id])
        if (usage := getattr(self._client, "input_tokens", None)) is not None:
            log.info("lore: %d input and %d output tokens, $%.2f", usage, self._client.output_tokens, self.spent or 0)
        log.info("lore: %d requests, %d approved, %d to review", self.requests, sum(l.ships for l in written.values()), sum(l.review == PENDING for l in written.values()))
        return written

    def _draft(self, common_name: str, scientific_name: str, facts: list[Fact], feedback: list[str]) -> dict | None:
        problems: list[str] = []
        for _ in range(ATTEMPTS):
            try:
                reply = self._complete(prompt(common_name, scientific_name, facts, feedback + problems))
            except LoreTruncated:
                problems = ["the reply was cut off; keep the lore and your thinking short"]
                continue
            except LoreRefused as refusal:
                log.error("  %s: the model declined to write lore (%s); no lore", common_name, refusal)
                return None
            try:
                draft = json.loads(reply)
            except json.JSONDecodeError:
                problems = ["the reply was not the JSON asked for"]
                continue
            draft = {
                "sentences": [{"text": s.get("text", "").strip(), "facts": list(s.get("facts") or [])} for s in draft.get("sentences") or []],
                "tagline": {"text": (draft.get("tagline") or {}).get("text", "").strip(), "facts": list((draft.get("tagline") or {}).get("facts") or [])},
            }
            problems = validate(draft, facts)
            if not problems:
                return draft
            log.info("  %s: draft sent back: %s", common_name, "; ".join(problems))
        log.error("  %s: no lore after %d drafts (%s)", common_name, ATTEMPTS, "; ".join(problems))
        return None

    def _complete(self, request: str) -> str:
        if self._client is None:
            self._client = self.client_factory()
        # Checked before a request rather than after, so a reply already paid for is never thrown away.
        if self.budget is not None and (spent := self.spent) is not None and spent > self.budget:
            raise LoreBudgetExceeded(f"spent ${spent:.2f}, past the ${self.budget:.2f} budget; what was written is locked")
        if self._last is not None and (wait := self.interval - (self.clock() - self._last)) > 0:
            self.sleep(wait)
        try:
            return self._client.complete(SYSTEM, request, SCHEMA)
        finally:
            self._last = self.clock()
            self.requests += 1

    @property
    def spent(self) -> float | None:
        """Dollars this run has spent, from the client's token counts; None for a client that keeps none."""
        tokens = (getattr(self._client, "input_tokens", None), getattr(self._client, "output_tokens", None))
        if None in tokens or self.model not in PRICES:
            return None
        prices = PRICES[self.model]
        return (tokens[0] * prices[0] + tokens[1] * prices[1]) / 1_000_000


def review(lock: LoreLock, approve: list[str] = (), reject: list[str] = (), approve_all: bool = False, why: str | None = None) -> None:
    """Records the maintainer's review: species named by id or common name."""
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
            if entry["review"] == PENDING:
                entry["review"] = APPROVED
    lock.write()


def _species_id(lock: LoreLock, name: str) -> str:
    name = name.strip()
    if name in lock.species:
        return name
    for species_id, entry in lock.species.items():
        if entry["common_name"].lower() == name.lower():
            return species_id
    raise KeyError(f"no lore in {lock.path} for {name!r}")


def review_sheet(lock: LoreLock, path: Path, pack_name: str, order: list[str] | None = None) -> Path:
    """The review file: per species its state, tagline, lore and the facts each sentence cites, in pack order."""
    ids = [species_id for species_id in (order or sorted(lock.species)) if species_id in lock.species]
    counts = {state: sum(lock.species[i]["review"] == state for i in ids) for state in (PENDING, APPROVED, REJECTED)}
    lines = [
        f"# {pack_name}: lore for review",
        "",
        f"{len(ids)} species: {counts[APPROVED]} approved, {counts[PENDING]} pending, {counts[REJECTED]} rejected. "
        "Each sentence is followed by the facts it cites. Approve or reject with `packbuilder lore-review`.",
    ]
    for species_id in ids:
        entry = lock.species[species_id]
        facts = {fact["id"]: fact for fact in entry["facts"]}
        lines += ["", f"## {entry['common_name']} ({entry['review']})", "", f"**{entry['tagline']['text']}** ({', '.join(entry['tagline']['facts'])})", ""]
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
