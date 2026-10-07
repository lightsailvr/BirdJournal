"""The clip maker (ffmpeg) and the BirdNET check, on synthetic audio. Skipped without ffmpeg; the check's model test
runs only when the models are downloaded."""

import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

from packbuilder import audio

pytestmark = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
MODELS = Path(__file__).resolve().parents[2] / "models"


def write_wav(path, samples, rate=44100):
    pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "s16le", "-ar", str(rate), "-ac", "1", "-i", "-", str(path)], input=pcm, check=True,
    )
    return path


def tone_burst(seconds=30.0, burst=(12.0, 20.0), rate=44100):
    """Quiet noise with a loud 3 kHz tone between `burst` seconds."""
    t = np.arange(int(seconds * rate)) / rate
    rng = np.random.default_rng(1)
    samples = 0.01 * rng.standard_normal(t.size)
    loud = (t >= burst[0]) & (t < burst[1])
    samples[loud] += 0.5 * np.sin(2 * np.pi * 3000 * t[loud])
    return samples


def test_loudest_window_finds_the_burst():
    rate = 32000
    samples = np.zeros(30 * rate, dtype=np.float32)
    samples[12 * rate:20 * rate] = 0.5
    assert audio.loudest_window(samples, rate, 8.0) == pytest.approx(12.0, abs=0.25)


def test_loudest_window_of_a_short_recording_is_its_start():
    assert audio.loudest_window(np.ones(32000 * 5, dtype=np.float32), 32000, 8.0) == 0.0


def test_clip_is_eight_seconds_of_mono_48k_aac_around_the_loudest_part(tmp_path):
    source = write_wav(tmp_path / "in.wav", tone_burst())

    clip = audio.ClipMaker().make(source, tmp_path / "clips" / "xc-1.m4a")

    assert clip.path.exists() and clip.path.suffix == ".m4a"
    assert 7800 <= clip.duration_ms <= 8200
    probe = audio.probe(clip.path)
    assert probe["codec_name"] == "aac" and int(probe["channels"]) == 1 and int(probe["sample_rate"]) == 48000
    assert clip.path.stat().st_size < 100_000, "about 65 KB at 64 kbps"
    decoded = audio.decode(clip.path, 32000)
    middle = np.abs(decoded[32000 * 2:32000 * 6]).mean()
    assert middle > 0.05, "the burst, not the quiet noise, was kept"
    assert np.abs(decoded[:32]).max() < np.abs(decoded[32000 * 2:32000 * 3]).max() / 4, "faded in"


def test_clip_of_a_short_recording_keeps_it_whole(tmp_path):
    source = write_wav(tmp_path / "in.wav", tone_burst(seconds=5.0, burst=(1.0, 4.0)))
    clip = audio.ClipMaker().make(source, tmp_path / "out.m4a")
    assert 4800 <= clip.duration_ms <= 5200


def test_an_undecodable_file_raises(tmp_path):
    bad = tmp_path / "bad.mp3"
    bad.write_bytes(b"not audio")
    with pytest.raises(audio.AudioError):
        audio.ClipMaker().make(bad, tmp_path / "out.m4a")


@pytest.mark.skipif(not (MODELS / audio.MODEL_FILE).exists(), reason="BirdNET model not downloaded")
def test_birdnet_check_refuses_a_pure_tone(tmp_path):
    source = write_wav(tmp_path / "in.wav", tone_burst(seconds=8.0, burst=(0.0, 8.0)))
    clip = audio.ClipMaker().make(source, tmp_path / "tone.m4a")
    check = audio.BirdNETCheck(MODELS)

    passed, score, top = check.check(clip.path, "Sayornis nigricans")

    assert not passed and top != "Sayornis nigricans"
