from collections.abc import Mapping
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    table_name: str
    # The user pool's issuer exactly as a token's iss claim has it: https://cognito-idp.<region>.amazonaws.com/<pool id>
    cognito_issuer: str
    # The app clients whose access tokens the API accepts (the iOS app's public client).
    cognito_client_ids: frozenset[str]
    region: str = "us-west-2"
    # Set only for DynamoDB Local (tests, local runs); Lambda talks to the regional endpoint.
    dynamodb_endpoint: str | None = None
    # Where invite links point (issue #61): `<invite_base_url>/i/<token>`, served by the invite site's CloudFront.
    invite_base_url: str = "https://birdquest.matthewcelia.com"
    # Scene art (issue #68). Without the buckets the art routes answer 503; the stack always sets them.
    upload_bucket: str | None = None
    art_bucket: str | None = None
    art_queue_url: str | None = None
    # Where painted art is served: the art CDN, https://<distribution>.cloudfront.net.
    art_cdn_base_url: str = ""
    # The worker token's Secrets Manager ARN (the stack), or the token itself (tests, local runs).
    art_worker_token_secret: str | None = None
    art_worker_token: str | None = None
    # The auto-paint rule: every_glasses_add (friends phase) or legendary_or_rare (public launch).
    art_auto_paint: str = "every_glasses_add"

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> "Settings":
        return cls(
            table_name=_require(env, "TABLE_NAME"),
            cognito_issuer=_require(env, "COGNITO_ISSUER"),
            cognito_client_ids=frozenset(
                client.strip() for client in _require(env, "COGNITO_CLIENT_IDS").split(",") if client.strip()
            ),
            region=env.get("AWS_REGION", "us-west-2"),
            dynamodb_endpoint=env.get("DYNAMODB_ENDPOINT") or None,
            invite_base_url=(env.get("INVITE_BASE_URL") or cls.invite_base_url).rstrip("/"),
            upload_bucket=env.get("UPLOAD_BUCKET") or None,
            art_bucket=env.get("ART_BUCKET") or None,
            art_queue_url=env.get("ART_QUEUE_URL") or None,
            art_cdn_base_url=(env.get("ART_CDN_BASE_URL") or "").rstrip("/"),
            art_worker_token_secret=env.get("ART_WORKER_TOKEN_SECRET") or None,
            art_auto_paint=_rule(env.get("ART_AUTO_PAINT") or cls.art_auto_paint),
        )


def _rule(value: str) -> str:
    if value not in ("every_glasses_add", "legendary_or_rare"):
        raise ValueError(f"ART_AUTO_PAINT must be every_glasses_add or legendary_or_rare, not {value!r}")
    return value


def _require(env: Mapping[str, str], name: str) -> str:
    value = env.get(name)
    if not value:
        raise KeyError(f"{name} is not set")
    return value
