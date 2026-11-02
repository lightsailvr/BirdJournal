"""Reports (issue #71, spec v2 "Safety"): a member reports a find or an account. The report is stored and emailed to
the maintainer through SES.

Only someone who shares the circle named in the report with the reported account, now, may report (404 otherwise, so
an account's or a find's existence never leaks); a find must have reached that circle. Never oneself (422). The report
keeps a snapshot of what was reported (the find as that circle showed it, its shared card's note, caption and photo
key), so the maintainer sees what the reporter saw even after the owner changes or deletes it.

A reporter files at most `REPORTS_PER_DAY` a UTC day (429 after), so the maintainer's inbox can't be flooded. The mail
is sent after the report is stored, and a failed send never fails the report (it is logged, and the report waits in
the table).

Items:

- `REPORTS` / `<created at>#<id>`: the report. One partition, like the digests', so the maintainer reads every report
  with one query, oldest first; there are few.
- `ACCOUNT#<reporter>` / `REPORTDAY#<yyyy-mm-dd>`: the day's count, `ttl` two days after.

Account deletion removes the reports a deleted account filed and those about it (one query of the partition, a filter).
"""

from __future__ import annotations

import logging
import secrets
import unicodedata
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from enum import StrEnum
from typing import Any, Protocol

from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

from birdjournal_api.circles import CircleStore, NotFound
from birdjournal_api.finds import FindStore

log = logging.getLogger(__name__)

REPORTS_PK = "REPORTS"
REPORTS_PER_DAY = 20
DETAILS_MAX = 1000


class ReportKind(StrEnum):
    FIND = "find"
    ACCOUNT = "account"


class ReportReason(StrEnum):
    INAPPROPRIATE = "inappropriate"
    HARASSMENT = "harassment"
    SPAM = "spam"
    OTHER = "other"

    @property
    def words(self) -> str:
        return {
            ReportReason.INAPPROPRIATE: "Inappropriate content",
            ReportReason.HARASSMENT: "Harassment or bullying",
            ReportReason.SPAM: "Spam",
            ReportReason.OTHER: "Something else",
        }[self]


class OwnAccount(Exception):
    """Nobody reports or blocks themselves."""


class TooManyReports(Exception):
    """The reporter's reports for the day are used up."""


@dataclass(frozen=True)
class Report:
    id: str
    kind: ReportKind
    reporter: str
    account: str
    circle_id: str
    sighting_id: str | None
    reason: ReportReason
    details: str | None
    created_at: datetime
    snapshot: dict[str, Any]


class Mailer(Protocol):
    """Sends one plain-text mail to the maintainer: SES in the stack, a recording fake in the tests."""

    def send(self, subject: str, body: str) -> None: ...


class NoMailer:
    """No report address configured (before the stack sets one): reports wait in the table."""

    def send(self, subject: str, body: str) -> None:
        log.warning("no report address: report mail not sent (%s)", subject)


class SesMailer:
    def __init__(self, ses: Any, *, sender: str, recipient: str) -> None:
        self._ses = ses
        self._sender = sender
        self._recipient = recipient

    def send(self, subject: str, body: str) -> None:
        self._ses.send_email(
            FromEmailAddress=self._sender,
            Destination={"ToAddresses": [self._recipient]},
            Content={"Simple": {"Subject": {"Data": subject[:200]}, "Body": {"Text": {"Data": body}}}},
        )


def clean_details(raw: str | None) -> str | None:
    if raw is None:
        return None
    text = raw.strip()
    if not text:
        return None
    if len(text) > DETAILS_MAX:
        raise ValueError(f"The details are longer than {DETAILS_MAX} characters")
    if any(character not in "\n\t" and unicodedata.category(character).startswith("C") for character in text):
        raise ValueError("The details have a control character")
    return text


