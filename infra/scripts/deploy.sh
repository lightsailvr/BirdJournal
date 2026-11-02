#!/usr/bin/env bash
# Deploys the BirdJournal stack in one command, then writes its sign-in settings into the app.
#
#   infra/scripts/deploy.sh            # template tests, cdk deploy, AccountServer.json
#   infra/scripts/deploy.sh --synth    # template tests and cdk synth only: no AWS calls
#
# Needs the wizards' console steps done first: infra/scripts/accounts-wizard.sh (the two secrets in Secrets
# Manager, the CDK bootstrap, BUDGET_ALERT_EMAIL in ~/keys/birdjournal.env) and, from issue #61,
# infra/scripts/circles-wizard.sh (the invite domain's issued certificate, INVITE_CERTIFICATE_ARN in the same file).
# Scene art (issue #68) needs nothing more to deploy; infra/scripts/art-wizard.sh then sets up the worker on comfybox.
# Pushes (issue #63) need infra/scripts/push-wizard.sh's APNs key in Secrets Manager, but a deploy without it works:
# the API sends no pushes until the key is there.
set -euo pipefail

infra="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$HOME/keys/birdjournal.env"
export AWS_PROFILE="${AWS_PROFILE:-lsvr-admin}"
# from_env NAME: NAME from the environment, else from ~/keys/birdjournal.env.
from_env() {
    local name="$1"
    if [[ -z "${!name:-}" && -f "$env_file" ]]; then
        # shellcheck disable=SC1090
        printf -v "$name" '%s' "$(source "$env_file" && printf '%s' "${!name:-}")"
    fi
}
from_env BUDGET_ALERT_EMAIL
from_env INVITE_CERTIFICATE_ARN
# A synth only renders these into the template; a deploy needs the real ones.
if [[ "${1:-}" == "--synth" ]]; then
    BUDGET_ALERT_EMAIL="${BUDGET_ALERT_EMAIL:-budget@example.invalid}"
    INVITE_CERTIFICATE_ARN="${INVITE_CERTIFICATE_ARN:-arn:aws:acm:us-east-1:000000000000:certificate/00000000-0000-0000-0000-000000000000}"
fi
export BUDGET_ALERT_EMAIL="${BUDGET_ALERT_EMAIL:?set BUDGET_ALERT_EMAIL or run infra/scripts/accounts-wizard.sh}"
export INVITE_CERTIFICATE_ARN="${INVITE_CERTIFICATE_ARN:?set INVITE_CERTIFICATE_ARN or run infra/scripts/circles-wizard.sh}"

cd "$infra"
[[ -d node_modules ]] || npm ci --silent
uv run --frozen pytest -q

if [[ "${1:-}" == "--synth" ]]; then
    npx cdk synth --quiet
    exit
fi

# The shared account's bootstrap must already be new enough; this never bootstraps it.
"$infra/scripts/check-bootstrap.sh"
npx cdk deploy BirdJournal --require-approval broadening
"$infra/scripts/write-app-config.sh"
