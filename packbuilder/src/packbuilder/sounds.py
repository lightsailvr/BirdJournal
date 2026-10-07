"""Reference sounds for the species card (issue #41): one song and one call per species, chosen from xeno-canto first
and iNaturalist when xeno-canto has nothing usable, trimmed to an 8 s clip and kept only when BirdNET names the
species in it.

The sources (`SoundSource`), the downloader, the clip maker and the BirdNET check are seams, so the choice is tested
without the network, ffmpeg or the model. Every remote request goes through a paced, capped client (`xenocanto.py`,
`sounds_inat.py`), and `sounds.lock.json` beside the pack definition records each chosen recording with its credit, so
a rebuild fetches only the chosen files and never searches again.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path
from typing import Protocol

from packbuilder.definition import SpeciesEntry
from packbuilder.licenses import audio_license_tier, sound_credit_line, sound_short_credit

log = logging.getLogger("packbuilder")

SONG, CALL, SOUND = "song", "call", "sound"
"""Clip kinds. `sound` is a recording its source does not type (iNaturalist), used only when xeno-canto gave the
species neither a song nor a call."""

KINDS = (SONG, CALL)
LENGTH_RANGE = (5.0, 60.0)
"""Recordings this long are preferred: long enough for an 8 s window, short enough to download lightly."""
QUALITY_ORDER = {"A": 0, "B": 1, "C": 2, "D": 3, "E": 4}


@dataclass(frozen=True)
class SoundCandidate:
    id: str
    """Pack-wide id: `xc-<nr>` or `inat-<sound id>`."""
    source: str
    catalogue: str
    """What the credit names the recording by: "XC573469", "iNaturalist sound 123"."""
    kind: str | None
    file_url: str
    extension: str
    recordist: str
    license: str
    """Canonical (`licenses.normalize_audio_license`); a candidate without an allowed license is never made."""
    source_url: str
    quality: str | None = None
    """xeno-canto's A (best) to E, None when unrated or from iNaturalist."""
    length_seconds: float | None = None
    recorded: str | None = None
    country: str | None = None
    background_species: int = 0

    @property
    def credit_line(self) -> str:
        return sound_credit_line(self.recordist, self.license, self.catalogue, self.source_url)

    @property
    def short_credit(self) -> str:
        return sound_short_credit(self.recordist, self.catalogue)

    def to_json(self) -> dict:
        return asdict(self)

    @classmethod
    def from_json(cls, data: dict) -> "SoundCandidate":
        return cls(**data)


class SoundSource(Protocol):
    name: str
    """`SoundCandidate.source` of its candidates."""

    def candidates_for(self, entry: SpeciesEntry) -> list[SoundCandidate]: ...

    def fetch(self, candidate: SoundCandidate) -> Path | None:
        """Downloads a candidate's file into the cache through the source's paced client; None when the file is gone."""
        ...


def rank_sounds(candidates: list[SoundCandidate], kind: str, country: str | None = None) -> list[SoundCandidate]:
    """The candidates of `kind`, best first: graded A or B before the rest, then open licenses before NonCommercial,
    then the better grade, then MP3 (a fraction of a WAV's download), then 5 to 60 s long, then no other species in the
    background, then the pack's country, then the newest."""

    def key(c: SoundCandidate):
        quality = QUALITY_ORDER.get(c.quality or "", 5)
        in_range = c.length_seconds is not None and LENGTH_RANGE[0] <= c.length_seconds <= LENGTH_RANGE[1]
        return (
            quality > QUALITY_ORDER["B"], audio_license_tier(c.license), quality, c.extension.lower() != "mp3", not in_range,
            c.background_species > 0, country is not None and c.country != country, _negated_date(c.recorded),
        )

    return sorted((c for c in candidates if c.kind == kind), key=key)


def _negated_date(date: str | None) -> tuple:
    """Sorts newest first; an unknown date last."""
    if not date:
        return (1,)
    return (0, tuple(-int(part) if part.isdigit() else 0 for part in date.split("-")))


@dataclass(frozen=True)
class SoundOverrides:
    """The `sounds` object of a species in `overrides.json`: `song` / `call` pin a recording id ahead of the ranking,
    `exclude` ids are never chosen, `xeno_canto_name` is the scientific name xeno-canto files the species under when it
    differs from BirdNET's (read by the CLI into the xeno-canto source's names), `accept` names the species BirdNET may hear instead (the other half of a split BirdNET+
    carries both of, e.g. Numenius phaeopus for Numenius hudsonicus)."""

    song: str | None = None
    call: str | None = None
    exclude: frozenset[str] = frozenset()
    xeno_canto_name: str | None = None
    accept: frozenset[str] = frozenset()

    def pinned(self, kind: str) -> str | None:
        return {SONG: self.song, CALL: self.call}.get(kind)

    @classmethod
    def from_mapping(cls, data: dict | None) -> "SoundOverrides":
        data = data or {}
        return cls(
            song=data.get("song"), call=data.get("call"), exclude=frozenset(data.get("exclude", [])), xeno_canto_name=data.get("xeno_canto_name"),
            accept=frozenset(data.get("accept", [])),
        )


@dataclass(frozen=True)
class Clip:
    path: Path
    duration_ms: int


@dataclass(frozen=True)
class ChosenSound:
    candidate: SoundCandidate
    kind: str
    clip: Clip
    score: float
    """BirdNET's mean score for the species over the clip's windows."""

    @property
    def id(self) -> str:
        return self.candidate.id


