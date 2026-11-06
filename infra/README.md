# BirdJournal infrastructure

One CDK (Python) stack, `BirdJournal`, in `us-west-2`, in the shared Lightsail VR account (AWS profile `lsvr-admin`). ADR-0002 explains the shape; issue #60 built it.

- **Cognito** user pool with Sign in with Apple and Google, a hosted domain (`birdjournal-lightsailvr.auth.us-west-2.amazoncognito.com`), and the iOS app's public client: the authorization code grant with PKCE, redirecting to `birdjournal://auth/callback`. Access and ID tokens last an hour, the refresh token a year. Retained with deletion protection.
- **API Gateway HTTP API** proxying every route to **FastAPI on Lambda** (`../backend`, Python 3.14 on ARM, 512 MB). The function verifies the Cognito access token itself. The stage throttles at 25 requests a second, bursts of 50.
- **DynamoDB**, one on-demand table (`pk`, `sk`), with point-in-time recovery, deletion protection and a Retain policy.
- A **budget**, `birdjournal-monthly` ($10, `monthlyBudgetUsd` in `cdk.json`), over the costs tagged `project=birdjournal`, emailing at 80 % actual and 100 % forecast.
- The **invite site** (issue #61): CloudFront at `featherguild.matthewcelia.com` (`inviteDomain` in `cdk.json`), and at `birdquest.matthewcelia.com` for good (`inviteFormerDomains`: its association file is served there and every other request redirects to the same path on the new host, because old invite links, QR codes and installed apps name it), over a private S3 bucket with origin access control, serving `infra/site/` (the home page and the fallback page every `/i/<token>` link shows in a browser, rewritten at the edge by a CloudFront function) and `/.well-known/apple-app-site-association` (application/json, `/i/*` for the app IDs in `iosAppIds`). Its certificate is in us-east-1 but outside the stack (below); the bucket is retained.
- Every resource is tagged `project=birdjournal` at the stack; `tests/test_stack.py` fails on any resource that isn't.

## First time: the wizard

```sh
infra/scripts/accounts-wizard.sh
```

It walks through every console-only step and stores what the stack needs: the budget address in `~/keys/birdjournal.env`, Sign in with Apple (App ID capability, Services ID, key) as the `birdjournal/apple-sign-in` secret, the Google OAuth client as `birdjournal/google-oauth`, the CDK bootstrap (`scripts/check-bootstrap.sh`: an existing `CDKToolkit` is only checked, never bootstrapped over, since ivan-parallax shares it; on 2026-11-01 it was at version 32 and this stack needs 6), the deploy, and activating `project` as a cost allocation tag. `WIZARD_FROM=<stage>` resumes at a stage: the tag only shows up for activation up to a day after the first tagged resource exists, so stage 11 may need a second run.

## The invite domain: the second wizard

```sh
infra/scripts/domain-wizard.sh
```

Run after the accounts wizard (issue #150; it replaces `circles-wizard.sh`, which set up the old host). It requests one certificate for both hosts in us-east-1 (tagged `project=birdjournal`, and saved as `INVITE_CERTIFICATE_ARN` in `~/keys/birdjournal.env` only once it's issued, because `deploy.sh` reads it), shows any validation CNAME missing from SiteGround's DNS Zone Editor (the zone `matthewcelia.com` is hosted there; the wizard checks the name servers first), waits for the certificate, has you add the new host's CNAME to CloudFront (the `InviteDistributionDomain` output), deploys after asking, checks both hosts with `curl` (the pages, the association file with no redirect and as JSON, an old invite link redirecting) and the API's invite links, then walks the console fields that name the host. Finished stages check themselves and move on, so it's safe to rerun; `WIZARD_FROM=<stage>` resumes. Keep both validation records and both CNAMEs: ACM renews with the first and old links depend on the second. The certificate lives outside the stack so CloudFormation never waits on a manual DNS change and us-east-1 needs no CDK bootstrap: CloudFront takes it by ARN from this us-west-2 stack.

## Pushes: the third wizard

```sh
infra/scripts/push-wizard.sh
```

Run after the other two (issue #63). It walks you through making the APNs auth key in the Apple Developer portal (Sandbox & Production, team scoped), saves its Key ID and Team ID in `~/keys/birdjournal.env`, stores the `.p8` with them in Secrets Manager as `birdjournal/apns` (tagged; the key goes nowhere else), has you tick Push Notifications on the App ID, deploys, and sends a test push to a phone's token (Settings → Developer in a Debug build). Deployed before the key is stored, the API sends no pushes and looks for the secret again every five minutes, so no redeploy is needed after storing it.

## Reports, moderation and account deletion: the fourth wizard

```sh
infra/scripts/safety-wizard.sh
```

Run after the others (issue #71). It saves the report address as `REPORT_EMAIL` in `~/keys/birdjournal.env` (the budget's address if you keep that), deploys (the API's grants to send as the address or its domain, Rekognition, `AdminDeleteUser` on the user pool and the Apple key's secret), checks that SES has the address's domain (or the address) verified and verifies the address only if neither is, sends a test report mail, checks SES production access (only needed to send reports elsewhere) and, for the public launch, `"moderation": "on"` in `cdk.json` and the AWS Organizations AI services opt-out.

## Deploy (one command)

```sh
infra/scripts/deploy.sh            # template tests, cdk deploy, then the app's AccountServer.json
infra/scripts/deploy.sh --synth    # template tests and cdk synth only: no AWS calls
infra/scripts/deploy.sh --diff     # template tests and cdk diff: reads AWS, changes nothing
```

`deploy.sh` checks the bootstrap the same way first (and stops if it is too old), reads `BUDGET_ALERT_EMAIL` and `INVITE_CERTIFICATE_ARN` from `~/keys/birdjournal.env`, stops if that certificate isn't issued or doesn't cover every host (`scripts/check-invite-certificate.sh`) and uses `AWS_PROFILE=lsvr-admin` unless set. After a deploy, `scripts/write-app-config.sh` writes the API URL, Cognito domain and client ID (all public) into `BirdJournal/BirdJournal/Account/AccountServer.json`; commit it, and the app's Settings → Account comes alive. Until then the app says accounts aren't available in this build.

The Lambda package is built on this machine with `uv` (ARM64 manylinux wheels for the runtime's Python), with no Docker; without `uv` CDK falls back to the runtime's build image in Docker.

`cdk destroy` leaves the user pool, the table and the invite site's bucket (Retain), both secrets, the certificate, and the CDK bootstrap stack.

## Tests

```sh
cd infra && uv run pytest
```

`tests/test_stack.py` synthesizes the stack with `cdk.json`'s context and no AWS calls (bundling skipped) and checks it against issue #60: tags on every resource, the budget, both identity providers, the app client, the table, the API and the function's environment; `tests/test_invite_site.py` checks issue #61's invite site (CloudFront, the certificate, the private bucket, the association file's content type, the edge rewrite and the old host's redirects run in node, the table's time-to-live); `tests/test_domain_wizard.py` runs the domain wizard over fake `aws`, `dig` and `curl`. `tests/test_bundling.py` builds the real Lambda package (needs PyPI).

## Smoke test (after a deploy)

```sh
cd infra && uv run python scripts/smoke.py                    # anonymous checks, then Sign in with Apple
uv run python scripts/smoke.py --provider Google
uv run python scripts/smoke.py --anonymous
```

The sign-in opens the hosted UI straight to the provider and catches the redirect on `http://localhost:48765/callback`.
