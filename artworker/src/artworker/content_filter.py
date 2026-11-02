"""The content filter every scene painting passes before it reaches a card (ADR-0007: the FLUX Kommunity License asks
for content filtering or review of outputs, and scene art is painted for a birder with no review).

The model is Falconsai/nsfw_image_detection (Apache 2.0), the classifier Black Forest Labs' reference code uses, as
the ONNX export onnx-community/nsfw_image_detection-ONNX (`scripts/download-filter.sh` fetches it, SHA-256 pinned):
a ViT at 224 × 224, inputs scaled to [-1, 1], labels 0 normal and 1 nsfw. It runs on the CPU in about a tenth of a
second, beside FLUX.3 on the GPU.
"""

from __future__ import annotations

from pathlib import Path
from typing import Protocol

import numpy as np
from PIL import Image

THRESHOLD = 0.5
"""A painting whose nsfw probability is above this is refused."""
SIZE = 224


class ContentFilter(Protocol):
    def allows(self, image: Image.Image) -> bool: ...


class NsfwFilter:
    def __init__(self, model: Path, threshold: float = THRESHOLD):
        import onnxruntime

        self.session = onnxruntime.InferenceSession(str(model), providers=["CPUExecutionProvider"])
        self.input_name = self.session.get_inputs()[0].name
        self.threshold = threshold

    def nsfw_probability(self, image: Image.Image) -> float:
        logits = self.session.run(None, {self.input_name: preprocess(image)})[0][0]
        exp = np.exp(logits - logits.max())
        return float((exp / exp.sum())[1])

    def allows(self, image: Image.Image) -> bool:
        return self.nsfw_probability(image) <= self.threshold


def preprocess(image: Image.Image) -> np.ndarray:
    """ViTFeatureExtractor's steps (the export's preprocessor_config.json): RGB, 224 × 224 bilinear, scaled to [0, 1],
    then normalised with mean and std 0.5; NCHW float32."""
    pixels = np.asarray(image.convert("RGB").resize((SIZE, SIZE), Image.Resampling.BILINEAR), dtype=np.float32) / 255.0
    return ((pixels - 0.5) / 0.5).transpose(2, 0, 1)[np.newaxis]
