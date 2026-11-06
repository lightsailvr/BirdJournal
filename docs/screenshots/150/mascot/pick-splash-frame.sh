#!/usr/bin/env bash
# The splash's frames in a recording of a launch, as the middle of those where it's at rest: the title has come in and the fade
# hasn't begun. A frame's distance from the next is small once the title has settled and before the Listen tab fades in.
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
# The splash is the frames whose top of the screen is plain paper (the launch screen and splash have nothing there) and whose
# middle isn't: the last of those is the splash at rest with its title, just before it fades.
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
