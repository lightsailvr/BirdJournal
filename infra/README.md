# BirdJournal infrastructure

One CDK (Python) stack, `BirdJournal`, in `us-west-2`, in the shared Lightsail VR account (AWS profile `lsvr-admin`). ADR-0002 explains the shape; issue #60 built it.

- **Cognito** user pool with Sign in with Apple and Google, a hosted domain (`birdjournal-lightsailvr.auth.us-west-2.amazoncognito.com`), and the iOS app's public client: the authorization code grant with PKCE, redirecting to `birdjournal://auth/callback`. Access and ID tokens last an hour, the refresh token a year. Retained with deletion protection.
- **API Gateway HTTP API** proxying every route to **FastAPI on Lambda** (`../backend`, Python 3.14 on ARM, 512 MB). The function verifies the Cognito access token itself. The stage throttles at 25 requests a second, bursts of 50.
- **DynamoDB**, one on-demand table (`pk`, `sk`), with point-in-time recovery, deletion protection and a Retain policy.
- A **budget**, `birdjournal-monthly` ($10, `monthlyBudgetUsd` in `cdk.json`), over the costs tagged `project=birdjournal`, emailing at 80 % actual and 100 % forecast.
- Every resource is tagged `project=birdjournal` at the stack; `tests/test_stack.py` fails on any resource that isn't.

## First time: the wizard

```sh
infra/scripts/accounts-wizard.sh
```

It walks through every console-only step and stores what the stack needs: the budget address in `~/keys/birdjournal.env`, Sign in with Apple (App ID capability, Services ID, key) as the `birdjournal/apple-sign-in` secret, the Google OAuth client as `birdjournal/google-oauth`, the CDK bootstrap (skipped when `CDKToolkit` already exists in the account), the deploy, and activating `project` as a cost allocation tag. `WIZARD_FROM=<stage>` resumes at a stage: the tag only shows up for activation up to a day after the first tagged resource exists, so stage 11 may need a second run.

## Deploy (one command)

```sh
infra/scripts/deploy.sh            # template tests, cdk deploy, then the app's AccountServer.json
infra/scripts/deploy.sh --synth    # template tests and cdk synth only: no AWS calls
```

`deploy.sh` reads `BUDGET_ALERT_EMAIL` from `~/keys/birdjournal.env` and uses `AWS_PROFILE=lsvr-admin` unless set. After a deploy, `scripts/write-app-config.sh` writes the API URL, Cognito domain and client ID (all public) into `BirdJournal/BirdJournal/Account/AccountServer.json`; commit it, and the app's Settings → Account comes alive. Until then the app says accounts aren't available in this build.

The Lambda package is built on this machine with `uv` (ARM64 manylinux wheels for the runtime's Python), with no Docker; without `uv` CDK falls back to the runtime's build image in Docker.

`cdk destroy` leaves the user pool and the table (Retain), both secrets, and the CDK bootstrap stack.

## Tests

```sh
cd infra && uv run pytest
```

`tests/test_stack.py` synthesizes the stack with `cdk.json`'s context and no AWS calls (bundling skipped) and checks it against issue #60: tags on every resource, the budget, both identity providers, the app client, the table, the API and the function's environment. `tests/test_bundling.py` builds the real Lambda package (needs PyPI).

## Smoke test (after a deploy)

```sh
cd infra && uv run python scripts/smoke.py                    # anonymous checks, then Sign in with Apple
uv run python scripts/smoke.py --provider Google
uv run python scripts/smoke.py --anonymous
```

The sign-in opens the hosted UI straight to the provider and catches the redirect on `http://localhost:48765/callback`.
