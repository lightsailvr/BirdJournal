import pytest

from packbuilder.licenses import (
    ALLOWED_LICENSES, audio_license_tier, audio_license_url, credit_line, normalize_audio_license, normalize_license, short_credit,
    sound_credit_line, sound_short_credit,
)


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


# Sounds (issue #41, option A): share-alike and NonCommercial are allowed, no-derivatives never (trimming a clip is an
# adaptation). The version is kept because SA terms differ by version.
@pytest.mark.parametrize(
    "raw, expected",
    [
        ("//creativecommons.org/licenses/by-nc-sa/4.0/", "CC BY-NC-SA 4.0"),
        ("https://creativecommons.org/licenses/by-sa/3.0/", "CC BY-SA 3.0"),
        ("//creativecommons.org/licenses/by/4.0/", "CC BY 4.0"),
        ("//creativecommons.org/licenses/by-nc/2.5/", "CC BY-NC 2.5"),
        ("//creativecommons.org/publicdomain/zero/1.0/", "CC0"),
        ("cc0", "CC0"),
        ("cc-by", "CC BY 4.0"),
        ("cc-by-sa", "CC BY-SA 4.0"),
        ("cc-by-nc", "CC BY-NC 4.0"),
    ],
)
def test_audio_licenses_normalize_with_their_version(raw, expected):
    assert normalize_audio_license(raw) == expected


@pytest.mark.parametrize(
    "raw",
    ["//creativecommons.org/licenses/by-nc-nd/4.0/", "//creativecommons.org/licenses/by-nd/2.5/", "cc-by-nd", "cc-by-nc-nd", "", None, "all rights reserved", "//example.org/licenses/by/4.0/"],
)
def test_no_derivatives_and_unknown_audio_licenses_are_refused(raw):
    assert normalize_audio_license(raw) is None


def test_open_audio_licenses_rank_ahead_of_noncommercial():
    assert audio_license_tier("CC0") == audio_license_tier("CC BY-SA 4.0") == audio_license_tier("CC BY 4.0") == 0
    assert audio_license_tier("CC BY-NC-SA 4.0") == audio_license_tier("CC BY-NC 4.0") == 1


def test_audio_license_deeds():
    assert audio_license_url("CC BY-NC-SA 4.0") == "https://creativecommons.org/licenses/by-nc-sa/4.0/"
    assert audio_license_url("CC0") == "https://creativecommons.org/publicdomain/zero/1.0/"


def test_xeno_canto_credit_names_recordist_catalogue_number_and_url():
    assert sound_credit_line("Jane Birder", "CC BY-NC-SA 4.0", "XC123456", "https://xeno-canto.org/123456") == "Jane Birder, XC123456, https://xeno-canto.org/123456 (CC BY-NC-SA 4.0)"
    assert sound_short_credit("Jane Birder", "XC123456") == "Sound: Jane Birder, XC123456"
