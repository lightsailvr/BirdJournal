"""Account deletion (issue #71, spec v2 story 69, App Review 5.1.1(v)): `DELETE /v1/account` removes everything the
server holds about the signed-in birder, deletes the Cognito user and revokes the Sign in with Apple token.

What goes, in this order (each step is idempotent, so a deletion cut short, say by the Lambda's 10 seconds on a very
full account, is finished by the phone calling again with the same access token):

0. A **tombstone** (`DELETED` / the subject's SHA-256, two hours): the account's access tokens are checked offline and
   stay valid up to an hour after the Cognito user goes, so any other call with one (an outbox put, a circles refresh)
   is refused rather than writing the account back. Only a retried deletion gets through. Then, before any circle
   changes, **other members' items naming it** (step 8 below), since the circles they are found through go in step 5.
1. **Finds** (`FindStore.delete`, #62): their feed items and species entries in every circle, shared cards and their
   photos (#66), and reactions on them with each reactor's copy and the reaction-push items (#64).
2. **Reactions it gave** on others' finds (its `REACTION#` copies, #64), with the find-side items, and its name taken
   out of the owners' collapsed reaction alerts (`REACTIONPUSH#…` `shown`) and waiting reaction buffers.
3. **Digest buffers** it is in, as recipient or friend (#63).
4. **Goals** in its circles: a custom goal it made stays with the circle but no longer names it (`created_by`
   removed, so only the circle's creator can delete it); a goal its find completed forgets which find (#65).
5. **Circles**: one where others remain passes to its longest-standing member when the account created it (#61's
   handoff, `CircleStore.leave`), and its membership item goes; one with nobody else in it now is deleted with its
   feed, goals and rollover entry. Circles it left before keep no membership item of it; one it was the last to leave
   and still names it as creator is deleted.
6. **Invites** it made (`ACCOUNT#<sub>` / `INVITE#…` copies, kept from #71 on).
7. **Devices** (#63), with the token pointers.
8. **Other members' items naming it**: their mutes and blocks of it and their last-push times about it, for everyone
   who ever shared a circle with it.
9. **Reports** it filed or that name it (#71).
10. **Everything left under `ACCOUNT#<sub>`**: the profile, mutes, blocks, the report day counters, push times,
    past-circle and invite copies.

Then the Apple token is revoked (best effort, below) and the Cognito user deleted, last, so a retry still has a valid
token until the very end. A photo uploaded for a card that was never sent is not known to the server (no listing of
the bucket); the bucket's one-day lifecycle rule removes it (#66).

**The Apple token.** Cognito does the Sign in with Apple code exchange itself, as the Services ID, and keeps Apple's
tokens: neither the app nor this API ever sees one, so there is nothing of Cognito's to revoke. Apple's `/auth/revoke`
takes a refresh or access token issued to the client asking. So at deletion the app asks Apple once more, natively
(`ASAuthorizationAppleIDProvider`, the bundle id's own client), and sends the authorization code with the delete; the
API exchanges it at `/auth/token` for a refresh token and revokes it at `/auth/revoke`, both with a client secret
signed by the Sign in with Apple key in `birdjournal/apple-sign-in`. Revoking a token of the app's primary App ID
ends the birder's Sign in with Apple relationship with the app group, the Services ID's included. Without a code
(the birder cancelled Apple's sheet, a Google account) or if Apple refuses, the deletion still goes ahead: it never
waits on Apple.
"""

from __future__ import annotations

import hashlib
import json
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Protocol

from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

from birdjournal_api.circles import CircleStore, NotFound
from birdjournal_api.devices import DeviceStore
from birdjournal_api.finds import FindStore, REACTIONS_PK, reaction_push_key
from birdjournal_api.pushes import DIGEST_PK
from birdjournal_api.safety import REPORTS_PK

log = logging.getLogger(__name__)

APPLE = "https://appleid.apple.com"
# Access tokens last an hour (#60); the tombstone outlives the last one.
TOMBSTONE_SECONDS = 2 * 3600


def tombstone_key(subject: str) -> dict[str, str]:
    """A deleted account's marker, by a hash of its subject, so no item names it (the scan test) while its last
    access tokens could still reach the API."""
    return {"pk": "DELETED", "sk": hashlib.sha256(subject.encode()).hexdigest()}


class UserDirectory(Protocol):
    """The user pool: deletes a user by its username."""

    def delete_user(self, username: str) -> None: ...


class AppleTokens(Protocol):
    """Revokes the token an authorization code from the app's own Sign in with Apple gives; True when Apple took it."""

    def revoke(self, authorization_code: str) -> bool: ...


@dataclass(frozen=True)
class DeletionReport:
    finds: int = 0
    reactions: int = 0
    circles_left: int = 0
    circles_deleted: int = 0
    apple_revoked: bool = False


