import pytest

from packbuilder.licenses import ALLOWED_LICENSES, credit_line, normalize_license, short_credit


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("cc0", "CC0"),
        ("CC0", "CC0"),
        ("cc-by", "CC BY"),
        ("CC-BY", "CC BY"),
        ("CC BY", "CC BY"),
        ("cc-by-nc", "CC BY-NC"),
        ("CC-BY-NC", "CC BY-NC"),
    ],
)
def test_allowed_spellings_normalize(raw, expected):
    assert normalize_license(raw) == expected
    assert expected in ALLOWED_LICENSES


@pytest.mark.parametrize("raw", ["cc-by-sa", "CC-BY-SA", "cc-by-nd", "cc-by-nc-sa", "cc-by-nc-nd", "", None, "all rights reserved", "pd"])
def test_disallowed_licenses_normalize_to_none(raw):
    assert normalize_license(raw) is None


def test_credit_lines_follow_inaturalist_format():
    assert credit_line("Jane Birder", "CC0") == "Jane Birder, no rights reserved (CC0)"
    assert credit_line("Jane Birder", "CC BY-NC") == "© Jane Birder, some rights reserved (CC BY-NC)"


def test_short_credit_fits_one_lens_line():
    assert short_credit("Jane Birder", "CC BY") == "Photo: Jane Birder, CC BY"
    assert short_credit("jbirder", "CC0") == "Photo: jbirder, CC0"