class ReportStore:
    def __init__(
        self, table: Any, circles: CircleStore, finds: FindStore, mailer: Mailer, clock: Callable[[], datetime],
        *, art_cdn_base_url: str | None = None,
    ) -> None:
        self._table = table
        self._circles = circles
        self._finds = finds
        self._mailer = mailer
        self._clock = clock
        self._cdn = art_cdn_base_url

    def report(
        self, reporter: str, *, kind: ReportKind, account: str, circle_id: str, sighting_id: str | None,
        reason: ReportReason, details: str | None,
    ) -> Report:
        if reporter == account:
            raise OwnAccount()
        if not (self._circles.is_member(reporter, circle_id) and self._circles.is_member(account, circle_id)):
            raise NotFound()
        snapshot: dict[str, Any] = {}
        if kind is ReportKind.FIND:
            if sighting_id is None:
                raise ValueError("sighting_id")
            find = self._finds.find(account, sighting_id)
            if find is None or circle_id not in find.circle_ids:
                raise NotFound()
            snapshot = self._finds.as_shown(find, circle_id)
        names = self._circles.display_names([reporter, account])
        snapshot["account_name"] = names.get(account)
        snapshot["reporter_name"] = names.get(reporter)
        snapshot["circle_name"] = self._circles.circle_names([circle_id]).get(circle_id)
        now = self._clock()
        self._count(reporter, now)
        report = Report(
            id=secrets.token_hex(8), kind=kind, reporter=reporter, account=account, circle_id=circle_id,
            sighting_id=sighting_id if kind is ReportKind.FIND else None, reason=reason, details=details,
            created_at=now, snapshot={key: value for key, value in snapshot.items() if value is not None},
        )
        item: dict[str, Any] = {
            "pk": REPORTS_PK,
            "sk": f"{now.astimezone(UTC).isoformat()}#{report.id}",
            "kind": kind.value,
            "reporter": reporter,
            "account": account,
            "circle_id": circle_id,
            "reason": reason.value,
            "created_at": now.isoformat(),
            "snapshot": report.snapshot,
        }
        if report.sighting_id:
            item["sighting_id"] = report.sighting_id
        if details:
            item["details"] = details
        self._table.put_item(Item=item)
        try:
            self._mailer.send(*self.mail(report))
        except Exception:
            # The report is kept; the maintainer reads the partition if a mail went missing.
            log.exception("the report mail failed")
        return report

    def reports(self) -> list[dict[str, Any]]:
        """Every report, oldest first."""
        items: list[dict[str, Any]] = []
        kwargs: dict[str, Any] = {"KeyConditionExpression": Key("pk").eq(REPORTS_PK), "ConsistentRead": True}
        while True:
            response = self._table.query(**kwargs)
            items.extend(response["Items"])
            if "LastEvaluatedKey" not in response:
                return items
            kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]

    def mail(self, report: Report) -> tuple[str, str]:
        snapshot = report.snapshot
        who = snapshot.get("account_name") or "an unnamed account"
        what = "a find" if report.kind is ReportKind.FIND else "an account"
        subject = f"BirdJournal report: {what} by {who} ({report.reason.words})"
        lines = [
            f"Report {report.id} at {report.created_at.astimezone(UTC).strftime('%Y-%m-%d %H:%M UTC')}",
            "",
            f"Reason: {report.reason.words}",
            f"Details: {report.details or '(none)'}",
            "",
            f"Reported account: {who} ({report.account})",
            f"Reported by: {snapshot.get('reporter_name') or 'an unnamed account'} ({report.reporter})",
            f"Circle: {snapshot.get('circle_name') or '?'} ({report.circle_id})",
        ]
        if report.kind is ReportKind.FIND:
            lines += [
                "",
                f"Find: {report.sighting_id}",
                f"Species: {snapshot.get('common_name')} ({snapshot.get('scientific_name')}), {snapshot.get('method')}",
                f"Place: {snapshot.get('place') or '(none)'}",
                f"Found at: {snapshot.get('found_at')}",
            ]
            for field, label in (("note", "Note"), ("caption", "Caption")):
                if snapshot.get(field):
                    lines.append(f"{label}: {snapshot[field]}")
            for field, label in (("photo_key", "Photo"), ("art_key", "Art")):
                if key := snapshot.get(field):
                    lines.append(f"{label}: {self._cdn}/{key}" if self._cdn else f"{label}: {key}")
        lines += ["", "Every report is also in the table: pk REPORTS."]
        return subject, "\n".join(lines)

    def _count(self, reporter: str, now: datetime) -> None:
        day = now.astimezone(UTC).date()
        try:
            self._table.update_item(
                Key={"pk": f"ACCOUNT#{reporter}", "sk": f"REPORTDAY#{day.isoformat()}"},
                UpdateExpression="ADD used :one SET #ttl = if_not_exists(#ttl, :ttl)",
                ConditionExpression="attribute_not_exists(used) OR used < :cap",
                ExpressionAttributeNames={"#ttl": "ttl"},
                ExpressionAttributeValues={
                    ":one": 1, ":cap": REPORTS_PER_DAY,
                    ":ttl": int((datetime(day.year, day.month, day.day, tzinfo=UTC) + timedelta(days=3)).timestamp()),
                },
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise TooManyReports() from None
            raise


class BlockStore:
    """Blocks (issue #71): `ACCOUNT#<blocker>` / `BLOCK#<blocked>` (devices.py's MuteStore keeps them beside the mutes,
    since pushes read both together). Only someone the birder shares a circle with now can be blocked (404 otherwise);
    unblocking always works."""

    def __init__(self, circles: CircleStore, mutes: Any) -> None:
        self._circles = circles
        self._mutes = mutes

    def block(self, subject: str, other: str) -> None:
        if subject == other:
            raise OwnAccount()
        if not self._circles.share_a_circle(subject, other):
            raise NotFound()
        self._mutes.block(subject, other)

    def unblock(self, subject: str, other: str) -> None:
        self._mutes.unblock(subject, other)

    def blocked(self, subject: str) -> list[tuple[str, str | None]]:
        """The blocked accounts with their names, for Settings' list."""
        ids = sorted(self._mutes.blocked_by(subject))
        names = self._circles.display_names(ids)
        return [(account, names.get(account)) for account in ids]
