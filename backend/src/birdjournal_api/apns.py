"""APNs over HTTP/2 with a token key (issue #63): no SNS, no Firebase.

The key (the .p8 from the Apple Developer portal, its Key ID and the Team ID) is the Secrets Manager secret
`birdjournal/apns`, JSON `{"key_id", "team_id", "private_key"}`, created by `infra/scripts/push-wizard.sh` outside the
stack. It is read on the first push and kept for the life of the Lambda instance; until the wizard has stored it,
pushes are skipped with a log line (and the secret looked for again every five minutes), and everything else works.

The provider token is an ES256 JWT (`iss` the team, `iat`, header `kid` the key), made again every 50 minutes:
Apple refuses one older than an hour and throttles one made more often than every 20 minutes.
"""

import json
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import httpx2
import jwt

from birdjournal_api.devices import Device, Environment
from birdjournal_api.pushes import Push, SendResult

log = logging.getLogger(__name__)

HOSTS = {
    Environment.SANDBOX: "https://api.sandbox.push.apple.com",
    Environment.PRODUCTION: "https://api.push.apple.com",
}
TOKEN_LIFETIME_SECONDS = 50 * 60
KEY_RETRY_SECONDS = 5 * 60
# Reasons that mean the token will never work for this app again.
GONE_REASONS = frozenset({"BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"})
# A notable find or a digest is stale after a day; a silent refresh after an hour.
ALERT_EXPIRY_SECONDS = 24 * 3600
REFRESH_EXPIRY_SECONDS = 3600


@dataclass(frozen=True)
class ApnsCredentials:
    key_id: str
    team_id: str
    private_key: str


def secrets_manager_credentials(secret_name: str, region: str) -> Callable[[], ApnsCredentials | None]:
    """Reads the key from Secrets Manager; None when the secret isn't there yet."""

    def load() -> ApnsCredentials | None:
        import boto3

        client = boto3.client("secretsmanager", region_name=region)
        try:
            raw = client.get_secret_value(SecretId=secret_name)["SecretString"]
        except client.exceptions.ResourceNotFoundException:
            log.warning("APNs key secret %s not found: pushes are off until the push wizard stores it", secret_name)
            return None
        value = json.loads(raw)
        return ApnsCredentials(key_id=value["key_id"], team_id=value["team_id"], private_key=value["private_key"])

    return load


class ApnsSender:
    def __init__(
        self,
        credentials: Callable[[], ApnsCredentials | None],
        topic: str,
        *,
        client: httpx2.Client | None = None,
        now: Callable[[], float] = time.time,
    ) -> None:
        self._load_credentials = credentials
        self._credentials: ApnsCredentials | None = None
        self._last_load: float | None = None
        self._topic = topic
        # HTTP/2 is what APNs speaks; one connection per host is reused across pushes and invocations.
        self._client = client or httpx2.Client(http2=True, timeout=httpx2.Timeout(5.0))
        self._now = now
        self._token: str | None = None
        self._token_made_at = 0.0

    def send(self, device: Device, push: Push) -> SendResult:
        credentials = self._key()
        if credentials is None:
            return SendResult.SKIPPED
        result, reason = self._post(device, push, credentials)
        if result is SendResult.FAILED and reason == "ExpiredProviderToken":
            self._token = None
            result, reason = self._post(device, push, credentials)
        if result is SendResult.FAILED:
            log.warning("APNs refused a %s push: %s", push.kind.value, reason)
        return result

    def provider_token(self, credentials: ApnsCredentials) -> str:
        now = self._now()
        if self._token is None or now - self._token_made_at >= TOKEN_LIFETIME_SECONDS:
            self._token = jwt.encode(
                {"iss": credentials.team_id, "iat": int(now)},
                credentials.private_key,
                algorithm="ES256",
                headers={"kid": credentials.key_id},
            )
            self._token_made_at = now
        return self._token

    def _post(self, device: Device, push: Push, credentials: ApnsCredentials) -> tuple[SendResult, str | None]:
        expiry = REFRESH_EXPIRY_SECONDS if push.is_silent else ALERT_EXPIRY_SECONDS
        headers = {
            "authorization": f"bearer {self.provider_token(credentials)}",
            "apns-topic": self._topic,
            "apns-push-type": "background" if push.is_silent else "alert",
            # Apple requires priority 5 for background pushes.
            "apns-priority": "5" if push.is_silent else "10",
            "apns-expiration": str(int(self._now()) + expiry),
        }
        if push.collapse_id:
            headers["apns-collapse-id"] = push.collapse_id
        try:
            response = self._client.post(
                f"{HOSTS[device.environment]}/3/device/{device.token}",
                content=json.dumps(push.payload(), separators=(",", ":")).encode(),
                headers=headers,
            )
        except httpx2.HTTPError as error:
            return SendResult.FAILED, type(error).__name__
        if response.status_code == 200:
            return SendResult.SENT, None
        reason = _reason(response)
        if response.status_code == 410 or reason in GONE_REASONS:
            return SendResult.GONE, reason
        return SendResult.FAILED, reason

    def _key(self) -> ApnsCredentials | None:
        """The key, read once; a missing one is looked for again every few minutes, so a key stored after the deploy
        is picked up without one."""
        now = self._now()
        if self._credentials is None and (self._last_load is None or now - self._last_load >= KEY_RETRY_SECONDS):
            self._last_load = now
            self._credentials = self._load_credentials()
        return self._credentials


class DisabledSender:
    """No APNs key configured (local runs): every push is skipped."""

    def send(self, device: Device, push: Push) -> SendResult:
        return SendResult.SKIPPED


def _reason(response: Any) -> str | None:
    try:
        value = response.json().get("reason")
    except ValueError:
        return None
    return str(value) if value else None
