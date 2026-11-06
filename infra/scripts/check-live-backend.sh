#!/usr/bin/env bash
# Refuses a checkout without backend fields that are already live but not yet on every branch, because deploying it would
# take them off the API. Slice 8's fields (#150) went live from their own branch. Run by deploy.sh and the domain wizard.
# It reads the models' source and imports nothing, so it needs no backend environment, and it looks at the fields
# themselves, so a comment doesn't count and reformatting doesn't matter.
#
# Remove this check once #150's epic has merged to dev, when every branch that can deploy holds these fields.
set -euo pipefail

backend="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/backend/src/birdjournal_api"

python3 -I - "$backend" <<'PY'
import ast
import pathlib
import sys

LIVE_FIELDS = [("goals_api.py", "GoalResponse", "species"), ("reactions_api.py", "ComparedSpeciesResponse", "editions")]


def has_field(path: pathlib.Path, class_name: str, field: str) -> bool:
    try:
        tree = ast.parse(path.read_text())
    except (OSError, SyntaxError):
        return False
    return any(
        isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == field
        for definition in tree.body
        if isinstance(definition, ast.ClassDef) and definition.name == class_name
        for node in definition.body
    )


missing = [f"{class_name}.{field} in {name}" for name, class_name, field in LIVE_FIELDS
           if not has_field(pathlib.Path(sys.argv[1]) / name, class_name, field)]
if missing:
    print("This checkout lacks fields that look already live on the API: " + ", ".join(missing) + ".")
    print("Deploying it would take them off the API. Merge that backend here first, or deploy from a branch with both.")
    print("If this is wrong (they moved or were renamed), or you mean to remove them: infra/scripts/deploy.sh --without-live-backend")
    print("If you have to deploy regardless of every check: infra/scripts/deploy.sh --emergency")
    sys.exit(1)
print("Backend: this checkout holds what's live. OK.")
PY