@dataclass
class SoundResult:
    sounds: list[ChosenSound] = field(default_factory=list)
    """Song first, then call (or the one untyped sound)."""
    rejections: list[dict] = field(default_factory=list)
    """{"id", "kind", "reason"} for every candidate tried and refused."""

    @property
    def gap(self) -> bool:
        return not self.sounds


class ClipMaker(Protocol):
    def make(self, source: Path, target: Path) -> Clip: ...


class SpeciesCheck(Protocol):
    def check(self, clip: Path, scientific_name: str) -> tuple[bool, float, str]:
        """(the species is BirdNET's top prediction, its mean score, the top species' name)."""
        ...


class SoundLock:
    """`packbuilder/packs/<id>/sounds.lock.json` (committed): species → kind → the chosen recording with its credit. A locked
    recording is used without a search, so a rebuild, even from a clean cache, asks the sources for nothing but the
    chosen files; a lock entry that no longer passes is replaced by a search and the diff shows it."""

    def __init__(self, path: Path | None):
        self.path = path
        self.entries: dict[str, dict[str, dict]] = json.loads(path.read_text()) if path and path.exists() else {}
        self._used: dict[str, dict[str, dict]] = {}

    def get(self, scientific_name: str, kind: str) -> SoundCandidate | None:
        data = self.entries.get(scientific_name, {}).get(kind)
        return SoundCandidate.from_json(data) if data else None

    def record(self, scientific_name: str, chosen: list[ChosenSound]) -> None:
        self._used[scientific_name] = {sound.kind: sound.candidate.to_json() for sound in chosen}

    def write(self) -> None:
        """Writes the recordings this build chose (a species without a clip drops out)."""
        if self.path is None:
            return
        self.path.write_text(json.dumps(dict(sorted(self._used.items())), indent=2, ensure_ascii=False) + "\n")


@dataclass
class SoundPicker:
    """Chooses a species' clips. `sources` are asked in order, and a later source only for a species the earlier ones
    left without any clip, so iNaturalist sees a request only where xeno-canto had nothing usable."""

    sources: list[SoundSource]
    clips: ClipMaker
    check: SpeciesCheck
    clip_dir: Path
    lock: SoundLock = field(default_factory=lambda: SoundLock(None))
    country: str | None = None
    max_tries: int = 3
    """Downloads per kind before the kind is a gap: each try is a request to the source."""

    def pick(self, entry: SpeciesEntry, overrides: SoundOverrides = SoundOverrides()) -> SoundResult:
        result = SoundResult()
        for kind in KINDS:
            locked = self.lock.get(entry.scientific_name, kind)
            if locked is not None and locked.id not in overrides.exclude and overrides.pinned(kind) in (None, locked.id):
                source = self._source_of(locked)
                chosen = self._try(entry, kind, locked, source, result, overrides) if source else None
                if chosen:
                    result.sounds.append(chosen)
                    continue
                log.warning("  locked %s %s no longer passes; searching", kind, locked.id)
        missing = [kind for kind in KINDS if kind not in {s.kind for s in result.sounds}]
        for index, source in enumerate(self.sources):
            if not missing or (index > 0 and result.sounds):
                break
            candidates = [c for c in source.candidates_for(entry) if c.id not in overrides.exclude]
            kinds = missing if index == 0 else [SOUND]
            for kind in kinds:
                ranked = rank_sounds([_as_kind(c, kind) for c in candidates], kind, self.country)
                pinned = overrides.pinned(kind)
                if pinned:
                    ranked.sort(key=lambda c: c.id != pinned)
                for candidate in ranked[: self.max_tries]:
                    chosen = self._try(entry, kind, candidate, source, result, overrides)
                    if chosen:
                        result.sounds.append(chosen)
                        break
            missing = [kind for kind in KINDS if kind not in {s.kind for s in result.sounds}]
        result.sounds.sort(key=lambda s: (SONG, CALL, SOUND).index(s.kind))
        self.lock.record(entry.scientific_name, result.sounds)
        return result

    def _source_of(self, candidate: SoundCandidate) -> SoundSource | None:
        return next((source for source in self.sources if source.name == candidate.source), None)

    def _try(self, entry: SpeciesEntry, kind: str, candidate: SoundCandidate, source: SoundSource, result: SoundResult, overrides: SoundOverrides) -> ChosenSound | None:
        def reject(reason: str) -> None:
            result.rejections.append({"id": candidate.id, "kind": kind, "reason": reason})
            log.info("  %s %s rejected: %s", kind, candidate.id, reason)

        original = source.fetch(candidate)
        if original is None:
            reject("unavailable")
            return None
        try:
            clip = self.clips.make(original, self.clip_dir / f"{candidate.id}.m4a")
        except Exception as error:  # a file ffmpeg cannot decode is one bad recording, not a failed build
            reject(f"undecodable: {error}")
            return None
        passed, score, top = self.check.check(clip.path, entry.birdnet_label)
        if not passed and top not in overrides.accept:
            reject(f"BirdNET heard {top}")
            return None
        log.info("  %s %s  score %.2f  %s", kind, candidate.id, score, candidate.credit_line)
        return ChosenSound(candidate=candidate, kind=kind, clip=clip, score=score)


def _as_kind(candidate: SoundCandidate, kind: str) -> SoundCandidate:
    """An untyped candidate offered as the untyped `sound` kind."""
    if kind == SOUND and candidate.kind is None:
        return replace(candidate, kind=SOUND)
    return candidate
