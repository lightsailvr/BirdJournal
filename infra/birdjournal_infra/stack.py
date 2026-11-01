from pathlib import Path
from typing import Any

from aws_cdk import CfnOutput, Stack, Tags
from constructs import Construct

from birdjournal_infra.api import Api
from birdjournal_infra.auth import Auth
from birdjournal_infra.budget import Budget
from birdjournal_infra.config import TAG_KEY, TAG_VALUE, BirdJournalConfig
from birdjournal_infra.data import Data

BACKEND_DIRECTORY = Path(__file__).resolve().parents[2] / "backend"


class BirdJournalStack(Stack):
    """The whole BirdJournal backend in one stack (ADR-0002, issue #60)."""

    def __init__(self, scope: Construct, id: str, *, config: BirdJournalConfig, **kwargs: Any) -> None:
        super().__init__(scope, id, **kwargs)
        # On the stack, so every resource in it carries the tag; the template tests check none is missed.
        Tags.of(self).add(TAG_KEY, TAG_VALUE)

        auth = Auth(self, "Auth", config=config)
        data = Data(self, "Data")
        api = Api(
            self,
            "Api",
            backend=BACKEND_DIRECTORY,
            environment={
                "TABLE_NAME": data.table.table_name,
                "COGNITO_ISSUER": auth.issuer,
                "COGNITO_CLIENT_IDS": auth.app_client.user_pool_client_id,
            },
        )
        data.table.grant_read_write_data(api.function)
        Budget(self, "Budget", monthly_usd=config.monthly_budget_usd, email=config.budget_alert_email)

        domain = f"{config.cognito_domain_prefix}.auth.{self.region}.amazoncognito.com"
        outputs = {
            "ApiUrl": api.url,
            "UserPoolId": auth.user_pool.user_pool_id,
            "AppClientId": auth.app_client.user_pool_client_id,
            "CognitoDomain": domain,
            # Both Google's authorized redirect URI and Apple's Services ID return URL.
            "IdpResponseUrl": f"https://{domain}/oauth2/idpresponse",
            "TableName": data.table.table_name,
        }
        for name, value in outputs.items():
            CfnOutput(self, name, value=value)
