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
    invite_base_url: str = "https://featherguild.matthewcelia.com"
    # The art CDN's bucket: shared cards' photos (issue #66).
    art_bucket: str | None = None
    # The art CDN (issue #62, the ArtCdn construct): feed items' art URLs are `<art_cdn_base_url>/<key>`. None before
    # the stack has one; the feed then gives keys without URLs.
    art_cdn_base_url: str | None = None
    # The APNs token key's Secrets Manager secret (issue #63; infra/scripts/push-wizard.sh stores it). None: no pushes.
    apns_secret_name: str | None = None
    # The app's bundle id, the apns-topic of every push.
    apns_topic: str = "com.matthewcelia.mybirdjournal"
    # Reports (issue #71) are mailed through SES to this address, from `report_sender` (both verified SES identities;
    # in the SES sandbox one verified address can be both). None: reports are stored but not mailed.
    report_email: str | None = None
    report_sender: str | None = None
    # Rekognition moderation of shared photos (issue #71): off until the public launch.
    moderation: bool = False
    # Sign in with Apple's key (the accounts wizard's secret), for revoking the birder's token at account deletion; and
    # the client the app's own Sign in with Apple authorizes as (the bundle id).
    apple_sign_in_secret_name: str | None = None
    apple_client_id: str = "com.matthewcelia.mybirdjournal"

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
            art_bucket=env.get("ART_BUCKET") or None,
            art_cdn_base_url=(env.get("ART_CDN_BASE_URL") or "").rstrip("/") or None,
            apns_secret_name=env.get("APNS_SECRET_NAME") or None,
            apns_topic=env.get("APNS_TOPIC") or cls.apns_topic,
            report_email=env.get("REPORT_EMAIL") or None,
            report_sender=env.get("REPORT_SENDER") or env.get("REPORT_EMAIL") or None,
            moderation=_switch(env.get("MODERATION") or "off"),
            apple_sign_in_secret_name=env.get("APPLE_SIGN_IN_SECRET_NAME") or None,
            apple_client_id=env.get("APPLE_CLIENT_ID") or cls.apple_client_id,
        )


def _switch(value: str) -> bool:
    if value not in ("on", "off"):
        raise ValueError(f"MODERATION must be on or off, not {value!r}")
    return value == "on"


def _require(env: Mapping[str, str], name: str) -> str:
    value = env.get(name)
    if not value:
        raise KeyError(f"{name} is not set")
    return value
