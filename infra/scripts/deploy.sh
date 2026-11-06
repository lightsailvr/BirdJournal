#!/usr/bin/env bash
# Deploys the BirdJournal stack in one command, then writes its sign-in settings into the app.
#
#   infra/scripts/deploy.sh            # checks, template tests, cdk deploy, AccountServer.json
#   infra/scripts/deploy.sh --synth    # template tests and cdk synth only: no AWS calls
#   infra/scripts/deploy.sh --diff     # template tests and a template-only cdk diff: reads AWS, changes and uploads nothing
#
# A deploy first checks the invite certificate, DNS, that the new host answers, and that the checkout holds the live
# backend. Two flags change that:
#   --new-host-first         the domain wizard's first deploy: adds the new host and certificate, leaves the old host's
#                            pages and the API's links alone, and doesn't need the new host to answer yet
#   --without-live-backend   deploy a checkout lacking the live backend's code, taking that code off the API
#
# Needs the wizards' console steps done first: infra/scripts/accounts-wizard.sh (the two secrets in Secrets
# Manager, the CDK bootstrap, BUDGET_ALERT_EMAIL in ~/keys/birdjournal.env) and, from issue #61,
# infra/scripts/domain-wizard.sh (the invite domain's issued certificate, INVITE_CERTIFICATE_ARN in the same file).
# Pushes (issue #63) need infra/scripts/push-wizard.sh's APNs key in Secrets Manager, but a deploy without it works:
# the API sends no pushes until the key is there. Reports, moderation and account deletion (issue #71) mail reports to
# REPORT_EMAIL (else BUDGET_ALERT_EMAIL); infra/scripts/safety-wizard.sh saves it and verifies it with SES after the
# deploy.
set -euo pipefail

mode=deploy
new_host_first=no
check_backend=yes
context=""
for argument in "$@"; do
    case "$argument" in
        --synth) mode=synth ;;
        --diff) mode=diff ;;
        --new-host-first) new_host_first=yes; context="-c inviteNewHostFirst=true" ;;
        --without-live-backend) check_backend=no ;;
        *) echo "Unknown argument $argument. See the top of this script." >&2; exit 2 ;;
    esac
done

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
from_env REPORT_EMAIL
[[ -n "${REPORT_EMAIL:-}" ]] && export REPORT_EMAIL
# A synth only renders these into the template; a deploy needs the real ones.
if [[ "$mode" == "synth" ]]; then
    BUDGET_ALERT_EMAIL="${BUDGET_ALERT_EMAIL:-budget@example.invalid}"
    INVITE_CERTIFICATE_ARN="${INVITE_CERTIFICATE_ARN:-arn:aws:acm:us-east-1:000000000000:certificate/00000000-0000-0000-0000-000000000000}"
fi
export BUDGET_ALERT_EMAIL="${BUDGET_ALERT_EMAIL:?set BUDGET_ALERT_EMAIL or run infra/scripts/accounts-wizard.sh}"
export INVITE_CERTIFICATE_ARN="${INVITE_CERTIFICATE_ARN:?set INVITE_CERTIFICATE_ARN or run infra/scripts/domain-wizard.sh}"

# Before anything slow: CloudFront would refuse a certificate that doesn't cover the hosts, partway through the deploy.
[[ "$mode" == "synth" ]] || "$infra/scripts/check-invite-certificate.sh"
if [[ "$mode" == "deploy" ]]; then
    "$infra/scripts/check-invite-dns.sh"
    [[ "$check_backend" == "no" ]] || "$infra/scripts/check-live-backend.sh"
    if [[ "$new_host_first" == "no" ]]; then
        # This deploy redirects the old host to the new one and puts the new one in invite links, so it has to work first.
        domain=$(jq -r '.context.inviteDomain' "$infra/cdk.json")
        answer=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://$domain/" 2>/dev/null) || true
        if [[ "$answer" != "200" ]]; then
            echo "https://$domain/ answered '$answer', not 200, so this deploy would send the old host's visitors to a broken page."
            echo "First deploy of the new host: infra/scripts/domain-wizard.sh. This Mac's resolver may also have cached"
            echo "\"no such host\" from before the record existed, for an hour or more: wait, and try again."
            exit 1
        fi
    fi
fi

cd "$infra"
[[ -d node_modules ]] || npm ci --silent
uv run --frozen pytest -q

# shellcheck disable=SC2086 # the context is one flag and its value, or nothing
if [[ "$mode" == "synth" ]]; then
    npx cdk synth --quiet $context
    exit
fi
# shellcheck disable=SC2086
if [[ "$mode" == "diff" ]]; then
    # Without --method=template, cdk creates a temporary change set with the deploy role and uploads the assets.
    npx cdk diff BirdJournal --method=template $context
    exit
fi

# The shared account's bootstrap must already be new enough; this never bootstraps it.
"$infra/scripts/check-bootstrap.sh"
# shellcheck disable=SC2086
npx cdk deploy BirdJournal --require-approval broadening $context
"$infra/scripts/write-app-config.sh"
