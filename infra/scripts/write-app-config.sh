#!/usr/bin/env bash
# Writes the deployed stack's public sign-in settings (API URL, Cognito domain, app client ID) to the
# app's bundled AccountServer.json. None of them is a secret: the client is public and uses PKCE.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target="$repo/BirdJournal/BirdJournal/Account/AccountServer.json"
export AWS_PROFILE="${AWS_PROFILE:-lsvr-admin}"

aws cloudformation describe-stacks --region us-west-2 --stack-name BirdJournal --output json \
    | jq '.Stacks[0].Outputs | map({(.OutputKey): .OutputValue}) | add
          | {apiURL: .ApiUrl, cognitoDomain: .CognitoDomain, clientID: .AppClientId}' > "$target"
echo "wrote $target"
