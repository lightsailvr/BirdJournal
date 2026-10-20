# Serverless backend on Lambda and DynamoDB, not ivan-parallax's App Runner and Postgres

Status: accepted, 2026-10-13

The backend for accounts, circles, finds, pushes and art jobs reuses ivan-parallax's CDK (Python) constructs for Cognito with Google, private buckets behind CloudFront, queues with dead-letter queues and scheduled jobs. It does not copy that project's compute and database. ivan-parallax runs FastAPI on App Runner with RDS Postgres and costs about $53 a month with no traffic. BirdJournal's traffic is bursty and small, it earns nothing (ADR-0001), and its data is a handful of access patterns: a circle's feed, an owner's finds, a circle's members, an account's devices. So FastAPI runs on Lambda behind an HTTP API, with DynamoDB on demand. Idle cost is a few dollars.

## Considered options

- **App Runner with RDS Postgres**: familiar and the code carries over, but it has an always-on cost floor.
- **Aurora Serverless v2 with scale to zero**: the first request after a pause waits about 15 seconds, which is wrong for someone opening a push.

## Consequences

- Push goes straight to APNs with a token key. There is no SNS and no Firebase.
- Sign in with Apple joins Google in the user pool, as App Review guideline 4.8 requires.
