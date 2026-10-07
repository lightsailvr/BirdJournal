"""iNaturalist observation sounds (research grade, open licenses only: CC0, CC BY, CC BY-SA, as #41 asks) as the
fallback for a species xeno-canto left without any clip (issue #41). iNaturalist does not type a sound as song or
call, so its clips are the untyped `sound` kind. The API asks for about one request per second; searches and file
downloads share one pacer at that rate, and both are cached."""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from urllib.parse import urlparse

import requests

from packbuilder.definition import SpeciesEntry
from packbuilder.http import Pacer, session as shared_session
from packbuilder.licenses import audio_license_tier, normalize_audio_license
from packbuilder.metadata_api import API, USER_AGENT
from packbuilder.sounds import SoundCandidate

UNITED_STATES = 1
SOUND_LICENSES = "cc0,cc-by,cc-by-sa"

log = logging.getLogger("packbuilder")


class INaturalistSoundSource:
    name = "inaturalist"

    def __init__(self, cache_dir: Path, place_id: int = UNITED_STATES, session=None, pacer: Pacer | None = None):
        self.cache_dir = Path(cache_dir)
        self.place_id = place_id
        self.session = session or shared_session()
        self.pacer = pacer or Pacer(1.0, minimum=1.0)

    def candidates_for(self, entry: SpeciesEntry) -> list[SoundCandidate]:
        cache_file = self.cache_dir / "api" / f"taxon-{entry.inat_taxon_id}-place-{self.place_id}.json"
        if cache_file.exists():
            payload = json.loads(cache_file.read_text())
        else:
            self.pacer.wait()
            response = self.session.get(
                API,
                params={
                    "taxon_id": entry.inat_taxon_id, "place_id": self.place_id, "sounds": "true", "sound_license": SOUND_LICENSES,
                    "quality_grade": "research", "order_by": "created_at", "order": "desc", "per_page": 50,
                },
                headers={"User-Agent": USER_AGENT}, timeout=60,
            )
            response.raise_for_status()
            payload = response.json()
            cache_file.parent.mkdir(parents=True, exist_ok=True)
            cache_file.write_text(json.dumps(payload))
        country = "United States" if self.place_id == UNITED_STATES else None
        return [c for observation in payload.get("results", []) for c in _candidates_in(observation, country)]

    def fetch(self, candidate: SoundCandidate) -> Path | None:
        target = self.cache_dir / "files" / f"{candidate.id}.{candidate.extension}"
        if target.exists():
            return target
        target.parent.mkdir(parents=True, exist_ok=True)
        self.pacer.wait()
        try:
            with self.session.get(candidate.file_url, headers={"User-Agent": USER_AGENT}, timeout=120, stream=True) as response:
                response.raise_for_status()
                partial = target.with_suffix(f"{target.suffix}.{os.getpid()}.download")
                with partial.open("wb") as handle:
                    for chunk in response.iter_content(1 << 20):
                        handle.write(chunk)
        except requests.HTTPError as error:
            log.warning("  %s unavailable: %s", candidate.id, error)
            return None
        partial.replace(target)
        return target


def _candidates_in(observation: dict, country: str | None) -> list[SoundCandidate]:
    user = observation.get("user") or {}
    recordist = (user.get("name") or user.get("login") or "").strip()
    out = []
    for sound in observation.get("sounds") or []:
        license = normalize_audio_license(sound.get("license_code"))
        url = sound.get("file_url")
        # The cached answer of an older build may hold NonCommercial sounds; the fallback takes open licenses only.
        if license is None or audio_license_tier(license) or not recordist or not url or sound.get("id") is None:
            continue
        name = urlparse(url).path.rsplit("/", 1)[-1]
        out.append(
            SoundCandidate(
                id=f"inat-{sound['id']}", source="inaturalist", catalogue=f"iNaturalist sound {sound['id']}", kind=None, file_url=url,
                extension=name.rsplit(".", 1)[-1].lower() if "." in name else "mp3", recordist=recordist, license=license,
                source_url=f"https://www.inaturalist.org/observations/{observation['id']}", recorded=observation.get("observed_on"),
                country=country,
            )
        )
    return out
