# BirdJournal API

FastAPI on Lambda behind an API Gateway HTTP API, over one DynamoDB table (ADR-0002). The stack is in `../infra`.

- `GET /health`
- `GET /v1/account`: the signed-in account, created on the first authenticated call.
- `PATCH /v1/account` with `{"display_name": "..."}`: 1 to 40 characters, trimmed, no control characters.

Every route but `/health` needs a Cognito access token from the iOS app client (`Authorization: Bearer ...`); `birdjournal_api.auth` checks its signature against the pool's JWKS, issuer, expiry, `token_use` and `client_id`.

## Tests: the in-process harness

```sh
cd backend && uv run pytest
```

`tests/conftest.py` is the harness every backend ticket tests through: the FastAPI app in process (`TestClient`), DynamoDB Local in a container (Docker running; or `DYNAMODB_ENDPOINT=http://localhost:8000` for one already up) with a fresh table per test, and `tests/tokens.py`'s `TestIssuer`, which signs Cognito-shaped access tokens with a test key and hands the app its JWKS. `issuer.headers(sub=..., exp=..., client_id=...)` makes a token with any claim changed.
