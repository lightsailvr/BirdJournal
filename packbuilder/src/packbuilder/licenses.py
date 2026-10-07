"""Photo licenses the pack may redistribute (DECISIONS.md, "Species pack") and the credit lines they require."""

from __future__ import annotations

# Canonical spellings, as stored in the pack.
CC0 = "CC0"
CC_BY = "CC BY"
CC_BY_NC = "CC BY-NC"

ALLOWED_LICENSES: frozenset[str] = frozenset({CC0, CC_BY, CC_BY_NC})

_SPELLINGS = {
    "cc0": CC0,
    "cc-by": CC_BY,
    "cc by": CC_BY,
    "cc-by-nc": CC_BY_NC,
    "cc by-nc": CC_BY_NC,
}


def normalize_license(raw: str | None) -> str | None:
    """The canonical allowed license for an iNaturalist spelling (`cc-by-nc` from the API, `CC-BY-NC` in the Open
    Data CSVs), or None for anything the pack may not carry: share-alike, no-derivatives, all rights reserved,
    unknown."""
    if raw is None:
        return None
    return _SPELLINGS.get(raw.strip().lower())


def credit_line(observer: str, license: str) -> str:
    """The attribution statement iNaturalist Open Data asks for, e.g. "© Name, some rights reserved (CC BY-NC)"."""
    if license == CC0:
        return f"{observer}, no rights reserved (CC0)"
    return f"© {observer}, some rights reserved ({license})"


def short_credit(observer: str, license: str) -> str:
    """The one-line credit on the lens species card (budgeted at eight words there)."""
    return f"Photo: {observer}, {license}"


# Sounds (issue #41, option A in DECISIONS.md): CC0, CC BY and CC BY-SA preferred, CC BY-NC and CC BY-NC-SA as the
# fallback (the posture the photos took with CC BY-NC), no-derivatives never: the pack trims, filters and re-encodes
# every clip, which is an adaptation. Share-alike clips stay under their own license in the pack LICENSE. Unlike the
# photos, the version is kept (xeno-canto carries 2.5, 3.0 and 4.0), because the share-alike terms differ by version.
_AUDIO_FAMILIES = {"by": "CC BY", "by-sa": "CC BY-SA", "by-nc": "CC BY-NC", "by-nc-sa": "CC BY-NC-SA"}
# iNaturalist names a license without a version; its current terms are 4.0.
_INAT_AUDIO = {"cc0": "CC0", "cc-by": "CC BY 4.0", "cc-by-sa": "CC BY-SA 4.0", "cc-by-nc": "CC BY-NC 4.0", "cc-by-nc-sa": "CC BY-NC-SA 4.0"}


def normalize_audio_license(raw: str | None) -> str | None:
    """The canonical license of a sound ("CC BY-NC-SA 4.0", "CC0") from a xeno-canto license URL
    (`//creativecommons.org/licenses/by-nc-sa/4.0/`) or an iNaturalist code (`cc-by-sa`), or None for anything the
    pack may not carry: no-derivatives, all rights reserved, unknown."""
    if not raw:
        return None
    value = raw.strip().lower()
    if value in _INAT_AUDIO:
        return _INAT_AUDIO[value]
    path = value.split("creativecommons.org/", 1)
    if len(path) != 2:
        return None
    parts = [p for p in path[1].split("/") if p]
    if parts[:2] == ["publicdomain", "zero"]:
        return CC0
    if len(parts) >= 3 and parts[0] == "licenses" and parts[1] in _AUDIO_FAMILIES:
        return f"{_AUDIO_FAMILIES[parts[1]]} {parts[2]}"
    return None


def audio_license_tier(license: str) -> int:
    """0 for the open licenses the pack prefers, 1 for the NonCommercial fallback."""
    return 1 if "-NC" in license else 0


def audio_license_url(license: str) -> str:
    """The Creative Commons deed of a canonical audio license."""
    if license == CC0:
        return "https://creativecommons.org/publicdomain/zero/1.0/"
    family, version = license.rsplit(" ", 1)
    return f"https://creativecommons.org/licenses/{family.removeprefix('CC ').lower()}/{version}/"


def sound_credit_line(recordist: str, license: str, catalogue: str, source_url: str) -> str:
    """The attribution xeno-canto asks for, recordist, catalogue number and the stable URL, with the license:
    "Name, XC123456, https://xeno-canto.org/123456 (CC BY-NC-SA 4.0)"."""
    return f"{recordist}, {catalogue}, {source_url} ({license})"


def sound_short_credit(recordist: str, catalogue: str) -> str:
    """The one-line credit beside a play control: "Sound: Name, XC123456"."""
    return f"Sound: {recordist}, {catalogue}"
