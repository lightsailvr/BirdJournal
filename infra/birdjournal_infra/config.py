import os
from dataclasses import dataclass

from constructs import Node

TAG_KEY = "project"
TAG_VALUE = "birdjournal"
ART_AUTO_PAINT_RULES = ("every_glasses_add", "legendary_or_rare")
MODERATION_SWITCH = ("off", "on")


@dataclass(frozen=True)
class BirdJournalConfig:
    # Globally unique per region: https://<prefix>.auth.us-west-2.amazoncognito.com
    cognito_domain_prefix: str
    # Both created once by infra/scripts/accounts-wizard.sh, outside the stack (cdk destroy leaves them):
    # the Google OAuth web client as {"client_id", "client_secret"}, and the Sign in with Apple
    # Services ID and key as {"services_id", "team_id", "key_id", "private_key"}.
    google_oauth_secret_name: str
    apple_sign_in_secret_name: str
    # The app's URL scheme on its own path (spec v2, "Accounts and the app client"), plus a localhost
    # pair for infra/scripts/smoke.py.
    oauth_callback_urls: tuple[str, ...]
    oauth_logout_urls: tuple[str, ...]
    # The monthly budget for everything tagged project=birdjournal, in US dollars.
    monthly_budget_usd: int
    # Who the budget alarm emails. Kept out of the public repo: `-c budgetAlertEmail=...` or the
    # BUDGET_ALERT_EMAIL environment variable (infra/scripts/deploy.sh reads it from ~/keys/birdjournal.env).
    budget_alert_email: str
    # The invite links' host (issue #61): https://<invite_domain>/i/<token>. Its DNS is at SiteGround.
    invite_domain: str
    # The app IDs (<team ID>.<bundle ID>) the domain's apple-app-site-association names for universal links.
    ios_app_ids: tuple[str, ...]
    # The invite domain's ACM certificate in us-east-1, requested by infra/scripts/circles-wizard.sh outside the
    # stack. Not a secret, but it names the account: `-c inviteCertificateArn=...` or INVITE_CERTIFICATE_ARN
    # (infra/scripts/deploy.sh reads it from ~/keys/birdjournal.env).
    invite_certificate_arn: str
    # The switch between the friends phase and the public launch (issues #68 and #69): `every_glasses_add` in the
    # friends phase paints every add with a glasses photo by a signed-in birder and every painting asked for;
    # `legendary_or_rare` at the public launch paints Legendary and Rare-or-rarer adds automatically, and other scene art
    # and all photo art on request within `art_daily_allowance` a day per account. The API reads both.
    art_auto_paint: str = "every_glasses_add"
    art_daily_allowance: int = 5
    # The APNs token key (issue #63): a Secrets Manager secret {"key_id", "team_id", "private_key"} created by
    # infra/scripts/push-wizard.sh outside the stack, and the app's bundle id, every push's apns-topic.
    apns_secret_name: str = "birdjournal/apns"
    apns_topic: str = "com.matthewcelia.mybirdjournal"
    # Where reports (issue #71) are mailed through SES, from the same address (one verified SES identity, so the
    # sandbox is enough). Kept out of the public repo like the budget's: `-c reportEmail=...` or REPORT_EMAIL, else the
    # budget alert address.
    report_email: str = ""
    # Rekognition moderation of art-job inputs and outputs and shared photos (issue #71): `off` in the friends phase,
    # `on` for the public launch.
    moderation: str = "off"

    @classmethod
    def from_context(cls, node: Node) -> "BirdJournalConfig":
        email = node.try_get_context("budgetAlertEmail") or os.environ.get("BUDGET_ALERT_EMAIL")
        if not email:
            raise ValueError(
                "Set BUDGET_ALERT_EMAIL (or -c budgetAlertEmail=...): the budget alarm needs an address. "
                "infra/scripts/deploy.sh reads it from ~/keys/birdjournal.env."
            )
        certificate = node.try_get_context("inviteCertificateArn") or os.environ.get("INVITE_CERTIFICATE_ARN")
        if not certificate:
            raise ValueError(
                "Set INVITE_CERTIFICATE_ARN (or -c inviteCertificateArn=...): the invite domain's us-east-1 "
                "certificate. infra/scripts/circles-wizard.sh requests it and saves it to ~/keys/birdjournal.env."
            )
        art_auto_paint = node.try_get_context("artAutoPaint") or "every_glasses_add"
        if art_auto_paint not in ART_AUTO_PAINT_RULES:
            raise ValueError(f"artAutoPaint must be one of {', '.join(ART_AUTO_PAINT_RULES)}, not {art_auto_paint!r}")
        moderation = node.try_get_context("moderation") or "off"
        if moderation not in MODERATION_SWITCH:
            raise ValueError(f"moderation must be on or off, not {moderation!r}")
        report_email = node.try_get_context("reportEmail") or os.environ.get("REPORT_EMAIL") or email
        art_daily_allowance = _whole_number(node.try_get_context("artDailyAllowance"), default=5, name="artDailyAllowance")
        return cls(
            cognito_domain_prefix=node.get_context("cognitoDomainPrefix"),
            google_oauth_secret_name=node.get_context("googleOAuthSecretName"),
            apple_sign_in_secret_name=node.get_context("appleSignInSecretName"),
            oauth_callback_urls=tuple(node.get_context("oauthCallbackUrls")),
            oauth_logout_urls=tuple(node.get_context("oauthLogoutUrls")),
            monthly_budget_usd=int(node.get_context("monthlyBudgetUsd")),
            budget_alert_email=email,
            invite_domain=node.get_context("inviteDomain"),
            ios_app_ids=tuple(node.get_context("iosAppIds")),
            invite_certificate_arn=certificate,
            art_auto_paint=art_auto_paint,
            art_daily_allowance=art_daily_allowance,
            apns_secret_name=node.get_context("apnsSecretName"),
            apns_topic=node.get_context("apnsTopic"),
            report_email=report_email,
            moderation=moderation,
        )


def _whole_number(value: object, *, default: int, name: str) -> int:
    if value is None:
        return default
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    raise ValueError(f"{name} must be a whole number of paintings, not {value!r}")
