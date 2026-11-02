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
    # The art CDN (issue #62, the ArtCdn construct): feed items' art URLs are `<art_cdn_base_url>/<key>`. None before
    # the stack has one; the feed then gives keys without URLs.
    art_cdn_base_url: str | None = None

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
            art_cdn_base_url=(env.get("ART_CDN_BASE_URL") or "").rstrip("/") or None,
        )


def _require(env: Mapping[str, str], name: str) -> str:
    value = env.get(name)
    if not value:
        raise KeyError(f"{name} is not set")
    return value
