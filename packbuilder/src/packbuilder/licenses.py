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
    """The one-line credit for the lens description page (budgeted at eight words there)."""
    return f"Photo: {observer}, {license}"
