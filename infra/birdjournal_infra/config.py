import os
from dataclasses import dataclass

from constructs import Node

TAG_KEY = "project"
TAG_VALUE = "birdjournal"


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

    @classmethod
    def from_context(cls, node: Node) -> "BirdJournalConfig":
        email = node.try_get_context("budgetAlertEmail") or os.environ.get("BUDGET_ALERT_EMAIL")
        if not email:
            raise ValueError(
                "Set BUDGET_ALERT_EMAIL (or -c budgetAlertEmail=...): the budget alarm needs an address. "
                "infra/scripts/deploy.sh reads it from ~/keys/birdjournal.env."
            )
        return cls(
            cognito_domain_prefix=node.get_context("cognitoDomainPrefix"),
            google_oauth_secret_name=node.get_context("googleOAuthSecretName"),
            apple_sign_in_secret_name=node.get_context("appleSignInSecretName"),
            oauth_callback_urls=tuple(node.get_context("oauthCallbackUrls")),
            oauth_logout_urls=tuple(node.get_context("oauthLogoutUrls")),
            monthly_budget_usd=int(node.get_context("monthlyBudgetUsd")),
            budget_alert_email=email,
        )
