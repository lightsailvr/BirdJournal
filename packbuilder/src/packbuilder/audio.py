"""Turns a downloaded recording into the pack's clip and checks it with BirdNET (issue #41).

The clip: the loudest 8 s of the recording (after a 200 Hz high-pass, so wind and traffic do not pick the window),
high-passed, loudness-normalized, with 100 ms fades, encoded mono 48 kHz AAC-LC at 64 kbps in an `.m4a` (about 65 KB).
The check: BirdNET+ V3.0 (the app's model) over 3 s windows 1.5 s apart, as the app listens; the clip is kept only
when the species is the top of the mean scores. ffmpeg does the decoding and encoding (`brew install ffmpeg`).
"""

from __future__ import annotations

import csv
import json
import shutil
import subprocess
from pathlib import Path

import numpy as np

from packbuilder.sounds import Clip

CLIP_SECONDS = 8.0
FADE_SECONDS = 0.1
HIGH_PASS_HZ = 200
MODEL_RATE = 32000
WINDOW_SECONDS = 3.0
HOP_SECONDS = 1.5
MODEL_FILE = "BirdNET+_V3.0-preview3.1_Global_11K_FP16_pruned.onnx"
LABELS_FILE = "BirdNET+_V3.0-preview3.1_Global_11K_Labels.csv"


class AudioError(RuntimeError):
    pass


def _ffmpeg() -> str:
    path = shutil.which("ffmpeg")
    if path is None:
        raise AudioError("ffmpeg is required for the sounds stage: brew install ffmpeg")
    return path


def decode(path: Path, rate: int, high_pass: bool = False) -> np.ndarray:
    """The file as mono float32 samples at `rate`."""
    filters = ["-af", f"highpass=f={HIGH_PASS_HZ}"] if high_pass else []
    run = subprocess.run(
        [_ffmpeg(), "-v", "error", "-i", str(path), *filters, "-ac", "1", "-ar", str(rate), "-f", "f32le", "-"], capture_output=True,
    )
    if run.returncode != 0 or not run.stdout:
        raise AudioError(run.stderr.decode(errors="replace").strip() or f"no audio in {path.name}")
    return np.frombuffer(run.stdout, dtype="<f4")


def probe(path: Path) -> dict:
    """ffprobe's description of the first audio stream."""
    run = subprocess.run(
        [shutil.which("ffprobe") or "ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name,channels,sample_rate,duration", "-of", "json", str(path)],
        capture_output=True, check=True,
    )
    return json.loads(run.stdout)["streams"][0]


def loudest_window(samples: np.ndarray, rate: int, seconds: float, step_seconds: float = 0.25) -> float:
    """The start, in seconds, of the `seconds`-long window with the most energy, on a `step_seconds` grid."""
    length = int(seconds * rate)
    if samples.size <= length:
        return 0.0
    energy = np.concatenate(([0.0], np.cumsum(samples.astype(np.float64) ** 2)))
    step = max(1, int(step_seconds * rate))
    starts = np.arange(0, samples.size - length + 1, step)
    totals = energy[starts + length] - energy[starts]
    return float(starts[int(np.argmax(totals))]) / rate


class ClipMaker:
    def make(self, source: Path, target: Path) -> Clip:
        samples = decode(source, MODEL_RATE, high_pass=True)
        total = samples.size / MODEL_RATE
        start = loudest_window(samples, MODEL_RATE, CLIP_SECONDS)
        length = min(CLIP_SECONDS, total - start)
        filters = ",".join([
            f"atrim=start={start:.3f}:duration={length:.3f}", "asetpts=PTS-STARTPTS", f"highpass=f={HIGH_PASS_HZ}",
            "loudnorm=I=-16:TP=-1.5:LRA=11", f"afade=t=in:d={FADE_SECONDS}", f"afade=t=out:st={max(0.0, length - FADE_SECONDS):.3f}:d={FADE_SECONDS}",
        ])
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_name(f"{target.stem}.partial.m4a")
        run = subprocess.run(
            [_ffmpeg(), "-v", "error", "-y", "-i", str(source), "-af", filters, "-ac", "1", "-ar", "48000", "-c:a", "aac", "-b:a", "64k",
             "-map_metadata", "-1", "-fflags", "+bitexact", "-movflags", "+faststart", str(partial)],
            capture_output=True,
        )
        if run.returncode != 0:
            partial.unlink(missing_ok=True)
            raise AudioError(run.stderr.decode(errors="replace").strip())
        partial.replace(target)
        return Clip(path=target, duration_ms=round(float(probe(target)["duration"]) * 1000))


class BirdNETCheck:
    """Whether BirdNET hears the species in a clip: the clip decoded at 32 kHz, cut into the app's 3 s windows 1.5 s
    apart, scored, and the scores averaged per class."""

    def __init__(self, models_dir: Path):
        import onnxruntime

        self.session = onnxruntime.InferenceSession(str(Path(models_dir) / MODEL_FILE), providers=["CPUExecutionProvider"])
        with (Path(models_dir) / LABELS_FILE).open(encoding="utf-8-sig") as handle:
            self.labels = [row["sci_name"] for row in csv.DictReader(handle, delimiter=";")]

    def check(self, clip: Path, scientific_name: str) -> tuple[bool, float, str]:
        samples = decode(clip, MODEL_RATE)
        window, hop = int(WINDOW_SECONDS * MODEL_RATE), int(HOP_SECONDS * MODEL_RATE)
        if samples.size < window:
            samples = np.pad(samples, (0, window - samples.size))
        batch = np.stack([samples[start:start + window] for start in range(0, samples.size - window + 1, hop)]).astype(np.float32)
        scores = self.session.run(["predictions"], {"input": batch})[0].astype(np.float64).mean(axis=0)
        top = self.labels[int(np.argmax(scores))]
        index = self.labels.index(scientific_name) if scientific_name in self.labels else None
        score = float(scores[index]) if index is not None else 0.0
        return top == scientific_name, score, top
