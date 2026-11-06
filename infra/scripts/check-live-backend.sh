#!/usr/bin/env bash
# Refuses a checkout without backend code that's already live but not yet on every branch, because deploying it would take
# that code off the API. Slice 8's fields (#150) went live from their own branch. Run by deploy.sh and the domain wizard.
# Add a line here when a backend goes live ahead of its merge. `deploy.sh --without-live-backend` overrides this.
set -euo pipefail

backend="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/backend/src/birdjournal_api"
missing=""
needs() { grep -qF "$2" "$backend/$1" 2>/dev/null || missing="$missing $1 ($2)"; }
needs goals_api.py "class GoalSpecies"
needs reactions_api.py "editions: list[str]"

if [[ -n "$missing" ]]; then
    echo "This checkout lacks backend code that's already live:$missing."
    echo "Deploying it would take those fields off the API. Merge that code here first, or deploy from a branch with both."
    echo "To take them off on purpose: infra/scripts/deploy.sh --without-live-backend"
    exit 1
fi
echo "Backend: this checkout holds what's live. OK."
