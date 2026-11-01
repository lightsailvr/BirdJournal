#!/usr/bin/env bash
# Checks the account's CDK bootstrap before a deploy, read-only. The lsvr-admin account is shared with
# ivan-parallax, so its CDKToolkit stack is never bootstrapped over from here.
#
#   exit 0: CDKToolkit exists and its BootstrapVersion meets what the synthesized stack requires
#   exit 2: no CDKToolkit in the region yet (bootstrap is safe: the wizard's stage 9 offers it)
#   exit 1: CDKToolkit is older than required: stop and ask the account's owner; never upgrade it from here
set -euo pipefail

infra="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
region="us-west-2"
export AWS_PROFILE="${AWS_PROFILE:-lsvr-admin}"

if [[ ! -f "$infra/cdk.out/manifest.json" ]]; then
    "$infra/scripts/deploy.sh" --synth >/dev/null
fi
required=$(jq '[.artifacts[].properties.requiresBootstrapStackVersion // empty] | max // 0' "$infra/cdk.out/manifest.json")

if ! current=$(aws cloudformation describe-stacks --region "$region" --stack-name CDKToolkit \
    --query "Stacks[0].Outputs[?OutputKey=='BootstrapVersion'].OutputValue" --output text 2>/dev/null); then
    echo "No CDKToolkit stack in $region: the account needs a bootstrap first."
    exit 2
fi
if (( current < required )); then
    echo "CDKToolkit in $region is at bootstrap version $current; this stack needs $required."
    echo "It is shared with other projects: ask the account's owner to upgrade it. Don't re-bootstrap it from here."
    exit 1
fi
echo "CDKToolkit in $region: bootstrap version $current (needs $required). OK."
