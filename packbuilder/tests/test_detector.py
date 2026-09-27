from pathlib import Path

import pytest
from PIL import Image

from packbuilder.detector import DETECTOR_FILE, BirdDetector

CACHE = Path(__file__).resolve().parents[1] / "cache"
MODEL = CACHE / "models" / DETECTOR_FILE


@pytest.mark.skipif(not MODEL.exists(), reason="detector model not downloaded (packbuilder build fetches it)")
def test_detector_finds_a_bird_in_a_cached_photo():
    photos = sorted((CACHE / "photos" / "large").glob("*.jp*g")) if (CACHE / "photos" / "large").exists() else []
    if not photos:
        pytest.skip("no cached photos to detect on")
    detector = BirdDetector(MODEL)
    found = 0
    for path in photos[:5]:
        with Image.open(path) as image:
            detections = detector.detect(image)
        for detection in detections:
            assert 0.0 <= detection.box.x0 < detection.box.x1 <= 1.0
            assert 0.0 <= detection.box.y0 < detection.box.y1 <= 1.0
        found += bool(detections)
    assert found > 0
