"""COCO bird detector: SSD MobileNet v1 from the ONNX model zoo (Apache-2.0), run through ONNX Runtime.

Input is a uint8 RGB image of any size; the model resizes internally, so photos are downscaled to
`INFERENCE_MAX_SIDE` first for speed. Only COCO class 16 (bird) is kept.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from packbuilder.download import fetch
from packbuilder.scoring import Box

DETECTOR_URL = "https://github.com/onnx/models/raw/main/validated/vision/object_detection_segmentation/ssd-mobilenetv1/model/ssd_mobilenet_v1_12.onnx"
DETECTOR_SHA256 = "b8fba5e404077d4048d27fcd1667e85e27e192eb9bf51e696c46a3acd7d21058"
DETECTOR_FILE = "ssd_mobilenet_v1_12.onnx"
COCO_BIRD = 16
INFERENCE_MAX_SIDE = 640
MIN_SCORE = 0.5


@dataclass(frozen=True)
class Detection:
    box: Box
    score: float


def ensure_model(cache_dir: Path) -> Path:
    return fetch(DETECTOR_URL, Path(cache_dir) / "models" / DETECTOR_FILE, DETECTOR_SHA256)


class BirdDetector:
    def __init__(self, model_path: Path):
        import onnxruntime as ort

        self.session = ort.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
        self.input_name = self.session.get_inputs()[0].name

    def detect(self, image: Image.Image) -> list[Detection]:
        """Birds in the image, best first, with boxes normalized to the image."""
        small = image.convert("RGB")
        small.thumbnail((INFERENCE_MAX_SIDE, INFERENCE_MAX_SIDE), Image.Resampling.BILINEAR)
        array = np.asarray(small, dtype=np.uint8)[None, ...]
        boxes, classes, scores, count = self.session.run(None, {self.input_name: array})
        detections = []
        for index in range(int(count[0])):
            if int(classes[0][index]) != COCO_BIRD or float(scores[0][index]) < MIN_SCORE:
                continue
            y0, x0, y1, x1 = (float(v) for v in boxes[0][index])
            detections.append(Detection(box=Box(x0, y0, x1, y1).clamped(), score=float(scores[0][index])))
        return sorted(detections, key=lambda d: -d.score)