class AccountDeleter:
    def __init__(
        self, table: Any, circles: CircleStore, finds: FindStore, devices: DeviceStore, *,
        users: UserDirectory, apple: AppleTokens | None,
        clock: Callable[[], datetime],
    ) -> None:
        self._table = table
        self._circles = circles
        self._finds = finds
        self._devices = devices
        self._users = users
        self._apple = apple
        self._clock = clock

    def is_deleted(self, subject: str) -> bool:
        """Whether the account was deleted within the life of its last access tokens."""
        item = self._table.get_item(Key=tombstone_key(subject), ConsistentRead=True).get("Item")
        return item is not None and int(item["until"]) > self._clock().timestamp()

    def delete(self, subject: str, username: str, *, apple_authorization_code: str | None = None) -> DeletionReport:
        account = f"ACCOUNT#{subject}"
        # First of all: the account's access tokens stay valid for up to an hour after the Cognito user goes, and any
        # other call with one (the outbox's put, a circles refresh) would write the account back (#71).
        self._table.put_item(Item={**tombstone_key(subject), "until": int(self._clock().timestamp() + TOMBSTONE_SECONDS),
                                   "ttl": int(self._clock().timestamp() + TOMBSTONE_SECONDS)})
        current = self._circles.circle_ids_of(subject)
        past = [str(item["sk"]).removeprefix("LEFT#") for item in self._query(account, "LEFT#")]
        circles = list(dict.fromkeys(current + past))
        # Everyone who ever shared a circle with it, read before any circle changes.
        co_members: set[str] = set()
        for circle_id in circles:
            _, members = self._circles.items_of_circle(circle_id)
            co_members.update(str(item["sk"]).removeprefix("MEMBER#") for item in members)
        co_members.discard(subject)

        # Other members' items naming it, first: the circles they are found through change below, so a deletion
        # cut short and retried could no longer find them.
        with self._table.batch_writer(overwrite_by_pkeys=["pk", "sk"]) as batch:
            for member in sorted(co_members):
                for sort_key in (f"MUTE#FRIEND#{subject}", f"BLOCK#{subject}", f"PUSHED#{subject}"):
                    batch.delete_item(Key={"pk": f"ACCOUNT#{member}", "sk": sort_key})

        # 1. Finds.
        find_ids = [str(item["sk"]).removeprefix("FIND#") for item in self._query(account, "FIND#")]
        for sighting_id in find_ids:
            self._finds.delete(subject, sighting_id)

        # 2. Reactions given.
        given = self._query(account, "REACTION#")
        for item in given:
            owner, sighting_id, kind = _reaction_copy(str(item["sk"]))
            self._table.delete_item(Key={"pk": f"FIND#{owner}#{sighting_id}", "sk": f"REACTION#{subject}#{kind}"})
            self._remove_from_set(reaction_push_key(owner, sighting_id), "shown", {f"{subject}#{kind}"})
            self._table.delete_item(Key={"pk": item["pk"], "sk": item["sk"]})
        for buffer in self._partition(REACTIONS_PK):
            mine = {value for value in buffer.get("reactions", set()) if str(value).startswith(f"{subject}#")}
            if mine:
                self._remove_from_set({"pk": buffer["pk"], "sk": buffer["sk"]}, "reactions", mine)

        # 3. Digest buffers.
        for buffer in self._partition(DIGEST_PK):
            if subject in (buffer.get("recipient"), buffer.get("friend")):
                self._table.delete_item(Key={"pk": buffer["pk"], "sk": buffer["sk"]})

        # 4. Goals.
        for circle_id in circles:
            for goal in self._partition(f"CIRCLE#{circle_id}#GOALS"):
                removes = []
                if goal.get("created_by") == subject:
                    removes.append("created_by")
                if str(goal.get("completed_by", "")).startswith(f"{subject}#"):
                    removes.append("completed_by")
                if removes:
                    self._table.update_item(
                        Key={"pk": goal["pk"], "sk": goal["sk"]}, UpdateExpression="REMOVE " + ", ".join(removes)
                    )

        # 5. Circles.
        left = deleted = 0
        for circle_id in circles:
            meta, members = self._circles.items_of_circle(circle_id)
            others = [m for m in members if "left_at" not in m and m["sk"] != f"MEMBER#{subject}"]
            if meta is None:
                self._circles.forget_member(circle_id, subject)
            elif not others and (circle_id in current or meta.get("created_by") == subject):
                # Nobody else in it: it goes. (A circle it left long ago that others left too, and that names
                # someone else as its creator, is theirs and stays.)
                self._circles.delete_circle(circle_id, subject)
                deleted += 1
            else:
                if circle_id in current:
                    try:
                        self._circles.leave(subject, circle_id)
                    except NotFound:
                        pass
                    left += 1
                self._circles.forget_member(circle_id, subject)

        # 6. Invites.
        for item in self._query(account, "INVITE#"):
            self._table.delete_item(Key={"pk": f"INVITE#{str(item['sk']).removeprefix('INVITE#')}", "sk": "INVITE"})

        # 7. Devices.
        for device in self._devices.devices_of(subject):
            self._devices.unregister(subject, device.token)

        # 9. Reports.
        for report in self._partition(REPORTS_PK):
            if subject in (report.get("reporter"), report.get("account")):
                self._table.delete_item(Key={"pk": report["pk"], "sk": report["sk"]})

        # 10. The rest of the account's partition, the profile last.
        rest = [{"pk": item["pk"], "sk": item["sk"]} for item in self._query(account, None)]
        with self._table.batch_writer(overwrite_by_pkeys=["pk", "sk"]) as batch:
            for key in rest:
                if key["sk"] != "PROFILE":
                    batch.delete_item(Key=key)
        self._table.delete_item(Key={"pk": account, "sk": "PROFILE"})

        revoked = False
        if apple_authorization_code and self._apple is not None:
            try:
                revoked = self._apple.revoke(apple_authorization_code)
            except Exception:
                log.exception("revoking the Sign in with Apple token failed")
        self._users.delete_user(username)
        log.info(
            "account deleted: %d finds, %d reactions, %d circles left, %d deleted, apple %s",
            len(find_ids), len(given), left, deleted, revoked,
        )
        return DeletionReport(
            finds=len(find_ids), reactions=len(given), circles_left=left, circles_deleted=deleted,
            apple_revoked=revoked,
        )

    def _remove_from_set(self, key: dict[str, str], attribute: str, values: set[str]) -> None:
        try:
            self._table.update_item(
                Key=key, UpdateExpression=f"DELETE #a :values", ConditionExpression="attribute_exists(pk)",
                ExpressionAttributeNames={"#a": attribute}, ExpressionAttributeValues={":values": values},
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    def _query(self, pk: str, prefix: str | None) -> list[dict[str, Any]]:
        condition = Key("pk").eq(pk) & Key("sk").begins_with(prefix) if prefix else Key("pk").eq(pk)
        return self._all(condition)

    def _partition(self, pk: str) -> list[dict[str, Any]]:
        return self._all(Key("pk").eq(pk))

    def _all(self, condition: Any) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        kwargs: dict[str, Any] = {"KeyConditionExpression": condition, "ConsistentRead": True}
        while True:
            response = self._table.query(**kwargs)
            items.extend(response["Items"])
            if "LastEvaluatedKey" not in response:
                return items
            kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]


