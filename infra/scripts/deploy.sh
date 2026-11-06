#!/usr/bin/env bash
# Deploys the BirdJournal stack in one command, then writes its sign-in settings into the app.
#
#   infra/scripts/deploy.sh            # checks, template tests, cdk deploy, AccountServer.json
#   infra/scripts/deploy.sh --synth    # template tests and cdk synth only: no AWS calls
#   infra/scripts/deploy.sh --diff     # template tests and a template-only cdk diff: reads AWS, changes and uploads nothing
#
# A deploy first checks the invite certificate, DNS and that the checkout holds the live backend. While the site is moving
# hosts (issue #150, the domain wizard), a plain deploy refuses, because it would have to say which side of the move it's on:
#   --new-host-first       the wizard's first deploy: adds the new host and certificate, leaves the old host's pages and
#                          the API's links alone. Refused once the stack has moved, because it would move them back.
#   --move-to-new-host     the wizard's second deploy: turns on the old host's redirects and moves the API's links. Needs
#                          the new host to answer. Once the stack has moved, a plain deploy does this and checks no more.
# And two ways past a refusal:
#   --without-live-backend the live-backend check is wrong, or you mean to remove those fields
#   --emergency            skips every check above, for when one of them stands between you and fixing an outage. The
#                          template tests and the bootstrap check still run. It says what it skipped.
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
move=stay
check_backend=yes
emergency=no
context=""
for argument in "$@"; do
    case "$argument" in
        --synth) mode=synth ;;
        --diff) mode=diff ;;
        --new-host-first) move=new-host-first; context="-c inviteNewHostFirst=true" ;;
        --move-to-new-host) move=move ;;
        --without-live-backend) check_backend=no ;;
        --emergency) emergency=yes ;;
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

EMERGENCY="If you have to deploy regardless: infra/scripts/deploy.sh --emergency"

# site_address: the stack's InviteBaseUrl, or "none" with no stack yet. Fails if the stack can't be read.
site_address() {
    local answer
    if ! answer=$(aws cloudformation describe-stacks --region us-west-2 --stack-name BirdJournal --output text \
        --query "Stacks[0].Outputs[?OutputKey=='InviteBaseUrl'].OutputValue" 2>&1); then
        [[ "$answer" == *"does not exist"* ]] || return 1
        answer=none
    fi
    printf '%s' "$answer"
}

# check_the_move: which side of the host move this deploy is on, against where the stack is.
check_the_move() {
    local new_url current answer
    new_url="https://$(jq -r '.context.inviteDomain' "$infra/cdk.json")"
    if ! current=$(site_address); then
        echo "Can't read the stack to see whether the site has moved hosts (is AWS_PROFILE $AWS_PROFILE signed in?)."
        echo "$EMERGENCY"
        exit 1
    fi
    if [[ "$current" == "none" ]]; then
        return 0 # A new account: no live host to protect.
    fi
    if [[ "$current" == "$new_url" ]]; then
        if [[ "$move" == "new-host-first" ]]; then
            echo "The stack has already moved to $new_url. --new-host-first would turn off the old host's redirects and move"
            echo "the API's links back to it. To change anything else, deploy without it."
            echo "If moving back is what you want: infra/scripts/deploy.sh --new-host-first --emergency"
            exit 1
        fi
        return 0
    fi
    case "$move" in
        new-host-first) ;;
        stay)
            echo "The site is partway through moving to $new_url: the stack's links are still on $current."
            echo "A plain deploy from this checkout would finish that move, so it has to be a choice:"
            echo "  to finish it, infra/scripts/domain-wizard.sh, or infra/scripts/deploy.sh --move-to-new-host"
            echo "  to deploy something else and leave the site where it is, infra/scripts/deploy.sh --new-host-first"
            echo "$EMERGENCY"
            exit 1
            ;;
        move)
            answer=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$new_url/" 2>/dev/null) || true
            if [[ "$answer" != "200" ]]; then
                echo "$new_url/ answered '$answer', not 200, so this deploy would send the old host's visitors to a broken page."
                echo "First deploy of the new host: infra/scripts/domain-wizard.sh. This Mac's resolver may also have cached"
                echo "\"no such host\" from before the record existed, for an hour or more: wait, and try again."
                echo "$EMERGENCY"
                exit 1
            fi
            ;;
    esac
}

if [[ "$emergency" == "yes" && "$mode" != "synth" ]]; then
    cat >&2 <<'WARNING'

  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  !! EMERGENCY DEPLOY. These checks are SKIPPED:
  !!   the invite certificate is issued and covers both hosts
  !!   DNS points both hosts at the distribution
  !!   this checkout holds the backend that's live
  !!   the new host answers, and which side of the host move this deploy is on
  !! Any of them could now break invite links or take fields off the API.
  !! The template tests and the shared account's bootstrap check still run.
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

WARNING
elif [[ "$mode" != "synth" ]]; then
    # Before anything slow: CloudFront would refuse a certificate that doesn't cover the hosts, partway through the deploy.
    "$infra/scripts/check-invite-certificate.sh"
    if [[ "$mode" == "deploy" ]]; then
        "$infra/scripts/check-invite-dns.sh"
        [[ "$check_backend" == "no" ]] || "$infra/scripts/check-live-backend.sh"
        check_the_move
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
