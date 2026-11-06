#!/usr/bin/env bash
# The last frame of the splash in a recording of a launch, when its title has come in and just before it fades: the last frame
# with nothing at the top of the screen and something in the middle.
#
#   pick-splash-frame.sh <movie> <out.jpg>
set -euo pipefail
movie="$1"; target="$2"; frames="$(mktemp -d)"
ffmpeg -loglevel error -i "$movie" -vf "fps=20,scale=800:-2" "$frames/%04d.jpg"
uv run -q --with pillow --with numpy python - "$frames" "$target" <<'PY'
import pathlib, shutil, sys
import numpy as np
from PIL import Image
files = sorted(pathlib.Path(sys.argv[1]).glob("*.jpg"))
pictures = [np.asarray(Image.open(file).convert("L"), dtype=float) for file in files]
middle = pictures[0].shape[0] // 2
def plain(picture):
    return picture[140:middle - 240].std() < 3
def busy(picture):
    return picture[middle - 100:middle + 100].std() > 12
shown = [index for index, picture in enumerate(pictures) if plain(picture) and busy(picture)]
if not shown:
    sys.exit("no splash frame found")
shutil.copy(files[shown[-1]], sys.argv[2])
print(f"{len(shown)} splash frames of {len(files)}, using {shown[-1]}", file=sys.stderr)
PY
