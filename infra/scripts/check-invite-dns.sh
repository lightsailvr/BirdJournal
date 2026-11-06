#!/usr/bin/env bash
# Checks at SiteGround's own name server that every host in infra/cdk.json points at the invite distribution, read-only.
# Run by deploy.sh and the domain wizard before a deploy. Without the new host's record the old host would redirect to
# a name that doesn't resolve, and the zone's negative caching can hold that failure for hours after the record is added.
#
#   exit 0: every host's CNAME is the distribution's name, or there's no stack yet, so nothing can break
#   exit 1: a record is missing or wrong, or something couldn't be read
set -euo pipefail

infra="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-lsvr-admin}"
domain=$(jq -r '.context.inviteDomain' "$infra/cdk.json")
hosts=$(jq -r '([.context.inviteDomain] + (.context.inviteFormerDomains // [])) | join(" ")' "$infra/cdk.json")
zone="${domain#*.}"

# first_answer DIG-ARGUMENTS: dig's first answer in lower case without the final dot. dig prints a timeout to stdout as a
# ";;" line, and that isn't an answer.
first_answer() {
    local answer
    answer=$(dig +short +time=3 +tries=2 "$@" 2>/dev/null | grep -v '^;' | sed -n 1p | tr '[:upper:]' '[:lower:]' || true)
    printf '%s' "${answer%.}"
}

if ! answer=$(aws cloudformation describe-stacks --region us-west-2 --stack-name BirdJournal --output text \
    --query "Stacks[0].Outputs[?OutputKey=='InviteDistributionDomain'].OutputValue" 2>&1); then
    if [[ "$answer" == *"does not exist"* ]]; then
        echo "No BirdJournal stack yet, so no live host to protect. DNS not checked."
        exit 0
    fi
    echo "Can't read the stack to check DNS (is AWS_PROFILE $AWS_PROFILE signed in?)."
    exit 1
fi
target=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
target="${target%.}"
name_server=$(first_answer NS "$zone")
if [[ -z "$name_server" || -z "$target" || "$target" == "none" ]]; then
    echo "Can't check DNS: name server '$name_server', distribution '$target'."
    exit 1
fi

for host in $hosts; do
    record=$(first_answer CNAME "$host" "@$name_server")
    if [[ "$record" != "$target" ]]; then
        echo "$name_server says $host points at '$record', wanted $target. A deploy now could break the site's links."
        echo "Add or fix the record: infra/scripts/domain-wizard.sh, stage 5."
        exit 1
    fi
done
echo "DNS: $hosts point at $target. OK."
