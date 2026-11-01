#!/usr/bin/env bash
# Deploys the BirdJournal stack in one command, then writes its sign-in settings into the app.
#
#   infra/scripts/deploy.sh            # template tests, cdk deploy, AccountServer.json
#   infra/scripts/deploy.sh --synth    # template tests and cdk synth only: no AWS calls
#
# Needs the wizard's console steps done first (infra/scripts/accounts-wizard.sh): the two secrets in
# Secrets Manager, the CDK bootstrap, and BUDGET_ALERT_EMAIL in ~/keys/birdjournal.env.
set -euo pipefail

infra="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$HOME/keys/birdjournal.env"
export AWS_PROFILE="${AWS_PROFILE:-lsvr-admin}"
if [[ -z "${BUDGET_ALERT_EMAIL:-}" && -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    BUDGET_ALERT_EMAIL="$(source "$env_file" && printf '%s' "${BUDGET_ALERT_EMAIL:-}")"
fi
# A synth only renders the address into the template; a deploy needs the real one.
[[ "${1:-}" == "--synth" ]] && BUDGET_ALERT_EMAIL="${BUDGET_ALERT_EMAIL:-budget@example.invalid}"
export BUDGET_ALERT_EMAIL="${BUDGET_ALERT_EMAIL:?set BUDGET_ALERT_EMAIL or run infra/scripts/accounts-wizard.sh}"

cd "$infra"
[[ -d node_modules ]] || npm ci --silent
uv run --frozen pytest -q

if [[ "${1:-}" == "--synth" ]]; then
    npx cdk synth --quiet
    exit
fi

npx cdk deploy BirdJournal --require-approval broadening
"$infra/scripts/write-app-config.sh"
