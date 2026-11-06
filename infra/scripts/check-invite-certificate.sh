#!/usr/bin/env bash
# Checks INVITE_CERTIFICATE_ARN before a deploy, read-only: issued, and covering every host in infra/cdk.json. CloudFormation
# only finds out mid-deploy, when CloudFront refuses an alias the certificate doesn't cover. Run by deploy.sh and the
# domain wizard.
#
#   exit 0: the certificate is issued and covers inviteDomain and inviteFormerDomains
#   exit 1: it isn't, or can't be read: infra/scripts/domain-wizard.sh makes the one the stack needs
set -euo pipefail

infra="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-lsvr-admin}"
arn="${INVITE_CERTIFICATE_ARN:?set INVITE_CERTIFICATE_ARN or run infra/scripts/domain-wizard.sh}"
EMERGENCY="If you have to deploy regardless: infra/scripts/deploy.sh --emergency"
hosts=$(jq -c '[.context.inviteDomain] + (.context.inviteFormerDomains // [])' "$infra/cdk.json")

if ! certificate=$(aws acm describe-certificate --region us-east-1 --certificate-arn "$arn" --output json 2>/dev/null); then
    echo "Can't read the invite certificate $arn in us-east-1 (is AWS_PROFILE $AWS_PROFILE signed in?)."
    echo "$EMERGENCY"
    exit 1
fi
status=$(jq -r '.Certificate.Status' <<<"$certificate")
missing=$(jq -r --argjson hosts "$hosts" '$hosts - .Certificate.SubjectAlternativeNames | join(" ")' <<<"$certificate")
if [[ -n "$missing" ]]; then
    echo "The invite certificate doesn't cover: $missing. CloudFront would refuse the deploy."
    echo "Run infra/scripts/domain-wizard.sh: it makes one for every host and saves its ARN."
    echo "$EMERGENCY"
    exit 1
fi
if [[ "$status" != "ISSUED" ]]; then
    echo "The invite certificate is $status, not ISSUED. Run infra/scripts/domain-wizard.sh to finish it."
    echo "$EMERGENCY"
    exit 1
fi
echo "Invite certificate: issued, covers $(jq -r 'join(" and ")' <<<"$hosts"). OK."