def _reaction_copy(sort_key: str) -> tuple[str, str, str]:
    """`REACTION#<owner>#<sighting id>#<kind>` into its parts."""
    rest = sort_key.removeprefix("REACTION#")
    head, _, kind = rest.rpartition("#")
    owner, _, sighting_id = head.rpartition("#")
    return owner, sighting_id, kind


# The real adapters.


class CognitoUsers:
    def __init__(self, cognito: Any, user_pool_id: str) -> None:
        self._cognito = cognito
        self._pool = user_pool_id

    def delete_user(self, username: str) -> None:
        try:
            self._cognito.admin_delete_user(UserPoolId=self._pool, Username=username)
        except self._cognito.exceptions.UserNotFoundException:
            # Already gone: a deletion retried after its last step.
            pass


class AppleSignIn:
    """Apple's token endpoints with a client secret signed by the Sign in with Apple key (`birdjournal/apple-sign-in`,
    JSON `{services_id, team_id, key_id, private_key}`, stored by the accounts wizard)."""

    def __init__(self, load_key: Callable[[], dict[str, str]], client_id: str, post: Callable[..., Any]) -> None:
        self._load_key = load_key
        self._client_id = client_id
        self._post = post

    def client_secret(self, now: int | None = None) -> str:
        import jwt

        key = self._load_key()
        issued = int(time.time()) if now is None else now
        return jwt.encode(
            {"iss": key["team_id"], "iat": issued, "exp": issued + 300, "aud": APPLE, "sub": self._client_id},
            key["private_key"], algorithm="ES256", headers={"kid": key["key_id"]},
        )

    def revoke(self, authorization_code: str) -> bool:
        secret = self.client_secret()
        token = self._post(
            f"{APPLE}/auth/token",
            data={
                "client_id": self._client_id, "client_secret": secret, "code": authorization_code,
                "grant_type": "authorization_code",
            },
        )
        if token.status_code != 200:
            log.warning("Apple refused the authorization code: %s %s", token.status_code, token.text[:200])
            return False
        body = token.json()
        value, hint = (body["refresh_token"], "refresh_token") if "refresh_token" in body else (body["access_token"], "access_token")
        revoked = self._post(
            f"{APPLE}/auth/revoke",
            data={"client_id": self._client_id, "client_secret": secret, "token": value, "token_type_hint": hint},
        )
        if revoked.status_code != 200:
            log.warning("Apple refused the revocation: %s %s", revoked.status_code, revoked.text[:200])
            return False
        return True


def secrets_manager_apple_key(secret_name: str, region: str) -> Callable[[], dict[str, str]]:
    def load() -> dict[str, str]:
        import boto3

        raw = boto3.client("secretsmanager", region_name=region).get_secret_value(SecretId=secret_name)["SecretString"]
        value: dict[str, str] = json.loads(raw)
        return value

    return load


def user_pool_id(issuer: str) -> str:
    """`https://cognito-idp.<region>.amazonaws.com/<pool id>` → the pool id."""
    return issuer.rstrip("/").rpartition("/")[2]
