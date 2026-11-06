#!/usr/bin/env bash
# Checks at the zone's own name servers that every host in infra/cdk.json points at the invite distribution, read-only.
# Run by deploy.sh and the domain wizard before a deploy. Without the new host's record the old host would redirect to
# a name that doesn't resolve, and the zone's negative caching can hold that failure for hours after the record is added.
#
#   exit 0: every host's CNAME is the distribution's name, or there's no stack yet, so nothing can break
#   exit 1: a record is missing or wrong
#   exit 3: DNS or the stack couldn't be read, so nothing is known about the records
set -euo pipefail

infra="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-lsvr-admin}"
domain=$(jq -r '.context.inviteDomain' "$infra/cdk.json")
hosts=$(jq -r '([.context.inviteDomain] + (.context.inviteFormerDomains // [])) | join(" ")' "$infra/cdk.json")
zone="${domain#*.}"
EMERGENCY="If you have to deploy regardless: infra/scripts/deploy.sh --emergency"

lower_no_dot() { local name; name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); printf '%s' "${name%.}"; }

if ! answer=$(aws cloudformation describe-stacks --region us-west-2 --stack-name BirdJournal --output text \
    --query "Stacks[0].Outputs[?OutputKey=='InviteDistributionDomain'].OutputValue" 2>&1); then
    if [[ "$answer" == *"does not exist"* ]]; then
        echo "No BirdJournal stack yet, so no live host to protect. DNS not checked."
        exit 0
    fi
    echo "Can't read the stack to check DNS (is AWS_PROFILE $AWS_PROFILE signed in?)."
    echo "$EMERGENCY"
    exit 3
fi
target=$(lower_no_dot "$answer")
if [[ -z "$target" || "$target" == "none" ]]; then
    echo "The stack has no InviteDistributionDomain output, so DNS can't be checked."
    echo "$EMERGENCY"
    exit 3
fi

# dig prints a timeout to stdout as a ";;" line, and that isn't a name server.
name_servers=$(dig +short +time=3 +tries=2 NS "$zone" 2>/dev/null | grep -v '^;' || true)
if [[ -z "$name_servers" ]]; then
    echo "Can't look up $zone's name servers from here, so nothing is known about its records. Try again in a minute."
    echo "$EMERGENCY"
    exit 3
fi

# record_at HOST: the host's CNAME from the first name server that gives a real answer, which may be that there's none.
# Fails if none does: a timeout or a SERVFAIL says nothing about the record.
record_at() {
    local server output status
    for server in $name_servers; do
        output=$(dig +noall +comments +answer +time=3 +tries=2 CNAME "$1" "@$server" 2>/dev/null) || continue
        status=$(printf '%s\n' "$output" | sed -n 's/.*status: \([A-Z]*\),.*/\1/p')
        if [[ "$status" == "NOERROR" || "$status" == "NXDOMAIN" ]]; then
            lower_no_dot "$(printf '%s\n' "$output" | awk '!/^;/ && $4 == "CNAME" { print $5; exit }')"
            return 0
        fi
    done
    return 1
}

for host in $hosts; do
    if ! record=$(record_at "$host"); then
        echo "None of $zone's name servers gave an answer for $host ($(echo $name_servers | tr '\n' ' ')), so nothing is known about"
        echo "its record. This is a lookup failure, not a missing record. Try again in a minute."
        echo "$EMERGENCY"
        exit 3
    fi
    if [[ "$record" != "$target" ]]; then
        if [[ -z "$record" ]]; then
            echo "$host has no CNAME at $zone's name servers, wanted $target. A deploy now could break the site's links."
        else
            echo "$host points at $record at $zone's name servers, wanted $target. A deploy now could break the site's links."
        fi
        echo "Add or fix the record: infra/scripts/domain-wizard.sh, stage 5."
        echo "$EMERGENCY"
        exit 1
    fi
done
echo "DNS: $hosts point at $target. OK."
