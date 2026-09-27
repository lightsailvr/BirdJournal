"""A normalized box, shared by the detector, the scorer and the crops."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Box:
    """Fractions of the image width and height, x right and y down."""

    x0: float
    y0: float
    x1: float
    y1: float

    @property
    def area(self) -> float:
        return max(0.0, self.x1 - self.x0) * max(0.0, self.y1 - self.y0)

    @property
    def center(self) -> tuple[float, float]:
        return (self.x0 + self.x1) / 2, (self.y0 + self.y1) / 2

    def clamped(self) -> "Box":
        return Box(min(max(self.x0, 0.0), 1.0), min(max(self.y0, 0.0), 1.0), min(max(self.x1, 0.0), 1.0), min(max(self.y1, 0.0), 1.0))

    def pixels(self, size: tuple[int, int]) -> tuple[int, int, int, int]:
        width, height = size
        return (int(round(self.x0 * width)), int(round(self.y0 * height)), int(round(self.x1 * width)), int(round(self.y1 * height)))
